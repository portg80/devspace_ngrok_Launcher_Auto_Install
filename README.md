<p align="center">
  <img src="https://github.com/user-attachments/assets/60c6a486-dbc9-4a06-8caa-66202636a559" alt="Преврати обычный ChatGPT в мощного агента для ПК — доступ к папкам и проектам Windows" width="100%" />
</p>

# DevSpace MCP Launcher для Windows

**Дайте ChatGPT доступ к проектам на своём компьютере.** Он сможет читать и изменять файлы, искать код, запускать команды и тесты — без постоянной отправки файлов в чат.

Этот CMD-файл устанавливает и запускает [DevSpace](https://github.com/Waishnav/devspace) через **OpenAI Secure MCP Tunnel** на Windows 10/11. Не нужно вручную устанавливать и настраивать каждый компонент.

## Что делает лаунчер

- Позволяет выбрать папки, к которым разрешён доступ ChatGPT.
- Помогает подключить ваш проект на ПК к чату в ChatGPT
- Проверяет и при необходимости устанавливает зависимости (WinGet, Git/Git Bash, Node.js, DevSpace и Secure MCP Tunnel).
- Запускает MCP сервер DevSpace, и показывает данные для подключения в ChatGPT.
- Останавливает сервер и туннель при закрытии лаунчера.

## Как установить

1. **[Скачайте `start-devspace-mcp.cmd` из релиза v2.0](https://github.com/portg80/devspace_ngrok_Launcher_Auto_Install/releases/download/v2.0/start-devspace-mcp.cmd)** и сохраните в отдельную папку.
2. **Запустите файл двойным щелчком.** Скрипт проверит Windows и установит недостающие компоненты. Нужны интернет и Windows 10/11 (64-бит); при необходимости подтвердите запрос Windows на установку.
<p align="center"><img width="400" alt="image" src="https://github.com/user-attachments/assets/221f069c-5c2f-4fa5-89ad-bd6240dbd36f" /></p>
3. Выберите "**[1] Запустить DevSpace**" и укажите папки проектов, с которыми сможет работать ChatGPT.
<p align="center"><img width="400" alt="image" src="https://github.com/user-attachments/assets/d6bcbfaa-4242-47c6-b74c-9ee999ea15b2" /></p>
4. При первом запуске следуйте подсказкам которые выводит скрипт, укажите ключи OpenAI, лаунчер сохранит их в файл `.env` рядом со скриптом:
   - **Runtime API key** — [создать ключ](https://platform.openai.com/settings/organization/api-keys) с разрешениями *Tunnels Read + Use*.
   - **Admin API key** — [создать ключ](https://platform.openai.com/settings/organization/admin-keys) с разрешениями *Tunnels Read + Manage*. Нужен для регистрации нового туннеля.
   <p align="center"><img width="400" alt="image" src="https://github.com/user-attachments/assets/2b63d7f4-3365-4146-b407-ff63d56fda63" /></p>
5. Если откроется страница авторизации DevSpace, введите **Owner Password**, который покажет окно лаунчера.
6. В ChatGPT откройте **Настройки → Плагины → Добавить собственный MCP-сервер**. Выберите подключение **Tunnel**, вставьте **Tunnel ID**, показанный лаунчером, и установите **Authentication: No authentication**.
<p align="center"><img width="1000" alt="image" src="https://github.com/user-attachments/assets/d4c3db48-f5b3-4877-bdca-44b73d1925d8" /></p>


После подключения ChatGPT сможет работать с выбранными папками. **Не закрывайте окно CMD, пока используете DevSpace**: при закрытии доступ прекращается.
<p align="center"><img width="1500" lt="image" src="https://github.com/user-attachments/assets/190e4bd0-70e0-492c-b9b1-243376a00527" /></p>

## Важно о безопасности

DevSpace может запускать команды с правами вашего пользователя Windows. Разрешайте доступ только к нужным проектам, а не ко всему диску. Файл `.env` содержит API-ключи — не публикуйте его, пароли и журналы запуска.

## О проекте

Это независимый лаунчер для [DevSpace от Waishnav](https://github.com/Waishnav/devspace), а не самостоятельный MCP-сервер или официальный продукт OpenAI. Исходный проект DevSpace предоставляет функции работы с файлами и командами; лаунчер автоматизирует установку и подключение к ChatGPT.
