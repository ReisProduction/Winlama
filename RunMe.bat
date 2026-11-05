@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
color 0F >nul
cd /d "%~dp0"
set "WINLAMA_LOCALIZATION_PATH=%~dp0String\tr.ini"
set "WINLAMA_LOCALIZATION_AVAILABLE="
if exist "%WINLAMA_LOCALIZATION_PATH%" (
    for /F "usebackq delims=" %%L in ("%WINLAMA_LOCALIZATION_PATH%") do set "WINLAMA_LOCALIZATION_AVAILABLE=1"
)
if defined WINLAMA_LOCALIZATION_AVAILABLE (
    call :LOAD_LOCALIZED_TEXT "Launcher.WindowTitle" "WINLAMA_WINDOW_TITLE"
    call :LOAD_LOCALIZED_TEXT "Common.Operation.Summary" "WINLAMA_OPERATION_SUMMARY"
    call :LOAD_LOCALIZED_TEXT "Common.Level.Error" "WINLAMA_LEVEL_ERROR"
    call :LOAD_LOCALIZED_TEXT "RunMe.Error.WindowsPowerShellMissing" "WINLAMA_POWERSHELL_MISSING"
    call :LOAD_LOCALIZED_TEXT "Common.Prompt.Selection" "WINLAMA_PROMPT_SELECTION"
    call :LOAD_LOCALIZED_TEXT "Common.Level.Warning" "WINLAMA_LEVEL_WARNING"
    call :LOAD_LOCALIZED_TEXT "Common.Command.Invalid" "WINLAMA_COMMAND_INVALID"
) else (
    call :USE_LOCALIZATION_FALLBACK
)
setlocal EnableDelayedExpansion
set "WINLAMA_PADDING=                                                                                                    "
set "WINLAMA_PROMPT_DISPLAY=!WINLAMA_PROMPT_SELECTION:~0,92!"
call :GET_TEXT_LENGTH WINLAMA_PROMPT_DISPLAY WINLAMA_PROMPT_LENGTH
set /A WINLAMA_PROMPT_COLUMN=WINLAMA_PROMPT_LENGTH+4
title !WINLAMA_WINDOW_TITLE!
set "WINLAMA_NO_PAUSE="
for %%A in (%*) do if /I "%%~A"=="-NoPause" set "WINLAMA_NO_PAUSE=1"
set "WINLAMA_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%WINLAMA_POWERSHELL%" (
    color 0B >nul
    echo ----------------------------------------------------------------------------------------------------
    set "WINLAMA_LINE=!WINLAMA_OPERATION_SUMMARY!!WINLAMA_PADDING!"
    echo ^| !WINLAMA_LINE:~0,96! ^|
    color 0F >nul
    <nul set /p "=| "
    color 0C >nul
    set "WINLAMA_STATUS=!WINLAMA_LEVEL_ERROR!!WINLAMA_PADDING!"
    <nul set /p "=!WINLAMA_STATUS:~0,6!"
    color 0F >nul
    <nul set /p "=| "
    set "WINLAMA_LINE=!WINLAMA_POWERSHELL_MISSING!!WINLAMA_PADDING!"
    echo !WINLAMA_LINE:~0,89!^|
    color 0B >nul
    echo ----------------------------------------------------------------------------------------------------
    if not defined WINLAMA_NO_PAUSE call :WAIT_EXIT
    exit /b 1
)
setlocal DisableDelayedExpansion
"%WINLAMA_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launcher.ps1" -RunMeHost %*
set "WINLAMA_EXIT=%ERRORLEVEL%"
exit /b %WINLAMA_EXIT%
:WAIT_EXIT
color 0F >nul
set "WINLAMA_CLOSE="
for /F "delims=" %%E in ('echo prompt $E^| cmd') do set "WINLAMA_ESC=%%E"
set "WINLAMA_LINE=!WINLAMA_PROMPT_DISPLAY!:!WINLAMA_PADDING!"
echo ^| !WINLAMA_LINE:~0,96! ^|
<nul set /p "=!WINLAMA_ESC![1A!WINLAMA_ESC![!WINLAMA_PROMPT_COLUMN!C"
set /p "WINLAMA_CLOSE="
if "!WINLAMA_CLOSE!"=="CIKIS" exit /b 0
color 0F >nul
<nul set /p "=| "
color 0E >nul
set "WINLAMA_STATUS=!WINLAMA_LEVEL_WARNING!!WINLAMA_PADDING!"
<nul set /p "=!WINLAMA_STATUS:~0,6!"
color 0F >nul
<nul set /p "=| "
set "WINLAMA_LINE=!WINLAMA_COMMAND_INVALID!!WINLAMA_PADDING!"
echo !WINLAMA_LINE:~0,89!^|
color 0B >nul
echo ----------------------------------------------------------------------------------------------------
goto WAIT_EXIT
:LOAD_LOCALIZED_TEXT
set "WINLAMA_LOCALIZATION_VALUE="
set "WINLAMA_LOCALIZATION_MATCHES=0"
for /F "tokens=1,* delims==" %%K in ('%SystemRoot%\System32\findstr.exe /B /L /C:"%~1=" "%WINLAMA_LOCALIZATION_PATH%" 2^>nul') do (
    if "%%K"=="%~1" (
        set /A WINLAMA_LOCALIZATION_MATCHES+=1
        set "WINLAMA_LOCALIZATION_VALUE=%%L"
    )
)
if not "%WINLAMA_LOCALIZATION_MATCHES%"=="1" set "WINLAMA_LOCALIZATION_VALUE=%~1"
if not defined WINLAMA_LOCALIZATION_VALUE set "WINLAMA_LOCALIZATION_VALUE=%~1"
set "%~2=%WINLAMA_LOCALIZATION_VALUE%"
exit /b 0
:USE_LOCALIZATION_FALLBACK
set "WINLAMA_WINDOW_TITLE=Winlama Launcher"
set "WINLAMA_OPERATION_SUMMARY=ISLEM OZETI"
set "WINLAMA_LEVEL_ERROR=HATA"
set "WINLAMA_POWERSHELL_MISSING=Windows PowerShell bulunamadi."
set "WINLAMA_PROMPT_SELECTION=Seçiminiz"
set "WINLAMA_LEVEL_WARNING=UYARI"
set "WINLAMA_COMMAND_INVALID=Bos veya gecersiz komut kabul edilmedi."
exit /b 0
:GET_TEXT_LENGTH
set "WINLAMA_LENGTH_VALUE=!%~1!"
set /A WINLAMA_LENGTH=0
:GET_TEXT_LENGTH_NEXT
if not defined WINLAMA_LENGTH_VALUE goto GET_TEXT_LENGTH_DONE
set "WINLAMA_LENGTH_VALUE=!WINLAMA_LENGTH_VALUE:~1!"
set /A WINLAMA_LENGTH+=1
goto GET_TEXT_LENGTH_NEXT
:GET_TEXT_LENGTH_DONE
set "%~2=!WINLAMA_LENGTH!"
exit /b 0