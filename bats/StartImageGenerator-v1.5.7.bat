@echo off
REM =====================================================================
REM  AI Adventure Master - local image generator (Windows)
REM
REM  ONE file for local image generation. It starts the local image worker
REM  (imagefree.net's own API) on 127.0.0.1:8002 and connects this
REM  computer to the site, so the free background pictures are drawn with
REM  THIS machine's own IP instead of the site's shared server IP:
REM
REM    - the free image service is drawn here: the worker
REM      creates the imagefree job and downloads the picture from this
REM      machine, so the prompt and the bytes never touch the site server,
REM    - AI Horde and Pollinations calls are relayed here as well, through
REM      the worker's /proxy route, so they leave from this machine too and
REM      the shared server IP never spends its per-IP limits on them.
REM
REM  The site decides per request: with this file running it uses the
REM  connected generator, and without it (or if the relay fails) it simply
REM  carries on from the server.
REM
REM  It uses the connector's agent mode (tools\StartLocalAI-connector.ps1)
REM  with image offload on. No local AI is needed or looked for: this file
REM  never becomes a local-model connector.
REM
REM  Usage: download it and double-click it (or run "StartImageGenerator").
REM  Keep this window open while you play: closing it stops the worker and
REM  disconnects this computer.
REM
REM  Built by tools\build-imagegenerator-bat.ps1 from:
REM    tools\StartLocalAI-connector.ps1   (the WebSocket half)
REM    tools\StartLocalImageWorker.ps1    (starts the Python worker)
REM    tools\local-image-worker.py        (the worker itself)
REM =====================================================================

setlocal EnableExtensions
title AI Adventure Master - image generator v1.5.7

set "VERSION=1.5.7"
REM  The one site this file is for, written in on purpose - see
REM  StartLocalAI.bat.in for the same reasoning.
set "HOMESITE=https://aiadventuremaster.space"

REM  Everything lives in a stable folder in the user's own profile, not in
REM  %TEMP%: the worker's Python virtualenv is created next to its script,
REM  and keeping both there means the first run installs its tools once and
REM  every later run starts in seconds.
set "BASEDIR=%LOCALAPPDATA%\AIAdventureMaster\image-generator"
set "PS1=%BASEDIR%\aim-connector.ps1"
set "WORKERPS1=%BASEDIR%\image-worker.ps1"
set "WORKERPY=%BASEDIR%\local-image-worker.py"
set "PSERR=%BASEDIR%\connector-%RANDOM%.err"
set "TRACE=%LOCALAPPDATA%\AIAdventureMaster\image-generator-trace.log"
set "STATEDIR=%LOCALAPPDATA%\AIAdventureMaster"
set "STATE=%STATEDIR%\connector-image.json"
set "IMAGEPORT=8002"
set "SITE="
set "TOKEN="
set "AIMEND="
set "AGENTPID="
set "WORKERPID="
set "misses=0"

if not exist "%BASEDIR%" md "%BASEDIR%" >nul 2>&1

echo.
echo   AI Adventure Master - local image generator v%VERSION%
echo   --------------------------------------------------
echo.

echo   [1/5] Preparing the image worker...
set "EXVER="
if exist "%BASEDIR%\.extracted-version" set /p EXVER=<"%BASEDIR%\.extracted-version"
if "%EXVER%"=="%VERSION%" if exist "%WORKERPY%" if exist "%WORKERPS1%" if exist "%PS1%" goto :files_cached
call :write_files
if not exist "%WORKERPY%" goto :extract_failed
if not exist "%WORKERPS1%" goto :extract_failed
if not exist "%PS1%" goto :extract_failed
> "%BASEDIR%\.extracted-version" echo %VERSION%
echo         Files ready.
goto :files_done
:files_cached
echo         Files ready (up to date).
:files_done

echo.
echo   [2/5] Starting the image worker...
call :worker_up
if not errorlevel 1 goto :worker_already_up
call :start_worker
echo.
echo         The first run downloads a private Python and its packages
echo         once (~2 minutes) and can take a little longer on a slow
echo         connection. Its setup window closes by itself once the worker
echo         is running in the background - keep THIS window open while
echo         you play.
echo.
goto :after_start_worker
:worker_already_up
set "WORKERREADY=1"
echo         Image worker already running on %IMAGEPORT% - skipping setup.
:after_start_worker

echo.
echo   [3/5] Waiting for the image worker to answer on port %IMAGEPORT%...
call :wait_worker
if not defined WORKERREADY goto :worker_failed
call :trace "image worker ready on %IMAGEPORT%"
echo         Image worker is ready.

echo.
echo   [4/5] Working out your address on the site...
call :resolve_site
if not defined SITE goto :nosite
call :resolve_token
if not defined TOKEN goto :nosite
set "AIMEND=%SITE%/ai/%TOKEN%/v1"
call :save_state
call :trace "site=%SITE% endpoint=%AIMEND%"
echo         Site:    %SITE%

echo.
echo   [5/5] Connecting this computer to the site...
where powershell >nul 2>&1
if errorlevel 1 goto :noproxy
call :start_agent
if not defined AGENTPID goto :agent_failed
call :trace "agent started, pid %AGENTPID%"

echo.
echo   Done.
echo.
echo   Image generation now runs on THIS computer: the free gateway, and
echo   AI Horde / Pollinations calls relayed from here.
echo   Keep this window open while you play - closing it stops the worker
echo   and disconnects this computer.
echo.
echo   Press Ctrl+C or close this window to stop.
goto :wait

REM ---------------------------------------------------------------------
REM  Keep the window open and watch both halves. The connector reconnects
REM  on its own; if either process is truly gone, say so.
REM ---------------------------------------------------------------------
:wait
ping -n 4 127.0.0.1 >nul
call :agent_alive
if not defined ALIVE goto :agent_died
call :find_worker
if not defined FOUND_PID goto :worker_died
set "misses=0"
goto :wait

:worker_died
REM  The agent still runs, but no images can be drawn without the worker,
REM  so say so once and keep watching - the window is not closed over it.
if %misses% GEQ 1 goto :wait
set /a misses+=1
echo.
echo   The image worker has stopped, so images cannot be drawn any more.
echo   Close this window and run the file again to restart it.
goto :wait

:worker_failed
call :cleanup
echo.
echo         The image worker did not start, or did not answer on port
echo         %IMAGEPORT%.
echo.
echo         Python does NOT have to be installed in advance - the worker
echo         downloads its own copy on the first run. The usual causes are:
echo           - no internet, or a proxy/firewall blocks python.org,
echo             bootstrap.pypa.io or pypi.org;
echo           - antivirus blocked the hidden Python window;
echo           - port %IMAGEPORT% is already taken by another program.
echo.
echo         The worker's own setup log (with the exact reason) is here:
echo           %BASEDIR%\image-worker.log
echo.
echo         A log of this run was left here:
echo           %TRACE%
echo.
call :stay
endlocal
exit /b 3

:agent_died
call :trace "agent process is gone"
call :cleanup
echo.
echo   The connector stopped. Close this window and run the file again.
call :stay
endlocal
exit /b 0

:agent_failed
call :cleanup
echo.
echo         The connector process did not start.
echo.
if exist "%PSERR%" for /f "usebackq delims=" %%L in ("%PSERR%") do echo         %%L
echo.
echo         Close any other copy of this file and run it again.
echo.
echo         A log of this run was left here:
echo           %TRACE%
echo.
call :stay
endlocal
exit /b 3

:extract_failed
echo.
echo         This copy of the file is damaged: its own scripts could not be
echo         unpacked. Download it again from the Settings page of the site.
echo.
call :trace "embedded files could not be written"
call :stay
endlocal
exit /b 4

REM ---------------------------------------------------------------------
REM  No website to talk to. Cannot happen with a normal download - the
REM  address is written into the file - and it is here only so that a file
REM  that was edited or truncated still says something plain.
REM ---------------------------------------------------------------------
:nosite
call :cleanup
echo         This copy of the file is damaged: the address of the site it
echo         belongs to is missing from it.
echo.
echo         Download the latest StartImageGenerator installer from the
echo         Settings page of the site, and run the copy you get there.
echo.
call :trace "no site address"
call :stay
endlocal
exit /b 4

:noproxy
call :cleanup
echo         The connector could not start.
echo.
echo         This file needs Windows PowerShell, which comes with Windows.
echo         Close any other copy of this file and run it again.
echo.
if exist "%PSERR%" for /f "usebackq delims=" %%L in ("%PSERR%") do echo         %%L
echo.
call :trace "connector did not start"
call :stay
endlocal
exit /b 3

REM ---------------------------------------------------------------------
REM  Keep this window on screen until it has actually been read (same
REM  reasoning as in StartLocalAI.bat.in).
REM ---------------------------------------------------------------------
:stay
echo.
echo   Press any key to close this window.
pause >nul 2>&1
timeout /t 4 /nobreak >nul 2>&1
goto :eof

REM ---------------------------------------------------------------------
REM  A plain text trail of what happened, because the window itself can
REM  disappear before anyone reads it.
REM ---------------------------------------------------------------------
:trace
>>"%TRACE%" echo %date% %time% %~1
goto :eof

REM ---------------------------------------------------------------------
REM  Which website to talk to: always the one it was downloaded from.
REM ---------------------------------------------------------------------
:resolve_site
set "SITE=%HOMESITE%"
:trim_site
if "%SITE:~-1%"=="/" (
    set "SITE=%SITE:~0,-1%"
    goto :trim_site
)
if not "%SITE:~0,8%"=="https://" if not "%SITE:~0,7%"=="http://" goto :nosite
if not defined SITE goto :nosite
goto :eof

REM ---------------------------------------------------------------------
REM  The token: 32 random bytes, made once on this computer and then kept.
REM  It is shared with StartLocalAI.bat (same connector.json), so the two
REM  files present the same address for this machine.
REM ---------------------------------------------------------------------
:resolve_token
if exist "%STATE%" for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "if (Test-Path '%STATE%') { $j = Get-Content -Raw '%STATE%' -ErrorAction SilentlyContinue | ConvertFrom-Json; if ($j.token) { Write-Output ($j.token) } }" 2^>nul`) do (
    if not defined TOKEN set "TOKEN=%%T"
)
if defined TOKEN goto :eof
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "$b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')"`) do set "TOKEN=%%T"
if not defined TOKEN goto :nosite
goto :eof

:save_state
if not exist "%STATEDIR%" md "%STATEDIR%" >nul 2>&1
powershell -NoProfile -Command "$o = [ordered]@{ site = '%SITE%'; token = '%TOKEN%'; port = 0; basePath = 'ROOT' }; [IO.File]::WriteAllText('%STATE%', ($o | ConvertTo-Json))" >nul 2>&1
goto :eof

REM ---------------------------------------------------------------------
REM  Start the worker in its OWN window. That window installs whatever is
REM  missing, then starts the worker (uvicorn) in the background and closes
REM  itself - so there is no long-lived powershell here to wait for. The
REM  readiness of the worker itself is confirmed by :wait_worker below.
REM ---------------------------------------------------------------------
:start_worker
set "WORKERPID="
start "AI Adventure Master - image worker" powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKERPS1%"
ping -n 2 127.0.0.1 >nul
goto :eof

REM ---------------------------------------------------------------------
REM  Wait until the worker answers on its health route. The first run can
REM  spend minutes installing, so this is patient. It keeps waiting only
REM  while something is still bringing the worker up - the setup window
REM  (installing) or the worker process itself. If neither exists and the
REM  health route is still down, the worker died during startup.
REM ---------------------------------------------------------------------
:wait_worker
set "WORKERREADY="
set "WORKERPID="
set /a wtries=0
:ww_loop
call :worker_up
if not errorlevel 1 goto :ww_ready
set "FOUND_PID="
call :find_pid "%WORKERPS1%"
if defined FOUND_PID goto :ww_more
set "FOUND_PID="
call :find_worker
if defined FOUND_PID goto :ww_more
goto :eof
:ww_more
set /a wtries+=1
if %wtries% GEQ 300 goto :eof
ping -n 4 127.0.0.1 >nul
goto :ww_loop
:ww_ready
set "WORKERREADY=1"
set "FOUND_PID="
call :find_worker
if defined FOUND_PID set "WORKERPID=%FOUND_PID%"
goto :eof

:worker_up
set "WCODE="
for /f "usebackq delims=" %%C in (`curl.exe -s -o NUL -m 3 -w "%%{http_code}" "http://127.0.0.1:%IMAGEPORT%/healthz" 2^>nul`) do set "WCODE=%%C"
if "%WCODE%"=="200" exit /b 0
exit /b 1

REM ---------------------------------------------------------------------
REM  Start the connector itself: the PowerShell half written into %PS1%.
REM  No local AI (TargetPort 0) and image offload on (-Image), so it only
REM  announces image capability and routes image jobs to the local worker.
REM  No window of its own - it shares the console being watched.
REM ---------------------------------------------------------------------
:start_agent
set "AGENTPID="
start "aim-connector" /b powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode agent -Site "%SITE%" -Token "%TOKEN%" -TargetPort 0 -BasePath ROOT -Image -ImagePort %IMAGEPORT% >"%PSERR%" 2>&1
set /a waits=0
:sa_pid
ping -n 2 127.0.0.1 >nul
set /a waits+=1
set "FOUND_PID="
call :find_pid "%PS1%"
if defined FOUND_PID (
    set "AGENTPID=%FOUND_PID%"
    goto :eof
)
if %waits% GEQ 15 goto :eof
goto :sa_pid

REM ---------------------------------------------------------------------
REM  Is the connector still there? Found by its command line.
REM  The pipes below live inside the quoted -Command argument, so they are
REM  NOT escaped as ^| - see StartLocalAI.bat.in for the full reasoning.
REM ---------------------------------------------------------------------
:agent_alive
set "ALIVE="
call :find_pid "%PS1%"
if defined FOUND_PID set "ALIVE=1"
goto :eof

:find_pid
set "FOUND_PID="
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*%~1*' } | Select-Object -First 1 -ExpandProperty ProcessId" 2^>nul`) do set "FOUND_PID=%%P"
goto :eof

REM ---------------------------------------------------------------------
REM  Is the worker itself still there? The worker is the python process
REM  running local-image-worker.py - NOT the setup window, which closes by
REM  design once the worker is up. Found by the script name in its command
REM  line, so it works no matter which interpreter the venv uses.
REM ---------------------------------------------------------------------
:find_worker
set "FOUND_PID="
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*local-image-worker.py*' -and $_.Name -like 'python*' } | Select-Object -First 1 -ExpandProperty ProcessId" 2^>nul`) do set "FOUND_PID=%%P"
goto :eof

:stop_agent
if defined AGENTPID taskkill /PID %AGENTPID% /F >nul 2>&1
set "AGENTPID="
goto :eof

REM ---------------------------------------------------------------------
REM  Stop the worker. Prefer the PID captured at startup; if that is gone
REM  (e.g. this file lost track of it), fall back to finding the python
REM  worker by name so a stray process is not left listening on the port.
REM ---------------------------------------------------------------------
:stop_worker
if not defined WORKERPID call :find_worker
if defined FOUND_PID set "WORKERPID=%FOUND_PID%"
if defined WORKERPID taskkill /PID %WORKERPID% /T /F >nul 2>&1
set "WORKERPID="
goto :eof

REM ---------------------------------------------------------------------
REM  Stop what this file started. The unpacked scripts and the worker's
REM  virtualenv are left in place on purpose, so the next run is fast.
REM ---------------------------------------------------------------------
:cleanup
call :stop_agent
call :stop_worker
del /q "%PSERR%" >nul 2>&1
goto :eof

REM ---------------------------------------------------------------------
REM  Put the three embedded files on disk:
REM    %PS1%        the connector PowerShell half
REM    %WORKERPS1%  the worker launcher
REM    %WORKERPY%   the worker itself (Python)
REM  The text travels as base64 because a batch file cannot carry a script
REM  block with braces and quotes intact. The plain-text originals live in
REM  tools\ and are the source of truth.
REM ---------------------------------------------------------------------
:write_files
>"%PS1%.b64" echo 77u/IyBUaGUgUG93ZXJTaGVsbCBoYWxmIG9mIFN0YXJ0TG9jYWxBSS5iYXQuDQojDQojIEl0IGlz
>>"%PS1%.b64" echo IGtlcHQgaGVyZSBhcyBhIHBsYWluIGZpbGUgYW5kIHRoZSAuYmF0IGNhcnJpZXMgYSBiYXNlNjQg
>>"%PS1%.b64" echo Y29weSBvZiBpdCwgc28NCiMgdGhhdCBjaGFuZ2luZyB0aGlzIHRleHQgZG9lcyBub3QgbWVhbiBy
>>"%PS1%.b64" echo ZS10eXBpbmcgOTggbGluZXMgb2YgYmFzZTY0IGludG8gYQ0KIyBiYXRjaCBmaWxlIGJ5IGhhbmQu
>>"%PS1%.b64" echo IFJ1biB0b29scy9idWlsZC1jb25uZWN0b3ItYmF0LnBzMSB0byByZWdlbmVyYXRlIGl0Lg0KIw0K
>>"%PS1%.b64" echo IyBPbmUgc2NyaXB0LCB0d28gam9icywgYmVjYXVzZSBib3RoIGFyZSAidGFsayB0byB0aGUgbG9j
>>"%PS1%.b64" echo YWwgQUkiOg0KIw0KIyAgIC1Nb2RlIGFnZW50ICB0aGUgbm9ybWFsIG9uZS4gT3BlbnMgYW4gT1VU
>>"%PS1%.b64" echo R09JTkcgV2ViU29ja2V0IHRvIHRoZSBzaXRlIGFuZA0KIyAgICAgICAgICAgICAgICB3YWl0cyBm
>>"%PS1%.b64" echo b3IgaXQgdG8gc2VuZCB3b3JrLiBUaGlzIGlzIHdoYXQgZ2l2ZXMgdGhlIHBsYXllciBhbg0KIyAg
>>"%PS1%.b64" echo ICAgICAgICAgICAgICBhZGRyZXNzIHRoYXQgbmV2ZXIgY2hhbmdlczogaHR0cHM6Ly88c2l0ZT4v
>>"%PS1%.b64" echo YWkvPHRva2VuPi92MQ0KIyAgICAgICAgICAgICAgICBiZWxvbmdzIHRvIHRoZSBzaXRlLCBzdXJ2
>>"%PS1%.b64" echo aXZlcyBldmVyeSByZXN0YXJ0LCBhbmQgbmVlZHMgbm90aGluZw0KIyAgICAgICAgICAgICAgICBv
>>"%PS1%.b64" echo cGVuIG9uIHRoZSBwbGF5ZXIncyByb3V0ZXIsIGJlY2F1c2UgdGhlIGNvbm5lY3Rpb24gaXMgbWFk
>>"%PS1%.b64" echo ZQ0KIyAgICAgICAgICAgICAgICBmcm9tIGhlcmUgdG8gdGhlcmUgYW5kIG5vdCB0aGUgb3RoZXIg
>>"%PS1%.b64" echo d2F5IHJvdW5kLg0KIw0KIyAgIC1Nb2RlIHJlbGF5ICB0aGUgb2xkZXIgYmVoYXZpb3VyLCBrZXB0
>>"%PS1%.b64" echo IGFzIGEgZmFsbGJhY2suIExpc3RlbnMgb24gYSBsb2NhbA0KIyAgICAgICAgICAgICAgICBwb3J0
>>"%PS1%.b64" echo IGFuZCBwdW1wcyBIVFRQIHRocm91Z2ggdG8gdGhlIGxvY2FsIEFJIHdpdGggYSBsb2NhbCBIb3N0
>>"%PS1%.b64" echo DQojICAgICAgICAgICAgICAgIGhlYWRlciwgc28gdGhhdCBhbiBleHRlcm5hbCB0dW5uZWwgKENs
>>"%PS1%.b64" echo b3VkZmxhcmUgYW5kIGZyaWVuZHMpIGNhbg0KIyAgICAgICAgICAgICAgICBwb2ludCBhdCBpdC4g
>>"%PS1%.b64" echo U3RpbGwgbmVlZGVkIGJlY2F1c2UgYSB0dW5uZWwgc2VuZHMgaXRzIG93biBkb21haW4NCiMgICAg
>>"%PS1%.b64" echo ICAgICAgICAgICAgYXMgSG9zdCwgYW5kIHNldmVyYWwgbG9jYWwgQUlzIChPbGxhbWEgYW1vbmcg
>>"%PS1%.b64" echo dGhlbSkgYW5zd2VyIDQwMyB0bw0KIyAgICAgICAgICAgICAgICBhbnl0aGluZyB0aGF0IGlzIG5v
>>"%PS1%.b64" echo dCBsb2NhbGhvc3QuDQojDQojIEFnZW50IG1vZGUgY2FuIGFsc28gaGFuZCB0aGlzIGZpbGUgb2Zm
>>"%PS1%.b64" echo bG9hZGVkIHdvcmsgZm9yIEZyZWUgQUk6IGltYWdlDQojIGdlbmVyYXRpb24gKC1JbWFnZSkgYW5k
>>"%PS1%.b64" echo IGZyZWUgdGV4dCBjb21wbGV0aW9ucyAoLUNoYXQpLCBlYWNoIG9uIGl0cyBvd24gbG9jYWwNCiMg
>>"%PS1%.b64" echo d29ya2VyIHBvcnQuIFdpdGhvdXQgdGhvc2Ugc3dpdGNoZXMgdGhlIGFnZW50IG9ubHkgc2VydmVz
>>"%PS1%.b64" echo IHRoZSBsb2NhbCBBSS4NCiMNCiMgV2h5IHRoZSB0dW5uZWwgaXMgbm8gbG9uZ2VyIHRoZSBtYWlu
>>"%PS1%.b64" echo IHBhdGg6IGZyZWUgdHVubmVsIGFkZHJlc3NlcyBhcmUgcmFuZG9tDQojIGFuZCBzaG9ydC1saXZl
>>"%PS1%.b64" echo ZC4gTWVhc3VyZWQgb24gdGhlIHRlc3QgbWFjaGluZSwgMjcgb2YgMzggbG9jYWxob3N0LnJ1biBy
>>"%PS1%.b64" echo dW5zDQojIGVuZGVkIHdpdGggInR1bm5lbCBhY3Rpdml0eSB0aW1lb3V0IiBhbmQgMjkgcHJpbnRl
>>"%PS1%.b64" echo ZCBhIGRpZmZlcmVudCBkb21haW4NCiMgbWlkLXJ1biwgc28gdGhlIHBsYXllciBoYWQgdG8gcGFz
>>"%PS1%.b64" echo dGUgYSBuZXcgbGluayBldmVyeSBzaW5nbGUgdGltZS4gQ2xvdWRmbGFyZQ0KIyBRdWljayBUdW5u
>>"%PS1%.b64" echo ZWxzIGtlZXAgYSBuYW1lIGZvciB0aGUgc2Vzc2lvbiwgYnV0IG9mZmljaWFsbHkgcmVmdXNlDQoj
>>"%PS1%.b64" echo IFNlcnZlci1TZW50IEV2ZW50cyAtIGFuZCB0aGlzIGdhbWUgc3RyZWFtcyBldmVyeSByZXBseSBp
>>"%PS1%.b64" echo dCBzaG93cy4NCg0KcGFyYW0oDQogICAgW1ZhbGlkYXRlU2V0KCdhZ2VudCcsICdyZWxheScpXQ0K
>>"%PS1%.b64" echo ICAgIFtzdHJpbmddJE1vZGUgPSAnYWdlbnQnLA0KICAgICMgVGhlIHNpdGUgdG8gZGlhbCwgZS5n
>>"%PS1%.b64" echo LiBodHRwczovL3RoZS5zaXRlLiBodHRwOi8vbG9jYWxob3N0OjUwMDAgYWxzbyB3b3Jrcw0KICAg
>>"%PS1%.b64" echo ICMgYW5kIGlzIHdoYXQgdGhlIGFjY2VwdGFuY2UgY2hlY2tzIHVzZS4NCiAgICBbc3RyaW5nXSRT
>>"%PS1%.b64" echo aXRlID0gJycsDQogICAgIyBUaGUgY3JlZGVudGlhbDogMzIgcmFuZG9tIGJ5dGVzIGluIGJhc2U2
>>"%PS1%.b64" echo NHVybCwgaW52ZW50ZWQgb24gdGhlIHBsYXllcidzDQogICAgIyBvd24gY29tcHV0ZXIgb24gdGhl
>>"%PS1%.b64" echo IGZpcnN0IHJ1biBhbmQgbmV2ZXIgc2VudCBhbnl3aGVyZSBidXQgdGhpcyBzaXRlLg0KICAgIFtz
>>"%PS1%.b64" echo dHJpbmddJFRva2VuID0gJycsDQogICAgW2ludF0kVGFyZ2V0UG9ydCA9IDExNDM0LA0KICAgICMg
>>"%PS1%.b64" echo J1JPT1QnIHdoZW4gdGhlIGxvY2FsIEFJIHNlcnZlcyAvbW9kZWxzIGF0IHRoZSByb290LCAnL3Yx
>>"%PS1%.b64" echo JyB3aGVuIGl0IHNlcnZlcw0KICAgICMgL3YxL21vZGVscy4gVGhlIHB1YmxpYyBhZGRyZXNzIGFs
>>"%PS1%.b64" echo d2F5cyBlbmRzIGluIC92MSAodGhhdCBpcyB3aGF0IHRoZQ0KICAgICMgZ2FtZSdzIEVuZHBvaW50
>>"%PS1%.b64" echo IGZpZWxkIGV4cGVjdHMpLCBzbyB0aGUgdHdvIGFyZSBub3QgdGhlIHNhbWUgdGhpbmcsIGFuZA0K
>>"%PS1%.b64" echo ICAgICMgdGhlIHNpdGUgc2VuZHMgcGF0aHMgd2l0aCB0aGF0IC92MSBhbHJlYWR5IHRha2VuIG9m
>>"%PS1%.b64" echo Zi4NCiAgICBbc3RyaW5nXSRCYXNlUGF0aCA9ICcvdjEnLA0KICAgIFtpbnRdJExpc3RlblBvcnQg
>>"%PS1%.b64" echo PSAxMTUwMCwNCiAgICAjIEFubm91bmNlIGltYWdlLWdlbmVyYXRpb24gY2FwYWJpbGl0eTogcm91
>>"%PS1%.b64" echo dGUgZnJlZS1pbWFnZSBqb2JzDQogICAgIyB0byB0aGlzIG1hY2hpbmUgc28gdGhleSBydW4gY2xp
>>"%PS1%.b64" echo ZW50LXNpZGUuDQogICAgW3N3aXRjaF0kSW1hZ2UsDQogICAgW2ludF0kSW1hZ2VQb3J0ID0gODAw
>>"%PS1%.b64" echo MiwNCiAgICAjIEFubm91bmNlIGZyZWUtZ2F0ZXdheSB0ZXh0LWNoYXQgY2FwYWJpbGl0eTogcm91
>>"%PS1%.b64" echo dGUgdGhlIGZyZWUgQUkncyB0ZXh0DQogICAgIyBjb21wbGV0aW9ucyB0byB0aGlzIG1hY2hpbmUn
>>"%PS1%.b64" echo cyBjaGF0IHdvcmtlciBzbyB0aGV5IGxlYXZlIGZyb20gVEhJUw0KICAgICMgbWFjaGluZSdzIElQ
>>"%PS1%.b64" echo IGluc3RlYWQgb2YgdGhlIHNpdGUncyBzaGFyZWQgcG9vbC4gTm8gQ2Ftb3Vmb3g6IHRyeWluZ29w
>>"%PS1%.b64" echo ZW4NCiAgICAjIHRleHQgaGFzIG5vIFR1cm5zdGlsZSwgc28gaXQgaXMgYSBwbGFpbiByZWxheS4g
>>"%PS1%.b64" echo SWdub3JlZCB1bmxlc3MgLUNoYXQuDQogICAgW3N3aXRjaF0kQ2hhdCwNCiAgICBbaW50XSRDaGF0
>>"%PS1%.b64" echo UG9ydCA9IDgwMDMNCikNCg0KIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>>"%PS1%.b64" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0NCiMgUmVsYXkgbW9kZTogYSB0
>>"%PS1%.b64" echo aW55IEhUVFAgcmVsYXkgaW4gZnJvbnQgb2YgdGhlIGxvY2FsIEFJLCBmb3IgdGhlIHR1bm5lbA0K
>>"%PS1%.b64" echo IyBmYWxsYmFjay4gSXQgcmV3cml0ZXMgSG9zdCB0byBhIGxvY2FsIG9uZSBhbmQgcGFzc2VzIGV2
>>"%PS1%.b64" echo ZXJ5dGhpbmcgZWxzZSB0aHJvdWdoLg0KIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>>"%PS1%.b64" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0NCmlmICgkTW9kZSAt
>>"%PS1%.b64" echo ZXEgJ3JlbGF5Jykgew0KICAgICMgVGhyZWUgdGhpbmdzIGl0IG11c3QgZ2V0IHJpZ2h0LCBhbGwg
>>"%PS1%.b64" echo bGVhcm5lZCB0aGUgaGFyZCB3YXk6DQogICAgIw0KICAgICMgICogQ29uY3VycmVuY3kuIFRoZSBi
>>"%PS1%.b64" echo cm93c2VyIHNlbmRzIGEgY2hhdCByZXF1ZXN0IHRoYXQgc3RyZWFtcyBmb3IgbWFueQ0KICAgICMg
>>"%PS1%.b64" echo ICAgc2Vjb25kcy4gQSByZWxheSB0aGF0IGhhbmRsZXMgb25lIGNvbm5lY3Rpb24gYXQgYSB0aW1l
>>"%PS1%.b64" echo IGNhbm5vdCBhbnN3ZXINCiAgICAjICAgIHRoZSBjb25uZWN0b3IncyBvd24gbGl2ZW5lc3MgY2hl
>>"%PS1%.b64" echo Y2sgd2hpbGUgdGhhdCBydW5zLCBzbyB0aGUgY29ubmVjdG9yDQogICAgIyAgICB0aGlua3MgdGhl
>>"%PS1%.b64" echo IGxpbmsgZGllZCBhbmQga2lsbHMgdGhlIHR1bm5lbCBtaWQtYW5zd2VyLg0KICAgICMgICogU3Ry
>>"%PS1%.b64" echo ZWFtaW5nLiBUaGUgc2l0ZSBhc2tzIGZvciBzdHJlYW06dHJ1ZSBhbmQgcmVhZHMgdGhlIGFuc3dl
>>"%PS1%.b64" echo ciBhcyBpdA0KICAgICMgICAgYXJyaXZlcy4gVGhlIHJlcGx5IGJvZHkgbXVzdCBiZSBjb3BpZWQg
>>"%PS1%.b64" echo Ynl0ZSBmb3IgYnl0ZSBhcyBpdCBjb21lcywgd2l0aA0KICAgICMgICAgaXRzIHRyYW5zZmVyIGVu
>>"%PS1%.b64" echo Y29kaW5nIHVudG91Y2hlZCAtIG90aGVyd2lzZSB0aGUgYnJvd3NlcidzIGZldGNoIHJlamVjdHMN
>>"%PS1%.b64" echo CiAgICAjICAgIGFuZCB0aGUgdXNlciBvbmx5IHNlZXMgIkZhaWxlZCB0byBmZXRjaCIuDQogICAg
>>"%PS1%.b64" echo IyAgKiBDT1JTLiBUaGUgcGFnZSBjb21lcyBmcm9tIHRoZSBzaXRlIGFuZCB0aGUgbW9kZWwgZnJv
>>"%PS1%.b64" echo bSBhIHR1bm5lbCBkb21haW4sDQogICAgIyAgICBzbyBldmVyeSByZXBseSBuZWVkcyBDT1JTIGhl
>>"%PS1%.b64" echo YWRlcnMgYW5kIE9QVElPTlMgaGFzIHRvIGJlIGFuc3dlcmVkLg0KDQogICAgIyBPbmUgY29ubmVj
>>"%PS1%.b64" echo dGlvbiBpcyBzZXJ2ZWQgaW4gaXRzIG93biBydW5zcGFjZSwgc28gYSBsb25nIHN0cmVhbWluZyBh
>>"%PS1%.b64" echo bnN3ZXINCiAgICAjIG5ldmVyIGJsb2NrcyB0aGUgY29ubmVjdG9yJ3MgaGVhbHRoIGNoZWNrLiBF
>>"%PS1%.b64" echo dmVyeXRoaW5nIHRoZSBoYW5kbGVyIG5lZWRzIGlzDQogICAgIyB0aGVyZWZvcmUgaW5zaWRlIHRo
>>"%PS1%.b64" echo aXMgb25lIHNjcmlwdCBibG9jay4NCiAgICAkSGFuZGxlciA9IHsNCiAgICAgICAgcGFyYW0oJENs
>>"%PS1%.b64" echo aWVudCwgJFRhcmdldFBvcnQpDQoNCiAgICAgICAgJEVycm9yQWN0aW9uUHJlZmVyZW5jZSA9ICdT
>>"%PS1%.b64" echo dG9wJw0KDQogICAgICAgIGZ1bmN0aW9uIFJlYWQtSGVhZCB7DQogICAgICAgICAgICBwYXJhbShb
>>"%PS1%.b64" echo U3lzdGVtLklPLlN0cmVhbV0kU3RyZWFtKQ0KDQogICAgICAgICAgICAkYnVmZmVyID0gTmV3LU9i
>>"%PS1%.b64" echo amVjdCBieXRlW10gMTYzODQNCiAgICAgICAgICAgICRhY2MgPSBOZXctT2JqZWN0IGJ5dGVbXSAx
>>"%PS1%.b64" echo NjM4NA0KICAgICAgICAgICAgJGxlbiA9IDANCiAgICAgICAgICAgICRlbmQgPSAtMQ0KDQogICAg
>>"%PS1%.b64" echo ICAgICAgICB3aGlsZSAoJHRydWUpIHsNCiAgICAgICAgICAgICAgICAkbiA9ICRTdHJlYW0uUmVh
>>"%PS1%.b64" echo ZCgkYnVmZmVyLCAwLCAkYnVmZmVyLkxlbmd0aCkNCiAgICAgICAgICAgICAgICBpZiAoJG4gLWxl
>>"%PS1%.b64" echo IDApIHsgYnJlYWsgfQ0KICAgICAgICAgICAgICAgIGlmICgkbGVuICsgJG4gLWd0ICRhY2MuTGVu
>>"%PS1%.b64" echo Z3RoKSB7DQogICAgICAgICAgICAgICAgICAgICRhY2MgPSBOZXctT2JqZWN0IGJ5dGVbXSAoW01h
>>"%PS1%.b64" echo dGhdOjpNYXgoJGFjYy5MZW5ndGggKiAyLCAkbGVuICsgJG4pKQ0KICAgICAgICAgICAgICAgIH0N
>>"%PS1%.b64" echo CiAgICAgICAgICAgICAgICBbQXJyYXldOjpDb3B5KCRidWZmZXIsIDAsICRhY2MsICRsZW4sICRu
>>"%PS1%.b64" echo KQ0KICAgICAgICAgICAgICAgICRsZW4gKz0gJG4NCg0KICAgICAgICAgICAgICAgICR0ZXh0ID0g
>>"%PS1%.b64" echo W1RleHQuRW5jb2RpbmddOjpBU0NJSS5HZXRTdHJpbmcoJGFjYywgMCwgJGxlbikNCiAgICAgICAg
>>"%PS1%.b64" echo ICAgICAgICAkZW5kID0gJHRleHQuSW5kZXhPZigiYHJgbmByYG4iKQ0KICAgICAgICAgICAgICAg
>>"%PS1%.b64" echo IGlmICgkZW5kIC1nZSAwKSB7IGJyZWFrIH0NCiAgICAgICAgICAgIH0NCg0KICAgICAgICAgICAg
>>"%PS1%.b64" echo aWYgKCRlbmQgLWx0IDApIHsNCiAgICAgICAgICAgICAgICByZXR1cm4gW3BzY3VzdG9tb2JqZWN0
>>"%PS1%.b64" echo XUB7IEhlYWQgPSAnJzsgUmVzdCA9IChOZXctT2JqZWN0IGJ5dGVbXSAwKSB9DQogICAgICAgICAg
>>"%PS1%.b64" echo ICB9DQoNCiAgICAgICAgICAgICRyZXN0ID0gTmV3LU9iamVjdCBieXRlW10gKFtNYXRoXTo6TWF4
>>"%PS1%.b64" echo KCRsZW4gLSAkZW5kIC0gNCwgMCkpDQogICAgICAgICAgICBpZiAoJHJlc3QuTGVuZ3RoIC1ndCAw
>>"%PS1%.b64" echo KSB7IFtBcnJheV06OkNvcHkoJGFjYywgJGVuZCArIDQsICRyZXN0LCAwLCAkcmVzdC5MZW5ndGgp
>>"%PS1%.b64" echo IH0NCg0KICAgICAgICAgICAgcmV0dXJuIFtwc2N1c3RvbW9iamVjdF1Aew0KICAgICAgICAgICAg
>>"%PS1%.b64" echo ICAgIEhlYWQgPSBbVGV4dC5FbmNvZGluZ106OkFTQ0lJLkdldFN0cmluZygkYWNjLCAwLCAkZW5k
>>"%PS1%.b64" echo ICsgNCkNCiAgICAgICAgICAgICAgICBSZXN0ID0gJHJlc3QNCiAgICAgICAgICAgIH0NCiAgICAg
>>"%PS1%.b64" echo ICAgfQ0KDQogICAgICAgIGZ1bmN0aW9uIEJ1aWxkLUhlYWQgew0KICAgICAgICAgICAgcGFyYW0o
>>"%PS1%.b64" echo JEhlYWQsICREcm9wLCAkUmVwbGFjZSwgJEFkZCkNCg0KICAgICAgICAgICAgJGxpbmVzID0gJEhl
>>"%PS1%.b64" echo YWQgLXNwbGl0ICJgcmBuIg0KICAgICAgICAgICAgJG91dCA9IE5ldy1PYmplY3QgU3lzdGVtLkNv
>>"%PS1%.b64" echo bGxlY3Rpb25zLkdlbmVyaWMuTGlzdFtzdHJpbmddDQogICAgICAgICAgICBbdm9pZF0kb3V0LkFk
>>"%PS1%.b64" echo ZCgkbGluZXNbMF0pDQoNCiAgICAgICAgICAgIGZvciAoJGkgPSAxOyAkaSAtbHQgJGxpbmVzLkNv
>>"%PS1%.b64" echo dW50OyAkaSsrKSB7DQogICAgICAgICAgICAgICAgJGxpbmUgPSAkbGluZXNbJGldDQogICAgICAg
>>"%PS1%.b64" echo ICAgICAgICAgaWYgKFtzdHJpbmddOjpJc051bGxPcldoaXRlU3BhY2UoJGxpbmUpKSB7IGNvbnRp
>>"%PS1%.b64" echo bnVlIH0NCg0KICAgICAgICAgICAgICAgICRuYW1lID0gKCRsaW5lIC1zcGxpdCAnOicsIDIpWzBd
>>"%PS1%.b64" echo LlRyaW0oKQ0KICAgICAgICAgICAgICAgIGlmICgkRHJvcCAtY29udGFpbnMgJG5hbWUpIHsgY29u
>>"%PS1%.b64" echo dGludWUgfQ0KICAgICAgICAgICAgICAgIGlmICgkUmVwbGFjZS5Db250YWluc0tleSgkbmFtZSkp
>>"%PS1%.b64" echo IHsgW3ZvaWRdJG91dC5BZGQoJFJlcGxhY2VbJG5hbWVdKTsgY29udGludWUgfQ0KDQogICAgICAg
>>"%PS1%.b64" echo ICAgICAgICAgW3ZvaWRdJG91dC5BZGQoJGxpbmUpDQogICAgICAgICAgICB9DQoNCiAgICAgICAg
>>"%PS1%.b64" echo ICAgIGlmICgkQWRkKSB7IGZvcmVhY2ggKCRhIGluICRBZGQpIHsgW3ZvaWRdJG91dC5BZGQoJGEp
>>"%PS1%.b64" echo IH0gfQ0KDQogICAgICAgICAgICByZXR1cm4gKCRvdXQgLWpvaW4gImByYG4iKSArICJgcmBuYHJg
>>"%PS1%.b64" echo biINCiAgICAgICAgfQ0KDQogICAgICAgICRDb3JzID0gQCgNCiAgICAgICAgICAgICdBY2Nlc3Mt
>>"%PS1%.b64" echo Q29udHJvbC1BbGxvdy1PcmlnaW46IConLA0KICAgICAgICAgICAgJ0FjY2Vzcy1Db250cm9sLUFs
>>"%PS1%.b64" echo bG93LU1ldGhvZHM6IEdFVCwgUE9TVCwgT1BUSU9OUycsDQogICAgICAgICAgICAnQWNjZXNzLUNv
>>"%PS1%.b64" echo bnRyb2wtQWxsb3ctSGVhZGVyczogKicsDQogICAgICAgICAgICAnQWNjZXNzLUNvbnRyb2wtTWF4
>>"%PS1%.b64" echo LUFnZTogODY0MDAnDQogICAgICAgICkNCg0KICAgICAgICAkdXBzdHJlYW0gPSAkbnVsbA0KICAg
>>"%PS1%.b64" echo ICAgICB0cnkgew0KICAgICAgICAgICAgJENsaWVudC5Ob0RlbGF5ID0gJHRydWUNCiAgICAgICAg
>>"%PS1%.b64" echo ICAgICRkb3duID0gJENsaWVudC5HZXRTdHJlYW0oKQ0KDQogICAgICAgICAgICAkaW5jb21pbmcg
>>"%PS1%.b64" echo PSBSZWFkLUhlYWQgLVN0cmVhbSAkZG93bg0KICAgICAgICAgICAgaWYgKFtzdHJpbmddOjpJc051
>>"%PS1%.b64" echo bGxPcldoaXRlU3BhY2UoJGluY29taW5nLkhlYWQpKSB7IHJldHVybiB9DQoNCiAgICAgICAgICAg
>>"%PS1%.b64" echo ICRyZXF1ZXN0TGluZSA9ICgkaW5jb21pbmcuSGVhZCAtc3BsaXQgImByYG4iKVswXQ0KDQogICAg
>>"%PS1%.b64" echo ICAgICAgICAjIFRoZSBDT1JTIHByZWZsaWdodCBjYXJyaWVzIG5vIGJvZHkgYW5kIG5lZWRzIG5v
>>"%PS1%.b64" echo IG1vZGVsLCBzbyBhbnN3ZXIgaXQNCiAgICAgICAgICAgICMgaGVyZSBpbnN0ZWFkIG9mIHNwZW5k
>>"%PS1%.b64" echo aW5nIGEgcm91bmQgdHJpcCBvbiB0aGUgbG9jYWwgQUkuDQogICAgICAgICAgICBpZiAoJHJlcXVl
>>"%PS1%.b64" echo c3RMaW5lIC1tYXRjaCAnXk9QVElPTlNccycpIHsNCiAgICAgICAgICAgICAgICAkaGVhZCA9IEJ1
>>"%PS1%.b64" echo aWxkLUhlYWQgIkhUVFAvMS4xIDIwNCBObyBDb250ZW50YHJgbmByYG4iIEAoKSBAe30gKCRDb3Jz
>>"%PS1%.b64" echo ICsgQCgnQ29ubmVjdGlvbjogY2xvc2UnKSkNCiAgICAgICAgICAgICAgICAkYnl0ZXMgPSBbVGV4
>>"%PS1%.b64" echo dC5FbmNvZGluZ106OkFTQ0lJLkdldEJ5dGVzKCRoZWFkKQ0KICAgICAgICAgICAgICAgICRkb3du
>>"%PS1%.b64" echo LldyaXRlKCRieXRlcywgMCwgJGJ5dGVzLkxlbmd0aCkNCiAgICAgICAgICAgICAgICAkZG93bi5G
>>"%PS1%.b64" echo bHVzaCgpDQogICAgICAgICAgICAgICAgcmV0dXJuDQogICAgICAgICAgICB9DQoNCiAgICAgICAg
>>"%PS1%.b64" echo ICAgICR1cHN0cmVhbSA9IE5ldy1PYmplY3QgU3lzdGVtLk5ldC5Tb2NrZXRzLlRjcENsaWVudA0K
>>"%PS1%.b64" echo ICAgICAgICAgICAgJHVwc3RyZWFtLk5vRGVsYXkgPSAkdHJ1ZQ0KICAgICAgICAgICAgJHVwc3Ry
>>"%PS1%.b64" echo ZWFtLkNvbm5lY3QoJzEyNy4wLjAuMScsICRUYXJnZXRQb3J0KQ0KICAgICAgICAgICAgJHVwID0g
>>"%PS1%.b64" echo JHVwc3RyZWFtLkdldFN0cmVhbSgpDQoNCiAgICAgICAgICAgICMgT3JpZ2luIGFuZCBSZWZlcmVy
>>"%PS1%.b64" echo IGFyZSBkcm9wcGVkIG9uIHB1cnBvc2UuIE9sbGFtYSAoYW5kIHNldmVyYWwgb3RoZXINCiAgICAg
>>"%PS1%.b64" echo ICAgICAgICMgbG9jYWwgc2VydmVycykgYW5zd2VyIDQwMyB0byBhIHJlcXVlc3QgY2Fycnlpbmcg
>>"%PS1%.b64" echo YSB3ZWIgb3JpZ2luIHRoZXkNCiAgICAgICAgICAgICMgZG8gbm90IGtub3csIGJlZm9yZSB0aGUg
>>"%PS1%.b64" echo YnJvd3NlciBldmVyIHNlZXMgaXQgLSB3aGljaCBzaG93ZWQgdXAgYXMNCiAgICAgICAgICAgICMg
>>"%PS1%.b64" echo IkZhaWxlZCB0byBmZXRjaCIgd2l0aCBubyBlcnJvciBhbnl3aGVyZS4gVGhlIGJyb3dzZXIgZG9l
>>"%PS1%.b64" echo cyBub3QgbmVlZA0KICAgICAgICAgICAgIyB0aGVtIGVpdGhlcjogdGhpcyByZWxheSBhbnN3ZXJz
>>"%PS1%.b64" echo IHRoZSBwcmVmbGlnaHQgaXRzZWxmIGFuZCBwdXRzIHRoZQ0KICAgICAgICAgICAgIyBDT1JTIGhl
>>"%PS1%.b64" echo YWRlcnMgb24gZXZlcnkgcmVwbHksIHNvIHRoZSBsb2NhbCBBSSBuZXZlciBsZWFybnMgdGhhdCB0
>>"%PS1%.b64" echo aGUNCiAgICAgICAgICAgICMgY2FsbGVyIHdhcyBhIHdlYiBwYWdlLg0KICAgICAgICAgICAgJHJl
>>"%PS1%.b64" echo cXVlc3RIZWFkID0gQnVpbGQtSGVhZCAkaW5jb21pbmcuSGVhZCBgDQogICAgICAgICAgICAgICAg
>>"%PS1%.b64" echo QCgnQ29ubmVjdGlvbicsICdQcm94eS1Db25uZWN0aW9uJywgJ09yaWdpbicsICdSZWZlcmVyJykg
>>"%PS1%.b64" echo YA0KICAgICAgICAgICAgICAgIEB7ICdIb3N0JyA9ICJIb3N0OiAxMjcuMC4wLjE6JFRhcmdldFBv
>>"%PS1%.b64" echo cnQiIH0gQCgnQ29ubmVjdGlvbjogY2xvc2UnKQ0KDQogICAgICAgICAgICAkaGVhZEJ5dGVzID0g
>>"%PS1%.b64" echo W1RleHQuRW5jb2RpbmddOjpBU0NJSS5HZXRCeXRlcygkcmVxdWVzdEhlYWQpDQogICAgICAgICAg
>>"%PS1%.b64" echo ICAkdXAuV3JpdGUoJGhlYWRCeXRlcywgMCwgJGhlYWRCeXRlcy5MZW5ndGgpDQogICAgICAgICAg
>>"%PS1%.b64" echo ICAkdXAuRmx1c2goKQ0KDQogICAgICAgICAgICAjIFRoZSByZXF1ZXN0IGJvZHkgdXN1YWxseSBh
>>"%PS1%.b64" echo cnJpdmVzIGluIGxhdGVyIHJlYWRzIHRoYW4gdGhlIGhlYWRlcnMsDQogICAgICAgICAgICAjIHNv
>>"%PS1%.b64" echo IHdoYXRldmVyIGNhbWUgd2l0aCB0aGVtIGlzIG9ubHkgcGFydCBvZiBpdC4gU2VuZGluZyBqdXN0
>>"%PS1%.b64" echo IHRoYXQNCiAgICAgICAgICAgICMgd291bGQgbGVhdmUgdGhlIGxvY2FsIEFJIHdhaXRpbmcgZm9y
>>"%PS1%.b64" echo IHRoZSByZXN0IG9mIHRoZSBwcm9tcHQgdW50aWwNCiAgICAgICAgICAgICMgdGhlIHNvY2tldCBi
>>"%PS1%.b64" echo cm9rZSAtIHNvIHRoZSBib2R5IGlzIGZvcndhcmRlZCBieSBDb250ZW50LUxlbmd0aC4NCiAgICAg
>>"%PS1%.b64" echo ICAgICAgICRjb250ZW50TGVuZ3RoID0gMA0KICAgICAgICAgICAgZm9yZWFjaCAoJGxpbmUgaW4g
>>"%PS1%.b64" echo KCRpbmNvbWluZy5IZWFkIC1zcGxpdCAiYHJgbiIpKSB7DQogICAgICAgICAgICAgICAgaWYgKCRs
>>"%PS1%.b64" echo aW5lIC1tYXRjaCAnXlxzKkNvbnRlbnQtTGVuZ3RoOlxzKihcZCspXHMqJCcpIHsgJGNvbnRlbnRM
>>"%PS1%.b64" echo ZW5ndGggPSBbaW50XSRNYXRjaGVzWzFdIH0NCiAgICAgICAgICAgIH0NCg0KICAgICAgICAgICAg
>>"%PS1%.b64" echo JHNlbnQgPSAwDQogICAgICAgICAgICBpZiAoJGluY29taW5nLlJlc3QuTGVuZ3RoIC1ndCAwKSB7
>>"%PS1%.b64" echo DQogICAgICAgICAgICAgICAgJHVwLldyaXRlKCRpbmNvbWluZy5SZXN0LCAwLCAkaW5jb21pbmcu
>>"%PS1%.b64" echo UmVzdC5MZW5ndGgpDQogICAgICAgICAgICAgICAgJHNlbnQgPSAkaW5jb21pbmcuUmVzdC5MZW5n
>>"%PS1%.b64" echo dGgNCiAgICAgICAgICAgIH0NCiAgICAgICAgICAgICR1cC5GbHVzaCgpDQoNCiAgICAgICAgICAg
>>"%PS1%.b64" echo IGlmICgkY29udGVudExlbmd0aCAtZ3QgJHNlbnQpIHsNCiAgICAgICAgICAgICAgICAkbmVlZCA9
>>"%PS1%.b64" echo ICRjb250ZW50TGVuZ3RoIC0gJHNlbnQNCiAgICAgICAgICAgICAgICB3aGlsZSAoJG5lZWQgLWd0
>>"%PS1%.b64" echo IDApIHsNCiAgICAgICAgICAgICAgICAgICAgJHdhbnQgPSBbaW50XVtNYXRoXTo6TWluKDY1NTM2
>>"%PS1%.b64" echo LCAkbmVlZCkNCiAgICAgICAgICAgICAgICAgICAgJGNodW5rID0gTmV3LU9iamVjdCBieXRlW10g
>>"%PS1%.b64" echo JHdhbnQNCiAgICAgICAgICAgICAgICAgICAgJGdvdCA9ICRkb3duLlJlYWQoJGNodW5rLCAwLCAk
>>"%PS1%.b64" echo d2FudCkNCiAgICAgICAgICAgICAgICAgICAgaWYgKCRnb3QgLWxlIDApIHsgYnJlYWsgfQ0KICAg
>>"%PS1%.b64" echo ICAgICAgICAgICAgICAgICAkdXAuV3JpdGUoJGNodW5rLCAwLCAkZ290KQ0KICAgICAgICAgICAg
>>"%PS1%.b64" echo ICAgICAgICAkbmVlZCAtPSAkZ290DQogICAgICAgICAgICAgICAgfQ0KICAgICAgICAgICAgICAg
>>"%PS1%.b64" echo ICR1cC5GbHVzaCgpDQogICAgICAgICAgICB9DQoNCiAgICAgICAgICAgICRyZXNwb25zZSA9IFJl
>>"%PS1%.b64" echo YWQtSGVhZCAtU3RyZWFtICR1cA0KICAgICAgICAgICAgaWYgKFtzdHJpbmddOjpJc051bGxPcldo
>>"%PS1%.b64" echo aXRlU3BhY2UoJHJlc3BvbnNlLkhlYWQpKSB7IHJldHVybiB9DQoNCiAgICAgICAgICAgICMgVGhl
>>"%PS1%.b64" echo IHRyYW5zZmVyIGVuY29kaW5nIGlzIGxlZnQgZXhhY3RseSBhcyBpdCBhcnJpdmVkOiB0aGUgYm9k
>>"%PS1%.b64" echo eSBiZWxvdw0KICAgICAgICAgICAgIyBpcyBjb3BpZWQgcmF3LCBzbyByZXdyaXRpbmcgY2h1bmtl
>>"%PS1%.b64" echo ZCBmcmFtaW5nIGhlcmUgd291bGQgY29ycnVwdCB0aGUNCiAgICAgICAgICAgICMgc3RyZWFtIHRo
>>"%PS1%.b64" echo ZSBicm93c2VyIGlzIHJlYWRpbmcuDQogICAgICAgICAgICAkcmVzcG9uc2VIZWFkID0gQnVpbGQt
>>"%PS1%.b64" echo SGVhZCAkcmVzcG9uc2UuSGVhZCBAKCdDb25uZWN0aW9uJywgJ1Byb3h5LUNvbm5lY3Rpb24nKSBg
>>"%PS1%.b64" echo DQogICAgICAgICAgICAgICAgQHt9ICgkQ29ycyArIEAoJ0Nvbm5lY3Rpb246IGNsb3NlJykpDQoN
>>"%PS1%.b64" echo CiAgICAgICAgICAgICRvdXRCeXRlcyA9IFtUZXh0LkVuY29kaW5nXTo6QVNDSUkuR2V0Qnl0ZXMo
>>"%PS1%.b64" echo JHJlc3BvbnNlSGVhZCkNCiAgICAgICAgICAgICRkb3duLldyaXRlKCRvdXRCeXRlcywgMCwgJG91
>>"%PS1%.b64" echo dEJ5dGVzLkxlbmd0aCkNCiAgICAgICAgICAgIGlmICgkcmVzcG9uc2UuUmVzdC5MZW5ndGggLWd0
>>"%PS1%.b64" echo IDApIHsgJGRvd24uV3JpdGUoJHJlc3BvbnNlLlJlc3QsIDAsICRyZXNwb25zZS5SZXN0Lkxlbmd0
>>"%PS1%.b64" echo aCkgfQ0KICAgICAgICAgICAgJGRvd24uRmx1c2goKQ0KDQogICAgICAgICAgICAkYnVmZmVyID0g
>>"%PS1%.b64" echo TmV3LU9iamVjdCBieXRlW10gMTYzODQNCiAgICAgICAgICAgIHdoaWxlICgkdHJ1ZSkgew0KICAg
>>"%PS1%.b64" echo ICAgICAgICAgICAgICRuID0gJHVwLlJlYWQoJGJ1ZmZlciwgMCwgJGJ1ZmZlci5MZW5ndGgpDQog
>>"%PS1%.b64" echo ICAgICAgICAgICAgICAgaWYgKCRuIC1sZSAwKSB7IGJyZWFrIH0NCiAgICAgICAgICAgICAgICAk
>>"%PS1%.b64" echo ZG93bi5Xcml0ZSgkYnVmZmVyLCAwLCAkbikNCiAgICAgICAgICAgICAgICAkZG93bi5GbHVzaCgp
>>"%PS1%.b64" echo DQogICAgICAgICAgICB9DQogICAgICAgIH0NCiAgICAgICAgY2F0Y2ggew0KICAgICAgICAgICAg
>>"%PS1%.b64" echo IyBBY3Jvc3MgYSB0dW5uZWwgYSBjbG9zZWQgc29ja2V0IGlzIGFsbCB0aGUgYnJvd3NlciBldmVy
>>"%PS1%.b64" echo IHNlZXMsIHNvDQogICAgICAgICAgICAjIHNheSBzb21ldGhpbmcgaW5zdGVhZCBvZiBmYWlsaW5n
>>"%PS1%.b64" echo IGluIHNpbGVuY2UuDQogICAgICAgICAgICB0cnkgew0KICAgICAgICAgICAgICAgICRkb3duID0g
>>"%PS1%.b64" echo JENsaWVudC5HZXRTdHJlYW0oKQ0KICAgICAgICAgICAgICAgICRtc2cgPSBbVGV4dC5FbmNvZGlu
>>"%PS1%.b64" echo Z106OkFTQ0lJLkdldEJ5dGVzKA0KICAgICAgICAgICAgICAgICAgICAiSFRUUC8xLjEgNTAyIEJh
>>"%PS1%.b64" echo ZCBHYXRld2F5YHJgbkFjY2Vzcy1Db250cm9sLUFsbG93LU9yaWdpbjogKmByYG5Db250ZW50LUxl
>>"%PS1%.b64" echo bmd0aDogMGByYG5Db25uZWN0aW9uOiBjbG9zZWByYG5gcmBuIikNCiAgICAgICAgICAgICAgICAk
>>"%PS1%.b64" echo ZG93bi5Xcml0ZSgkbXNnLCAwLCAkbXNnLkxlbmd0aCkNCiAgICAgICAgICAgICAgICAkZG93bi5G
>>"%PS1%.b64" echo bHVzaCgpDQogICAgICAgICAgICB9DQogICAgICAgICAgICBjYXRjaCB7IH0NCiAgICAgICAgfQ0K
>>"%PS1%.b64" echo ICAgICAgICBmaW5hbGx5IHsNCiAgICAgICAgICAgIGlmICgkdXBzdHJlYW0pIHsgJHVwc3RyZWFt
>>"%PS1%.b64" echo LkNsb3NlKCkgfQ0KICAgICAgICAgICAgJENsaWVudC5DbG9zZSgpDQogICAgICAgIH0NCiAgICB9
>>"%PS1%.b64" echo DQoNCiAgICAkSGFuZGxlclRleHQgPSAkSGFuZGxlci5Ub1N0cmluZygpDQoNCiAgICAkcG9vbCA9
>>"%PS1%.b64" echo IFtydW5zcGFjZWZhY3RvcnldOjpDcmVhdGVSdW5zcGFjZVBvb2woMSwgMTYpDQogICAgJHBvb2wu
>>"%PS1%.b64" echo T3BlbigpDQoNCiAgICAkbGlzdGVuZXIgPSBOZXctT2JqZWN0IFN5c3RlbS5OZXQuU29ja2V0cy5U
>>"%PS1%.b64" echo Y3BMaXN0ZW5lcihbTmV0LklQQWRkcmVzc106Okxvb3BiYWNrLCAkTGlzdGVuUG9ydCkNCiAgICAk
>>"%PS1%.b64" echo bGlzdGVuZXIuU3RhcnQoKQ0KICAgIFdyaXRlLU91dHB1dCAibGlzdGVuaW5nICRMaXN0ZW5Qb3J0
>>"%PS1%.b64" echo IC0+ICRUYXJnZXRQb3J0Ig0KDQogICAgJGpvYnMgPSBOZXctT2JqZWN0IFN5c3RlbS5Db2xsZWN0
>>"%PS1%.b64" echo aW9ucy5BcnJheUxpc3QNCg0KICAgIHdoaWxlICgkdHJ1ZSkgew0KICAgICAgICAkY2xpZW50ID0g
>>"%PS1%.b64" echo JGxpc3RlbmVyLkFjY2VwdFRjcENsaWVudCgpDQoNCiAgICAgICAgJHBzID0gW3Bvd2Vyc2hlbGxd
>>"%PS1%.b64" echo OjpDcmVhdGUoKQ0KICAgICAgICAkcHMuUnVuc3BhY2VQb29sID0gJHBvb2wNCiAgICAgICAgW3Zv
>>"%PS1%.b64" echo aWRdJHBzLkFkZFNjcmlwdCgkSGFuZGxlclRleHQpLkFkZEFyZ3VtZW50KCRjbGllbnQpLkFkZEFy
>>"%PS1%.b64" echo Z3VtZW50KCRUYXJnZXRQb3J0KQ0KICAgICAgICAkaGFuZGxlID0gJHBzLkJlZ2luSW52b2tlKCkN
>>"%PS1%.b64" echo CiAgICAgICAgW3ZvaWRdJGpvYnMuQWRkKEB7IFBTID0gJHBzOyBIYW5kbGUgPSAkaGFuZGxlIH0p
>>"%PS1%.b64" echo DQoNCiAgICAgICAgZm9yICgkaSA9ICRqb2JzLkNvdW50IC0gMTsgJGkgLWdlIDA7ICRpLS0pIHsN
>>"%PS1%.b64" echo CiAgICAgICAgICAgIGlmICgtbm90ICRqb2JzWyRpXS5IYW5kbGUuSXNDb21wbGV0ZWQpIHsgY29u
>>"%PS1%.b64" echo dGludWUgfQ0KICAgICAgICAgICAgdHJ5IHsgJGpvYnNbJGldLkhhbmRsZS5FbmRJbnZva2UoJGpv
>>"%PS1%.b64" echo YnNbJGldLkhhbmRsZSkgfSBjYXRjaCB7IH0NCiAgICAgICAgICAgICRqb2JzWyRpXS5QUy5EaXNw
>>"%PS1%.b64" echo b3NlKCkNCiAgICAgICAgICAgICRqb2JzLlJlbW92ZUF0KCRpKQ0KICAgICAgICB9DQogICAgfQ0K
>>"%PS1%.b64" echo fQ0KDQojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>>"%PS1%.b64" echo PT09PT09PT09PT09PT09PT09PT09PT09PQ0KIyBBZ2VudCBtb2RlDQojID09PT09PT09PT09PT09
>>"%PS1%.b64" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>>"%PS1%.b64" echo PT09PQ0KDQokRXJyb3JBY3Rpb25QcmVmZXJlbmNlID0gJ1N0b3AnDQoNCiMgV2luZG93cyBQb3dl
>>"%PS1%.b64" echo clNoZWxsIDUuMSBzdGlsbCBvZmZlcnMgVExTIDEuMCBvbiBzb21lIHN5c3RlbXMsIGFuZCBhIHNp
>>"%PS1%.b64" echo dGUgdGhhdA0KIyBvbmx5IHNwZWFrcyBUTFMgMS4yKyB3b3VsZCBiZSB1bnJlYWNoYWJsZSAtIHdp
>>"%PS1%.b64" echo dGggYSBiYXJlICJ0aGUgcmVxdWVzdCB3YXMNCiMgYWJvcnRlZCIgaW5zdGVhZCBvZiBhbnl0aGlu
>>"%PS1%.b64" echo ZyBhIHBsYXllciBjb3VsZCBhY3Qgb24uDQpbTmV0LlNlcnZpY2VQb2ludE1hbmFnZXJdOjpTZWN1
>>"%PS1%.b64" echo cml0eVByb3RvY29sID0gW05ldC5TZWN1cml0eVByb3RvY29sVHlwZV06OlRsczEyDQoNCmZ1bmN0
>>"%PS1%.b64" echo aW9uIFNheSB7DQogICAgcGFyYW0oW3N0cmluZ10kTWVzc2FnZSkNCg0KICAgICMgVGhlIHBhcmVu
>>"%PS1%.b64" echo dGhlc2VzIGFyZSBub3QgZGVjb3JhdGlvbi4gVGhlIGNvbW1hIG9wZXJhdG9yIGJpbmRzIGxvb3Nl
>>"%PS1%.b64" echo ciB0aGFuDQogICAgIyAtZiwgc28gd2l0aG91dCB0aGVtIHRoaXMgcGFyc2VzIGFzICJmb3JtYXQg
>>"%PS1%.b64" echo dGhlIGZpcnN0IGFyZ3VtZW50LCB0aGVuIG1ha2UNCiAgICAjIGFuIGFycmF5IG9mIHR3byIgYW5k
>>"%PS1%.b64" echo IGV2ZXJ5IGxpbmUgdGhlIHBsYXllciBzaG91bGQgcmVhZCBmYWlscyB3aXRoIGENCiAgICAjIEZv
>>"%PS1%.b64" echo cm1hdEVycm9yIGluc3RlYWQgb2YgYmVpbmcgcHJpbnRlZC4NCiAgICB0cnkgew0KICAgICAgICBb
>>"%PS1%.b64" echo Q29uc29sZV06Ok91dC5Xcml0ZUxpbmUoKCJ7MH0gezF9IiAtZiAoR2V0LURhdGUgLUZvcm1hdCAn
>>"%PS1%.b64" echo SEg6bW06c3MnKSwgJE1lc3NhZ2UpKQ0KICAgICAgICBbQ29uc29sZV06Ok91dC5GbHVzaCgpDQog
>>"%PS1%.b64" echo ICAgfQ0KICAgIGNhdGNoIHsNCiAgICAgICAgIyBBIGxvZyBsaW5lIGlzIG5ldmVyIHdvcnRoIHRh
>>"%PS1%.b64" echo a2luZyB0aGUgY29ubmVjdG9yIGRvd24gb3Zlci4NCiAgICB9DQp9DQoNCiMgQSBmcmFtZSBpcyBh
>>"%PS1%.b64" echo IG9uZS1saW5lIEpTT04gb2JqZWN0LiBDb252ZXJ0VG8tSnNvbiBlc2NhcGVzIGV2ZXJ5dGhpbmcg
>>"%PS1%.b64" echo b3V0c2lkZQ0KIyBwbGFpbiBBU0NJSSwgc28gbm8gaGVhZGVyIG9yIHRva2VuIGNhbiBhY2NpZGVu
>>"%PS1%.b64" echo dGFsbHkgYnJlYWsgdGhlIGxpbmUsIGFuZCBvbmUNCiMgZnJhbWUgcGVyIGxpbmUga2VlcHMgdGhl
>>"%PS1%.b64" echo IG90aGVyIGVuZCdzIHJlYWRlciB0cml2aWFsLg0KZnVuY3Rpb24gTmV3LUZyYW1lIHsNCiAgICBw
>>"%PS1%.b64" echo YXJhbShbc3RyaW5nXSRUeXBlLCBbbG9uZ10kSWQgPSAwLCAkRXh0cmEpDQoNCiAgICAkZnJhbWUg
>>"%PS1%.b64" echo PSBbb3JkZXJlZF1AeyB0ID0gJFR5cGUgfQ0KICAgIGlmICgkSWQgLWd0IDApIHsgJGZyYW1lWydp
>>"%PS1%.b64" echo ZCddID0gJElkIH0NCiAgICBpZiAoJEV4dHJhKSB7IGZvcmVhY2ggKCRrZXkgaW4gJEV4dHJhLktl
>>"%PS1%.b64" echo eXMpIHsgJGZyYW1lWyRrZXldID0gJEV4dHJhWyRrZXldIH0gfQ0KICAgIHJldHVybiAoJGZyYW1l
>>"%PS1%.b64" echo IHwgQ29udmVydFRvLUpzb24gLURlcHRoIDYgLUNvbXByZXNzKQ0KfQ0KDQpmdW5jdGlvbiBTZW5k
>>"%PS1%.b64" echo LUZyYW1lIHsNCiAgICBwYXJhbSgkU29ja2V0LCBbc3RyaW5nXSRGcmFtZSkNCg0KICAgICRieXRl
>>"%PS1%.b64" echo cyA9IFtUZXh0LkVuY29kaW5nXTo6VVRGOC5HZXRCeXRlcygkRnJhbWUpDQogICAgJHNlZ21lbnQg
>>"%PS1%.b64" echo PSBOZXctT2JqZWN0IFN5c3RlbS5BcnJheVNlZ21lbnRbYnl0ZV0gKCwkYnl0ZXMpDQogICAgIyBb
>>"%PS1%.b64" echo dm9pZF06IFNlbmRBc3luYyByZXR1cm5zIFRhc2s8Vm9pZFRhc2tSZXN1bHQ+LCBhbmQgd2l0aG91
>>"%PS1%.b64" echo dCBpdCBldmVyeQ0KICAgICMgc2VudCBmcmFtZSBpcyBlY2hvZWQgaW50byB0aGUgY29uc29sZSBh
>>"%PS1%.b64" echo cyAiU3lzdGVtLlRocmVhZGluZy5UYXNrcy5Wb2lkVGFza1Jlc3VsdCIuDQogICAgW3ZvaWRdJFNv
>>"%PS1%.b64" echo Y2tldC5TZW5kQXN5bmMoJHNlZ21lbnQsIFtTeXN0ZW0uTmV0LldlYlNvY2tldHMuV2ViU29ja2V0
>>"%PS1%.b64" echo TWVzc2FnZVR5cGVdOjpUZXh0LCAkdHJ1ZSwgJGNvbm5lY3QuVG9rZW4pLkdldEF3YWl0ZXIoKS5H
>>"%PS1%.b64" echo ZXRSZXN1bHQoKQ0KfQ0KDQojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>>"%PS1%.b64" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQ0KIyBUaGUgd29ya2VyOiBvbmUg
>>"%PS1%.b64" echo bG9jYWwgSFRUUCByZXF1ZXN0LCBzdHJlYW1lZCBiYWNrIGFzIGZyYW1lcy4NCiMNCiMgSXQgcnVu
>>"%PS1%.b64" echo cyBpbiBpdHMgb3duIHJ1bnNwYWNlIHNvIGEgcmVwbHkgdGhhdCB0YWtlcyBtaW51dGVzIGNhbm5v
>>"%PS1%.b64" echo dCBzdG9wIHRoZQ0KIyBzb2NrZXQgZnJvbSBiZWluZyByZWFkLiBFdmVyeXRoaW5nIGl0IG5lZWRz
>>"%PS1%.b64" echo IGlzIGhhbmRlZCBvdmVyIGFzIGFuIGFyZ3VtZW50LCBhbmQNCiMgd2hhdCBpdCBwcm9kdWNlcyBn
>>"%PS1%.b64" echo b2VzIGludG8gdGhlIHNoYXJlZCBvdXRib3ggdGhhdCB0aGUgc29ja2V0IHRocmVhZCBkcmFpbnMu
>>"%PS1%.b64" echo DQojIE5ldy1GcmFtZSBpcyBwcmVwZW5kZWQgdG8gdGhlIHdvcmtlciB0ZXh0IGJlY2F1c2UgYSBy
>>"%PS1%.b64" echo dW5zcGFjZSBoYXMgbm8gYWNjZXNzIHRvDQojIHRoZSBmdW5jdGlvbnMgb2YgdGhlIG9uZSB0aGF0
>>"%PS1%.b64" echo IHN0YXJ0ZWQgaXQuDQojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>>"%PS1%.b64" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQ0KJFdvcmtlciA9IHsNCiAgICBwYXJh
>>"%PS1%.b64" echo bSgkSWQsICRNZXRob2QsICRQYXRoLCAkSGVhZGVycywgJEJvZHksICRRdWV1ZSwgJExpdmUsICRU
>>"%PS1%.b64" echo YXJnZXRQb3J0LCAkUHJlZml4KQ0KDQogICAgJEVycm9yQWN0aW9uUHJlZmVyZW5jZSA9ICdTdG9w
>>"%PS1%.b64" echo Jw0KDQogICAgIyBOZXctRnJhbWUgbGl2ZXMgSU5TSURFIHRoZSB3b3JrZXIsIG5vdCBiZXNpZGUg
>>"%PS1%.b64" echo aXQuIEEgcnVuc3BhY2UgaGFzIG5vIGFjY2Vzcw0KICAgICMgdG8gdGhlIGZ1bmN0aW9ucyBvZiB0
>>"%PS1%.b64" echo aGUgcnVuc3BhY2UgdGhhdCBzdGFydGVkIGl0LCBzbyBpdCBoYXMgdG8gdHJhdmVsIHdpdGgNCiAg
>>"%PS1%.b64" echo ICAjIHRoZSB0ZXh0IC0gYnV0IGl0IGNhbm5vdCBiZSBwcmVwZW5kZWQgdG8gaXQgZWl0aGVyOiAi
>>"%PS1%.b64" echo cGFyYW0iIGhhcyB0byBiZSB0aGUNCiAgICAjIHZlcnkgZmlyc3QgdGhpbmcgaW4gYSBzY3JpcHQs
>>"%PS1%.b64" echo IGFuZCBwcmVwZW5kaW5nIHB1dHMgYSBmdW5jdGlvbiBpbiBmcm9udCBvZg0KICAgICMgaXQsIHdo
>>"%PS1%.b64" echo aWNoIFBvd2VyU2hlbGwgcmVmdXNlcyB3aXRoICJwYXJhbSBpcyBub3QgcmVjb2duaXplZCIuIEhl
>>"%PS1%.b64" echo bmNlIGhlcmUsDQogICAgIyBhZnRlciB0aGUgcGFyYW1ldGVycyBhbmQgYmVmb3JlIGFueXRoaW5n
>>"%PS1%.b64" echo IHRoYXQgdXNlcyBpdC4NCiAgICBmdW5jdGlvbiBOZXctRnJhbWUgew0KICAgICAgICBwYXJhbShb
>>"%PS1%.b64" echo c3RyaW5nXSRUeXBlLCBbbG9uZ10kSWQgPSAwLCAkRXh0cmEpDQoNCiAgICAgICAgJGZyYW1lID0g
>>"%PS1%.b64" echo W29yZGVyZWRdQHsgdCA9ICRUeXBlIH0NCiAgICAgICAgaWYgKCRJZCAtZ3QgMCkgeyAkZnJhbWVb
>>"%PS1%.b64" echo J2lkJ10gPSAkSWQgfQ0KICAgICAgICBpZiAoJEV4dHJhKSB7IGZvcmVhY2ggKCRrZXkgaW4gJEV4
>>"%PS1%.b64" echo dHJhLktleXMpIHsgJGZyYW1lWyRrZXldID0gJEV4dHJhWyRrZXldIH0gfQ0KICAgICAgICByZXR1
>>"%PS1%.b64" echo cm4gKCRmcmFtZSB8IENvbnZlcnRUby1Kc29uIC1EZXB0aCA2IC1Db21wcmVzcykNCiAgICB9DQoN
>>"%PS1%.b64" echo CiAgICBmdW5jdGlvbiBQdXNoLUNodW5rIHsNCiAgICAgICAgcGFyYW0oW2J5dGVbXV0kQnl0ZXMp
>>"%PS1%.b64" echo DQoNCiAgICAgICAgJHBhcnQgPSBOZXctT2JqZWN0IGJ5dGVbXSAkQnl0ZXMuTGVuZ3RoDQogICAg
>>"%PS1%.b64" echo ICAgIFtBcnJheV06OkNvcHkoJEJ5dGVzLCAwLCAkcGFydCwgMCwgJEJ5dGVzLkxlbmd0aCkNCiAg
>>"%PS1%.b64" echo ICAgICAgJFF1ZXVlLkVucXVldWUoKE5ldy1GcmFtZSAnY2h1bmsnICRJZCBAeyBkYXRhID0gW0Nv
>>"%PS1%.b64" echo bnZlcnRdOjpUb0Jhc2U2NFN0cmluZygkcGFydCkgfSkpDQogICAgfQ0KDQogICAgJHJlcXVlc3Qg
>>"%PS1%.b64" echo PSAkbnVsbA0KICAgICRyZXNwb25zZSA9ICRudWxsDQoNCiAgICB0cnkgew0KICAgICAgICAkYXV0
>>"%PS1%.b64" echo aG9yaXphdGlvbiA9ICRudWxsDQogICAgICAgICRhY2NlcHQgPSAkbnVsbA0KICAgICAgICAkY29u
>>"%PS1%.b64" echo dGVudFR5cGUgPSAkbnVsbA0KICAgICAgICAkdGV4dFByb3ZpZGVyID0gJG51bGwNCiAgICAgICAg
>>"%PS1%.b64" echo aWYgKCRudWxsIC1uZSAkSGVhZGVycykgew0KICAgICAgICAgICAgaWYgKCRIZWFkZXJzLlBTT2Jq
>>"%PS1%.b64" echo ZWN0LlByb3BlcnRpZXNbJ0F1dGhvcml6YXRpb24nXSkgeyAkYXV0aG9yaXphdGlvbiA9ICRIZWFk
>>"%PS1%.b64" echo ZXJzLkF1dGhvcml6YXRpb24gfQ0KICAgICAgICAgICAgaWYgKCRIZWFkZXJzLlBTT2JqZWN0LlBy
>>"%PS1%.b64" echo b3BlcnRpZXNbJ0FjY2VwdCddKSB7ICRhY2NlcHQgPSAkSGVhZGVycy5BY2NlcHQgfQ0KICAgICAg
>>"%PS1%.b64" echo ICAgICAgaWYgKCRIZWFkZXJzLlBTT2JqZWN0LlByb3BlcnRpZXNbJ0NvbnRlbnQtVHlwZSddKSB7
>>"%PS1%.b64" echo ICRjb250ZW50VHlwZSA9ICRIZWFkZXJzLidDb250ZW50LVR5cGUnIH0NCiAgICAgICAgICAgICMg
>>"%PS1%.b64" echo VGhlIGZyZWUtY2hhdCB3b3JrZXIgY2hvb3NlcyBpdHMgdXBzdHJlYW0gYWRhcHRlciBmcm9tIHRo
>>"%PS1%.b64" echo aXMgaGVhZGVyDQogICAgICAgICAgICAjIChkZWVwc2VlayAvIHRyeWluZ29wZW4pOyBpdCBpcyBt
>>"%PS1%.b64" echo ZWFuaW5nbGVzcyB0byBhIGxvY2FsIG1vZGVsLCBzbyBpdA0KICAgICAgICAgICAgIyBpcyBmb3J3
>>"%PS1%.b64" echo YXJkZWQgb25seSB3aGVuIHRoZSBzaXRlIHNlbnQgb25lLg0KICAgICAgICAgICAgaWYgKCRIZWFk
>>"%PS1%.b64" echo ZXJzLlBTT2JqZWN0LlByb3BlcnRpZXNbJ1gtVGV4dC1Qcm92aWRlciddKSB7ICR0ZXh0UHJvdmlk
>>"%PS1%.b64" echo ZXIgPSBbc3RyaW5nXSRIZWFkZXJzLidYLVRleHQtUHJvdmlkZXInIH0NCiAgICAgICAgfQ0KDQog
>>"%PS1%.b64" echo ICAgICAgICMgJFByZWZpeCBhcnJpdmVzIGFzICcvdjEnIGFuZCAkUGF0aCBhcyAnL21vZGVscycs
>>"%PS1%.b64" echo IHNvIGpvaW5pbmcgdGhlbSB3aXRoDQogICAgICAgICMgYSBzbGFzaCB3b3VsZCBhc2sgdGhlIGxv
>>"%PS1%.b64" echo Y2FsIEFJIGZvciAnL3YxLy9tb2RlbHMnLiBPbGxhbWEgYW5zd2VycyB0aGF0DQogICAgICAgICMg
>>"%PS1%.b64" echo d2l0aCA0MDQsIGFuZCBhIDQwNCBmcm9tIHRoZSBsb2NhbCBtb2RlbCBpcyBhIGNvbmZ1c2luZyB0
>>"%PS1%.b64" echo aGluZyB0byBzZWUNCiAgICAgICAgIyB3aGVuIHRoZSBnYW1lIGFza2VkIGZvciBzb21ldGhpbmcg
>>"%PS1%.b64" echo cGVyZmVjdGx5IG9yZGluYXJ5LiBPbmUgc2xhc2guDQogICAgICAgICRsb2NhbFBhdGggPSAiJFBy
>>"%PS1%.b64" echo ZWZpeC8kUGF0aCIgLXJlcGxhY2UgJy97Mix9JywgJy8nDQogICAgICAgIGlmICgtbm90ICRUYXJn
>>"%PS1%.b64" echo ZXRQb3J0IC1vciAkVGFyZ2V0UG9ydCAtbGUgMCkgew0KICAgICAgICAgICAgdGhyb3cgJ05vIGxv
>>"%PS1%.b64" echo Y2FsIEFJIGlzIGNvbmZpZ3VyZWQgb24gdGhpcyBjb21wdXRlci4nDQogICAgICAgIH0NCiAgICAg
>>"%PS1%.b64" echo ICAgJHVyaSA9ICJodHRwOi8vMTI3LjAuMC4xOiRUYXJnZXRQb3J0JGxvY2FsUGF0aCINCg0KICAg
>>"%PS1%.b64" echo ICAgICAjIEh0dHBXZWJSZXF1ZXN0IHJhdGhlciB0aGFuIGEgcmF3IHNvY2tldCwgYmVjYXVzZSBp
>>"%PS1%.b64" echo dCBoYW5kbGVzIHRoZSBoZWFkZXINCiAgICAgICAgIyBwYXJzaW5nIGFuZCB0aGUgY2h1bmtlZCBk
>>"%PS1%.b64" echo ZWNvZGluZyBmb3IgdXMuIFRoYXQgbWF0dGVyczogdGhlIHNpdGUgd3JpdGVzDQogICAgICAgICMg
>>"%PS1%.b64" echo d2hhdCBhcnJpdmVzIHN0cmFpZ2h0IG9udG8gYSBmcmVzaCBIVFRQIHJlc3BvbnNlIG9mIGl0cyBv
>>"%PS1%.b64" echo d24sIHNvIGENCiAgICAgICAgIyB0cmFuc2Zlci1lbmNvZGluZyBoZWFkZXIgc3Vydml2aW5nIGlu
>>"%PS1%.b64" echo IHRoZSByYXcgYnl0ZXMgd291bGQgY29ycnVwdCBpdC4NCiAgICAgICAgIyBJdCBhbHNvIHNldHMg
>>"%PS1%.b64" echo SG9zdCB0byAxMjcuMC4wLjEgYnkgaXRzZWxmLCB3aGljaCBpcyBleGFjdGx5IHdoYXQgT2xsYW1h
>>"%PS1%.b64" echo DQogICAgICAgICMgYW5kIGZyaWVuZHMgaW5zaXN0IG9uLCBhbmQgc2VuZHMgbm8gT3JpZ2luIG9y
>>"%PS1%.b64" echo IFJlZmVyZXIgYXQgYWxsIC0gdGhlDQogICAgICAgICMgY2FsbGVyIGlzIGEgV2ViU29ja2V0LCBu
>>"%PS1%.b64" echo b3QgYSB3ZWIgcGFnZS4NCiAgICAgICAgJHJlcXVlc3QgPSBbTmV0Lkh0dHBXZWJSZXF1ZXN0XTo6
>>"%PS1%.b64" echo Q3JlYXRlKCR1cmkpDQogICAgICAgICRyZXF1ZXN0Lk1ldGhvZCA9ICRNZXRob2QNCiAgICAgICAg
>>"%PS1%.b64" echo JHJlcXVlc3QuQWxsb3dBdXRvUmVkaXJlY3QgPSAkZmFsc2UNCiAgICAgICAgJHJlcXVlc3QuVXNl
>>"%PS1%.b64" echo ckFnZW50ID0gJ2FpbS1jb25uZWN0b3InDQogICAgICAgICRyZXF1ZXN0LlByb3RvY29sVmVyc2lv
>>"%PS1%.b64" echo biA9IFtOZXQuSHR0cFZlcnNpb25dOjpWZXJzaW9uMTENCiAgICAgICAgIyBOb3QgYSBsaW1pdCBv
>>"%PS1%.b64" echo biB0aGUgd2hvbGUgZ2VuZXJhdGlvbjogdGhlIHJlcGx5IGlzIHJlYWQgaW4gYSBsb29wIGJlbG93
>>"%PS1%.b64" echo DQogICAgICAgICMgYW5kIG1heSB0YWtlIGFzIGxvbmcgYXMgdGhlIG1vZGVsIG5lZWRzLiBUaGlz
>>"%PS1%.b64" echo IG9ubHkgY292ZXJzIGdldHRpbmcgdGhlDQogICAgICAgICMgY29ubmVjdGlvbiBhbmQgdGhlIGZp
>>"%PS1%.b64" echo cnN0IGJ5dGUgb2YgdGhlIGFuc3dlci4NCiAgICAgICAgJHJlcXVlc3QuVGltZW91dCA9IDMwMDAw
>>"%PS1%.b64" echo MA0KICAgICAgICAkcmVxdWVzdC5SZWFkV3JpdGVUaW1lb3V0ID0gMzAwMDAwDQoNCiAgICAgICAg
>>"%PS1%.b64" echo aWYgKCRhdXRob3JpemF0aW9uKSB7ICRyZXF1ZXN0LkhlYWRlcnNbJ0F1dGhvcml6YXRpb24nXSA9
>>"%PS1%.b64" echo ICRhdXRob3JpemF0aW9uIH0NCiAgICAgICAgaWYgKCRhY2NlcHQpIHsgJHJlcXVlc3QuQWNjZXB0
>>"%PS1%.b64" echo ID0gJGFjY2VwdCB9DQogICAgICAgIGlmICgkdGV4dFByb3ZpZGVyKSB7ICRyZXF1ZXN0LkhlYWRl
>>"%PS1%.b64" echo cnNbJ1gtVGV4dC1Qcm92aWRlciddID0gJHRleHRQcm92aWRlciB9DQoNCiAgICAgICAgaWYgKCRC
>>"%PS1%.b64" echo b2R5IC1hbmQgJEJvZHkuTGVuZ3RoIC1ndCAwKSB7DQogICAgICAgICAgICAkYnl0ZXMgPSBbYnl0
>>"%PS1%.b64" echo ZVtdXSRCb2R5DQogICAgICAgICAgICAkcmVxdWVzdC5Db250ZW50TGVuZ3RoID0gJGJ5dGVzLkxl
>>"%PS1%.b64" echo bmd0aA0KICAgICAgICAgICAgaWYgKCRjb250ZW50VHlwZSkgeyAkcmVxdWVzdC5Db250ZW50VHlw
>>"%PS1%.b64" echo ZSA9ICRjb250ZW50VHlwZSB9DQogICAgICAgICAgICAkb3V0ID0gJHJlcXVlc3QuR2V0UmVxdWVz
>>"%PS1%.b64" echo dFN0cmVhbSgpDQogICAgICAgICAgICAkb3V0LldyaXRlKCRieXRlcywgMCwgJGJ5dGVzLkxlbmd0
>>"%PS1%.b64" echo aCkNCiAgICAgICAgICAgICRvdXQuRmx1c2goKQ0KICAgICAgICAgICAgJG91dC5DbG9zZSgpDQog
>>"%PS1%.b64" echo ICAgICAgIH0NCg0KICAgICAgICAjIFJlZ2lzdGVyZWQgYmVmb3JlIHRoZSBjYWxsLCBzbyB0aGF0
>>"%PS1%.b64" echo IGEgImNhbmNlbCIgYXJyaXZpbmcgd2hpbGUgdGhlIG1vZGVsDQogICAgICAgICMgaXMgc3RpbGwg
>>"%PS1%.b64" echo dGhpbmtpbmcgY2FuIGFib3J0IGl0LiBPdGhlcndpc2UgYSBwbGF5ZXIgd2hvIHByZXNzZWQgU3Rv
>>"%PS1%.b64" echo cA0KICAgICAgICAjIHdvdWxkIHN0aWxsIGJlIHBheWluZyBmb3IgYSBmdWxsIGdlbmVyYXRpb24g
>>"%PS1%.b64" echo bm9ib2R5IHdpbGwgcmVhZC4NCiAgICAgICAgJExpdmUuVHJ5QWRkKCRJZCwgJHJlcXVlc3QpDQoN
>>"%PS1%.b64" echo CiAgICAgICAgJHJlc3BvbnNlID0gJHJlcXVlc3QuR2V0UmVzcG9uc2UoKQ0KICAgICAgICAkUXVl
>>"%PS1%.b64" echo dWUuRW5xdWV1ZSgoTmV3LUZyYW1lICdyZXMnICRJZCBAew0KICAgICAgICAgICAgc3RhdHVzICA9
>>"%PS1%.b64" echo IFtpbnRdJHJlc3BvbnNlLlN0YXR1c0NvZGUNCiAgICAgICAgICAgIGhlYWRlcnMgPSBAeyAnQ29u
>>"%PS1%.b64" echo dGVudC1UeXBlJyA9IFtzdHJpbmddJHJlc3BvbnNlLkNvbnRlbnRUeXBlIH0NCiAgICAgICAgfSkp
>>"%PS1%.b64" echo DQoNCiAgICAgICAgJHN0cmVhbSA9ICRyZXNwb25zZS5HZXRSZXNwb25zZVN0cmVhbSgpDQogICAg
>>"%PS1%.b64" echo ICAgICRidWZmZXIgPSBOZXctT2JqZWN0IGJ5dGVbXSA2NTUzNg0KICAgICAgICB3aGlsZSAoJHRy
>>"%PS1%.b64" echo dWUpIHsNCiAgICAgICAgICAgIHRyeSB7DQogICAgICAgICAgICAgICAgJG4gPSAkc3RyZWFtLlJl
>>"%PS1%.b64" echo YWQoJGJ1ZmZlciwgMCwgJGJ1ZmZlci5MZW5ndGgpDQogICAgICAgICAgICB9DQogICAgICAgICAg
>>"%PS1%.b64" echo ICBjYXRjaCBbU3lzdGVtLklPLklPRXhjZXB0aW9uXSB7DQogICAgICAgICAgICAgICAgYnJlYWsN
>>"%PS1%.b64" echo CiAgICAgICAgICAgIH0NCiAgICAgICAgICAgIGlmICgkbiAtbGUgMCkgeyBicmVhayB9DQogICAg
>>"%PS1%.b64" echo ICAgICAgICAkc2xpY2UgPSBOZXctT2JqZWN0IGJ5dGVbXSAkbg0KICAgICAgICAgICAgW0FycmF5
>>"%PS1%.b64" echo XTo6Q29weSgkYnVmZmVyLCAwLCAkc2xpY2UsIDAsICRuKQ0KICAgICAgICAgICAgUHVzaC1DaHVu
>>"%PS1%.b64" echo ayAkc2xpY2UNCiAgICAgICAgfQ0KICAgICAgICAkc3RyZWFtLkNsb3NlKCkNCg0KICAgICAgICAk
>>"%PS1%.b64" echo UXVldWUuRW5xdWV1ZSgoTmV3LUZyYW1lICdlbmQnICRJZCkpDQogICAgfQ0KICAgIGNhdGNoIFtT
>>"%PS1%.b64" echo eXN0ZW0uTmV0LldlYkV4Y2VwdGlvbl0gew0KICAgICAgICAjIEFuIEhUVFAgZXJyb3Igc3RhdHVz
>>"%PS1%.b64" echo IGlzIE5PVCBhIGZhaWx1cmUgaGVyZS4gQSByb3V0ZXIgdGhhdCB3YW50cyBhbiBBUEkNCiAgICAg
>>"%PS1%.b64" echo ICAgIyBrZXkgYW5zd2VycyA0MDEsIGFuZCB0aGUgZ2FtZSB3YW50cyB0aGF0IDQwMSB3aXRoIGl0
>>"%PS1%.b64" echo cyBib2R5LCBiZWNhdXNlDQogICAgICAgICMgdGhhdCBpcyB0aGUgYW5zd2VyIGl0IGtub3dzIGhv
>>"%PS1%.b64" echo dyB0byBleHBsYWluIHRvIHRoZSBwbGF5ZXIuDQogICAgICAgICMgQSBjYW5jZWwgYWJvcnRzIHRo
>>"%PS1%.b64" echo ZSByZXF1ZXN0IGZyb20gdGhlIG91dHNpZGUsIGFuZCB0aGF0IHN1cmZhY2VzIGFzIGENCiAgICAg
>>"%PS1%.b64" echo ICAgIyBXZWJFeGNlcHRpb24gd2l0aCBubyByZXNwb25zZSBhdHRhY2hlZC4gUmVwb3J0aW5nIGl0
>>"%PS1%.b64" echo IGFzICJjYW5ub3QgcmVhY2gNCiAgICAgICAgIyB0aGUgbG9jYWwgQUkiIHdvdWxkIGJsYW1lIHRo
>>"%PS1%.b64" echo ZSBwbGF5ZXIncyBzZXR1cCBmb3IgdGhlaXIgb3duIFN0b3AgcHJlc3MsDQogICAgICAgICMgc28g
>>"%PS1%.b64" echo Y2FuY2VsbGF0aW9uIGlzIHJlY29nbmlzZWQgaGVyZSBhbmQgcGFzc2VkIG92ZXIgaW4gc2lsZW5j
>>"%PS1%.b64" echo ZSAtIHRoZQ0KICAgICAgICAjIHNpdGUgYWxyZWFkeSBrbm93cyBhYm91dCBpdCwgaXQgaXMgdGhl
>>"%PS1%.b64" echo IG9uZSB0aGF0IHNlbnQgdGhlIGNhbmNlbC4NCiAgICAgICAgJGFib3J0ZWQgPSAoJF8uRXhjZXB0
>>"%PS1%.b64" echo aW9uLlN0YXR1cyAtZXEgJ1JlcXVlc3RDYW5jZWxlZCcpIC1vciAoJF8uRXhjZXB0aW9uLlN0YXR1
>>"%PS1%.b64" echo cyAtZXEgJ0Fib3J0ZWQnKQ0KDQogICAgICAgICRlcnJvclJlc3BvbnNlID0gJF8uRXhjZXB0aW9u
>>"%PS1%.b64" echo LlJlc3BvbnNlDQogICAgICAgIGlmICgkbnVsbCAtbmUgJGVycm9yUmVzcG9uc2UpIHsNCiAgICAg
>>"%PS1%.b64" echo ICAgICAgIHRyeSB7DQogICAgICAgICAgICAgICAgJFF1ZXVlLkVucXVldWUoKE5ldy1GcmFtZSAn
>>"%PS1%.b64" echo cmVzJyAkSWQgQHsNCiAgICAgICAgICAgICAgICAgICAgc3RhdHVzICA9IFtpbnRdJGVycm9yUmVz
>>"%PS1%.b64" echo cG9uc2UuU3RhdHVzQ29kZQ0KICAgICAgICAgICAgICAgICAgICBoZWFkZXJzID0gQHsgJ0NvbnRl
>>"%PS1%.b64" echo bnQtVHlwZScgPSBbc3RyaW5nXSRlcnJvclJlc3BvbnNlLkNvbnRlbnRUeXBlIH0NCiAgICAgICAg
>>"%PS1%.b64" echo ICAgICAgICB9KSkNCiAgICAgICAgICAgICAgICAkZXJyb3JTdHJlYW0gPSAkZXJyb3JSZXNwb25z
>>"%PS1%.b64" echo ZS5HZXRSZXNwb25zZVN0cmVhbSgpDQogICAgICAgICAgICAgICAgJGVycm9yQnVmZmVyID0gTmV3
>>"%PS1%.b64" echo LU9iamVjdCBieXRlW10gNjU1MzYNCiAgICAgICAgICAgICAgICB3aGlsZSAoJHRydWUpIHsNCiAg
>>"%PS1%.b64" echo ICAgICAgICAgICAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgICAgICAgICAgICAgICRuID0gJGVy
>>"%PS1%.b64" echo cm9yU3RyZWFtLlJlYWQoJGVycm9yQnVmZmVyLCAwLCAkZXJyb3JCdWZmZXIuTGVuZ3RoKQ0KICAg
>>"%PS1%.b64" echo ICAgICAgICAgICAgICAgICB9DQogICAgICAgICAgICAgICAgICAgIGNhdGNoIFtTeXN0ZW0uSU8u
>>"%PS1%.b64" echo SU9FeGNlcHRpb25dIHsNCiAgICAgICAgICAgICAgICAgICAgICAgIGJyZWFrDQogICAgICAgICAg
>>"%PS1%.b64" echo ICAgICAgICAgIH0NCiAgICAgICAgICAgICAgICAgICAgaWYgKCRuIC1sZSAwKSB7IGJyZWFrIH0N
>>"%PS1%.b64" echo CiAgICAgICAgICAgICAgICAgICAgJGVzbGljZSA9IE5ldy1PYmplY3QgYnl0ZVtdICRuDQogICAg
>>"%PS1%.b64" echo ICAgICAgICAgICAgICAgIFtBcnJheV06OkNvcHkoJGVycm9yQnVmZmVyLCAwLCAkZXNsaWNlLCAw
>>"%PS1%.b64" echo LCAkbikNCiAgICAgICAgICAgICAgICAgICAgUHVzaC1DaHVuayAkZXNsaWNlDQogICAgICAgICAg
>>"%PS1%.b64" echo ICAgICAgfQ0KICAgICAgICAgICAgICAgICRlcnJvclN0cmVhbS5DbG9zZSgpDQogICAgICAgICAg
>>"%PS1%.b64" echo ICAgICAgJFF1ZXVlLkVucXVldWUoKE5ldy1GcmFtZSAnZW5kJyAkSWQpKQ0KICAgICAgICAgICAg
>>"%PS1%.b64" echo fQ0KICAgICAgICAgICAgY2F0Y2ggew0KICAgICAgICAgICAgICAgICRRdWV1ZS5FbnF1ZXVlKChO
>>"%PS1%.b64" echo ZXctRnJhbWUgJ2VycicgJElkIEB7IG1lc3NhZ2UgPSAkXy5FeGNlcHRpb24uTWVzc2FnZSB9KSkN
>>"%PS1%.b64" echo CiAgICAgICAgICAgIH0NCiAgICAgICAgfQ0KICAgICAgICBlbHNlaWYgKC1ub3QgJGFib3J0ZWQp
>>"%PS1%.b64" echo IHsNCiAgICAgICAgICAgICMgTm8gcmVzcG9uc2UgYXQgYWxsOiB0aGUgbG9jYWwgQUkgaXMgbm90
>>"%PS1%.b64" echo IHJ1bm5pbmcsIG9yIHJlZnVzZWQgdGhlDQogICAgICAgICAgICAjIGNvbm5lY3Rpb24uIFRoaXMg
>>"%PS1%.b64" echo aXMgdGhlIG1lc3NhZ2UgdGhlIHBsYXllciBjYW4gYWN0IG9uLg0KICAgICAgICAgICAgJFF1ZXVl
>>"%PS1%.b64" echo LkVucXVldWUoKE5ldy1GcmFtZSAnZXJyJyAkSWQgQHsgbWVzc2FnZSA9ICJDYW5ub3QgcmVhY2gg
>>"%PS1%.b64" echo dGhlIGxvY2FsIEFJIG9uIHBvcnQgJFRhcmdldFBvcnQuIiB9KSkNCiAgICAgICAgfQ0KICAgIH0N
>>"%PS1%.b64" echo CiAgICBjYXRjaCBbU3lzdGVtLlRocmVhZGluZy5UaHJlYWRJbnRlcnJ1cHRlZEV4Y2VwdGlvbl0g
>>"%PS1%.b64" echo ew0KICAgIH0NCiAgICBjYXRjaCBbU3lzdGVtLk9wZXJhdGlvbkNhbmNlbGVkRXhjZXB0aW9uXSB7
>>"%PS1%.b64" echo DQogICAgICAgICMgQWJvcnRlZCBvbiBwdXJwb3NlLCBiZWNhdXNlIHRoZSBwbGF5ZXIgcHJlc3Nl
>>"%PS1%.b64" echo ZCBTdG9wLg0KICAgIH0NCiAgICBjYXRjaCB7DQogICAgICAgICRRdWV1ZS5FbnF1ZXVlKChOZXct
>>"%PS1%.b64" echo RnJhbWUgJ2VycicgJElkIEB7IG1lc3NhZ2UgPSAkXy5FeGNlcHRpb24uTWVzc2FnZSB9KSkNCiAg
>>"%PS1%.b64" echo ICB9DQogICAgZmluYWxseSB7DQogICAgICAgICRMaXZlLlRyeVJlbW92ZSgkSWQsICRudWxsKQ0K
>>"%PS1%.b64" echo ICAgICAgICBpZiAoJHJlc3BvbnNlKSB7IHRyeSB7ICRyZXNwb25zZS5DbG9zZSgpIH0gY2F0Y2gg
>>"%PS1%.b64" echo eyB9IH0NCiAgICAgICAgaWYgKCRyZXF1ZXN0KSB7IHRyeSB7ICRyZXF1ZXN0LkFib3J0KCkgfSBj
>>"%PS1%.b64" echo YXRjaCB7IH0gfQ0KICAgIH0NCn0NCg0KJFdvcmtlclRleHQgPSAkV29ya2VyLlRvU3RyaW5nKCkN
>>"%PS1%.b64" echo Cg0KIyBBIHBhdGggdGhhdCByZWFkcyB3ZWxsIGluIHRoZSBsb2cgYW5kIGluIHRoZSBmcmFtZTog
>>"%PS1%.b64" echo Jy92MScgb3IgJycuDQokcHJlZml4ID0gJycNCmlmICgkQmFzZVBhdGggLW5lICdST09UJykgeyAk
>>"%PS1%.b64" echo cHJlZml4ID0gJy8nICsgJEJhc2VQYXRoLlRyaW0oJy8nKSB9DQoNCiRwb29sID0gW3J1bnNwYWNl
>>"%PS1%.b64" echo ZmFjdG9yeV06OkNyZWF0ZVJ1bnNwYWNlUG9vbCgxLCA4KQ0KJHBvb2wuT3BlbigpDQoNCiMgU2hh
>>"%PS1%.b64" echo cmVkIGJldHdlZW4gdGhlIHNvY2tldCB0aHJlYWQgYW5kIHRoZSB3b3JrZXJzOiBhIHF1ZXVlIGJl
>>"%PS1%.b64" echo Y2F1c2Ugc2V2ZXJhbA0KIyB3b3JrZXJzIGZpbmlzaCBhdCBvbmNlLCBhIGRpY3Rpb25hcnkgc28g
>>"%PS1%.b64" echo YSAiY2FuY2VsIiBmcmFtZSBjYW4gZmluZCB0aGUgcmVxdWVzdA0KIyBpdCBiZWxvbmdzIHRvLiBC
>>"%PS1%.b64" echo dWlsdCBoZXJlIHNvIGV2ZXJ5IHJ1bnNwYWNlIGhvbGRzIHRoZSBTQU1FIG9iamVjdHMuDQokb3V0
>>"%PS1%.b64" echo Ym94ID0gTmV3LU9iamVjdCAnU3lzdGVtLkNvbGxlY3Rpb25zLkNvbmN1cnJlbnQuQ29uY3VycmVu
>>"%PS1%.b64" echo dFF1ZXVlW3N0cmluZ10nDQokbGl2ZSA9IE5ldy1PYmplY3QgJ1N5c3RlbS5Db2xsZWN0aW9ucy5D
>>"%PS1%.b64" echo b25jdXJyZW50LkNvbmN1cnJlbnREaWN0aW9uYXJ5W2ludCxvYmplY3RdJw0KJHdvcmtlcnMgPSBO
>>"%PS1%.b64" echo ZXctT2JqZWN0IFN5c3RlbS5Db2xsZWN0aW9ucy5BcnJheUxpc3QNCg0KZnVuY3Rpb24gU3RhcnQt
>>"%PS1%.b64" echo V29ya2VyIHsNCiAgICBwYXJhbShbbG9uZ10kSWQsIFtzdHJpbmddJE1ldGhvZCwgW3N0cmluZ10k
>>"%PS1%.b64" echo UGF0aCwgJEhlYWRlcnMsICRCb2R5LA0KICAgICAgICAgIFtpbnRdJFBvcnQgPSAwLCBbc3RyaW5n
>>"%PS1%.b64" echo XSRQYXRoUHJlZml4ID0gJHByZWZpeCkNCg0KICAgICMgJFBvcnQgY2FuIGJlIGhhbmRlZCBleHBs
>>"%PS1%.b64" echo aWNpdGx5ICh0aGUgaW1hZ2UvY2hhdCBicmFuY2hlcyBwYXNzIHRoZWlyIHdvcmtlcg0KICAgICMg
>>"%PS1%.b64" echo cG9ydHMpIG9yIGxlZnQgYXQgMCB0byBtZWFuICJ0aGUgZGV0ZWN0ZWQgQUkgcG9ydCIuDQogICAg
>>"%PS1%.b64" echo aWYgKCRQb3J0IC1sZSAwKSB7ICRQb3J0ID0gJFRhcmdldFBvcnQgfQ0KDQogICAgJHBzID0gW3Bv
>>"%PS1%.b64" echo d2Vyc2hlbGxdOjpDcmVhdGUoKQ0KICAgICRwcy5SdW5zcGFjZVBvb2wgPSAkcG9vbA0KICAgIFt2
>>"%PS1%.b64" echo b2lkXSRwcy5BZGRTY3JpcHQoJFdvcmtlclRleHQpLg0KICAgICAgICBBZGRBcmd1bWVudCgkSWQp
>>"%PS1%.b64" echo LkFkZEFyZ3VtZW50KCRNZXRob2QpLkFkZEFyZ3VtZW50KCRQYXRoKS5BZGRBcmd1bWVudCgkSGVh
>>"%PS1%.b64" echo ZGVycykuDQogICAgICAgIEFkZEFyZ3VtZW50KCRCb2R5KS5BZGRBcmd1bWVudCgkb3V0Ym94KS5B
>>"%PS1%.b64" echo ZGRBcmd1bWVudCgkbGl2ZSkuDQogICAgICAgIEFkZEFyZ3VtZW50KCRQb3J0KS5BZGRBcmd1bWVu
>>"%PS1%.b64" echo dCgkUGF0aFByZWZpeCkNCiAgICBbdm9pZF0kd29ya2Vycy5BZGQoQHsgUFMgPSAkcHM7IEhhbmRs
>>"%PS1%.b64" echo ZSA9ICRwcy5CZWdpbkludm9rZSgpIH0pDQp9DQoNCiMgT25lIGluY29taW5nIGZyYW1lLCBvbmUg
>>"%PS1%.b64" echo YWN0aW9uLiBBbnl0aGluZyB1bnJlY29nbmlzZWQgaXMgaWdub3JlZCBvbiBwdXJwb3NlOg0KIyB0
>>"%PS1%.b64" echo aGUgb3RoZXIgZW5kIG1heSBiZSBhIG5ld2VyIGJ1aWxkIHRoYXQgc2VuZHMgZnJhbWUgdHlwZXMg
>>"%PS1%.b64" echo dGhpcyBvbmUgaGFzIG5ldmVyDQojIGhlYXJkIG9mLCBhbmQgYSBjaGF0IGluIHByb2dyZXNzIG11
>>"%PS1%.b64" echo c3Qgbm90IGRpZSBvdmVyIHRoYXQuDQpmdW5jdGlvbiBIYW5kbGUtSW5jb21pbmcgew0KICAgIHBh
>>"%PS1%.b64" echo cmFtKFtzdHJpbmddJFRleHQpDQoNCiAgICB0cnkgeyAkZnJhbWUgPSBDb252ZXJ0RnJvbS1Kc29u
>>"%PS1%.b64" echo ICRUZXh0IH0gY2F0Y2ggeyByZXR1cm4gfQ0KICAgIGlmICgkbnVsbCAtZXEgJGZyYW1lIC1vciAk
>>"%PS1%.b64" echo bnVsbCAtZXEgJGZyYW1lLnQpIHsgcmV0dXJuIH0NCg0KICAgIHN3aXRjaCAoJGZyYW1lLnQpIHsN
>>"%PS1%.b64" echo CiAgICAgICAgJ3BpbmcnIHsNCiAgICAgICAgICAgICRvdXRib3guRW5xdWV1ZSgoTmV3LUZyYW1l
>>"%PS1%.b64" echo ICdwb25nJykpDQogICAgICAgIH0NCiAgICAgICAgJ3JlcScgew0KICAgICAgICAgICAgJGJ5dGVz
>>"%PS1%.b64" echo ID0gJG51bGwNCiAgICAgICAgICAgIGlmICgkZnJhbWUuYm9keSkgeyAkYnl0ZXMgPSBbQ29udmVy
>>"%PS1%.b64" echo dF06OkZyb21CYXNlNjRTdHJpbmcoW3N0cmluZ10kZnJhbWUuYm9keSkgfQ0KICAgICAgICAgICAg
>>"%PS1%.b64" echo aWYgKChbc3RyaW5nXSRmcmFtZS5raW5kKSAtZXEgJ2ltYWdlJykgew0KICAgICAgICAgICAgICAg
>>"%PS1%.b64" echo IFN0YXJ0LVdvcmtlciAoW2xvbmddJGZyYW1lLmlkKSAoW3N0cmluZ10kZnJhbWUubWV0aG9kKSAo
>>"%PS1%.b64" echo W3N0cmluZ10kZnJhbWUucGF0aCkgJGZyYW1lLmhlYWRlcnMgJGJ5dGVzICRJbWFnZVBvcnQgJycN
>>"%PS1%.b64" echo CiAgICAgICAgICAgIH0NCiAgICAgICAgICAgIGVsc2VpZiAoKFtzdHJpbmddJGZyYW1lLmtpbmQp
>>"%PS1%.b64" echo IC1lcSAnY2hhdCcpIHsNCiAgICAgICAgICAgICAgICBTdGFydC1Xb3JrZXIgKFtsb25nXSRmcmFt
>>"%PS1%.b64" echo ZS5pZCkgKFtzdHJpbmddJGZyYW1lLm1ldGhvZCkgKFtzdHJpbmddJGZyYW1lLnBhdGgpICRmcmFt
>>"%PS1%.b64" echo ZS5oZWFkZXJzICRieXRlcyAkQ2hhdFBvcnQgJycNCiAgICAgICAgICAgIH0NCiAgICAgICAgICAg
>>"%PS1%.b64" echo IGVsc2Ugew0KICAgICAgICAgICAgICAgIFN0YXJ0LVdvcmtlciAoW2xvbmddJGZyYW1lLmlkKSAo
>>"%PS1%.b64" echo W3N0cmluZ10kZnJhbWUubWV0aG9kKSAoW3N0cmluZ10kZnJhbWUucGF0aCkgJGZyYW1lLmhlYWRl
>>"%PS1%.b64" echo cnMgJGJ5dGVzDQogICAgICAgICAgICB9DQogICAgICAgIH0NCiAgICAgICAgJ2NhbmNlbCcgew0K
>>"%PS1%.b64" echo ICAgICAgICAgICAgIyBUaGUgc2l0ZSBpcyBubyBsb25nZXIgcmVhZGluZyB0aGlzIGFuc3dlcjog
>>"%PS1%.b64" echo aXQgd2FzIGEgU3RvcCBidXR0b24sIGENCiAgICAgICAgICAgICMgY2xvc2VkIHRhYiwgb3IgYSBy
>>"%PS1%.b64" echo ZXF1ZXN0IHRoYXQgaGl0IGEgbGltaXQuIEFib3J0IHRoZSBsb2NhbCBjYWxsIHNvDQogICAgICAg
>>"%PS1%.b64" echo ICAgICAjIHRoZSBHUFUgc3RvcHMgd29ya2luZyBvbiBhIHJlcGx5IG5vYm9keSB3aWxsIHNlZS4N
>>"%PS1%.b64" echo CiAgICAgICAgICAgIGlmICgkbGl2ZS5Db250YWluc0tleShbaW50XSRmcmFtZS5pZCkpIHsNCiAg
>>"%PS1%.b64" echo ICAgICAgICAgICAgICB0cnkgeyAkbGl2ZVtbaW50XSRmcmFtZS5pZF0uQWJvcnQoKSB9IGNhdGNo
>>"%PS1%.b64" echo IHsgfQ0KICAgICAgICAgICAgfQ0KICAgICAgICB9DQogICAgICAgICdwb25nJyB7DQogICAgICAg
>>"%PS1%.b64" echo IH0NCiAgICAgICAgZGVmYXVsdCB7DQogICAgICAgIH0NCiAgICB9DQp9DQoNCiMgaHR0cDovLyBo
>>"%PS1%.b64" echo YXMgdG8gYmVjb21lIHdzOi8vIGFuZCBodHRwczovLyB3c3M6Ly8uIENsaWVudFdlYlNvY2tldCBy
>>"%PS1%.b64" echo ZWZ1c2VzIGENCiMgcGxhaW4gaHR0cCBhZGRyZXNzIG91dHJpZ2h0LCBzbyB3aXRob3V0IHRoaXMg
>>"%PS1%.b64" echo ZXZlcnkgaHR0cDovLyBzaXRlIC0gaW5jbHVkaW5nIGENCiMgZGV2ZWxvcGVyJ3Mgb3duIG1hY2hp
>>"%PS1%.b64" echo bmUsIGFuZCB0aGUgYWNjZXB0YW5jZSBydW4gLSBmYWlscyBhdCBvbmNlIHdpdGggYW4NCiMgImlu
>>"%PS1%.b64" echo dmFsaWQgVVJJIiB0aGF0IHNheXMgbm90aGluZyBhYm91dCB0aGUgY2F1c2UuDQokaG9zdEFuZFBh
>>"%PS1%.b64" echo dGggPSAkU2l0ZSAtcmVwbGFjZSAnXig/aSlodHRwcz86Ly8nLCAnJw0KJHNjaGVtZSA9IGlmICgk
>>"%PS1%.b64" echo U2l0ZSAtbWF0Y2ggJ14oP2kpaHR0cHM6Ly8nKSB7ICd3c3MnIH0gZWxzZSB7ICd3cycgfQ0KJGVu
>>"%PS1%.b64" echo ZHBvaW50ID0gKCd7MH06Ly97MX0vYWktYWdlbnQ/dj0xJnQ9ezJ9JyAtZiAkc2NoZW1lLCAkaG9z
>>"%PS1%.b64" echo dEFuZFBhdGgsICRUb2tlbikNCmlmICgkVGFyZ2V0UG9ydCAtZ3QgMCkgew0KICAgIFNheSAiYWdl
>>"%PS1%.b64" echo bnQgc3RhcnRpbmc6IHNpdGUgJFNpdGUsIGxvY2FsIEFJIG9uIHBvcnQgJFRhcmdldFBvcnQkcHJl
>>"%PS1%.b64" echo Zml4Ig0KfQ0KZWxzZSB7DQogICAgU2F5ICJhZ2VudCBzdGFydGluZzogc2l0ZSAkU2l0ZSwgbm8g
>>"%PS1%.b64" echo bG9jYWwgQUkgKG9mZmxvYWRlZCB3b3JrIG9ubHkpIg0KfQ0KaWYgKCRJbWFnZS5Jc1ByZXNlbnQp
>>"%PS1%.b64" echo IHsNCiAgICBTYXkgImltYWdlIG9mZmxvYWQgb246IGltYWdlIGdlbmVyYXRpb24gam9icyBnbyB0
>>"%PS1%.b64" echo byBsb2NhbCB3b3JrZXIgb24gcG9ydCAkSW1hZ2VQb3J0Ig0KfQ0KaWYgKCRDaGF0LklzUHJlc2Vu
>>"%PS1%.b64" echo dCkgew0KICAgIFNheSAiY2hhdCBvZmZsb2FkIG9uOiB0aGUgZnJlZSBBSSdzIHRleHQgY29tcGxl
>>"%PS1%.b64" echo dGlvbnMgZ28gdG8gbG9jYWwgd29ya2VyIG9uIHBvcnQgJENoYXRQb3J0Ig0KfQ0KDQojIC0tLS0t
>>"%PS1%.b64" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>>"%PS1%.b64" echo LS0tLS0tLS0tLS0tLQ0KIyAiQ29ubmVjdCBhdXRvbWF0aWNhbGx5IjogdGhlIGxvb3BiYWNrIHRv
>>"%PS1%.b64" echo a2VuIGRvb3IuDQojDQojIFRoZSBTZXR0aW5ncyBwYWdlIG9uIFRISVMgY29tcHV0ZXIgcmVhZHMg
>>"%PS1%.b64" echo dGhlIGNvbm5lY3RvciB0b2tlbiBzdHJhaWdodCBmcm9tDQojIHRoaXMgd2luZG93LCBzbyBub2Jv
>>"%PS1%.b64" echo ZHkgaGFzIHRvIGNvcHkgYW4gYWRkcmVzcyBvdXQgb2YgYSBjb25zb2xlIGFuZCBwYXN0ZSBpdA0K
>>"%PS1%.b64" echo IyBpbnRvIGEgZmllbGQuIFRoZSBmaWxlIGFuc3dlcnMgb25lIHJlcXVlc3Qgb24gMTI3LjAuMC4x
>>"%PS1%.b64" echo IChsb29wYmFjayBvbmx5LA0KIyBuZXZlciB0aGUgbmV0d29yaykgb24gb25lIG9mIHRoZSBwb3J0
>>"%PS1%.b64" echo cyBiZWxvdywgYW5kIHRoZSBwYWdlIHNjYW5zIHRoYXQgZXhhY3QNCiMgcmFuZ2UuIEEgbG9vcGJh
>>"%PS1%.b64" echo Y2sgYWRkcmVzcyBpcyBzcGVjaWFsIHRvIGJyb3dzZXJzOiBhbiBodHRwcyBwYWdlIG1heSBmZXRj
>>"%PS1%.b64" echo aCBpdA0KIyAocG90ZW50aWFsbHkgdHJ1c3R3b3J0aHksIHNvIG5vIG1peGVkLWNvbnRlbnQgYmxv
>>"%PS1%.b64" echo Y2spLCB5ZXQgdGhlIGNhbGwgYXJyaXZlcw0KIyB3aXRoIHRoZSBwYWdlJ3MgT3JpZ2luIOKAlCBh
>>"%PS1%.b64" echo bmQgdGhlIHRva2VuIGlzIG9ubHkgZXZlciByZXZlYWxlZCB0byBhbiBvcmlnaW4NCiMgdGhhdCBJ
>>"%PS1%.b64" echo UyB0aGlzIHNpdGUgKHRoZSBvbmUgdGhpcyBmaWxlIHdhcyBkb3dubG9hZGVkIGZyb20pIG9yIGFu
>>"%PS1%.b64" echo b3RoZXINCiMgbG9vcGJhY2sgcGFnZSAodGhlIHBsYXllcidzIG93biBtYWNoaW5lKS4gVGhlIHNl
>>"%PS1%.b64" echo Y3JldCBuZXZlciByaWRlcyBpbiBhIGhlYWRlcg0KIyBvciBhIFVSTCwgb25seSBpbiB0aGUgYm9k
>>"%PS1%.b64" echo eSBvZiB0aGlzIG9uZSBwYXRoLg0KIw0KIyBUaGUgYWdlbnQgY29ubmVjdG9yIG93bnMgMTE1MTAt
>>"%PS1%.b64" echo MTE1MTMuIDExNTAwIGlzIGRlbGliZXJhdGVseSBza2lwcGVkIOKAlCBpdA0KIyBpcyBQUk9YWVBP
>>"%PS1%.b64" echo UlQsIHRoZSByZWxheS1tb2RlIGRvb3J3YXkuDQojDQojIFRoZSBpbWFnZSBnZW5lcmF0b3Igc2hp
>>"%PS1%.b64" echo cHMgdGhpcyBzYW1lIGZpbGUgd2l0aCAtSW1hZ2UgYW5kIGlzIHNraXBwZWQgaGVyZSBvbg0KIyBw
>>"%PS1%.b64" echo dXJwb3NlOiBpdHMgdG9rZW4gaXMgbm90IGEgbG9jYWwtbW9kZWwgYWRkcmVzcyBhbmQgbXVzdCBu
>>"%PS1%.b64" echo ZXZlciBiZSBvZmZlcmVkIHRvDQojIHRoZSBTZXR0aW5ncyBwYWdlIGFzIG9uZS4gVGhpcyBpcyB0
>>"%PS1%.b64" echo aGUgb25seSBnYXRlIHRoZSBmbGFnIGdldHMuDQojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>>"%PS1%.b64" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQ0KDQojIFRo
>>"%PS1%.b64" echo ZSBKU09OIHRoZSBwYWdlIHJlYWRzLiBraW5kIHNheXMgd2hpY2ggU2V0dGluZ3MgZmllbGQgdGhl
>>"%PS1%.b64" echo IGFkZHJlc3MgYmVsb25ncw0KIyB0bzsgdGhlIHBhZ2UgcmVidWlsZHMgaHR0cHM6Ly88c2l0ZT4v
>>"%PS1%.b64" echo YWkvPHRva2VuPi92MSBmcm9tIHNpdGUrdG9rZW4sIGJ5dGUgZm9yDQojIGJ5dGUgdGhlIGFkZHJl
>>"%PS1%.b64" echo c3MgdGhlIGNvbnNvbGUgcHJpbnRzLg0KJGluZm9QYXlsb2FkID0gQ29udmVydFRvLUpzb24gLUNv
>>"%PS1%.b64" echo bXByZXNzIC1JbnB1dE9iamVjdCBAew0KICAgIG9rICAgID0gJHRydWUNCiAgICBraW5kICA9ICdh
>>"%PS1%.b64" echo Z2VudCcNCiAgICBzaXRlICA9ICRTaXRlDQogICAgdG9rZW4gPSAkVG9rZW4NCn0NCg0KIyBUaGUg
>>"%PS1%.b64" echo b25lIG5vbi1sb29wYmFjayBvcmlnaW4gYWxsb3dlZCB0byByZWFkIHRoZSB0b2tlbjogc2NoZW1l
>>"%PS1%.b64" echo ICsgaG9zdCAoKyBwb3J0LA0KIyB3aGVuIHRoZSBzaXRlIHVzZXMgYSBub24tZGVmYXVsdCBvbmU7
>>"%PS1%.b64" echo IFVyaS5Qb3J0IGZpbGxzIGRlZmF1bHQgcG9ydHMgaW4gYW5kIGENCiMgYnJvd3NlcidzIE9yaWdp
>>"%PS1%.b64" echo biBvbWl0cyB0aGVtLCBzbyBib3RoIHNpZGVzIG1lZXQgaW4gdGhlIG1pZGRsZSkuDQokaW5mb1Np
>>"%PS1%.b64" echo dGVVcmkgPSAkbnVsbA0KJGluZm9TaXRlU2NoZW1lID0gJycNCiRpbmZvU2l0ZUhvc3QgPSAnJw0K
>>"%PS1%.b64" echo JGluZm9TaXRlUG9ydCA9IC0xDQppZiAoW1VyaV06OlRyeUNyZWF0ZSgkU2l0ZSwgW1VyaUtpbmRd
>>"%PS1%.b64" echo OjpBYnNvbHV0ZSwgW3JlZl0kaW5mb1NpdGVVcmkpIC1hbmQgJGluZm9TaXRlVXJpLlNjaGVtZSAt
>>"%PS1%.b64" echo bWF0Y2ggJ14oP2kpaHR0cHM/JCcpIHsNCiAgICAkaW5mb1NpdGVTY2hlbWUgPSAkaW5mb1NpdGVV
>>"%PS1%.b64" echo cmkuU2NoZW1lLlRvTG93ZXJJbnZhcmlhbnQoKQ0KICAgICRpbmZvU2l0ZUhvc3QgPSAkaW5mb1Np
>>"%PS1%.b64" echo dGVVcmkuSG9zdC5Ub0xvd2VySW52YXJpYW50KCkNCiAgICAkaW5mb1NpdGVQb3J0ID0gJGluZm9T
>>"%PS1%.b64" echo aXRlVXJpLlBvcnQNCn0NCg0KIyBPbmUgY29ubmVjdGlvbiwgb25lIHNob3J0IGFuc3dlci4gSXQg
>>"%PS1%.b64" echo cnVucyBpbiBpdHMgb3duIHJ1bnNwYWNlIHNvIHRoZSBhZ2VudA0KIyBsb29wIGJlbG93IGlzIG5l
>>"%PS1%.b64" echo dmVyIGJsb2NrZWQgYnkgYSBzbG93IG9yIGhvc3RpbGUgbG9jYWwgcmVxdWVzdDsgZXZlcnl0aGlu
>>"%PS1%.b64" echo Zw0KIyBpdCBuZWVkcyBhcnJpdmVzIGFzIGFuIGFyZ3VtZW50LCBiZWNhdXNlIGEgcnVuc3BhY2Ug
>>"%PS1%.b64" echo aGFzIG5vIGFjY2VzcyB0byB0aGUNCiMgdmFyaWFibGVzIG9mIHRoZSBvbmUgdGhhdCBzdGFydGVk
>>"%PS1%.b64" echo IGl0Lg0KJEluZm9IYW5kbGVyID0gew0KICAgIHBhcmFtKCRDbGllbnQsICRQYXlsb2FkLCAkQWxs
>>"%PS1%.b64" echo b3dlZFNjaGVtZSwgJEFsbG93ZWRIb3N0LCAkQWxsb3dlZFBvcnQpDQoNCiAgICAkRXJyb3JBY3Rp
>>"%PS1%.b64" echo b25QcmVmZXJlbmNlID0gJ1N0b3AnDQoNCiAgICBmdW5jdGlvbiBSZWFkLUhlYWQgew0KICAgICAg
>>"%PS1%.b64" echo ICBwYXJhbShbU3lzdGVtLklPLlN0cmVhbV0kU3RyZWFtKQ0KDQogICAgICAgICRidWZmZXIgPSBO
>>"%PS1%.b64" echo ZXctT2JqZWN0IGJ5dGVbXSAxNjM4NA0KICAgICAgICAkYWNjID0gTmV3LU9iamVjdCBieXRlW10g
>>"%PS1%.b64" echo MTYzODQNCiAgICAgICAgJGxlbiA9IDANCg0KICAgICAgICB3aGlsZSAoJHRydWUpIHsNCiAgICAg
>>"%PS1%.b64" echo ICAgICAgICRuID0gJFN0cmVhbS5SZWFkKCRidWZmZXIsIDAsICRidWZmZXIuTGVuZ3RoKQ0KICAg
>>"%PS1%.b64" echo ICAgICAgICAgaWYgKCRuIC1sZSAwKSB7IGJyZWFrIH0NCiAgICAgICAgICAgIGlmICgkbGVuICsg
>>"%PS1%.b64" echo JG4gLWd0ICRhY2MuTGVuZ3RoKSB7DQogICAgICAgICAgICAgICAgJGFjYyA9IE5ldy1PYmplY3Qg
>>"%PS1%.b64" echo Ynl0ZVtdIChbTWF0aF06Ok1heCgkYWNjLkxlbmd0aCAqIDIsICRsZW4gKyAkbikpDQogICAgICAg
>>"%PS1%.b64" echo ICAgICB9DQogICAgICAgICAgICBbQXJyYXldOjpDb3B5KCRidWZmZXIsIDAsICRhY2MsICRsZW4s
>>"%PS1%.b64" echo ICRuKQ0KICAgICAgICAgICAgJGxlbiArPSAkbg0KICAgICAgICAgICAgaWYgKFtUZXh0LkVuY29k
>>"%PS1%.b64" echo aW5nXTo6QVNDSUkuR2V0U3RyaW5nKCRhY2MsIDAsICRsZW4pLkluZGV4T2YoImByYG5gcmBuIikg
>>"%PS1%.b64" echo LWdlIDApIHsgYnJlYWsgfQ0KICAgICAgICB9DQoNCiAgICAgICAgcmV0dXJuIFtUZXh0LkVuY29k
>>"%PS1%.b64" echo aW5nXTo6QVNDSUkuR2V0U3RyaW5nKCRhY2MsIDAsICRsZW4pDQogICAgfQ0KDQogICAgZnVuY3Rp
>>"%PS1%.b64" echo b24gU2VuZC1SZXBseSB7DQogICAgICAgIHBhcmFtKFtzdHJpbmddJFN0YXR1cywgW3N0cmluZ10k
>>"%PS1%.b64" echo Qm9keSwgW3N0cmluZ10kT3JpZ2luKQ0KDQogICAgICAgICRib2R5Qnl0ZXMgPSBOZXctT2JqZWN0
>>"%PS1%.b64" echo IGJ5dGVbXSAwDQogICAgICAgIGlmICgkQm9keSkgeyAkYm9keUJ5dGVzID0gW1RleHQuRW5jb2Rp
>>"%PS1%.b64" echo bmddOjpVVEY4LkdldEJ5dGVzKCRCb2R5KSB9DQoNCiAgICAgICAgJGhlYWQgPSBOZXctT2JqZWN0
>>"%PS1%.b64" echo IFN5c3RlbS5Db2xsZWN0aW9ucy5HZW5lcmljLkxpc3Rbc3RyaW5nXQ0KICAgICAgICBbdm9pZF0k
>>"%PS1%.b64" echo aGVhZC5BZGQoIkhUVFAvMS4xICRTdGF0dXMiKQ0KICAgICAgICBbdm9pZF0kaGVhZC5BZGQoJ0Nv
>>"%PS1%.b64" echo bm5lY3Rpb246IGNsb3NlJykNCiAgICAgICAgW3ZvaWRdJGhlYWQuQWRkKCdDYWNoZS1Db250cm9s
>>"%PS1%.b64" echo OiBuby1zdG9yZScpDQogICAgICAgIFt2b2lkXSRoZWFkLkFkZCgnQWNjZXNzLUNvbnRyb2wtQWxs
>>"%PS1%.b64" echo b3ctTWV0aG9kczogR0VULCBPUFRJT05TJykNCiAgICAgICAgW3ZvaWRdJGhlYWQuQWRkKCdBY2Nl
>>"%PS1%.b64" echo c3MtQ29udHJvbC1BbGxvdy1IZWFkZXJzOiAqJykNCiAgICAgICAgIyBDaHJvbWUncyBsb2NhbC1u
>>"%PS1%.b64" echo ZXR3b3JrIHByZWZsaWdodCBpbnNpc3RzIG9uIHRoaXMgZXhwbGljaXQgbm9kIGJlZm9yZQ0KICAg
>>"%PS1%.b64" echo ICAgICAjIGl0IGxldHMgYSBwYWdlIGZldGNoZWQgZnJvbSBhIHB1YmxpYyBzaXRlIGNhbGwgYSBs
>>"%PS1%.b64" echo b29wYmFjayBhZGRyZXNzIGF0DQogICAgICAgICMgYWxsLiBTZW50IG9uIGV2ZXJ5IGFuc3dlciwg
>>"%PS1%.b64" echo dGhlIHJlZnVzYWwgaW5jbHVkZWQsIHNvIHRoZSBvYmplY3Rpb24NCiAgICAgICAgIyBjYW5ub3Qg
>>"%PS1%.b64" echo YmUgbWlzdGFrZW4gZm9yIGl0cyBvd24gZmFpbHVyZS4NCiAgICAgICAgW3ZvaWRdJGhlYWQuQWRk
>>"%PS1%.b64" echo KCdBY2Nlc3MtQ29udHJvbC1BbGxvdy1Qcml2YXRlLU5ldHdvcms6IHRydWUnKQ0KICAgICAgICBb
>>"%PS1%.b64" echo dm9pZF0kaGVhZC5BZGQoJ0FjY2Vzcy1Db250cm9sLU1heC1BZ2U6IDYwMCcpDQogICAgICAgIGlm
>>"%PS1%.b64" echo ICgkT3JpZ2luKSB7DQogICAgICAgICAgICAjIFRoZSBvcmlnaW4gaXMgZWNob2VkLCBuZXZlciBn
>>"%PS1%.b64" echo cmFudGVkIGFzICcqJzogdGhlIGJvZHkgY2FycmllcyB0aGUNCiAgICAgICAgICAgICMgdG9rZW4s
>>"%PS1%.b64" echo IHNvIGEgcGFnZSBtYXkgcmVhZCBpdCBvbmx5IGFmdGVyIHRoZSBPcmlnaW4gY2hlY2sgYmVsb3cN
>>"%PS1%.b64" echo CiAgICAgICAgICAgICMgaGFzIHByb3ZlZCB3aG8gdGhlIGNhbGxlciBpcy4gQSBmb3JlaWduIHBh
>>"%PS1%.b64" echo Z2UgZ2V0cyBubyBBQ0FPIGFuZA0KICAgICAgICAgICAgIyBjYW5ub3QgcmVhZCBhIHNpbmdsZSBi
>>"%PS1%.b64" echo eXRlIG9mIHRoZSBhbnN3ZXIuDQogICAgICAgICAgICBbdm9pZF0kaGVhZC5BZGQoIkFjY2Vzcy1D
>>"%PS1%.b64" echo b250cm9sLUFsbG93LU9yaWdpbjogJE9yaWdpbiIpDQogICAgICAgICAgICBbdm9pZF0kaGVhZC5B
>>"%PS1%.b64" echo ZGQoJ1Zhcnk6IE9yaWdpbicpDQogICAgICAgIH0NCiAgICAgICAgaWYgKCRib2R5Qnl0ZXMuTGVu
>>"%PS1%.b64" echo Z3RoIC1ndCAwKSB7IFt2b2lkXSRoZWFkLkFkZCgnQ29udGVudC1UeXBlOiBhcHBsaWNhdGlvbi9q
>>"%PS1%.b64" echo c29uOyBjaGFyc2V0PXV0Zi04JykgfQ0KICAgICAgICBbdm9pZF0kaGVhZC5BZGQoIkNvbnRlbnQt
>>"%PS1%.b64" echo TGVuZ3RoOiAkKCRib2R5Qnl0ZXMuTGVuZ3RoKSIpDQogICAgICAgIFt2b2lkXSRoZWFkLkFkZCgn
>>"%PS1%.b64" echo JykNCg0KICAgICAgICAkZG93biA9ICRDbGllbnQuR2V0U3RyZWFtKCkNCiAgICAgICAgIyBBIGpv
>>"%PS1%.b64" echo aW4gb24gdGhlIHRyYWlsaW5nIGVtcHR5IGxpbmUgbGVhdmVzIG9uZSBcclxuIGF0IHRoZSBlbmQ7
>>"%PS1%.b64" echo IEhUVFANCiAgICAgICAgIyBtYXJrcyB0aGUgaGVhZGVyJ3MgZW5kIHdpdGggdHdvIChcclxuXHJc
>>"%PS1%.b64" echo biksIHNvIG9uZSBtb3JlIGlzIGFwcGVuZGVkLg0KICAgICAgICAkaGVhZEJ5dGVzID0gW1RleHQu
>>"%PS1%.b64" echo RW5jb2RpbmddOjpBU0NJSS5HZXRCeXRlcygoJGhlYWQgLWpvaW4gImByYG4iKSArICJgcmBuIikN
>>"%PS1%.b64" echo CiAgICAgICAgJGRvd24uV3JpdGUoJGhlYWRCeXRlcywgMCwgJGhlYWRCeXRlcy5MZW5ndGgpDQog
>>"%PS1%.b64" echo ICAgICAgIGlmICgkYm9keUJ5dGVzLkxlbmd0aCAtZ3QgMCkgeyAkZG93bi5Xcml0ZSgkYm9keUJ5
>>"%PS1%.b64" echo dGVzLCAwLCAkYm9keUJ5dGVzLkxlbmd0aCkgfQ0KICAgICAgICAkZG93bi5GbHVzaCgpDQogICAg
>>"%PS1%.b64" echo fQ0KDQogICAgIyBXaG8gbWF5IHJlYWQgdGhlIHRva2VuOiBwYWdlcyBzZXJ2ZWQgZnJvbSB0aGlz
>>"%PS1%.b64" echo IHZlcnkgc2l0ZSwgYW55IGxvb3BiYWNrDQogICAgIyBwYWdlICh0aGUgcGxheWVyJ3Mgb3duIG1h
>>"%PS1%.b64" echo Y2hpbmUg4oCUIGRldiBzZXJ2ZXIsIGFub3RoZXIgdGFiKSwgYW5kIGNhbGxlcnMNCiAgICAjIHdp
>>"%PS1%.b64" echo dGggbm8gT3JpZ2luIGF0IGFsbCAobG9jYWwgdG9vbHMgbGlrZSBjdXJsOyB0aGUgdG9rZW4gbGll
>>"%PS1%.b64" echo cyBpbiBwbGFpbnRleHQNCiAgICAjIGZpbGVzIG9uIHRoaXMgbWFjaGluZSBhbnl3YXksIHNvIHRo
>>"%PS1%.b64" echo YXQgaXMgbm90IGEgbGVhaykuDQogICAgZnVuY3Rpb24gT3JpZ2luLUFsbG93cyhbc3RyaW5nXSRP
>>"%PS1%.b64" echo cmlnaW4pIHsNCiAgICAgICAgaWYgKFtzdHJpbmddOjpJc051bGxPcldoaXRlU3BhY2UoJE9yaWdp
>>"%PS1%.b64" echo bikpIHsgcmV0dXJuICR0cnVlIH0NCiAgICAgICAgJG8gPSAkbnVsbA0KICAgICAgICBpZiAoLW5v
>>"%PS1%.b64" echo dCBbVXJpXTo6VHJ5Q3JlYXRlKCRPcmlnaW4sIFtVcmlLaW5kXTo6QWJzb2x1dGUsIFtyZWZdJG8p
>>"%PS1%.b64" echo KSB7IHJldHVybiAkZmFsc2UgfQ0KICAgICAgICBpZiAoJG8uU2NoZW1lIC1ub3RtYXRjaCAnXig/
>>"%PS1%.b64" echo aSlodHRwcz8kJykgeyByZXR1cm4gJGZhbHNlIH0NCiAgICAgICAgaWYgKCRvLkhvc3QuVG9Mb3dl
>>"%PS1%.b64" echo ckludmFyaWFudCgpIC1pbiBAKCdsb2NhbGhvc3QnLCAnMTI3LjAuMC4xJywgJ1s6OjFdJykpIHsg
>>"%PS1%.b64" echo cmV0dXJuICR0cnVlIH0NCiAgICAgICAgaWYgKC1ub3QgJEFsbG93ZWRTY2hlbWUpIHsgcmV0dXJu
>>"%PS1%.b64" echo ICRmYWxzZSB9DQogICAgICAgIGlmICgkby5TY2hlbWUuVG9Mb3dlckludmFyaWFudCgpIC1uZSAk
>>"%PS1%.b64" echo QWxsb3dlZFNjaGVtZSkgeyByZXR1cm4gJGZhbHNlIH0NCiAgICAgICAgaWYgKCRvLkhvc3QuVG9M
>>"%PS1%.b64" echo b3dlckludmFyaWFudCgpIC1uZSAkQWxsb3dlZEhvc3QpIHsgcmV0dXJuICRmYWxzZSB9DQogICAg
>>"%PS1%.b64" echo ICAgIGlmICgkby5Qb3J0IC1uZSAkQWxsb3dlZFBvcnQpIHsgcmV0dXJuICRmYWxzZSB9DQogICAg
>>"%PS1%.b64" echo ICAgIHJldHVybiAkdHJ1ZQ0KICAgIH0NCg0KICAgIHRyeSB7DQogICAgICAgICRDbGllbnQuTm9E
>>"%PS1%.b64" echo ZWxheSA9ICR0cnVlDQogICAgICAgICRyYXcgPSBSZWFkLUhlYWQgLVN0cmVhbSAkQ2xpZW50Lkdl
>>"%PS1%.b64" echo dFN0cmVhbSgpDQogICAgICAgIGlmIChbc3RyaW5nXTo6SXNOdWxsT3JXaGl0ZVNwYWNlKCRyYXcp
>>"%PS1%.b64" echo KSB7IHJldHVybiB9DQoNCiAgICAgICAgJGxpbmVzID0gJHJhdyAtc3BsaXQgImByYG4iDQogICAg
>>"%PS1%.b64" echo ICAgIGlmICgkbGluZXNbMF0gLW5vdG1hdGNoICdeKEdFVHxPUFRJT05TKVxzKyhcUyspXHMrSFRU
>>"%PS1%.b64" echo UC8xXC5bMDFdJCcpIHsgcmV0dXJuIH0NCiAgICAgICAgJG1ldGhvZCA9ICRNYXRjaGVzWzFdDQog
>>"%PS1%.b64" echo ICAgICAgICRwYXRoID0gKCRNYXRjaGVzWzJdIC1zcGxpdCAnXD8nKVswXQ0KDQogICAgICAgICMg
>>"%PS1%.b64" echo T25seSB0aGlzIG9uZSBwYXRoIGV2ZXIgYW5zd2VyczsgZXZlcnl0aGluZyBlbHNlIGdldHMgdGhl
>>"%PS1%.b64" echo IGNvbm5lY3Rpb24NCiAgICAgICAgIyBjbG9zZWQgd2l0aG91dCBhIGJ5dGUsIHNvIGEgcG9ydCBz
>>"%PS1%.b64" echo Y2FuIG9mIHRoZSByYW5nZSBsZWFybnMgbm90aGluZy4NCiAgICAgICAgaWYgKCRwYXRoIC1uZSAn
>>"%PS1%.b64" echo L2FpbS9jb25uZWN0b3InKSB7IHJldHVybiB9DQoNCiAgICAgICAgJG9yaWdpbiA9ICcnDQogICAg
>>"%PS1%.b64" echo ICAgIGZvcmVhY2ggKCRsaW5lIGluICRsaW5lcykgew0KICAgICAgICAgICAgaWYgKCRsaW5lIC1t
>>"%PS1%.b64" echo YXRjaCAnXk9yaWdpbjpccyooXFMrKScpIHsgJG9yaWdpbiA9ICRNYXRjaGVzWzFdLlRyaW0oKTsg
>>"%PS1%.b64" echo YnJlYWsgfQ0KICAgICAgICB9DQogICAgICAgICRhbGxvd2VkID0gT3JpZ2luLUFsbG93cyAkb3Jp
>>"%PS1%.b64" echo Z2luDQoNCiAgICAgICAgaWYgKCRtZXRob2QgLWVxICdPUFRJT05TJykgew0KICAgICAgICAgICAg
>>"%PS1%.b64" echo IyBUaGUgcHJlZmxpZ2h0IChDT1JTLCBhbmQgQ2hyb21lJ3MgcHJpdmF0ZS1uZXR3b3JrIHByZWZs
>>"%PS1%.b64" echo aWdodCkNCiAgICAgICAgICAgICMgY2FycmllcyBubyBib2R5IGFuZCBuZWVkcyBvbmx5IHRoZSBo
>>"%PS1%.b64" echo ZWFkZXJzIGFib3ZlLiBBIHJlZnVzZWQNCiAgICAgICAgICAgICMgb3JpZ2luIGlzIGNsb3NlZCB3
>>"%PS1%.b64" echo aXRob3V0IGEgZ3JhbnQsIGV4YWN0bHkgbGlrZSBhIEdFVC4NCiAgICAgICAgICAgIGlmICgkYWxs
>>"%PS1%.b64" echo b3dlZCkgeyBTZW5kLVJlcGx5ICcyMDQgTm8gQ29udGVudCcgJycgJG9yaWdpbiB9DQogICAgICAg
>>"%PS1%.b64" echo ICAgICByZXR1cm4NCiAgICAgICAgfQ0KDQogICAgICAgIGlmICgtbm90ICRhbGxvd2VkKSB7DQog
>>"%PS1%.b64" echo ICAgICAgICAgICBTZW5kLVJlcGx5ICc0MDMgRm9yYmlkZGVuJyAneyJlcnJvciI6InJlZnVzZWQi
>>"%PS1%.b64" echo fScgJG9yaWdpbg0KICAgICAgICAgICAgcmV0dXJuDQogICAgICAgIH0NCg0KICAgICAgICBTZW5k
>>"%PS1%.b64" echo LVJlcGx5ICcyMDAgT0snICRQYXlsb2FkICRvcmlnaW4NCiAgICB9DQogICAgY2F0Y2ggeyB9DQog
>>"%PS1%.b64" echo ICAgZmluYWxseSB7IHRyeSB7ICRDbGllbnQuQ2xvc2UoKSB9IGNhdGNoIHsgfSB9DQp9DQoNCiRJ
>>"%PS1%.b64" echo bmZvSGFuZGxlclRleHQgPSAkSW5mb0hhbmRsZXIuVG9TdHJpbmcoKQ0KDQppZiAoLW5vdCAkSW1h
>>"%PS1%.b64" echo Z2UuSXNQcmVzZW50KSB7DQogICAgIyBUaGUgZmlyc3QgZnJlZSBwb3J0IG9mIHRoZSByYW5nZSBp
>>"%PS1%.b64" echo cyB0YWtlbjsgdGhlIHBhZ2Ugc2NhbnMgdGhlIHdob2xlDQogICAgIyByYW5nZSwgc28gdGhlIGV4
>>"%PS1%.b64" echo YWN0IHBvcnQgaXMgaXRzIGJ1c2luZXNzLCBub3Qgb3Vycy4gQSBwb3J0IGhlbGQgYnkgc29tZQ0K
>>"%PS1%.b64" echo ICAgICMgb3RoZXIgcHJvZ3JhbSBpcyBhIHNraXAsIG5vdCBhIGZhaWx1cmUuDQogICAgJGluZm9Q
>>"%PS1%.b64" echo b3J0cyA9IDExNTEwLi4xMTUxMw0KICAgICRpbmZvTGlzdGVuZXIgPSAkbnVsbA0KICAgIGZvcmVh
>>"%PS1%.b64" echo Y2ggKCRwIGluICRpbmZvUG9ydHMpIHsNCiAgICAgICAgJHRyaWFsID0gTmV3LU9iamVjdCBTeXN0
>>"%PS1%.b64" echo ZW0uTmV0LlNvY2tldHMuVGNwTGlzdGVuZXIoW05ldC5JUEFkZHJlc3NdOjpMb29wYmFjaywgJHAp
>>"%PS1%.b64" echo DQogICAgICAgIHRyeSB7DQogICAgICAgICAgICAkdHJpYWwuU3RhcnQoKQ0KICAgICAgICAgICAg
>>"%PS1%.b64" echo JGluZm9MaXN0ZW5lciA9ICR0cmlhbA0KICAgICAgICAgICAgYnJlYWsNCiAgICAgICAgfQ0KICAg
>>"%PS1%.b64" echo ICAgICBjYXRjaCB7DQogICAgICAgICAgICB0cnkgeyAkdHJpYWwuU3RvcCgpIH0gY2F0Y2ggeyB9
>>"%PS1%.b64" echo DQogICAgICAgIH0NCiAgICB9DQoNCiAgICBpZiAoJG51bGwgLW5lICRpbmZvTGlzdGVuZXIpIHsN
>>"%PS1%.b64" echo CiAgICAgICAgJEluZm9Mb29wID0gew0KICAgICAgICAgICAgcGFyYW0oJExpc3RlbmVyLCAkSGFu
>>"%PS1%.b64" echo ZGxlclRleHQsICRQYXlsb2FkLCAkQWxsb3dlZFNjaGVtZSwgJEFsbG93ZWRIb3N0LCAkQWxsb3dl
>>"%PS1%.b64" echo ZFBvcnQpDQoNCiAgICAgICAgICAgICMgQSB0aW55IHBvb2wgc28gdHdvIHBhZ2Ugc2NhbnMgY2Fu
>>"%PS1%.b64" echo bm90IGJsb2NrIGVhY2ggb3RoZXI7IHBlcg0KICAgICAgICAgICAgIyBjb25uZWN0aW9uIG9uZSBz
>>"%PS1%.b64" echo aG9ydC1saXZlZCBjb21tYW5kLCBhbnN3ZXJlZCBhbmQgY2xvc2VkLg0KICAgICAgICAgICAgJHBv
>>"%PS1%.b64" echo b2wgPSBbcnVuc3BhY2VmYWN0b3J5XTo6Q3JlYXRlUnVuc3BhY2VQb29sKDEsIDgpDQogICAgICAg
>>"%PS1%.b64" echo ICAgICAkcG9vbC5PcGVuKCkNCiAgICAgICAgICAgIHRyeSB7DQogICAgICAgICAgICAgICAgd2hp
>>"%PS1%.b64" echo bGUgKCR0cnVlKSB7DQogICAgICAgICAgICAgICAgICAgICRjbGllbnQgPSAkTGlzdGVuZXIuQWNj
>>"%PS1%.b64" echo ZXB0VGNwQ2xpZW50KCkNCiAgICAgICAgICAgICAgICAgICAgJHBzID0gW3Bvd2Vyc2hlbGxdOjpD
>>"%PS1%.b64" echo cmVhdGUoKQ0KICAgICAgICAgICAgICAgICAgICAkcHMuUnVuc3BhY2VQb29sID0gJHBvb2wNCiAg
>>"%PS1%.b64" echo ICAgICAgICAgICAgICAgICAgW3ZvaWRdJHBzLkFkZFNjcmlwdCgkSGFuZGxlclRleHQpLg0KICAg
>>"%PS1%.b64" echo ICAgICAgICAgICAgICAgICAgICAgQWRkQXJndW1lbnQoJGNsaWVudCkuQWRkQXJndW1lbnQoJFBh
>>"%PS1%.b64" echo eWxvYWQpLg0KICAgICAgICAgICAgICAgICAgICAgICAgQWRkQXJndW1lbnQoJEFsbG93ZWRTY2hl
>>"%PS1%.b64" echo bWUpLkFkZEFyZ3VtZW50KCRBbGxvd2VkSG9zdCkuQWRkQXJndW1lbnQoJEFsbG93ZWRQb3J0KQ0K
>>"%PS1%.b64" echo ICAgICAgICAgICAgICAgICAgICBbdm9pZF0kcHMuQmVnaW5JbnZva2UoKQ0KICAgICAgICAgICAg
>>"%PS1%.b64" echo ICAgIH0NCiAgICAgICAgICAgIH0NCiAgICAgICAgICAgIGNhdGNoIHsgfQ0KICAgICAgICB9DQoN
>>"%PS1%.b64" echo CiAgICAgICAgJGluZm9SdW4gPSBbcnVuc3BhY2VmYWN0b3J5XTo6Q3JlYXRlUnVuc3BhY2UoKQ0K
>>"%PS1%.b64" echo ICAgICAgICAkaW5mb1J1bi5PcGVuKCkNCiAgICAgICAgJGluZm9QcyA9IFtwb3dlcnNoZWxsXTo6
>>"%PS1%.b64" echo Q3JlYXRlKCkNCiAgICAgICAgJGluZm9Qcy5SdW5zcGFjZSA9ICRpbmZvUnVuDQogICAgICAgIFt2
>>"%PS1%.b64" echo b2lkXSRpbmZvUHMuQWRkU2NyaXB0KCRJbmZvTG9vcCkuDQogICAgICAgICAgICBBZGRBcmd1bWVu
>>"%PS1%.b64" echo dCgkaW5mb0xpc3RlbmVyKS5BZGRBcmd1bWVudCgkSW5mb0hhbmRsZXJUZXh0KS5BZGRBcmd1bWVu
>>"%PS1%.b64" echo dCgkaW5mb1BheWxvYWQpLg0KICAgICAgICAgICAgQWRkQXJndW1lbnQoJGluZm9TaXRlU2NoZW1l
>>"%PS1%.b64" echo KS5BZGRBcmd1bWVudCgkaW5mb1NpdGVIb3N0KS5BZGRBcmd1bWVudCgkaW5mb1NpdGVQb3J0KQ0K
>>"%PS1%.b64" echo ICAgICAgICBbdm9pZF0kaW5mb1BzLkJlZ2luSW52b2tlKCkNCiAgICAgICAgU2F5ICJjb25uZWN0
>>"%PS1%.b64" echo IGF1dG9tYXRpY2FsbHk6IHRoZSBzaXRlJ3MgU2V0dGluZ3MgcGFnZSBmaW5kcyB0aGlzIHdpbmRv
>>"%PS1%.b64" echo dyBieSBpdHNlbGYgLSBub3RoaW5nIHRvIHR5cGUgaW4iDQogICAgfQ0KfQ0KDQokYXR0ZW1wdCA9
>>"%PS1%.b64" echo IDANCndoaWxlICgkdHJ1ZSkgew0KICAgICRhdHRlbXB0KysNCiAgICAkc29ja2V0ID0gJG51bGwN
>>"%PS1%.b64" echo CiAgICAkY29ubmVjdCA9IE5ldy1PYmplY3QgU3lzdGVtLlRocmVhZGluZy5DYW5jZWxsYXRpb25U
>>"%PS1%.b64" echo b2tlblNvdXJjZQ0KICAgICR3b3JrZXJzID0gTmV3LU9iamVjdCBTeXN0ZW0uQ29sbGVjdGlvbnMu
>>"%PS1%.b64" echo QXJyYXlMaXN0DQoNCiAgICB0cnkgew0KICAgICAgICAkYnVmZmVyID0gTmV3LU9iamVjdCBieXRl
>>"%PS1%.b64" echo W10gNjU1MzYNCiAgICAgICAgJHNlZ21lbnQgPSBOZXctT2JqZWN0IFN5c3RlbS5BcnJheVNlZ21l
>>"%PS1%.b64" echo bnRbYnl0ZV0gKCwkYnVmZmVyKQ0KICAgICAgICAkcGFydGlhbCA9IE5ldy1PYmplY3QgU3lzdGVt
>>"%PS1%.b64" echo LkNvbGxlY3Rpb25zLkdlbmVyaWMuTGlzdFtieXRlXQ0KDQogICAgICAgICRzb2NrZXQgPSBOZXct
>>"%PS1%.b64" echo T2JqZWN0IFN5c3RlbS5OZXQuV2ViU29ja2V0cy5DbGllbnRXZWJTb2NrZXQNCiAgICAgICAgIyBQ
>>"%PS1%.b64" echo cm90b2NvbC1sZXZlbCBrZWVwLWFsaXZlLCBzbyBhIE5BVCB0aGF0IHF1aWV0bHkgZHJvcHMgYW4g
>>"%PS1%.b64" echo aWRsZQ0KICAgICAgICAjIGNvbm5lY3Rpb24gaXMgbm90aWNlZCB3aXRoaW4gYSBtaW51dGUgaW5z
>>"%PS1%.b64" echo dGVhZCBvZiBhdCB0aGUgbmV4dCByZXF1ZXN0Lg0KICAgICAgICAkc29ja2V0Lk9wdGlvbnMuS2Vl
>>"%PS1%.b64" echo cEFsaXZlSW50ZXJ2YWwgPSBbVGltZVNwYW5dOjpGcm9tU2Vjb25kcygyMCkNCg0KICAgICAgICAj
>>"%PS1%.b64" echo IEEgZGVhZGxpbmUgZm9yIHRoZSBoYW5kc2hha2Ugb25seS4gSXQgaXMgc3dpdGNoZWQgb2ZmIHN0
>>"%PS1%.b64" echo cmFpZ2h0IGFmdGVyLA0KICAgICAgICAjIGJlY2F1c2UgdGhlIHNhbWUgdG9rZW4gdGhlbiBoYXMg
>>"%PS1%.b64" echo dG8gc3Vydml2ZSB0aGUgd2hvbGUgc2Vzc2lvbiAtIGENCiAgICAgICAgIyByZWNlaXZlIGxvb3Ag
>>"%PS1%.b64" echo dGhhdCBkaWVzIG9uIGl0cyBvd24gZGVhZGxpbmUgd291bGQgZHJvcCB0aGUgcGxheWVyIG91dA0K
>>"%PS1%.b64" echo ICAgICAgICAjIG9mIGEgY2hhdCBldmVyeSB0d2VudHkgc2Vjb25kcy4NCiAgICAgICAgJGNvbm5l
>>"%PS1%.b64" echo Y3QuQ2FuY2VsQWZ0ZXIoMjAwMDApDQogICAgICAgICRzb2NrZXQuQ29ubmVjdEFzeW5jKFtVcmld
>>"%PS1%.b64" echo JGVuZHBvaW50LCAkY29ubmVjdC5Ub2tlbikuR2V0QXdhaXRlcigpLkdldFJlc3VsdCgpDQogICAg
>>"%PS1%.b64" echo ICAgICRjb25uZWN0LkNhbmNlbEFmdGVyKFtUaHJlYWRpbmcuVGltZW91dF06OkluZmluaXRlKQ0K
>>"%PS1%.b64" echo ICAgICAgICBTYXkgImNvbm5lY3RlZCB0byAkU2l0ZSINCg0KICAgICAgICBTZW5kLUZyYW1lICRz
>>"%PS1%.b64" echo b2NrZXQgKE5ldy1GcmFtZSAnaGVsbG8nIDAgQHsNCiAgICAgICAgICAgIHBvcnQgICAgID0gJFRh
>>"%PS1%.b64" echo cmdldFBvcnQNCiAgICAgICAgICAgIGJhc2VQYXRoID0gJHByZWZpeA0KICAgICAgICAgICAgbmVl
>>"%PS1%.b64" echo ZHNLZXkgPSAkZmFsc2UNCiAgICAgICAgICAgIGltYWdlICAgID0gW2Jvb2xdJEltYWdlDQogICAg
>>"%PS1%.b64" echo ICAgICAgICBjaGF0ICAgICA9IFtib29sXSRDaGF0DQogICAgICAgICAgICBjaGF0UG9ydCA9IFtp
>>"%PS1%.b64" echo bnRdJENoYXRQb3J0DQogICAgICAgIH0pDQoNCiAgICAgICAgIyBFeGFjdGx5IG9uZSByZWNlaXZl
>>"%PS1%.b64" echo IGluIGZsaWdodCBhdCBhIHRpbWUsIGFuZCBuZXZlciB3YWl0ZWQgb246IHdoaWxlIGl0DQogICAg
>>"%PS1%.b64" echo ICAgICMgaXMgcGVuZGluZyB0aGlzIGxvb3Agc2VuZHMgd2hhdGV2ZXIgdGhlIHdvcmtlcnMgcHJv
>>"%PS1%.b64" echo ZHVjZWQuIFRoYXQgaXMgd2hhdA0KICAgICAgICAjIGxldHMgYSBsb25nIHN0cmVhbWluZyByZXBs
>>"%PS1%.b64" echo eSBhbmQgdGhlIG5leHQgcmVxdWVzdCB0cmF2ZWwgb3ZlciB0aGUgc2FtZQ0KICAgICAgICAjIHNv
>>"%PS1%.b64" echo Y2tldCBhdCB0aGUgc2FtZSB0aW1lLg0KICAgICAgICAkcmVjZWl2ZVRhc2sgPSAkc29ja2V0LlJl
>>"%PS1%.b64" echo Y2VpdmVBc3luYygkc2VnbWVudCwgJGNvbm5lY3QuVG9rZW4pDQogICAgICAgICRydW5uaW5nID0g
>>"%PS1%.b64" echo JHRydWUNCg0KICAgICAgICB3aGlsZSAoJHJ1bm5pbmcpIHsNCiAgICAgICAgICAgIGlmICgkcmVj
>>"%PS1%.b64" echo ZWl2ZVRhc2suSXNDb21wbGV0ZWQpIHsNCiAgICAgICAgICAgICAgICAkcmVzdWx0ID0gJHJlY2Vp
>>"%PS1%.b64" echo dmVUYXNrLkdldEF3YWl0ZXIoKS5HZXRSZXN1bHQoKQ0KICAgICAgICAgICAgICAgIGlmICgkcmVz
>>"%PS1%.b64" echo dWx0Lk1lc3NhZ2VUeXBlIC1lcSBbU3lzdGVtLk5ldC5XZWJTb2NrZXRzLldlYlNvY2tldE1lc3Nh
>>"%PS1%.b64" echo Z2VUeXBlXTo6Q2xvc2UpIHsgYnJlYWsgfQ0KDQogICAgICAgICAgICAgICAgaWYgKCRyZXN1bHQu
>>"%PS1%.b64" echo Q291bnQgLWd0IDApIHsNCiAgICAgICAgICAgICAgICAgICAgJGNodW5rID0gTmV3LU9iamVjdCBi
>>"%PS1%.b64" echo eXRlW10gJHJlc3VsdC5Db3VudA0KICAgICAgICAgICAgICAgICAgICBbQXJyYXldOjpDb3B5KCRi
>>"%PS1%.b64" echo dWZmZXIsIDAsICRjaHVuaywgMCwgJHJlc3VsdC5Db3VudCkNCiAgICAgICAgICAgICAgICAgICAg
>>"%PS1%.b64" echo JHBhcnRpYWwuQWRkUmFuZ2UoJGNodW5rKQ0KICAgICAgICAgICAgICAgIH0NCg0KICAgICAgICAg
>>"%PS1%.b64" echo ICAgICAgIGlmICgkcmVzdWx0LkVuZE9mTWVzc2FnZSkgew0KICAgICAgICAgICAgICAgICAgICBI
>>"%PS1%.b64" echo YW5kbGUtSW5jb21pbmcgKFtUZXh0LkVuY29kaW5nXTo6VVRGOC5HZXRTdHJpbmcoJHBhcnRpYWwu
>>"%PS1%.b64" echo VG9BcnJheSgpKSkNCiAgICAgICAgICAgICAgICAgICAgJHBhcnRpYWwuQ2xlYXIoKQ0KICAgICAg
>>"%PS1%.b64" echo ICAgICAgICAgIH0NCg0KICAgICAgICAgICAgICAgICRyZWNlaXZlVGFzayA9ICRzb2NrZXQuUmVj
>>"%PS1%.b64" echo ZWl2ZUFzeW5jKCRzZWdtZW50LCAkY29ubmVjdC5Ub2tlbikNCiAgICAgICAgICAgIH0NCiAgICAg
>>"%PS1%.b64" echo ICAgICAgIGVsc2Ugew0KICAgICAgICAgICAgICAgICRmcmFtZSA9ICRudWxsDQogICAgICAgICAg
>>"%PS1%.b64" echo ICAgICAgd2hpbGUgKCRvdXRib3guVHJ5RGVxdWV1ZShbcmVmXSRmcmFtZSkpIHsgU2VuZC1GcmFt
>>"%PS1%.b64" echo ZSAkc29ja2V0ICRmcmFtZSB9DQoNCiAgICAgICAgICAgICAgICAjIFJldGlyZSBmaW5pc2hlZCB3
>>"%PS1%.b64" echo b3JrZXJzLiBUaGVpciBvdXRwdXQgd2VudCBpbnRvIHRoZSBvdXRib3ggYXMNCiAgICAgICAgICAg
>>"%PS1%.b64" echo ICAgICAjIGl0IHdhcyBwcm9kdWNlZCwgc28gbm90aGluZyBvZiB0aGVpcnMgaXMgcmVhZCBoZXJl
>>"%PS1%.b64" echo Lg0KICAgICAgICAgICAgICAgIGZvciAoJGkgPSAkd29ya2Vycy5Db3VudCAtIDE7ICRpIC1nZSAw
>>"%PS1%.b64" echo OyAkaS0tKSB7DQogICAgICAgICAgICAgICAgICAgIGlmICgtbm90ICR3b3JrZXJzWyRpXS5IYW5k
>>"%PS1%.b64" echo bGUuSXNDb21wbGV0ZWQpIHsgY29udGludWUgfQ0KICAgICAgICAgICAgICAgICAgICB0cnkgeyAk
>>"%PS1%.b64" echo d29ya2Vyc1skaV0uSGFuZGxlLkVuZEludm9rZSgkd29ya2Vyc1skaV0uSGFuZGxlKSB9IGNhdGNo
>>"%PS1%.b64" echo IHsgfQ0KICAgICAgICAgICAgICAgICAgICAkd29ya2Vyc1skaV0uUFMuRGlzcG9zZSgpDQogICAg
>>"%PS1%.b64" echo ICAgICAgICAgICAgICAgICR3b3JrZXJzLlJlbW92ZUF0KCRpKQ0KICAgICAgICAgICAgICAgIH0N
>>"%PS1%.b64" echo Cg0KICAgICAgICAgICAgICAgIFN0YXJ0LVNsZWVwIC1NaWxsaXNlY29uZHMgMjANCiAgICAgICAg
>>"%PS1%.b64" echo ICAgIH0NCiAgICAgICAgfQ0KICAgIH0NCiAgICBjYXRjaCB7DQogICAgICAgICMgQ29ubmVjdEFz
>>"%PS1%.b64" echo eW5jIHJlcG9ydHMgZmFpbHVyZXMgd3JhcHBlZCwgYW5kIHRoZSBpbm5lciBtZXNzYWdlIGlzIHRo
>>"%PS1%.b64" echo ZQ0KICAgICAgICAjIG9uZSB0aGF0IHNheXMgd2hldGhlciB0aGlzIHdhcyBhIHJlZnVzZWQgY29u
>>"%PS1%.b64" echo bmVjdGlvbiwgYSB3cm9uZyB0b2tlbiwgb3INCiAgICAgICAgIyB0aGUgc2l0ZSBiZWluZyBkb3du
>>"%PS1%.b64" echo Lg0KICAgICAgICAkcmVhc29uID0gJF8uRXhjZXB0aW9uDQogICAgICAgIHdoaWxlICgkcmVhc29u
>>"%PS1%.b64" echo LklubmVyRXhjZXB0aW9uKSB7ICRyZWFzb24gPSAkcmVhc29uLklubmVyRXhjZXB0aW9uIH0NCiAg
>>"%PS1%.b64" echo ICAgICAgU2F5ICgiY29ubmVjdGlvbiBsb3N0OiAiICsgJHJlYXNvbi5NZXNzYWdlKQ0KICAgIH0N
>>"%PS1%.b64" echo CiAgICBmaW5hbGx5IHsNCiAgICAgICAgIyBTdG9wIGFueSBnZW5lcmF0aW9uIHN0aWxsIHJ1bm5p
>>"%PS1%.b64" echo bmcgZm9yIHRoaXMgc29ja2V0OiB0aGUgc2l0ZSBpcyBub3QNCiAgICAgICAgIyB0aGVyZSB0byBy
>>"%PS1%.b64" echo ZWNlaXZlIGl0LCBhbmQgYSBidXN5IEdQVSBmb3Igbm9ib2R5IGlzIGEgd2FzdGUuDQogICAgICAg
>>"%PS1%.b64" echo IGZvcmVhY2ggKCRwYWlyIGluICRsaXZlKSB7IGlmICgkcGFpci5WYWx1ZSkgeyB0cnkgeyAkcGFp
>>"%PS1%.b64" echo ci5WYWx1ZS5BYm9ydCgpIH0gY2F0Y2ggeyB9IH0gfQ0KICAgICAgICBmb3JlYWNoICgkam9iIGlu
>>"%PS1%.b64" echo ICR3b3JrZXJzKSB7DQogICAgICAgICAgICB0cnkgeyAkam9iLlBTLlN0b3AoKSB9IGNhdGNoIHsg
>>"%PS1%.b64" echo fQ0KICAgICAgICAgICAgdHJ5IHsgJGpvYi5QUy5EaXNwb3NlKCkgfSBjYXRjaCB7IH0NCiAgICAg
>>"%PS1%.b64" echo ICAgfQ0KDQogICAgICAgIHRyeSB7ICRjb25uZWN0LkNhbmNlbCgpIH0gY2F0Y2ggeyB9DQogICAg
>>"%PS1%.b64" echo ICAgIHRyeSB7ICRjb25uZWN0LkRpc3Bvc2UoKSB9IGNhdGNoIHsgfQ0KICAgICAgICBpZiAoJHNv
>>"%PS1%.b64" echo Y2tldCkgeyB0cnkgeyAkc29ja2V0LkFib3J0KCkgfSBjYXRjaCB7IH0gdHJ5IHsgJHNvY2tldC5E
>>"%PS1%.b64" echo aXNwb3NlKCkgfSBjYXRjaCB7IH0gfQ0KICAgIH0NCg0KICAgICMgUmVjb25uZWN0IGZvcmV2ZXIu
>>"%PS1%.b64" echo IFRoZSBhZGRyZXNzIHRoZSBwbGF5ZXIgcGFzdGVkIGludG8gU2V0dGluZ3MgZG9lcyBub3QNCiAg
>>"%PS1%.b64" echo ICAjIGNvbnRhaW4gdGhpcyBzb2NrZXQsIHNvIG5vdGhpbmcgdGhleSB0eXBlZCBoYXMgdG8gY2hh
>>"%PS1%.b64" echo bmdlIC0gd2hpY2ggaXMgdGhlDQogICAgIyBlbnRpcmUgcG9pbnQgb2YgZG9pbmcgaXQgdGhpcyB3
>>"%PS1%.b64" echo YXkuDQogICAgJHBhdXNlID0gW01hdGhdOjpNaW4oMzAsIDIgKyAkYXR0ZW1wdCAqIDIpDQogICAg
>>"%PS1%.b64" echo U2F5ICJyZWNvbm5lY3RpbmcgaW4gJHBhdXNlIHNlY29uZChzKSINCiAgICBTdGFydC1TbGVlcCAt
>>"%PS1%.b64" echo U2Vjb25kcyAkcGF1c2UNCn0=
powershell -NoProfile -Command "[IO.File]::WriteAllBytes('%PS1%', [Convert]::FromBase64String(([IO.File]::ReadAllText('%PS1%.b64') -replace '\s','')))" >nul 2>&1
del /q "%PS1%.b64" >nul 2>&1
>"%WORKERPS1%.b64" echo 77u/IyBMb2NhbCBpbWFnZSB3b3JrZXIgZm9yIGFnZW50LWJhc2VkIGltYWdlIG9mZmxvYWQNCiMg
>>"%WORKERPS1%.b64" echo TGlzdGVucyBvbiBodHRwOi8vMTI3LjAuMC4xOjgwMDIgYW5kIGRyYXdzIHRocm91Z2ggaW1hZ2Vm
>>"%WORKERPS1%.b64" echo cmVlLm5ldCdzIEpTT04gQVBJDQojDQojIE5vIFB5dGhvbiBvbiB0aGUgUEMgaXMgbm90IGEgZGVh
>>"%WORKERPS1%.b64" echo ZCBlbmQ6IGEga25vd24tZ29vZCBpbnRlcnByZXRlciBpcyBsb29rZWQgZm9yDQojIGZpcnN0LCBh
>>"%WORKERPS1%.b64" echo bmQgaWYgbm9uZSBpcyBmb3VuZCBhIHBvcnRhYmxlIFB5dGhvbiAzLjEyIGlzIGRvd25sb2FkZWQg
>>"%WORKERPS1%.b64" echo b25jZSBpbnRvDQojIHRoaXMgZm9sZGVyIGFuZCB1c2VkIGZyb20gdGhlcmUuIE5vdGhpbmcgaXMg
>>"%WORKERPS1%.b64" echo aW5zdGFsbGVkIHN5c3RlbS13aWRlIGFuZCB0aGUNCiMgcGxheWVyIG5ldmVyIGhhcyB0byB2aXNp
>>"%WORKERPS1%.b64" echo dCBweXRob24ub3JnLg0KDQpwYXJhbSgNCiAgICBbaW50XSRQb3J0ID0gODAwMg0KKQ0KDQokRXJy
>>"%WORKERPS1%.b64" echo b3JBY3Rpb25QcmVmZXJlbmNlID0gJ1N0b3AnDQokc2NyaXB0RGlyID0gU3BsaXQtUGF0aCAtUGFy
>>"%WORKERPS1%.b64" echo ZW50ICRNeUludm9jYXRpb24uTXlDb21tYW5kLlBhdGgNCiR3b3JrZXJQeSA9IEpvaW4tUGF0aCAk
>>"%WORKERPS1%.b64" echo c2NyaXB0RGlyICdsb2NhbC1pbWFnZS13b3JrZXIucHknDQokdmVudkRpciA9IEpvaW4tUGF0aCAk
>>"%WORKERPS1%.b64" echo c2NyaXB0RGlyICcudmVudi1pbWFnZXdvcmtlcicNCiRweXRob25FeGUgPSBKb2luLVBhdGggJHZl
>>"%WORKERPS1%.b64" echo bnZEaXIgJ1NjcmlwdHNccHl0aG9uLmV4ZScNCiRlbWJlZGRlZERpciA9IEpvaW4tUGF0aCAkc2Ny
>>"%WORKERPS1%.b64" echo aXB0RGlyICdweXRob24tZW1iZWRkZWQnDQokZW1iZWRkZWRFeGUgPSBKb2luLVBhdGggJGVtYmVk
>>"%WORKERPS1%.b64" echo ZGVkRGlyICdweXRob24uZXhlJw0KJGdldFBpcFNjcmlwdCA9IEpvaW4tUGF0aCAkc2NyaXB0RGly
>>"%WORKERPS1%.b64" echo ICdnZXQtcGlwLnB5Jw0KDQojIFRoZSBmYWxsYmFjayBkb3dubG9hZHMgZnJvbSBweXRob24ub3Jn
>>"%WORKERPS1%.b64" echo IGFuZCBib290c3RyYXAucHlwYS5pby4gV2luZG93cw0KIyBQb3dlclNoZWxsIDUuMSBvbiBhbiB1
>>"%WORKERPS1%.b64" echo bnBhdGNoZWQgc3lzdGVtIG1heSBzdGlsbCBvZmZlciBvbmx5IFRMUyAxLjAsIHdoaWNoIGJvdGgN
>>"%WORKERPS1%.b64" echo CiMgaG9zdHMgcmVmdXNlLCBhbmQgdGhhdCB3b3VsZCBsb29rIGxpa2UgIm5vIGludGVybmV0IiBp
>>"%WORKERPS1%.b64" echo biB0aGUgbG9nLg0KdHJ5IHsNCiAgICBbTmV0LlNlcnZpY2VQb2ludE1hbmFnZXJdOjpTZWN1cml0
>>"%WORKERPS1%.b64" echo eVByb3RvY29sID0gW05ldC5TZXJ2aWNlUG9pbnRNYW5hZ2VyXTo6U2VjdXJpdHlQcm90b2NvbCAt
>>"%WORKERPS1%.b64" echo Ym9yIFtOZXQuU2VjdXJpdHlQcm90b2NvbFR5cGVdOjpUbHMxMg0KfSBjYXRjaCB7IH0NCg0KIyBF
>>"%WORKERPS1%.b64" echo dmVyeSBsaW5lIGFsc28gbGFuZHMgaW4gYSBmaWxlLCBiZWNhdXNlIHRoZSBzZXR1cCB3aW5kb3cg
>>"%WORKERPS1%.b64" echo bm93IGNsb3NlcyBieQ0KIyBpdHNlbGYgKHRoYXQgaXMgdGhlIHBvaW50IG9mIHRoaXMgc2NyaXB0
>>"%WORKERPS1%.b64" echo KS4gSWYgc29tZXRoaW5nIGZhaWxzLCBTdGFydEltYWdlR2VuZXJhdG9yDQojIHBvaW50cyB0aGUg
>>"%WORKERPS1%.b64" echo cGxheWVyIGF0IHRoaXMgbG9nIHNvIGEgdmFuaXNoZWQgd2luZG93IG5ldmVyIGhpZGVzIHRoZSBy
>>"%WORKERPS1%.b64" echo ZWFzb24uDQokbG9nRmlsZSA9IEpvaW4tUGF0aCAkc2NyaXB0RGlyICdpbWFnZS13b3JrZXIubG9n
>>"%WORKERPS1%.b64" echo Jw0KDQpmdW5jdGlvbiBTYXkgew0KICAgIHBhcmFtKFtzdHJpbmddJE1lc3NhZ2UpDQogICAgJGxp
>>"%WORKERPS1%.b64" echo bmUgPSAoInswfSB7MX0iIC1mIChHZXQtRGF0ZSAtRm9ybWF0ICdISDptbTpzcycpLCAkTWVzc2Fn
>>"%WORKERPS1%.b64" echo ZSkNCiAgICB0cnkgeyBbQ29uc29sZV06Ok91dC5Xcml0ZUxpbmUoJGxpbmUpOyBbQ29uc29sZV06
>>"%WORKERPS1%.b64" echo Ok91dC5GbHVzaCgpIH0gY2F0Y2ggeyB9DQogICAgdHJ5IHsgQWRkLUNvbnRlbnQgLUxpdGVyYWxQ
>>"%WORKERPS1%.b64" echo YXRoICRsb2dGaWxlIC1WYWx1ZSAkbGluZSAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZSB9
>>"%WORKERPS1%.b64" echo IGNhdGNoIHsgfQ0KfQ0KDQojIExvZyBhbnkgdGVybWluYXRpbmcgZXJyb3IgKGEgdGhyb3csIG9y
>>"%WORKERPS1%.b64" echo IGEgZmFpbGluZyB2ZW52L3BpcCBzdGVwKSBhbmQgZXhpdA0KIyBub24temVybyBzbyBTdGFydElt
>>"%WORKERPS1%.b64" echo YWdlR2VuZXJhdG9yIHJlcG9ydHMgYSBmYWlsdXJlIGluc3RlYWQgb2YgY2xvc2luZyBzaWxlbnRs
>>"%WORKERPS1%.b64" echo eS4NCnRyYXAgew0KICAgIFNheSAoIkVSUk9SOiB7MH0iIC1mICRfKQ0KICAgIGV4aXQgMQ0KfQ0K
>>"%WORKERPS1%.b64" echo DQpTYXkgIkxvY2FsIGltYWdlIHdvcmtlciBzdGFydGluZy4uLiINClNheSAiUG9ydDogJFBvcnQi
>>"%WORKERPS1%.b64" echo DQpTYXkgIlB5dGhvbiBzY3JpcHQ6ICR3b3JrZXJQeSINCg0KaWYgKC1ub3QgKFRlc3QtUGF0aCAt
>>"%WORKERPS1%.b64" echo TGl0ZXJhbFBhdGggJHdvcmtlclB5KSkgew0KICAgIHRocm93ICJNaXNzaW5nICR3b3JrZXJQeSIN
>>"%WORKERPS1%.b64" echo Cn0NCg0KIyBDbG9zaW5nIHRoZSBpbnN0YWxsZXIgd2luZG93IGRvZXMgbm90IGtpbGwgdGhlIGhp
>>"%WORKERPS1%.b64" echo ZGRlbiBQeXRob24gY2hpbGQuIFJlLXJ1bm5pbmcNCiMgdGhlIGluc3RhbGxlciBtdXN0IHRoZXJl
>>"%WORKERPS1%.b64" echo Zm9yZSBzdG9wIHRoZSBwcmV2aW91cyB3b3JrZXIgZmlyc3QsIG90aGVyd2lzZSB0aGUgbmV3DQoj
>>"%WORKERPS1%.b64" echo IHByb2Nlc3MgZmFpbHMgdG8gYmluZCAkUG9ydCBhbmQgdGhlIHNpdGUga2VlcHMgdGFsa2luZyB0
>>"%WORKERPS1%.b64" echo byB0aGUgT0xEIHNjcmlwdC4NCkdldC1DaW1JbnN0YW5jZSBXaW4zMl9Qcm9jZXNzIHwgV2hlcmUt
>>"%WORKERPS1%.b64" echo T2JqZWN0IHsNCiAgICAkXy5OYW1lIC1tYXRjaCAnXnB5dGhvbih3KT9cLmV4ZSQnIC1hbmQgJF8u
>>"%WORKERPS1%.b64" echo Q29tbWFuZExpbmUgLWFuZA0KICAgICgkXy5Db21tYW5kTGluZSAtbGlrZSAoJyonICsgJHdvcmtl
>>"%WORKERPS1%.b64" echo clB5ICsgJyonKSAtb3INCiAgICAgJF8uQ29tbWFuZExpbmUgLWxpa2UgJypBSUFkdmVudHVyZU1h
>>"%WORKERPS1%.b64" echo c3Rlcipsb2NhbC0qLXdvcmtlci5weSonKQ0KfSB8IEZvckVhY2gtT2JqZWN0IHsNCiAgICBTYXkg
>>"%WORKERPS1%.b64" echo IlN0b3BwaW5nIHByZXZpb3VzIHdvcmtlciBwaWQgJCgkXy5Qcm9jZXNzSWQpIg0KICAgIFN0b3At
>>"%WORKERPS1%.b64" echo UHJvY2VzcyAtSWQgJF8uUHJvY2Vzc0lkIC1Gb3JjZSAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250
>>"%WORKERPS1%.b64" echo aW51ZQ0KfQ0KR2V0LU5ldFRDUENvbm5lY3Rpb24gLUxvY2FsUG9ydCAkUG9ydCAtU3RhdGUgTGlz
>>"%WORKERPS1%.b64" echo dGVuIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlIHwNCiAgICBTZWxlY3QtT2JqZWN0IC1F
>>"%WORKERPS1%.b64" echo eHBhbmRQcm9wZXJ0eSBPd25pbmdQcm9jZXNzIC1VbmlxdWUgfA0KICAgIFdoZXJlLU9iamVjdCB7
>>"%WORKERPS1%.b64" echo ICRfIC1ndCAwIH0gfCBGb3JFYWNoLU9iamVjdCB7DQogICAgICAgICRwcm9jID0gR2V0LUNpbUlu
>>"%WORKERPS1%.b64" echo c3RhbmNlIFdpbjMyX1Byb2Nlc3MgLUZpbHRlciAiUHJvY2Vzc0lkPSRfIiAtRXJyb3JBY3Rpb24g
>>"%WORKERPS1%.b64" echo U2lsZW50bHlDb250aW51ZQ0KICAgICAgICBpZiAoJHByb2MgLWFuZCAkcHJvYy5OYW1lIC1tYXRj
>>"%WORKERPS1%.b64" echo aCAnXnB5dGhvbih3KT9cLmV4ZSQnIC1hbmQgJHByb2MuQ29tbWFuZExpbmUgLWxpa2UgJypBSUFk
>>"%WORKERPS1%.b64" echo dmVudHVyZU1hc3RlcionKSB7DQogICAgICAgICAgICBTYXkgIkZyZWVpbmcgcG9ydCAkUG9ydCBm
>>"%WORKERPS1%.b64" echo cm9tIHBpZCAkXyINCiAgICAgICAgICAgIFN0b3AtUHJvY2VzcyAtSWQgJF8gLUZvcmNlIC1FcnJv
>>"%WORKERPS1%.b64" echo ckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlDQogICAgICAgIH0NCiAgICB9DQoNCiMgLS0tLS0tLS0t
>>"%WORKERPS1%.b64" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>>"%WORKERPS1%.b64" echo LS0tLS0tLS0tDQojIFBpY2sgYW4gaW50ZXJwcmV0ZXIuIFRoaXMgd29ya2VyIG5lZWRzIG5vIGJy
>>"%WORKERPS1%.b64" echo b3dzZXIgZm9yIGltYWdlZnJlZSB0ZXh0LCBidXQgYQ0KIyBicmFuZC1uZXcgUHl0aG9uICgzLjE0
>>"%WORKERPS1%.b64" echo KykgY2FuIHN0aWxsIGxhY2sgYmluYXJ5IHdoZWVscyBmb3IgdGhlIHRyYW5zaXRpdmUgZGVwcw0K
>>"%WORKERPS1%.b64" echo IyBvZiBmYXN0YXBpL3V2aWNvcm4gYW5kIGZvcmNlIGEgZG9vbWVkIHNvdXJjZSBidWlsZC4gUHJl
>>"%WORKERPS1%.b64" echo ZmVyIGEga25vd24tZ29vZA0KIyAzLjExLTMuMTMgaW50ZXJwcmV0ZXIgYW5kIHJlZnVzZSBhbnl0
>>"%WORKERPS1%.b64" echo aGluZyBuZXdlciB3aXRoIGEgcmVhZGFibGUgcmVhc29uOyBpZg0KIyB0aGVyZSBpcyBubyB1c2Fi
>>"%WORKERPS1%.b64" echo bGUgb25lIGF0IGFsbCwgZmV0Y2ggYSBwb3J0YWJsZSBjb3B5IGJlbG93Lg0KJHN1cHBvcnRlZE1p
>>"%WORKERPS1%.b64" echo biA9IDExDQokc3VwcG9ydGVkTWF4ID0gMTMNCg0KIyBUaGUgcHJvYmVzIGJlbG93IGFyZSBxdWVz
>>"%WORKERPS1%.b64" echo dGlvbnMsIG5vdCBjb21tYW5kcyB0aGF0IG11c3Qgc3VjY2VlZC4gV2l0aCB0aGUNCiMgc2NyaXB0
>>"%WORKERPS1%.b64" echo LXdpZGUgJEVycm9yQWN0aW9uUHJlZmVyZW5jZT0nU3RvcCcgYSBuYXRpdmUgY29tbWFuZCdzIHN0
>>"%WORKERPS1%.b64" echo ZGVyciBiZWNvbWVzIGENCiMgdGVybWluYXRpbmcgZXJyb3IgYmVmb3JlIGEgcHJvYmUgY2FuIHJ1
>>"%WORKERPS1%.b64" echo biwgc28gZXZlcnkgcHJvYmUgZ29lcyB0aHJvdWdoIHRoaXMNCiMgaGVscGVyOiBpdCByZWxheGVz
>>"%WORKERPS1%.b64" echo IHRoZSBwcmVmZXJlbmNlIGZvciB0aGUgY2FsbCwgc3dhbGxvd3Mgc3RkZXJyLCBhbmQgcmV0dXJu
>>"%WORKERPS1%.b64" echo cw0KIyB0aGUgdG9vbCdzIGZpcnN0IGxpbmUgb2Ygc3Rkb3V0IG9yICRudWxsLg0KZnVuY3Rpb24g
>>"%WORKERPS1%.b64" echo SW52b2tlLVF1aWV0IHsNCiAgICBwYXJhbShbc2NyaXB0YmxvY2tdJENvbW1hbmQpDQogICAgJHBy
>>"%WORKERPS1%.b64" echo ZXYgPSAkRXJyb3JBY3Rpb25QcmVmZXJlbmNlDQogICAgJEVycm9yQWN0aW9uUHJlZmVyZW5jZSA9
>>"%WORKERPS1%.b64" echo ICdDb250aW51ZScNCiAgICB0cnkgew0KICAgICAgICByZXR1cm4gKCYgJENvbW1hbmQgMj4kbnVs
>>"%WORKERPS1%.b64" echo bCB8IFNlbGVjdC1PYmplY3QgLUZpcnN0IDEpDQogICAgfSBjYXRjaCB7DQogICAgICAgIHJldHVy
>>"%WORKERPS1%.b64" echo biAkbnVsbA0KICAgIH0gZmluYWxseSB7DQogICAgICAgICRFcnJvckFjdGlvblByZWZlcmVuY2Ug
>>"%WORKERPS1%.b64" echo PSAkcHJldg0KICAgIH0NCn0NCg0KIyBTYW1lIHJlbGF4YXRpb24sIGJ1dCBmb3IgY29tbWFuZHMg
>>"%WORKERPS1%.b64" echo d2hvc2UgZXhpdCBjb2RlIGlzIHRoZSBhbnN3ZXIuIGdldC1waXAgYW5kDQojIHBpcCBib3RoIHdy
>>"%WORKERPS1%.b64" echo aXRlIHdhcm5pbmdzIHRvIHN0ZGVyciAodGhlIFNjcmlwdHMgZm9sZGVyIGlzIG5vdCBvbiBQQVRI
>>"%WORKERPS1%.b64" echo LCB3aGVlbHMNCiMgYXJlIGJlaW5nIGRvd25sb2FkZWQpLCBhbmQgdW5kZXIgJ1N0b3AnIFBvd2Vy
>>"%WORKERPS1%.b64" echo U2hlbGwgNS4xIHJhaXNlcyBhIHRlcm1pbmF0aW5nDQojIE5hdGl2ZUNvbW1hbmRFcnJvciBmb3Ig
>>"%WORKERPS1%.b64" echo dGhhdCBiZWZvcmUgJExBU1RFWElUQ09ERSBjYW4gYmUgcmVhZC4NCmZ1bmN0aW9uIEludm9rZS1O
>>"%WORKERPS1%.b64" echo YXRpdmUgew0KICAgIHBhcmFtKFtzY3JpcHRibG9ja10kQ29tbWFuZCkNCiAgICAkcHJldiA9ICRF
>>"%WORKERPS1%.b64" echo cnJvckFjdGlvblByZWZlcmVuY2UNCiAgICAkRXJyb3JBY3Rpb25QcmVmZXJlbmNlID0gJ0NvbnRp
>>"%WORKERPS1%.b64" echo bnVlJw0KICAgIHRyeSB7DQogICAgICAgICYgJENvbW1hbmQgKj4gJG51bGwNCiAgICAgICAgcmV0
>>"%WORKERPS1%.b64" echo dXJuICRMQVNURVhJVENPREUNCiAgICB9IGNhdGNoIHsNCiAgICAgICAgcmV0dXJuIDENCiAgICB9
>>"%WORKERPS1%.b64" echo IGZpbmFsbHkgew0KICAgICAgICAkRXJyb3JBY3Rpb25QcmVmZXJlbmNlID0gJHByZXYNCiAgICB9
>>"%WORKERPS1%.b64" echo DQp9DQoNCmZ1bmN0aW9uIEdldC1QeVZlcnNpb24gew0KICAgIHBhcmFtKFtzdHJpbmddJEV4ZSkN
>>"%WORKERPS1%.b64" echo CiAgICAkdiA9IEludm9rZS1RdWlldCB7ICYgJEV4ZSAtYyAiaW1wb3J0IHN5czsgcHJpbnQoJyVk
>>"%WORKERPS1%.b64" echo LiVkJyAlIHN5cy52ZXJzaW9uX2luZm9bOjJdKSIgfQ0KICAgIGlmICgkdiAtaXMgW3N0cmluZ10g
>>"%WORKERPS1%.b64" echo LWFuZCAkdi5UcmltKCkgLW1hdGNoICdeKFxkKylcLihcZCspJCcpIHsNCiAgICAgICAgIyBtYWpv
>>"%WORKERPS1%.b64" echo cioxMDAgKyBtaW5vcjogUHl0aG9uIDMuMTIgaXMgMzEyLCBQeXRob24gMy4xNSBpcyAzMTUuDQog
>>"%WORKERPS1%.b64" echo ICAgICAgIHJldHVybiAoW2ludF0kTWF0Y2hlc1sxXSAqIDEwMCArIFtpbnRdJE1hdGNoZXNbMl0p
>>"%WORKERPS1%.b64" echo DQogICAgfQ0KICAgIHJldHVybiAwDQp9DQoNCmZ1bmN0aW9uIFRlc3QtUHlTdXBwb3J0ZWQgew0K
>>"%WORKERPS1%.b64" echo ICAgIHBhcmFtKFtpbnRdJFZlcnNpb24pDQogICAgIyBPbmx5IGEgMy54IGludGVycHJldGVyIGlz
>>"%WORKERPS1%.b64" echo IHRhcmdldGVkLCBzbyBQeXRob24gMi43ICgyMDcpIG9yIDQuMCAoNDAwKSBpcw0KICAgICMgcmVm
>>"%WORKERPS1%.b64" echo dXNlZCBvdXRyaWdodCByYXRoZXIgdGhhbiBwYXNzaW5nIHRoZSBtaW5vci1vbmx5IGJvdW5kcyBi
>>"%WORKERPS1%.b64" echo eSBhY2NpZGVudC4NCiAgICBpZiAoJFZlcnNpb24gLWx0IDMwMCAtb3IgJFZlcnNpb24gLWdlIDQw
>>"%WORKERPS1%.b64" echo MCkgeyByZXR1cm4gJGZhbHNlIH0NCiAgICAkbWlub3IgPSAkVmVyc2lvbiAlIDEwMA0KICAgIHJl
>>"%WORKERPS1%.b64" echo dHVybiAoJG1pbm9yIC1nZSAkc3VwcG9ydGVkTWluIC1hbmQgJG1pbm9yIC1sZSAkc3VwcG9ydGVk
>>"%WORKERPS1%.b64" echo TWF4KQ0KfQ0KDQokcHlDbWQgPSAkbnVsbA0KJHVzZUVtYmVkZGVkID0gJGZhbHNlDQoNCiMgMS4g
>>"%WORKERPS1%.b64" echo VGhlIHB5IGxhdW5jaGVyJ3Mga25vd24tZ29vZCB2ZXJzaW9ucywgbmV3ZXN0IGZpcnN0Lg0KJHB5
>>"%WORKERPS1%.b64" echo TGF1bmNoZXIgPSAkbnVsbA0KdHJ5IHsgJHB5TGF1bmNoZXIgPSAoR2V0LUNvbW1hbmQgcHkgLUVy
>>"%WORKERPS1%.b64" echo cm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUpLlNvdXJjZSB9IGNhdGNoIHsgfQ0KaWYgKCRweUxh
>>"%WORKERPS1%.b64" echo dW5jaGVyKSB7DQogICAgZm9yZWFjaCAoJHYgaW4gQCgnMy4xMycsICczLjEyJywgJzMuMTEnKSkg
>>"%WORKERPS1%.b64" echo ew0KICAgICAgICAkZXhlID0gSW52b2tlLVF1aWV0IHsgJiBweSAiLSR2IiAtYyAiaW1wb3J0IHN5
>>"%WORKERPS1%.b64" echo czsgcHJpbnQoc3lzLmV4ZWN1dGFibGUpIiB9DQogICAgICAgIGlmICgtbm90ICRleGUpIHsgY29u
>>"%WORKERPS1%.b64" echo dGludWUgfQ0KICAgICAgICAkZXhlID0gKFtzdHJpbmddJGV4ZSkuVHJpbSgpDQogICAgICAgIGlm
>>"%WORKERPS1%.b64" echo ICgkZXhlIC1hbmQgKFRlc3QtUGF0aCAtTGl0ZXJhbFBhdGggJGV4ZSkpIHsgJHB5Q21kID0gJGV4
>>"%WORKERPS1%.b64" echo ZTsgYnJlYWsgfQ0KICAgIH0NCn0NCg0KIyAyLiBXaGF0ZXZlciAicHl0aG9uIiByZXNvbHZlcyB0
>>"%WORKERPS1%.b64" echo bywgaWYgaXRzIHZlcnNpb24gaXMgc3VwcG9ydGVkLg0KaWYgKC1ub3QgJHB5Q21kKSB7DQogICAg
>>"%WORKERPS1%.b64" echo JHBsYWluID0gJG51bGwNCiAgICB0cnkgeyAkcGxhaW4gPSAoR2V0LUNvbW1hbmQgcHl0aG9uIC1F
>>"%WORKERPS1%.b64" echo cnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlKS5Tb3VyY2UgfSBjYXRjaCB7IH0NCiAgICBpZiAo
>>"%WORKERPS1%.b64" echo JHBsYWluKSB7DQogICAgICAgICR2ZXIgPSBHZXQtUHlWZXJzaW9uIC1FeGUgJHBsYWluDQogICAg
>>"%WORKERPS1%.b64" echo ICAgIGlmIChUZXN0LVB5U3VwcG9ydGVkIC1WZXJzaW9uICR2ZXIpIHsNCiAgICAgICAgICAgICRw
>>"%WORKERPS1%.b64" echo eUNtZCA9ICRwbGFpbg0KICAgICAgICB9IGVsc2Ugew0KICAgICAgICAgICAgU2F5ICgiUHl0aG9u
>>"%WORKERPS1%.b64" echo IGF0ICRwbGFpbiByZXBvcnRzIHswfS57MX0sIHdoaWNoIGlzIG5ld2VyIHRoYW4gdGhpcyB3b3Jr
>>"%WORKERPS1%.b64" echo ZXIncyB0b29scyBzdXBwb3J0LiIgLWYgW2ludF0oJHZlciAvIDEwMCksICgkdmVyICUgMTAwKSkN
>>"%WORKERPS1%.b64" echo CiAgICAgICAgfQ0KICAgIH0NCn0NCg0KIyAzLiBOb3RoaW5nIHVzYWJsZSBvbiBQQVRIOiBkb3du
>>"%WORKERPS1%.b64" echo bG9hZCB0aGUgZW1iZWRkYWJsZSBidWlsZCBvbmNlLiBJdCBpcyBhIG5vcm1hbA0KIyAgICB6aXAs
>>"%WORKERPS1%.b64" echo IG5lZWRzIG5vIGluc3RhbGxlciwgbm8gYWRtaW4gcmlnaHRzIGFuZCBubyBQQVRIIGNoYW5nZXMg
>>"%WORKERPS1%.b64" echo LSBpdCBsaXZlcyBpbg0KIyAgICB0aGlzIGZvbGRlciBhbmQgaXMgb25seSB1c2VkIGJ5IHRoaXMg
>>"%WORKERPS1%.b64" echo d29ya2VyLg0KaWYgKC1ub3QgJHB5Q21kKSB7DQogICAgJHB5VmVyc2lvbiA9ICczLjEyLjgnDQog
>>"%WORKERPS1%.b64" echo ICAgJGVtYmVkVXJsID0gImh0dHBzOi8vd3d3LnB5dGhvbi5vcmcvZnRwL3B5dGhvbi8kcHlWZXJz
>>"%WORKERPS1%.b64" echo aW9uL3B5dGhvbi0kcHlWZXJzaW9uLWVtYmVkLWFtZDY0LnppcCINCiAgICAkemlwUGF0aCA9IEpv
>>"%WORKERPS1%.b64" echo aW4tUGF0aCAkc2NyaXB0RGlyICdweXRob24tZW1iZWQuemlwJw0KDQogICAgaWYgKC1ub3QgKFRl
>>"%WORKERPS1%.b64" echo c3QtUGF0aCAtTGl0ZXJhbFBhdGggJGVtYmVkZGVkRXhlKSkgew0KICAgICAgICBTYXkgIlB5dGhv
>>"%WORKERPS1%.b64" echo biAkc3VwcG9ydGVkTWluLSRzdXBwb3J0ZWRNYXggbm90IGZvdW5kIG9uIHRoaXMgUEMuIg0KICAg
>>"%WORKERPS1%.b64" echo ICAgICBTYXkgIkRvd25sb2FkaW5nIHBvcnRhYmxlIFB5dGhvbiAkcHlWZXJzaW9uIG9uY2UgKH4x
>>"%WORKERPS1%.b64" echo MSBNQikuLi4iDQogICAgICAgIHRyeSB7DQogICAgICAgICAgICAkY2xpZW50ID0gTmV3LU9iamVj
>>"%WORKERPS1%.b64" echo dCBTeXN0ZW0uTmV0LldlYkNsaWVudA0KICAgICAgICAgICAgJGNsaWVudC5Eb3dubG9hZEZpbGUo
>>"%WORKERPS1%.b64" echo JGVtYmVkVXJsLCAkemlwUGF0aCkNCiAgICAgICAgfSBjYXRjaCB7DQogICAgICAgICAgICB0aHJv
>>"%WORKERPS1%.b64" echo dyAiRmFpbGVkIHRvIGRvd25sb2FkIFB5dGhvbjogJCgkXy5FeGNlcHRpb24uTWVzc2FnZSkiDQog
>>"%WORKERPS1%.b64" echo ICAgICAgIH0NCiAgICAgICAgU2F5ICJFeHRyYWN0aW5nIGVtYmVkZGVkIFB5dGhvbi4uLiINCiAg
>>"%WORKERPS1%.b64" echo ICAgICAgRXhwYW5kLUFyY2hpdmUgLVBhdGggJHppcFBhdGggLURlc3RpbmF0aW9uUGF0aCAkZW1i
>>"%WORKERPS1%.b64" echo ZWRkZWREaXIgLUZvcmNlDQogICAgICAgIFJlbW92ZS1JdGVtIC1MaXRlcmFsUGF0aCAkemlwUGF0
>>"%WORKERPS1%.b64" echo aCAtRm9yY2UgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUNCiAgICB9DQoNCiAgICAjIFRo
>>"%WORKERPS1%.b64" echo ZSBlbWJlZGRhYmxlIGJ1aWxkIHNoaXBzIHdpdGggc2l0ZSBkaXNhYmxlZCBpbiBweXRob25YWS5f
>>"%WORKERPS1%.b64" echo cHRoLCBzbyBhDQogICAgIyBwYWNrYWdlIGluc3RhbGxlZCBuZXh0IHRvIGl0IGNhbm5vdCBiZSBp
>>"%WORKERPS1%.b64" echo bXBvcnRlZCAtIG5vdCBldmVuIHBpcC4gVHVybiBzaXRlDQogICAgIyBvbiBvbmNlIGFuZCBhZGQg
>>"%WORKERPS1%.b64" echo TGliXHNpdGUtcGFja2FnZXMsIHdoaWNoIGlzIHdoZXJlIGdldC1waXAgaW5zdGFsbHMuDQogICAg
>>"%WORKERPS1%.b64" echo JHB0aCA9IEdldC1DaGlsZEl0ZW0gLUxpdGVyYWxQYXRoICRlbWJlZGRlZERpciAtRmlsdGVyICdw
>>"%WORKERPS1%.b64" echo eXRob24qLl9wdGgnIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlIHwgU2VsZWN0LU9iamVj
>>"%WORKERPS1%.b64" echo dCAtRmlyc3QgMQ0KICAgIGlmICgtbm90ICRwdGgpIHsgdGhyb3cgIkVtYmVkZGVkIFB5dGhvbiBp
>>"%WORKERPS1%.b64" echo cyBtaXNzaW5nIGl0cyAuX3B0aCBmaWxlOiAkZW1iZWRkZWREaXIiIH0NCiAgICAkcHRoVGV4dCA9
>>"%WORKERPS1%.b64" echo IFtJTy5GaWxlXTo6UmVhZEFsbFRleHQoJHB0aC5GdWxsTmFtZSkNCiAgICBpZiAoJHB0aFRleHQg
>>"%WORKERPS1%.b64" echo LW5vdG1hdGNoICcoP20pXlxzKmltcG9ydFxzK3NpdGVccyokJykgew0KICAgICAgICAkcHRoVGV4
>>"%WORKERPS1%.b64" echo dCA9ICRwdGhUZXh0IC1yZXBsYWNlICcoP20pXlxzKiNccyppbXBvcnRccytzaXRlXHMqJCcsICdp
>>"%WORKERPS1%.b64" echo bXBvcnQgc2l0ZScNCiAgICAgICAgaWYgKCRwdGhUZXh0IC1ub3RtYXRjaCAnKD9tKV5ccyppbXBv
>>"%WORKERPS1%.b64" echo cnRccytzaXRlXHMqJCcpIHsNCiAgICAgICAgICAgICRwdGhUZXh0ID0gJHB0aFRleHQuVHJpbUVu
>>"%WORKERPS1%.b64" echo ZCgpICsgImByYG5pbXBvcnQgc2l0ZWByYG4iDQogICAgICAgIH0NCiAgICAgICAgaWYgKCRwdGhU
>>"%WORKERPS1%.b64" echo ZXh0IC1ub3RtYXRjaCAnKD9tKV5ccypMaWJcXHNpdGUtcGFja2FnZXNccyokJykgew0KICAgICAg
>>"%WORKERPS1%.b64" echo ICAgICAgJHB0aFRleHQgPSAkcHRoVGV4dC5UcmltRW5kKCkgKyAiYHJgbkxpYlxzaXRlLXBhY2th
>>"%WORKERPS1%.b64" echo Z2VzYHJgbiINCiAgICAgICAgfQ0KICAgICAgICBbSU8uRmlsZV06OldyaXRlQWxsVGV4dCgkcHRo
>>"%WORKERPS1%.b64" echo LkZ1bGxOYW1lLCAkcHRoVGV4dCwgKE5ldy1PYmplY3QgVGV4dC5BU0NJSUVuY29kaW5nKSkNCiAg
>>"%WORKERPS1%.b64" echo ICB9DQoNCiAgICAjIHBpcCBpcyBub3QgcGFydCBvZiB0aGUgZW1iZWRkYWJsZSBidWlsZCBlaXRo
>>"%WORKERPS1%.b64" echo ZXIsIHNvIGJvb3RzdHJhcCBpdCBvbmNlLiBUaGUNCiAgICAjIGNoZWNrIG1ha2VzIGxhdGVyIHJ1
>>"%WORKERPS1%.b64" echo bnMgKGFuZCBhIGhhbGYtZmluaXNoZWQgZWFybGllciBvbmUpIGNoZWFwLg0KICAgIGlmICgoSW52
>>"%WORKERPS1%.b64" echo b2tlLU5hdGl2ZSB7ICYgJGVtYmVkZGVkRXhlIC1jICJpbXBvcnQgcGlwIiB9KSAtbmUgMCkgew0K
>>"%WORKERPS1%.b64" echo ICAgICAgICBpZiAoLW5vdCAoVGVzdC1QYXRoIC1MaXRlcmFsUGF0aCAkZ2V0UGlwU2NyaXB0KSkg
>>"%WORKERPS1%.b64" echo ew0KICAgICAgICAgICAgU2F5ICJEb3dubG9hZGluZyBwaXAgaW5zdGFsbGVyLi4uIg0KICAgICAg
>>"%WORKERPS1%.b64" echo ICAgICAgdHJ5IHsNCiAgICAgICAgICAgICAgICAkY2xpZW50ID0gTmV3LU9iamVjdCBTeXN0ZW0u
>>"%WORKERPS1%.b64" echo TmV0LldlYkNsaWVudA0KICAgICAgICAgICAgICAgICRjbGllbnQuRG93bmxvYWRGaWxlKCdodHRw
>>"%WORKERPS1%.b64" echo czovL2Jvb3RzdHJhcC5weXBhLmlvL2dldC1waXAucHknLCAkZ2V0UGlwU2NyaXB0KQ0KICAgICAg
>>"%WORKERPS1%.b64" echo ICAgICAgfSBjYXRjaCB7DQogICAgICAgICAgICAgICAgdGhyb3cgIkZhaWxlZCB0byBkb3dubG9h
>>"%WORKERPS1%.b64" echo ZCBnZXQtcGlwLnB5OiAkKCRfLkV4Y2VwdGlvbi5NZXNzYWdlKSINCiAgICAgICAgICAgIH0NCiAg
>>"%WORKERPS1%.b64" echo ICAgICAgfQ0KICAgICAgICBTYXkgIkluc3RhbGxpbmcgcGlwIGludG8gZW1iZWRkZWQgUHl0aG9u
>>"%WORKERPS1%.b64" echo Li4uIg0KICAgICAgICAkcmMgPSBJbnZva2UtTmF0aXZlIHsgJiAkZW1iZWRkZWRFeGUgJGdldFBp
>>"%WORKERPS1%.b64" echo cFNjcmlwdCAtLW5vLXdhcm4tc2NyaXB0LWxvY2F0aW9uIH0NCiAgICAgICAgaWYgKCRyYyAtbmUg
>>"%WORKERPS1%.b64" echo MCkgeyB0aHJvdyAicGlwIGluc3RhbGwgaW50byBlbWJlZGRlZCBQeXRob24gZmFpbGVkIChleGl0
>>"%WORKERPS1%.b64" echo ICRyYykiIH0NCiAgICB9DQoNCiAgICAkcHlDbWQgPSAkZW1iZWRkZWRFeGUNCiAgICAkdXNlRW1i
>>"%WORKERPS1%.b64" echo ZWRkZWQgPSAkdHJ1ZQ0KICAgIFNheSAiVXNpbmcgZW1iZWRkZWQgUHl0aG9uOiAkcHlDbWQiDQp9
>>"%WORKERPS1%.b64" echo DQoNClNheSAiVXNpbmcgUHl0aG9uOiAkcHlDbWQiDQoNCmlmICgkdXNlRW1iZWRkZWQpIHsNCiAg
>>"%WORKERPS1%.b64" echo ICAjIFRoZSBlbWJlZGRhYmxlIGJ1aWxkIGhhcyBubyB2ZW52IG1vZHVsZSwgYW5kIHBpcCBpbnN0
>>"%WORKERPS1%.b64" echo YWxscyBpbnRvIHRoYXQgdHJlZQ0KICAgICMgZGlyZWN0bHksIHNvIHRoZXJlIGlzIG5vIHZpcnR1
>>"%WORKERPS1%.b64" echo YWxlbnYgdG8gY3JlYXRlIG9yIHJlcGFpciBoZXJlLg0KICAgICRweXRob25FeGUgPSAkZW1iZWRk
>>"%WORKERPS1%.b64" echo ZWRFeGUNCiAgICBTYXkgIlVzaW5nIHRoZSBlbWJlZGRlZCBQeXRob24gZGlyZWN0bHkgKG5vIHZp
>>"%WORKERPS1%.b64" echo cnR1YWxlbnYpLiINCn0gZWxzZSB7DQogICAgIyBSZWJ1aWxkIHRoZSB2ZW52IHdoZW4gaXQgd2Fz
>>"%WORKERPS1%.b64" echo IG1hZGUgYnkgYW4gdW5zdXBwb3J0ZWQgUHl0aG9uIChhIHByZXZpb3VzDQogICAgIyBmYWlsZWQg
>>"%WORKERPS1%.b64" echo cnVuIGxlYXZlcyBleGFjdGx5IHRoYXQgYmVoaW5kLCBhbmQgcmV1c2luZyBpdCB3b3VsZCBmYWls
>>"%WORKERPS1%.b64" echo IHRoZSBzYW1lDQogICAgIyB3YXkpLg0KICAgICR2ZW52VXNhYmxlID0gJGZhbHNlDQogICAgaWYg
>>"%WORKERPS1%.b64" echo KFRlc3QtUGF0aCAtTGl0ZXJhbFBhdGggJHB5dGhvbkV4ZSkgew0KICAgICAgICAkdmVudlVzYWJs
>>"%WORKERPS1%.b64" echo ZSA9IFRlc3QtUHlTdXBwb3J0ZWQgLVZlcnNpb24gKEdldC1QeVZlcnNpb24gLUV4ZSAkcHl0aG9u
>>"%WORKERPS1%.b64" echo RXhlKQ0KICAgIH0NCiAgICBpZiAoLW5vdCAkdmVudlVzYWJsZSkgew0KICAgICAgICBpZiAoVGVz
>>"%WORKERPS1%.b64" echo dC1QYXRoIC1MaXRlcmFsUGF0aCAkdmVudkRpcikgew0KICAgICAgICAgICAgU2F5ICJSZWJ1aWxk
>>"%WORKERPS1%.b64" echo aW5nIHRoZSB2aXJ0dWFsZW52IHdpdGggYSBzdXBwb3J0ZWQgUHl0aG9uLi4uIg0KICAgICAgICAg
>>"%WORKERPS1%.b64" echo ICAgUmVtb3ZlLUl0ZW0gLUxpdGVyYWxQYXRoICR2ZW52RGlyIC1SZWN1cnNlIC1Gb3JjZSAtRXJy
>>"%WORKERPS1%.b64" echo b3JBY3Rpb24gU2lsZW50bHlDb250aW51ZQ0KICAgICAgICB9IGVsc2Ugew0KICAgICAgICAgICAg
>>"%WORKERPS1%.b64" echo U2F5ICJDcmVhdGluZyB2aXJ0dWFsZW52Li4uIg0KICAgICAgICB9DQogICAgICAgICYgJHB5Q21k
>>"%WORKERPS1%.b64" echo IC1tIHZlbnYgJHZlbnZEaXINCiAgICAgICAgaWYgKCRMQVNURVhJVENPREUgLW5lIDApIHsgdGhy
>>"%WORKERPS1%.b64" echo b3cgInZlbnYgY3JlYXRpb24gZmFpbGVkIiB9DQogICAgfQ0KfQ0KDQojIC0tLS0tLS0tLS0tLS0t
>>"%WORKERPS1%.b64" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>>"%WORKERPS1%.b64" echo LS0tLQ0KIyBJbnN0YWxsIG9ubHkgd2hhdCBpcyBhY3R1YWxseSBtaXNzaW5nLiBUaGlzIHJ1bnMg
>>"%WORKERPS1%.b64" echo b24gZXZlcnkgbGF1bmNoLCBzbyBhIHNlY29uZA0KIyAoYW5kIGh1bmRyZWR0aCkgcnVuIG11c3Qg
>>"%WORKERPS1%.b64" echo c3RhcnQgaW4gc2Vjb25kcy4gSW1wb3J0aW5nIGV2ZXJ5IHJlcXVpcmVkIG1vZHVsZSBhdA0KIyBv
>>"%WORKERPS1%.b64" echo bmNlIGFuc3dlcnMgaXQ6IGEgbm9uLXplcm8gZXhpdCBtZWFucyBhdCBsZWFzdCBvbmUgaXMgYWJz
>>"%WORKERPS1%.b64" echo ZW50IGFuZCB0aGUgd2hlZWxzDQojIG11c3QgYmUgZmV0Y2hlZC4NCmlmICgoSW52b2tlLU5hdGl2
>>"%WORKERPS1%.b64" echo ZSB7ICYgJHB5dGhvbkV4ZSAtYyAiaW1wb3J0IGh0dHB4LCBmYXN0YXBpLCB1dmljb3JuIiB9KSAt
>>"%WORKERPS1%.b64" echo ZXEgMCkgew0KICAgIFNheSAiUHl0aG9uIGRlcGVuZGVuY2llcyBhbHJlYWR5IHByZXNlbnQuIg0K
>>"%WORKERPS1%.b64" echo fSBlbHNlIHsNCiAgICBTYXkgIkluc3RhbGxpbmcgZGVwZW5kZW5jaWVzIChodHRweCwgZmFzdGFw
>>"%WORKERPS1%.b64" echo aSwgdXZpY29ybikuLi4iDQogICAgIyBBIGZhaWxlZCBwaXAgc2VsZi11cGdyYWRlIGlzIG5vdCBm
>>"%WORKERPS1%.b64" echo YXRhbDogdGhlIGluc3RhbGwgYmVsb3cgaXMgd2hhdCBtYXR0ZXJzLg0KICAgIFt2b2lkXShJbnZv
>>"%WORKERPS1%.b64" echo a2UtTmF0aXZlIHsgJiAkcHl0aG9uRXhlIC1tIHBpcCBpbnN0YWxsIC0tZGlzYWJsZS1waXAtdmVy
>>"%WORKERPS1%.b64" echo c2lvbi1jaGVjayAtLXVwZ3JhZGUgcGlwIH0pDQogICAgJHJjID0gSW52b2tlLU5hdGl2ZSB7ICYg
>>"%WORKERPS1%.b64" echo JHB5dGhvbkV4ZSAtbSBwaXAgaW5zdGFsbCAtLWRpc2FibGUtcGlwLXZlcnNpb24tY2hlY2sgImh0
>>"%WORKERPS1%.b64" echo dHB4IiAiZmFzdGFwaSIgInV2aWNvcm5bc3RhbmRhcmRdIiB9DQogICAgaWYgKCRyYyAtbmUgMCkg
>>"%WORKERPS1%.b64" echo eyB0aHJvdyAicGlwIGluc3RhbGwgZmFpbGVkIChleGl0ICRyYykiIH0NCn0NCg0KIyBTdGFydCB3
>>"%WORKERPS1%.b64" echo b3JrZXINCiRlbnY6SU1BR0VfV09SS0VSX1BPUlQgPSAkUG9ydA0KU2F5ICJTdGFydGluZyB1dmlj
>>"%WORKERPS1%.b64" echo b3JuIG9uIGh0dHA6Ly8xMjcuMC4wLjE6JFBvcnQuLi4iDQpTdGFydC1Qcm9jZXNzIC1GaWxlUGF0
>>"%WORKERPS1%.b64" echo aCAkcHl0aG9uRXhlIC1Bcmd1bWVudExpc3QgKCciJyArICR3b3JrZXJQeSArICciJykgLVdpbmRv
>>"%WORKERPS1%.b64" echo d1N0eWxlIEhpZGRlbg0KIyBUaGUgd29ya2VyIG5vdyBydW5zIGluIHRoZSBiYWNrZ3JvdW5kIG9u
>>"%WORKERPS1%.b64" echo IGl0cyBvd24uIFRoaXMgc2V0dXAgd2luZG93IGhhcyBkb25lDQojIGl0cyBqb2IsIHNvIGl0IGNs
>>"%WORKERPS1%.b64" echo b3NlcyBieSBpdHNlbGYgLSB0aGUgcGxheWVyIGtlZXBzIG9ubHkgdGhlIEZJUlNUIHdpbmRvdw0K
>>"%WORKERPS1%.b64" echo IyAoU3RhcnRJbWFnZUdlbmVyYXRvcikgb3Blbi4gQ2xvc2luZyBpdCBkb2VzIG5vdCBzdG9wIHRo
>>"%WORKERPS1%.b64" echo ZSBoaWRkZW4gY2hpbGQ7IHRoZQ0KIyBjbGVhbnVwIHN0ZXAgYXQgdGhlIHRvcCBvZiBldmVyeSBs
>>"%WORKERPS1%.b64" echo YXVuY2ggZG9lcy4NClNheSAiV29ya2VyIGlzIHJ1bm5pbmcgaW4gdGhlIGJhY2tncm91bmQuIFRo
>>"%WORKERPS1%.b64" echo aXMgd2luZG93IHdpbGwgbm93IGNsb3NlLiINCmV4aXQgMA0K
powershell -NoProfile -Command "[IO.File]::WriteAllBytes('%WORKERPS1%', [Convert]::FromBase64String(([IO.File]::ReadAllText('%WORKERPS1%.b64') -replace '\s','')))" >nul 2>&1
del /q "%WORKERPS1%.b64" >nul 2>&1
>"%WORKERPY%.b64" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJMb2NhbCBpbWFnZSB3b3JrZXIgZm9yIGFnZW50IG9m
>>"%WORKERPY%.b64" echo ZmxvYWQuCgpMaXN0ZW5zIG9uIGh0dHA6Ly8xMjcuMC4wLjE6ODAwMiBhbmQgZXhwb3NlczoKLSBQ
>>"%WORKERPY%.b64" echo T1NUIC92MS9pbWFnZXMvZ2VuZXJhdGlvbnMgKE9wZW5BSS1jb21wYXRpYmxlIHNoYXBlKSAtIGRy
>>"%WORKERPY%.b64" echo YXdzIHRocm91Z2ggdGhlCiAgcGxheWVyJ3Mgc2lnbmVkLWluIEdlbWluaSB0YWIgKHZpYSB0aGUg
>>"%WORKERPY%.b64" echo Y2hhdCB3b3JrZXIgb24gODAwMyksIHRoZW4gRHVjay5haSdzCiAgR1BUIEltYWdlIDIsIHRoZW4g
>>"%WORKERPY%.b64" echo UHV0ZXIgd2hlbiBQVVRFUl9BQ0NFU1NfVE9LRU4gaXMgc2V0LiBBbHdheXMgcmV0dXJucwogIGI2
>>"%WORKERPY%.b64" echo NF9qc29uIGFuZCBuYW1lcyB0aGUgbW9kZWwgdGhhdCBhY3R1YWxseSBkcmV3IHRoZSBwaWN0dXJl
>>"%WORKERPY%.b64" echo LiBaLUltYWdlLVR1cmJvCiAgaXMgTk9UIHBhcnQgb2YgdGhpcyBjaGFpbjogdGhlIHNpdGUgZHJh
>>"%WORKERPY%.b64" echo d3MgaXQgaXRzZWxmIGZyb20gaW1hZ2VmcmVlLm5ldCwKICB3aXRoIG5vIGJhdCBmaWxlIGFuZCBu
>>"%WORKERPY%.b64" echo byBicm93c2VyIHRhYi4KLSBQT1NUIC9wcm94eSAtIGdlbmVyaWMgSFRUUCBwcm94eSAoZm9yIHJl
>>"%WORKERPY%.b64" echo bGF5aW5nIFBvbGxpbmF0aW9ucy9Ib3JkZSBjYWxscwogIGZyb20gdGhlIHVzZXIncyBJUCkuCi0g
>>"%WORKERPY%.b64" echo R0VUIC9oZWFsdGh6IC0gaGVhbHRoIGNoZWNrLgoKVGhpcyBydW5zIGVudGlyZWx5IG9uIHRoZSB1
>>"%WORKERPY%.b64" echo c2VyJ3MgbWFjaGluZSB3aGVuIGxhdW5jaGVkIHZpYSB0aGUgYnVuZGxlZApiYXQvcHMxLiBObyBh
>>"%WORKERPY%.b64" echo dXRvbWF0aWMgc3RhcnR1cCBmcm9tIHRoZSBicm93c2VyLgoKV2h5IHBsYWluIEhUVFAgaW5zdGVh
>>"%WORKERPY%.b64" echo ZCBvZiBhIGJyb3dzZXI6IGltYWdlZnJlZS5uZXQncyBnZW5lcmF0b3IgcGFnZSBpcyBhCk5leHQu
>>"%WORKERPY%.b64" echo anMgY2xpZW50IG92ZXIgdHdvIFhIUiBlbmRwb2ludHMsIFBPU1QgL2FwaS9nZW5lcmF0ZSAocmV0
>>"%WORKERPY%.b64" echo dXJucyBhCnRhc2tJZCkgYW5kIEdFVCAvYXBpL2dlbmVyYXRlL3N0YXR1cz90YXNrSWQ9Li4uIChw
>>"%WORKERPY%.b64" echo cm9ncmVzcywgdGhlbiB0aGUgaW1hZ2UKVVJMKS4gVGhvc2UgYXJlIHRoZSBzYW1lIHJlcXVlc3Rz
>>"%WORKERPY%.b64" echo IHRoZSBwYWdlIG1ha2VzLCBzbyBhIHBsYWluIGNsaWVudCBkb2VzCmV4YWN0bHkgd2hhdCB0aGUg
>>"%WORKERPY%.b64" echo YnJvd3NlciBkaWQgLSBidXQgd2l0aG91dCBhIDEtMiBHQiBDYW1vdWZveCBkb3dubG9hZCwgYQp2
>>"%WORKERPY%.b64" echo aXNpYmxlIHdpbmRvdywgZ3Vlc3NlZCBDU1Mgc2VsZWN0b3JzIG9yIHdhaXRpbmcgbWludXRlcyBm
>>"%WORKERPY%.b64" echo b3IgYSBmb3JtIHRoYXQKbmV2ZXIgcHJvZHVjZWQgYSBwaWN0dXJlLiBJbiB0aGUgZGVmYXVsdCBj
>>"%WORKERPY%.b64" echo aGFpbiB0aG9zZSBjYWxscyBhcmUgbm8gbG9uZ2VyCnVzZWQgYXQgYWxsOiBpbWFnZWZyZWUubmV0
>>"%WORKERPY%.b64" echo IGlzIHJlYWNoZWQgYnkgdGhlIFNJVEUgZGlyZWN0bHkuIEFuIGV4cGxpY2l0bHkKcmVxdWVzdGVk
>>"%WORKERPY%.b64" echo ICJpbWFnZWZyZWUiIG1vZGVsIHN0aWxsIHdvcmtzIGhlcmUgZnJvbSB0aGUgcGxheWVyJ3Mgb3du
>>"%WORKERPY%.b64" echo IElQLgoiIiIKZnJvbSBfX2Z1dHVyZV9fIGltcG9ydCBhbm5vdGF0aW9ucwoKaW1wb3J0IGFzeW5j
>>"%WORKERPY%.b64" echo aW8KaW1wb3J0IGJhc2U2NAppbXBvcnQganNvbgppbXBvcnQgbG9nZ2luZwppbXBvcnQgb3MKaW1w
>>"%WORKERPY%.b64" echo b3J0IHJlCmltcG9ydCB0aW1lCmZyb20gdHlwaW5nIGltcG9ydCBBbnksIERpY3QKZnJvbSB1cmxs
>>"%WORKERPY%.b64" echo aWIucGFyc2UgaW1wb3J0IHVybHBhcnNlCgppbXBvcnQgaHR0cHgKZnJvbSBmYXN0YXBpIGltcG9y
>>"%WORKERPY%.b64" echo dCBGYXN0QVBJLCBIVFRQRXhjZXB0aW9uLCBSZXF1ZXN0CmZyb20gZmFzdGFwaS5yZXNwb25zZXMg
>>"%WORKERPY%.b64" echo aW1wb3J0IEpTT05SZXNwb25zZQoKbG9nID0gbG9nZ2luZy5nZXRMb2dnZXIoImxvY2FsLWltYWdl
>>"%WORKERPY%.b64" echo LXdvcmtlciIpCgojIFRoZSB3b3JrZXIgaXMgY29waWVkIG5leHQgdG8gaW1hZ2Utd29ya2VyLnBz
>>"%WORKERPY%.b64" echo MSwgd2hvc2UgbG9nIHRoaXMgc2hhcmVzOgojIHV2aWNvcm4gcnVucyBoaWRkZW4sIHNvIGEgZmls
>>"%WORKERPY%.b64" echo ZSBpcyB0aGUgb25seSBwbGFjZSBhIGZhaWx1cmUgY2FuIGJlIHJlYWQuCl9MT0dfUEFUSCA9IG9z
>>"%WORKERPY%.b64" echo LnBhdGguam9pbihvcy5wYXRoLmRpcm5hbWUob3MucGF0aC5hYnNwYXRoKF9fZmlsZV9fKSksICJp
>>"%WORKERPY%.b64" echo bWFnZS13b3JrZXIubG9nIikKbG9nZ2luZy5iYXNpY0NvbmZpZygKICAgIGxldmVsPWxvZ2dpbmcu
>>"%WORKERPY%.b64" echo SU5GTywKICAgIGZvcm1hdD0iJShhc2N0aW1lKXMgJShsZXZlbG5hbWUpcyAlKG5hbWUpcyAlKG1l
>>"%WORKERPY%.b64" echo c3NhZ2UpcyIsCiAgICBoYW5kbGVycz1bbG9nZ2luZy5GaWxlSGFuZGxlcihfTE9HX1BBVEgsIGVu
>>"%WORKERPY%.b64" echo Y29kaW5nPSJ1dGYtOCIpLCBsb2dnaW5nLlN0cmVhbUhhbmRsZXIoKV0sCikKCmFwcCA9IEZhc3RB
>>"%WORKERPY%.b64" echo UEkodGl0bGU9IkxvY2FsIEltYWdlIFdvcmtlciIsIHZlcnNpb249IjIuMC4wIikKCiMgVGhlIGZy
>>"%WORKERPY%.b64" echo ZWUgaW1hZ2Ugc2VydmljZS4gSGVyZSB0aGUgcmVxdWVzdHMgbGVhdmUgZnJvbSB0aGUgcGxheWVy
>>"%WORKERPY%.b64" echo J3MgbWFjaGluZQojIGluc3RlYWQgb2YgdGhlIHNpdGUncyBzZXJ2ZXIuClVQU1RSRUFNID0gb3Mu
>>"%WORKERPY%.b64" echo Z2V0ZW52KCJJTUFHRV9XT1JLRVJfVVBTVFJFQU0iLCAiaHR0cHM6Ly9pbWFnZWZyZWUubmV0Iiku
>>"%WORKERPY%.b64" echo cnN0cmlwKCIvIikKIyBSZXBvcnRlZCB0byB0aGUgc2l0ZSBzbyB0aGUgYmFja2dyb3VuZCBzdGF0
>>"%WORKERPY%.b64" echo dXMgY2FuIG5hbWUgdGhlIGV4YWN0IHVwc3RyZWFtLgpJTUFHRV9QUk9WSURFUiA9IHVybHBhcnNl
>>"%WORKERPY%.b64" echo KFVQU1RSRUFNKS5ob3N0bmFtZSBvciAiaW1hZ2VmcmVlLm5ldCIKIyBUaGUgY29uY3JldGUgbW9k
>>"%WORKERPY%.b64" echo ZWxzIGJlaGluZCB0aGUgZnJlZSBpbWFnZSBzZXJ2aWNlcywgZm9yIHRoZSBTZXR0aW5ncwojIHN0
>>"%WORKERPY%.b64" echo YXR1cyBsaW5lLiBpbWFnZWZyZWUubmV0J3Mgb3duIHNpdGUgY3JlZGl0cyBaLUltYWdlLVR1cmJv
>>"%WORKERPY%.b64" echo ICg4LXN0ZXAgRGlUKTsKIyBEdWNrLmFpJ3Mgb3duIGVuZ2luZWVyaW5nIHBvZGNhc3QgbmFtZXMg
>>"%WORKERPY%.b64" echo R1BUIEltYWdlIDI7IHRoZSBHZW1pbmkgdGFiIHVzZXMgdGhlCiMgRmxhc2ggd2ViIG1vZGVsIHdp
>>"%WORKERPY%.b64" echo dGggbmF0aXZlIE5hbm8gQmFuYW5hIGltYWdlIGdlbmVyYXRpb24uCklNQUdFX01PREVMID0gb3Mu
>>"%WORKERPY%.b64" echo Z2V0ZW52KCJJTUFHRV9XT1JLRVJfTU9ERUwiLCAiei1pbWFnZS10dXJibyIpCkdFTUlOSV9JTUFH
>>"%WORKERPY%.b64" echo RV9NT0RFTCA9ICJnZW1pbmktZmxhc2gtaW1hZ2UiCkRVQ0tfSU1BR0VfTU9ERUwgPSAiZ3B0LWlt
>>"%WORKERPY%.b64" echo YWdlLTIiCiMgUHV0ZXIncyBicm93c2VyIEFQSSAoL2RyaXZlcnMvY2FsbCkgbmVlZHMgYSBmcmVl
>>"%WORKERPY%.b64" echo IGFjY291bnQgdG9rZW4uIFRoZSBvd25lciBjYW4KIyBwdXQgaXQgaW4gUFVURVJfQUNDRVNTX1RP
>>"%WORKERPY%.b64" echo S0VOIG5leHQgdG8gdGhlIG90aGVyIHdvcmtlciBzZXR0aW5nczsgd2l0aG91dCBpdCB0aGUKIyBQ
>>"%WORKERPY%.b64" echo dXRlciBydW5nIHNpbXBseSByZXBvcnRzICJub3QgY29uZmlndXJlZCIgYW5kIHRoZSBzaXRlIHRy
>>"%WORKERPY%.b64" echo aWVzIGl0cyBvd24gc2VydmVyLgpQVVRFUl9BUEkgPSBvcy5nZXRlbnYoIlBVVEVSX0FQSSIsICJo
>>"%WORKERPY%.b64" echo dHRwczovL2FwaS5wdXRlci5jb20iKS5yc3RyaXAoIi8iKQpQVVRFUl9JTUFHRV9NT0RFTCA9IG9z
>>"%WORKERPY%.b64" echo LmdldGVudigiUFVURVJfSU1BR0VfTU9ERUwiLCAiZ3B0LWltYWdlLTIuNi1mbGFyZSIpClBVVEVS
>>"%WORKERPY%.b64" echo X0lNQUdFX01PREVMX0xBQkVMID0gInB1dGVyIC8gIiArIFBVVEVSX0lNQUdFX01PREVMClBVVEVS
>>"%WORKERPY%.b64" echo X0FDQ0VTU19UT0tFTiA9IG9zLmdldGVudigiUFVURVJfQUNDRVNTX1RPS0VOIiwgIiIpLnN0cmlw
>>"%WORKERPY%.b64" echo KCkKUFVURVJfSU1BR0VfVElNRU9VVCA9IGZsb2F0KG9zLmdldGVudigiUFVURVJfSU1BR0VfVElN
>>"%WORKERPY%.b64" echo RU9VVCIsICI5MCIpKQoKIyBUaGUgc2VydmVyIGdpdmVzIHRoaXMgY2FsbCBCYWNrZ3JvdW5kOklt
>>"%WORKERPY%.b64" echo YWdlQXBpVGltZW91dFNlY29uZHMgKyAxMCAoMTkwcyBieQojIGRlZmF1bHQpLCBzbyBzdG9wIHBv
>>"%WORKERPY%.b64" echo bGxpbmcgYSBsaXR0bGUgYmVmb3JlIHRoYXQ6IGEgY2xlYXIgInRpbWVkIG91dCIgYmVhdHMgdGhl
>>"%WORKERPY%.b64" echo CiMgc2VydmVyIGdpdmluZyB1cCBmaXJzdCBhbmQgcmVwb3J0aW5nIG5vdGhpbmcuClBPTExfVElN
>>"%WORKERPY%.b64" echo RU9VVCA9IGZsb2F0KG9zLmdldGVudigiSU1BR0VfV09SS0VSX1RJTUVPVVQiLCAiMTc1IikpClBP
>>"%WORKERPY%.b64" echo TExfSU5URVJWQUwgPSBmbG9hdChvcy5nZXRlbnYoIklNQUdFX1dPUktFUl9QT0xMX0lOVEVSVkFM
>>"%WORKERPY%.b64" echo IiwgIjMiKSkKCiMgVGhlIGNoYXQgd29ya2VyIG93bnMgdGhlIHBsYXllcidzIEdlbWluaS9EZWVw
>>"%WORKERPY%.b64" echo U2Vlay9BcmVuYS9EdWNrIGJyb3dzZXIKIyBzZXNzaW9ucy4gSW1hZ2UgcmVxdWVzdHMgZm9yIHRo
>>"%WORKERPY%.b64" echo b3NlIHByb3ZpZGVycyBhcmUgZm9yd2FyZGVkIHRvIGl0cyBpbWFnZQojIGVuZHBvaW50LiBBbnl0
>>"%WORKERPY%.b64" echo aGluZyBlbHNlIGtlZXBzIHVzaW5nIGltYWdlZnJlZS5uZXQgZXhhY3RseSBhcyBiZWZvcmUuCkNI
>>"%WORKERPY%.b64" echo QVRfV09SS0VSX1VSTCA9IG9zLmdldGVudigiQ0hBVF9XT1JLRVJfVVJMIiwgImh0dHA6Ly8xMjcu
>>"%WORKERPY%.b64" echo MC4wLjE6ODAwMyIpLnJzdHJpcCgiLyIpCiMgVGhlIHNpdGUgYWxsb3dzIG9uZSBnZW5lcmF0aW9u
>>"%WORKERPY%.b64" echo IH4xOTBzLiBDYXAgZWFjaCBicm93c2VyIGF0dGVtcHQgc28gdHdvIGZhaWxlZAojIGF0dGVtcHRz
>>"%WORKERPY%.b64" echo IHN0aWxsIGxlYXZlIHJvb20gZm9yIHRoZSBzaXRlJ3Mgb3duIFotSW1hZ2UtVHVyYm8gcGF0aC4K
>>"%WORKERPY%.b64" echo R0VNSU5JX0lNQUdFX1RJTUVPVVQgPSBmbG9hdChvcy5nZXRlbnYoIkdFTUlOSV9JTUFHRV9USU1F
>>"%WORKERPY%.b64" echo T1VUIiwgIjUwIikpCkRVQ0tfSU1BR0VfVElNRU9VVCA9IGZsb2F0KG9zLmdldGVudigiRFVDS19J
>>"%WORKERPY%.b64" echo TUFHRV9USU1FT1VUIiwgIjY1IikpCgojIFNhbWUgc2hhcGUgdGhlIHBhZ2Ugc2VuZHM6IGEgc2Ft
>>"%WORKERPY%.b64" echo ZS1vcmlnaW4gZmV0Y2ggd2l0aCBhIGJyb3dzZXIgdXNlciBhZ2VudC4KIyBSZWZlcmVyL09yaWdp
>>"%WORKERPY%.b64" echo biBtYXR0ZXIgdG8gdGhlIHVwc3RyZWFtJ3MgV0FGLCBub3QgdG8gdXMuCl9IRUFERVJTID0gewog
>>"%WORKERPY%.b64" echo ICAgIlVzZXItQWdlbnQiOiAoCiAgICAgICAgIk1vemlsbGEvNS4wIChXaW5kb3dzIE5UIDEwLjA7
>>"%WORKERPY%.b64" echo IFdpbjY0OyB4NjQpIEFwcGxlV2ViS2l0LzUzNy4zNiAiCiAgICAgICAgIihLSFRNTCwgbGlrZSBH
>>"%WORKERPY%.b64" echo ZWNrbykgQ2hyb21lLzEzMS4wLjAuMCBTYWZhcmkvNTM3LjM2IgogICAgKSwKICAgICJBY2NlcHQi
>>"%WORKERPY%.b64" echo OiAiKi8qIiwKICAgICJDb250ZW50LVR5cGUiOiAiYXBwbGljYXRpb24vanNvbiIsCiAgICAiT3Jp
>>"%WORKERPY%.b64" echo Z2luIjogVVBTVFJFQU0sCiAgICAiUmVmZXJlciI6IFVQU1RSRUFNICsgIi8iLAogICAgIkFjY2Vw
>>"%WORKERPY%.b64" echo dC1MYW5ndWFnZSI6ICJlbi1VUyxlbjtxPTAuOSIsCiAgICAiU2VjLUZldGNoLURlc3QiOiAiZW1w
>>"%WORKERPY%.b64" echo dHkiLAogICAgIlNlYy1GZXRjaC1Nb2RlIjogImNvcnMiLAogICAgIlNlYy1GZXRjaC1TaXRlIjog
>>"%WORKERPY%.b64" echo InNhbWUtb3JpZ2luIiwKfQoKX1JBVElPID0gcmUuY29tcGlsZShyIl5cZHsxLDJ9OlxkezEsMn0k
>>"%WORKERPY%.b64" echo IikKCgpkZWYgX2FzcGVjdChib2R5OiBEaWN0W3N0ciwgQW55XSkgLT4gc3RyOgogICAgIiIiVGhl
>>"%WORKERPY%.b64" echo IHJhdGlvIHRoZSBzaXRlIHVuZGVyc3RhbmRzOiBpdHMgb3duIHZhbHVlLCBlbHNlIHRoZSBwYWdl
>>"%WORKERPY%.b64" echo IGRlZmF1bHQuIiIiCiAgICByYXRpbyA9IHN0cihib2R5LmdldCgiYXNwZWN0X3JhdGlvIikgb3Ig
>>"%WORKERPY%.b64" echo IiIpLnN0cmlwKCkKICAgIGlmIF9SQVRJTy5tYXRjaChyYXRpbyk6CiAgICAgICAgcmV0dXJuIHJh
>>"%WORKERPY%.b64" echo dGlvCgogICAgd2lkdGgsIGhlaWdodCA9IGJvZHkuZ2V0KCJ3aWR0aCIpLCBib2R5LmdldCgiaGVp
>>"%WORKERPY%.b64" echo Z2h0IikKICAgIHRyeToKICAgICAgICB3aWR0aCwgaGVpZ2h0ID0gaW50KHdpZHRoKSwgaW50KGhl
>>"%WORKERPY%.b64" echo aWdodCkKICAgICAgICBpZiB3aWR0aCA+IDAgYW5kIGhlaWdodCA+IDA6CiAgICAgICAgICAgIGEs
>>"%WORKERPY%.b64" echo IGIgPSB3aWR0aCwgaGVpZ2h0CiAgICAgICAgICAgIHdoaWxlIGI6CiAgICAgICAgICAgICAgICBh
>>"%WORKERPY%.b64" echo LCBiID0gYiwgYSAlIGIKICAgICAgICAgICAgcmV0dXJuIGYie3dpZHRoIC8vIGF9OntoZWlnaHQg
>>"%WORKERPY%.b64" echo Ly8gYX0iCiAgICBleGNlcHQgKFR5cGVFcnJvciwgVmFsdWVFcnJvcik6CiAgICAgICAgcGFzcwog
>>"%WORKERPY%.b64" echo ICAgcmV0dXJuICIxOjEiCgoKZGVmIF9lcnJvcl9kZXRhaWwoZGF0YTogRGljdFtzdHIsIEFueV0p
>>"%WORKERPY%.b64" echo IC0+IHN0cjoKICAgIG1lc3NhZ2UgPSBkYXRhLmdldCgiZXJyb3IiKQogICAgY29kZSA9IGRhdGEu
>>"%WORKERPY%.b64" echo Z2V0KCJlcnJvckNvZGUiKQogICAgaWYgbWVzc2FnZSBhbmQgY29kZToKICAgICAgICByZXR1cm4g
>>"%WORKERPY%.b64" echo ZiJ7bWVzc2FnZX0gKHtjb2RlfSkiCiAgICByZXR1cm4gc3RyKG1lc3NhZ2Ugb3IgY29kZSBvciAi
>>"%WORKERPY%.b64" echo dGhlIHVwc3RyZWFtIHJlamVjdGVkIHRoZSByZXF1ZXN0IikKCgphc3luYyBkZWYgX3N1Ym1pdChj
>>"%WORKERPY%.b64" echo bGllbnQ6IGh0dHB4LkFzeW5jQ2xpZW50LCBwcm9tcHQ6IHN0ciwgYXNwZWN0OiBzdHIpIC0+IHN0
>>"%WORKERPY%.b64" echo cjoKICAgICIiIkNyZWF0ZXMgdGhlIGdlbmVyYXRpb24gdGFzayBhbmQgcmV0dXJucyBpdHMgaWQu
>>"%WORKERPY%.b64" echo CgogICAgVGhlIGZyZWUgcXVldWUgYWNjZXB0cyBhbiBhbm9ueW1vdXMgcmVxdWVzdCAodHVybnN0
>>"%WORKERPY%.b64" echo aWxlX3Rva2VuIG51bGwpIGV4YWN0bHkKICAgIGFzIHRoZSBwYWdlIHNlbmRzIGl0IGJlZm9yZSBh
>>"%WORKERPY%.b64" echo IGNoYWxsZW5nZSBpcyBzb2x2ZWQuIEEgY2hhbGxlbmdlLCBhIHBlci1JUAogICAgbGltaXQgb3Ig
>>"%WORKERPY%.b64" echo YW55IG90aGVyIHJlZnVzYWwgY29tZXMgYmFjayBhcyB7ImVycm9yIjogLi4ufSBpbiB0aGUgSlNP
>>"%WORKERPY%.b64" echo TiBib2R5LAogICAgd2hpY2ggaXMgcGFzc2VkIG9uIHZlcmJhdGltIHNvIHRoZSBzaXRlIGNhbiBz
>>"%WORKERPY%.b64" echo aG93IHRoZSByZWFsIHJlYXNvbi4KICAgICIiIgogICAgcmVzcG9uc2UgPSBhd2FpdCBjbGllbnQu
>>"%WORKERPY%.b64" echo cG9zdCgKICAgICAgICBmIntVUFNUUkVBTX0vYXBpL2dlbmVyYXRlIiwKICAgICAgICBqc29uPXsi
>>"%WORKERPY%.b64" echo cHJvbXB0IjogcHJvbXB0LCAiYXNwZWN0X3JhdGlvIjogYXNwZWN0LCAidHVybnN0aWxlX3Rva2Vu
>>"%WORKERPY%.b64" echo IjogTm9uZX0sCiAgICAgICAgaGVhZGVycz1fSEVBREVSUywKICAgICkKICAgIHRyeToKICAgICAg
>>"%WORKERPY%.b64" echo ICBkYXRhID0gcmVzcG9uc2UuanNvbigpCiAgICBleGNlcHQgVmFsdWVFcnJvcjoKICAgICAgICBk
>>"%WORKERPY%.b64" echo YXRhID0ge30KCiAgICBpZiByZXNwb25zZS5zdGF0dXNfY29kZSAhPSAyMDAgb3IgZGF0YS5nZXQo
>>"%WORKERPY%.b64" echo ImVycm9yIik6CiAgICAgICAgcmFpc2UgSFRUUEV4Y2VwdGlvbigKICAgICAgICAgICAgc3RhdHVz
>>"%WORKERPY%.b64" echo X2NvZGU9NTAyLAogICAgICAgICAgICBkZXRhaWw9ZiJpbWFnZWZyZWUubmV0IHJlZnVzZWQgdGhl
>>"%WORKERPY%.b64" echo IGpvYjoge19lcnJvcl9kZXRhaWwoZGF0YSkgb3IgJ0hUVFAgJyArIHN0cihyZXNwb25zZS5zdGF0
>>"%WORKERPY%.b64" echo dXNfY29kZSl9IiwKICAgICAgICApCgogICAgdGFza19pZCA9IGRhdGEuZ2V0KCJ0YXNrSWQiKQog
>>"%WORKERPY%.b64" echo ICAgaWYgbm90IHRhc2tfaWQ6CiAgICAgICAgcmFpc2UgSFRUUEV4Y2VwdGlvbihzdGF0dXNfY29k
>>"%WORKERPY%.b64" echo ZT01MDIsIGRldGFpbD0iaW1hZ2VmcmVlLm5ldCByZXR1cm5lZCBubyB0YXNrSWQiKQogICAgbG9n
>>"%WORKERPY%.b64" echo LmluZm8oImdlbmVyYXRpb24gc3VibWl0dGVkOiB0YXNrPSVzIHJhdGlvPSVzIiwgdGFza19pZCwg
>>"%WORKERPY%.b64" echo YXNwZWN0KQogICAgcmV0dXJuIHN0cih0YXNrX2lkKQoKCmFzeW5jIGRlZiBfcG9sbChjbGllbnQ6
>>"%WORKERPY%.b64" echo IGh0dHB4LkFzeW5jQ2xpZW50LCB0YXNrX2lkOiBzdHIsIHRpbWVvdXQ6IGZsb2F0IHwgTm9uZSA9
>>"%WORKERPY%.b64" echo IE5vbmUpIC0+IHN0cjoKICAgICIiIldhaXRzIGZvciB0aGUgdGFzayBhbmQgcmV0dXJucyB0aGUg
>>"%WORKERPY%.b64" echo cGljdHVyZSdzIFVSTC4iIiIKICAgIGxpbWl0ID0gUE9MTF9USU1FT1VUIGlmIHRpbWVvdXQgaXMg
>>"%WORKERPY%.b64" echo Tm9uZSBlbHNlIHRpbWVvdXQKICAgIGRlYWRsaW5lID0gdGltZS5tb25vdG9uaWMoKSArIGxpbWl0
>>"%WORKERPY%.b64" echo CiAgICBsYXN0X3Byb2dyZXNzID0gTm9uZQoKICAgIHdoaWxlIFRydWU6CiAgICAgICAgaWYgdGlt
>>"%WORKERPY%.b64" echo ZS5tb25vdG9uaWMoKSA+IGRlYWRsaW5lOgogICAgICAgICAgICByYWlzZSBIVFRQRXhjZXB0aW9u
>>"%WORKERPY%.b64" echo KAogICAgICAgICAgICAgICAgc3RhdHVzX2NvZGU9NTA0LAogICAgICAgICAgICAgICAgZGV0YWls
>>"%WORKERPY%.b64" echo PWYiaW1hZ2VmcmVlLm5ldCBkaWQgbm90IGZpbmlzaCB3aXRoaW4ge2xpbWl0Oi4wZn1zICh0YXNr
>>"%WORKERPY%.b64" echo IHt0YXNrX2lkfSkiLAogICAgICAgICAgICApCgogICAgICAgIHRyeToKICAgICAgICAgICAgcmVz
>>"%WORKERPY%.b64" echo cG9uc2UgPSBhd2FpdCBjbGllbnQuZ2V0KAogICAgICAgICAgICAgICAgZiJ7VVBTVFJFQU19L2Fw
>>"%WORKERPY%.b64" echo aS9nZW5lcmF0ZS9zdGF0dXMiLAogICAgICAgICAgICAgICAgcGFyYW1zPXsidGFza0lkIjogdGFz
>>"%WORKERPY%.b64" echo a19pZH0sCiAgICAgICAgICAgICAgICBoZWFkZXJzPV9IRUFERVJTLAogICAgICAgICAgICApCiAg
>>"%WORKERPY%.b64" echo ICAgICAgZXhjZXB0IGh0dHB4LlRyYW5zcG9ydEVycm9yIGFzIGV4YzoKICAgICAgICAgICAgIyBB
>>"%WORKERPY%.b64" echo IGJsaXAgd2hpbGUgcG9sbGluZyBpcyBub3QgYSBmYWlsZWQgcGljdHVyZTsgdGhlIGRlYWRsaW5l
>>"%WORKERPY%.b64" echo IGFib3ZlCiAgICAgICAgICAgICMgaXMgd2hhdCBlbmRzIGFuIHVucmVhY2hhYmxlIHVwc3RyZWFt
>>"%WORKERPY%.b64" echo LgogICAgICAgICAgICBsb2cud2FybmluZygic3RhdHVzIHJlcXVlc3QgZmFpbGVkIGZvciB0YXNr
>>"%WORKERPY%.b64" echo ICVzOiAlcyIsIHRhc2tfaWQsIGV4YykKICAgICAgICAgICAgYXdhaXQgYXN5bmNpby5zbGVlcChQ
>>"%WORKERPY%.b64" echo T0xMX0lOVEVSVkFMKQogICAgICAgICAgICBjb250aW51ZQoKICAgICAgICBpZiByZXNwb25zZS5z
>>"%WORKERPY%.b64" echo dGF0dXNfY29kZSA+PSA0MDA6CiAgICAgICAgICAgIHJhaXNlIEhUVFBFeGNlcHRpb24oCiAgICAg
>>"%WORKERPY%.b64" echo ICAgICAgICAgICBzdGF0dXNfY29kZT01MDIsCiAgICAgICAgICAgICAgICBkZXRhaWw9ZiJpbWFn
>>"%WORKERPY%.b64" echo ZWZyZWUubmV0IHN0YXR1cyBjaGVjayBmYWlsZWQ6IEhUVFAge3Jlc3BvbnNlLnN0YXR1c19jb2Rl
>>"%WORKERPY%.b64" echo fSIsCiAgICAgICAgICAgICkKCiAgICAgICAgdHJ5OgogICAgICAgICAgICBkYXRhID0gcmVzcG9u
>>"%WORKERPY%.b64" echo c2UuanNvbigpCiAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgIGRhdGEgPSB7
>>"%WORKERPY%.b64" echo fQoKICAgICAgICBpZiBkYXRhLmdldCgiZXJyb3IiKToKICAgICAgICAgICAgcmFpc2UgSFRUUEV4
>>"%WORKERPY%.b64" echo Y2VwdGlvbigKICAgICAgICAgICAgICAgIHN0YXR1c19jb2RlPTUwMiwKICAgICAgICAgICAgICAg
>>"%WORKERPY%.b64" echo IGRldGFpbD1mImltYWdlZnJlZS5uZXQgcmVwb3J0ZWQgYW4gZXJyb3I6IHtfZXJyb3JfZGV0YWls
>>"%WORKERPY%.b64" echo KGRhdGEpfSIsCiAgICAgICAgICAgICkKCiAgICAgICAgc3RhdHVzID0gZGF0YS5nZXQoInN0YXR1
>>"%WORKERPY%.b64" echo cyIpCiAgICAgICAgcHJvZ3Jlc3MgPSBkYXRhLmdldCgicHJvZ3Jlc3MiKQogICAgICAgIGlmIHBy
>>"%WORKERPY%.b64" echo b2dyZXNzICE9IGxhc3RfcHJvZ3Jlc3M6CiAgICAgICAgICAgIGxvZy5pbmZvKCJ0YXNrICVzOiAl
>>"%WORKERPY%.b64" echo cyAlcyUlIiwgdGFza19pZCwgc3RhdHVzLCBwcm9ncmVzcykKICAgICAgICAgICAgbGFzdF9wcm9n
>>"%WORKERPY%.b64" echo cmVzcyA9IHByb2dyZXNzCgogICAgICAgIGlmIHN0YXR1cyA9PSAiY29tcGxldGVkIjoKICAgICAg
>>"%WORKERPY%.b64" echo ICAgICAgaW1hZ2UgPSBkYXRhLmdldCgiaW1hZ2UiKQogICAgICAgICAgICBpZiBub3QgaW1hZ2U6
>>"%WORKERPY%.b64" echo CiAgICAgICAgICAgICAgICByYWlzZSBIVFRQRXhjZXB0aW9uKHN0YXR1c19jb2RlPTUwMiwgZGV0
>>"%WORKERPY%.b64" echo YWlsPSJpbWFnZWZyZWUubmV0IGZpbmlzaGVkIHdpdGhvdXQgYW4gaW1hZ2UgVVJMIikKICAgICAg
>>"%WORKERPY%.b64" echo ICAgICAgcmV0dXJuIHN0cihpbWFnZSkKCiAgICAgICAgaWYgc3RhdHVzIGluICgiZXJyb3IiLCAi
>>"%WORKERPY%.b64" echo ZmFpbGVkIik6CiAgICAgICAgICAgIHJhaXNlIEhUVFBFeGNlcHRpb24oCiAgICAgICAgICAgICAg
>>"%WORKERPY%.b64" echo ICBzdGF0dXNfY29kZT01MDIsCiAgICAgICAgICAgICAgICBkZXRhaWw9ZiJpbWFnZWZyZWUubmV0
>>"%WORKERPY%.b64" echo IGZhaWxlZCB0byBkcmF3IHRoZSBwaWN0dXJlOiB7X2Vycm9yX2RldGFpbChkYXRhKX0iLAogICAg
>>"%WORKERPY%.b64" echo ICAgICAgICApCgogICAgICAgIGF3YWl0IGFzeW5jaW8uc2xlZXAoUE9MTF9JTlRFUlZBTCkKCgph
>>"%WORKERPY%.b64" echo c3luYyBkZWYgX2dlbmVyYXRlKHByb21wdDogc3RyLCBhc3BlY3Q6IHN0ciwgcG9sbF90aW1lb3V0
>>"%WORKERPY%.b64" echo OiBmbG9hdCB8IE5vbmUgPSBOb25lKSAtPiBEaWN0W3N0ciwgQW55XToKICAgICMgVGhlIHBpY3R1
>>"%WORKERPY%.b64" echo cmUgaXRzZWxmIGlzIGEgZmV3IGh1bmRyZWQgS0IgdG8gYSBjb3VwbGUgb2YgTUI6IGdpdmUgdGhl
>>"%WORKERPY%.b64" echo CiAgICAjIGRvd25sb2FkIGl0cyBvd24gZ2VuZXJvdXMgcmVhZCB0aW1lb3V0LgogICAgdGltZW91
>>"%WORKERPY%.b64" echo dCA9IGh0dHB4LlRpbWVvdXQoMzAuMCwgcmVhZD0xMjAuMCwgY29ubmVjdD0yMC4wKQogICAgYXN5
>>"%WORKERPY%.b64" echo bmMgd2l0aCBodHRweC5Bc3luY0NsaWVudCh0aW1lb3V0PXRpbWVvdXQsIGZvbGxvd19yZWRpcmVj
>>"%WORKERPY%.b64" echo dHM9VHJ1ZSkgYXMgY2xpZW50OgogICAgICAgIHRhc2tfaWQgPSBhd2FpdCBfc3VibWl0KGNsaWVu
>>"%WORKERPY%.b64" echo dCwgcHJvbXB0LCBhc3BlY3QpCiAgICAgICAgaW1hZ2VfdXJsID0gYXdhaXQgX3BvbGwoY2xpZW50
>>"%WORKERPY%.b64" echo LCB0YXNrX2lkLCBwb2xsX3RpbWVvdXQpCgogICAgICAgICMgRG93bmxvYWQgaGVyZSwgb24gdGhp
>>"%WORKERPY%.b64" echo cyBtYWNoaW5lLCBhbmQgaGFuZCB0aGUgYnl0ZXMgYmFjayBhcyBiYXNlNjQ6CiAgICAgICAgIyB0
>>"%WORKERPY%.b64" echo aGUgc2VydmVyIHRoYXQgYXNrZWQgZm9yIHRoZSBwaWN0dXJlIG5ldmVyIGhhcyB0byByZWFjaAog
>>"%WORKERPY%.b64" echo ICAgICAgICMgaW1hZ2VmcmVlLm5ldCAob3IgaXRzIENETikgaXRzZWxmLgogICAgICAgIHJlc3Bv
>>"%WORKERPY%.b64" echo bnNlID0gYXdhaXQgY2xpZW50LmdldChpbWFnZV91cmwpCiAgICAgICAgcmVzcG9uc2UucmFpc2Vf
>>"%WORKERPY%.b64" echo Zm9yX3N0YXR1cygpCiAgICAgICAgcmF3ID0gcmVzcG9uc2UuY29udGVudAogICAgICAgIG1pbWUg
>>"%WORKERPY%.b64" echo PSAocmVzcG9uc2UuaGVhZGVycy5nZXQoImNvbnRlbnQtdHlwZSIpIG9yICJpbWFnZS9wbmciKS5z
>>"%WORKERPY%.b64" echo cGxpdCgiOyIpWzBdLnN0cmlwKCkKICAgICAgICBpZiBub3QgbWltZS5zdGFydHN3aXRoKCJpbWFn
>>"%WORKERPY%.b64" echo ZS8iKToKICAgICAgICAgICAgbWltZSA9ICJpbWFnZS9wbmciCgogICAgbG9nLmluZm8oInRhc2sg
>>"%WORKERPY%.b64" echo JXM6ICVkIGJ5dGVzIG9mICVzIiwgdGFza19pZCwgbGVuKHJhdyksIG1pbWUpCiAgICByZXR1cm4g
>>"%WORKERPY%.b64" echo X3dpdGhfcHJvdmlkZXIoewogICAgICAgICJjcmVhdGVkIjogaW50KHRpbWUudGltZSgpKSwKICAg
>>"%WORKERPY%.b64" echo ICAgICAiZGF0YSI6IFsKICAgICAgICAgICAgewogICAgICAgICAgICAgICAgImI2NF9qc29uIjog
>>"%WORKERPY%.b64" echo YmFzZTY0LmI2NGVuY29kZShyYXcpLmRlY29kZSgiYXNjaWkiKSwKICAgICAgICAgICAgICAgICJt
>>"%WORKERPY%.b64" echo aW1lX3R5cGUiOiBtaW1lLAogICAgICAgICAgICB9CiAgICAgICAgXSwKICAgIH0sIElNQUdFX1BS
>>"%WORKERPY%.b64" echo T1ZJREVSLCBJTUFHRV9NT0RFTCkKCgpkZWYgX3NpdGVfaGVhZGVycyhvcmlnaW46IHN0ciwgY29u
>>"%WORKERPY%.b64" echo dGVudF90eXBlOiBzdHIgfCBOb25lID0gTm9uZSkgLT4gRGljdFtzdHIsIHN0cl06CiAgICAiIiJU
>>"%WORKERPY%.b64" echo aGUgc2FtZS1vcmlnaW4gZmV0Y2ggaGVhZGVycyBQdXRlci5qcyBzZW5kcyBmcm9tIHB1dGVyLmNv
>>"%WORKERPY%.b64" echo bS4iIiIKICAgIHJvb3QgPSBvcmlnaW4ucnN0cmlwKCIvIikKICAgIGhlYWRlcnMgPSBkaWN0KF9I
>>"%WORKERPY%.b64" echo RUFERVJTKQogICAgaGVhZGVyc1siT3JpZ2luIl0gPSByb290CiAgICBoZWFkZXJzWyJSZWZlcmVy
>>"%WORKERPY%.b64" echo Il0gPSByb290ICsgIi8iCiAgICBpZiBjb250ZW50X3R5cGUgaXMgTm9uZToKICAgICAgICBoZWFk
>>"%WORKERPY%.b64" echo ZXJzLnBvcCgiQ29udGVudC1UeXBlIiwgTm9uZSkKICAgIGVsc2U6CiAgICAgICAgaGVhZGVyc1si
>>"%WORKERPY%.b64" echo Q29udGVudC1UeXBlIl0gPSBjb250ZW50X3R5cGUKICAgIHJldHVybiBoZWFkZXJzCgoKZGVmIF9m
>>"%WORKERPY%.b64" echo aW5kX21lZGlhKG5vZGU6IEFueSkgLT4gQW55OgogICAgIiIiRmluZCBhbiBpbWFnZSBVUkwgLyBk
>>"%WORKERPY%.b64" echo YXRhIFVSSSAvIGJhc2U2NCBibG9iIGluIFB1dGVyJ3MgYW5zd2VyIHNoYXBlcy4iIiIKICAgIGlm
>>"%WORKERPY%.b64" echo IGlzaW5zdGFuY2Uobm9kZSwgZGljdCk6CiAgICAgICAgZm9yIGtleSBpbiAoImltYWdlX3VybCIs
>>"%WORKERPY%.b64" echo ICJhc3NldF91cmwiLCAiYjY0X2pzb24iLCAiYmFzZTY0IiwgInVybCIsICJocmVmIiwgImltYWdl
>>"%WORKERPY%.b64" echo IiwgInJlc3VsdCIsICJvdXRwdXQiLCAiZGF0YSIpOgogICAgICAgICAgICBpZiBrZXkgbm90IGlu
>>"%WORKERPY%.b64" echo IG5vZGU6CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICB2YWx1ZSA9IG5vZGVb
>>"%WORKERPY%.b64" echo a2V5XQogICAgICAgICAgICBpZiBpc2luc3RhbmNlKHZhbHVlLCBzdHIpIGFuZCAoCiAgICAgICAg
>>"%WORKERPY%.b64" echo ICAgICAgICB2YWx1ZS5zdGFydHN3aXRoKCJodHRwOi8vIikgb3IgdmFsdWUuc3RhcnRzd2l0aCgi
>>"%WORKERPY%.b64" echo aHR0cHM6Ly8iKQogICAgICAgICAgICAgICAgb3IgdmFsdWUuc3RhcnRzd2l0aCgiZGF0YTppbWFn
>>"%WORKERPY%.b64" echo ZS8iKSBvciBsZW4odmFsdWUpID4gNTEyCiAgICAgICAgICAgICk6CiAgICAgICAgICAgICAgICBy
>>"%WORKERPY%.b64" echo ZXR1cm4gdmFsdWUKICAgICAgICAgICAgaWYgaXNpbnN0YW5jZSh2YWx1ZSwgKGRpY3QsIGxpc3Qp
>>"%WORKERPY%.b64" echo KToKICAgICAgICAgICAgICAgIGZvdW5kID0gX2ZpbmRfbWVkaWEodmFsdWUpCiAgICAgICAgICAg
>>"%WORKERPY%.b64" echo ICAgICBpZiBmb3VuZCBpcyBub3QgTm9uZToKICAgICAgICAgICAgICAgICAgICByZXR1cm4gZm91
>>"%WORKERPY%.b64" echo bmQKICAgICAgICBmb3IgdmFsdWUgaW4gbm9kZS52YWx1ZXMoKToKICAgICAgICAgICAgaWYgaXNp
>>"%WORKERPY%.b64" echo bnN0YW5jZSh2YWx1ZSwgKGRpY3QsIGxpc3QpKToKICAgICAgICAgICAgICAgIGZvdW5kID0gX2Zp
>>"%WORKERPY%.b64" echo bmRfbWVkaWEodmFsdWUpCiAgICAgICAgICAgICAgICBpZiBmb3VuZCBpcyBub3QgTm9uZToKICAg
>>"%WORKERPY%.b64" echo ICAgICAgICAgICAgICAgICByZXR1cm4gZm91bmQKICAgIGVsaWYgaXNpbnN0YW5jZShub2RlLCBs
>>"%WORKERPY%.b64" echo aXN0KToKICAgICAgICBmb3IgdmFsdWUgaW4gbm9kZToKICAgICAgICAgICAgZm91bmQgPSBfZmlu
>>"%WORKERPY%.b64" echo ZF9tZWRpYSh2YWx1ZSkKICAgICAgICAgICAgaWYgZm91bmQgaXMgbm90IE5vbmU6CiAgICAgICAg
>>"%WORKERPY%.b64" echo ICAgICAgICByZXR1cm4gZm91bmQKICAgIGVsaWYgaXNpbnN0YW5jZShub2RlLCBzdHIpIGFuZCBs
>>"%WORKERPY%.b64" echo ZW4obm9kZSkgPiA1MTIgYW5kIG5vdCBub2RlLnN0YXJ0c3dpdGgoInsiKToKICAgICAgICByZXR1
>>"%WORKERPY%.b64" echo cm4gbm9kZQogICAgcmV0dXJuIE5vbmUKCgphc3luYyBkZWYgX2RlY29kZV9tZWRpYShjbGllbnQ6
>>"%WORKERPY%.b64" echo IGh0dHB4LkFzeW5jQ2xpZW50LCBtZWRpYTogc3RyKSAtPiB0dXBsZVtieXRlcywgc3RyXToKICAg
>>"%WORKERPY%.b64" echo IGlmIG1lZGlhLnN0YXJ0c3dpdGgoImRhdGE6aW1hZ2UvIik6CiAgICAgICAgaGVhZCwgXywgcGF5
>>"%WORKERPY%.b64" echo bG9hZCA9IG1lZGlhLnBhcnRpdGlvbigiLCIpCiAgICAgICAgbWltZSA9IGhlYWRbNTpdLnNwbGl0
>>"%WORKERPY%.b64" echo KCI7IilbMF0gb3IgImltYWdlL3BuZyIKICAgICAgICBpZiAiO2Jhc2U2NCIgaW4gaGVhZDoKICAg
>>"%WORKERPY%.b64" echo ICAgICAgICAgcmV0dXJuIGJhc2U2NC5iNjRkZWNvZGUocGF5bG9hZCksIG1pbWUKICAgICAgICBy
>>"%WORKERPY%.b64" echo ZXR1cm4gcGF5bG9hZC5lbmNvZGUoInV0Zi04IiksIG1pbWUKICAgIGlmIG1lZGlhLnN0YXJ0c3dp
>>"%WORKERPY%.b64" echo dGgoImh0dHA6Ly8iKSBvciBtZWRpYS5zdGFydHN3aXRoKCJodHRwczovLyIpOgogICAgICAgIHJl
>>"%WORKERPY%.b64" echo c3BvbnNlID0gYXdhaXQgY2xpZW50LmdldChtZWRpYSwgaGVhZGVycz1fc2l0ZV9oZWFkZXJzKCJo
>>"%WORKERPY%.b64" echo dHRwczovL3B1dGVyLmNvbSIpKQogICAgICAgIHJlc3BvbnNlLnJhaXNlX2Zvcl9zdGF0dXMoKQog
>>"%WORKERPY%.b64" echo ICAgICAgIHJhdyA9IHJlc3BvbnNlLmNvbnRlbnQKICAgICAgICBtaW1lID0gKHJlc3BvbnNlLmhl
>>"%WORKERPY%.b64" echo YWRlcnMuZ2V0KCJjb250ZW50LXR5cGUiKSBvciAiaW1hZ2UvcG5nIikuc3BsaXQoIjsiKVswXS5z
>>"%WORKERPY%.b64" echo dHJpcCgpCiAgICAgICAgcmV0dXJuIHJhdywgbWltZSBpZiBtaW1lLnN0YXJ0c3dpdGgoImltYWdl
>>"%WORKERPY%.b64" echo LyIpIGVsc2UgImltYWdlL3BuZyIKICAgIHJldHVybiBiYXNlNjQuYjY0ZGVjb2RlKG1lZGlhKSwg
>>"%WORKERPY%.b64" echo ImltYWdlL3BuZyIKCgphc3luYyBkZWYgX3B1dGVyX2ltYWdlKHByb21wdDogc3RyLCBhc3BlY3Q6
>>"%WORKERPY%.b64" echo IHN0ciwgdGltZW91dDogZmxvYXQpIC0+IERpY3Rbc3RyLCBBbnldOgogICAgIiIiRHJhdyB3aXRo
>>"%WORKERPY%.b64" echo IFBVVEVSX0FDQ0VTU19UT0tFTiB0aHJvdWdoIFB1dGVyJ3Mgb3duIGJyb3dzZXItY2FsbCBBUEku
>>"%WORKERPY%.b64" echo IiIiCiAgICBpZiBub3QgUFVURVJfQUNDRVNTX1RPS0VOOgogICAgICAgIHJhaXNlIFJ1bnRpbWVF
>>"%WORKERPY%.b64" echo cnJvcigKICAgICAgICAgICAgInB1dGVyOiBzZXQgUFVURVJfQUNDRVNTX1RPS0VOIGluIHRoZSBi
>>"%WORKERPY%.b64" echo YXQgc2V0dGluZ3MgdG8gdXNlIHRoaXMgbW9kZWwgIgogICAgICAgICAgICAiKGEgZnJlZSBQdXRl
>>"%WORKERPY%.b64" echo ciBhY2NvdW50IGlzIGVub3VnaCkiCiAgICAgICAgKQogICAgYm9keSA9IHsKICAgICAgICAiYXV0
>>"%WORKERPY%.b64" echo aF90b2tlbiI6IFBVVEVSX0FDQ0VTU19UT0tFTiwKICAgICAgICAiaW50ZXJmYWNlIjogInB1dGVy
>>"%WORKERPY%.b64" echo LWltYWdlLWdlbmVyYXRpb24iLAogICAgICAgICJkcml2ZXIiOiAiYWktaW1hZ2UiLAogICAgICAg
>>"%WORKERPY%.b64" echo ICJtZXRob2QiOiAiZ2VuZXJhdGUiLAogICAgICAgICJ0ZXN0X21vZGUiOiBGYWxzZSwKICAgICAg
>>"%WORKERPY%.b64" echo ICAiYXJncyI6IHsicHJvbXB0IjogcHJvbXB0LCAibW9kZWwiOiBQVVRFUl9JTUFHRV9NT0RFTCwg
>>"%WORKERPY%.b64" echo ImFzcGVjdF9yYXRpbyI6IGFzcGVjdH0sCiAgICB9CiAgICBjbGllbnRfdGltZW91dCA9IGh0dHB4
>>"%WORKERPY%.b64" echo LlRpbWVvdXQoMzAuMCwgcmVhZD10aW1lb3V0LCBjb25uZWN0PTIwLjApCiAgICBhc3luYyB3aXRo
>>"%WORKERPY%.b64" echo IGh0dHB4LkFzeW5jQ2xpZW50KHRpbWVvdXQ9Y2xpZW50X3RpbWVvdXQsIGZvbGxvd19yZWRpcmVj
>>"%WORKERPY%.b64" echo dHM9VHJ1ZSkgYXMgY2xpZW50OgogICAgICAgIHJlc3BvbnNlID0gYXdhaXQgY2xpZW50LnBvc3Qo
>>"%WORKERPY%.b64" echo CiAgICAgICAgICAgIFBVVEVSX0FQSSArICIvZHJpdmVycy9jYWxsIiwKICAgICAgICAgICAgY29u
>>"%WORKERPY%.b64" echo dGVudD1qc29uLmR1bXBzKGJvZHkpLAogICAgICAgICAgICBoZWFkZXJzPV9zaXRlX2hlYWRlcnMo
>>"%WORKERPY%.b64" echo Imh0dHBzOi8vcHV0ZXIuY29tIiwgInRleHQvcGxhaW47YWN0dWFsbHk9anNvbiIpLAogICAgICAg
>>"%WORKERPY%.b64" echo ICkKICAgICAgICB0cnk6CiAgICAgICAgICAgIGRhdGEgPSByZXNwb25zZS5qc29uKCkKICAgICAg
>>"%WORKERPY%.b64" echo ICBleGNlcHQgVmFsdWVFcnJvcjoKICAgICAgICAgICAgZGF0YSA9IHt9CiAgICAgICAgaWYgcmVz
>>"%WORKERPY%.b64" echo cG9uc2Uuc3RhdHVzX2NvZGUgPj0gNDAwIG9yIChpc2luc3RhbmNlKGRhdGEsIGRpY3QpIGFuZCBk
>>"%WORKERPY%.b64" echo YXRhLmdldCgic3VjY2VzcyIpIGlzIEZhbHNlKToKICAgICAgICAgICAgcmFpc2UgUnVudGltZUVy
>>"%WORKERPY%.b64" echo cm9yKGYicHV0ZXIgcmVmdXNlZCB0aGUgam9iOiBIVFRQIHtyZXNwb25zZS5zdGF0dXNfY29kZX0g
>>"%WORKERPY%.b64" echo e3N0cihkYXRhKVs6MjAwXX0iKQogICAgICAgIG1lZGlhID0gX2ZpbmRfbWVkaWEoZGF0YS5nZXQo
>>"%WORKERPY%.b64" echo InJlc3VsdCIpIGlmIGlzaW5zdGFuY2UoZGF0YSwgZGljdCkgYW5kICJyZXN1bHQiIGluIGRhdGEg
>>"%WORKERPY%.b64" echo ZWxzZSBkYXRhKQogICAgICAgIGlmIG5vdCBtZWRpYToKICAgICAgICAgICAgcmFpc2UgUnVudGlt
>>"%WORKERPY%.b64" echo ZUVycm9yKCJwdXRlciByZXR1cm5lZCBubyBpbWFnZTogIiArIHN0cihkYXRhKVs6MjAwXSkKICAg
>>"%WORKERPY%.b64" echo ICAgICByYXcsIG1pbWUgPSBhd2FpdCBfZGVjb2RlX21lZGlhKGNsaWVudCwgc3RyKG1lZGlhKSkK
>>"%WORKERPY%.b64" echo ICAgIGxvZy5pbmZvKCJwdXRlciBnZW5lcmF0ZWQgJWQgYnl0ZXMgb2YgJXMiLCBsZW4ocmF3KSwg
>>"%WORKERPY%.b64" echo bWltZSkKICAgIHJldHVybiBfd2l0aF9wcm92aWRlcih7CiAgICAgICAgImNyZWF0ZWQiOiBpbnQo
>>"%WORKERPY%.b64" echo dGltZS50aW1lKCkpLAogICAgICAgICJkYXRhIjogW3siYjY0X2pzb24iOiBiYXNlNjQuYjY0ZW5j
>>"%WORKERPY%.b64" echo b2RlKHJhdykuZGVjb2RlKCJhc2NpaSIpLCAibWltZV90eXBlIjogbWltZX1dLAogICAgfSwgInB1
>>"%WORKERPY%.b64" echo dGVyIiwgUFVURVJfSU1BR0VfTU9ERUxfTEFCRUwpCgoKZGVmIF93aXRoX3Byb3ZpZGVyKHJlc3Vs
>>"%WORKERPY%.b64" echo dDogRGljdFtzdHIsIEFueV0sIHByb3ZpZGVyOiBzdHIsIG1vZGVsOiBzdHIpIC0+IERpY3Rbc3Ry
>>"%WORKERPY%.b64" echo LCBBbnldOgogICAgIiIiVGFnIHRoZSBhbnN3ZXIgd2l0aCB0aGUgdXBzdHJlYW0gQU5EIG1vZGVs
>>"%WORKERPY%.b64" echo IHRoYXQgYWN0dWFsbHkgZHJldyBpdC4KCiAgICBUaGUgc2l0ZSBzdG9yZXMgYm90aCBuZXh0IHRv
>>"%WORKERPY%.b64" echo IHRoZSBiYWNrZ3JvdW5kIHNvIFNldHRpbmdzIGNhbiBzYXkKICAgICJGcmVlIEFJIChHZW1pbmkg
>>"%WORKERPY%.b64" echo Rmxhc2ggaW1hZ2UpIiAvICJGcmVlIEFJIChpbWFnZWZyZWUubmV0IC8gWi1JbWFnZS1UdXJibyki
>>"%WORKERPY%.b64" echo CiAgICBpbnN0ZWFkIG9mIG9uZSBnZW5lcmljIGxhYmVsLiBBbiBvbGRlciB3b3JrZXIgb21pdHMg
>>"%WORKERPY%.b64" echo dGhlIGZpZWxkczsgdGhlIHNpdGUKICAgIHRoZW4gc2F5cyB0aGUgc291cmNlIGlzIHVua25vd24g
>>"%WORKERPY%.b64" echo YW5kIGFza3MgdGhlIHBsYXllciB0byB1cGRhdGUgdGhlIGZpbGUuCiAgICAiIiIKICAgIG91dCA9
>>"%WORKERPY%.b64" echo IGRpY3QocmVzdWx0KSBpZiBpc2luc3RhbmNlKHJlc3VsdCwgZGljdCkgZWxzZSB7fQogICAgb3V0
>>"%WORKERPY%.b64" echo WyJwcm92aWRlciJdID0gcHJvdmlkZXIKICAgIG91dFsibW9kZWwiXSA9IG1vZGVsCiAgICByZXR1
>>"%WORKERPY%.b64" echo cm4gb3V0CgoKYXN5bmMgZGVmIF9jaGF0X2ltYWdlKHByb3ZpZGVyOiBzdHIsIHByb21wdDogc3Ry
>>"%WORKERPY%.b64" echo LCB0aW1lb3V0OiBmbG9hdCkgLT4gRGljdFtzdHIsIEFueV06CiAgICAiIiJGb3J3YXJkIGFuIGlt
>>"%WORKERPY%.b64" echo YWdlIHJlcXVlc3QgdG8gdGhlIGJyb3dzZXItc2Vzc2lvbiB3b3JrZXIgb24gcG9ydCA4MDAzLiIi
>>"%WORKERPY%.b64" echo IgogICAgbW9kZWwgPSAiZ2VtaW5pLWltYWdlIiBpZiBwcm92aWRlciA9PSAiZ2VtaW5pIiBlbHNl
>>"%WORKERPY%.b64" echo ICJkdWNrYWktaW1hZ2UiCiAgICB0cnk6CiAgICAgICAgYXN5bmMgd2l0aCBodHRweC5Bc3luY0Ns
>>"%WORKERPY%.b64" echo aWVudCh0aW1lb3V0PXRpbWVvdXQpIGFzIGNsaWVudDoKICAgICAgICAgICAgcmVzcG9uc2UgPSBh
>>"%WORKERPY%.b64" echo d2FpdCBjbGllbnQucG9zdCgKICAgICAgICAgICAgICAgIGYie0NIQVRfV09SS0VSX1VSTH0vdjEv
>>"%WORKERPY%.b64" echo aW1hZ2VzL2dlbmVyYXRpb25zIiwKICAgICAgICAgICAgICAgIGpzb249eyJtb2RlbCI6IG1vZGVs
>>"%WORKERPY%.b64" echo LCAicHJvbXB0IjogcHJvbXB0fSwKICAgICAgICAgICAgKQogICAgZXhjZXB0IGh0dHB4LlRyYW5z
>>"%WORKERPY%.b64" echo cG9ydEVycm9yIGFzIGV4YzoKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoZiJjaGF0IHdvcmtl
>>"%WORKERPY%.b64" echo ciBvbiBwb3J0IDgwMDMgaXMgbm90IHJlYWNoYWJsZToge2V4Y30iKSBmcm9tIGV4YwogICAgaWYg
>>"%WORKERPY%.b64" echo cmVzcG9uc2Uuc3RhdHVzX2NvZGUgPj0gNDAwOgogICAgICAgIHRyeToKICAgICAgICAgICAgZGV0
>>"%WORKERPY%.b64" echo YWlsID0gKHJlc3BvbnNlLmpzb24oKS5nZXQoImRldGFpbCIpIG9yIHJlc3BvbnNlLnRleHRbOjIw
>>"%WORKERPY%.b64" echo MF0pCiAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgIGRldGFpbCA9IHJlc3Bv
>>"%WORKERPY%.b64" echo bnNlLnRleHRbOjIwMF0KICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoZiJ7cHJvdmlkZXJ9OiB7
>>"%WORKERPY%.b64" echo ZGV0YWlsfSIpCiAgICB0cnk6CiAgICAgICAgcmVzdWx0ID0gcmVzcG9uc2UuanNvbigpCiAgICBl
>>"%WORKERPY%.b64" echo eGNlcHQgVmFsdWVFcnJvciBhcyBleGM6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKGYie3By
>>"%WORKERPY%.b64" echo b3ZpZGVyfSByZXR1cm5lZCBpbnZhbGlkIEpTT04iKSBmcm9tIGV4YwogICAgZGF0YSA9IHJlc3Vs
>>"%WORKERPY%.b64" echo dC5nZXQoImRhdGEiKSBpZiBpc2luc3RhbmNlKHJlc3VsdCwgZGljdCkgZWxzZSBOb25lCiAgICBp
>>"%WORKERPY%.b64" echo ZiBub3QgaXNpbnN0YW5jZShkYXRhLCBsaXN0KSBvciBub3QgZGF0YSBvciBub3QgZGF0YVswXS5n
>>"%WORKERPY%.b64" echo ZXQoImI2NF9qc29uIik6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKGYie3Byb3ZpZGVyfSBy
>>"%WORKERPY%.b64" echo ZXR1cm5lZCBubyBpbWFnZSBkYXRhIikKICAgIHJldHVybiBfd2l0aF9wcm92aWRlcihyZXN1bHQs
>>"%WORKERPY%.b64" echo IHByb3ZpZGVyLCBHRU1JTklfSU1BR0VfTU9ERUwgaWYgcHJvdmlkZXIgPT0gImdlbWluaSIgZWxz
>>"%WORKERPY%.b64" echo ZSBEVUNLX0lNQUdFX01PREVMKQoKCkBhcHAucG9zdCgiL3YxL2ltYWdlcy9nZW5lcmF0aW9ucyIp
>>"%WORKERPY%.b64" echo CmFzeW5jIGRlZiBpbWFnZXNfZ2VuZXJhdGlvbnMocmVxdWVzdDogUmVxdWVzdCk6CiAgICB0cnk6
>>"%WORKERPY%.b64" echo CiAgICAgICAgYm9keSA9IGF3YWl0IHJlcXVlc3QuanNvbigpCiAgICBleGNlcHQgRXhjZXB0aW9u
>>"%WORKERPY%.b64" echo OgogICAgICAgIGJvZHkgPSB7fQogICAgaWYgbm90IGlzaW5zdGFuY2UoYm9keSwgZGljdCk6CiAg
>>"%WORKERPY%.b64" echo ICAgICAgYm9keSA9IHt9CgogICAgcHJvbXB0ID0gKGJvZHkuZ2V0KCJwcm9tcHQiKSBvciBib2R5
>>"%WORKERPY%.b64" echo LmdldCgiaW5wdXQiKSBvciAiIikuc3RyaXAoKQogICAgaWYgbm90IHByb21wdDoKICAgICAgICBy
>>"%WORKERPY%.b64" echo YWlzZSBIVFRQRXhjZXB0aW9uKHN0YXR1c19jb2RlPTQwMCwgZGV0YWlsPSJwcm9tcHQgcmVxdWly
>>"%WORKERPY%.b64" echo ZWQiKQoKICAgIG1vZGVsID0gc3RyKGJvZHkuZ2V0KCJtb2RlbCIpIG9yICIiKS5zdHJpcCgpLmxv
>>"%WORKERPY%.b64" echo d2VyKCkKICAgIHN0YXJ0ZWQgPSB0aW1lLm1vbm90b25pYygpCgogICAgIyBBbiBleHBsaWNpdCBt
>>"%WORKERPY%.b64" echo b2RlbCB3aW5zLiBUaGUgYmFyZSBkZWZhdWx0ICgiaW1hZ2VmcmVlL2RlZmF1bHQiIGZyb20gdGhl
>>"%WORKERPY%.b64" echo CiAgICAjIHNpdGUpIG1lYW5zICJiZXN0IGZyZWUgcGljdHVyZSB0aGlzIFBDIGNhbiBtYWtlIiwg
>>"%WORKERPY%.b64" echo cmFua2VkIGJ5IHRoZSBtb2RlbAogICAgIyBlYWNoIHNlcnZpY2UgYWN0dWFsbHkgcnVucyAtIHNl
>>"%WORKERPY%.b64" echo ZSB0aGUgb3JkZXIgYmVsb3cuIEV2ZXJ5IGF0dGVtcHQgaXMKICAgICMgYm91bmRlZCBzbyB0aGUg
>>"%WORKERPY%.b64" echo c2VydmVyJ3MgfjE5MHMgZGVhZGxpbmUgaXMgbmV2ZXIgYmxvd24gYnkgYSBodW5nIHRhYi4KICAg
>>"%WORKERPY%.b64" echo IGlmIG1vZGVsLnN0YXJ0c3dpdGgoKCJnZW1pbmkiLCAibmFubyIpKToKICAgICAgICB0cnk6CiAg
>>"%WORKERPY%.b64" echo ICAgICAgICAgIHJldHVybiBKU09OUmVzcG9uc2UoYXdhaXQgX2NoYXRfaW1hZ2UoImdlbWluaSIs
>>"%WORKERPY%.b64" echo IHByb21wdCwgR0VNSU5JX0lNQUdFX1RJTUVPVVQpKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24g
>>"%WORKERPY%.b64" echo YXMgZXhjOgogICAgICAgICAgICBsb2cud2FybmluZygiZ2VtaW5pIGltYWdlIGZhaWxlZDogJXMi
>>"%WORKERPY%.b64" echo LCBleGMpCiAgICAgICAgICAgIHJhaXNlIEhUVFBFeGNlcHRpb24oc3RhdHVzX2NvZGU9NTAyLCBk
>>"%WORKERPY%.b64" echo ZXRhaWw9c3RyKGV4YykpCiAgICBpZiBtb2RlbC5zdGFydHN3aXRoKCgiZHVjayIsICJncHQtaW1h
>>"%WORKERPY%.b64" echo Z2UiKSk6CiAgICAgICAgdHJ5OgogICAgICAgICAgICByZXR1cm4gSlNPTlJlc3BvbnNlKGF3YWl0
>>"%WORKERPY%.b64" echo IF9jaGF0X2ltYWdlKCJkdWNrYWkiLCBwcm9tcHQsIERVQ0tfSU1BR0VfVElNRU9VVCkpCiAgICAg
>>"%WORKERPY%.b64" echo ICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6CiAgICAgICAgICAgIGxvZy53YXJuaW5nKCJkdWNr
>>"%WORKERPY%.b64" echo LmFpIGltYWdlIGZhaWxlZDogJXMiLCBleGMpCiAgICAgICAgICAgIHJhaXNlIEhUVFBFeGNlcHRp
>>"%WORKERPY%.b64" echo b24oc3RhdHVzX2NvZGU9NTAyLCBkZXRhaWw9c3RyKGV4YykpCgogICAgaWYgbW9kZWwuc3RhcnRz
>>"%WORKERPY%.b64" echo d2l0aCgicHV0ZXIiKToKICAgICAgICB0cnk6CiAgICAgICAgICAgIHJldHVybiBKU09OUmVzcG9u
>>"%WORKERPY%.b64" echo c2UoYXdhaXQgX3B1dGVyX2ltYWdlKHByb21wdCwgX2FzcGVjdChib2R5KSwgUFVURVJfSU1BR0Vf
>>"%WORKERPY%.b64" echo VElNRU9VVCkpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6CiAgICAgICAgICAgIGxv
>>"%WORKERPY%.b64" echo Zy53YXJuaW5nKCJwdXRlciBpbWFnZSBmYWlsZWQ6ICVzIiwgZXhjKQogICAgICAgICAgICByYWlz
>>"%WORKERPY%.b64" echo ZSBIVFRQRXhjZXB0aW9uKHN0YXR1c19jb2RlPTUwMiwgZGV0YWlsPXN0cihleGMpKQogICAgaWYg
>>"%WORKERPY%.b64" echo bW9kZWwuc3RhcnRzd2l0aCgoImZyZWUuYWkiLCAiZnJlZWFpIiwgImZyZWVkb3RhaSIsICJtYWdl
>>"%WORKERPY%.b64" echo IiwgIm1hbmdvIiwgImd1YXZhIikpOgogICAgICAgICMgVGhlc2UgdXNlIGFjY291bnQgdG9rZW5z
>>"%WORKERPY%.b64" echo IGhlbGQgYnkgdGhlIFNJVEUsIG5vdCBieSB0aGUgcGxheWVyJ3MgUEMuCiAgICAgICAgIyBGYWls
>>"%WORKERPY%.b64" echo IGZhc3Qgc28gdGhlIHNlcnZlci1zaWRlIHByb3ZpZGVyIG9mIHRoZSBzYW1lIG5hbWUgdGFrZXMg
>>"%WORKERPY%.b64" echo b3Zlci4KICAgICAgICByYWlzZSBIVFRQRXhjZXB0aW9uKHN0YXR1c19jb2RlPTUwMiwgZGV0YWls
>>"%WORKERPY%.b64" echo PWYie21vZGVsfTogY29uZmlndXJlZCBvbiB0aGUgc2VydmVyIG9ubHk7IG5vIGxvY2FsIHRva2Vu
>>"%WORKERPY%.b64" echo IikKCiAgICBpZiBub3QgbW9kZWwgb3IgbW9kZWwgaW4gKCJpbWFnZWZyZWUvZGVmYXVsdCIsICJk
>>"%WORKERPY%.b64" echo ZWZhdWx0IiwgImF1dG8taW1hZ2UiLCAiZnJlZSIpOgogICAgICAgICMgT25seSB0aGUgYnJvd3Nl
>>"%WORKERPY%.b64" echo ci1iYWNrZWQgbW9kZWxzIGJlbG9uZyB0byB0aGlzIHdvcmtlcjoKICAgICAgICAjICAgMS4gR2Vt
>>"%WORKERPY%.b64" echo aW5pIEZsYXNoIGltYWdlIC0gaGlnaCBxdWFsaXR5IEFORCBmYXN0ICg1MHMgY2FwKS4KICAgICAg
>>"%WORKERPY%.b64" echo ICAjICAgMi4gRHVjay5haSAvIEdQVCBJbWFnZSAyIC0gaXRzIG93biBlbmdpbmVlcnMgY2FsbCBp
>>"%WORKERPY%.b64" echo dCB0aGUgc2xvd2VzdAogICAgICAgICMgICAgICBvZiB0aGVpciBpbWFnZSBtb2RlbHMgKDY1cyBj
>>"%WORKERPY%.b64" echo YXApLgogICAgICAgICMgICAzLiBQdXRlciAoL2RyaXZlcnMvY2FsbCkgd2hlbiB0aGUgb3duZXIg
>>"%WORKERPY%.b64" echo c3VwcGxpZWQgUFVURVJfQUNDRVNTX1RPS0VOLgogICAgICAgICMgWi1JbWFnZS1UdXJibyBpcyBk
>>"%WORKERPY%.b64" echo ZWxpYmVyYXRlbHkgTk9UIGhlcmUuIFRoZSBzaXRlIGFscmVhZHkgZHJhd3MgaXQKICAgICAgICAj
>>"%WORKERPY%.b64" echo IGZyb20gaW1hZ2VmcmVlLm5ldCBhcyBpdHMgRklSU1Qgc291cmNlLCB3aXRob3V0IGFueSBiYXQg
>>"%WORKERPY%.b64" echo ZmlsZTsKICAgICAgICAjIGR1cGxpY2F0aW5nIGl0IGhlcmUgd291bGQgcHV0IGFsbCBGcmVlIEFJ
>>"%WORKERPY%.b64" echo IG1vZGVscyBpbiBvbmUgcG90IGFnYWluLgogICAgICAgICMgVGhlIHNpdGUgdHJpZXMgQUkgSG9y
>>"%WORKERPY%.b64" echo ZGUgbmV4dCBhbmQgUG9sbGluYXRpb25zIChTQU5BKSBsYXN0LgogICAgICAgIGF0dGVtcHRzID0g
>>"%WORKERPY%.b64" echo WwogICAgICAgICAgICAoImdlbWluaSIsIEdFTUlOSV9JTUFHRV9USU1FT1VULCBHRU1JTklfSU1B
>>"%WORKERPY%.b64" echo R0VfTU9ERUwpLAogICAgICAgICAgICAoImR1Y2thaSIsIERVQ0tfSU1BR0VfVElNRU9VVCwgRFVD
>>"%WORKERPY%.b64" echo S19JTUFHRV9NT0RFTCksCiAgICAgICAgXQogICAgICAgIGlmIFBVVEVSX0FDQ0VTU19UT0tFTjoK
>>"%WORKERPY%.b64" echo ICAgICAgICAgICAgYXR0ZW1wdHMuYXBwZW5kKCgicHV0ZXIiLCBQVVRFUl9JTUFHRV9USU1FT1VU
>>"%WORKERPY%.b64" echo LCBQVVRFUl9JTUFHRV9NT0RFTF9MQUJFTCkpCiAgICAgICAgbGFzdF9lcnJvciA9ICJubyBmcmVl
>>"%WORKERPY%.b64" echo IGltYWdlIG1vZGVsIG9uIHRoaXMgUEMgYW5zd2VyZWQiCiAgICAgICAgZm9yIHByb3ZpZGVyLCB0
>>"%WORKERPY%.b64" echo aW1lb3V0LCBtb2RlbF9uYW1lIGluIGF0dGVtcHRzOgogICAgICAgICAgICB0cnk6CiAgICAgICAg
>>"%WORKERPY%.b64" echo ICAgICAgICBpZiBwcm92aWRlciA9PSAicHV0ZXIiOgogICAgICAgICAgICAgICAgICAgIHJlc3Vs
>>"%WORKERPY%.b64" echo dCA9IGF3YWl0IF9wdXRlcl9pbWFnZShwcm9tcHQsIF9hc3BlY3QoYm9keSksIHRpbWVvdXQpCiAg
>>"%WORKERPY%.b64" echo ICAgICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgICAgIHJlc3VsdCA9IGF3YWl0IF9j
>>"%WORKERPY%.b64" echo aGF0X2ltYWdlKHByb3ZpZGVyLCBwcm9tcHQsIHRpbWVvdXQpCiAgICAgICAgICAgICAgICBsb2cu
>>"%WORKERPY%.b64" echo aW5mbygiZ2VuZXJhdGVkIHdpdGggJXMgaW4gJS4xZnMiLCBtb2RlbF9uYW1lLCB0aW1lLm1vbm90
>>"%WORKERPY%.b64" echo b25pYygpIC0gc3RhcnRlZCkKICAgICAgICAgICAgICAgIHJldHVybiBKU09OUmVzcG9uc2UocmVz
>>"%WORKERPY%.b64" echo dWx0KQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzoKICAgICAgICAgICAgICAg
>>"%WORKERPY%.b64" echo IGxhc3RfZXJyb3IgPSBzdHIoZXhjKQogICAgICAgICAgICAgICAgbG9nLndhcm5pbmcoIiVzIGlt
>>"%WORKERPY%.b64" echo YWdlIGF0dGVtcHQgZmFpbGVkOiAlcyIsIG1vZGVsX25hbWUsIGV4YykKICAgICAgICByYWlzZSBI
>>"%WORKERPY%.b64" echo VFRQRXhjZXB0aW9uKHN0YXR1c19jb2RlPTUwMiwgZGV0YWlsPWxhc3RfZXJyb3JbOjMwMF0pCgog
>>"%WORKERPY%.b64" echo ICAgdHJ5OgogICAgICAgIHJldHVybiBKU09OUmVzcG9uc2UoYXdhaXQgX2dlbmVyYXRlKHByb21w
>>"%WORKERPY%.b64" echo dCwgX2FzcGVjdChib2R5KSkpCiAgICBleGNlcHQgSFRUUEV4Y2VwdGlvbjoKICAgICAgICByYWlz
>>"%WORKERPY%.b64" echo ZQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6CiAgICAgICAgbG9nLmV4Y2VwdGlvbigiaW1h
>>"%WORKERPY%.b64" echo Z2UgZ2VuZXJhdGlvbiBlcnJvciIpCiAgICAgICAgcmFpc2UgSFRUUEV4Y2VwdGlvbihzdGF0dXNf
>>"%WORKERPY%.b64" echo Y29kZT01MDAsIGRldGFpbD1zdHIoZXhjKSkKCgpAYXBwLnBvc3QoIi9wcm94eSIpCkBhcHAucG9z
>>"%WORKERPY%.b64" echo dCgiL3YxL3Byb3h5IikKYXN5bmMgZGVmIHByb3h5X3JlcXVlc3QocmVxdWVzdDogUmVxdWVzdCk6
>>"%WORKERPY%.b64" echo CiAgICAiIiJHZW5lcmljIEhUVFAgcHJveHk6IGZvcndhcmRzIGFyYml0cmFyeSByZXF1ZXN0IGZy
>>"%WORKERPY%.b64" echo b20gdGhpcyBtYWNoaW5lJ3MgSVAuCgogICAgRXhwZWN0ZWQgSlNPTiBib2R5OgogICAgewogICAg
>>"%WORKERPY%.b64" echo ICAibWV0aG9kIjogIkdFVHxQT1NUfFBVVHxERUxFVEV8Li4uIiwKICAgICAgInVybCI6ICJodHRw
>>"%WORKERPY%.b64" echo czovLy4uLiIsCiAgICAgICJoZWFkZXJzIjogeyJIZWFkZXIiOiAidmFsdWUifSwKICAgICAgImJv
>>"%WORKERPY%.b64" echo ZHlfYjY0IjogImJhc2U2NCBlbmNvZGVkIGJvZHkgb3IgZW1wdHkiLAogICAgICAiZm9sbG93X3Jl
>>"%WORKERPY%.b64" echo ZGlyZWN0cyI6IHRydWUKICAgIH0KICAgIFJldHVybnM6CiAgICB7CiAgICAgICJzdGF0dXMiOiAy
>>"%WORKERPY%.b64" echo MDAsCiAgICAgICJoZWFkZXJzIjogey4uLn0sCiAgICAgICJib2R5X2I2NCI6ICIuLi4iLAogICAg
>>"%WORKERPY%.b64" echo ICAiY29udGVudF90eXBlIjogIi4uLiIKICAgIH0KICAgICIiIgogICAgdHJ5OgogICAgICAgIGJv
>>"%WORKERPY%.b64" echo ZHkgPSBhd2FpdCByZXF1ZXN0Lmpzb24oKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBy
>>"%WORKERPY%.b64" echo YWlzZSBIVFRQRXhjZXB0aW9uKHN0YXR1c19jb2RlPTQwMCwgZGV0YWlsPSJpbnZhbGlkIGpzb24i
>>"%WORKERPY%.b64" echo KQoKICAgIG1ldGhvZCA9IChib2R5LmdldCgibWV0aG9kIikgb3IgIkdFVCIpLnVwcGVyKCkKICAg
>>"%WORKERPY%.b64" echo IHVybCA9IGJvZHkuZ2V0KCJ1cmwiKSBvciAiIgogICAgaWYgbm90IHVybDoKICAgICAgICByYWlz
>>"%WORKERPY%.b64" echo ZSBIVFRQRXhjZXB0aW9uKHN0YXR1c19jb2RlPTQwMCwgZGV0YWlsPSJ1cmwgcmVxdWlyZWQiKQoK
>>"%WORKERPY%.b64" echo ICAgIGhlYWRlcnMgPSBib2R5LmdldCgiaGVhZGVycyIpIG9yIHt9CiAgICBib2R5X2I2NCA9IGJv
>>"%WORKERPY%.b64" echo ZHkuZ2V0KCJib2R5X2I2NCIpIG9yICIiCiAgICBmb2xsb3dfcmVkaXJlY3RzID0gYm9keS5nZXQo
>>"%WORKERPY%.b64" echo ImZvbGxvd19yZWRpcmVjdHMiLCBUcnVlKQoKICAgIHJlcV9ib2R5ID0gTm9uZQogICAgaWYgYm9k
>>"%WORKERPY%.b64" echo eV9iNjQ6CiAgICAgICAgdHJ5OgogICAgICAgICAgICByZXFfYm9keSA9IGJhc2U2NC5iNjRkZWNv
>>"%WORKERPY%.b64" echo ZGUoYm9keV9iNjQpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcmFpc2Ug
>>"%WORKERPY%.b64" echo SFRUUEV4Y2VwdGlvbihzdGF0dXNfY29kZT00MDAsIGRldGFpbD0iaW52YWxpZCBib2R5X2I2NCIp
>>"%WORKERPY%.b64" echo CgogICAgdHJ5OgogICAgICAgIGFzeW5jIHdpdGggaHR0cHguQXN5bmNDbGllbnQodGltZW91dD0z
>>"%WORKERPY%.b64" echo MDAsIGZvbGxvd19yZWRpcmVjdHM9Zm9sbG93X3JlZGlyZWN0cykgYXMgY2xpZW50OgogICAgICAg
>>"%WORKERPY%.b64" echo ICAgICByZXNwID0gYXdhaXQgY2xpZW50LnJlcXVlc3QoCiAgICAgICAgICAgICAgICBtZXRob2Q9
>>"%WORKERPY%.b64" echo bWV0aG9kLAogICAgICAgICAgICAgICAgdXJsPXVybCwKICAgICAgICAgICAgICAgIGhlYWRlcnM9
>>"%WORKERPY%.b64" echo aGVhZGVycywKICAgICAgICAgICAgICAgIGNvbnRlbnQ9cmVxX2JvZHksCiAgICAgICAgICAgICkK
>>"%WORKERPY%.b64" echo ICAgICAgICAgICAgcmVzcF9ib2R5ID0gcmVzcC5jb250ZW50CiAgICAgICAgICAgIHJlc3BfaGVh
>>"%WORKERPY%.b64" echo ZGVycyA9IHt9CiAgICAgICAgICAgIGZvciBrLCB2IGluIHJlc3AuaGVhZGVycy5pdGVtcygpOgog
>>"%WORKERPY%.b64" echo ICAgICAgICAgICAgICAgcmVzcF9oZWFkZXJzW2tdID0gdgogICAgICAgICAgICByZXR1cm4gSlNP
>>"%WORKERPY%.b64" echo TlJlc3BvbnNlKHsKICAgICAgICAgICAgICAgICJzdGF0dXMiOiByZXNwLnN0YXR1c19jb2RlLAog
>>"%WORKERPY%.b64" echo ICAgICAgICAgICAgICAgImhlYWRlcnMiOiByZXNwX2hlYWRlcnMsCiAgICAgICAgICAgICAgICAi
>>"%WORKERPY%.b64" echo Ym9keV9iNjQiOiBiYXNlNjQuYjY0ZW5jb2RlKHJlc3BfYm9keSkuZGVjb2RlKCJhc2NpaSIpLAog
>>"%WORKERPY%.b64" echo ICAgICAgICAgICAgICAgImNvbnRlbnRfdHlwZSI6IHJlc3AuaGVhZGVycy5nZXQoImNvbnRlbnQt
>>"%WORKERPY%.b64" echo dHlwZSIsICIiKSwKICAgICAgICAgICAgfSkKICAgIGV4Y2VwdCBodHRweC5UaW1lb3V0RXhjZXB0
>>"%WORKERPY%.b64" echo aW9uOgogICAgICAgIHJhaXNlIEhUVFBFeGNlcHRpb24oc3RhdHVzX2NvZGU9NTA0LCBkZXRhaWw9
>>"%WORKERPY%.b64" echo InByb3h5IHJlcXVlc3QgdGltZWQgb3V0IikKICAgIGV4Y2VwdCBodHRweC5SZXF1ZXN0RXJyb3Ig
>>"%WORKERPY%.b64" echo YXMgZXhjOgogICAgICAgIHJhaXNlIEhUVFBFeGNlcHRpb24oc3RhdHVzX2NvZGU9NTAyLCBkZXRh
>>"%WORKERPY%.b64" echo aWw9ZiJwcm94eSByZXF1ZXN0IGZhaWxlZDoge2V4Y30iKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBh
>>"%WORKERPY%.b64" echo cyBleGM6CiAgICAgICAgbG9nLmV4Y2VwdGlvbigicHJveHkgZXJyb3IiKQogICAgICAgIHJhaXNl
>>"%WORKERPY%.b64" echo IEhUVFBFeGNlcHRpb24oc3RhdHVzX2NvZGU9NTAwLCBkZXRhaWw9c3RyKGV4YykpCgoKQGFwcC5n
>>"%WORKERPY%.b64" echo ZXQoIi9oZWFsdGh6IikKYXN5bmMgZGVmIGhlYWx0aHooKToKICAgIHJldHVybiB7InN0YXR1cyI6
>>"%WORKERPY%.b64" echo ICJvayJ9CgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIGltcG9ydCB1dmljb3JuCgog
>>"%WORKERPY%.b64" echo ICAgcG9ydCA9IGludChvcy5nZXRlbnYoIklNQUdFX1dPUktFUl9QT1JUIiwgIjgwMDIiKSkKICAg
>>"%WORKERPY%.b64" echo IHV2aWNvcm4ucnVuKGFwcCwgaG9zdD0iMTI3LjAuMC4xIiwgcG9ydD1wb3J0LCBsb2dfbGV2ZWw9
>>"%WORKERPY%.b64" echo ImluZm8iKQo=
powershell -NoProfile -Command "[IO.File]::WriteAllBytes('%WORKERPY%', [Convert]::FromBase64String(([IO.File]::ReadAllText('%WORKERPY%.b64') -replace '\s','')))" >nul 2>&1
del /q "%WORKERPY%.b64" >nul 2>&1
goto :eof
