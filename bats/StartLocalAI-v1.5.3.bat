@echo off
REM =====================================================================
REM  AI Adventure Master - local AI connector (Windows)
REM
REM  The version is in the file name on purpose: the window prints it, so
REM  you can always tell at a glance whether the copy you downloaded is the
REM  copy the website is currently serving.
REM
REM  This file does not install anything and does not start any AI.
REM
REM  What it does: it finds the local AIs that are ALREADY running on this
REM  computer and connects this machine to the website. This file is built
REM  for one site and carries its address inside, so nothing has to be typed
REM  in and no address has to be copied out of a page first. The address it
REM  prints afterwards belongs to the website and never changes - not after
REM  a restart, not after a reconnect, not when this window is closed and
REM  opened again. That is the whole point: a tunnel hands out a new random
REM  address every time, so the old one had to be pasted again and again.
REM
REM  Any OpenAI-compatible local AI works - Ollama, LM Studio, llama.cpp,
REM  vLLM, Jan, LocalAI, GPT4All, KoboldCpp, TabbyAPI, text-generation-webui,
REM  LiteLLM Proxy, one-api, FreeLLMAPI and anything else. A router that
REM  asks for an API key is found too - the site sends the key itself.
REM
REM  No local AI at all? Then there is nothing to connect yet - start the
REM  AI first and run this file again. It is found either way; nothing has
REM  to be typed in and no address has to be copied out of a page first.
REM
REM  Keep this window open while you play: closing it closes the link.
REM =====================================================================

REM  Keep this window on screen: it is the only place the address and any
REM  error are shown, and closing it closes the link.
setlocal EnableExtensions
title AI Adventure Master - local AI v1.5.2

set "VERSION=1.5.3"
REM  The one site this file is for. It is written in here on purpose: the file
REM  is downloaded from that site, so it always knows where to dial, and a
REM  player never has to be asked for an address or told to paste one in.
set "HOMESITE=https://aiadventuremaster.space"
set "PS1=%TEMP%\aim-connector-%RANDOM%%RANDOM%.ps1"
set "PROXYPORT=11500"
set "RUNID=%RANDOM%%RANDOM%"
set "CFLOG=%TEMP%\aim-cloudflared-%RUNID%.log"
set "SSHLOG=%TEMP%\aim-ssh-%RUNID%.log"
set "SVELOG=%TEMP%\aim-serveo-%RUNID%.log"
set "NGLOG=%TEMP%\aim-ngrok-%RUNID%.log"
set "PSERR=%TEMP%\aim-connector-%RUNID%.err"
set "TRACE=%TEMP%\aim-trace.log"
set "PIDFILE=%TEMP%\aim-tunnel-%RUNID%.pid"
set "LISFILE=%TEMP%\aim-listen-%RUNID%.txt"
set "STATEDIR=%LOCALAPPDATA%\AIAdventureMaster"
set "STATE=%STATEDIR%\connector.json"
set "PORT="
set "SUFFIX=/v1"
REM  How many local AIs are connected at the same time. The site's loopback
REM  door knows four (ports 11510-11513), so four is the most that can be
REM  shown on the Settings page - and four is what step 1 can fill.
set "MAXSLOTS=4"
set "SLOTS=0"
set "AI1_PORT="
set "AI1_NAME="
set "AI1_BASE="
set "AI2_PORT="
set "AI2_NAME="
set "AI2_BASE="
set "AI3_PORT="
set "AI3_NAME="
set "AI3_BASE="
set "AI4_PORT="
set "AI4_NAME="
set "AI4_BASE="
set "SITE="
set "TOKEN="
set "AIMEND="
set "AGENTPID="
set "URL="
set "LISTEN="
set "misses=0"

REM  Logs of earlier runs are of no use to anyone once the game is over, and
REM  a temp folder that fills up with them is its own kind of trouble. Only
REM  files older than a day go, so a second window open right now is never
REM  touched.
powershell -NoProfile -Command "Get-ChildItem -Path $env:TEMP -Filter 'aim-*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Force -ErrorAction SilentlyContinue" >nul 2>&1

REM  A doorway from an earlier run may still be listening.
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /r /c:"127.0.0.1:%PROXYPORT% .*LISTENING"') do taskkill /PID %%P /F >nul 2>&1
del /q "%TEMP%\aim-tunnel-*.pid" >nul 2>&1

echo.
echo   AI Adventure Master - local AI connector v%VERSION%
echo   -----------------------------------------
echo.

echo   [1/4] Looking for local AIs that are already running...
REM  Every port this project knows about is asked in one sweep, in order of
REM  preference - the list is the block of "call :scan_port" lines right
REM  below, one line per port, easy to add to.
REM
REM  Two gates decide whether a port is asked at all. The first is netstat,
REM  run ONCE for every port (:listen_set): a port that is not listening is
REM  never asked over HTTP, because a closed local port does NOT refuse
REM  straight away on a Windows machine with a VPN filter driver loaded -
REM  the SYN is swallowed and the answer only arrives when the timeout does.
REM  Measured here with a bare TcpClient.Connect: an open port answered in
REM  0-70 ms, a closed one took 2014-2103 ms, five times out of five - so
REM  probing a port list blind would be minutes of staring at dead ports.
REM
REM  The second gate is the answer itself (:probe_ai): 200 on /v1/models or
REM  a root /models, or 401/403 - a server that IS there and only wants a
REM  key the game sends itself - fills a slot. The STATUS alone is not
REM  enough, though: the answer has to read like an AI as well. A plain 200
REM  counts only when the body is a JSON model list (a "data" array), and a
REM  401/403 only when the body is an error the server explains itself in
REM  (an "error" property). Without that second look, ANY service that
REM  answers 401 to everything passed for a local AI - on the machine this
REM  was measured on, http.sys (Microsoft-HTTPAPI/2.0, the System process)
REM  sits on 1337 and answers 401 with "{}", and Jan was reported running
REM  when it had never been installed. The order of the list is the order of
REM  PREFERENCE: the first ports that answer take the slots, so a live
REM  Ollama on 11434 is always slot 1.
call :trace "step1 start"
call :listen_set
set "ANY_PORT_FOUND="
set "SLOTS=0"
set "AI1_ADDR="
set "AI2_ADDR="
set "AI3_ADDR="
set "AI4_ADDR="
call :scan_port 11434 "Ollama"
call :scan_port 1234 "LM Studio"
call :scan_port 8080 "llama.cpp / LocalAI / llamafile"
call :scan_port 8000 "vLLM / TGI"
call :scan_port 1337 "Jan"
call :scan_port 5001 "KoboldCpp / LM Studio alt"
call :scan_port 4891 "GPT4All"
call :scan_port 12434 "LM Studio alt2"
call :scan_port 5000 "TabbyAPI / text-generation-webui"
call :scan_port 7860 "Stable Diffusion"
call :scan_port 4000 "LiteLLM Proxy"
call :scan_port 3000 "one-api / new-api"
REM  FreeLLMAPI gets one line per port on purpose: the app takes 31415 and
REM  steps up to the next free port when that one is taken, and some
REM  installs use 3001 instead - every one of those must be found.
call :scan_port 31415 "FreeLLMAPI"
call :scan_port 31416 "FreeLLMAPI"
call :scan_port 31417 "FreeLLMAPI"
call :scan_port 31418 "FreeLLMAPI"
call :scan_port 31419 "FreeLLMAPI"
call :scan_port 3001 "FreeLLMAPI alt"
del /q "%LISFILE%" "%TEMP%\aim-probe-%RUNID%.json" >nul 2>&1
if not defined ANY_PORT_FOUND goto :noport
call :trace "step1 OK, %SLOTS% port(s) found"
REM  The temporary-link fallback relays to ONE port - the first found, which
REM  is the most preferred one by list order.
set "PORT=%AI1_PORT%"
echo.
echo   Found local AI(s):
if defined AI1_PORT echo         %AI1_NAME% - port %AI1_PORT%
if defined AI2_PORT echo         %AI2_NAME% - port %AI2_PORT%
if defined AI3_PORT echo         %AI3_NAME% - port %AI3_PORT%
if defined AI4_PORT echo         %AI4_NAME% - port %AI4_PORT%

:step2
echo.
echo   [2/4] Working out your addresses on the site...
call :resolve_site
if not defined SITE goto :nosite
echo         Site:   %SITE%
REM  Resolve one base token (kept in connector.json) and derive per-port tokens
REM  by appending the port number, so every AI gets its own stable address.
call :resolve_token
if not defined TOKEN goto :nosite
if defined AI1_PORT set "AI1_ADDR=%SITE%/ai/%TOKEN%%AI1_PORT%%SUFFIX%"
if defined AI2_PORT set "AI2_ADDR=%SITE%/ai/%TOKEN%%AI2_PORT%%SUFFIX%"
if defined AI3_PORT set "AI3_ADDR=%SITE%/ai/%TOKEN%%AI3_PORT%%SUFFIX%"
if defined AI4_PORT set "AI4_ADDR=%SITE%/ai/%TOKEN%%AI4_PORT%%SUFFIX%"
call :save_state
call :trace "site=%SITE% baseToken=%TOKEN%"
echo         Addresses (one per AI, ports are part of the token path):
if defined AI1_ADDR echo         %AI1_NAME%:   %AI1_ADDR%
if defined AI2_ADDR echo         %AI2_NAME%:   %AI2_ADDR%
if defined AI3_ADDR echo         %AI3_NAME%:   %AI3_ADDR%
if defined AI4_ADDR echo         %AI4_NAME%:   %AI4_ADDR%

echo.
echo   [3/4] Connecting this computer to the site...
where powershell >nul 2>&1
if errorlevel 1 goto :noproxy
REM  Start one connector per found port. Each gets its own token (base token
REM  with the port number appended), its own local door, and the base path
REM  the probe actually saw there (/v1, or ROOT for a server that exposes
REM  its API at the root).
if defined AI1_ADDR call :start_agent_for_port %AI1_PORT% "%TOKEN%%AI1_PORT%" %AI1_BASE%
if defined AI2_ADDR call :start_agent_for_port %AI2_PORT% "%TOKEN%%AI2_PORT%" %AI2_BASE%
if defined AI3_ADDR call :start_agent_for_port %AI3_PORT% "%TOKEN%%AI3_PORT%" %AI3_BASE%
if defined AI4_ADDR call :start_agent_for_port %AI4_PORT% "%TOKEN%%AI4_PORT%" %AI4_BASE%
call :trace "agents launched"

set /a atries=0
echo.
echo         Connecting and checking that every address really works. This
echo         usually takes a second or two.
:agent_wait_all
ping -n 3 127.0.0.1 >nul
set /a atries+=1
set "ALL_OK=1"
if defined AI1_ADDR call :answered "%AI1_ADDR%/models" 10 strict || set "ALL_OK="
if defined AI2_ADDR call :answered "%AI2_ADDR%/models" 10 strict || set "ALL_OK="
if defined AI3_ADDR call :answered "%AI3_ADDR%/models" 10 strict || set "ALL_OK="
if defined AI4_ADDR call :answered "%AI4_ADDR%/models" 10 strict || set "ALL_OK="
if defined ALL_OK goto :agent_ok_all
if %atries% GEQ 30 goto :agent_failed_all
goto :agent_wait_all
:agent_ok_all
call :trace "all agents answered, addresses accepted"

echo.
echo   [4/4] Done.
echo.
echo   Your local AI(s) are reachable at the addresses above, and each stays
echo   at its address for as long as this site exists.
echo.
echo   Next: open the site's Settings page. For the Local source the site
echo   finds this window by itself and fills in the address - nothing has to
echo   be typed in by hand. Then press "Load models", pick your model
echo   and press "Save". Do the same for "Remember world" and "Chat background"
echo   if you want a different local AI for each of them.
echo.
echo   Keep this window open while you play. After a restart, run this file
echo   again - the addresses are unchanged.
echo.
echo   Anyone who has an address and your API key can use that AI while this
echo   window is open.
echo.
echo   Press Ctrl+C or close this window to disconnect all.
goto :wait

REM ---------------------------------------------------------------------
REM  The permanent address did not come up. An old-style temporary link is
REM  better than nothing: the game still works, the link just has to be put
REM  into the Endpoint field again next time. This is exactly what earlier
REM  versions did and it is kept for networks where the outgoing connection
REM  is blocked.
REM ---------------------------------------------------------------------
:agent_failed_all
REM  Stop whatever agents we managed to start.
if defined AI1_ADDR call :stop_agent_for_port %AI1_PORT% "%TOKEN%%AI1_PORT%"
if defined AI2_ADDR call :stop_agent_for_port %AI2_PORT% "%TOKEN%%AI2_PORT%"
if defined AI3_ADDR call :stop_agent_for_port %AI3_PORT% "%TOKEN%%AI3_PORT%"
if defined AI4_ADDR call :stop_agent_for_port %AI4_PORT% "%TOKEN%%AI4_PORT%"
call :trace "no agent became reachable, falling back to a temporary link"
echo.
echo         The site did not accept the connection within a minute.
echo.
echo         Trying the old way instead: a temporary https link, which has
echo         to be put into the Endpoint field again after every restart.
echo.
call :fallback
goto :eof

REM ---------------------------------------------------------------------
REM  Start one connector for one port. Used once per found port.
REM  Each call launches its own hidden PowerShell with its own token+port.
REM ---------------------------------------------------------------------
:start_agent_for_port
set "_sap_port=%~1"
set "_sap_token=%~2"
set "_sap_base=%~3"
call :write_script
if not exist "%PS1%" goto :eof
start "aim-connector-%_sap_port%" /b powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode agent -Site "%SITE%" -Token "%_sap_token%" -TargetPort %_sap_port% -BasePath %_sap_base% >"%PSERR%.%_sap_port%" 2>&1
call :trace "  connector launched for port %_sap_port%, token %_sap_token%"
set /a _sap_waits=0
:sap_pid
ping -n 2 127.0.0.1 >nul
set /a _sap_waits+=1
set "FOUND_PID="
call :find_pid_by_port %_sap_port%
if defined FOUND_PID (
    goto :eof
)
if %_sap_waits% GEQ 15 goto :eof
goto :sap_pid

REM ---------------------------------------------------------------------
REM  Stop one connector by its port/token.
REM ---------------------------------------------------------------------
:stop_agent_for_port
set "_sdp_port=%~1"
set "_sdp_token=%~2"
REM  Kill the PowerShell whose command line mentions our port.
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*TargetPort %_sdp_port%*' } | Select-Object -First 1 -ExpandProperty ProcessId" 2^>nul`) do (
    if defined %%P taskkill /PID %%P /F >nul 2>&1
)
goto :eof

REM ---------------------------------------------------------------------
REM  Find a connector PID by listening port (for :wait_agent below).
REM
REM  The pipes in here are NOT escaped as ^| and must not be. cmd only
REM  un-escapes a caret OUTSIDE double quotes; these live inside the quoted
REM  -Command argument, so a ^| reaches PowerShell as a literal "^|" and the
REM  whole command dies with a parse error - which is invisible here, and
REM  the visible result was that the connector was reported as gone one
REM  second after it had just started. For the same reason the process name
REM  is compared in Where-Object instead of through -Filter with \" quotes:
REM  a backslash is not an escape character to cmd, so those inner quotes
REM  close the argument early and the command is chopped in half.
REM ---------------------------------------------------------------------
:find_pid_by_port
set "FOUND_PID="
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*TargetPort %~1*' } | Select-Object -First 1 -ExpandProperty ProcessId" 2^>nul`) do set "FOUND_PID=%%P"
goto :eof

REM =====================================================================
REM  The temporary-link fallback. The doorway and the tunnel code below are
REM  unchanged from earlier versions, so a network that worked before keeps
REM  working.
REM =====================================================================
:fallback
call :start_proxy
call :trace "proxy returned, PROXYOK=%PROXYOK%"
if not defined PROXYOK goto :noproxy

echo.
echo         Opening an https link. If one service is blocked on your
echo         network, the next one is tried automatically.
echo.
REM  The order matters. Cloudflare comes first because its quick tunnel
REM  keeps one name for the whole session. ngrok comes next, but only if it
REM  is already installed, and with an account its name is stable too.
REM  localhost.run is left for last: on its free tier it hands out a NEW
REM  name every time it reconnects (27 of 38 runs on this machine ended
REM  with "tunnel activity timeout"), so it is a lifeline for networks that
REM  block Cloudflare, not a link to rely on. serveo is the final attempt.
call :try_cloudflare 2>nul
call :trace "  after cloudflare, URL=%URL%"
if not defined URL call :try_ngrok 2>nul
call :trace "  after ngrok, URL=%URL%"
if not defined URL call :try_ssh 2>nul
call :trace "  after localhost.run, URL=%URL%"
if not defined URL call :try_serveo 2>nul
call :trace "  after serveo, URL=%URL%"
if not defined URL goto :failed

REM  Show the address on screen. This is the temporary link, NOT the
REM  permanent address printed in step 2 above (that one did not come up,
REM  which is why the fallback is running). The Settings page cannot find a
REM  temporary link by itself - there is no door on this machine for it -
REM  so this address is the one the player has to put into the Endpoint
REM  field, and this window is the only place it is ever shown.
echo   Address: %URL%%SUFFIX%
echo.
echo   Your local AI is reachable at that address now.
echo.
echo   Next: go back to the site tab, open Settings and put that address
echo   into the "Endpoint" field. Then press "Load models", pick your model
echo   and press "Save".
echo.
echo   Keep this window open while you play. After you restart your
echo   computer, run this file again - the link changes every time.
echo   Anyone who knows this random link can use your AI while it is open.
echo.
echo   Press Ctrl+C or close this window to disconnect.
:wait
ping -n 4 127.0.0.1 >nul
REM  The old-way (tunnel) window watches the tunnel it actually opened; the
REM  agent window watches the permanent addresses. Falling into the same
REM  loop either way was wrong: a fallback window checked the dead agent
REM  addresses and reported a failure that was not one.
if defined URL goto :wait_tunnel
goto :wait_agents

:wait_agents
REM  One round every ~7 seconds. This loop used to spin as fast as the
REM  network answered, and the site counts how often an address is asked
REM  about (120 a minute, per address - Server:RateLimits:ConnectorPerWindow).
REM  A tight loop spent that budget in a few seconds, the site then answered
REM  429 to everything, and the warning below printed over and over while
REM  the addresses were fine the whole time. ~25 questions a minute per
REM  address stays well inside the limit, and a liveness check has no use
REM  for being faster than that.
ping -n 8 127.0.0.1 >nul
set "ANY_ALIVE="
if defined AI1_ADDR call :answered "%AI1_ADDR%/models" 15 strict && set "ANY_ALIVE=1"
if defined AI2_ADDR call :answered "%AI2_ADDR%/models" 15 strict && set "ANY_ALIVE=1"
if defined AI3_ADDR call :answered "%AI3_ADDR%/models" 15 strict && set "ANY_ALIVE=1"
if defined AI4_ADDR call :answered "%AI4_ADDR%/models" 15 strict && set "ANY_ALIVE=1"

if defined ANY_ALIVE (
    if defined WASDOWN (
        echo.
        echo   Back online - the site can reach your local AI^(s^) again.
    )
    set "WASDOWN="
    set /a misses=0
    goto :wait_agents
)

REM  Three quiet rounds in a row before saying anything, and then ONCE.
REM  Repeating the same paragraph every two seconds told the player nothing
REM  new and buried everything else this window had to say. It stays quiet
REM  until the addresses answer again, and then says so.
set /a misses+=1
if %misses% LSS 3 goto :wait_agents
set /a misses=0
if defined WASDOWN goto :wait_agents
set "WASDOWN=1"
call :trace "addresses not answering, warning shown once"
echo.
echo   The site cannot reach your local AI^(s^) at the moment. Nothing about
echo   your settings has changed and the addresses have NOT changed - this
echo   window keeps trying by itself. Start your local AI again if it stopped.
goto :wait_agents

:agent_died
call :trace "a connector process is gone"
call :cleanup_all
echo.
echo   A connector stopped. Close this window and run the file again.
call :stay
endlocal
exit /b 0

:wait_tunnel
REM  Same lesson as :wait_agents - ask at a sane pace. The tunnel check is
REM  local traffic, so nothing here is rate-limited, but a loop with no
REM  pause hammers the local AI's /models several times a second for as
REM  long as the window stays open, for no benefit.
ping -n 4 127.0.0.1 >nul
call :tunnel_alive
if "%TUNNEL_ALIVE%"=="1" goto :wait_tunnel
call :cleanup
echo.
echo   The link is closed now.
call :trace "link closed, waiting to exit"
call :stay
endlocal
exit /b 0

REM ---------------------------------------------------------------------
REM  Keep this window on screen until it has actually been read.
REM
REM  "pause" alone is not enough: when the file is started from another
REM  program (a terminal, an editor, a launcher) there is no console to
REM  wait on, so "pause" returns at once and the window vanishes before the
REM  message above can be read - which looks like the file "just closed".
REM ---------------------------------------------------------------------
:stay
echo.
echo   Press any key to close this window.
pause >nul 2>&1
timeout /t 4 /nobreak >nul 2>&1
goto :eof

REM ---------------------------------------------------------------------
REM  A plain text trail of what happened, because the window itself can
REM  disappear before anyone reads it. Sent to the temp folder only.
REM ---------------------------------------------------------------------
:trace
>>"%TRACE%" echo %date% %time% %~1
goto :eof

REM ---------------------------------------------------------------------
REM  Which website to talk to: always the one it was downloaded from.
REM
REM  This used to be worked out at run time - first argument, then the
REM  AIM_SITE variable, then whatever was remembered, then a question - which
REM  meant a player could point the file at a different site by hand and a
REM  mistyped address ended the run with nothing to show. The file ships from
REM  one site and is built for that site, so the address is simply written in
REM  at the top (HOMESITE) and never asked about. The stored value is still
REM  read, but only for the token, and a stale site inside it is ignored.
REM ---------------------------------------------------------------------
:resolve_site
set "SITE=%HOMESITE%"
:check_site
REM  A trailing slash is dropped, and only a trailing slash: the address ends
REM  in "https://host" and the address of the connector is built by appending
REM  to it, so a leftover slash would turn the result into a double slash that
REM  no token ever matches.
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
REM
REM  It is a password and nothing else - it is never shown anywhere on the
REM  site and never sent anywhere but to the site this file talks to. Making
REM  a NEW one on every run would break the stored address, so it is read
REM  back from the small file next to it instead.
REM ---------------------------------------------------------------------
:resolve_token
if not "%~2"=="" set "TOKEN=%~2"
if defined TOKEN goto :eof
if exist "%STATE%" for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "if (Test-Path '%STATE%') { $j = Get-Content -Raw '%STATE%' -ErrorAction SilentlyContinue | ConvertFrom-Json; if ($j.token) { Write-Output ($j.token) } }" 2^>nul`) do (
    if not defined TOKEN set "TOKEN=%%T"
)
if defined TOKEN goto :eof
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "$b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')"`) do set "TOKEN=%%T"
if not defined TOKEN goto :nosite
goto :eof

REM ---------------------------------------------------------------------
REM  Remember site, token and the port that was found, so the next run needs
REM  no typing at all. A plain small file in the user's own profile folder -
REM  nothing is installed and nothing is written anywhere else.
REM ---------------------------------------------------------------------
:save_state
if not exist "%STATEDIR%" md "%STATEDIR%" >nul 2>&1
REM  Keep one base token and the site. The port is now part of the address
REM  (token11434, token1234, token7860), so every AI gets its own stable path
REM  on the same site.
powershell -NoProfile -Command "$o = [ordered]@{ site = '%SITE%'; token = '%TOKEN%' }; [IO.File]::WriteAllText('%STATE%', ($o | ConvertTo-Json))" >nul 2>&1
goto :eof

REM ---------------------------------------------------------------------
REM  One port, one look. Called once per line of the step-1 list, in order
REM  of preference: the first ports that answer fill the slots.
REM
REM  Gate 1, netstat: a port with nothing LISTENING is not asked at all -
REM  the list comes from :listen_set. When the list cannot be trusted
REM  (LISTEN is unset), the port is asked anyway: a missing netstat must
REM  cost two seconds, never a wrong "no local AI found".
REM
REM  Gate 2, the answer: /v1/models first, then a bare /models for servers
REM  that expose the API at the root. The server is recognised by what it
REM  answers, never by its name, so a model this file has never heard of
REM  still works. 401/403 counts too: the server IS there and only wants a
REM  key - the game sends that key itself, and a file that walked past it
REM  would tell the user to go and start an AI they already started. That
REM  whole check is :probe_ai below, which reads the BODY as well: a status
REM  on its own is not proof of an AI (see the note there).
REM ---------------------------------------------------------------------
:scan_port
if %SLOTS% GEQ %MAXSLOTS% goto :eof
set "_sp_port=%~1"
set "_sp_name=%~2"
if not defined LISTEN goto :sp_ask
findstr /c:":%_sp_port%  " "%LISFILE%" >nul 2>&1
if errorlevel 1 goto :eof
:sp_ask
call :trace "  probe %_sp_port% /v1/models"
call :probe_ai "http://localhost:%_sp_port%/v1/models" 2
if not errorlevel 1 goto :sp_v1
call :trace "  probe %_sp_port% /models"
call :probe_ai "http://localhost:%_sp_port%/models" 2
if errorlevel 1 goto :eof
call :take_slot "%_sp_port%" "%_sp_name%" ROOT
goto :eof
:sp_v1
call :take_slot "%_sp_port%" "%_sp_name%" /v1
goto :eof

REM ---------------------------------------------------------------------
REM  Does this port answer like a local AI? %1 url, %2 timeout.
REM
REM  A status code alone is not an answer. The first version of this scan
REM  accepted any 401/403 as "a keyed server", and on the machine this was
REM  measured on that turned http.sys into Jan: Microsoft-HTTPAPI/2.0 (the
REM  System process, PID 4) listens on 1337 and answers 401 with an empty
REM  "{}" to every path and every key, so the file reported a Jan that was
REM  never installed, gave it a token, and started a connector to it. Nothing
REM  about that answer was ever AI-shaped - only its status was.
REM
REM  So the body decides, and the rule is the same one the site uses to read
REM  a model list: the answer must be JSON, and it must carry the property a
REM  real server would put there:
REM
REM    200        -> "data"  (an OpenAI-compatible /v1/models list)
REM    401 / 403  -> "error" (the server explaining what it wants, the way
REM                          LiteLLM, one-api and their kin do)
REM
REM  An empty object carries neither, a web page is not JSON at all, and a
REM  server that answers neither is skipped exactly like a dead port. The
REM  cost of being strict is a keyed router that explains itself in some
REM  other shape being missed - the player can still type that address into
REM  Settings by hand, which is not true of a connector opened to http.sys.
REM ---------------------------------------------------------------------
:probe_ai
set "_pa_url=%~1"
set "CODE="
set "AIBODY=%TEMP%\aim-probe-%RUNID%.json"
del /q "%AIBODY%" >nul 2>&1
for /f "usebackq delims=" %%C in (`curl.exe -s -o "%AIBODY%" -m %~2 -w "%%{http_code}" "%_pa_url%" 2^>nul`) do set "CODE=%%C"
if "%CODE%"=="200" goto :pa_models
if "%CODE%"=="401" goto :pa_keyed
if "%CODE%"=="403" goto :pa_keyed
exit /b 1
:pa_models
call :json_property "%AIBODY%" "data"
if errorlevel 1 exit /b 1
call :trace "  %_pa_url% answered 200 with a model list"
exit /b 0
:pa_keyed
call :json_property "%AIBODY%" "error"
if errorlevel 1 (
    call :trace "  %_pa_url% answered %CODE% without an AI's error body, ignored"
    exit /b 1
)
call :trace "  %_pa_url% answered %CODE%, a keyed AI"
exit /b 0

REM ---------------------------------------------------------------------
REM  Is %2 a top-level property of the JSON in file %1? Answered by reading
REM  the body as JSON rather than by looking for a word in it: the word
REM  "data" sits in almost every web page, while a "data" ARRAY does not.
REM  A body that is not JSON at all simply says no.
REM ---------------------------------------------------------------------
:json_property
set "_jp_hit="
for /f "usebackq delims=" %%R in (`powershell -NoProfile -Command "try { $j = Get-Content -Raw '%~1' -ErrorAction Stop | ConvertFrom-Json; if ($null -ne $j.%~2) { 'yes' } } catch { }" 2^>nul`) do set "_jp_hit=%%R"
if not defined _jp_hit exit /b 1
exit /b 0

REM ---------------------------------------------------------------------
REM  A port answered - it takes the next free slot. The port number is
REM  remembered as it was FOUND (FreeLLMAPI may sit on 31416 rather than
REM  31415), because the site address, the token and the connector all
REM  carry that exact number.
REM ---------------------------------------------------------------------
:take_slot
set /a SLOTS+=1
set "AI%SLOTS%_PORT=%~1"
set "AI%SLOTS%_NAME=%~2"
set "AI%SLOTS%_BASE=%~3"
set "ANY_PORT_FOUND=1"
call :trace "  port %~1 (%~2) answered, slot %SLOTS% of %MAXSLOTS%, base %~3"
goto :eof

:stop_agent
if defined AGENTPID taskkill /PID %AGENTPID% /F >nul 2>&1
set "AGENTPID="
goto :eof

REM ---------------------------------------------------------------------
REM  Stop every connector we started (every port that was found).
REM ---------------------------------------------------------------------
:cleanup_all
if defined AI1_ADDR call :stop_agent_for_port %AI1_PORT% "%TOKEN%%AI1_PORT%"
if defined AI2_ADDR call :stop_agent_for_port %AI2_PORT% "%TOKEN%%AI2_PORT%"
if defined AI3_ADDR call :stop_agent_for_port %AI3_PORT% "%TOKEN%%AI3_PORT%"
if defined AI4_ADDR call :stop_agent_for_port %AI4_PORT% "%TOKEN%%AI4_PORT%"
call :cleanup
goto :eof

REM ---------------------------------------------------------------------
REM  The doorway for the temporary-link fallback. A tunnel sends its own
REM  domain as the Host header, and some local AI servers (Ollama among
REM  them) answer 403 to anything that is not localhost - so straight
REM  through a tunnel the game would never load a model. This little local
REM  relay takes whatever Host arrives and forwards the request to the real
REM  local AI with a local Host, streaming the answer back untouched. It
REM  knows nothing about models, only about relaying HTTP, which is why one
REM  copy covers every local AI.
REM ---------------------------------------------------------------------
:start_proxy
call :write_script
if not exist "%PS1%" goto :eof
start "aim-proxy" /b powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode relay -ListenPort %PROXYPORT% -TargetPort %PORT% >"%PSERR%" 2>&1
call :trace "  relay process launched, waiting for port %PROXYPORT%"

set /a waits=0
:proxy_wait
ping -n 2 127.0.0.1 >nul
set /a waits+=1
set "PROXYOK="
call :answered "http://127.0.0.1:%PROXYPORT%%SUFFIX%/models" 3
if not errorlevel 1 set "PROXYOK=1"
if defined PROXYOK goto :proxy_ok
if %waits% GEQ 15 goto :eof
goto :proxy_wait
:proxy_ok
call :trace "  relay answered %CODE%, doorway ready"
echo         Ready on port %PROXYPORT% - any local AI can be passed through.
goto :eof

REM ---------------------------------------------------------------------
REM  Put the PowerShell half on disk. The text lives in this file as base64,
REM  because a bat file cannot carry a script block with all its braces and
REM  quotes in one piece without something in the middle eating them. The
REM  plain-text original is tools\StartLocalAI-connector.ps1 in the project.
REM ---------------------------------------------------------------------
:write_script
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
powershell -NoProfile -Command "[IO.File]::WriteAllBytes('%PS1%', [Convert]::FromBase64String(([IO.File]::ReadAllText('%PS1%.b64') -replace '\s','')))" >"%PSERR%" 2>&1
del /q "%PS1%.b64" >nul 2>&1
goto :eof

REM ---------------------------------------------------------------------
REM  Is the link still good? Asking the link itself is the only honest
REM  test: process ids are not to be trusted here (a tunnel service may
REM  hand the session to another process, and a name can match something
REM  unrelated), while a working link always answers the model list.
REM  A miss only counts once the tunnel log has been asked whether the
REM  address simply changed, and three misses in a row end the wait, so
REM  neither one hiccup nor a renamed tunnel closes a window that works.
REM ---------------------------------------------------------------------
:tunnel_alive
call :answered "%URL%%SUFFIX%/models" 15 strict
if not errorlevel 1 (
    set /a misses=0
    goto :alive_yes
)
REM  A dead address does not always mean a dead tunnel. localhost.run
REM  rebuilds its connection and hands out a NEW name, and the old one
REM  stops answering from that moment - so a link that worked fine a
REM  minute ago suddenly gives nothing. Look at the tunnel's own log
REM  before giving up: if the name changed, keep the window and use it.
set "OLDURL=%URL%"
call :refresh_url
if not "%URL%"=="%OLDURL%" (
    call :trace "  tunnel moved to a new address, using %URL%%SUFFIX%"
    echo.
    echo   The tunnel service gave this link a new name. Use this one now:
    echo.
    echo       %URL%%SUFFIX%
    echo.
    call :answered "%URL%%SUFFIX%/models" 15 strict
    if not errorlevel 1 (
        set /a misses=0
        goto :alive_yes
    )
)
set /a misses+=1
if %misses% GEQ 3 (set "TUNNEL_ALIVE=0") else (set "TUNNEL_ALIVE=1")
goto :eof
:alive_yes
set "TUNNEL_ALIVE=1"
goto :eof

REM ---------------------------------------------------------------------
REM  Re-read the address out of the log of the tunnel that is running.
REM  %TUNNELLOG% and %URLPATTERN% are set by the tunnel that won, so this
REM  works the same for every service. Nothing happens when the tunnel
REM  prints no address, which is the normal case while all is well.
REM ---------------------------------------------------------------------
:refresh_url
if not defined TUNNELLOG goto :eof
if not exist "%TUNNELLOG%" goto :eof
set "SAVEDURL=%URL%"
call :grab_url "%TUNNELLOG%" "%URLPATTERN%"
if not defined URL set "URL=%SAVEDURL%"
goto :eof

REM ---------------------------------------------------------------------
REM  Did something answer with an HTTP code at all?
REM
REM  %1 url, %2 timeout, %3 "strict" to refuse 403 as well.
REM
REM  200 is the plain case. 401 is just as good: the server IS there and
REM  only wants a key (LiteLLM Proxy with a master key, FreeLLMAPI,
REM  one-api). The game sends that key itself, so such a server works
REM  exactly like an open one - and a file that walked past it would tell
REM  the user to go and start an AI they already started.
REM
REM  403 counts only right here, on the user's own machine, where nothing
REM  else could have answered. Further down the tunnel it does NOT: a
REM  quick tunnel that is not ready yet also answers 403, so those checks
REM  pass "strict" and keep the 200 test as well.
REM ---------------------------------------------------------------------
:answered
set "CODE="
for /f "usebackq delims=" %%C in (`curl.exe -s -o NUL -m %~2 -w "%%{http_code}" "%~1" 2^>nul`) do set "CODE=%%C"
if "%CODE%"=="200" exit /b 0
if "%CODE%"=="401" exit /b 0
if /i "%~3"=="strict" exit /b 1
if "%CODE%"=="403" exit /b 0
exit /b 1

REM ---------------------------------------------------------------------
REM  Nothing local is running. The AI itself is the user's business: this
REM  file only reads an address that already exists.
REM ---------------------------------------------------------------------
:noport
call :trace "no local AI found on any port"
echo         No local AI answered on this computer, so there is nothing to
echo         connect yet.
echo.
echo         If you DID mean to connect your own local AI (Ollama, LM Studio,
echo         ...), start it first and run this file again; it is found either
echo         way. The usual ports are 11434 (Ollama), 1234/5001 (LM Studio),
echo         8080 (llama.cpp / LocalAI), 8000 (vLLM), 1337 (Jan), 4891
echo         (GPT4All), 5000 (TabbyAPI / text-gen-webui), 4000 (LiteLLM),
echo         3001/31415 (FreeLLMAPI).
echo.
echo         A log of this run was left here:
echo           %TRACE%
echo.
call :cleanup
call :stay
endlocal
exit /b 5

REM ---------------------------------------------------------------------
REM  No website to talk to. Cannot happen with a normal download - the
REM  address is written into the file - and it is here only so that a file
REM  that was edited or truncated still says something plain instead of
REM  carrying on with a half-built address.
REM ---------------------------------------------------------------------
:nosite
call :cleanup
echo         This copy of the file is damaged: the address of the site it
echo         belongs to is missing from it.
echo.
echo         Download the latest StartLocalAI installer from the Settings
echo         page of the site, and run the copy you get there.
echo.
call :trace "no site address"
call :stay
endlocal
REM  A bare "exit", NOT "exit /b": this label is jumped to from inside
REM  "call :resolve_site", and "exit /b" would only RETURN from that call -
REM  the script would carry on with the very address it just declared
REM  broken and start connectors for nothing. "exit" closes the whole
REM  window, which is the only place anything is shown anyway.
exit 4

REM ---------------------------------------------------------------------
REM  The doorway could not be opened.
REM ---------------------------------------------------------------------
:noproxy
call :cleanup
echo         The connector could not start.
echo.
echo         This file needs Windows PowerShell, which comes with Windows.
echo         Close any other copy of this file and run it again.
echo.
if exist "%PSERR%" for /f "usebackq delims=" %%L in ("%PSERR%") do echo         %%L
echo.
echo         A log of this run was left here:
echo           %TRACE%
echo.
call :trace "connector did not start"
call :stay
endlocal
exit /b 3

REM ---------------------------------------------------------------------
REM  No tunnel worked.
REM ---------------------------------------------------------------------
:failed
call :cleanup
echo         Could not open an https link from this network.
echo.
echo         Every connection service was tried. This is usually a network
echo         restriction. Try again later, try another network (or a VPN),
echo         or use the AI Horde / Model API source on the site instead.
echo.
echo         Logs of this run were left here:
echo           %TRACE%
echo           %CFLOG%
echo           %SSHLOG%
echo           %SVELOG%
echo           %NGLOG%
echo.
call :trace "no tunnel service produced a working link"
call :stay
endlocal
exit /b 2

REM ---------------------------------------------------------------------
REM  One netstat call, then only the ports that are actually listening get
REM  asked over HTTP. This exists because a closed local port does not refuse
REM  instantly here - the SYN goes nowhere and curl waits out its whole -m,
REM  which made every port below the live one cost 2 seconds x 2 requests.
REM
REM  netstat is asked once instead of once per port. The result is kept in a
REM  file rather than in a variable because the number is the part that is
REM  awkward in batch: it sits after the LAST colon of the local address, and
REM  that address has three shapes (0.0.0.0:port, 127.0.0.1:port and
REM  [::1]:port), so pulling it out by position is not worth the trouble.
REM  Instead the port is looked for as ":port" followed by the column padding,
REM  which is the one form all three shapes share.
REM
REM  LISTEN is left UNSET if the list cannot be trusted, and then every port
REM  is probed exactly as before. That is the whole safety net: a netstat
REM  this file cannot read - an unusual Windows that words the state
REM  differently, or a netstat that is not there - costs the old one minute,
REM  never a wrong "no local AI found".
REM ---------------------------------------------------------------------
:listen_set
set "LISTEN="
netstat -ano -p tcp 2>nul | findstr /c:"LISTENING" >"%LISFILE%"
if not exist "%LISFILE%" goto :eof
REM  A readable list of nothing but "no LISTENING line was understood" must
REM  not be read as "nothing is listening", so the state word itself is
REM  what has to be there before the list is believed.
findstr /c:"LISTENING" "%LISFILE%" >nul 2>&1
if errorlevel 1 (
    del /q "%LISFILE%" >nul 2>&1
    goto :eof
)
set "LISTEN=1"
call :trace "  listening ports read from netstat, dead ports will be skipped"
goto :eof

REM ---------------------------------------------------------------------
REM  Tunnel 1: Cloudflare quick tunnel. No account, no install.
REM ---------------------------------------------------------------------
:try_cloudflare
set "CFUSE="
where cloudflared >nul 2>&1
if not errorlevel 1 set "CFUSE=cloudflared"
if defined CFUSE goto :cf_launch
if exist "%TEMP%\aim\cloudflared.exe" goto :cf_launch
echo         Trying Cloudflare ^(first run, about 50 MB download^)...
set "CFDL=amd64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "CFDL=arm64"
if not exist "%TEMP%\aim" md "%TEMP%\aim" >nul 2>&1
curl.exe -sL -m 300 -o "%TEMP%\aim\cloudflared.exe" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-%CFDL%.exe" 2>nul
if not exist "%TEMP%\aim\cloudflared.exe" goto :eof
:cf_launch
echo         Trying Cloudflare...
set "TUNNELLOG=%CFLOG%"
set "URLPATTERN=trycloudflare.com"
if exist "%CFLOG%" del /q "%CFLOG%" >nul 2>&1
REM  --protocol http2 is not a preference, it is the difference between
REM  working and not working on many networks. By default cloudflared
REM  reaches Cloudflare over QUIC (UDP 443), and where that is blocked or
REM  throttled it never manages to register. HTTP/2 travels over ordinary
REM  TCP 443, which is almost never blocked, and the same command then
REM  registers once and stays up. Verified here: 0 errors, 8 polls out of
REM  8 answered, against a local server that asks for a key.
if defined CFUSE goto :cf_run
start "aim-tunnel" /b "%TEMP%\aim\cloudflared.exe" tunnel --url "http://127.0.0.1:%PROXYPORT%" --no-autoupdate --protocol http2 > "%CFLOG%" 2>&1
goto :cf_pid
:cf_run
start "aim-tunnel" /b cloudflared tunnel --url "http://127.0.0.1:%PROXYPORT%" --no-autoupdate --protocol http2 > "%CFLOG%" 2>&1
:cf_pid
call :capture_pid cloudflared
set /a tries=0
:wait_cf
ping -n 2 127.0.0.1 >nul
set /a tries+=1
call :grab_url "%CFLOG%" "trycloudflare.com"
if defined URL goto :verify_link
REM  Cloudflare earns the patience. Its quick tunnel keeps the SAME name for
REM  the whole session, while the free localhost.run fallback changes its
REM  name whenever it reconnects. A slow start here costs the user a
REM  copy/paste mid-game later, so a minute of waiting is the cheaper trade.
if %tries% GEQ 30 goto :eof
goto :wait_cf

REM ---------------------------------------------------------------------
REM  Tunnel 2: localhost.run over the SSH client Windows already has.
REM ---------------------------------------------------------------------
:try_ssh
echo         Trying localhost.run ^(a free one, its link can change^)...
set "TUNNELLOG=%SSHLOG%"
set "URLPATTERN=.lhr.life"
where ssh >nul 2>&1
if errorlevel 1 goto :eof
if exist "%SSHLOG%" del /q "%SSHLOG%" >nul 2>&1
start "aim-tunnel" /b ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -R 80:127.0.0.1:%PROXYPORT% nokey@localhost.run > "%SSHLOG%" 2>&1
call :capture_pid ssh
set /a tries=0
:wait_ssh
ping -n 2 127.0.0.1 >nul
set /a tries+=1
call :grab_url "%SSHLOG%" ".lhr.life"
if defined URL goto :verify_link
if %tries% GEQ 8 goto :eof
goto :wait_ssh

REM ---------------------------------------------------------------------
REM  Tunnel 3: serveo.net, same idea as localhost.run.
REM ---------------------------------------------------------------------
:try_serveo
echo         Trying serveo.net...
set "TUNNELLOG=%SVELOG%"
set "URLPATTERN=.serveo"
where ssh >nul 2>&1
if errorlevel 1 goto :eof
if exist "%SVELOG%" del /q "%SVELOG%" >nul 2>&1
start "aim-tunnel" /b ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -R 80:127.0.0.1:%PROXYPORT% serveo.net > "%SVELOG%" 2>&1
call :capture_pid ssh
set /a tries=0
:wait_serveo
ping -n 2 127.0.0.1 >nul
set /a tries+=1
call :grab_url "%SVELOG%" ".serveousercontent.com"
if defined URL goto :verify_link
call :grab_url "%SVELOG%" ".serveo.net"
if defined URL goto :verify_link
if %tries% GEQ 8 goto :eof
goto :wait_serveo

REM ---------------------------------------------------------------------
REM  Tunnel 4: ngrok, only if the user already installed it.
REM ---------------------------------------------------------------------
:try_ngrok
REM  No log is read back for ngrok: its log also holds documentation and
REM  dashboard addresses, so a name taken from it later could be the wrong
REM  one. The tunnel simply stays as it is.
set "TUNNELLOG="
set "URLPATTERN="
where ngrok >nul 2>&1
if errorlevel 1 goto :eof
echo         Trying ngrok...
if exist "%NGLOG%" del /q "%NGLOG%" >nul 2>&1
start "aim-tunnel" /b ngrok http %PROXYPORT% --log=stdout > "%NGLOG%" 2>&1
call :capture_pid ngrok
set /a tries=0
:wait_ngrok
ping -n 2 127.0.0.1 >nul
set /a tries+=1
for /f "tokens=2 delims=:,  " %%U in ('curl.exe -s -m 5 http://127.0.0.1:4040/api/tunnels ^| findstr /c:"public_url"') do set "URL=%%U"
if defined URL goto :verify_link
if %tries% GEQ 6 goto :eof
goto :wait_ngrok

REM ---------------------------------------------------------------------
REM  Pull the address out of a tunnel log. A tunnel log is full of other
REM  addresses (documentation, dashboards), so only a word that both starts
REM  with https:// and carries this tunnel's own domain is taken, and
REM  anything printed after it (colour codes, punctuation) is cut off.
REM ---------------------------------------------------------------------
:grab_url
REM  The LAST address in the file is the one that counts. localhost.run
REM  hands out a name, then hands out another one when its connection is
REM  rebuilt, and the old name is dead from that moment on. Taking the
REM  first match therefore keeps a link that can never answer again, and
REM  the window closes a couple of minutes later with nothing wrong on
REM  this side. The same guard is cheap for the other tunnels too.
if not exist "%~1" goto :eof
for /f "usebackq delims=" %%U in (`powershell -NoProfile -Command "$m=[regex]::Matches((Get-Content -Raw '%~1' -ErrorAction SilentlyContinue), 'https://[a-zA-Z0-9.-]+%~2'); if ($m.Count -gt 0) { $m[$m.Count-1].Value }"`) do set "URL=%%U"
goto :eof

REM ---------------------------------------------------------------------
REM  A link is only accepted when the model list really comes back through
REM  it. A tunnel that answers 403 or 503 is useless, so the next is tried -
REM  but a fresh tunnel often needs a moment, so the same link gets a few
REM  chances first. 401 is accepted: that is the local AI asking for its key
REM  and the game answering it.
REM ---------------------------------------------------------------------
:verify_link
set /a vtry=0
:verify_again
set /a vtry+=1
call :verify
if defined URL goto :eof
if %vtry% GEQ 3 goto :verify_out
ping -n 3 127.0.0.1 >nul
goto :verify_again
:verify_out
call :stop_tunnel
goto :eof

:verify
call :answered "%URL%%SUFFIX%/models" 20 strict
if errorlevel 1 set "URL="
goto :eof

REM ---------------------------------------------------------------------
REM  Remember which process the tunnel is, so only that one is stopped.
REM  The id is looked up by the command line, not by process name alone:
REM  the user may well have their own ssh session or tunnel open, and
REM  those must survive this file closing.
REM ---------------------------------------------------------------------
:capture_pid
set "TUNNEL_PID="
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq '%~1.exe' -and $_.CommandLine -like '*%PROXYPORT%*' } | Select-Object -First 1 -ExpandProperty ProcessId" 2^>nul`) do set "TUNNEL_PID=%%P"
if not defined TUNNEL_PID goto :eof
echo %TUNNEL_PID%>"%PIDFILE%"
goto :eof

:stop_tunnel
call :kill_from "%PIDFILE%"
call :kill_tunnels
REM  Give the killed process a moment to let go of its log file.
ping -n 2 127.0.0.1 >nul
goto :eof

REM ---------------------------------------------------------------------
REM  Stop every tunnel this file started, including the ones left behind by
REM  a service that was tried and rejected. Only processes whose own command
REM  line points at our own doorway port are touched, so a tunnel or an ssh
REM  session of the user's own is never killed - a broad "kill all ssh"
REM  would be both rude and wrong.
REM ---------------------------------------------------------------------
:kill_tunnels
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'cloudflared.exe' -or $_.Name -eq 'ssh.exe' -or $_.Name -eq 'ngrok.exe' } | Where-Object { $_.CommandLine -like '*127.0.0.1:%PROXYPORT%*' } | ForEach-Object { $_.ProcessId }" 2^>nul`) do taskkill /PID %%P /F >nul 2>&1
goto :eof

REM ---------------------------------------------------------------------
REM  Stop what this file started: the connector, the tunnel and the doorway.
REM  The user's own AI is never touched - this file did not start it.
REM ---------------------------------------------------------------------
:cleanup
call :stop_agent
call :kill_from "%PIDFILE%"
call :kill_tunnels
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /r /c:"127.0.0.1:%PROXYPORT% .*LISTENING"') do taskkill /PID %%P /F >nul 2>&1
del /q "%PS1%" "%PS1%.b64" "%PSERR%" "%CFLOG%" "%SSHLOG%" "%SVELOG%" "%NGLOG%" "%LISFILE%" "%TEMP%\aim-probe-%RUNID%.json" >nul 2>&1
goto :eof

:kill_from
if not exist "%~1" goto :eof
set /p KILL_PID=<"%~1"
if defined KILL_PID taskkill /PID %KILL_PID% /F >nul 2>&1
del /q "%~1" >nul 2>&1
set "KILL_PID="
goto :eof