@echo off
REM ============================================================
REM  promotion-pass.cmd - weekly promotion-agent runner (Windows)
REM
REM  Register with Task Scheduler, e.g.:
REM    schtasks /create /tn "Vault-PromotionAgent" /tr "\"C:\path\to\vault\.claude\scripts\promotion-pass.cmd\"" /sc weekly /d SAT /st 20:00
REM
REM  READ THIS BEFORE SCHEDULING IT. Unlike the dream-agent, the promotion-agent
REM  WRITES into 31-standards\ and 40-llm-wiki\wiki\ - the long tier that steers
REM  every future session. Its only guard is its own definition, which requires a
REM  git snapshot before any write. Run it manually a few times first.
REM
REM  The same three Windows traps documented in dream-pass.cmd apply here:
REM  parenthesise every (echo ...)>> "log"; always pass -p or the agent starts an
REM  interactive session and exits 0 having done nothing; and judge health by
REM  LastTaskResult plus the log, never by the task's State column.
REM ============================================================

cd /d "%~dp0..\.."
if errorlevel 1 exit /b 1

if not exist ".claude\logs" mkdir ".claude\logs"

if not defined CLAUDE_BIN set "CLAUDE_BIN=claude"

REM Snapshot BOTH signals before the run. A pass that legitimately promotes
REM nothing is a valid outcome, so accept either a new long-tier note OR real log
REM growth - but never neither. This is what turns a future silent no-op into a
REM non-zero LastTaskResult instead of a green run that produced nothing.
set "BEFORE_COUNT=0"
for /f %%N in ('dir /b /s "31-standards\*.md" "40-llm-wiki\wiki\*.md" 2^>nul ^| find /c /v ""') do set "BEFORE_COUNT=%%N"
set "LOGSIZE_BEFORE=0"
if exist ".claude\logs\promotion-agent.log" for %%A in (".claude\logs\promotion-agent.log") do set "LOGSIZE_BEFORE=%%~zA"

(echo [%DATE% %TIME%] starting promotion-agent weekly pass)>> ".claude\logs\promotion-agent.log"

"%CLAUDE_BIN%" -p "Run this week's promotion pass per your instructions: scan 20-projects/_logs/ for promotion candidates, run the trust sweep over the long-term notes, and write the ones that meet the promotion bar. Follow your write-safety rules -- take a git snapshot before any write and abort on unexpected drift." --agent promotion-agent --permission-mode acceptEdits >> ".claude\logs\promotion-agent.log" 2>&1
set "RC=%ERRORLEVEL%"

(echo [%DATE% %TIME%] promotion-agent exited with code %RC%)>> ".claude\logs\promotion-agent.log"

set "AFTER_COUNT=0"
for /f %%N in ('dir /b /s "31-standards\*.md" "40-llm-wiki\wiki\*.md" 2^>nul ^| find /c /v ""') do set "AFTER_COUNT=%%N"
set "LOGSIZE_AFTER=0"
if exist ".claude\logs\promotion-agent.log" for %%A in (".claude\logs\promotion-agent.log") do set "LOGSIZE_AFTER=%%~zA"
set /a "LOG_GREW=LOGSIZE_AFTER-LOGSIZE_BEFORE"

set "HAS_ARTIFACT=0"
if %AFTER_COUNT% GTR %BEFORE_COUNT% set "HAS_ARTIFACT=1"
set "HAS_SUMMARY=0"
if %LOG_GREW% GTR 500 set "HAS_SUMMARY=1"

if "%RC%"=="0" if "%HAS_ARTIFACT%"=="0" if "%HAS_SUMMARY%"=="0" (
  (echo [%DATE% %TIME%] NO-ARTIFACT: exited 0 with no new long-tier note and log grew only %LOG_GREW% bytes ^(threshold 500^))>> ".claude\logs\promotion-agent.log"
  exit /b 1
)

exit /b %RC%
