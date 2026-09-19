@echo off
REM ============================================================
REM  vault-retention.cmd - weekly archiving runner (Windows)
REM
REM  A thin wrapper. All of the logic - what may move, the run lock, the
REM  put-back and the recovery record - lives in vault-retention.sh, run here
REM  through Git Bash, so Windows and macOS/Linux can never drift apart. Git for
REM  Windows is already required: the hooks themselves are bash.
REM
REM  Register with Task Scheduler, e.g. Sundays at 04:00:
REM    schtasks /create /tn "Vault-Retention" /tr "\"C:\path\to\vault\.claude\scripts\vault-retention.cmd\"" /sc weekly /d SUN /st 04:00
REM
REM  Set ExecutionTimeLimit to more than the run can take, and remember that
REM  with MultipleInstances=IgnoreNew one hung run suppresses every later one
REM  for the whole limit. See docs/setup.md for the formula.
REM
REM  Arguments are passed through, so --dry-run and --adopt-legacy work here too.
REM  Environment passed through to the script: RETENTION_DAYS, RETENTION_MAX_MOVES,
REM  VAULT_STATE_DIR, RUN_LOCK_WAIT, RUN_LOCK_POLL, RUNNER_GIT_TIMEOUT.
REM  Set BASH_EXE if Git Bash is not in a standard location.
REM
REM  WINDOWS TRAPS ENCODED BELOW - do not "simplify" them away:
REM  1. Never search PATH for bash. C:\Windows\System32\bash.exe is WSL, not
REM     Git Bash, and would run the script in a different filesystem entirely.
REM  2. `echo ... %RC%>> "log"` makes cmd parse the trailing digit as a file
REM     handle, so the line and the exit code are lost. Always parenthesise:
REM     (echo ...)>> "log". Keep literal ")" out of the echoed text.
REM  3. `exit /b %RC%` is what makes Task Scheduler's LastTaskResult mean
REM     anything. Judge task health by LastTaskResult plus the log on disk,
REM     never by the task's State column.
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

(echo [%DATE% %TIME%] ERROR: Git Bash not found. Install Git for Windows or set BASH_EXE.)>> ".claude\logs\vault-retention.log"
exit /b 127

:have_bash
REM Forward slashes: Git Bash's dirname does not treat "\" as a separator, so a
REM backslashed script path would resolve the vault root to the wrong place.
set "SCRIPT=%~dp0vault-retention.sh"
set "SCRIPT=%SCRIPT:\=/%"

"%BASH_EXE%" "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"
exit /b %RC%
