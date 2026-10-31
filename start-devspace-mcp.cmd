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
# DevSpace MCP all-in-one installer / launcher for Windows 10/11
# - no PowerShell execution-policy prerequisite: CMD bootstrap uses Bypass
# - idempotent dependency checks and installs
# - WinGet recovery chain
# - Git + Git Bash, compatible Node.js LTS, ngrok, DevSpace
# - ngrok authtoken + fixed/random tunnel
# - DevSpace init/config/doctor through Git Bash
# - full visible errors + transcript logs (secrets excluded where practical)
# -----------------------------------------------------------------------------

$ScriptPath = [IO.Path]::GetFullPath($env:DEVSPACE_BOOTSTRAP_FILE)
$ScriptDir  = Split-Path -Parent $ScriptPath
$Port       = 7676
$MinNode    = [Version]'22.19.0'
$MaxNode    = [Version]'27.0.0'
$MinNgrok   = [Version]'3.20.0'
$SettingsPath = Join-Path $ScriptDir 'devspace-mcp-settings.json'
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
$ScriptVersion = '1.3.9'

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
$script:NgrokExe = $null
$script:NgrokConfigPathHint = $null
$script:NgrokProcess = $null
$script:NgrokStdOut = $null
$script:NgrokStdErr = $null
$script:NgrokFailureLogsShown = $false
$script:DevSpaceProcess = $null
$script:DevSpaceStdOut = $null
$script:DevSpaceStdErr = $null
$script:DevSpaceWatchdogProcess = $null
$script:DevSpaceWatchdogStopFile = $null
$script:DevSpaceJobProtected = $false

# -----------------------------------------------------------------------------
# Process lifetime guard
#
# DevSpace and ngrok are intentionally attached to a Windows Job Object with
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. This gives us a security property that a
# PowerShell finally block alone cannot provide: if this launcher is terminated
# by Ctrl+C, the console window is closed, PowerShell crashes, or the launcher
# is otherwise killed, Windows closes the job handle and terminates the managed
# MCP/ngrok processes automatically.
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
            ngrok = Get-RuntimeProcessRecord -Process $script:NgrokProcess
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
        [pscustomobject]@{ Property='ngrok'; Label='старый ngrok MCP' }
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

function Stop-StaleNgrokForDevSpace {
    $stopped = 0

    try {
        $ngrokProcesses = @(Get-CimInstance Win32_Process -Filter "Name='ngrok.exe'" -ErrorAction SilentlyContinue)
    } catch {
        $ngrokProcesses = @()
    }

    foreach ($p in $ngrokProcesses) {
        $cmd = [string]$p.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }

        $targetsPort = (
            ($cmd -match ('(?i)\bhttp\b.*(?:\s|=)' + [regex]::Escape([string]$Port) + '(?:\s|$)')) -or
            ($cmd -match ('(?i)(?:\s|=)' + [regex]::Escape([string]$Port) + '(?:\s|$).*\bhttp\b'))
        )

        if ($targetsPort) {
            if (Stop-ProcessTreeTargeted -ProcessId ([int]$p.ProcessId) -Label 'старый ngrok-туннель DevSpace') {
                $stopped++
            }
        }
    }

    # MSIX can occasionally hide/normalize CommandLine. If Inspector confirms
    # that its only running tunnel forwards to our MCP port and there is exactly
    # one ngrok.exe, identify that process as ours.
    if ($stopped -eq 0 -and @($ngrokProcesses).Count -eq 1) {
        try {
            $tunnels = Invoke-RestMethod -Uri 'http://127.0.0.1:4040/api/tunnels' -TimeoutSec 1 -ErrorAction Stop
            $ours = @($tunnels.tunnels | Where-Object {
                $addr = [string]$_.config.addr
                $addr -match ('(?i)(?:^|:)' + [regex]::Escape([string]$Port) + '$')
            })

            if ($ours.Count -gt 0) {
                if (Stop-ProcessTreeTargeted -ProcessId ([int]$ngrokProcesses[0].ProcessId) -Label 'старый ngrok-туннель DevSpace') {
                    $stopped++
                }
            }
        } catch {}
    }

    return $stopped
}

function Invoke-StartupProcessCleanup {
    Write-Rule 'ПРЕДСТАРТОВАЯ ПРОВЕРКА ОСТАТОЧНЫХ ПРОЦЕССОВ'

    $total = 0
    $total += Stop-StaleProcessesFromRuntimeState
    $total += Stop-StaleLauncherWatchdogs
    $total += Stop-StaleDevSpaceListener
    $total += Stop-StaleNgrokForDevSpace

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

    # Keep the user's input visible in the console, but do not persist secrets
    # such as the ngrok Authtoken into Start-Transcript logs.
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

function Get-NgrokCandidates {
    Refresh-ProcessPath
    $candidates = New-Object System.Collections.Generic.List[string]
    try {
        Get-Command ngrok.exe -All -ErrorAction Stop | ForEach-Object {
            $p = if ($_.Source) { $_.Source } else { $_.Path }
            if ($p -and -not $candidates.Contains($p)) { [void]$candidates.Add($p) }
        }
    } catch {}
    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\ngrok\ngrok.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\ngrok.exe'),
        (Join-Path $env:USERPROFILE 'scoop\shims\ngrok.exe')
    )) {
        if ($p -and (Test-Path -LiteralPath $p) -and -not $candidates.Contains($p)) { [void]$candidates.Add($p) }
    }
    return $candidates.ToArray()
}

function Get-NgrokInfo {
    $best = $null
    foreach ($path in (Get-NgrokCandidates)) {
        $r = Invoke-Native -FilePath $path -Arguments @('--version') -AllowFailure -Quiet
        if ($r.ExitCode -ne 0) { $r = Invoke-Native -FilePath $path -Arguments @('version') -AllowFailure -Quiet }
        if ($r.ExitCode -ne 0) { continue }
        $v = ConvertTo-Version $r.Output
        if (-not $v) { continue }
        $item = [pscustomobject]@{ Path=$path; Version=$v; Raw=$r.Output.Trim() }
        if (-not $best -or $item.Version -gt $best.Version) { $best = $item }
    }
    return $best
}

function Find-Ngrok {
    $ng = Get-NgrokInfo
    if ($ng) { return $ng.Path }
    return $null
}

function Add-UserPathEntry {
    param([Parameter(Mandatory=$true)][string]$Directory)
    $dir = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() })
    $exists = $false
    foreach ($p in $parts) {
        try {
            if ([IO.Path]::GetFullPath($p).TrimEnd('\') -ieq $dir) { $exists = $true; break }
        } catch {
            if ($p.TrimEnd('\') -ieq $dir) { $exists = $true; break }
        }
    }
    if (-not $exists) {
        $newPath = (($parts + $dir) -join ';')
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Info "Добавлено в пользовательский PATH: $dir"
    }
    Refresh-ProcessPath
}

function Invoke-DownloadFileVisible {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$OutFile,
        [string]$Label = 'файл'
    )

    Reset-ConsoleLayout
    Write-Host ''
    Write-Host ("  [СИСТЕМНЫЙ ВЫВОД] Загрузка {0}" -f $Label) -ForegroundColor DarkGray
    Write-Host ("  URL: {0}" -f $Url) -ForegroundColor DarkGray
    Write-Host ('  ' + ('·' * 74)) -ForegroundColor DarkGray

    $response = $null
    $responseStream = $null
    $output = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.AllowAutoRedirect = $true
        $request.UserAgent = "DevSpace-MCP-Bootstrap/$ScriptVersion"
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 30000
        $response = $request.GetResponse()

        $length = [int64]$response.ContentLength
        $responseStream = $response.GetResponseStream()
        $output = [IO.File]::Open($OutFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        [byte[]]$buffer = New-Object byte[] 131072
        [int64]$downloaded = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $lastReportMs = -1500

        while (($read = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $output.Write($buffer, 0, $read)
            $downloaded += $read

            if (($sw.ElapsedMilliseconds - $lastReportMs) -ge 1500) {
                $mb = [Math]::Round($downloaded / 1MB, 1)
                if ($length -gt 0) {
                    $totalMb = [Math]::Round($length / 1MB, 1)
                    $pct = [Math]::Min(100, [Math]::Round(($downloaded * 100.0) / $length, 0))
                    Write-Host ("  Загружено: {0} / {1} МБ ({2}%)" -f $mb, $totalMb, $pct) -ForegroundColor DarkGray
                } else {
                    Write-Host ("  Загружено: {0} МБ" -f $mb) -ForegroundColor DarkGray
                }
                $lastReportMs = $sw.ElapsedMilliseconds
            }
        }
        $output.Flush()

        $finalMb = [Math]::Round($downloaded / 1MB, 1)
        Write-Host ("  Загрузка завершена: {0} МБ" -f $finalMb) -ForegroundColor DarkGray
        Write-Host ('  ' + ('·' * 74)) -ForegroundColor DarkGray
    } catch {
        Reset-ConsoleLayout
        Write-Host ('  ' + ('·' * 74)) -ForegroundColor DarkRed
        Write-Host $_.Exception.ToString() -ForegroundColor Red
        throw
    } finally {
        if ($output) { try { $output.Dispose() } catch {} }
        if ($responseStream) { try { $responseStream.Dispose() } catch {} }
        if ($response) { try { $response.Dispose() } catch {} }
        Reset-ConsoleLayout
    }
}

function Install-NgrokStandalone {
    Write-Info 'Основной способ установки ngrok: официальный standalone ZIP с ngrok.com.'
    Write-Info 'Microsoft Store используется только как резервный вариант, если ZIP скачать/установить не удалось.'

    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    switch -Regex ($arch) {
        'ARM64' { $ngrokArch = 'arm64' }
        'AMD64|x86_64' { $ngrokArch = 'amd64' }
        default { throw "Не удалось подобрать standalone ngrok для архитектуры '$arch'." }
    }

    $url = "https://bin.ngrok.com/c/bNyj1mQVY4c/ngrok-v3-stable-windows-$ngrokArch.zip"
    $installDir = Join-Path $env:LOCALAPPDATA 'Programs\ngrok'
    $zip = Join-Path $env:TEMP ("ngrok-v3-{0}-{1}.zip" -f $ngrokArch, [Guid]::NewGuid().ToString('N'))
    $extractDir = $null
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null

    try {
        Invoke-DownloadFileVisible -Url $url -OutFile $zip -Label 'официального ngrok ZIP'
    } catch {
        throw "Не удалось скачать официальный ZIP ngrok: $($_.Exception.Message)"
    }

    try {
        Write-Host '  Распаковка архива...' -ForegroundColor DarkGray
        $extractDir = Join-Path $env:TEMP ("ngrok-extract-{0}" -f [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $extractDir -Force
        $exe = Get-ChildItem -Path $extractDir -Filter 'ngrok.exe' -File -Recurse | Select-Object -First 1
        if (-not $exe) { throw 'В скачанном архиве не найден ngrok.exe.' }
        Copy-Item -LiteralPath $exe.FullName -Destination (Join-Path $installDir 'ngrok.exe') -Force
        try { Unblock-File -LiteralPath (Join-Path $installDir 'ngrok.exe') -ErrorAction SilentlyContinue } catch {}
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        if ($extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Add-UserPathEntry -Directory $installDir
    $test = Invoke-Native -FilePath (Join-Path $installDir 'ngrok.exe') -Arguments @('--version') -AllowFailure -Quiet
    if ($test.ExitCode -ne 0) { throw 'Standalone ngrok скачан, но ngrok.exe не запускается.' }
    Write-Ok ("ngrok установлен из официального ZIP: {0}" -f $test.Output.Trim())
}

function Install-NgrokFromStore {
    param([string]$Winget)
    Write-Warn 'Официальный ZIP ngrok не сработал. Пробую резервный канал: Microsoft Store через WinGet.'
    Write-Info 'Watchdog Microsoft Store: 180 секунд. При зависании скрипт остановит WinGet и покажет ошибку.'
    $r = Install-WingetPackage -Winget $Winget -IdOrName 'ngrok' -Source 'msstore' -TimeoutSeconds 180 -AllowFailure
    Reset-ConsoleLayout
    Refresh-ProcessPath
    $ng = Get-NgrokInfo
    if ($ng) {
        Write-Ok ("ngrok появился после резервной установки Microsoft Store: {0}" -f $ng.Raw)
        return $ng
    }
    if ($r.TimedOut) {
        Write-Warn 'Microsoft Store не завершил резервную установку ngrok за 180 секунд.'
    } else {
        Write-Warn ("Microsoft Store не установил рабочий ngrok (код WinGet: {0})." -f $r.ExitCode)
    }
    return $null
}

function Install-NgrokPreferred {
    param([string]$Winget)

    try {
        Install-NgrokStandalone
        Refresh-ProcessPath
        $ng = Get-NgrokInfo
        if ($ng) { return $ng }
        throw 'После установки из ZIP ngrok.exe не обнаружен.'
    } catch {
        Reset-ConsoleLayout
        Write-Warn ("Установка ngrok из официального ZIP не удалась: {0}" -f $_.Exception.Message)
        return (Install-NgrokFromStore -Winget $Winget)
    }
}

function Repair-NgrokVersion {
    param([string]$Winget)
    Write-Warn 'Обнаружена устаревшая/несовместимая версия ngrok. Исправляю установку.'
    $old = Find-Ngrok
    if ($old) {
        $upd = Invoke-Native -FilePath $old -Arguments @('update') -AllowFailure
        Refresh-ProcessPath
        $after = Get-NgrokInfo
        if ($after -and $after.Version -and $after.Version -ge $MinNgrok) {
            Write-Ok ("ngrok обновлён: {0}" -f $after.Raw)
            return $after
        }
    }

    Write-Info 'Удаляю старый пакет Ngrok.Ngrok из community-репозитория WinGet (если он установлен).'
    Invoke-Native -FilePath $Winget -Arguments @('uninstall','--id','Ngrok.Ngrok','-e','--source','winget','--silent','--disable-interactivity') -AllowFailure | Out-Null
    $after = Install-NgrokPreferred -Winget $Winget
    if (-not $after) { throw 'ngrok не найден после восстановления установки.' }
    return $after
}

function Ensure-Ngrok {
    param([string]$Winget)
    Write-Step 'ngrok: установка и проверка версии'
    $ng = Get-NgrokInfo
    if (-not $ng) {
        $ng = Install-NgrokPreferred -Winget $Winget
    }
    if (-not $ng) { throw 'ngrok не найден после установки.' }
    Write-Info ("Найдено: {0}; путь: {1}" -f $ng.Raw, $ng.Path)
    if (-not $ng.Version -or $ng.Version -lt $MinNgrok) {
        $ng = Repair-NgrokVersion -Winget $Winget
    }
    if (-not $ng.Version -or $ng.Version -lt $MinNgrok) {
        $all = (& where.exe ngrok.exe 2>$null) -join '; '
        throw "Активная версия ngrok всё ещё ниже $MinNgrok. Найденные ngrok.exe: $all"
    }
    Write-Ok ("ngrok совместим: {0}" -f $ng.Raw)
    $script:NgrokExe = $ng.Path
    return $ng
}

function Get-NgrokConfigCheckInfo {
    $result = [ordered]@{
        ExitCode = -1
        Output   = ''
        Path     = $null
    }

    if (-not $script:NgrokExe) {
        return [pscustomobject]$result
    }

    try {
        $r = Invoke-Native -FilePath $script:NgrokExe -Arguments @('config','check') -AllowFailure -Quiet
        $result.ExitCode = $r.ExitCode
        $result.Output = [string]$r.Output

        foreach ($line in ($r.Output -split '\r?\n')) {
            # Strip ANSI escape sequences before parsing a Windows path.
            $clean = [regex]::Replace([string]$line, "$([char]27)\[[0-9;?]*[ -/]*[@-~]", '')
            $m = [regex]::Match($clean, '(?i)(?<path>[A-Za-z]:\\.*?\.ya?ml)(?:"|''|\s|$)')
            if ($m.Success) {
                $candidate = $m.Groups['path'].Value.Trim()
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $result.Path = (Resolve-Path -LiteralPath $candidate).Path
                    break
                }
            }
        }
    } catch {
        $result.Output = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Add-UniqueExistingPath {
    param(
        [Parameter(Mandatory=$true)]$List,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    try {
        $clean = [Environment]::ExpandEnvironmentVariables(
            $Path.Trim().Trim([char]34, [char]39, [char]32)
        )
        if (-not (Test-Path -LiteralPath $clean -PathType Leaf)) { return }

        $resolved = (Resolve-Path -LiteralPath $clean).Path
        foreach ($existing in $List) {
            if ([string]::Equals([string]$existing, $resolved, [StringComparison]::OrdinalIgnoreCase)) {
                return
            }
        }
        [void]$List.Add($resolved)
    } catch {}
}

function Get-NgrokConfigPaths {
    $paths = New-Object 'System.Collections.Generic.List[string]'

    # 1. Exact path learned during this launcher run.
    Add-UniqueExistingPath -List $paths -Path $script:NgrokConfigPathHint

    # 2. Explicit ngrok override.
    Add-UniqueExistingPath -List $paths -Path $env:NGROK_CONFIG

    # 3. Ask the active ngrok executable for the config it actually validates.
    $check = Get-NgrokConfigCheckInfo
    Add-UniqueExistingPath -List $paths -Path $check.Path

    # 4. Official/default Windows locations for current and legacy ngrok.
    $known = @(
        (Join-Path $env:LOCALAPPDATA 'ngrok\ngrok.yml'),
        (Join-Path $env:LOCALAPPDATA 'ngrok\ngrok.yaml'),
        (Join-Path $env:USERPROFILE 'AppData\Local\ngrok\ngrok.yml'),
        (Join-Path $env:USERPROFILE 'AppData\Local\ngrok\ngrok.yaml'),
        (Join-Path $env:USERPROFILE '.config\ngrok\ngrok.yml'),
        (Join-Path $env:USERPROFILE '.config\ngrok\ngrok.yaml'),
        (Join-Path $env:USERPROFILE '.ngrok2\ngrok.yml'),
        (Join-Path $env:USERPROFILE '.ngrok2\ngrok.yaml')
    )
    foreach ($p in $known) {
        Add-UniqueExistingPath -List $paths -Path $p
    }

    # 5. MSIX packages may expose package-local state. Probe only package
    # directories whose names contain "ngrok", not the whole Packages tree.
    $packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path -LiteralPath $packagesRoot -PathType Container) {
        try {
            Get-ChildItem -LiteralPath $packagesRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '(?i)ngrok' } |
                ForEach-Object {
                    try {
                        Get-ChildItem -LiteralPath $_.FullName -File -Recurse -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -match '(?i)^ngrok\.ya?ml$' } |
                            ForEach-Object {
                                Add-UniqueExistingPath -List $paths -Path $_.FullName
                            }
                    } catch {}
                }
        } catch {}
    }

    return @($paths.ToArray())
}

function Get-NgrokConfigPath {
    $paths = @(Get-NgrokConfigPaths)
    if ($paths.Count -gt 0) { return [string]$paths[0] }
    return $null
}

function Read-TextFileAutoEncoding {
    param([Parameter(Mandatory=$true)][string]$Path)

    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return '' }

    # BOM-aware decoding.
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }

    # Detect UTF-16 without BOM by the characteristic NUL-byte pattern.
    $sampleLength = [Math]::Min($bytes.Length, 512)
    $evenNulls = 0
    $oddNulls = 0
    for ($i = 0; $i -lt $sampleLength; $i++) {
        if ($bytes[$i] -eq 0) {
            if (($i % 2) -eq 0) { $evenNulls++ } else { $oddNulls++ }
        }
    }
    if ($oddNulls -gt 4 -and $oddNulls -gt ($evenNulls * 2)) {
        return [Text.Encoding]::Unicode.GetString($bytes)
    }
    if ($evenNulls -gt 4 -and $evenNulls -gt ($oddNulls * 2)) {
        return [Text.Encoding]::BigEndianUnicode.GetString($bytes)
    }

    # ngrok itself writes UTF-8/ASCII on Windows.
    try {
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        return $strictUtf8.GetString($bytes)
    } catch {
        return [Text.Encoding]::Default.GetString($bytes)
    }
}

function ConvertFrom-NgrokYamlScalar {
    param([string]$Value)

    if ($null -eq $Value) { return $null }
    $v = $Value.Trim()
    if (-not $v) { return $null }

    if ($v.Length -ge 2 -and $v[0] -eq '"' -and $v[$v.Length - 1] -eq '"') {
        return $v.Substring(1, $v.Length - 2)
    }
    if ($v.Length -ge 2 -and $v[0] -eq [char]39 -and $v[$v.Length - 1] -eq [char]39) {
        return $v.Substring(1, $v.Length - 2)
    }

    # Remove a YAML comment only when separated from the value by whitespace.
    $v = [regex]::Replace($v, '\s+#.*$', '').Trim()
    if (-not $v) { return $null }

    # Environment-variable references are valid YAML values too.
    if ($v -match '^\$\{(?<name>[A-Za-z_][A-Za-z0-9_]*)\}$') {
        $envValue = [Environment]::GetEnvironmentVariable($Matches['name'])
        if (-not [string]::IsNullOrWhiteSpace($envValue)) { return $envValue }
    }
    if ($v -match '^\$(?<name>[A-Za-z_][A-Za-z0-9_]*)$') {
        $envValue = [Environment]::GetEnvironmentVariable($Matches['name'])
        if (-not [string]::IsNullOrWhiteSpace($envValue)) { return $envValue }
    }

    return $v
}

function Read-NgrokAuthtokenFromConfig {
    param([Parameter(Mandatory=$true)][string]$Path)

    try {
        $text = Read-TextFileAutoEncoding -Path $Path
    } catch {
        return $null
    }

    # Normal ngrok v2:
    #   authtoken: TOKEN
    #
    # Normal ngrok v3:
    #   agent:
    #       authtoken: TOKEN
    #
    # Parse line-by-line first so indentation and the surrounding section do
    # not matter.
    foreach ($line in ($text -split '\r?\n')) {
        $m = [regex]::Match(
            [string]$line,
            '^\s*(?:agent\.)?authtoken\s*:\s*(?<value>.*?)\s*$',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($m.Success) {
            $token = ConvertFrom-NgrokYamlScalar -Value $m.Groups['value'].Value
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                return $token
            }
        }
    }

    # Defensive fallback for compact/inline YAML, for example:
    # agent: { authtoken: TOKEN }
    $inline = [regex]::Match(
        $text,
        '(?i)(?:^|[\{,]\s*)authtoken\s*:\s*(?<value>"[^"]*"|''[^'']*''|[^,\}\r\n]+)'
    )
    if ($inline.Success) {
        $token = ConvertFrom-NgrokYamlScalar -Value $inline.Groups['value'].Value
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            return $token
        }
    }

    return $null
}

function Get-NgrokAuthtokenValue {
    if (-not [string]::IsNullOrWhiteSpace($env:NGROK_AUTHTOKEN)) {
        return [string]$env:NGROK_AUTHTOKEN
    }

    foreach ($p in @(Get-NgrokConfigPaths)) {
        $token = Read-NgrokAuthtokenFromConfig -Path $p
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            $script:NgrokConfigPathHint = $p
            return $token
        }
    }

    return $null
}

function Test-NgrokConfigValid {
    $check = Get-NgrokConfigCheckInfo
    return ($check.ExitCode -eq 0)
}

function Get-NgrokAuthState {
    for ($i = 0; $i -lt 6; $i++) {
        $token = Get-NgrokAuthtokenValue
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            return [pscustomobject]@{
                Configured  = $true
                Token       = $token
                Readable    = $true
                ConfigValid = $true
                ConfigPath  = $script:NgrokConfigPathHint
            }
        }
        if ($i -lt 5) { Start-Sleep -Milliseconds 200 }
    }

    $check = Get-NgrokConfigCheckInfo
    return [pscustomobject]@{
        Configured  = $false
        Token       = $null
        Readable    = $false
        ConfigValid = ($check.ExitCode -eq 0)
        ConfigPath  = $check.Path
    }
}

function Test-NgrokAuthtokenConfigured {
    return [bool](Get-NgrokAuthState).Configured
}

function Get-MaskedSecret {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '(не настроен)' }
    if ($Value.Length -le 10) { return ('*' * $Value.Length) }
    return $Value.Substring(0,5) + ('*' * [Math]::Max(6, $Value.Length - 10)) + $Value.Substring($Value.Length - 5)
}

function Set-NgrokAuthtokenValue {
    param([Parameter(Mandatory=$true)][string]$Token)

    $plain = $Token.Trim()
    if ([string]::IsNullOrWhiteSpace($plain)) { throw 'Authtoken не введён.' }

    try {
        # Show ngrok's own result, but capture it as well so we can remember the
        # exact configuration file it wrote.
        $r = Invoke-Native -FilePath $script:NgrokExe -Arguments @('config','add-authtoken',$plain) -AllowFailure
    } finally {
        $plain = $null
    }

    if ($r.ExitCode -ne 0) {
        throw "ngrok config add-authtoken завершился с кодом $($r.ExitCode)."
    }

    foreach ($line in ($r.Output -split '\r?\n')) {
        $clean = [regex]::Replace([string]$line, "$([char]27)\[[0-9;?]*[ -/]*[@-~]", '')
        $m = [regex]::Match($clean, '(?i)(?<path>[A-Za-z]:\\.*?\.ya?ml)(?:"|''|\s|$)')
        if ($m.Success) {
            $candidate = $m.Groups['path'].Value.Trim()
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $script:NgrokConfigPathHint = (Resolve-Path -LiteralPath $candidate).Path
                break
            }
        }
    }

    $authState = Get-NgrokAuthState
    if (-not $authState.Readable) {
        $where = if ($authState.ConfigPath) { $authState.ConfigPath } else { '(путь не определён)' }
        throw ("ngrok сообщил об успешном сохранении Authtoken, но launcher не смог прочитать ключ authtoken из активного файла конфигурации: {0}. Это внутренняя ошибка чтения конфигурации, запуск не будет молча продолжен." -f $where)
    }

    Write-Ok ('Authtoken сохранён: {0}' -f (Get-MaskedSecret $authState.Token))
}

function Set-NgrokAuthtokenInteractive {
    Write-Host ''
    Write-NoticeBox -Title 'ГДЕ ВЗЯТЬ NGROK AUTHTOKEN' -Lines @(
        'Откройте страницу:'
        'https://dashboard.ngrok.com/get-started/your-authtoken'
        'Скопируйте Authtoken и вставьте его ниже.'
    )
    $plain = Read-Host 'Вставьте Authtoken'
    Set-NgrokAuthtokenValue -Token $plain
}

function Ensure-NgrokAuthtoken {
    $authState = Get-NgrokAuthState
    if ($authState.Readable) {
        Write-Ok ('Authtoken настроен: {0}' -f (Get-MaskedSecret $authState.Token))
    } else {
        Set-NgrokAuthtokenInteractive
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
        $jsonText = $j | ConvertTo-Json -Depth 20`n        [IO.File]::WriteAllText($configPath, $jsonText, (New-Object Text.UTF8Encoding($false)))
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
    $obj = [ordered]@{ FixedDomain=$null; LastTunnelMode='random' }
    if (Test-Path -LiteralPath $SettingsPath) {
        try {
            $j = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
            if ($j.FixedDomain) { $obj.FixedDomain = [string]$j.FixedDomain }
            if ($j.LastTunnelMode) { $obj.LastTunnelMode = [string]$j.LastTunnelMode }
        } catch { Write-Warn "Не удалось прочитать settings JSON: $($_.Exception.Message)" }
    }
    if (-not $obj.FixedDomain -and (Test-Path -LiteralPath $LegacyDomainPath)) {
        try {
            $legacy = (Get-Content -LiteralPath $LegacyDomainPath -Raw).Trim([char]0xFEFF).Trim()
            if ($legacy) {
                $obj.FixedDomain = ($legacy -replace '^https?://','' -replace '/mcp/?$','' -replace '/+$','')
                $obj.LastTunnelMode = 'fixed'
            }
        } catch {}
    }
    return $obj
}

function Save-Settings {
    param($Settings)
    $Settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $SettingsPath -Encoding UTF8
}

function Normalize-NgrokOrigin {
    param([string]$InputText)
    if ([string]::IsNullOrWhiteSpace($InputText)) { throw 'Адрес не введён.' }
    $s = $InputText.Trim().Trim('"','''')
    $s = $s -replace '\\','/'
    if ($s -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $s = 'https://' + $s }
    try { $u = [Uri]$s } catch { throw "Некорректный URL: $InputText" }
    if (-not $u.IsAbsoluteUri) { throw 'Нужен абсолютный HTTPS URL.' }
    if ($u.Scheme -ne 'https') { throw 'Для публичного MCP нужен https:// адрес.' }
    if ([string]::IsNullOrWhiteSpace($u.Host)) { throw 'В URL отсутствует домен.' }
    if ($u.Query -or $u.Fragment) { throw 'Не добавляйте query-параметры или #fragment к адресу ngrok.' }
    $path = $u.AbsolutePath.TrimEnd('/')
    if ($path -and $path -ne '' -and $path -ne '/mcp') {
        throw "В адресе обнаружен лишний путь '$path'. Нужен только домен; /mcp скрипт добавляет сам для ChatGPT."
    }
    if ($path -eq '/mcp') { Write-Warn 'Вы ввели /mcp. Для publicBaseUrl он удалён автоматически.' }
    $builder = New-Object UriBuilder($u.Scheme, $u.Host)
    if (-not $u.IsDefaultPort) { $builder.Port = $u.Port } else { $builder.Port = -1 }
    $builder.Path = ''
    $builder.Query = ''
    $builder.Fragment = ''
    return $builder.Uri.AbsoluteUri.TrimEnd('/')
}

function Set-FixedDomainInteractive {
    param($Settings)
    Write-Rule 'ФИКСИРОВАННЫЙ NGROK DEV DOMAIN'
    Write-NoticeBox -Title 'ГДЕ ВЗЯТЬ ФИКСИРОВАННЫЙ DEV DOMAIN' -Lines @(
        'Откройте страницу:'
        'https://dashboard.ngrok.com/domains'
        'Скопируйте ваш Dev Domain. Можно вставить с https:// или без него.'
    )
    Write-Host 'Введите Dev Domain / ngrok URL.' -ForegroundColor Cyan
    Write-Host 'Пример:  bright-forest-panda.ngrok-free.dev' -ForegroundColor DarkGray
    Write-Host 'Пример:  https://bright-forest-panda.ngrok-free.dev' -ForegroundColor DarkGray
    Write-Host 'Не надо: .../mcp  (если введёте, скрипт удалит /mcp).' -ForegroundColor DarkGray
    $raw = Read-Host 'Адрес'
    $origin = Normalize-NgrokOrigin $raw
    $Settings.FixedDomain = ([Uri]$origin).Host
    $Settings.LastTunnelMode = 'fixed'
    Save-Settings $Settings
    Write-Ok "Сохранён фиксированный домен: $($Settings.FixedDomain)"
}

function Select-TunnelModeInteractive {
    param($Settings)
    while ($true) {
        Write-Rule 'РЕЖИМ NGROK'
        $savedMode = if ($Settings.LastTunnelMode -eq 'fixed' -and $Settings.FixedDomain) { 'fixed' } else { 'random' }
        $savedNumber = if ($savedMode -eq 'fixed') { '1' } else { '2' }
        $savedLabel = if ($savedMode -eq 'fixed') { 'Фиксированный Dev Domain' } else { 'Временный случайный адрес ngrok' }
        Write-SavedAccent ("Сохранённый режим: [{0}] {1}" -f $savedNumber, $savedLabel)
        Write-Host ''
        Write-Host '  [1] Фиксированный Dev Domain  <- рекомендуемый путь' -ForegroundColor Green
        Write-Host '  [2] Временный случайный адрес ngrok' -ForegroundColor White
        Write-SavedAccent '  Enter — оставить сохранённый режим.'
        Write-Host '  B — назад в главное меню.' -ForegroundColor DarkGray
        $choice = (Read-Host 'Режим').Trim()
        if ($choice -match '(?i)^(b|back|назад)$') { return $null }
        if (-not $choice) { return $savedMode }
        switch ($choice) {
            '1' { $Settings.LastTunnelMode = 'fixed'; Save-Settings $Settings; return 'fixed' }
            '2' { $Settings.LastTunnelMode = 'random'; Save-Settings $Settings; return 'random' }
            default { Write-Warn 'Введите 1, 2, Enter или B.' }
        }
    }
}

function Select-FixedDomainInteractive {
    param($Settings, [string]$Mode)
    if ($Mode -ne 'fixed') { return $true }
    while ($true) {
        Write-Rule 'ФИКСИРОВАННЫЙ NGROK DEV DOMAIN'
        Write-NoticeBox -Title 'ГДЕ ВЗЯТЬ ФИКСИРОВАННЫЙ DEV DOMAIN' -Lines @(
            'Откройте страницу:'
            'https://dashboard.ngrok.com/domains'
            'Скопируйте ваш Dev Domain. Например: bright-forest-panda.ngrok-free.dev'
        )
        if ($Settings.FixedDomain) {
            Write-SavedAccent ("Сохранённый домен: https://{0}" -f $Settings.FixedDomain)
            Write-SavedAccent 'Enter — оставить сохранённый домен.'
        } else {
            Write-Host 'Фиксированный домен ещё не сохранён.' -ForegroundColor Yellow
        }
        Write-Host 'Введите другой домен, чтобы заменить сохранённый.' -ForegroundColor White
        Write-Host 'B — назад в главное меню.' -ForegroundColor DarkGray
        $raw = (Read-Host 'Dev Domain').Trim()
        if ($raw -match '(?i)^(b|back|назад)$') { return $false }
        if (-not $raw) {
            if ($Settings.FixedDomain) { return $true }
            Write-Warn 'Сохранённого Dev Domain нет — введите домен.'
            continue
        }
        try {
            $origin = Normalize-NgrokOrigin $raw
            $Settings.FixedDomain = ([Uri]$origin).Host
            $Settings.LastTunnelMode = 'fixed'
            Save-Settings $Settings
            Write-Ok "Сохранён фиксированный домен: $($Settings.FixedDomain)"
            return $true
        } catch { Write-Warn $_.Exception.Message }
    }
}

function Select-NgrokAuthtokenInteractive {
    while ($true) {
        Write-Rule 'NGROK AUTHTOKEN'
        Write-NoticeBox -Title 'ГДЕ ВЗЯТЬ NGROK AUTHTOKEN' -Lines @(
            'Откройте страницу:'
            'https://dashboard.ngrok.com/get-started/your-authtoken'
            'Скопируйте Authtoken и вставьте его ниже.'
        )

        $authState = Get-NgrokAuthState
        if ($authState.Readable) {
            Write-SavedAccent ("Сохранённый токен: {0}" -f (Get-MaskedSecret $authState.Token))
            Write-SavedAccent 'Enter — оставить сохранённый токен.'
        } else {
            Write-Host 'Authtoken ещё не настроен или не читается из конфигурации ngrok.' -ForegroundColor Yellow
            if ($authState.ConfigPath) {
                Write-Host ("Активный конфиг ngrok: {0}" -f $authState.ConfigPath) -ForegroundColor DarkGray
            }
            if ($authState.ConfigValid) {
                Write-Warn 'ngrok считает конфигурацию синтаксически валидной, но ключ authtoken в ней не найден. Это НЕ считается сохранённым токеном.'
            }
        }

        Write-Host 'Введите новый токен, чтобы заменить или настроить его.' -ForegroundColor White
        Write-Host 'B — назад в главное меню.' -ForegroundColor DarkGray

        $raw = (Read-HostWithoutTranscript -Prompt 'Authtoken').Trim()
        if ($raw -match '(?i)^(b|back|назад)$') { return $false }

        if (-not $raw) {
            if ($authState.Readable) { return $true }
            Write-Warn 'Сохранённый Authtoken не найден — вставьте токен.'
            continue
        }

        try {
            Set-NgrokAuthtokenValue -Token $raw
            return $true
        } catch {
            Write-Warn $_.Exception.Message
        }
    }
}

function Stop-PreviousNgrok {
    try {
        $procs = Get-Process -Name ngrok -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Info 'Останавливаю ранее запущенный ngrok, чтобы не было конфликта туннелей.'
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
        }
    } catch {}
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

function Get-NgrokPublicUrl {
    try {
        $tunnels = Invoke-RestMethod -Uri 'http://127.0.0.1:4040/api/tunnels' -TimeoutSec 2 -ErrorAction Stop
        $t = $tunnels.tunnels | Where-Object { $_.public_url -like 'https://*' } | Select-Object -First 1
        if ($t) { return [string]$t.public_url }
    } catch {}
    return $null
}

function Show-NgrokFailureLogs {
    if ($script:NgrokFailureLogsShown) { return }
    $script:NgrokFailureLogsShown = $true
    if ($script:NgrokStdOut -and (Test-Path $script:NgrokStdOut)) {
        $txt = Get-Content -LiteralPath $script:NgrokStdOut -Raw -ErrorAction SilentlyContinue
        if ($txt) { Write-Host "`n--- ngrok stdout ---" -ForegroundColor Red; Write-Host $txt }
    }
    if ($script:NgrokStdErr -and (Test-Path $script:NgrokStdErr)) {
        $txt = Get-Content -LiteralPath $script:NgrokStdErr -Raw -ErrorAction SilentlyContinue
        if ($txt) { Write-Host "`n--- ngrok stderr ---" -ForegroundColor Red; Write-Host $txt }
    }
}

function Start-NgrokTunnel {
    param([string]$Mode, $Settings, [string]$Winget, [switch]$RetryAfterRepair)
    $script:NgrokFailureLogsShown = $false
    Stop-PreviousNgrok
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:NgrokStdOut = Join-Path $LogDir "ngrok-$stamp.stdout.log"
    $script:NgrokStdErr = Join-Path $LogDir "ngrok-$stamp.stderr.log"
    $args = @('http', [string]$Port)
    if ($Mode -eq 'fixed') {
        $origin = Normalize-NgrokOrigin $Settings.FixedDomain
        $args += ("--url={0}" -f $origin)
        Write-Info "Запускаю ngrok с фиксированным URL: $origin"
    } else {
        Write-Info 'Запускаю ngrok со случайным HTTPS URL.'
    }
    try {
        $script:NgrokProcess = Start-Process -FilePath $script:NgrokExe -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $script:NgrokStdOut -RedirectStandardError $script:NgrokStdErr
        Register-ManagedProcess -Process $script:NgrokProcess -Name 'ngrok'
        Save-RuntimeState
    } catch {
        $launchError = $_.Exception.ToString()

        # Microsoft Store/MSIX executables can already be constrained by a
        # package Job Object. In that case Windows may reject attaching ngrok
        # to our KILL_ON_JOB_CLOSE guard. Fall back once to the official
        # standalone ZIP, whose process can be managed reliably.
        if (($launchError -match 'Windows Job Object') -and
            ($script:NgrokExe -match '(?i)\\Microsoft\\WindowsApps\\') -and
            (-not $RetryAfterRepair)) {
            Write-Warn 'Store-версию ngrok не удалось привязать к защите жизненного цикла. Переключаюсь на официальный standalone ZIP и повторяю запуск.'
            try {
                Install-NgrokStandalone
                $standalone = Join-Path $env:LOCALAPPDATA 'Programs\ngrok\ngrok.exe'
                if (-not (Test-Path -LiteralPath $standalone -PathType Leaf)) {
                    throw 'После установки standalone ZIP ngrok.exe не найден.'
                }
                $script:NgrokExe = $standalone
                return Start-NgrokTunnel -Mode $Mode -Settings $Settings -Winget $Winget -RetryAfterRepair
            } catch {
                throw "Не удалось запустить ngrok и перейти со Store-версии на standalone ZIP: $($_.Exception.ToString())"
            }
        }

        throw "Не удалось запустить ngrok: $launchError"
    }

    $url = $null
    for ($i=0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if ($script:NgrokProcess.HasExited) { break }
        $url = Get-NgrokPublicUrl
        if ($url) { break }
    }
    if ($url) {
        $origin = Normalize-NgrokOrigin $url
        Write-Ok "ngrok туннель готов: $origin"
        return $origin
    }

    Show-NgrokFailureLogs
    $combined = ''
    if (Test-Path $script:NgrokStdOut) { $combined += (Get-Content $script:NgrokStdOut -Raw -ErrorAction SilentlyContinue) }
    if (Test-Path $script:NgrokStdErr) { $combined += "`n" + (Get-Content $script:NgrokStdErr -Raw -ErrorAction SilentlyContinue) }
    try { if ($script:NgrokProcess -and -not $script:NgrokProcess.HasExited) { $script:NgrokProcess.Kill() } } catch {}

    if (($combined -match 'ERR_NGROK_121') -and (-not $RetryAfterRepair)) {
        Write-Warn 'Получен ERR_NGROK_121: ngrok требует более новый агент. Автоматически обновляю/переустанавливаю через официальный ZIP и повторяю запуск один раз.'
        $fixed = Repair-NgrokVersion -Winget $Winget
        $script:NgrokExe = $fixed.Path
        return Start-NgrokTunnel -Mode $Mode -Settings $Settings -Winget $Winget -RetryAfterRepair
    }
    if ($combined -match 'ERR_NGROK_9040') {
        Write-NoticeBox -Title 'NGROK НЕ РАЗРЕШАЕТ ПОДКЛЮЧЕНИЕ С ТЕКУЩЕГО IP' -Lines @(
            'ERR_NGROK_9040 означает, что ngrok отклонил подключение с текущего исходящего IP.'
            'Это не ошибка Dev Domain, Authtoken или версии ngrok.'
            'ВАЖНО ДЛЯ VPN: если VPN включён, первым делом проверьте его режим.'
            'Переключите VPN в режим полного туннелирования (Tunnel/TUN/VPN), а не System Proxy/системный прокси.'
            'После переключения режима VPN повторите запуск DevSpace MCP.'
            'Случайный URL ngrok здесь не поможет, если агент всё равно выходит в интернет через тот же заблокированный IP.'
            'Если VPN не используется, отключите TOR/анонимизирующие прокси или попробуйте другую сеть.'
            'Документация: https://ngrok.com/docs/errors/err_ngrok_9040'
            'Поддержка: support@ngrok.com'
        )
        throw 'ngrok отклонил подключение с текущего IP (ERR_NGROK_9040). Следуйте жёлтой подсказке выше.'
    }
    throw "ngrok не создал туннель. Полный stdout/stderr показан выше и сохранён в $LogDir"
}

function Get-OwnerToken {
    $auth = Join-Path $env:USERPROFILE '.devspace\auth.json'
    if (-not (Test-Path -LiteralPath $auth)) { return $null }
    try {
        $j = Get-Content -LiteralPath $auth -Raw | ConvertFrom-Json
        return [string]$j.ownerToken
    } catch { return $null }
}

function Show-ConnectionCard {
    param([string]$PublicOrigin)
    $owner = Get-OwnerToken
    $mcp = $PublicOrigin.TrimEnd('/') + '/mcp'
    $authPath = Join-Path $env:USERPROFILE '.devspace\auth.json'

    Stop-Log

    Write-Rule 'РАСШИРЕННЫЕ ДАННЫЕ'
    Write-Host 'Authentication:' -ForegroundColor Yellow
    Write-Host '  OAuth' -ForegroundColor White
    Write-Host ''
    Write-Host 'Файл с Owner Password:' -ForegroundColor Yellow
    Write-Host ("  {0}" -f $authPath) -ForegroundColor White
    Write-Host ''
    Write-Host 'Локальный MCP:' -ForegroundColor Yellow
    Write-Host ("  http://127.0.0.1:{0}/mcp" -f $Port) -ForegroundColor White
    Write-Host 'ngrok Inspector:' -ForegroundColor Yellow
    Write-Host '  http://127.0.0.1:4040' -ForegroundColor White
    Write-Host ''
    Write-Host 'Техническая информация:' -ForegroundColor Yellow
    Write-Host '  • publicBaseUrl в DevSpace хранится БЕЗ /mcp.' -ForegroundColor Gray
    Write-Host '  • URL подключения к MCP заканчивается на /mcp.' -ForegroundColor Gray
    Write-Host '  • Owner Password не публикуйте и не отправляйте другим людям.' -ForegroundColor Gray

    Write-Rule 'ГОТОВО — ДАННЫЕ ДЛЯ CHATGPT'
    Write-NoticeBox -Title 'КАК ДОБАВИТЬ CUSTOM MCP В CHATGPT' -Lines @(
        'Откройте страницу: https://chatgpt.com/plugins?directoryTab=personal'
        'или в ChatGPT перейдите: Plugins → + → Add custom MCP server.'
        'Authentication выберите OAuth.'
        'Ниже находятся два основных значения для подключения.'
    )
    Write-Host ''
    Write-Host 'Название:' -ForegroundColor Yellow
    Write-Host '  DevSpace MCP' -ForegroundColor White
    Write-Host ''
    Write-Host 'MCP Server URL:' -ForegroundColor Cyan
    Write-Host ("  {0}" -f $mcp) -ForegroundColor Green
    Write-Host ''
    Write-Host 'Owner Password:' -ForegroundColor Cyan
    if ($owner) { Write-Host ("  {0}" -f $owner) -ForegroundColor Magenta }
    else { Write-Host '  НЕ НАЙДЕН — проверьте auth.json' -ForegroundColor Red }
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host ''

    Start-Log -Append
}

function Show-VersionSummary {
    param([string]$Winget, [pscustomobject]$NodeInfo, $NgrokInfo, [string]$DevSpaceVersion)
    Write-Rule 'ПРОВЕРКА КОМПОНЕНТОВ'
    $wv = Invoke-Native -FilePath $Winget -Arguments @('--version') -Quiet
    $git = Get-CommandPath -Name 'git.exe'
    $gv = if ($git) { (Invoke-Native -FilePath $git -Arguments @('--version') -Quiet).Output.Trim() } else { 'не найден' }
    $npmv = (Invoke-Native -FilePath $NodeInfo.Npm -Arguments @('--version') -Quiet).Output.Trim()
    Write-Host ("  WinGet   : {0}" -f $wv.Output.Trim())
    Write-Host ("  Git      : {0}" -f $gv)
    Write-Host ("  Git Bash : {0}" -f $script:GitBash)
    Write-Host ("  Node.js  : {0} ({1} LTS)" -f $NodeInfo.Version, $NodeInfo.Lts)
    Write-Host ("  npm      : {0}" -f $npmv)
    Write-Host ("  ngrok    : {0}" -f $NgrokInfo.Raw)
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
        'DevSpace ещё не создавал свои config/auth файлы.'
        'Сейчас откроется его официальный мастер один раз.'
        'После него основной запуск отдельно спросит разрешённые папки, ngrok-режим, домен и токен.'
    )
    $cmd = (Get-DevSpaceCommand) + ' init'
    Stop-Log
    try { Invoke-DevSpaceInitWithTty -Command $cmd }
    finally { Start-Log -Append }
    if (-not (Test-DevSpaceInitialized)) {
        Write-Warn 'DevSpace init не создал конфигурацию.'
        return $false
    }
    return $true
}

function Configure-LaunchWizard {
    param($Settings)
    if (-not (Ensure-DevSpaceInitializedForLauncher)) { return $null }
    if (-not (Select-AllowedRootsInteractive)) { return $null }
    $mode = Select-TunnelModeInteractive -Settings $Settings
    if (-not $mode) { return $null }
    if (-not (Select-FixedDomainInteractive -Settings $Settings -Mode $mode)) { return $null }
    if (-not (Select-NgrokAuthtokenInteractive)) { return $null }
    return [pscustomobject]@{ Mode=$mode }
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

function Stop-NgrokTunnelBackground {
    try {
        if ($script:NgrokProcess -and -not $script:NgrokProcess.HasExited) {
            $script:NgrokProcess.Kill()
            try { [void]$script:NgrokProcess.WaitForExit(3000) } catch {}
            Write-Ok 'ngrok остановлен.'
        }
    } catch {
        Write-Warn "Не удалось штатно остановить ngrok: $($_.Exception.Message)"
    } finally {
        $script:NgrokProcess = $null
        Save-RuntimeState
        if (-not $script:DevSpaceProcess -and -not $script:DevSpaceWatchdogProcess) {
            Clear-RuntimeState
        }
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
            Write-Info 'Закрытие этого окна или Ctrl+C автоматически остановит DevSpace и ngrok.'
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
    param([string]$PublicOrigin)
    while ($true) {
        Write-Rule 'DEVSPACE MCP — СЕРВЕР ЗАПУЩЕН'
        $roots = @(Get-DevSpaceAllowedRoots)
        Write-AccessWarningBox -Roots $roots
        Write-Host ("  MCP Server URL : {0}/mcp" -f $PublicOrigin.TrimEnd('/')) -ForegroundColor Green
        Write-Host ("  DevSpace       : запущен, порт {0}" -f $Port) -ForegroundColor Green
        Write-Host '  ngrok          : запущен' -ForegroundColor Green
        $protectionLabel = if ($script:DevSpaceJobProtected -and $script:DevSpaceWatchdogProcess) {
            'Windows Job Object + watchdog'
        } elseif ($script:DevSpaceWatchdogProcess) {
            'watchdog'
        } else {
            'Windows Job Object'
        }
        Write-Host ("  Защита         : {0}; закрытие окна / Ctrl+C = оборвать MCP-доступ" -f $protectionLabel) -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  [1] Изменить разрешённые папки и применить' -ForegroundColor Green
        Write-Host '      Если папки изменятся, DevSpace перезапустится автоматически.' -ForegroundColor Gray
        Write-Host ''
        Write-Host '  [0] Остановить сервер и вернуться в главное меню' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Здесь Enter ничего не выбирает — введите 1 или 0.' -ForegroundColor Magenta
        $choice = (Read-Host 'Выбор').Trim()
        if (-not $choice) {
            Write-Warn 'Введите конкретный пункт: 1 или 0.'
            continue
        }
        switch ($choice) {
            '1' {
                $before = @($roots | ForEach-Object { $_.ToLowerInvariant() }) -join '|'
                $selected = Select-AllowedRootsInteractive -BackLabel 'меню запущенного сервера'
                if (-not $selected) { continue }
                $afterRoots = @(Get-DevSpaceAllowedRoots)
                $after = @($afterRoots | ForEach-Object { $_.ToLowerInvariant() }) -join '|'
                if ($before -eq $after) {
                    Write-Info 'Разрешённые папки не изменились. Перезапуск сервера не требуется.'
                } else {
                    Restart-DevSpaceServerForRoots
                }
            }
            '0' { return }
            default { Write-Warn 'Неизвестный пункт. Введите 1 или 0.' }
        }
    }
}

function Start-DevSpaceSession {
    param([string]$Winget, $Settings, [string]$Mode)

    $origin = $null
    try {
        Write-Step 'Запуск туннеля ngrok'
        Test-DevSpacePort
        $origin = Start-NgrokTunnel -Mode $Mode -Settings $Settings -Winget $Winget

        Write-Step 'Обновление публичного URL DevSpace'
        Set-DevSpacePublicUrl -PublicOrigin $origin

        if (-not (Test-DevSpaceAllowedRootsConfigured)) {
            throw 'Разрешённые папки Project Roots не настроены. Запуск MCP остановлен.'
        }

        Write-Step 'Диагностика DevSpace перед запуском'
        $doctorOk = Invoke-DevSpaceDoctor
        if (-not $doctorOk) {
            $ans = (Read-Host 'Doctor сообщил ошибку. Всё равно попробовать запустить сервер? [y/N]').Trim().ToLowerInvariant()
            if ($ans -ne 'y' -and $ans -ne 'yes') { throw 'Запуск отменён после ошибки devspace doctor.' }
        }

        Write-Step 'Запуск DevSpace MCP server'
        Start-DevSpaceServerBackground

        # Connection data is useful only after the server has actually opened its port.
        Show-ConnectionCard -PublicOrigin $origin
        Show-RunningServerMenu -PublicOrigin $origin
    } finally {
        Stop-DevSpaceServerBackground
        Stop-NgrokTunnelBackground
    }
}

function Show-MainMenu {
    param($Settings)
    while ($true) {
        Write-Rule 'DEVSPACE MCP — ГЛАВНОЕ МЕНЮ'
        Write-Host '  [1] Запустить MCP сервер и дать ChatGPT доступ к папке  <- основной путь' -ForegroundColor Green
        Write-Host '      Папка → режим ngrok → Dev Domain → Authtoken → запуск' -ForegroundColor Green
        Write-Host ''
        Write-Host '  [2] Штатные настройки DevSpace (ChatGPT / Coding Agents / агенты)' -ForegroundColor White
        Write-Host '  [3] Диагностика DevSpace' -ForegroundColor White
        Write-Host '  [0] Выход' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host 'В любом шаге основного мастера: B — назад в это меню.' -ForegroundColor DarkGray
        $choice = (Read-Host 'Выбор [1]').Trim()
        if (-not $choice) { $choice = '1' }
        switch ($choice) {
            '1' {
                $launch = Configure-LaunchWizard -Settings $Settings
                if ($launch) { return [pscustomobject]@{ Action='start'; Mode=$launch.Mode } }
            }
            '2' { Open-DevSpaceNativeSettings }
            '3' { Run-DiagnosticsOnly }
            '0' { return [pscustomobject]@{ Action='exit'; Mode=$null } }
            default { Write-Warn 'Неизвестный пункт меню.' }
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
    Write-Rule ("DEVSPACE MCP — АВТОУСТАНОВКА И ЗАПУСК v{0}" -f $ScriptVersion)
    Write-Host 'Скрипт проверяет компоненты и устанавливает только отсутствующие/несовместимые.' -ForegroundColor Gray
    Write-Host 'Системный вывод установщиков показывается в реальном времени; ошибки дополнительно выделяются красным.' -ForegroundColor Gray
    Write-Host 'ngrok ставится напрямую из официального ZIP; Microsoft Store используется только как резервный вариант.' -ForegroundColor Gray
    Write-Host ("Журнал: {0}" -f $LogPath) -ForegroundColor DarkGray

    Invoke-StartupProcessCleanup
    Prepare-PowerShellPolicy
    $winget = Ensure-Winget
    Ensure-Git -Winget $winget
    $nodeInfo = Ensure-Node -Winget $winget
    $ngrokInfo = Ensure-Ngrok -Winget $winget
    $devspaceVersion = Ensure-DevSpace -NodeInfo $nodeInfo
    Show-VersionSummary -Winget $winget -NodeInfo $nodeInfo -NgrokInfo $ngrokInfo -DevSpaceVersion $devspaceVersion

    $settings = Load-Settings
    while ($true) {
        try {
            $menu = Show-MainMenu -Settings $settings
        } catch {
            Show-RecoverableError -ErrorRecord $_ -Context 'главное меню / настройка запуска'
            continue
        }
        if ($menu.Action -eq 'exit') { break }
        try {
            Start-DevSpaceSession -Winget $winget -Settings $settings -Mode $menu.Mode
        } catch {
            # Start-DevSpaceSession has its own finally block, so DevSpace/ngrok are
            # stopped before we return to the menu. Keep the launcher itself alive.
            Show-RecoverableError -ErrorRecord $_ -Context 'запуск MCP сервера'
            continue
        }
        # Start-DevSpaceSession returns here only after [0] stopped DevSpace/ngrok.
        # Keep the same console window and show the main menu again.
    }
    exit 0
}
catch {
    Write-Rule 'ОШИБКА'
    Write-Host $_.Exception.ToString() -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host ''
        Write-Host 'PowerShell stack:' -ForegroundColor DarkRed
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    }
    Write-Host ''
    Write-Host ("Журнал: {0}" -f $LogPath) -ForegroundColor Yellow
    Show-NgrokFailureLogs
    exit 1
}
finally {
    # Final safety net. Normal session cleanup should already have stopped the
    # watchdog and child processes. Keep both guards here for abnormal paths.
    try { Stop-DevSpaceServerBackground } catch {}
    try { Stop-NgrokTunnelBackground } catch {}
    try { Stop-DevSpaceWatchdog } catch {}
    try { [DevSpaceMcp.ProcessGuard]::Shutdown() } catch {}
    Stop-Log
}
