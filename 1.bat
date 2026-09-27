@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul

REM ============================================================
REM  build-and-broadcast.bat
REM  1. Собирает deadman.exe (MinGW или MSVC)
REM  2. Получает список chat_id через getUpdates
REM  3. Рассылает exe ВСЕМ найденным чатам
REM ============================================================

set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%"

set "SRC=deadman.cpp"
set "OUT=deadman.exe"
set "LOGFILE=%SCRIPT_DIR%build.log"
set "UPDATES=%SCRIPT_DIR%updates.json"
set "RESP=%SCRIPT_DIR%resp.json"
set "CHATS=%SCRIPT_DIR%chats.txt"

REM >>> ВРЕМЕННЫЙ ТОКЕН — СМЕНИТЬ СРАЗУ ПОСЛЕ ТЕСТА <<<
set "BOT_TOKEN=8750177867:AAE29IriAtGDrpvW0_YhQRax4fTGI3yFPEs"

REM ---------- 1. Проверка исходника ----------
if not exist "%SRC%" (
    echo [x] Не найден %SRC% в %CD%
    exit /b 1
)

REM ---------- 2. Поиск компилятора ----------
set "TOOLCHAIN="
where x86_64-w64-mingw32-g++ >nul 2>&1 && set "TOOLCHAIN=cross"
if "%TOOLCHAIN%"=="" where g++ >nul 2>&1 && set "TOOLCHAIN=mingw"
if "%TOOLCHAIN%"=="" where cl.exe >nul 2>&1 && set "TOOLCHAIN=msvc"

if "%TOOLCHAIN%"=="" (
    echo [x] Не найден компилятор: нужен MinGW-w64 ^(g++^) или MSVC ^(cl.exe^).
    exit /b 1
)
echo [*] Компилятор: %TOOLCHAIN%

REM ---------- 3. Сборка ----------
echo [*] Сборка %OUT% ...
del /q "%OUT%" >nul 2>&1

if "%TOOLCHAIN%"=="cross" (
    x86_64-w64-mingw32-g++ "%SRC%" -o "%OUT%" ^
        -lgdiplus -lwinhttp -lgdi32 -luser32 -lcomctl32 -ldwmapi ^
        -mwindows -std=c++17 -O2 -DUNICODE -D_UNICODE >"%LOGFILE%" 2>&1
) else if "%TOOLCHAIN%"=="mingw" (
    g++ "%SRC%" -o "%OUT%" ^
        -lgdiplus -lwinhttp -lgdi32 -luser32 -lcomctl32 -ldwmapi ^
        -mwindows -std=c++17 -O2 -DUNICODE -D_UNICODE >"%LOGFILE%" 2>&1
) else if "%TOOLCHAIN%"=="msvc" (
    cl "%SRC%" /nologo /EHsc /std:c++17 /O2 /DUNICODE /D_UNICODE ^
       /link gdiplus.lib winhttp.lib gdi32.lib user32.lib comctl32.lib dwmapi.lib ^
       /SUBSYSTEM:WINDOWS /OUT:"%OUT%" >"%LOGFILE%" 2>&1
)

if not exist "%OUT%" (
    echo [x] Сборка не удалась. Лог: %LOGFILE%
    type "%LOGFILE%"
    exit /b 1
)

for %%F in ("%OUT%") do set "SIZE=%%~zF"
echo [+] Собрано: %OUT% ^(%SIZE% байт^)

REM ---------- 4. Проверка curl ----------
where curl.exe >nul 2>&1
if errorlevel 1 (
    echo [x] Не найден curl.exe. Нужен Windows 10 1803+ / Windows 11.
    exit /b 1
)

REM ---------- 5. getUpdates: собираем chat_id ----------
echo [*] Запрашиваю getUpdates ...
curl.exe -sS "https://api.telegram.org/bot%BOT_TOKEN%/getUpdates" -o "%UPDATES%"
if errorlevel 1 (
    echo [x] Не удалось получить updates
    exit /b 1
)

REM Проверим ok:true
findstr /C:"\"ok\":true" "%UPDATES%" >nul
if errorlevel 1 (
    echo [x] Telegram вернул ошибку на getUpdates:
    type "%UPDATES%"
    exit /b 1
)

REM Извлекаем уникальные chat.id через PowerShell (встроен в Windows)
echo [*] Извлекаю chat_id ...
powershell -NoProfile -Command ^
  "$j = Get-Content -Raw '%UPDATES%' | ConvertFrom-Json;" ^
  "$ids = $j.result | ForEach-Object { $_.message.chat.id, $_.channel_post.chat.id, $_.edited_message.chat.id } | Where-Object { $_ -ne $null } | Sort-Object -Unique;" ^
  "if (-not $ids) { Write-Host '[!] Пусто — никто ещё не писал боту.'; exit 2 };" ^
  "$ids | Set-Content -Encoding ASCII '%CHATS%';" ^
  "Write-Host ('[+] Найдено чатов: ' + $ids.Count)"

if errorlevel 1 (
    echo [x] Нет chat_id. Напишите боту /start в личке или добавьте его в группу и повторите.
    exit /b 1
)

REM ---------- 6. Рассылка ----------
set /a SENT=0
set /a FAIL=0

for /f "usebackq delims=" %%C in ("%CHATS%") do (
    set "CID=%%C"
    echo [*] Отправка в chat_id=!CID! ...
    curl.exe -sS -X POST "https://api.telegram.org/bot%BOT_TOKEN%/sendDocument" ^
        -F "chat_id=!CID!" ^
        -F "caption=deadman.exe ^(%DATE% %TIME%^)" ^
        -F "document=@%OUT%;type=application/octet-stream" ^
        -o "%RESP%"

    findstr /C:"\"ok\":true" "%RESP%" >nul
    if errorlevel 1 (
        echo     [!] Ошибка: & type "%RESP%"
        set /a FAIL+=1
    ) else (
        echo     [+] OK
        set /a SENT+=1
    )
)

echo.
echo [+] Итог: отправлено=!SENT!, ошибок=!FAIL!
echo [!] Не забудьте отозвать токен: https://t.me/BotFather -^> /revoke
endlocal
exit /b 0
