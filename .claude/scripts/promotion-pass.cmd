@echo off
REM ============================================================
REM  promotion-pass.cmd - weekly promotion-agent runner (Windows)
REM
REM  A thin wrapper. All of the logic - the watchdog timeout, the write fence,
REM  the artifact assertion - lives in promotion-pass.sh, run here through Git
REM  Bash, so Windows and macOS/Linux can never drift apart.
REM
REM  READ THIS BEFORE SCHEDULING IT. The promotion-agent WRITES into
REM  31-standards\ and 40-llm-wiki\wiki\ - the long tier that steers every future
REM  session. Run it manually a few times first.
REM
REM  Register with Task Scheduler, e.g.:
REM    schtasks /create /tn "Vault-PromotionAgent" /tr "\"C:\path\to\vault\.claude\scripts\promotion-pass.cmd\"" /sc weekly /d SAT /st 20:00
REM
REM  Environment passed through to the script: CLAUDE_BIN, PROMOTION_PASS_TIMEOUT.
REM  Set BASH_EXE if Git Bash is not in a standard location.
REM
REM  The three Windows traps documented in dream-pass.cmd apply here: never
REM  search PATH for bash (that finds WSL), parenthesise every (echo ...)>> "log",
REM  and judge health by LastTaskResult plus the log, never by State.
REM ============================================================

setlocal
cd /d "%~dp0..\.."
if errorlevel 1 exit /b 1
if not exist ".claude\logs" mkdir ".claude\logs"

if defined BASH_EXE if exist "%BASH_EXE%" goto :have_bash
set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if exist "%BASH_EXE%" goto :have_bash
set "BASH_EXE=%ProgramW6432%\Git\bin\bash.exe"
if exist "%BASH_EXE%" goto :have_bash
set "BASH_EXE=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if exist "%BASH_EXE%" goto :have_bash

(echo [%DATE% %TIME%] ERROR: Git Bash not found. Install Git for Windows or set BASH_EXE.)>> ".claude\logs\promotion-agent.log"
exit /b 127

:have_bash
set "SCRIPT=%~dp0promotion-pass.sh"
set "SCRIPT=%SCRIPT:\=/%"

"%BASH_EXE%" "%SCRIPT%"
set "RC=%ERRORLEVEL%"
exit /b %RC%
