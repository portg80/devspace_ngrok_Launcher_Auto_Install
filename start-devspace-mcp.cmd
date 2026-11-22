@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1
set "DEVSPACE_BOOTSTRAP_FILE=%~f0"

where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo [FATAL] Windows PowerShell not found. This launcher requires Windows 10/11 PowerShell.
  pause
  exit /b 9009
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $p=$env:DEVSPACE_BOOTSTRAP_FILE; $t=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8); $m='#'+'<POWERSHELL_PAYLOAD_V1>'; $i=$t.IndexOf($m); if($i -lt 0){throw 'PowerShell payload marker not found.'}; Invoke-Expression $t.Substring($i+$m.Length)"
set "EC=%ERRORLEVEL%"
echo.
if not "%EC%"=="0" echo Launcher finished with error code %EC%.
echo Press any key to close this window...
pause >nul
exit /b %EC%

#<POWERSHELL_PAYLOAD_V1>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# -----------------------------------------------------------------------------
# DevSpace MCP Secure Tunnel launcher for Windows 10/11
# - no PowerShell execution-policy prerequisite: CMD bootstrap uses Bypass
# - idempotent dependency checks and installs
# - WinGet recovery chain
# - Git + Git Bash, compatible Node.js LTS, Secure MCP Tunnel client, DevSpace
# - OpenAI Secure MCP Tunnel with outbound-only HTTPS and local OAuth bridge
# - DevSpace init/config/doctor through Git Bash
# - full visible errors + transcript logs (secrets excluded where practical)
# -----------------------------------------------------------------------------

$ScriptPath = [IO.Path]::GetFullPath($env:DEVSPACE_BOOTSTRAP_FILE)
$ScriptDir  = Split-Path -Parent $ScriptPath
$Port       = 7676
$MinNode    = [Version]'22.19.0'
$MaxNode    = [Version]'27.0.0'
$MinTunnelClient = [Version]'0.0.19'

$SettingsPath = Join-Path $ScriptDir 'devspace-secure-tunnel-settings.json'
$DotEnvPath = Join-Path $ScriptDir '.env'
$LegacyDomainPath = Join-Path $ScriptDir 'dev-domain.txt'
$LogDir = Join-Path $ScriptDir 'logs'
$RuntimeDir = Join-Path $env:LOCALAPPDATA 'DevSpaceMCPLauncher'
try {
    New-Item -ItemType Directory -Path $RuntimeDir -Force -ErrorAction Stop | Out-Null
} catch {
    $RuntimeDir = Join-Path $env:TEMP 'DevSpaceMCPLauncher'
    New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
}
$RuntimeStatePath = Join-Path $RuntimeDir 'runtime.json'
$ScriptVersion = '2.5.5'

try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch {}
try { [Console]::InputEncoding  = New-Object Text.UTF8Encoding($false) } catch {}


# Light-pink accent for saved values / "Enter — keep saved" hints.
# ConsoleColor only has Magenta, which is too close to the green menu accent and
# looks purple in many Windows palettes. Enable VT processing and use a true-color
# light pink where supported; fall back to standard Magenta on older consoles.
$script:UseLightPinkAnsi = $false
$consoleAnsiSource = @'
using System;
using System.Runtime.InteropServices;
namespace DevSpaceMcp {
    public static class ConsoleAnsi {
        private const int STD_OUTPUT_HANDLE = -11;
        private const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern IntPtr GetStdHandle(int nStdHandle);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
        public static bool EnableVirtualTerminal() {
            IntPtr h = GetStdHandle(STD_OUTPUT_HANDLE);
            if (h == IntPtr.Zero || h == new IntPtr(-1)) return false;
            uint mode;
            if (!GetConsoleMode(h, out mode)) return false;
            return SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        }
    }
}
'@
try {
    Add-Type -TypeDefinition $consoleAnsiSource -Language CSharp -ErrorAction Stop
    $script:UseLightPinkAnsi = [DevSpaceMcp.ConsoleAnsi]::EnableVirtualTerminal()
} catch {
    $script:UseLightPinkAnsi = $false
}

if (-not (Test-Path $LogDir)) {
    try { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    catch {
        $LogDir = Join-Path $env:TEMP 'DevSpaceMCP-logs'
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
}
$LogPath = Join-Path $LogDir ("DevSpace-MCP-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$WingetLogDir = Join-Path $LogDir 'winget'
try { New-Item -ItemType Directory -Path $WingetLogDir -Force | Out-Null } catch { $WingetLogDir = $LogDir }
$script:TranscriptActive = $false
$script:CurrentStep = 0
$script:GitBash = $null
$script:GitMintty = $null
$script:TunnelExe = $null
$script:TunnelProcess = $null
$script:TunnelStdOut = $null
$script:TunnelStdErr = $null
$script:BridgeProcess = $null
$script:BridgeStdOut = $null
$script:BridgeStdErr = $null
$script:BridgePort = 7677
$script:HealthPort = 7680
$script:RuntimeKey = $null
$script:SelectedAdminKey = ''
$script:RuntimeKeyChanged = $false
$script:AdminKeyChanged = $false
$script:AdminSelectionBack = $false
$script:NewAccountBinding = $false
$script:DevSpaceProcess = $null
$script:DevSpaceStdOut = $null
$script:DevSpaceStdErr = $null
$script:DevSpaceWatchdogProcess = $null
$script:DevSpaceWatchdogStopFile = $null
$script:DevSpaceJobProtected = $false

# -----------------------------------------------------------------------------
# Process lifetime guard
#
# DevSpace, the local OAuth bridge, and tunnel-client are attached to a Windows Job Object with
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. This gives us a security property that a
# PowerShell finally block alone cannot provide: if this launcher is terminated
# by Ctrl+C, the console window is closed, PowerShell crashes, or the launcher
# is otherwise killed, Windows closes the job handle and terminates the managed
# MCP/tunnel processes automatically.
# -----------------------------------------------------------------------------
$processGuardSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace DevSpaceMcp {
    public static class ProcessGuard {
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        private const int JobObjectExtendedLimitInformation = 9;
        private const uint PROCESS_TERMINATE = 0x0001;
        private const uint PROCESS_SET_QUOTA = 0x0100;
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        private static readonly object Sync = new object();
        private static IntPtr _job = IntPtr.Zero;
        private static HandlerRoutine _handler;

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        private delegate bool HandlerRoutine(uint ctrlType);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr hJob, int infoType, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

        public static void Initialize() {
            lock (Sync) {
                if (_job != IntPtr.Zero) return;
                IntPtr job = CreateJobObject(IntPtr.Zero, null);
                if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed");

                var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                IntPtr ptr = Marshal.AllocHGlobal(length);
                try {
                    Marshal.StructureToPtr(info, ptr, false);
                    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ptr, (uint)length)) {
                        int err = Marshal.GetLastWin32Error();
                        CloseHandle(job);
                        throw new Win32Exception(err, "SetInformationJobObject failed");
                    }
                } finally {
                    Marshal.FreeHGlobal(ptr);
                }

                _job = job;
                _handler = new HandlerRoutine(ConsoleControlHandler);
                // Best effort. KILL_ON_JOB_CLOSE still protects us when the launcher
                // process itself exits, even if a console handler cannot be installed.
                SetConsoleCtrlHandler(_handler, true);
            }
        }

        public static bool Assign(int processId) {
            lock (Sync) {
                if (_job == IntPtr.Zero) return false;
                IntPtr process = OpenProcess(PROCESS_TERMINATE | PROCESS_SET_QUOTA | PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
                if (process == IntPtr.Zero) return false;
                try {
                    bool inThisJob;
                    if (IsProcessInJob(process, _job, out inThisJob) && inThisJob) return true;
                    return AssignProcessToJobObject(_job, process);
                } finally {
                    CloseHandle(process);
                }
            }
        }

        public static void Shutdown() {
            lock (Sync) {
                if (_handler != null) {
                    try { SetConsoleCtrlHandler(_handler, false); } catch { }
                    _handler = null;
                }
                if (_job != IntPtr.Zero) {
                    IntPtr job = _job;
                    _job = IntPtr.Zero;
                    CloseHandle(job); // KILL_ON_JOB_CLOSE terminates anything still attached.
                }
            }
        }

        private static bool ConsoleControlHandler(uint ctrlType) {
            // CTRL_C_EVENT=0, CTRL_BREAK_EVENT=1, CTRL_CLOSE_EVENT=2,
            // CTRL_LOGOFF_EVENT=5, CTRL_SHUTDOWN_EVENT=6.
            // Close the job immediately so MCP access is revoked before the
            // launcher finishes processing the console-control event.
            lock (Sync) {
                if (_job != IntPtr.Zero) {
                    IntPtr job = _job;
                    _job = IntPtr.Zero;
                    CloseHandle(job);
                }
            }
            return false; // Let the default Windows handler terminate the launcher too.
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $processGuardSource -Language CSharp -ErrorAction Stop
    [DevSpaceMcp.ProcessGuard]::Initialize()
} catch {
    throw "Не удалось включить защиту жизненного цикла MCP-процессов (Windows Job Object): $($_.Exception.Message)"
}

function Register-ManagedProcess {
    param(
        [Parameter(Mandatory=$true)]$Process,
        [Parameter(Mandatory=$true)][string]$Name
    )
    if (-not $Process) { throw "Не удалось привязать $Name к лаунчеру: процесс отсутствует." }
    $ok = $false
    try { $ok = [DevSpaceMcp.ProcessGuard]::Assign([int]$Process.Id) } catch { $ok = $false }
    if (-not $ok) {
        try { if (-not $Process.HasExited) { $Process.Kill() } } catch {}
        throw "Не удалось привязать процесс '$Name' (PID $($Process.Id)) к защитному Windows Job Object. Процесс остановлен, чтобы он не мог остаться работать после закрытия лаунчера."
    }
}

function Register-ManagedPid {
    param(
        [Parameter(Mandatory=$true)][int]$ProcessId,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $ok = $false
    try { $ok = [DevSpaceMcp.ProcessGuard]::Assign($ProcessId) } catch { $ok = $false }
    if (-not $ok) {
        try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch {}
        throw "Не удалось привязать процесс '$Name' (PID $ProcessId) к защитному Windows Job Object. Процесс остановлен."
    }
}


function Try-RegisterManagedProcess {
    param(
        [Parameter(Mandatory=$true)]$Process,
        [Parameter(Mandatory=$true)][string]$Name
    )

    if (-not $Process) { return $false }

    try {
        $ok = [DevSpaceMcp.ProcessGuard]::Assign([int]$Process.Id)
        if ($ok) { return $true }
    } catch {}

    Write-Warn ("Процесс '{0}' (PID {1}) уже может принадлежать другому Windows Job Object. " +
        "Привязка к внутреннему Job Object пропущена; безопасность обеспечит watchdog." -f $Name, $Process.Id)
    return $false
}

function Try-RegisterManagedPid {
    param(
        [Parameter(Mandatory=$true)][int]$ProcessId,
        [Parameter(Mandatory=$true)][string]$Name
    )

    try {
        $ok = [DevSpaceMcp.ProcessGuard]::Assign($ProcessId)
        if ($ok) { return $true }
    } catch {}

    Write-Warn ("Процесс '{0}' (PID {1}) не удалось дополнительно привязать к Windows Job Object. " +
        "Watchdog продолжит контролировать завершение DevSpace." -f $Name, $ProcessId)
    return $false
}

function Start-DevSpaceWatchdog {
    param([Parameter(Mandatory=$true)][int]$DevSpaceLauncherPid)

    Stop-DevSpaceWatchdog

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $script:DevSpaceWatchdogStopFile = Join-Path $LogDir ("devspace-watchdog-{0}-{1}.stop" -f $PID, $stamp)
    try { Remove-Item -LiteralPath $script:DevSpaceWatchdogStopFile -Force -ErrorAction SilentlyContinue } catch {}

    $parentStartTicks = 0L
    try {
        $parentStartTicks = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToFileTimeUtc()
    } catch {
        throw "Не удалось определить время запуска процесса launcher для watchdog: $($_.Exception.Message)"
    }

    $watchdogScript = @"
`$parentPid = $PID
`$parentStartTicks = $parentStartTicks
`$devSpaceLauncherPid = $DevSpaceLauncherPid
`$port = $Port
`$stopFile = '$($script:DevSpaceWatchdogStopFile.Replace("'","''"))'

function Test-LauncherAlive {
    try {
        `$p = Get-Process -Id `$parentPid -ErrorAction Stop
        return (`$p.StartTime.ToFileTimeUtc() -eq `$parentStartTicks)
    } catch {
        return `$false
    }
}

while (`$true) {
    if (Test-Path -LiteralPath `$stopFile) { exit 0 }
    if (-not (Test-LauncherAlive)) { break }
    Start-Sleep -Milliseconds 350
}

if (Test-Path -LiteralPath `$stopFile) { exit 0 }

# The launcher disappeared unexpectedly: revoke MCP access.
try {
    & "`$env:SystemRoot\System32\taskkill.exe" /PID `$devSpaceLauncherPid /T /F *> `$null
} catch {}

Start-Sleep -Milliseconds 250

# Defensive fallback in case Node detached from the Bash process tree.
try {
    `$listeners = Get-NetTCPConnection -LocalPort `$port -State Listen -ErrorAction SilentlyContinue
    foreach (`$listener in @(`$listeners)) {
        `$ownerPid = [int]`$listener.OwningProcess
        if (`$ownerPid -gt 0 -and `$ownerPid -ne `$PID) {
            try { Stop-Process -Id `$ownerPid -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
} catch {}

exit 0
"@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($watchdogScript))
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    try {
        $script:DevSpaceWatchdogProcess = Start-Process `
            -FilePath $psExe `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-EncodedCommand',$encoded) `
            -PassThru `
            -WindowStyle Hidden

        Start-Sleep -Milliseconds 120
        if ($script:DevSpaceWatchdogProcess.HasExited) {
            throw "watchdog завершился сразу после запуска с кодом $($script:DevSpaceWatchdogProcess.ExitCode)"
        }

        Write-Info ("Watchdog защиты DevSpace запущен (PID {0})." -f $script:DevSpaceWatchdogProcess.Id)
        Save-RuntimeState
        return $true
    } catch {
        $script:DevSpaceWatchdogProcess = $null
        Write-Warn "Не удалось запустить watchdog DevSpace: $($_.Exception.Message)"
        return $false
    }
}

function Stop-DevSpaceWatchdog {
    $watchdog = $script:DevSpaceWatchdogProcess
    $stopFile = $script:DevSpaceWatchdogStopFile

    if ($stopFile) {
        try {
            [IO.File]::WriteAllText($stopFile, 'stop', (New-Object Text.UTF8Encoding($false)))
        } catch {}
    }

    if ($watchdog) {
        try {
            if (-not $watchdog.HasExited) {
                try { [void]$watchdog.WaitForExit(1200) } catch {}
                if (-not $watchdog.HasExited) {
                    try { $watchdog.Kill() } catch {}
                }
            }
        } catch {}
    }

    if ($stopFile) {
        try { Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue } catch {}
    }

    $script:DevSpaceWatchdogProcess = $null
    $script:DevSpaceWatchdogStopFile = $null
    Save-RuntimeState
}


function Stop-ProcessTreeTargeted {
    param(
        [Parameter(Mandatory=$true)][int]$ProcessId,
        [string]$Label = 'процесс',
        $ExpectedStartTicks = $null,
        [switch]$Quiet
    )

    if ($ProcessId -le 0 -or $ProcessId -eq $PID) { return $false }

    $proc = $null
    try { $proc = Get-Process -Id $ProcessId -ErrorAction Stop } catch { return $false }

    if ($null -ne $ExpectedStartTicks) {
        try {
            $actual = [long]$proc.StartTime.ToFileTimeUtc()
            if ($actual -ne [long]$ExpectedStartTicks) {
                if (-not $Quiet) {
                    Write-Info ("PID {0} из старого runtime-state уже принадлежит другому процессу; пропускаю." -f $ProcessId)
                }
                return $false
            }
        } catch {
            return $false
        }
    }

    if (-not $Quiet) {
        Write-Info ("Останавливаю остаточный {0} (PID {1})..." -f $Label, $ProcessId)
    }

    try {
        $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        [void](Start-Process -FilePath $taskkill -ArgumentList @('/PID',[string]$ProcessId,'/T','/F') -PassThru -Wait -WindowStyle Hidden)
    } catch {
        try { Stop-Process -Id $ProcessId -Force -ErrorAction Stop } catch { return $false }
    }

    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
            if (-not $Quiet) { Write-Ok ("{0} остановлен." -f $Label) }
            return $true
        }
        Start-Sleep -Milliseconds 100
    }

    if (-not $Quiet) {
        Write-Warn ("Не удалось подтвердить завершение {0} (PID {1})." -f $Label, $ProcessId)
    }
    return $false
}

function Get-RuntimeProcessRecord {
    param($Process)

    if (-not $Process) { return $null }
    try {
        if ($Process.HasExited) { return $null }
        return [ordered]@{
            pid = [int]$Process.Id
            startTicks = [long]$Process.StartTime.ToFileTimeUtc()
        }
    } catch {
        return $null
    }
}

function Save-RuntimeState {
    try {
        $launcher = Get-Process -Id $PID -ErrorAction Stop
        $state = [ordered]@{
            schema = 1
            launcher = [ordered]@{
                pid = [int]$PID
                startTicks = [long]$launcher.StartTime.ToFileTimeUtc()
            }
            port = [int]$Port
            devspace = Get-RuntimeProcessRecord -Process $script:DevSpaceProcess
            tunnel = Get-RuntimeProcessRecord -Process $script:TunnelProcess
            bridge = Get-RuntimeProcessRecord -Process $script:BridgeProcess
            watchdog = Get-RuntimeProcessRecord -Process $script:DevSpaceWatchdogProcess
            updatedAt = [DateTime]::UtcNow.ToString('o')
        }

        $json = $state | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($RuntimeStatePath, $json, (New-Object Text.UTF8Encoding($false)))
    } catch {
        # Runtime-state is a recovery aid, not a reason to stop a working MCP.
        Write-Warn "Не удалось обновить runtime-state launcher: $($_.Exception.Message)"
    }
}

function Clear-RuntimeState {
    try { Remove-Item -LiteralPath $RuntimeStatePath -Force -ErrorAction SilentlyContinue } catch {}
}

function Stop-StaleProcessesFromRuntimeState {
    if (-not (Test-Path -LiteralPath $RuntimeStatePath -PathType Leaf)) { return 0 }

    try {
        $state = Get-Content -LiteralPath $RuntimeStatePath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warn 'Старый runtime-state повреждён; удаляю его и продолжаю сигнатурную проверку.'
        Clear-RuntimeState
        return 0
    }

    $stopped = 0
    foreach ($spec in @(
        [pscustomobject]@{ Property='watchdog'; Label='старый watchdog DevSpace' },
        [pscustomobject]@{ Property='devspace'; Label='старый DevSpace MCP' },
        [pscustomobject]@{ Property='tunnel'; Label='старый DevSpace Secure Tunnel' },
        [pscustomobject]@{ Property='bridge'; Label='старый DevSpace OAuth bridge' }
    )) {
        $property = $state.PSObject.Properties[$spec.Property]
        if (-not $property -or $null -eq $property.Value) { continue }

        $data = $property.Value
        $pidProp = $data.PSObject.Properties['pid']
        $ticksProp = $data.PSObject.Properties['startTicks']
        if (-not $pidProp) { continue }

        $pidValue = 0
        try { $pidValue = [int]$pidProp.Value } catch { continue }

        $ticksValue = $null
        if ($ticksProp) {
            try { $ticksValue = [long]$ticksProp.Value } catch { $ticksValue = $null }
        }

        if ($pidValue -gt 0) {
            if (Stop-ProcessTreeTargeted -ProcessId $pidValue -Label $spec.Label -ExpectedStartTicks $ticksValue) {
                $stopped++
            }
        }
    }

    Clear-RuntimeState
    return $stopped
}

function Test-IsDevSpaceServerProcess {
    param($CimProcess)

    if (-not $CimProcess) { return $false }

    $name = [string]$CimProcess.Name
    $cmd = [string]$CimProcess.CommandLine
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }

    if ($cmd -match '(?i)@waishnav[\\/]+devspace') { return $true }
    if ($cmd -match '(?i)\bdevspace\b.*\bserve\b') { return $true }
    if ($name -match '(?i)^node\.exe$' -and $cmd -match '(?i)\bdevspace\b') { return $true }

    return $false
}

function Get-EncodedPowerShellPayload {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }

    $m = [regex]::Match(
        $CommandLine,
        '(?i)(?:-EncodedCommand|-enc)\s+(?:"(?<b64>[A-Za-z0-9+/=]+)"|(?<b64>[A-Za-z0-9+/=]+))'
    )
    if (-not $m.Success) { return $null }

    try {
        $bytes = [Convert]::FromBase64String($m.Groups['b64'].Value)
        return [Text.Encoding]::Unicode.GetString($bytes)
    } catch {
        return $null
    }
}

function Stop-StaleLauncherWatchdogs {
    $stopped = 0
    try {
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match '(?i)^(powershell|pwsh)\.exe$' -and
                [int]$_.ProcessId -ne $PID
            }

        foreach ($p in @($procs)) {
            $payload = Get-EncodedPowerShellPayload -CommandLine ([string]$p.CommandLine)
            if (-not $payload) { continue }

            if (($payload -match '\$devSpaceLauncherPid') -and
                ($payload -match 'Test-LauncherAlive') -and
                ($payload -match ('\$port\s*=\s*' + [regex]::Escape([string]$Port)))) {
                if (Stop-ProcessTreeTargeted -ProcessId ([int]$p.ProcessId) -Label 'старый watchdog DevSpace') {
                    $stopped++
                }
            }
        }
    } catch {
        Write-Warn "Не удалось проверить старые watchdog-процессы: $($_.Exception.Message)"
    }
    return $stopped
}

function Stop-StaleDevSpaceListener {
    $stopped = 0
    try {
        $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
        foreach ($listener in $listeners) {
            $ownerPid = [int]$listener.OwningProcess
            if ($ownerPid -le 0 -or $ownerPid -eq $PID) { continue }

            $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$ownerPid" -ErrorAction SilentlyContinue
            if (Test-IsDevSpaceServerProcess -CimProcess $cim) {
                if (Stop-ProcessTreeTargeted -ProcessId $ownerPid -Label ("старый DevSpace на порту {0}" -f $Port)) {
                    $stopped++
                }
            } else {
                $name = if ($cim) { [string]$cim.Name } else { 'неизвестный процесс' }
                Write-Warn ("Порт {0} уже занят процессом {1} (PID {2}), но он не похож на DevSpace. Автоматически его не завершаю." -f $Port, $name, $ownerPid)
            }
        }
    } catch {
        Write-Warn "Не удалось выполнить предстартовую проверку порта ${Port}: $($_.Exception.Message)"
    }
    return $stopped
}



function Invoke-StartupProcessCleanup {
    Write-Rule 'ПРЕДСТАРТОВАЯ ПРОВЕРКА ОСТАТОЧНЫХ ПРОЦЕССОВ'

    $total = 0
    $total += Stop-StaleProcessesFromRuntimeState
    $total += Stop-StaleLauncherWatchdogs
    $total += Stop-StaleDevSpaceListener

    Start-Sleep -Milliseconds 500

    try {
        Get-ChildItem -LiteralPath $LogDir -Filter 'devspace-watchdog-*.stop' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}

    if ($total -gt 0) {
        Write-Ok ("Предыдущий запуск очищен. Завершено остаточных процессов: {0}." -f $total)
    } else {
        Write-Ok 'Остаточные процессы предыдущего запуска не найдены.'
    }
}

function Start-Log {
    param([switch]$Append)
    if ($script:TranscriptActive) { return }
    try {
        if ($Append) { Start-Transcript -Path $LogPath -Append -Force | Out-Null }
        else { Start-Transcript -Path $LogPath -Force | Out-Null }
        $script:TranscriptActive = $true
    } catch {
        Write-Host "[WARN] Не удалось включить transcript-лог: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Stop-Log {
    if (-not $script:TranscriptActive) { return }
    try { Stop-Transcript | Out-Null } catch {}
    $script:TranscriptActive = $false
}

function Read-HostWithoutTranscript {
    param([Parameter(Mandatory=$true)][string]$Prompt)

    # Keep input out of Start-Transcript logs when it may contain secrets.
    $resumeTranscript = $script:TranscriptActive
    if ($resumeTranscript) { Stop-Log }
    try {
        return (Read-Host $Prompt)
    } finally {
        if ($resumeTranscript) { Start-Log -Append }
    }
}

function Write-Rule {
    param([string]$Title = '')
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    if ($Title) { Write-Host ("  {0}" -f $Title) -ForegroundColor Cyan }
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

function Write-Step {
    param([string]$Title)
    $script:CurrentStep++
    Write-Host ''
    Write-Host ("[ШАГ {0}] {1}" -f $script:CurrentStep, $Title) -ForegroundColor Cyan
    Write-Host ('-' * 78) -ForegroundColor DarkGray
}

function Write-Ok   { param([string]$Text) Write-Host ("  [OK]   {0}" -f $Text) -ForegroundColor Green }
function Write-Info { param([string]$Text) Write-Host ("  [INFO] {0}" -f $Text) -ForegroundColor Gray }
function Write-Warn { param([string]$Text) Write-Host ("  [WARN] {0}" -f $Text) -ForegroundColor Yellow }


function Write-SavedAccent {
    param([Parameter(Mandatory=$true)][string]$Text)
    if ($script:UseLightPinkAnsi) {
        $esc = [char]27
        # #FF96D2 — deliberately lighter/pinker than the console Magenta palette.
        Write-Host (("{0}[38;2;255;150;210m{1}{0}[0m" -f $esc, $Text))
    } else {
        Write-Host $Text -ForegroundColor Magenta
    }
}

function Write-NoticeBox {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][string[]]$Lines
    )
    $width = 76
    Write-Host ''
    Write-Host ('+' + ('-' * $width) + '+') -ForegroundColor Yellow
    $titleText = (' ' + $Title).PadRight($width)
    if ($titleText.Length -gt $width) { $titleText = $titleText.Substring(0, $width) }
    Write-Host ('|' + $titleText + '|') -ForegroundColor Yellow
    Write-Host ('+' + ('-' * $width) + '+') -ForegroundColor Yellow
    foreach ($line in $Lines) {
        $remaining = [string]$line
        if ($null -eq $remaining) { $remaining = '' }
        do {
            $chunk = if ($remaining.Length -gt $width - 2) { $remaining.Substring(0, $width - 2) } else { $remaining }
            $remaining = if ($remaining.Length -gt $width - 2) { $remaining.Substring($width - 2) } else { '' }
            $content = (' ' + $chunk).PadRight($width)
            Write-Host ('|' + $content + '|') -ForegroundColor Yellow
        } while ($remaining.Length -gt 0)
    }
    Write-Host ('+' + ('-' * $width) + '+') -ForegroundColor Yellow
    Write-Host ''
}

function Write-AccessWarningBox {
    param([string[]]$Roots)
    $width = 76
    Write-Host ''
    Write-Host ('+' + ('-' * $width) + '+') -ForegroundColor Red
    $titleText = (' ВНИМАНИЕ — DEVSPACE И CHATGPT ИМЕЮТ ДОСТУП К ЭТИМ ПАПКАМ').PadRight($width)
    if ($titleText.Length -gt $width) { $titleText = $titleText.Substring(0, $width) }
    Write-Host ('|' + $titleText + '|') -ForegroundColor Red
    Write-Host ('+' + ('-' * $width) + '+') -ForegroundColor Red
    if (-not $Roots -or @($Roots).Count -eq 0) {
        $Roots = @('НЕ НАСТРОЕНО — сервер не должен работать в таком состоянии.')
    }
    foreach ($root in $Roots) {
        $remaining = [string]$root
        do {
            $chunk = if ($remaining.Length -gt $width - 4) { $remaining.Substring(0, $width - 4) } else { $remaining }
            $remaining = if ($remaining.Length -gt $width - 4) { $remaining.Substring($width - 4) } else { '' }
            $content = ('   ' + $chunk).PadRight($width)
            Write-Host ('|' + $content + '|') -ForegroundColor Red
        } while ($remaining.Length -gt 0)
    }
    Write-Host ('+' + ('-' * $width) + '+') -ForegroundColor Red
    $warning = ' ВАЖНО: ChatGPT сможет выполнять любые консольные команды. Будьте осторожны.'
    if ($warning.Length -gt $width) { $warning = $warning.Substring(0, $width) }
    Write-Host ('|' + $warning.PadRight($width) + '|') -ForegroundColor Yellow
    Write-Host ('+' + ('-' * $width) + '+') -ForegroundColor Red
    Write-Host ''
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Refresh-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($p in (($machine + ';' + $user) -split ';')) {
        if ($p -and -not $parts.Contains($p)) { [void]$parts.Add($p) }
    }
    $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if ((Test-Path $windowsApps) -and -not $parts.Contains($windowsApps)) { [void]$parts.Add($windowsApps) }
    $npmBin = Join-Path $env:APPDATA 'npm'
    if ((Test-Path $npmBin) -and -not $parts.Contains($npmBin)) { [void]$parts.Add($npmBin) }
    $env:Path = ($parts -join ';')
}

function ConvertTo-Version {
    param([string]$Text)
    if ($Text -match '(?<v>\d+\.\d+\.\d+)') {
        try { return [Version]$Matches['v'] } catch {}
    }
    return $null
}

function Invoke-Native {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure,
        [switch]$Quiet,
        [string]$FriendlyName = ''
    )

    # Windows PowerShell 5.1 converts stderr from native programs into PowerShell
    # ErrorRecord objects. With the script-wide ErrorActionPreference='Stop', even
    # harmless output such as `npm warn ...` can become a terminating exception
    # before the native process exits. Native success/failure must instead be
    # determined from the program's real process exit code ($LASTEXITCODE).
    $lines = New-Object System.Collections.Generic.List[string]
    $oldErrorActionPreference = $ErrorActionPreference
    $code = 1
    try {
        $ErrorActionPreference = 'Continue'
        $LASTEXITCODE = 0
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                if ($_.Exception -and -not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
                    $s = $_.Exception.Message
                } else {
                    $s = $_.ToString()
                }
            } else {
                $s = $_.ToString()
            }
            [void]$lines.Add($s)
            if (-not $Quiet) { Write-Host $s }
        }
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } catch {
        # A genuine PowerShell launch/runtime failure (for example, executable
        # not found) still lands here. Native stderr no longer does.
        $s = $_.Exception.ToString()
        [void]$lines.Add($s)
        if (-not $Quiet) { Write-Host $s -ForegroundColor Red }
        $code = 1
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    $output = ($lines -join [Environment]::NewLine)
    if (($code -ne 0) -and (-not $AllowFailure)) {
        $name = if ($FriendlyName) { $FriendlyName } else { $FilePath }
        throw ("Команда '{0}' завершилась с кодом {1}. Полный вывод показан выше.`n{2}" -f $name, $code, $output)
    }
    return [pscustomobject]@{ ExitCode = [int]$code; Output = $output }
}

function ConvertTo-CommandLineArgument {
    param([AllowEmptyString()][string]$Argument)
    if ($null -eq $Argument) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    # Windows CommandLineToArgvW-compatible quoting.
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq '\') {
            $slashes++
            continue
        }
        if ($ch -eq '"') {
            [void]$sb.Append(('\' * ($slashes * 2 + 1)))
            [void]$sb.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$sb.Append(('\' * $slashes)); $slashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($slashes -gt 0) { [void]$sb.Append(('\' * ($slashes * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Reset-ConsoleLayout {
    # Native installers (especially WinGet/MS Store) redraw one console line with CR/VT sequences.
    # If such a process is force-killed, it can leave the cursor/color state half-updated.
    # Always restore a clean line before our own output continues.
    try { [Console]::ResetColor() } catch {}
    try {
        $esc = [char]27
        [Console]::Write(("{0}[0m{0}[2K`r`n" -f $esc))
    } catch {
        try { Write-Host '' } catch {}
    }
    try {
        $pos = $Host.UI.RawUI.CursorPosition
        if ($pos.X -ne 0) {
            $pos.X = 0
            $Host.UI.RawUI.CursorPosition = $pos
        }
    } catch {}
}

function Invoke-NativeConsole {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure,
        [string]$FriendlyName = '',
        [int]$TimeoutSeconds = 0,
        [string]$FailureLogPath = ''
    )

    $name = if ($FriendlyName) { $FriendlyName } else { $FilePath }
    $argLine = (($Arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' ')
    Reset-ConsoleLayout
    Write-Host ''
    Write-Host ('  [СИСТЕМНЫЙ ВЫВОД] {0}' -f $name) -ForegroundColor DarkGray
    Write-Host ('  > {0} {1}' -f $FilePath, $argLine) -ForegroundColor DarkGray
    Write-Host ('  ' + ('·' * 74)) -ForegroundColor DarkGray

    $oldColor = $null
    try { $oldColor = $Host.UI.RawUI.ForegroundColor; $Host.UI.RawUI.ForegroundColor = 'DarkGray' } catch {}
    $timedOut = $false
    $code = 1
    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $argLine -NoNewWindow -PassThru -ErrorAction Stop
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $nextHeartbeat = 20
        while (-not $p.HasExited) {
            Start-Sleep -Milliseconds 500
            try { $p.Refresh() } catch {}
            if ($p.HasExited) { break }
            if ($sw.Elapsed.TotalSeconds -ge $nextHeartbeat) {
                # Put every heartbeat on its own fresh line. Do not try to animate/overwrite it.
                Reset-ConsoleLayout
                $elapsed = [int]$sw.Elapsed.TotalSeconds
                Write-Host ("  [ожидание] Процесс всё ещё работает — {0} сек." -f $elapsed) -ForegroundColor DarkGray
                $nextHeartbeat += 20
            }
            if ($TimeoutSeconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                break
            }
        }
        if ($timedOut) {
            try { & taskkill.exe /PID $p.Id /T /F *> $null } catch { try { $p.Kill() } catch {} }
            try { $p.WaitForExit(3000) | Out-Null } catch {}
            $code = 1460
        } else {
            try { $p.WaitForExit() } catch {}
            $code = [int]$p.ExitCode
        }
    } catch {
        $code = 1
        try { if ($oldColor) { $Host.UI.RawUI.ForegroundColor = $oldColor } } catch {}
        Reset-ConsoleLayout
        Write-Host $_.Exception.ToString() -ForegroundColor Red
    } finally {
        try { if ($oldColor) { $Host.UI.RawUI.ForegroundColor = $oldColor } } catch {}
        Reset-ConsoleLayout
    }

    Write-Host ('  ' + ('·' * 74)) -ForegroundColor DarkGray
    if ($timedOut) {
        Write-Host ("  [TIMEOUT] {0} не завершился за {1} сек.; процесс остановлен." -f $name, $TimeoutSeconds) -ForegroundColor Yellow
    } elseif ($code -eq 0) {
        Write-Host ("  [SYSTEM OK] {0}" -f $name) -ForegroundColor DarkGray
    } else {
        Write-Host ("  [SYSTEM ERROR] {0}; код выхода: {1}" -f $name, $code) -ForegroundColor Red
    }

    if (($code -ne 0) -and $FailureLogPath -and (Test-Path -LiteralPath $FailureLogPath)) {
        Write-Host ''
        Write-Host ('  Полный диагностический лог команды: {0}' -f $FailureLogPath) -ForegroundColor Red
        Write-Host ('  ' + ('-' * 74)) -ForegroundColor DarkRed
        try {
            Get-Content -LiteralPath $FailureLogPath -Raw -ErrorAction Stop | Write-Host -ForegroundColor Red
        } catch {
            Write-Host ("Не удалось прочитать лог: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
        Write-Host ('  ' + ('-' * 74)) -ForegroundColor DarkRed
    }

    if (($code -ne 0) -and (-not $AllowFailure)) {
        if ($timedOut) { throw "Команда '$name' зависла/превысила лимит ожидания $TimeoutSeconds сек." }
        throw "Команда '$name' завершилась с кодом $code. Полный системный вывод был показан выше; диагностический лог WinGet показан при наличии."
    }
    return [pscustomobject]@{ ExitCode=[int]$code; TimedOut=$timedOut; LogPath=$FailureLogPath }
}

function Get-CommandPath {
    param([string]$Name, [string[]]$Candidates = @())
    try {
        $cmd = Get-Command $Name -ErrorAction Stop | Select-Object -First 1
        if ($cmd -and $cmd.Source) { return $cmd.Source }
        if ($cmd -and $cmd.Path) { return $cmd.Path }
    } catch {}
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Test-Winget {
    Refresh-ProcessPath
    $candidates = New-Object System.Collections.Generic.List[string]
    try {
        Get-Command winget.exe -All -ErrorAction Stop | ForEach-Object {
            $p = if ($_.Source) { $_.Source } else { $_.Path }
            if ($p -and -not $candidates.Contains($p)) { [void]$candidates.Add($p) }
        }
    } catch {}
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if ((Test-Path -LiteralPath $alias) -and -not $candidates.Contains($alias)) { [void]$candidates.Add($alias) }
    try {
        Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Join-Path $_.InstallLocation 'winget.exe'
            if ((Test-Path -LiteralPath $p) -and -not $candidates.Contains($p)) { [void]$candidates.Add($p) }
        }
    } catch {}
    if (Test-IsAdministrator) {
        try {
            Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue | ForEach-Object {
                $p = Join-Path $_.InstallLocation 'winget.exe'
                if ((Test-Path -LiteralPath $p) -and -not $candidates.Contains($p)) { [void]$candidates.Add($p) }
            }
        } catch {}
    }
    foreach ($path in $candidates) {
        $r = Invoke-Native -FilePath $path -Arguments @('--version') -AllowFailure -Quiet
        if ($r.ExitCode -eq 0 -and $r.Output -match '\d') {
            return [pscustomobject]@{ Path=$path; Version=$r.Output.Trim() }
        }
    }
    return $null
}

function Relaunch-Elevated {
    Write-Warn 'Для восстановления WinGet нужны права администратора. Сейчас появится запрос UAC.'
    Stop-Log
    $comspec = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
    $arg = '/d /c ""{0}""' -f $ScriptPath
    try {
        $p = Start-Process -FilePath $comspec -ArgumentList $arg -Verb RunAs -Wait -PassThru
        exit $p.ExitCode
    } catch {
        throw "Не удалось перезапустить установщик от имени администратора: $($_.Exception.Message)"
    }
}

function Repair-Winget {
    Write-Warn 'WinGet отсутствует или не запускается. Запускаю цепочку восстановления.'
    if (-not (Test-IsAdministrator)) { Relaunch-Elevated }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Info 'Попытка 1/3: перерегистрация Microsoft Desktop App Installer.'
    try {
        $packages = Get-AppxPackage -AllUsers '*DesktopAppInstaller*' -ErrorAction Stop
        foreach ($pkg in $packages) {
            $manifest = Join-Path $pkg.InstallLocation 'AppXManifest.xml'
            if (Test-Path $manifest) {
                Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
            }
        }
    } catch {
        Write-Warn ("Перерегистрация не помогла/недоступна: {0}" -f $_.Exception.Message)
    }
    Refresh-ProcessPath
    $w = Test-Winget
    if ($w) { return $w }

    Write-Info 'Попытка 2/3: сброс Microsoft.DesktopAppInstaller.'
    try {
        $reset = Get-Command Reset-AppxPackage -ErrorAction SilentlyContinue
        if ($reset) {
            Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop | Reset-AppxPackage -ErrorAction Stop
        } else {
            Write-Warn 'Команда Reset-AppxPackage недоступна в этой версии Windows.'
        }
    } catch {
        Write-Warn ("Сброс пакета не помог: {0}" -f $_.Exception.Message)
    }
    Refresh-ProcessPath
    $w = Test-Winget
    if ($w) { return $w }

    Write-Info 'Попытка 3/3: Microsoft.WinGet.Client + Repair-WinGetPackageManager.'
    $repoWasTrusted = $false
    try {
        try {
            $repo = Get-PSRepository -Name PSGallery -ErrorAction Stop
            $repoWasTrusted = ($repo.InstallationPolicy -eq 'Trusted')
            if (-not $repoWasTrusted) { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop }
        } catch {}

        try {
            Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' -Force -Scope AllUsers -ErrorAction SilentlyContinue | Out-Null
        } catch {}

        Install-Module -Name Microsoft.WinGet.Client -Force -AllowClobber -Repository PSGallery -Scope AllUsers -ErrorAction Stop
        Import-Module Microsoft.WinGet.Client -Force -ErrorAction Stop
        if (-not (Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue)) {
            throw 'Модуль Microsoft.WinGet.Client установлен, но Repair-WinGetPackageManager не найден.'
        }
        Repair-WinGetPackageManager -Force -Latest -AllUsers -ErrorAction Stop
    } finally {
        if (-not $repoWasTrusted) {
            try { Set-PSRepository -Name PSGallery -InstallationPolicy Untrusted -ErrorAction SilentlyContinue } catch {}
        }
    }

    Refresh-ProcessPath
    $w = Test-Winget
    if (-not $w) {
        throw 'Восстановление WinGet завершилось, но winget.exe всё ещё не запускается. Проверьте журнал выше.'
    }
    return $w
}

function Ensure-Winget {
    Write-Step 'WinGet: проверка и восстановление при необходимости'
    $w = Test-Winget
    if (-not $w) { $w = Repair-Winget }
    Write-Ok ("WinGet работает: {0}" -f $w.Version)
    $sourceResult = Invoke-Native -FilePath $w.Path -Arguments @('source','update','--disable-interactivity') -AllowFailure -Quiet
    if ($sourceResult.ExitCode -ne 0) {
        Write-Warn 'Не удалось обновить источники WinGet. Установка пакетов всё равно будет попробована.'
        Write-Host $sourceResult.Output -ForegroundColor DarkYellow
    }
    return $w.Path
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory=$true)][string]$Winget,
        [Parameter(Mandatory=$true)][string]$IdOrName,
        [string]$Source = 'winget',
        [switch]$Exact,
        [int]$TimeoutSeconds = 1200,
        [switch]$AllowFailure
    )
    $args = New-Object System.Collections.Generic.List[string]
    [void]$args.Add('install')
    if ($Exact) { [void]$args.Add('--id') } else { [void]$args.Add('--name') }
    [void]$args.Add($IdOrName)
    if ($Exact) { [void]$args.Add('-e') }
    if ($Source) { [void]$args.Add('-s'); [void]$args.Add($Source) }
    [void]$args.Add('--accept-package-agreements')
    [void]$args.Add('--accept-source-agreements')
    [void]$args.Add('--disable-interactivity')

    $safeName = ($IdOrName -replace '[^A-Za-z0-9._-]', '_')
    $wingetLog = Join-Path $WingetLogDir ("install-{0}-{1}.log" -f $safeName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [void]$args.Add('--log')
    [void]$args.Add($wingetLog)
    [void]$args.Add('--verbose-logs')

    Write-Info "Запускаю установку пакета '$IdOrName'. Ниже показывается реальный вывод WinGet; он не скрывается."
    $r = Invoke-NativeConsole -FilePath $Winget -Arguments $args.ToArray() -FriendlyName "winget install $IdOrName" -TimeoutSeconds $TimeoutSeconds -FailureLogPath $wingetLog -AllowFailure:$AllowFailure
    Refresh-ProcessPath
    if ($AllowFailure) { return $r }
}

function Find-GitBash {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:ProgramFiles) { [void]$candidates.Add((Join-Path $env:ProgramFiles 'Git\bin\bash.exe')) }
    if (${env:ProgramFiles(x86)}) { [void]$candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe')) }
    if ($env:LOCALAPPDATA) { [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')) }
    try {
        $git = Get-Command git.exe -ErrorAction Stop | Select-Object -First 1
        if ($git.Source) {
            $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
            [void]$candidates.Add((Join-Path $gitRoot 'bin\bash.exe'))
        }
    } catch {}
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return (Resolve-Path -LiteralPath $p).Path }
    }
    return $null
}

function Find-GitMintty {
    param([string]$BashPath)
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($BashPath) {
        try {
            $gitRoot = Split-Path -Parent (Split-Path -Parent $BashPath)
            [void]$candidates.Add((Join-Path $gitRoot 'usr\bin\mintty.exe'))
        } catch {}
    }
    if ($env:ProgramFiles) { [void]$candidates.Add((Join-Path $env:ProgramFiles 'Git\usr\bin\mintty.exe')) }
    if (${env:ProgramFiles(x86)}) { [void]$candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Git\usr\bin\mintty.exe')) }
    if ($env:LOCALAPPDATA) { [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git\usr\bin\mintty.exe')) }
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return (Resolve-Path -LiteralPath $p).Path }
    }
    return $null
}

function Ensure-Git {
    param([string]$Winget)
    Write-Step 'Git for Windows + Git Bash'
    Refresh-ProcessPath
    $git = Get-CommandPath -Name 'git.exe'
    $bash = Find-GitBash
    if (-not $git -or -not $bash) {
        Write-Info 'Git или именно Git Bash не найдены. Устанавливаю Git for Windows.'
        Install-WingetPackage -Winget $Winget -IdOrName 'Git.Git' -Source 'winget' -Exact
        $git = Get-CommandPath -Name 'git.exe'
        $bash = Find-GitBash
    }
    if (-not $git) { throw 'После установки git.exe не найден в PATH.' }
    if (-not $bash) { throw 'Git установлен, но Git Bash (bash.exe) не найден.' }
    $gv = Invoke-Native -FilePath $git -Arguments @('--version') -Quiet
    $bv = Invoke-Native -FilePath $bash -Arguments @('--version') -Quiet
    Write-Ok $gv.Output.Trim()
    Write-Ok ("Git Bash: {0}" -f (($bv.Output -split "`r?`n")[0]))
    $script:GitBash = $bash
    $script:GitMintty = Find-GitMintty -BashPath $bash
    if ($script:GitMintty) {
        Write-Ok ("Git Bash TTY (mintty): {0}" -f $script:GitMintty)
    } else {
        Write-Warn 'mintty.exe не найден. Штатный мастер DevSpace может не получить полноценный TTY.'
    }
}

function Get-NodeInfo {
    Refresh-ProcessPath
    $node = Get-CommandPath -Name 'node.exe'
    if (-not $node) { return $null }
    $vr = Invoke-Native -FilePath $node -Arguments @('--version') -AllowFailure -Quiet
    if ($vr.ExitCode -ne 0) { return $null }
    $v = ConvertTo-Version $vr.Output
    if (-not $v) { return $null }
    # Avoid nested quote parsing through Windows PowerShell/native invocation.
    # `process.release.lts` prints the LTS codename on LTS releases and
    # `undefined` on non-LTS releases.
    $ltsr = Invoke-Native -FilePath $node -Arguments @('-p', 'process.release.lts') -AllowFailure -Quiet
    $lts = if ($ltsr.ExitCode -eq 0) { $ltsr.Output.Trim() } else { '' }
    if ($lts -match '^(?i:undefined|null|false)$') { $lts = '' }
    return [pscustomobject]@{ Path=$node; Version=$v; Raw=$vr.Output.Trim(); Lts=$lts }
}

function Ensure-Node {
    param([string]$Winget)
    Write-Step 'Node.js LTS + npm + npx'
    $node = Get-NodeInfo
    $compatible = $false
    if ($node) {
        $compatible = ($node.Version -ge $MinNode -and $node.Version -lt $MaxNode -and -not [string]::IsNullOrWhiteSpace($node.Lts))
        Write-Info ("Найден Node {0}; LTS: {1}; путь: {2}" -f $node.Raw, $(if($node.Lts){$node.Lts}else{'нет'}), $node.Path)
    }
    if (-not $compatible) {
        Write-Info ("Нужен LTS в диапазоне >= {0} и < {1}. Устанавливаю OpenJS.NodeJS.LTS." -f $MinNode, $MaxNode)
        Install-WingetPackage -Winget $Winget -IdOrName 'OpenJS.NodeJS.LTS' -Source 'winget' -Exact
        $node = Get-NodeInfo
    }
    if (-not $node) { throw 'Node.js не найден после установки.' }
    if ($node.Version -lt $MinNode -or $node.Version -ge $MaxNode) {
        $all = (& where.exe node.exe 2>$null) -join '; '
        throw "Активный Node $($node.Raw) несовместим с DevSpace. Найденные node.exe: $all"
    }
    if ([string]::IsNullOrWhiteSpace($node.Lts)) {
        throw "Активный Node $($node.Raw) не является LTS. Проверьте конфликтующие установки/PATH."
    }
    $npm = Get-CommandPath -Name 'npm.cmd'
    if (-not $npm) { $npm = Get-CommandPath -Name 'npm.exe' }
    $npx = Get-CommandPath -Name 'npx.cmd'
    if (-not $npx) { $npx = Get-CommandPath -Name 'npx.exe' }
    if (-not $npm -or -not $npx) { throw 'Node.js есть, но npm/npx не найдены.' }
    $npmv = Invoke-Native -FilePath $npm -Arguments @('--version') -Quiet
    Write-Ok ("Node {0} ({1} LTS), npm {2}" -f $node.Version, $node.Lts, $npmv.Output.Trim())
    return [pscustomobject]@{ Node=$node.Path; Npm=$npm; Npx=$npx; Version=$node.Version; Lts=$node.Lts }
}



















































function Get-TunnelClientPath {
    $list = New-Object System.Collections.Generic.List[string]
    $found = Get-Command tunnel-client.exe -ErrorAction SilentlyContinue
    if ($found) { $list.Add([string]$found.Source) }
    # Reuse the same tunnel-client binary as Start-Agent-Infrastructure.ps1 when present.
    $list.Add((Join-Path $HOME 'Tools\mcp\tunnel-client-dist\tunnel-client.exe'))
    $list.Add((Join-Path $HOME 'Tools\mcp\tunnel-client.exe'))
    $list.Add((Join-Path $env:LOCALAPPDATA 'Programs\tunnel-client\tunnel-client.exe'))
    $list.Add((Join-Path $env:LOCALAPPDATA 'tunnel-client\tunnel-client.exe'))
    foreach ($path in $list) {
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and ($path -notmatch '^(?i:https?://)')) {
            $verified = Test-TunnelClientBinary -Path $path
            if ($verified.Compatible) { return $path }
        }
    }
    return $null
}

function Test-TunnelClientBinary {
    param([Parameter(Mandatory=$true)][string]$Path)
    $r = Invoke-Native -FilePath $Path -Arguments @('--version') -AllowFailure -Quiet
    if ($r.ExitCode -ne 0) { return [pscustomobject]@{ Compatible=$false; Version=''; Reason='Команда --version не работает.' } }
    $v = ConvertTo-Version -Text $r.Output
    if (-not $v) { return [pscustomobject]@{ Compatible=$false; Version=''; Reason='Версия не распознана.' } }
    if ($v -lt $MinTunnelClient) {
        return [pscustomobject]@{ Compatible=$false; Version=$v; Reason=("Нужна версия не ниже {0}." -f $MinTunnelClient) }
    }
    foreach ($check in @(
        [pscustomobject]@{ Args=@('run','--help'); Flags=@('--control-plane.tunnel-id','--mcp.server-url','--health.listen-addr') },
        [pscustomobject]@{ Args=@('admin','tunnels','list','--help'); Flags=@('--organization-id','--workspace-id') },
        [pscustomobject]@{ Args=@('admin','tunnels','create','--help'); Flags=@('--organization-id','--workspace-id') },
        [pscustomobject]@{ Args=@('runtimes','status','--help'); Flags=@() }
    )) {
        $helpResult = Invoke-Native -FilePath $Path -Arguments $check.Args -AllowFailure -Quiet
        if ($helpResult.ExitCode -ne 0) {
            return [pscustomobject]@{ Compatible=$false; Version=$v; Reason=("Недоступна команда {0}." -f ($check.Args -join ' ')) }
        }
        foreach ($flag in $check.Flags) {
            if (-not $helpResult.Output.Contains($flag)) {
                return [pscustomobject]@{ Compatible=$false; Version=$v; Reason=("Не поддерживается {0}." -f $flag) }
            }
        }
    }
    return [pscustomobject]@{ Compatible=$true; Version=$v; Reason='' }
}

function Get-TunnelReleaseMetadata {
    param([string]$Arch)
    $headers = @{ 'User-Agent'='DevSpace-Secure-Tunnel-Launcher'; 'Accept'='application/vnd.github+json' }
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/openai/tunnel-client/releases/latest' -Headers $headers -TimeoutSec 25
        if ($release.tag_name -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Неподдерживаемый тег релиза.' }
        return $release
    } catch {
        Write-Warn ("GitHub API недоступен: {0}. Проверяю страницу релиза." -f $_.Exception.Message)
    }
    try {
        $response = Invoke-WebRequest -Uri 'https://github.com/openai/tunnel-client/releases/latest' -UseBasicParsing -TimeoutSec 25 -MaximumRedirection 10
        $url = [string]$response.BaseResponse.ResponseUri.AbsoluteUri
        if ($url -notmatch '/releases/tag/(v[0-9]+\.[0-9]+\.[0-9]+)(?:[/?#]|$)') {
            throw 'Не удалось определить тег последнего релиза.'
        }
        $tag = $Matches[1]
        $filename = 'tunnel-client-{0}-windows-{1}.zip' -f $tag,$Arch
        $base = 'https://github.com/openai/tunnel-client/releases/download/' + $tag + '/'
        Write-Info ("Версия {0} получена через страницу релизов." -f $tag)
        return [pscustomobject]@{ tag_name=$tag; assets=@(
            [pscustomobject]@{ name=$filename; browser_download_url=($base+$filename); digest='' },
            [pscustomobject]@{ name='SHA256SUMS.txt'; browser_download_url=($base+'SHA256SUMS.txt') }
        ) }
    } catch {
        Write-Warn ("Страница релиза недоступна: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-LocalTunnelArchive {
    param([string]$Arch)
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($folder in @($ScriptDir,(Join-Path $ScriptDir 'tunnel-client-cache'))) {
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        $sums = Join-Path $folder 'SHA256SUMS.txt'
        if (-not (Test-Path -LiteralPath $sums -PathType Leaf)) { continue }
        foreach ($archive in @(Get-ChildItem -LiteralPath $folder -Filter ("tunnel-client-v*-windows-{0}.zip" -f $Arch) -File -ErrorAction SilentlyContinue)) {
            if ($archive.Name -notmatch '^tunnel-client-v([0-9]+\.[0-9]+\.[0-9]+)-windows-(amd64|arm64)\.zip$') { continue }
            $v = [Version]$Matches[1]
            if ($v -lt $MinTunnelClient) { continue }
            $found.Add([pscustomobject]@{ Zip=$archive.FullName; Sums=$sums; FileName=$archive.Name; Version=$v })
        }
    }
    return @($found | Sort-Object Version -Descending | Select-Object -First 1)
}

function Get-TunnelArchiveHash {
    param([string]$FileName,[string]$SumsPath)
    $body = [IO.File]::ReadAllText($SumsPath,[Text.Encoding]::UTF8)
    $pattern = '(?m)^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($FileName) + '\s*$'
    $match = [regex]::Match($body,$pattern)
    if (-not $match.Success) { throw ("SHA256SUMS.txt не содержит {0}." -f $FileName) }
    return $match.Groups[1].Value
}

function Ensure-TunnelClient {
    Write-Step 'Secure MCP Tunnel: проверка tunnel-client'
    $existing = Get-TunnelClientPath
    if ($existing) {
        $check = Test-TunnelClientBinary -Path $existing
        if ($check.Compatible) {
            $script:TunnelExe = $existing
            Write-Ok ("tunnel-client {0}: {1}" -f $check.Version, $existing)
            return
        }
        Write-Warn ("Найденный tunnel-client несовместим: {0}. Установлю официальный релиз." -f $check.Reason)
    }
    [Net.ServicePointManager]::SecurityProtocol = (
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    )
    Write-Info 'Загружаю последнюю версию с github.com/openai/tunnel-client.'
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { throw 'Нужна 64-битная Windows.' }
    if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -match 'ARM64') { $arch = 'arm64' }
    $headers = @{ 'User-Agent'='DevSpace-Secure-Tunnel-Launcher'; 'Accept'='application/vnd.github+json' }
    $release = Get-TunnelReleaseMetadata -Arch $arch
    $asset = if ($release) { @($release.assets | Where-Object { $_.name -match ("^tunnel-client-v[0-9.]+-windows-{0}\.zip$" -f $arch) }) | Select-Object -First 1 } else { $null }
    if (-not $asset) { Write-Warn 'Релиз для нужной архитектуры не найден; проверяю локальные архивы.' }
    $folder = Join-Path $env:LOCALAPPDATA 'Programs\tunnel-client'
    $temp = Join-Path $env:TEMP ('devspace-tunnel-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        $zip = Join-Path $temp 'client.zip'
        $expected = ''
        $loaded = $false
        if ($asset) {
            try {
                Write-Info ("Загружаю официальный tunnel-client: {0}" -f $asset.name)
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -Headers $headers -TimeoutSec 180
                if ($asset.digest -and ([string]$asset.digest -match '^sha256:([0-9a-fA-F]{64})$')) {
                    $expected = $Matches[1]
                } else {
                    $sums = @($release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' }) | Select-Object -First 1
                    if (-not $sums) { throw 'В релизе отсутствует SHA256SUMS.txt.' }
                    $sumFile = Join-Path $temp 'SHA256SUMS.txt'
                    Invoke-WebRequest -Uri $sums.browser_download_url -OutFile $sumFile -UseBasicParsing -Headers $headers -TimeoutSec 45
                    $expected = Get-TunnelArchiveHash -FileName $asset.name -SumsPath $sumFile
                }
                $loaded = $true
            } catch {
                Write-Warn ("Автоматическая загрузка не удалась: {0}" -f $_.Exception.Message)
                Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $loaded) {
            $offline = @(Get-LocalTunnelArchive -Arch $arch)
            if ($offline.Count -eq 0) {
                throw (
                    'Не удалось скачать tunnel-client. Скачайте Windows ZIP и SHA256SUMS.txt одного релиза с ' +
                    'https://github.com/openai/tunnel-client/releases/latest или ' +
                    'https://platform.openai.com/settings/organization/tunnels. ' +
                    'Положите оба файла рядом с CMD либо в папку tunnel-client-cache и повторите запуск.'
                )
            }
            $selected = $offline[0]
            Copy-Item -LiteralPath $selected.Zip -Destination $zip -Force
            $expected = Get-TunnelArchiveHash -FileName $selected.FileName -SumsPath $selected.Sums
            Write-Info ("Используется проверенный локальный архив: {0}" -f $selected.FileName)
        }
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($actual -ine $expected) { throw 'SHA256 архива tunnel-client не совпадает! Установка остановлена.' }
        $extract = Join-Path $temp 'unpacked'
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $exe = Get-ChildItem -LiteralPath $extract -Filter 'tunnel-client.exe' -File -Recurse | Select-Object -First 1
        if (-not $exe) { throw 'В официальном ZIP не найден tunnel-client.exe.' }
        $archiveBinary = Test-TunnelClientBinary -Path $exe.FullName
        if (-not $archiveBinary.Compatible) { throw ("В архиве несовместимый tunnel-client: {0}" -f $archiveBinary.Reason) }
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $dest = Join-Path $folder 'tunnel-client.exe'
        Copy-Item -LiteralPath $exe.FullName -Destination $dest -Force
        Unblock-File -LiteralPath $dest -ErrorAction SilentlyContinue
        $installed = Test-TunnelClientBinary -Path $dest
        if (-not $installed.Compatible) { throw ("Установленный tunnel-client несовместим: {0}" -f $installed.Reason) }
        $script:TunnelExe = $dest
        Write-Ok ("Официальный tunnel-client {0} установлен; SHA256 проверен." -f $installed.Version)
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-RuntimeKeyFromFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Файл с ключом не найден: $full" }
    $raw = [IO.File]::ReadAllText($full).Trim()
    if ($raw.StartsWith('{')) {
        $j = $raw | ConvertFrom-Json
        foreach ($name in @('CONTROL_PLANE_API_KEY','control_plane_api_key','runtime_api_key','api_key')) {
            $prop = $j.PSObject.Properties[$name]
            if ($prop -and $prop.Value) { return [string]$prop.Value }
        }
        throw 'JSON не содержит CONTROL_PLANE_API_KEY или runtime_api_key.'
    }
    $match = [regex]::Match($raw, '(?im)^\s*(?:export\s+|set\s+)?CONTROL_PLANE_API_KEY\s*=\s*["'']?(?<key>[^\r\n"'']+)["'']?\s*$')
    if ($match.Success) { return $match.Groups['key'].Value.Trim() }
    if ($raw -match '[\r\n]') { throw 'Не найден CONTROL_PLANE_API_KEY=... в многострочном файле.' }
    return $raw.Trim([char]34, [char]39)
}

# Persistent DevSpace credentials and tunnel registration data are held only in
# the .env next to this CMD. Do not read/write the Windows User or Machine
# environment. tunnel-client still needs a temporary child process environment.
function Get-DotEnvValue {
    param([Parameter(Mandatory=$true)][string]$Name)
    if (-not (Test-Path -LiteralPath $DotEnvPath -PathType Leaf)) { return '' }
    $matcher = '^\s*(?:export\s+)?' + [regex]::Escape($Name) + '\s*=(.*)$'
    $result = ''
    foreach ($line in [IO.File]::ReadAllLines($DotEnvPath, [Text.Encoding]::UTF8)) {
        $match = [regex]::Match($line, $matcher)
        if (-not $match.Success) { continue }
        $value = $match.Groups[1].Value.Trim()
        if ($value.Length -ge 2 -and (
            ($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length-2)
        }
        $result = $value
    }
    return $result
}

function Save-DotEnvValue {
    param([Parameter(Mandatory=$true)][string]$Name,
          [Parameter(Mandatory=$true)][string]$Value)
    if ($Name -notmatch '^[A-Z][A-Z0-9_]*$') { throw 'Некорректное имя параметра .env.' }
    if ($Value -match '[\r\n]') { throw 'Значения .env не могут содержать перевод строки.' }
    if ($Value -match '\s' -or $Value -match '["'']') { throw 'Значение .env содержит недопустимый символ.' }
    # Keep other lines/comments in an existing .env (including unrelated keys).
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $DotEnvPath -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($DotEnvPath, [Text.Encoding]::UTF8)) {
            $lines.Add($line)
        }
    } else {
        $lines.Add('# DevSpace Secure MCP Tunnel — local configuration; DO NOT COMMIT')
        $lines.Add('# API keys are stored as plaintext. Keep this .env private.')
    }
    $matcher = '^\s*(?:export\s+)?' + [regex]::Escape($Name) + '\s*='
    $output = New-Object System.Collections.Generic.List[string]
    $written = $false
    foreach ($line in $lines) {
        if ([regex]::IsMatch($line, $matcher)) {
            if (-not $written) { $output.Add($Name + '=' + $Value); $written = $true }
        } else { $output.Add($line) }
    }
    if (-not $written) { $output.Add($Name + '=' + $Value) }
    $tempFile = Join-Path $ScriptDir ('.env.tmp.' + [guid]::NewGuid().ToString('N'))
    $backupFile = Join-Path $ScriptDir ('.env.bak.' + [guid]::NewGuid().ToString('N'))
    $replacedExisting = $false
    try {
        [IO.File]::WriteAllText($tempFile, (($output.ToArray() -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $DotEnvPath -PathType Leaf) {
            # On Windows PowerShell / .NET Framework, a null backup path may
            # produce 'The path is not of a legal form.' Use a real backup path.
            # Replace is atomic on NTFS and preserves the destination ACL.
            [IO.File]::Replace($tempFile, $DotEnvPath, $backupFile)
            $replacedExisting = $true
        } else {
            [IO.File]::Move($tempFile, $DotEnvPath)
            # Best effort: give the current user exclusive ACL on a new secret file.
            try {
                $acl = Get-Acl -LiteralPath $DotEnvPath
                $acl.SetAccessRuleProtection($true,$false)
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)
                [void]$acl.AddAccessRule($rule)
                Set-Acl -LiteralPath $DotEnvPath -AclObject $acl -ErrorAction Stop
            } catch {
                Write-Warn 'Не удалось ограничить права на .env автоматически; проверьте права доступа к файлу.'
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        # Delete the backup only after a successful atomic replacement.
        if ($replacedExisting -and (Test-Path -LiteralPath $backupFile)) {
            Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Ok ('Сохранён {0} в {1}.' -f $Name, $DotEnvPath)
}

function Read-VisibleKey {
    param([Parameter(Mandatory=$true)][string]$Prompt)
    # Echo typed/pasted keys in the console, as requested. Temporarily suspend
    # Start-Transcript so the plaintext secret is NOT copied to launcher logs.
    return (Read-HostWithoutTranscript -Prompt $Prompt)
}

function Get-KeyFingerprint {
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Key)
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
    } finally { $sha.Dispose() }
}

function Format-MaskedApiKey {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '(не задан)' }
    $valueText = $Value.Trim()
    # Show only the first 17 and last 8 characters of a saved key.
    if ($valueText.Length -ge 30) {
        return ($valueText.Substring(0,17) + '***' + $valueText.Substring($valueText.Length-8))
    }
    if ($valueText.Length -ge 12) {
        return ($valueText.Substring(0,5) + '***' + $valueText.Substring($valueText.Length-4))
    }
    if ($valueText.Length -ge 5) {
        return ($valueText.Substring(0,2) + '***' + $valueText.Substring($valueText.Length-2))
    }
    return '***'
}

function Show-RuntimeKeyHelp {
    Write-NoticeBox -Title 'ПОДСКАЗКА — КЛЮЧ ДЛЯ РАБОТЫ ТУННЕЛЕЙ' -Lines @(
        'CONTROL_PLANE_API_KEY — Runtime API key для tunnel-client.',
        'Где получить: https://platform.openai.com/settings/organization/api-keys',
        'Выберите Restricted и разрешения Tunnels Read + Use.',
        'Для создания туннеля требуется отдельный Admin API key.',
        'Ключ хранится в .env рядом с CMD, НЕ в переменных Windows.'
    )
}

function Show-AdminKeyHelp {
    Write-NoticeBox -Title 'ПОДСКАЗКА — КЛЮЧ ДЛЯ СОЗДАНИЯ ТУННЕЛЕЙ' -Lines @(
        'OPENAI_ADMIN_KEY — отдельный Admin API key для регистрации.',
        'Где получить: https://platform.openai.com/settings/organization/admin-keys',
        'Для создания туннеля нужны права Tunnels Read + Manage.',
        'Runtime key (sk-proj-...) не заменяет Admin API key.',
        'Admin key при запуске готового туннеля НЕ используется.',
        'Ключ хранится в .env рядом с CMD, НЕ в переменных Windows.'
    )
}

function Resolve-SharedRuntimeKey {
    param($Settings)
    Write-Rule 'OPENAI SECURE MCP TUNNEL — API-КЛЮЧ'
    Show-RuntimeKeyHelp
    $old = Get-DotEnvValue -Name 'CONTROL_PLANE_API_KEY'
    if ($old) {
        Write-SavedAccent ('Найден сохраненный CONTROL_PLANE_API_KEY: {0}.' -f (Format-MaskedApiKey -Value $old))
        Write-SavedAccent 'Enter — оставить; R — заменить; B — назад.'
        while ($true) {
            $choice = (Read-HostWithoutTranscript 'Ключ').Trim()
            if ($choice -eq '' -or $choice -match '^(?i:k|keep)$') {
                $script:RuntimeKey = $old
                Write-Ok 'Используется Runtime API key из локального .env.'
                return $true
            }
            if ($choice -match '^(?i:b|back|назад)$') { return $false }
            if ($choice -match '^(?i:r|replace|з|заменить)$') { break }
            Write-Warn 'Выберите Enter, R или B.'
        }
    } else {
        Write-Warn 'В локальном .env нет CONTROL_PLANE_API_KEY.'
        Write-Info 'Введите Runtime API key, он сохранится только в .env рядом с CMD.'
    }
    while ($true) {
        $newKey = Read-VisibleKey -Prompt 'Runtime API key (Enter = отмена)'
        if (-not $newKey) { return $false }
        if ($newKey -match '\s') { Write-Warn 'В ключе не должно быть пробелов или переносов строк.'; continue }
        if ($old -and $newKey -cne $old) { $script:RuntimeKeyChanged = $true }
        Save-DotEnvValue -Name 'CONTROL_PLANE_API_KEY' -Value $newKey
        $script:RuntimeKey = $newKey
        Write-Ok 'Runtime API key сохранён в .env.'
        return $true
    }
}

function Get-JsonField {
    param($Value, [Parameter(Mandatory=$true)][string]$Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertFrom-NativeJson {
    param([string]$Output)
    if (-not $Output) { return $null }
    # Prefer the full JSON response. Do not scrape arbitrary output for secrets.
    try { return ($Output | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Get-UniqueTunnelIdsFromOutput {
    param([string]$Output)
    # Used only on a CLI response that has already been scoped to one DevSpace alias.
    return @([regex]::Matches([string]$Output, 'tunnel_[A-Za-z0-9_-]+') |
        ForEach-Object { $_.Value } | Select-Object -Unique)
}

function Read-DevSpaceTunnelIdFromNativeState {
    # Check the local alias first: status is scoped to devspace-mcp, so a unique
    # tunnel ID anywhere in this command's JSON is safe to adopt.
    $found = Invoke-Native -FilePath $script:TunnelExe -Arguments @('runtimes','status','devspace-mcp','--json') -Quiet -AllowFailure
    if ($found.ExitCode -eq 0) {
        $ids = @(Get-UniqueTunnelIdsFromOutput -Output $found.Output)
        if ($ids.Count -eq 1) { return [string]$ids[0] }
        if ($ids.Count -gt 1) { Write-Warn 'У alias devspace-mcp несколько разных ID; автоматический выбор небезопасен.' }
    }

    $listed = Invoke-Native -FilePath $script:TunnelExe -Arguments @('runtimes','list','--json') -Quiet -AllowFailure
    if ($listed.ExitCode -ne 0) { return '' }
    $j = ConvertFrom-NativeJson -Output $listed.Output
    if ($null -eq $j) { return '' }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($root in @($j)) { if ($null -ne $root) { $entries.Add($root) } }
    foreach ($property in @('aliases','local_aliases','runtimes','local','entries','items')) {
        $group = Get-JsonField -Value $j -Name $property
        if ($null -eq $group) { continue }
        $namedEntry = Get-JsonField -Value $group -Name 'devspace-mcp'
        if ($null -ne $namedEntry) { $entries.Add($namedEntry) }
        foreach ($entry in @($group)) { if ($null -ne $entry) { $entries.Add($entry) } }
    }
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $entries) {
        $alias = Get-JsonField -Value $entry -Name 'alias'
        if ($alias -ne 'devspace-mcp') { continue }
        $ids = @(Get-UniqueTunnelIdsFromOutput -Output ($entry | ConvertTo-Json -Depth 12 -Compress))
        foreach ($id in $ids) { if (-not $candidates.Contains([string]$id)) { $candidates.Add([string]$id) } }
    }
    if ($candidates.Count -eq 1) { return [string]$candidates[0] }
    if ($candidates.Count -gt 1) { Write-Warn 'В локальном состоянии DevSpace обнаружены противоречивые Tunnel ID.' }
    return ''
}

function Save-DevSpaceTunnelId {
    param($Settings, [Parameter(Mandatory=$true)][string]$TunnelId)
    if ($TunnelId -notmatch '^tunnel_[A-Za-z0-9_-]+$') { throw 'Некорректный Tunnel ID от tunnel-client.' }
    $Settings.TunnelId = $TunnelId
    # Store ONLY fingerprints. Never store API keys in settings.json.
    $Settings.RuntimeKeyFingerprint = Get-KeyFingerprint -Key $script:RuntimeKey
    if ($script:SelectedAdminKey) {
        $Settings.AdminKeyFingerprint = Get-KeyFingerprint -Key $script:SelectedAdminKey
    }
    Save-Settings $Settings
    Save-DotEnvValue -Name 'DEVSPACE_MCP_TUNNEL_ID' -Value $TunnelId
}

function Get-ScopeFromLocalRuntimes {
    # Scope can be learned from tunnel metadata using only a Runtime key.
    # Never infer the scope from the key itself and never reuse another tunnel ID.
    $scopeMatches = New-Object System.Collections.Generic.List[object]
    $oldRuntime = [Environment]::GetEnvironmentVariable('CONTROL_PLANE_API_KEY','Process')
    $oldAdmin = [Environment]::GetEnvironmentVariable('OPENAI_ADMIN_KEY','Process')
    try {
        [Environment]::SetEnvironmentVariable('CONTROL_PLANE_API_KEY', $script:RuntimeKey, 'Process')
        $result = Invoke-Native -FilePath $script:TunnelExe -Arguments @('runtimes','list','--json') -Quiet -AllowFailure
        if ($result.ExitCode -ne 0) { return $null }
        $allIds = [regex]::Matches([string]$result.Output, 'tunnel_[A-Za-z0-9_-]+') |
            ForEach-Object { $_.Value } | Select-Object -Unique -First 8
        # The read-only get command should use the runtime credential, not a
        # potentially unrelated admin key present in this PowerShell process.
        [Environment]::SetEnvironmentVariable('OPENAI_ADMIN_KEY', $null, 'Process')
        foreach ($tid in @($allIds)) {
            if ($tid -notmatch '^tunnel_[A-Za-z0-9_-]+$') { continue }
            $r = Invoke-Native -FilePath $script:TunnelExe -Arguments @('admin','tunnels','get',$tid,'--json') -Quiet -AllowFailure
            if ($r.ExitCode -ne 0) { continue }
            $info = ConvertFrom-NativeJson -Output $r.Output
            if ($null -eq $info) { continue }
            $orgs = @(Get-JsonField -Value $info -Name 'organization_ids' | Where-Object { $_ })
            $workspaces = @(Get-JsonField -Value $info -Name 'workspace_ids' | Where-Object { $_ })
            if ($orgs.Count -eq 1 -or $workspaces.Count -eq 1) {
                $org = if ($orgs.Count -eq 1) { [string]$orgs[0] } else { '' }
                $ws = if ($workspaces.Count -eq 1) { [string]$workspaces[0] } else { '' }
                if ($org -or $ws) {
                    $key = ($org + '|' + $ws)
                    if (@($scopeMatches | Where-Object { $_.Key -eq $key }).Count -eq 0) {
                        $scopeMatches.Add([pscustomobject]@{ Key=$key; Org=$org; Workspace=$ws })
                    }
                }
            }
        }
    } finally {
        [Environment]::SetEnvironmentVariable('CONTROL_PLANE_API_KEY', $oldRuntime, 'Process')
        [Environment]::SetEnvironmentVariable('OPENAI_ADMIN_KEY', $oldAdmin, 'Process')
    }
    if ($scopeMatches.Count -eq 1) {
        $item = $scopeMatches[0]
        Write-Ok 'Организация/workspace определены по метаданным другого локального туннеля.'
        return $item
    }
    if ($scopeMatches.Count -gt 1) {
        Write-Info 'У локальных туннелей разные области доступа. Выберите нужную для DevSpace:'
        for ($i=0; $i -lt $scopeMatches.Count; $i++) {
            Write-Host ("  [{0}] Организация: {1}; Workspace: {2}" -f ($i+1), $scopeMatches[$i].Org, $scopeMatches[$i].Workspace) -ForegroundColor Cyan
        }
        Write-Host '  [M] Указать другую область вручную' -ForegroundColor Gray
        while ($true) {
            $choice = (Read-HostWithoutTranscript 'Область').Trim()
            if ($choice -eq '' -or $choice -match '^(?i:m)$') { return $null }
            $index = 0
            if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $scopeMatches.Count) {
                return $scopeMatches[$index-1]
            }
            Write-Warn 'Выберите номер области или M.'
        }
    }
    return $null
}

function Resolve-RegistrationScope {
    if ($script:NewAccountBinding) {
        $org = ''
        $workspace = ''
        Write-Warn 'Выбран другой аккаунт OpenAI: старые Organization/Workspace ID не используются.'
    } else {
        $org = Get-DotEnvValue -Name 'OPENAI_ORG_ID'
        $workspace = Get-DotEnvValue -Name 'OPENAI_WORKSPACE_ID'
    }
    if ($org -or $workspace) {
        Write-Ok 'Scope регистрации найден в локальном .env.'
        return [pscustomobject]@{ Org=$org; Workspace=$workspace }
    }
    if (-not $script:NewAccountBinding) {
        Write-Info 'Проверяю scope по уже настроенным локальным туннелям.'
        $discovered = Get-ScopeFromLocalRuntimes
        if ($discovered) {
            if ($discovered.Org) { Save-DotEnvValue -Name 'OPENAI_ORG_ID' -Value $discovered.Org }
            if ($discovered.Workspace) { Save-DotEnvValue -Name 'OPENAI_WORKSPACE_ID' -Value $discovered.Workspace }
            return $discovered
        }
    }
    Write-NoticeBox -Title 'ПЕРВАЯ РЕГИСТРАЦИЯ ТУННЕЛЯ: ОБЛАСТЬ ДОСТУПА' -Lines @(
        'Scope — ID организации или ChatGPT workspace, НЕ API-ключ.',
        'Без scope невозможно создать новый туннель.',
        'Организация: https://platform.openai.com/settings/organization/general',
        'Workspace: настройки рабочего пространства ChatGPT.',
        'Укажите хотя бы одно значение; оно сохранится в .env.',
        'Чтобы отменить настройку, введите B.'
    )
    while ($true) {
        $org = (Read-HostWithoutTranscript 'Organization ID (Enter = пропустить, B = назад)').Trim()
        if ($org -match '^(?i:b|back|назад)$') { return $null }
        $workspace = (Read-HostWithoutTranscript 'Workspace ID (Enter = пропустить, B = назад)').Trim()
        if ($workspace -match '^(?i:b|back|назад)$') { return $null }
        if (-not $org -and -not $workspace) { Write-Warn 'Укажите хотя бы один ID организации или workspace.'; continue }
        if ($org -match '\s' -or $workspace -match '\s') { Write-Warn 'ID не должен содержать пробелы.'; continue }
        # Save both fields, including empty values, so switching accounts
        # cannot leave the previous account's workspace/org behind.
        Save-DotEnvValue -Name 'OPENAI_ORG_ID' -Value $org
        Save-DotEnvValue -Name 'OPENAI_WORKSPACE_ID' -Value $workspace
        return [pscustomobject]@{ Org=$org; Workspace=$workspace }
    }
}

function Resolve-AdminCreateKey {
    param([switch]$RequireReplacement, [switch]$Optional)
    $existing = Get-DotEnvValue -Name 'OPENAI_ADMIN_KEY'
    if ($existing) {
        Write-SavedAccent ('Найден сохраненный OPENAI_ADMIN_KEY: {0}.' -f (Format-MaskedApiKey -Value $existing))
        if ($RequireReplacement) {
            Write-Warn 'Предыдущая попытка отклонена. Введите другой Admin API key или отмените.'
        } else {
            Write-SavedAccent 'Enter — оставить; R — заменить; B — назад.'
            while ($true) {
                $choice = (Read-HostWithoutTranscript 'Admin API key').Trim()
                if ($choice -eq '') { return $existing }
                if ($choice -match '^(?i:b|back|назад)$') {
                    $script:AdminSelectionBack = $true
                    return ''
                }
                if ($choice -match '^(?i:r|replace|з|заменить)$') { break }
                Write-Warn 'Выберите Enter, R или B.'
            }
        }
    } else {
        Write-Warn 'В локальном .env нет OPENAI_ADMIN_KEY.'
        if ($Optional) {
            Write-Info 'Для уже существующего туннеля admin-ключ необязателен.'
            Write-SavedAccent 'Enter — пропустить; R — ввести ключ; B — назад.'
            while ($true) {
                $choice = (Read-HostWithoutTranscript 'Admin API key').Trim()
                if ($choice -eq '') { return '' }
                if ($choice -match '^(?i:b|back|назад)$') {
                    $script:AdminSelectionBack = $true
                    return ''
                }
                if ($choice -match '^(?i:r|replace|з|заменить)$') { break }
                Write-Warn 'Выберите Enter, R или B.'
            }
        } else {
            Write-Info 'Для создания нового туннеля введите Admin API key.'
        }
    }
    while ($true) {
        $newKey = Read-VisibleKey -Prompt 'Новый Admin API key (Enter = отмена)'
        if (-not $newKey) { return '' }
        if ($newKey -match '\s') { Write-Warn 'В ключе не должно быть пробелов или переносов строк.'; continue }
        if ($existing -and $newKey -ceq $existing -and $RequireReplacement) {
            Write-Warn 'Это тот же отклонённый ключ. Введите другой или отмените.'
            continue
        }
        if ($existing -and $newKey -cne $existing) { $script:AdminKeyChanged = $true }
        Save-DotEnvValue -Name 'OPENAI_ADMIN_KEY' -Value $newKey
        return $newKey
    }
}

function Invoke-DevSpaceAdminCommand {
    param(
        [Parameter(Mandatory=$true)][string]$ApiKey,
        [Parameter(Mandatory=$true)][string[]]$CliArguments
    )
    # Never pass the admin key as a command-line argument or log its value.
    # The process environment is restored as soon as tunnel-client exits.
    $temporaryName = 'DEVSPACE_TUNNEL_CREATE_KEY'
    $previous = [Environment]::GetEnvironmentVariable($temporaryName,'Process')
    try {
        [Environment]::SetEnvironmentVariable($temporaryName,$ApiKey,'Process')
        $args = @('admin','--json','tunnels') + $CliArguments + @('--admin-key','env:DEVSPACE_TUNNEL_CREATE_KEY')
        return (Invoke-Native -FilePath $script:TunnelExe -Arguments $args -Quiet -AllowFailure)
    } finally {
        [Environment]::SetEnvironmentVariable($temporaryName,$previous,'Process')
    }
}

function Invoke-ListDevSpaceTunnels {
    param([Parameter(Mandatory=$true)][string]$ApiKey, $Scope)
    # The admin list endpoint requires EXACTLY one scope flag. Do not pass both.
    $args = @('list')
    if ($Scope.Org) { $args += @('--organization-id',[string]$Scope.Org) }
    elseif ($Scope.Workspace) { $args += @('--workspace-id',[string]$Scope.Workspace) }
    else { throw 'Для просмотра списка туннелей необходим scope организации/workspace.' }

    $r = Invoke-DevSpaceAdminCommand -ApiKey $ApiKey -CliArguments $args
    $found = New-Object System.Collections.Generic.List[object]
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{ Success=$false; Tunnels=@(); Output=[string]$r.Output }
    }
    $data = ConvertFrom-NativeJson -Output $r.Output
    if ($null -eq $data) {
        return [pscustomobject]@{ Success=$false; Tunnels=@(); Output='Невозможно разобрать JSON списка туннелей.' }
    }
    $items = Get-JsonField -Value $data -Name 'tunnels'
    if ($null -eq $items -and $data -is [array]) { $items = $data }
    foreach ($t in @($items)) {
        if ($null -eq $t) { continue }
        $name = [string](Get-JsonField -Value $t -Name 'name')
        $id = [string](Get-JsonField -Value $t -Name 'id')
        if ($name -eq 'DevSpace MCP' -and $id -match '^tunnel_[A-Za-z0-9_-]+$') {
            $found.Add([pscustomobject]@{ Id=$id; Name=$name })
        }
    }
    return [pscustomobject]@{ Success=$true; Tunnels=@($found.ToArray()); Output='' }
}

function Select-DevSpaceRemoteTunnelId {
    param($Snapshot)
    $matches = @($Snapshot.Tunnels)
    if ($matches.Count -eq 0) { return '' }
    if ($matches.Count -eq 1) {
        Write-Ok 'Нашёл ранее зарегистрированный DevSpace MCP в OpenAI; создание нового туннеля не требуется.'
        return [string]$matches[0].Id
    }
    Write-Warn 'Найдено несколько DevSpace MCP с одинаковым названием. Новый туннель не создаю.'
    for ($i=0; $i -lt $matches.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i+1), $matches[$i].Id) -ForegroundColor Cyan
    }
    Write-Host '  [B] Вернуться в меню без изменений' -ForegroundColor Gray
    while ($true) {
        $choice = (Read-HostWithoutTranscript 'Выбери существующий DevSpace Tunnel ID').Trim()
        if ($choice -eq '' -or $choice -match '^(?i:b|back|назад)$') { return '' }
        $index = 0
        if ([int]::TryParse($choice,[ref]$index) -and $index -ge 1 -and $index -le $matches.Count) {
            return [string]$matches[$index-1].Id
        }
        Write-Warn 'Введите номер найденного туннеля или B.'
    }
}

function Invoke-CreateDevSpaceTunnel {
    param([Parameter(Mandatory=$true)][string]$ApiKey, $Scope)
    # Direct admin CRUD returns the tunnel object with a top-level `id`.
    # The previous `runtimes create` returned a different nested shape that
    # wasn't handled by the launcher, even when it did create the tunnel.
    $args = @('create','--name','DevSpace MCP',
        '--description','Private DevSpace MCP via Secure MCP Tunnel')
    if ($Scope.Org) { $args += @('--organization-id',[string]$Scope.Org) }
    if ($Scope.Workspace) { $args += @('--workspace-id',[string]$Scope.Workspace) }
    return (Invoke-DevSpaceAdminCommand -ApiKey $ApiKey -CliArguments $args)
}

function Resolve-OrCreateDevSpaceTunnelId {
    param($Settings)
    Write-Step 'Secure MCP Tunnel: поиск или создание ID для DevSpace'
    Show-AdminKeyHelp
    # Prompt for the admin key EVEN IF a tunnel ID already exists. The owner
    # can switch accounts/keys from the wizard without editing any script.
    $script:AdminSelectionBack = $false
    $script:SelectedAdminKey = Resolve-AdminCreateKey -Optional
    if ($script:AdminSelectionBack) { return '' }

    $id = ''
    foreach ($candidate in @((Get-DotEnvValue -Name 'DEVSPACE_MCP_TUNNEL_ID'), [string]$Settings.TunnelId)) {
        if ($candidate -match '^tunnel_[A-Za-z0-9_-]+$') { $id = [string]$candidate; break }
    }
    # On an account switch, native client state may belong to the old owner.
    if (-not $id) { $id = Read-DevSpaceTunnelIdFromNativeState }

    $runtimeFingerprint = Get-KeyFingerprint -Key $script:RuntimeKey
    $adminFingerprint = Get-KeyFingerprint -Key $script:SelectedAdminKey
    $fingerprintChanged = $false
    if ($Settings.RuntimeKeyFingerprint -and ($Settings.RuntimeKeyFingerprint -cne $runtimeFingerprint)) { $fingerprintChanged = $true }
    if ($Settings.AdminKeyFingerprint -and $script:SelectedAdminKey -and ($Settings.AdminKeyFingerprint -cne $adminFingerprint)) { $fingerprintChanged = $true }
    if ($script:RuntimeKeyChanged -or $script:AdminKeyChanged) { $fingerprintChanged = $true }
    # Old versions did not store key fingerprints. Confirm the first reuse once.
    $unverifiedBinding = ($id -and -not $Settings.RuntimeKeyFingerprint)
    if ($id -and ($fingerprintChanged -or $unverifiedBinding)) {
        Write-NoticeBox -Title 'ПРОВЕРКА АККАУНТА ДЛЯ DEVSPACE TUNNEL ID' -Lines @(
            'Сохранённый Tunnel ID может относиться к другому аккаунту OpenAI.',
            'Enter — тот же аккаунт: оставить существующий Tunnel ID.',
            'N — другой аккаунт: найти или создать отдельный туннель.',
            'B — вернуться в меню без подключения.',
            'При N старый туннель НЕ удаляется. .env относится только к DevSpace.'
        )
        while ($true) {
            $answer = (Read-HostWithoutTranscript 'Аккаунт [Enter/N/B]').Trim()
            if ($answer -eq '') { break }
            if ($answer -match '^(?i:b|back|назад)$') { return '' }
            if ($answer -match '^(?i:n|new|новый)$') {
                $script:NewAccountBinding = $true
                $id = ''
                break
            }
            Write-Warn 'Выберите Enter, N или B.'
        }
    }
    if (-not $script:NewAccountBinding -and $id) {
        Write-Ok "Найден существующий DevSpace Tunnel ID: $id"
        Save-DevSpaceTunnelId -Settings $Settings -TunnelId $id
        return $id
    }
    if ($script:NewAccountBinding) {
        Write-Info 'Аккаунт переключён: старый DevSpace Tunnel ID не используется.'
    }

    $scope = Resolve-RegistrationScope
    if (-not $scope) { return '' }
    $admin = $script:SelectedAdminKey
    if (-not $admin) {
        Write-Info 'Для поиска или создания туннеля нового аккаунта нужен Admin API key.'
        $script:AdminSelectionBack = $false
        $admin = Resolve-AdminCreateKey
        if ($script:AdminSelectionBack -or -not $admin) { return '' }
        $script:SelectedAdminKey = $admin
    }

    # An earlier version reported 'created, but ID could not be extracted'.
    # REMOTE READ FIRST, including on a clean installation. Never create a new
    # tunnel while the remote list state is unknown.
    Write-Info 'Ищу ранее зарегистрированный DevSpace MCP в OpenAI (без изменений других туннелей).'
    $remote = Invoke-ListDevSpaceTunnels -ApiKey $admin -Scope $scope
    if (-not $remote.Success) {
        Write-Warn 'Не удалось получить список туннелей. Создание нового заблокировано во избежание дубликатов.'
        $diagnostic = [string]$remote.Output
        if ($admin) { $diagnostic = $diagnostic.Replace($admin,'[СКРЫТО]') }
        if ($script:RuntimeKey) { $diagnostic = $diagnostic.Replace($script:RuntimeKey,'[СКРЫТО]') }
        if ($diagnostic.Length -gt 700) { $diagnostic = $diagnostic.Substring(0,700) + '...' }
        if ($diagnostic) { Write-Host $diagnostic -ForegroundColor DarkYellow }
        if ($diagnostic -match '(?i)(401|403|unauthoriz|forbidden|permission|credential|api.?key)') {
            Write-Warn 'Похоже, административный ключ не имеет нужных прав.'
            $replacement = Resolve-AdminCreateKey -RequireReplacement
            if (-not $replacement) { return '' }
            $admin = $replacement
            $script:SelectedAdminKey = $admin
            $remote = Invoke-ListDevSpaceTunnels -ApiKey $admin -Scope $scope
            if (-not $remote.Success) {
                Write-Warn 'Повторная проверка списка не прошла; ничего не создаю.'
                return ''
            }
        } else { return '' }
    }
    if (@($remote.Tunnels).Count -gt 0) {
        $id = Select-DevSpaceRemoteTunnelId -Snapshot $remote
        if (-not $id) { return '' }
        Save-DevSpaceTunnelId -Settings $Settings -TunnelId $id
        Write-Ok "Восстановлен DevSpace Tunnel ID: $id"
        return $id
    }

    Write-Info 'Зарегистрированных DevSpace MCP не найдено; создаю один новый туннель.'
    $created = Invoke-CreateDevSpaceTunnel -ApiKey $admin -Scope $scope
    if ($created.ExitCode -ne 0) {
        # Also check remote when create reports failure; the server may have
        # committed the request before a network/CLI reporting failure.
        Write-Warn ("CLI вернул код {0}. Перед повторной попыткой проверяю реестр туннелей." -f $created.ExitCode)
        $remote = Invoke-ListDevSpaceTunnels -ApiKey $admin -Scope $scope
        if ($remote.Success -and @($remote.Tunnels).Count -gt 0) {
            $id = Select-DevSpaceRemoteTunnelId -Snapshot $remote
            if ($id) {
                Save-DevSpaceTunnelId -Settings $Settings -TunnelId $id
                Write-Ok "Восстановлен DevSpace Tunnel ID: $id"
                return $id
            }
        }
        $diagnostic = [string]$created.Output
        if ($admin) { $diagnostic = $diagnostic.Replace($admin,'[СКРЫТО]') }
        if ($script:RuntimeKey) { $diagnostic = $diagnostic.Replace($script:RuntimeKey,'[СКРЫТО]') }
        if ($diagnostic.Length -gt 900) { $diagnostic = $diagnostic.Substring(0,900) + '...' }
        if ($diagnostic) { Write-Host $diagnostic -ForegroundColor DarkYellow }
        Write-Warn 'Создание не подтверждено. Проверьте доступ к OpenAI или права Tunnels Manage.'
        return ''
    }

    $id = ''
    $json = ConvertFrom-NativeJson -Output $created.Output
    if ($null -ne $json) {
        $raw = Get-JsonField -Value $json -Name 'id'
        if (-not $raw) { $raw = Get-JsonField -Value $json -Name 'tunnel_id' }
        if (-not $raw) {
            $nested = Get-JsonField -Value $json -Name 'tunnel'
            $raw = Get-JsonField -Value $nested -Name 'id'
        }
        if ($raw -match '^tunnel_[A-Za-z0-9_-]+$') { $id = [string]$raw }
    }
    if (-not $id) {
        Write-Warn 'Ответ на создание получен, но ID не распознан. Восстанавливаю его из реестра OpenAI.'
        $remote = Invoke-ListDevSpaceTunnels -ApiKey $admin -Scope $scope
        if ($remote.Success -and @($remote.Tunnels).Count -gt 0) {
            $id = Select-DevSpaceRemoteTunnelId -Snapshot $remote
        }
    }
    if (-not $id) {
        Write-Warn 'Не удалось безопасно определить ID. НОВЫЙ туннель автоматически не создаю.'
        Write-Host 'Список: https://platform.openai.com/settings/organization/tunnels' -ForegroundColor Cyan
        return ''
    }
    Save-DevSpaceTunnelId -Settings $Settings -TunnelId $id
    Write-Ok "DevSpace Tunnel ID: $id"
    Write-Info 'ID сохранён для следующих запусков и подключения плагина ChatGPT.'
    return $id
}

function Select-TunnelCredentials {
    param($Settings)
    $script:RuntimeKeyChanged = $false
    $script:AdminKeyChanged = $false
    $script:NewAccountBinding = $false
    $script:SelectedAdminKey = ''
    if (-not (Resolve-SharedRuntimeKey -Settings $Settings)) { return $false }
    $id = Resolve-OrCreateDevSpaceTunnelId -Settings $Settings
    if (-not $id) {
        Write-Info 'Создание туннеля отменено или не завершено. Возвращаюсь в меню.'
        return $false
    }
    return $true
}

function Test-LocalReady {
    param([Parameter(Mandatory=$true)][string]$Url)
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(2)
    try {
        $r = $client.GetAsync($Url).GetAwaiter().GetResult()
        return ($r.StatusCode -eq [System.Net.HttpStatusCode]::OK)
    } catch { return $false }
    finally { $client.Dispose(); $handler.Dispose() }
}

function Show-SecureTunnelLogs {
    foreach ($p in @($script:BridgeStdErr, $script:TunnelStdErr)) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            $lines = @(Get-Content -LiteralPath $p -Tail 30 -ErrorAction SilentlyContinue)
            foreach ($line in $lines) { Write-Host $line -ForegroundColor DarkRed }
        }
    }
}

function Get-GlobalDevSpaceVersion {
    param([string]$Npm)
    $r = Invoke-Native -FilePath $Npm -Arguments @('list','-g','@waishnav/devspace','--depth=0','--json') -AllowFailure -Quiet
    if ([string]::IsNullOrWhiteSpace($r.Output)) { return $null }
    try {
        $j = $r.Output | ConvertFrom-Json
        if ($j.dependencies -and $j.dependencies.'@waishnav/devspace') {
            return [string]$j.dependencies.'@waishnav/devspace'.version
        }
    } catch {}
    return $null
}

function Get-LatestDevSpaceVersion {
    param([string]$Npm)
    $r = Invoke-Native -FilePath $Npm -Arguments @('view','@waishnav/devspace','version') -AllowFailure -Quiet
    if ($r.ExitCode -eq 0 -and $r.Output -match '\d+\.\d+\.\d+') { return $Matches[0] }
    return $null
}

function Ensure-DevSpace {
    param([pscustomobject]$NodeInfo)
    Write-Step 'DevSpace CLI (@waishnav/devspace)'
    $installed = Get-GlobalDevSpaceVersion -Npm $NodeInfo.Npm
    $latest = Get-LatestDevSpaceVersion -Npm $NodeInfo.Npm
    if ($installed) { Write-Info "Установленная версия: $installed" }
    if ($latest) { Write-Info "Последняя стабильная версия npm: $latest" }

    $needInstall = (-not $installed)
    if ($installed -and $latest) {
        $iv = ConvertTo-Version $installed
        $lv = ConvertTo-Version $latest
        if ($iv -and $lv -and $iv -lt $lv) { $needInstall = $true }
    }

    if ($needInstall) {
        $spec = if ($latest) { "@waishnav/devspace@$latest" } else { '@waishnav/devspace@latest' }
        Write-Info "Устанавливаю/обновляю $spec глобально через npm."

        # npm can legitimately write warnings to stderr while still succeeding.
        # Wait for the real exit code and only treat a non-zero result as failure.
        $install = Invoke-Native -FilePath $NodeInfo.Npm -Arguments @('install','-g',$spec) -AllowFailure -FriendlyName 'npm install -g @waishnav/devspace'
        Refresh-ProcessPath
        $installed = Get-GlobalDevSpaceVersion -Npm $NodeInfo.Npm

        if ($install.ExitCode -ne 0 -or -not $installed) {
            Write-Warn 'Глобальная установка DevSpace через npm не завершилась успешно.'
            Write-Info 'Проверяю официальный режим запуска через npx — глобальная установка DevSpace не обязательна.'
            $npxTest = Invoke-Native -FilePath $NodeInfo.Npx -Arguments @('--yes',$spec,'--help') -AllowFailure -Quiet -FriendlyName 'npx @waishnav/devspace --help'
            if ($npxTest.ExitCode -eq 0) {
                $reported = if ($latest) { $latest } else { 'latest' }
                Write-Ok "DevSpace доступен через npx ($reported). Продолжаю без глобальной установки."
                return ("{0} (npx)" -f $reported)
            }

            $details = @()
            if (-not [string]::IsNullOrWhiteSpace($install.Output)) {
                $details += "npm install -g:`n$($install.Output)"
            }
            if (-not [string]::IsNullOrWhiteSpace($npxTest.Output)) {
                $details += "npx check:`n$($npxTest.Output)"
            }
            throw ("DevSpace не удалось запустить ни глобально, ни через npx.`n{0}" -f ($details -join "`n`n"))
        }
    }

    if (-not $installed) {
        $spec = if ($latest) { "@waishnav/devspace@$latest" } else { '@waishnav/devspace@latest' }
        $npxTest = Invoke-Native -FilePath $NodeInfo.Npx -Arguments @('--yes',$spec,'--help') -AllowFailure -Quiet
        if ($npxTest.ExitCode -eq 0) {
            $reported = if ($latest) { $latest } else { 'latest' }
            Write-Ok "DevSpace доступен через npx ($reported)."
            return ("{0} (npx)" -f $reported)
        }
        throw 'DevSpace не обнаружен после установки и не запускается через npx.'
    }

    Write-Ok "DevSpace CLI: $installed"

    $check = Invoke-GitBash -Command 'command -v devspace >/dev/null 2>&1 && devspace --help >/dev/null 2>&1' -AllowFailure -Quiet
    if ($check.ExitCode -ne 0) {
        Write-Warn 'Git Bash не видит глобальную команду devspace; для запуска будет использоваться npx.'
    }
    return $installed
}

function Ensure-DevSpaceUtf8ShellPatch {
    param([pscustomobject]$NodeInfo)

    $npmRootResult = Invoke-Native -FilePath $NodeInfo.Npm -Arguments @('root','-g') -AllowFailure -Quiet
    if ($npmRootResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($npmRootResult.Output)) {
        Write-Warn 'Не удалось определить глобальный npm root; UTF-8 патч DevSpace не применён.'
        return
    }

    $npmRoot = ($npmRootResult.Output -split "`r?`n" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Last 1).Trim()

    $dist = Join-Path $npmRoot '@waishnav\devspace\dist'
    $processPlatform = Join-Path $dist 'process-platform.js'
    $processSessions = Join-Path $dist 'process-sessions.js'

    foreach ($required in @($processPlatform, $processSessions)) {
        if (-not (Test-Path -LiteralPath $required)) {
            Write-Warn "Не найден $required; UTF-8 патч DevSpace пропущен."
            return
        }
    }

    $utf8NoBom = New-Object Text.UTF8Encoding($false)

    $platformSource = [IO.File]::ReadAllText($processPlatform, [Text.Encoding]::UTF8)
    $platformOriginal = 'args: ["/d", "/s", "/c", command],'
    $platformPatched = 'args: ["/d", "/s", "/c", `chcp 65001>nul && ${command}`],'

    if (-not $platformSource.Contains($platformPatched)) {
        if (-not $platformSource.Contains($platformOriginal)) {
            Write-Warn 'DevSpace process-platform.js изменился; автоматический UTF-8 патч требует проверки.'
            return
        }
        [IO.File]::WriteAllText(
            $processPlatform,
            $platformSource.Replace($platformOriginal, $platformPatched),
            $utf8NoBom
        )
    }

    $sessionsSource = [IO.File]::ReadAllText($processSessions, [Text.Encoding]::UTF8)
    $sessionsOriginal = 'const child = spawn(input.command, {'
    $sessionsPatched = 'const child = spawn(`chcp 65001>nul && ${input.command}`, {'

    if (-not $sessionsSource.Contains($sessionsPatched)) {
        if (-not $sessionsSource.Contains($sessionsOriginal)) {
            Write-Warn 'DevSpace process-sessions.js изменился; автоматический UTF-8 патч требует проверки.'
            return
        }
        [IO.File]::WriteAllText(
            $processSessions,
            $sessionsSource.Replace($sessionsOriginal, $sessionsPatched),
            $utf8NoBom
        )
    }

    Write-Ok 'DevSpace exec_command настроен на UTF-8 для обычного pipe и PTY режима.'
}
function Escape-BashSingleQuote {
    param([string]$Text)
    # PublicOrigin is normalized to scheme + host + optional port only, so double quotes are safe.
    return '"' + $Text + '"'
}

function Invoke-GitBash {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [switch]$AllowFailure,
        [switch]$Quiet,
        [switch]$Interactive
    )
    if (-not $script:GitBash) { throw 'Git Bash не инициализирован.' }
    $oldConv = $env:MSYS2_ARG_CONV_EXCL
    $env:MSYS2_ARG_CONV_EXCL = '*'
    try {
        if ($Interactive) {
            & $script:GitBash --login -i -c $Command
            $code = $LASTEXITCODE
            if (($code -ne 0) -and (-not $AllowFailure)) { throw "Git Bash command failed with exit code $code." }
            return [pscustomobject]@{ ExitCode=$code; Output='' }
        }
        return Invoke-Native -FilePath $script:GitBash -Arguments @('--login','-c',$Command) -AllowFailure:$AllowFailure -Quiet:$Quiet -FriendlyName 'Git Bash / DevSpace'
    } finally {
        if ($null -eq $oldConv) { Remove-Item Env:MSYS2_ARG_CONV_EXCL -ErrorAction SilentlyContinue }
        else { $env:MSYS2_ARG_CONV_EXCL = $oldConv }
    }
}

function Get-DevSpaceCommand {
    $r = Invoke-GitBash -Command 'command -v devspace >/dev/null 2>&1' -AllowFailure -Quiet
    if ($r.ExitCode -eq 0) { return 'devspace' }
    return 'npx --yes @waishnav/devspace'
}

function Test-DevSpaceInitialized {
    $dir = Join-Path $env:USERPROFILE '.devspace'
    $auth = Join-Path $dir 'auth.json'
    $config1 = Join-Path $dir 'config.jsonc'
    $config0 = Join-Path $dir 'config.json'
    return ((Test-Path -LiteralPath $auth) -and ((Test-Path -LiteralPath $config1) -or (Test-Path -LiteralPath $config0)))
}

function Get-DevSpaceResolvedConfig {
    $cmd = Get-DevSpaceCommand
    $r = Invoke-GitBash -Command ("$cmd config get") -AllowFailure -Quiet
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.Output)) { return $null }
    try {
        $raw = $r.Output
        $first = $raw.IndexOf('{')
        $last = $raw.LastIndexOf('}')
        if ($first -ge 0 -and $last -gt $first) {
            return ($raw.Substring($first, $last - $first + 1) | ConvertFrom-Json)
        }
    } catch {}
    return $null
}

function Get-SafePropertyValue {
    param($Object, [Parameter(Mandatory=$true)][string]$Name)
    if ($null -eq $Object) { return $null }
    try {
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -eq $prop) { return $null }
        return $prop.Value
    } catch {
        return $null
    }
}

function Get-DevSpaceAllowedRoots {
    # StrictMode throws when a JSON property is absent. DevSpace may legitimately
    # omit allowedRoots until ChatGPT/project roots have been configured, so every
    # lookup here must be optional rather than direct property dereferencing.
    $cfg = Get-DevSpaceResolvedConfig
    if ($null -eq $cfg) { return @() }

    $workspaces = Get-SafePropertyValue -Object $cfg -Name 'workspaces'
    $roots = Get-SafePropertyValue -Object $workspaces -Name 'allowedRoots'
    if ($null -eq $roots) {
        # v1.0 compatibility: allowedRoots used to be a top-level field.
        $roots = Get-SafePropertyValue -Object $cfg -Name 'allowedRoots'
    }
    if ($null -eq $roots) { return @() }

    return @($roots | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Normalize-AllowedRootsInput {
    param([string]$InputText)
    $parts = @($InputText -split ';' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ })
    if ($parts.Count -eq 0) { throw 'Не указана ни одна разрешённая папка.' }
    $result = @()
    foreach ($p0 in $parts) {
        $p = [Environment]::ExpandEnvironmentVariables($p0)
        if ($p -eq '~') { $p = $env:USERPROFILE }
        elseif ($p.StartsWith('~\') -or $p.StartsWith('~/')) { $p = Join-Path $env:USERPROFILE $p.Substring(2) }
        try { $full = [IO.Path]::GetFullPath($p) } catch { throw "Некорректный путь: $p0" }
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Папка не существует: $full" }
        $root = [IO.Path]::GetPathRoot($full)
        if ($full.TrimEnd('\') -eq $root.TrimEnd('\')) { throw 'Нельзя разрешать корень диска целиком. Выберите конкретную папку проектов.' }
        $result += $full.TrimEnd('\')
    }
    return @($result | Select-Object -Unique)
}

function Set-DevSpaceAllowedRoots {
    param([Parameter(Mandatory=$true)][string[]]$Roots)

    $configPath = Join-Path $env:USERPROFILE '.devspace\config.jsonc'
    if (-not (Test-Path -LiteralPath $configPath)) {
        $legacy = Join-Path $env:USERPROFILE '.devspace\config.json'
        if (Test-Path -LiteralPath $legacy) { $configPath = $legacy }
    }
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw 'Конфигурация DevSpace ещё не создана. Сначала откройте «Штатные настройки DevSpace» и завершите мастер.'
    }

    $jsonValues = @($Roots | ForEach-Object { ConvertTo-Json ([string]$_) -Compress })
    $arrayText = '[' + ($jsonValues -join ', ') + ']'
    $content = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop

    if ($configPath.EndsWith('.jsonc', [StringComparison]::OrdinalIgnoreCase)) {
        $backup = $configPath + '.launcher.bak'
        Copy-Item -LiteralPath $configPath -Destination $backup -Force

        $allowedPattern = '(?<key>"allowedRoots"\s*:\s*)\[(?<body>[\s\S]*?)\]'
        if ([regex]::IsMatch($content, $allowedPattern)) {
            $updated = [regex]::Replace($content, $allowedPattern, '${key}' + $arrayText, 1)
        } else {
            # A valid DevSpace config may omit allowedRoots. Insert it into the
            # workspaces section instead of forcing the user through init again.
            $workspacesPattern = '(?<head>"workspaces"\s*:\s*\{)'
            if ([regex]::IsMatch($content, $workspacesPattern)) {
                $insert = '${head}' + "`r`n    `"allowedRoots`": $arrayText,"
                $updated = [regex]::Replace($content, $workspacesPattern, $insert, 1)
            } else {
                # Extremely minimal but valid v1.1 config: create workspaces after
                # configVersion. DevSpace itself validates the result below.
                $versionPattern = '(?<head>"configVersion"\s*:\s*1\s*,)'
                if (-not [regex]::IsMatch($content, $versionPattern)) {
                    throw 'Не удалось безопасно добавить workspaces.allowedRoots в config.jsonc: секция workspaces/configVersion не найдена.'
                }
                $insert = '${head}' + "`r`n  `"workspaces`": { `"allowedRoots`": $arrayText },"
                $updated = [regex]::Replace($content, $versionPattern, $insert, 1)
            }
        }
        [IO.File]::WriteAllText($configPath, $updated, (New-Object Text.UTF8Encoding($false)))
    } else {
        $j = $content | ConvertFrom-Json
        if (-not $j.workspaces) { $j | Add-Member -NotePropertyName workspaces -NotePropertyValue ([pscustomobject]@{}) }
        $j.workspaces | Add-Member -NotePropertyName allowedRoots -NotePropertyValue @($Roots) -Force
        $jsonText = $j | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($configPath, $jsonText, (New-Object Text.UTF8Encoding($false)))
    }

    try {
        $check = @(Get-DevSpaceAllowedRoots)
        if ($check.Count -eq 0) {
            throw 'DevSpace не подтвердил сохранённые allowedRoots после изменения конфигурации.'
        }

        $expected = @($Roots | ForEach-Object { ([IO.Path]::GetFullPath([string]$_)).TrimEnd('\') })
        $actual = @($check | ForEach-Object { ([IO.Path]::GetFullPath([string]$_)).TrimEnd('\') })
        $expectedKey = (($expected | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object) -join '|')
        $actualKey = (($actual | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object) -join '|')
        if ($expectedKey -ne $actualKey) {
            throw ("DevSpace вернул другой список allowedRoots после сохранения. Ожидалось: {0}; получено: {1}" -f ($expected -join '; '), ($actual -join '; '))
        }

        Write-Ok ('Разрешённые папки DevSpace: {0}' -f ($check -join '; '))
    } catch {
        # Never leave DevSpace with a broken/partially-written config. JSONC
        # changes are made only after a backup has been created above.
        if ($configPath.EndsWith('.jsonc', [StringComparison]::OrdinalIgnoreCase)) {
            $backup = $configPath + '.launcher.bak'
            if (Test-Path -LiteralPath $backup) {
                try {
                    Copy-Item -LiteralPath $backup -Destination $configPath -Force
                    Write-Warn 'Изменение allowedRoots не прошло проверку. Предыдущая конфигурация автоматически восстановлена.'
                } catch {
                    Write-Warn "Не удалось автоматически восстановить backup конфигурации: $($_.Exception.Message)"
                }
            }
        }
        throw
    }
}

function Select-AllowedRootsInteractive {
    param([string]$BackLabel = 'главное меню')
    while ($true) {
        Write-Rule 'РАЗРЕШЁННЫЕ ПАПКИ DEVSPACE'
        $saved = @(Get-DevSpaceAllowedRoots)
        if ($saved.Count -gt 0) {
            Write-SavedAccent 'Сохранённые разрешённые папки:'
            foreach ($p in $saved) { Write-SavedAccent ("  {0}" -f $p) }
            Write-Host ''
            Write-SavedAccent 'Enter — оставить сохранённые папки.'
        } else {
            Write-Host 'Разрешённые папки ещё не настроены.' -ForegroundColor Yellow
        }
        Write-Host 'Введите новый путь, чтобы заменить настройку.' -ForegroundColor White
        Write-Host 'Несколько папок можно разделить символом ;' -ForegroundColor DarkGray
        Write-Host 'Пример: C:\Projects\MyApp' -ForegroundColor DarkGray
        Write-Host ("B — назад в {0}." -f $BackLabel) -ForegroundColor DarkGray
        $raw = (Read-Host 'Папка').Trim()
        if ($raw -match '(?i)^(b|back|назад)$') { return $false }
        if (-not $raw) {
            if ($saved.Count -gt 0) { return $true }
            Write-Warn 'Сохранённой папки нет — укажите путь.'
            continue
        }
        try {
            $roots = @(Normalize-AllowedRootsInput -InputText $raw)
            Set-DevSpaceAllowedRoots -Roots $roots
            return $true
        } catch { Write-Warn $_.Exception.Message }
    }
}

function Invoke-DevSpaceInitWithTty {
    param([string]$Command)

    # Do not pass a long interactive command directly through mintty/Start-Process.
    # On Windows the quoting layers can cause mintty to start and immediately exit.
    # A temporary Bash script gives DevSpace a real interactive terminal and also
    # guarantees that the window remains open long enough to show any error.
    $tempSh = Join-Path $env:TEMP ("devspace-launcher-init-{0}.sh" -f ([Guid]::NewGuid().ToString('N')))
    $oldCommand = $env:DEVSPACE_LAUNCHER_INIT_COMMAND
    $oldScriptPath = $env:DEVSPACE_LAUNCHER_INIT_SCRIPT
    try {
        $env:DEVSPACE_LAUNCHER_INIT_COMMAND = $Command
        $scriptBody = @'
#!/usr/bin/env bash
set +e
printf '\n==============================================================================\n'
printf '  DEVSPACE — ШТАТНЫЙ МАСТЕР НАСТРОЙКИ\n'
printf '==============================================================================\n\n'
eval "$DEVSPACE_LAUNCHER_INIT_COMMAND"
__devspace_ec=$?
printf '\n'
if [ "$__devspace_ec" -eq 0 ]; then
  printf 'DevSpace setup completed successfully.\n'
else
  printf 'DevSpace setup failed with exit code %s.\n' "$__devspace_ec"
fi
printf '\nPress Enter to close this Git Bash window and return to the launcher...\n'
read -r
exit "$__devspace_ec"
'@
        # Git Bash handles UTF-8 scripts without BOM more reliably.
        [IO.File]::WriteAllText($tempSh, $scriptBody.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
        $env:DEVSPACE_LAUNCHER_INIT_SCRIPT = $tempSh

        $cyg = Invoke-Native -FilePath $script:GitBash -Arguments @('--login','-c','cygpath -u "$DEVSPACE_LAUNCHER_INIT_SCRIPT"') -AllowFailure -Quiet -FriendlyName 'Git Bash cygpath'
        if ($cyg.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($cyg.Output)) {
            throw 'Не удалось преобразовать путь временного setup-скрипта для Git Bash.'
        }
        $unixScript = (($cyg.Output -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()

        Write-Host ''
        Write-Host 'Открываю отдельное интерактивное окно Git Bash для штатного мастера DevSpace...' -ForegroundColor Green
        Write-Host 'Окно НЕ должно закрыться само: после мастера оно ждёт Enter и показывает код завершения.' -ForegroundColor Yellow
        Write-Host ''

        $proc = $null
        if ($script:GitMintty -and (Test-Path -LiteralPath $script:GitMintty -PathType Leaf)) {
            # Use one quoted argument string because Windows PowerShell 5.1 joins
            # ArgumentList items and otherwise loses quotes around paths with spaces.
            $safeUnix = $unixScript.Replace('"','\"')
            $argLine = '/usr/bin/bash --login -i "' + $safeUnix + '"'
            $proc = Start-Process -FilePath $script:GitMintty -ArgumentList $argLine -PassThru -Wait -ErrorAction Stop
        } else {
            Write-Warn 'mintty.exe не найден. Открываю Bash в отдельном Windows Console.'
            $safeUnix = $unixScript.Replace('"','\"')
            $argLine = '--login -i "' + $safeUnix + '"'
            $proc = Start-Process -FilePath $script:GitBash -ArgumentList $argLine -PassThru -Wait -ErrorAction Stop
        }

        if ($proc -and $proc.ExitCode -ne 0) {
            throw "DevSpace init завершился с кодом $($proc.ExitCode). Подробности были показаны в окне Git Bash."
        }
    } finally {
        try { Remove-Item -LiteralPath $tempSh -Force -ErrorAction SilentlyContinue } catch {}
        if ($null -eq $oldCommand) { Remove-Item Env:DEVSPACE_LAUNCHER_INIT_COMMAND -ErrorAction SilentlyContinue }
        else { $env:DEVSPACE_LAUNCHER_INIT_COMMAND = $oldCommand }
        if ($null -eq $oldScriptPath) { Remove-Item Env:DEVSPACE_LAUNCHER_INIT_SCRIPT -ErrorAction SilentlyContinue }
        else { $env:DEVSPACE_LAUNCHER_INIT_SCRIPT = $oldScriptPath }
    }
}

function Test-DevSpaceAllowedRootsConfigured {
    return (@(Get-DevSpaceAllowedRoots).Count -gt 0)
}

function Initialize-DevSpaceInteractive {
    param([string]$PublicOrigin, [switch]$Force)
    Write-Rule 'ПЕРВИЧНАЯ НАСТРОЙКА DEVSPACE'
    Write-Host 'Сейчас откроется штатный мастер DevSpace в отдельном окне Git Bash.' -ForegroundColor White
    Write-Host 'Он ОБЯЗАТЕЛЬНО должен спросить, какие папки разрешено открывать через ChatGPT.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Рекомендуемые ответы:' -ForegroundColor Yellow
    Write-Host '  • Где использовать: ChatGPT (или Both, если нужны и локальные Coding Agents).' -ForegroundColor Gray
    Write-Host '  • Project Roots: укажите только нужные папки проектов, НЕ C:\ и НЕ весь профиль.' -ForegroundColor Green
    Write-Host '    Именно эти папки сможет открывать и изменять ChatGPT через MCP.' -ForegroundColor Yellow
    Write-Host ("  • Public Base URL: {0}" -f $PublicOrigin) -ForegroundColor White
    Write-Host '    Здесь БЕЗ /mcp. После мастера скрипт сам ещё раз проверит URL.' -ForegroundColor Gray
    Write-Host ''

    $cmd = Get-DevSpaceCommand
    if ($Force) { $cmd += ' init --force' } else { $cmd += ' init' }
    Stop-Log
    try { Invoke-DevSpaceInitWithTty -Command $cmd }
    finally { Start-Log -Append }

    if (-not (Test-DevSpaceInitialized)) {
        throw 'DevSpace init завершился, но ~/.devspace/auth.json или config-файл не найден.'
    }
    if (-not (Test-DevSpaceAllowedRootsConfigured)) {
        Write-NoticeBox -Title 'НЕ ВЫБРАНЫ РАЗРЕШЁННЫЕ ПАПКИ DEVSPACE' -Lines @(
            'Для ChatGPT обязательно нужно выбрать хотя бы одну Project Root.'
            'Это граница доступа: MCP сможет открывать и изменять проекты только внутри этих папок.'
            'Не выбирайте C:\ целиком и не открывайте весь профиль пользователя без необходимости.'
            'Повторно запустите мастер, выберите ChatGPT или Both и укажите Project Roots.'
        )
        $again = (Read-Host 'Запустить штатный мастер DevSpace ещё раз сейчас? [Y/n]').Trim().ToLowerInvariant()
        if (-not $again -or $again -eq 'y' -or $again -eq 'yes') {
            Stop-Log
            try { Invoke-DevSpaceInitWithTty -Command ((Get-DevSpaceCommand) + ' init --force') }
            finally { Start-Log -Append }
        }
        if (-not (Test-DevSpaceAllowedRootsConfigured)) {
            throw 'Разрешённые папки Project Roots не настроены. Запуск MCP остановлен, чтобы не продолжать с неправильной областью доступа.'
        }
    }
    Write-Ok 'DevSpace инициализирован; разрешённые Project Roots настроены.'
}

function Set-DevSpacePublicUrl {
    param([string]$PublicOrigin)
    $cmd = Get-DevSpaceCommand
    $quoted = Escape-BashSingleQuote $PublicOrigin
    Write-Info "Записываю publicBaseUrl = $PublicOrigin"
    Invoke-GitBash -Command ("{0} config set publicBaseUrl {1}" -f $cmd, $quoted) | Out-Null
}

function Invoke-DevSpaceDoctor {
    $cmd = Get-DevSpaceCommand
    Write-Info 'Запускаю devspace doctor...'
    $r = Invoke-GitBash -Command ("$cmd doctor") -AllowFailure
    if ($r.ExitCode -eq 0) {
        Write-Ok 'devspace doctor: проверка пройдена.'
        return $true
    }
    if ($r.Output -match 'better-sqlite3') {
        Write-Warn 'Doctor указал на better-sqlite3. Пробую штатную пересборку глобального пакета.'
        $npm = Get-CommandPath -Name 'npm.cmd'
        if ($npm) {
            Invoke-Native -FilePath $npm -Arguments @('rebuild','-g','@waishnav/devspace') -AllowFailure | Out-Null
            $retry = Invoke-GitBash -Command ("$cmd doctor") -AllowFailure
            if ($retry.ExitCode -eq 0) { Write-Ok 'После rebuild devspace doctor пройден.'; return $true }
        }
    }
    Write-Warn 'devspace doctor сообщил ошибку. Полный вывод показан выше.'
    return $false
}

function Load-Settings {
    $obj = [ordered]@{ TunnelId=''; KeyFilePath=''; RuntimeKeyFingerprint=''; AdminKeyFingerprint='' }
    if (Test-Path -LiteralPath $SettingsPath) {
        try {
            $j = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
            if ($j.TunnelId) { $obj.TunnelId = [string]$j.TunnelId }
            if ($j.KeyFilePath) { $obj.KeyFilePath = [string]$j.KeyFilePath }
            if ($j.RuntimeKeyFingerprint) { $obj.RuntimeKeyFingerprint = [string]$j.RuntimeKeyFingerprint }
            if ($j.AdminKeyFingerprint) { $obj.AdminKeyFingerprint = [string]$j.AdminKeyFingerprint }
        } catch { Write-Warn "Не удалось прочитать настройки Secure Tunnel: $($_.Exception.Message)" }
    }
    return $obj
}

function Save-Settings {
    param($Settings)
    $Settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $SettingsPath -Encoding UTF8
}













function Test-DevSpacePort {
    try {
        $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if (-not $listeners) { return }
        foreach ($l in $listeners) {
            $ownerPid = $l.OwningProcess
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ownerPid" -ErrorAction SilentlyContinue
            if ($p -and $p.CommandLine -match '(?i)devspace') {
                Write-Warn "Найден старый DevSpace на порту $Port (PID $ownerPid). Останавливаю его."
                Stop-Process -Id $ownerPid -Force -ErrorAction Stop
            } else {
                $name = if ($p) { $p.Name } else { 'неизвестный процесс' }
                throw "Порт $Port уже занят процессом $name (PID $ownerPid). Освободите порт и запустите скрипт снова."
            }
        }
    } catch {
        if ($_.Exception.Message -match 'Порт') { throw }
        Write-Warn "Не удалось проверить порт $Port через Get-NetTCPConnection: $($_.Exception.Message)"
    }
}









function Show-ConnectionCard {
    param([string]$TunnelId)
    Write-Rule 'SECURE MCP TUNNEL — ПОДКЛЮЧЕНИЕ'
    Write-Host ("  Tunnel ID       : {0}" -f $TunnelId) -ForegroundColor Green
    Write-Host ("  DevSpace        : http://127.0.0.1:{0}/mcp" -f $Port)
    Write-Host ("  OAuth bridge    : http://127.0.0.1:{0}/mcp" -f $script:BridgePort)
    Write-Host ("  Tunnel dashboard: http://127.0.0.1:{0}/ui" -f $script:HealthPort) -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'ChatGPT → Settings → Plugins → Add custom MCP server:' -ForegroundColor Yellow
    Write-Host '  Connection: Tunnel' -ForegroundColor White
    Write-Host ("  Tunnel:     {0}" -f $TunnelId) -ForegroundColor White
    Write-Host '  Authentication: No authentication / Unauthenticated' -ForegroundColor White
    Write-Host '  Name:       DevSpacePC (Secure Tunnel)' -ForegroundColor White
    Write-Host ''
    Write-Host 'Для проверки подключения используйте open_workspace.' -ForegroundColor Yellow
    Write-Host 'Токены DevSpace находятся только в памяти OAuth bridge и не сохраняются.' -ForegroundColor Gray
}

function Show-VersionSummary {
    param([string]$Winget, [pscustomobject]$NodeInfo, [string]$DevSpaceVersion)
    Write-Rule 'ПРОВЕРКА КОМПОНЕНТОВ'
    $git = Get-CommandPath -Name 'git.exe'
    $gv = if ($git) { (Invoke-Native -FilePath $git -Arguments @('--version') -Quiet).Output.Trim() } else { 'не найден' }
    Write-Host ("  Git      : {0}" -f $gv)
    Write-Host ("  Git Bash : {0}" -f $script:GitBash)
    Write-Host ("  Node.js  : {0} ({1} LTS)" -f $NodeInfo.Version, $NodeInfo.Lts)
    Write-Host ("  tunnel   : {0}" -f $script:TunnelExe)
    Write-Host ("  DevSpace : {0}" -f $DevSpaceVersion)
    Write-Host ("  Log      : {0}" -f $LogPath) -ForegroundColor DarkGray
}

function Run-DiagnosticsOnly {
    Write-Rule 'ДИАГНОСТИКА DEVSPACE'
    if (-not (Test-DevSpaceInitialized)) {
        Write-Warn 'DevSpace ещё не инициализирован.'
    } else {
        [void](Invoke-DevSpaceDoctor)
    }
    Write-Host ''
    Write-Host 'Нажмите Enter для возврата в меню.' -ForegroundColor Gray
    [void](Read-Host)
}

function Open-DevSpaceNativeSettings {
    Write-Rule 'ШТАТНЫЕ НАСТРОЙКИ DEVSPACE'
    Write-Host 'Откроется официальный мастер DevSpace.' -ForegroundColor Green
    Write-Host 'В нём можно выбрать ChatGPT / Coding Agents и настроить доступные локальные агенты.' -ForegroundColor White
    Write-Host 'Для полной перенастройки используется штатная команда devspace init --force.' -ForegroundColor Gray
    Write-Host ''
    $cmd = (Get-DevSpaceCommand) + ' init --force'
    Stop-Log
    try { Invoke-DevSpaceInitWithTty -Command $cmd }
    finally { Start-Log -Append }
    Write-Host ''
    Write-Host 'Нажмите Enter для возврата в главное меню.' -ForegroundColor Gray
    [void](Read-Host)
}

function Ensure-DevSpaceInitializedForLauncher {
    if (Test-DevSpaceInitialized) { return $true }
    Write-NoticeBox -Title 'ПЕРВАЯ ИНИЦИАЛИЗАЦИЯ DEVSPACE' -Lines @(
        'Откроется официальный мастер DevSpace.'
        'Адрес DevSpace для локальной настройки: http://127.0.0.1:7676.'
        'Разрешённые папки задаются отдельно в следующем шаге.'
    )
    $cmd = (Get-DevSpaceCommand) + ' init'
    Stop-Log
    try { Invoke-DevSpaceInitWithTty -Command $cmd }
    finally { Start-Log -Append }
    if (-not (Test-DevSpaceInitialized)) { Write-Warn 'DevSpace init не создал конфигурацию.'; return $false }
    return $true
}

function Configure-LaunchWizard {
    param($Settings)
    if (-not (Ensure-DevSpaceInitializedForLauncher)) { return $false }
    if (-not (Select-AllowedRootsInteractive)) { return $false }
    if (-not (Select-TunnelCredentials -Settings $Settings)) { return $false }
    return $true
}

function Stop-DevSpaceServerBackground {
    try {
        if ($script:DevSpaceProcess -and -not $script:DevSpaceProcess.HasExited) {
            Write-Info 'Останавливаю DevSpace MCP server...'
            $pidToStop = [int]$script:DevSpaceProcess.Id
            try {
                $tk = Start-Process -FilePath "$env:SystemRoot\System32\taskkill.exe" -ArgumentList @('/PID', [string]$pidToStop, '/T', '/F') -PassThru -Wait -WindowStyle Hidden
            } catch {
                try { $script:DevSpaceProcess.Kill() } catch {}
            }

            # If a Node process detached from Bash, terminate the listener owned
            # by this MCP session as a final local cleanup.
            for ($i=0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 150
                $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
                if (-not $listener) { break }

                if ($i -ge 10) {
                    foreach ($entry in @($listener)) {
                        $ownerPid = [int]$entry.OwningProcess
                        if ($ownerPid -gt 0 -and $ownerPid -ne $PID) {
                            try { Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue } catch {}
                        }
                    }
                }
            }

            Write-Ok 'DevSpace MCP server остановлен.'
        }
    } catch {
        Write-Warn "Не удалось штатно остановить DevSpace server: $($_.Exception.Message)"
    } finally {
        $script:DevSpaceProcess = $null
        $script:DevSpaceJobProtected = $false
        Save-RuntimeState
        # Stop watchdog only after the server tree has been cleaned up. If the
        # launcher dies during cleanup, watchdog still revokes access.
        Stop-DevSpaceWatchdog
    }
}



function Show-DevSpaceServerFailureLogs {
    if ($script:DevSpaceStdOut -and (Test-Path -LiteralPath $script:DevSpaceStdOut)) {
        $txt = Get-Content -LiteralPath $script:DevSpaceStdOut -Raw -ErrorAction SilentlyContinue
        if ($txt) { Write-Host "`n--- DevSpace stdout ---" -ForegroundColor Red; Write-Host $txt }
    }
    if ($script:DevSpaceStdErr -and (Test-Path -LiteralPath $script:DevSpaceStdErr)) {
        $txt = Get-Content -LiteralPath $script:DevSpaceStdErr -Raw -ErrorAction SilentlyContinue
        if ($txt) { Write-Host "`n--- DevSpace stderr ---" -ForegroundColor Red; Write-Host $txt }
    }
}

function Start-DevSpaceServerBackground {
    Test-DevSpacePort
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:DevSpaceStdOut = Join-Path $LogDir "devspace-serve-$stamp.stdout.log"
    $script:DevSpaceStdErr = Join-Path $LogDir "devspace-serve-$stamp.stderr.log"
    $cmd = Get-DevSpaceCommand
    $serverCommand = "$cmd serve"

    Write-Info 'Запускаю DevSpace MCP server в управляемом фоновом процессе.'
    $oldConv = $env:MSYS2_ARG_CONV_EXCL
    $env:MSYS2_ARG_CONV_EXCL = '*'

    $watchdogReady = $false
    try {
        # Start-Process joins ArgumentList elements without preserving quotes around
        # a command containing spaces, therefore pass one explicitly quoted line.
        $argLine = '--login -c "' + $serverCommand.Replace('"','\"') + '"'
        $script:DevSpaceProcess = Start-Process -FilePath $script:GitBash -ArgumentList $argLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $script:DevSpaceStdOut -RedirectStandardError $script:DevSpaceStdErr

        # Job Object assignment is best-effort for Git Bash. A process can
        # already belong to another job (for example because of its host/MSYS
        # environment), in which case Windows may reject another assignment.
        # Do not abort a perfectly valid DevSpace launch because of that.
        $script:DevSpaceJobProtected = Try-RegisterManagedProcess -Process $script:DevSpaceProcess -Name 'DevSpace Git Bash launcher'

        # Independent watchdog is the cross-environment safety net. It observes
        # this launcher process and kills the complete DevSpace process tree if
        # the console is closed, Ctrl+C terminates the launcher, or PowerShell
        # crashes before normal cleanup can run.
        $watchdogReady = Start-DevSpaceWatchdog -DevSpaceLauncherPid ([int]$script:DevSpaceProcess.Id)

        if (-not $script:DevSpaceJobProtected -and -not $watchdogReady) {
            try {
                & "$env:SystemRoot\System32\taskkill.exe" /PID $script:DevSpaceProcess.Id /T /F *> $null
            } catch {}
            throw 'Не удалось включить ни Windows Job Object, ни watchdog. Сервер остановлен, потому что launcher не может гарантировать отключение MCP при закрытии консоли.'
        }
    } finally {
        if ($null -eq $oldConv) { Remove-Item Env:MSYS2_ARG_CONV_EXCL -ErrorAction SilentlyContinue }
        else { $env:MSYS2_ARG_CONV_EXCL = $oldConv }
    }

    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 250

        if ($script:DevSpaceProcess.HasExited) {
            Show-DevSpaceServerFailureLogs
            Stop-DevSpaceWatchdog
            throw "DevSpace server завершился сразу после запуска с кодом $($script:DevSpaceProcess.ExitCode)."
        }

        $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($listener) {
            # Attach the actual listener to our Job Object when Windows permits
            # it. Failure is non-fatal because watchdog already tracks the Bash
            # process tree and also clears any remaining listener on port 7676.
            $listenerPids = @($listener | Select-Object -ExpandProperty OwningProcess -Unique)
            foreach ($listenerPid in $listenerPids) {
                if ($listenerPid -and ($listenerPid -ne $PID)) {
                    [void](Try-RegisterManagedPid -ProcessId ([int]$listenerPid) -Name 'DevSpace MCP listener')
                }
            }

            Write-Ok "DevSpace MCP server запущен и слушает порт $Port."
            Save-RuntimeState
            if ($script:DevSpaceJobProtected -and $watchdogReady) {
                Write-Info 'Защита доступа активна: Windows Job Object + независимый watchdog.'
            } elseif ($watchdogReady) {
                Write-Info 'Защита доступа активна: независимый watchdog (Job Object для Git Bash недоступен в этой среде).'
            } else {
                Write-Info 'Защита доступа активна: Windows Job Object.'
            }
            Write-Info 'Закрытие этого окна или Ctrl+C автоматически остановит DevSpace и Secure MCP Tunnel.'
            return
        }
    }

    Show-DevSpaceServerFailureLogs
    Stop-DevSpaceServerBackground
    throw "DevSpace server не открыл порт $Port за 15 секунд. Полный вывод сохранён в $LogDir"
}

function Restart-DevSpaceServerForRoots {
    Write-Rule 'ПЕРЕЗАПУСК DEVSPACE С НОВЫМИ ПАПКАМИ'
    Stop-DevSpaceServerBackground
    Start-DevSpaceServerBackground
    Write-Ok 'Новые разрешённые папки применены. DevSpace MCP server перезапущен.'
}

function Show-RunningServerMenu {
    param([string]$TunnelId)
    while ($true) {
        Write-Rule 'DEVSPACE MCP — SECURE TUNNEL ЗАПУЩЕН'
        $roots = @(Get-DevSpaceAllowedRoots)
        Write-AccessWarningBox -Roots $roots
        Write-Host ("  Tunnel ID : {0}" -f $TunnelId) -ForegroundColor Green
        Write-Host ("  DevSpace  : http://127.0.0.1:{0}/mcp" -f $Port) -ForegroundColor Green
        Write-Host ("  Tunnel UI : http://127.0.0.1:{0}/ui" -f $script:HealthPort) -ForegroundColor Cyan
        Write-Host '  Закрытие окна / Ctrl+C останавливает DevSpace, OAuth bridge и tunnel-client.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  [1] Изменить разрешённые папки (перезапуск DevSpace и OAuth bridge)' -ForegroundColor Green
        Write-Host '  [0] Остановить всё и вернуться в главное меню' -ForegroundColor Yellow
        $choice = (Read-Host 'Выбор').Trim()
        switch ($choice) {
            '1' {
                $before = @($roots | ForEach-Object { $_.ToLowerInvariant() }) -join '|'
                $selected = Select-AllowedRootsInteractive -BackLabel 'меню запущенного сервера'
                if (-not $selected) { continue }
                $after = @(Get-DevSpaceAllowedRoots | ForEach-Object { $_.ToLowerInvariant() }) -join '|'
                if ($before -ne $after) {
                    Write-Info 'Перезапускаю всю сессию, чтобы OAuth-грант соответствовал новым папкам.'
                    return 'restart'
                }
            }
            '0' { return 'stop' }
            default { Write-Warn 'Введите 1 или 0.' }
        }
    }
}

function Show-DevSpaceOwnerPassword {
    # Call only while Start-Transcript is stopped. This is a local secret and
    # must never end up in the launcher logs or subprocess command lines.
    $authPath = Join-Path $env:USERPROFILE '.devspace\auth.json'
    Write-NoticeBox -Title 'ПАРОЛЬ ДЛЯ ПОДКЛЮЧЕНИЯ DEVSPACE' -Lines @(
        'Owner Password создан локальным DevSpace при первоначальной настройке.'
        'Он НЕ является OpenAI API key, Admin key или Tunnel ID.'
        'Вставьте значение ниже в поле Owner password в открывшемся браузере.'
        'Никому не отправляйте этот пароль и не публикуйте скриншоты с ним.'
    )
    if (-not (Test-Path -LiteralPath $authPath -PathType Leaf)) {
        Write-Warn ("Файл с Owner Password не найден: {0}" -f $authPath)
        Write-Host 'Настройте DevSpace через его штатный мастер (пункт 2 главного меню).' -ForegroundColor Yellow
        return
    }
    $ownerPassword = $null
    try {
        $auth = Get-Content -LiteralPath $authPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $ownerPassword = [string]$auth.ownerToken
    } catch {
        Write-Warn 'Не удалось прочитать ownerToken из auth.json. Проверьте штатную настройку DevSpace.'
        return
    }
    if ([string]::IsNullOrWhiteSpace($ownerPassword)) {
        Write-Warn 'В auth.json отсутствует ownerToken. Запустите штатную настройку DevSpace.'
        return
    }
    Write-Host 'Owner Password (для копирования в браузер):' -ForegroundColor Cyan
    Write-Host ("  {0}" -f $ownerPassword) -ForegroundColor Magenta
    Write-Host ("Файл: {0}" -f $authPath) -ForegroundColor DarkGray
    Write-Host 'Пароль показан только в консоли; в журнал запуска не записывается.' -ForegroundColor DarkGray
    Write-Host ''
}

function Start-DevSpaceOAuthBridge {
    Write-Step 'DevSpace OAuth: локальный мост на 127.0.0.1'
    $file = Join-Path $RuntimeDir 'devspace-oauth-bridge.js'
    $js = @'
'use strict';
// Generated at runtime by the DevSpace Secure MCP Tunnel launcher.
// OAuth credentials are kept only in this process memory; no extra Docker container.
const http = require('node:http');
const { createHash, randomBytes } = require('node:crypto');
const { URL, URLSearchParams } = require('node:url');
const upstream = new URL(process.env.DEVSPACE_BRIDGE_UPSTREAM || 'http://127.0.0.1:7676');
const port = Number(process.env.DEVSPACE_BRIDGE_PORT || '7677');
const localOrigin = `http://127.0.0.1:${port}`;
const resource = new URL('/mcp', upstream).toString();
let client, oauth, accessToken = '', refreshToken = '', expiry = 0;
let challengeState, codeVerifier;
const log = (msg) => process.stdout.write(`${msg}\n`);
function localEndpoint(raw) {
  const value = new URL(raw, upstream);
  if (value.origin !== upstream.origin) throw new Error('OAuth metadata advertised an unexpected non-local origin');
  return value.toString();
}
async function jsonRequest(url, options) {
  const r = await fetch(url, { ...options, redirect: 'manual', signal: AbortSignal.timeout(10000) });
  const raw = await r.text();
  if (!r.ok) throw new Error(`OAuth HTTP ${r.status} at ${new URL(url).pathname}`);
  try { return JSON.parse(raw); } catch { throw new Error('OAuth endpoint returned invalid JSON'); }
}
async function initializeOAuth() {
  let meta;
  for (const path of ['/.well-known/oauth-authorization-server', '/.well-known/oauth-authorization-server/mcp']) {
    const r = await fetch(new URL(path, upstream), { redirect: 'manual', signal: AbortSignal.timeout(10000) });
    if (r.status === 404) continue;
    if (!r.ok) throw new Error(`OAuth discovery failed: ${r.status}`);
    meta = await r.json();
    break;
  }
  if (!meta) throw new Error('DevSpace OAuth authorization-server metadata is missing');
  oauth = {
    authorization_endpoint: localEndpoint(meta.authorization_endpoint),
    registration_endpoint: localEndpoint(meta.registration_endpoint || '/register'),
    token_endpoint: localEndpoint(meta.token_endpoint),
  };
  client = await jsonRequest(oauth.registration_endpoint, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ client_name: 'DevSpace private tunnel launcher',
      redirect_uris: [`${localOrigin}/callback`], response_types: ['code'],
      grant_types: ['authorization_code', 'refresh_token'],
      token_endpoint_auth_method: 'none', application_type: 'native' }),
  });
  if (!client.client_id) throw new Error('OAuth DCR returned no client_id');
  codeVerifier = randomBytes(48).toString('base64url');
  challengeState = randomBytes(24).toString('hex');
  const url = new URL(oauth.authorization_endpoint);
  for (const [k, v] of Object.entries({ response_type: 'code', client_id: client.client_id,
    redirect_uri: `${localOrigin}/callback`, code_challenge: createHash('sha256').update(codeVerifier).digest('base64url'),
    code_challenge_method: 'S256', state: challengeState, scope: 'devspace', resource })) url.searchParams.set(k, v);
  log(`AUTH_URL=${url}`);
}
async function exchange(fields) {
  if (client.client_secret) fields.client_secret = client.client_secret;
  fields.client_id = client.client_id;
  const data = await jsonRequest(oauth.token_endpoint, {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(fields),
  });
  if (!data.access_token) throw new Error('OAuth token response contains no access_token');
  accessToken = data.access_token;
  if (data.refresh_token) refreshToken = data.refresh_token;
  expiry = Date.now() + Math.max(60, Number(data.expires_in || 3600)) * 1000;
}
let refreshing;
async function ensureToken() {
  if (accessToken && Date.now() < expiry - 60000) return;
  if (!refreshToken) throw new Error('OAuth token unavailable; restart launcher and authorize');
  if (!refreshing) refreshing = exchange({ grant_type: 'refresh_token', refresh_token: refreshToken,
    resource }).finally(() => { refreshing = undefined; });
  await refreshing;
}
function send(res, status, text, type = 'text/plain; charset=utf-8') {
  res.writeHead(status, { 'content-type': type, 'cache-control': 'no-store' });
  res.end(text);
}
async function onRequest(req, res) {
  let path;
  try { path = new URL(req.url, localOrigin); } catch { send(res, 400, 'Bad request'); return; }
  if (path.pathname === '/healthz') { send(res, 200, 'alive'); return; }
  if (path.pathname === '/readyz') { send(res, accessToken ? 200 : 503, accessToken ? 'ready' : 'awaiting OAuth'); return; }
  if (path.pathname === '/callback') {
    if (!challengeState || path.searchParams.get('state') !== challengeState || !path.searchParams.get('code')) {
      send(res, 400, 'Invalid authorization state/code'); return;
    }
    // One-shot authorization code: reject callbacks replayed with the same state.
    const code = path.searchParams.get('code');
    challengeState = '';
    try {
      await exchange({ grant_type: 'authorization_code', code, redirect_uri: `${localOrigin}/callback`,
        code_verifier: codeVerifier, resource });
      codeVerifier = '';
      send(res, 200, '<h3>DevSpace: OAuth authorized</h3><p>You can close this tab.</p>', 'text/html; charset=utf-8');
      log('AUTH_OK');
    } catch (e) { send(res, 502, 'OAuth token exchange failed; check launcher logs'); log(`ERROR=${e.message}`); }
    return;
  }
  if (path.pathname !== '/mcp' || path.search) { send(res, 404, 'Not Found'); return; }
  if (!accessToken) { send(res, 503, 'DevSpace authorization not completed'); return; }
  try { await ensureToken(); }
  catch (e) { log(`ERROR=${e.message}`); send(res, 503, 'DevSpace OAuth refresh failed'); return; }
  const headers = { ...req.headers, host: upstream.host, authorization: `Bearer ${accessToken}` };
  for (const k of Object.keys(headers)) {
    if (/^(connection|proxy-connection|keep-alive|te|trailer|transfer-encoding|upgrade|forwarded|x-forwarded-.*|proxy-authorization)$/i.test(k)) delete headers[k];
  }
  const target = new URL('/mcp', upstream);
  const proxy = http.request(target, { method: req.method, headers, timeout: 110000 }, (r) => {
    const reply = { ...r.headers };
    for (const h of ['connection', 'transfer-encoding', 'keep-alive']) delete reply[h];
    res.writeHead(r.statusCode || 502, reply);
    r.pipe(res);
  });
  proxy.on('timeout', () => proxy.destroy(new Error('upstream timeout')));
  proxy.on('error', (e) => { log(`ERROR=upstream proxy: ${e.message}`); if (!res.headersSent) send(res, 502, 'DevSpace unreachable'); else res.destroy(); });
  req.pipe(proxy);
}
async function main() {
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid bridge port');
  const server = http.createServer((req, res) => { onRequest(req, res).catch((e) => { log(`ERROR=${e.message}`); if (!res.headersSent) send(res, 500, 'Internal proxy error'); else res.destroy(); }); });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  log(`BRIDGE_LISTENING=${localOrigin}`);
  await initializeOAuth();
}
main().catch((e) => { log(`ERROR=${e.message}`); process.exitCode = 1; });
'@
    [IO.File]::WriteAllText($file, $js, (New-Object Text.UTF8Encoding($false)))
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:BridgeStdOut = Join-Path $LogDir "devspace-bridge-$stamp.stdout.log"
    $script:BridgeStdErr = Join-Path $LogDir "devspace-bridge-$stamp.stderr.log"
    $node = Get-CommandPath -Name 'node.exe'
    if (-not $node) { throw 'Node.js не найден для OAuth моста.' }
    $oldPort = [Environment]::GetEnvironmentVariable('DEVSPACE_BRIDGE_PORT','Process')
    $oldUrl = [Environment]::GetEnvironmentVariable('DEVSPACE_BRIDGE_UPSTREAM','Process')
    try {
        [Environment]::SetEnvironmentVariable('DEVSPACE_BRIDGE_PORT', [string]$script:BridgePort,'Process')
        [Environment]::SetEnvironmentVariable('DEVSPACE_BRIDGE_UPSTREAM', "http://127.0.0.1:$Port",'Process')
        $script:BridgeProcess = Start-Process -FilePath $node -ArgumentList ('"' + $file + '"') -PassThru -WindowStyle Hidden -RedirectStandardOutput $script:BridgeStdOut -RedirectStandardError $script:BridgeStdErr
        Register-ManagedProcess -Process $script:BridgeProcess -Name 'DevSpace OAuth bridge'
        Save-RuntimeState
    } finally {
        [Environment]::SetEnvironmentVariable('DEVSPACE_BRIDGE_PORT', $oldPort,'Process')
        [Environment]::SetEnvironmentVariable('DEVSPACE_BRIDGE_UPSTREAM', $oldUrl,'Process')
    }
    $authUrl = ''
    $opened = $false
    for ($i = 0; $i -lt 180; $i++) {
        if ($script:BridgeProcess.HasExited) {
            Show-SecureTunnelLogs
            $tail = @(Get-Content -LiteralPath $script:BridgeStdOut -Tail 12 -ErrorAction SilentlyContinue) -join '; '
            throw "Локальный OAuth мост завершился. $tail"
        }
        if (Test-LocalReady -Url ("http://127.0.0.1:{0}/readyz" -f $script:BridgePort)) {
            Write-Ok 'Авторизация DevSpace подтверждена; OAuth bearer в памяти моста.'
            return
        }
        if (Test-Path -LiteralPath $script:BridgeStdOut) {
            $lines = @(Get-Content -LiteralPath $script:BridgeStdOut -Tail 8 -ErrorAction SilentlyContinue)
            $authLine = @($lines | Where-Object { $_ -match '^AUTH_URL=' }) | Select-Object -Last 1
            if (-not $opened -and $authLine) {
                $authUrl = ([string]$authLine).Substring('AUTH_URL='.Length)
                $opened = $true
                Stop-Log
                try {
                    Write-Host 'Для авторизации понадобится Owner Password DevSpace.' -ForegroundColor Yellow
                    Show-DevSpaceOwnerPassword
                    Write-Host "Авторизация: $authUrl" -ForegroundColor Cyan
                    try { Start-Process -FilePath $authUrl -ErrorAction Stop | Out-Null }
                    catch { Write-Warn 'Не удалось открыть браузер автоматически; откройте ссылку выше вручную.' }
                } finally { Start-Log -Append }
            }
            $errors = @($lines | Where-Object { $_ -match '^ERROR=' })
            if ($errors.Count -gt 0) { throw ("OAuth bridge: {0}" -f $errors[-1]) }
        }
        Start-Sleep -Seconds 1
    }
    throw 'Авторизация DevSpace не завершена за 180 секунд. Запуск остановлен.'
}

function Start-SecureTunnel {
    param([Parameter(Mandatory=$true)][string]$TunnelId)
    Write-Step 'OpenAI Secure MCP Tunnel: подключение'
    $bridgeUrl = 'http://127.0.0.1:{0}/mcp' -f $script:BridgePort
    $health = 'http://127.0.0.1:{0}/readyz' -f $script:HealthPort
    if (-not $script:RuntimeKey) { throw 'Runtime API key отсутствует.' }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:TunnelStdOut = Join-Path $LogDir "devspace-tunnel-$stamp.stdout.log"
    $script:TunnelStdErr = Join-Path $LogDir "devspace-tunnel-$stamp.stderr.log"
    $oldKey = [Environment]::GetEnvironmentVariable('CONTROL_PLANE_API_KEY','Process')
    try {
        [Environment]::SetEnvironmentVariable('CONTROL_PLANE_API_KEY', $script:RuntimeKey,'Process')
        $args = @('run','--control-plane.tunnel-id',$TunnelId,'--mcp.server-url',$bridgeUrl,
            '--health.listen-addr',("127.0.0.1:{0}" -f $script:HealthPort))
        $script:TunnelProcess = Start-Process -FilePath $script:TunnelExe -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $script:TunnelStdOut -RedirectStandardError $script:TunnelStdErr
        Register-ManagedProcess -Process $script:TunnelProcess -Name 'DevSpace Secure Tunnel'
        Save-RuntimeState
    } finally {
        [Environment]::SetEnvironmentVariable('CONTROL_PLANE_API_KEY', $oldKey,'Process')
        $script:RuntimeKey = $null
    }
    for ($i = 0; $i -lt 45; $i++) {
        if ($script:TunnelProcess.HasExited) {
            Show-SecureTunnelLogs
            throw "tunnel-client завершился (exit $($script:TunnelProcess.ExitCode))."
        }
        if (Test-LocalReady -Url $health) {
            Write-Ok "Secure MCP Tunnel готов и опрашивает OpenAI: $TunnelId"
            return
        }
        Start-Sleep -Seconds 1
    }
    Show-SecureTunnelLogs
    throw 'tunnel-client запущен, но /readyz не стал готовым за 45 секунд.'
}

function Stop-SecureTunnel {
    try {
        if ($script:TunnelProcess -and -not $script:TunnelProcess.HasExited) {
            [void](Stop-ProcessTreeTargeted -ProcessId ([int]$script:TunnelProcess.Id) -Label 'DevSpace Secure Tunnel' -Quiet)
        }
        if ($script:BridgeProcess -and -not $script:BridgeProcess.HasExited) {
            [void](Stop-ProcessTreeTargeted -ProcessId ([int]$script:BridgeProcess.Id) -Label 'DevSpace OAuth bridge' -Quiet)
        }
    } finally {
        $script:TunnelProcess = $null
        $script:BridgeProcess = $null
        Save-RuntimeState
        if (-not $script:TunnelProcess -and -not $script:BridgeProcess -and -not $script:DevSpaceProcess -and -not $script:DevSpaceWatchdogProcess) { Clear-RuntimeState }
    }
}

function Start-DevSpaceSession {
    param([string]$Winget, $Settings)
    try {
        # No public OAuth issuer: DevSpace OAuth is completed locally by the bridge.
        Set-DevSpacePublicUrl -PublicOrigin ("http://127.0.0.1:{0}" -f $Port)
        if (-not (Test-DevSpaceAllowedRootsConfigured)) {
            throw 'Project Roots не настроены; запуск DevSpace остановлен.'
        }
        Write-Step 'Диагностика DevSpace'
        $doctorOk = Invoke-DevSpaceDoctor
        if (-not $doctorOk) { throw 'DevSpace doctor сообщил ошибку. Исправьте её перед запуском.' }
        Start-DevSpaceServerBackground
        Start-DevSpaceOAuthBridge
        Start-SecureTunnel -TunnelId $Settings.TunnelId
        Show-ConnectionCard -TunnelId $Settings.TunnelId
        return (Show-RunningServerMenu -TunnelId $Settings.TunnelId)
    } finally {
        Stop-SecureTunnel
        Stop-DevSpaceServerBackground
    }
}

function Show-MainMenu {
    param($Settings)
    while ($true) {
        Write-Rule 'DEVSPACE MCP — ГЛАВНОЕ МЕНЮ'
        Write-Host '  [1] Запустить DevSpace через OpenAI Secure MCP Tunnel' -ForegroundColor Green
        Write-Host '      Папки → ключи из .env → ID туннеля → OAuth → запуск' -ForegroundColor Gray
        Write-Host '  [2] Штатные настройки DevSpace' -ForegroundColor White
        Write-Host '  [3] Диагностика DevSpace' -ForegroundColor White
        Write-Host '  [0] Выход' -ForegroundColor DarkGray
        $choice = (Read-Host 'Выбор [1]').Trim()
        if (-not $choice) { $choice = '1' }
        switch ($choice) {
            '1' {
                if (Configure-LaunchWizard -Settings $Settings) {
                    return [pscustomobject]@{ Action='start' }
                }
            }
            '2' { Open-DevSpaceNativeSettings }
            '3' { Run-DiagnosticsOnly }
            '0' { return [pscustomobject]@{ Action='exit' } }
            default { Write-Warn 'Выберите 1, 2, 3 или 0.' }
        }
    }
}

function Prepare-PowerShellPolicy {
    Write-Step 'PowerShell: политика выполнения и Mark of the Web'
    try {
        $current = Get-ExecutionPolicy -Scope CurrentUser
        if ($current -ne 'RemoteSigned' -and $current -ne 'Unrestricted' -and $current -ne 'Bypass') {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop
            Write-Ok 'CurrentUser ExecutionPolicy = RemoteSigned.'
        } else {
            Write-Ok "ExecutionPolicy уже подходит: $current"
        }
    } catch {
        Write-Warn "Не удалось изменить ExecutionPolicy (возможно, действует Group Policy): $($_.Exception.Message)"
        Write-Info 'Это не блокирует данный .cmd: он уже запускает встроенный PowerShell с -ExecutionPolicy Bypass.'
    }
    try {
        Unblock-File -LiteralPath $ScriptPath -ErrorAction Stop
        Write-Ok 'Mark of the Web для этого файла снят (если был).'
    } catch {
        Write-Warn "Unblock-File не выполнен: $($_.Exception.Message)"
    }
}

function Show-RecoverableError {
    param([Parameter(Mandatory=$true)]$ErrorRecord, [string]$Context = 'Операция')
    Write-Rule ("ОШИБКА — {0}" -f $Context)
    Write-Host $ErrorRecord.Exception.ToString() -ForegroundColor Red
    if ($ErrorRecord.ScriptStackTrace) {
        Write-Host ''
        Write-Host 'PowerShell stack:' -ForegroundColor DarkRed
        Write-Host $ErrorRecord.ScriptStackTrace -ForegroundColor DarkRed
    }
    Write-Host ''
    Write-Host ("Журнал: {0}" -f $LogPath) -ForegroundColor Yellow
    Write-Host 'Скрипт остаётся запущенным. Нажмите Enter, чтобы вернуться в главное меню.' -ForegroundColor Yellow
    [void](Read-Host)
}

# ------------------------------- MAIN -----------------------------------------
Start-Log
try {
    Clear-Host
    Write-Rule ("DEVSPACE MCP — SECURE TUNNEL v{0}" -f $ScriptVersion)
    Write-Host 'Локальный DevSpace + OAuth bridge + OpenAI Secure MCP Tunnel.'
    Write-Host ('.env рядом с CMD: {0}' -f $DotEnvPath) -ForegroundColor DarkGray
    Write-Host ("Журнал: {0}" -f $LogPath) -ForegroundColor DarkGray
    Invoke-StartupProcessCleanup
    Prepare-PowerShellPolicy
    $winget = Ensure-Winget
    Ensure-Git -Winget $winget
    $nodeInfo = Ensure-Node -Winget $winget
    Ensure-TunnelClient
    $devspaceVersion = Ensure-DevSpace -NodeInfo $nodeInfo
    Ensure-DevSpaceUtf8ShellPatch -NodeInfo $nodeInfo
    Show-VersionSummary -Winget $winget -NodeInfo $nodeInfo -DevSpaceVersion $devspaceVersion
    $settings = Load-Settings
    while ($true) {
        try { $menu = Show-MainMenu -Settings $settings }
        catch { Show-RecoverableError -ErrorRecord $_ -Context 'настройка запуска'; continue }
        if ($menu.Action -eq 'exit') { break }
        try {
            $outcome = Start-DevSpaceSession -Winget $winget -Settings $settings
            if ($outcome -eq 'restart') { continue }
        } catch {
            Show-RecoverableError -ErrorRecord $_ -Context 'запуск Secure MCP Tunnel'
            continue
        }
    }
    exit 0
} catch {
    Write-Rule 'ОШИБКА'
    Write-Host $_.Exception.ToString() -ForegroundColor Red
    Show-SecureTunnelLogs
    exit 1
} finally {
    try { Stop-SecureTunnel } catch {}
    try { Stop-DevSpaceServerBackground } catch {}
    try { Stop-DevSpaceWatchdog } catch {}
    try { [DevSpaceMcp.ProcessGuard]::Shutdown() } catch {}
    Stop-Log
}
