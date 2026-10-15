@echo off
setlocal
cd /d "%~dp0"

dart run tool\windows_oauth.dart --build
if errorlevel 1 (
    echo.
    echo Falha ao compilar o LocresHub.
    if not defined CI pause
    exit /b 1
)

echo.
echo Compilacao concluida:
echo build\windows\x64\runner\Release\locres_hub.exe
if not defined CI pause
exit /b 0
