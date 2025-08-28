@echo off
setlocal

:: Check if we are running in a Git Bash (MinTTY) environment.
:: The "TERM" variable is a good indicator. In cmd.exe it's typically not set.
:: In Git Bash, it's often "cygwin" or "xterm".
if "%TERM%" == "cygwin" goto :run_script
if "%TERM%" == "xterm" goto :run_script

:: If not in Git Bash, find bash.exe and re-launch.
echo Not running in Git Bash. Attempting to launch Git Bash...

set "GIT_BASH_PATH="
if exist "%ProgramFiles%\Git\bin\bash.exe" set "GIT_BASH_PATH=%ProgramFiles%\Git\bin\bash.exe"
if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "GIT_BASH_PATH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "GIT_BASH_PATH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"

if defined GIT_BASH_PATH goto :found_bash

:: This block runs if bash.exe was not found.
echo.
echo ERROR: Git Bash (bash.exe) not found in common locations.
echo Please install Git for Windows and ensure it's in your PATH or installed in the default directory.
echo You can also run this script from a Git Bash terminal directly.
pause
exit /b 1

:found_bash
echo Found Git Bash at: %GIT_BASH_PATH%
echo Launching UltimateComfy.sh...
echo.

:: Execute the .sh script using the found bash.exe.
:: We pass the path to the .sh script. %~dp0 expands to the directory of the batch file.
"%GIT_BASH_PATH%" --login -i "%~dp0UltimateComfy.sh"

:: Pause at the end to see any final messages from the script if it exits quickly.
echo.
echo Script execution finished. Press any key to exit this window.
pause
goto :eof

:run_script
echo Already in a Git Bash environment. Running script directly.
bash "%~dp0/UltimateComfy.sh"
echo.
echo Script execution finished.
:: No pause here, as the user is already in a shell.

:eof
endlocal
