@echo off
setlocal
cd /d "%~dp0"
set "RESULT_FILE=%~dp0INSTALL_MATCHING_YANEOURAOU_EXE_RESULT.txt"
set "VERIFY_FILE=%~dp0engine\MATCHING_ENGINE_VERIFIED.txt"
set "ENGINE_EXE=%~dp0engine\yaneuraou.exe"
set "EVAL_NN=%~dp0engine\eval\nn.bin"
set "NEED_INSTALL=1"
set "PS_CMD="

where powershell >nul 2>nul
if not errorlevel 1 set "PS_CMD=powershell"
if not defined PS_CMD (
  where pwsh >nul 2>nul
  if not errorlevel 1 set "PS_CMD=pwsh"
)
if not defined PS_CMD (
  echo.
  echo PowerShell was not found.
  echo Install Windows PowerShell 5.1 or PowerShell 7 and try again.
  echo.
  echo press any key to close.
  pause >nul
  exit /b 1
)

echo.
echo local yaneuraou bridge launcher
echo.
if exist "%ENGINE_EXE%" if exist "%EVAL_NN%" (
  if exist "%VERIFY_FILE%" (
    findstr /C:"verified=OK" "%VERIFY_FILE%" >nul 2>nul
    if not errorlevel 1 set "NEED_INSTALL=0"
  )
  if "%NEED_INSTALL%"=="1" if exist "%RESULT_FILE%" (
    findstr /C:"finalProbe=OK" "%RESULT_FILE%" >nul 2>nul
    if not errorlevel 1 set "NEED_INSTALL=0"
  )
)

if "%NEED_INSTALL%"=="1" (
  echo setup required. engine and eval will be downloaded automatically.
  %PS_CMD% -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0INSTALL_MATCHING_YANEOURAOU_EXE.ps1"
  if errorlevel 1 (
    echo.
    echo setup failed. bridge will not start.
    echo check INSTALL_MATCHING_YANEOURAOU_EXE_RESULT.txt
    echo check C:\Users\adazi\Downloads\powershell\*.txt
    echo.
    echo press any key to close.
    pause >nul
    exit /b 1
  )
) else (
  echo verified engine and eval were found. skipping setup.
)

echo.
echo starting bridge server...
%PS_CMD% -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0bridge_server.ps1"
echo.
echo bridge exited. press any key to close.
pause >nul
endlocal
