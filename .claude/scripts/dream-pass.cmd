@echo off
REM ============================================================
REM  dream-pass.cmd - nightly dream-agent runner (Windows)
REM
REM  Register with Task Scheduler, e.g.:
REM    schtasks /create /tn "Vault-DreamAgent" /tr "\"C:\path\to\vault\.claude\scripts\dream-pass.cmd\"" /sc daily /st 23:00
REM
REM  THREE WINDOWS TRAPS ARE ENCODED BELOW. Do not "simplify" them away.
REM
REM  1. `echo ... %RC%>> "log"` does NOT work. cmd parses the expanded trailing
REM     digit as a file-handle number - "0>>" means redirect stdin - so the line
REM     goes to the console and the exit code is lost. Always use the
REM     (echo ...)>> "log" parenthesised form. Keep any literal ")" out of the
REM     echoed text, because it closes the group early.
REM
REM  2. `claude --agent X` with NO -p starts an INTERACTIVE session. Under Task
REM     Scheduler there is no TTY and stdin is NUL, so it reads EOF and exits 0
REM     within seconds having done nothing at all - and the scheduler records
REM     success. Always pass -p.
REM
REM  3. Task health is LastTaskResult plus a log on disk, NEVER the task's State
REM     column. A task can sit at "Ready" while every run has been dying for
REM     weeks. `exit /b %RC%` below is what makes LastTaskResult meaningful;
REM     without it the status is merely the last command's, and a trailing echo
REM     would report success over any failure.
REM
REM  Also set ExecutionTimeLimit on the task. With MultipleInstances=IgnoreNew,
REM  one hung run suppresses every later run for the whole limit.
REM ============================================================

REM Resolve the vault root from this script's own location (%~dp0 = its folder).
cd /d "%~dp0..\.."
if errorlevel 1 exit /b 1

if not exist ".claude\logs" mkdir ".claude\logs"

REM Set CLAUDE_BIN if claude.exe is not on the PATH that Task Scheduler inherits.
REM A scheduled task does NOT get your interactive PATH.
if not defined CLAUDE_BIN set "CLAUDE_BIN=claude"

for /f "tokens=2 delims==" %%D in ('wmic os get LocalDateTime /value 2^>nul ^| find "="') do set "LDT=%%D"
set "TODAY=%LDT:~0,4%-%LDT:~4,2%-%LDT:~6,2%"
set "JOURNAL=20-projects\_logs\dream-%TODAY%.md"

(echo [%DATE% %TIME%] starting dream-agent)>> ".claude\logs\dream-agent.log"

"%CLAUDE_BIN%" -p "Run tonight's dream/consolidation pass and write today's dream journal per your instructions." --agent dream-agent --permission-mode acceptEdits >> ".claude\logs\dream-agent.log" 2>&1
set "RC=%ERRORLEVEL%"

(echo [%DATE% %TIME%] dream-agent exited with code %RC%)>> ".claude\logs\dream-agent.log"

REM ARTIFACT ASSERTION. An exit code says the process ended; it does not say the
REM pass did anything. The dream-agent's contract is "write exactly one journal",
REM so a 0 with no journal on disk is a failure no matter what the code claims.
if "%RC%"=="0" if not exist "%JOURNAL%" (
  (echo [%DATE% %TIME%] NO-ARTIFACT: exited 0 but %JOURNAL% was not written)>> ".claude\logs\dream-agent.log"
  exit /b 1
)

exit /b %RC%
