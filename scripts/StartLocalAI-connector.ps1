# The PowerShell half of StartLocalAI.bat.
#
# It is kept here as a plain file and the .bat carries a base64 copy of it, so
# that changing this text does not mean re-typing 98 lines of base64 into a
# batch file by hand. Run tools/build-connector-bat.ps1 to regenerate it.
#
# One script, two jobs, because both are "talk to the local AI":
#
#   -Mode agent  the normal one. Opens an OUTGOING WebSocket to the site and
#                waits for it to send work. This is what gives the player an
#                address that never changes: https://<site>/ai/<token>/v1
#                belongs to the site, survives every restart, and needs nothing
#                open on the player's router, because the connection is made
#                from here to there and not the other way round.
#
#   -Mode relay  the older behaviour, kept as a fallback. Listens on a local
#                port and pumps HTTP through to the local AI with a local Host
#                header, so that an external tunnel (Cloudflare and friends) can
#                point at it. Still needed because a tunnel sends its own domain
#                as Host, and several local AIs (Ollama among them) answer 403 to
#                anything that is not localhost.
#
# Agent mode can also hand this file offloaded work for Free AI: image
# generation (-Image) and free text completions (-Chat), each on its own local
# worker port. Without those switches the agent only serves the local AI.
#
# Why the tunnel is no longer the main path: free tunnel addresses are random
# and short-lived. Measured on the test machine, 27 of 38 localhost.run runs
# ended with "tunnel activity timeout" and 29 printed a different domain
# mid-run, so the player had to paste a new link every single time. Cloudflare
# Quick Tunnels keep a name for the session, but officially refuse
# Server-Sent Events - and this game streams every reply it shows.

param(
    [ValidateSet('agent', 'relay')]
    [string]$Mode = 'agent',
    # The site to dial, e.g. https://the.site. http://localhost:5000 also works
    # and is what the acceptance checks use.
    [string]$Site = '',
    # The credential: 32 random bytes in base64url, invented on the player's
    # own computer on the first run and never sent anywhere but this site.
    [string]$Token = '',
    [int]$TargetPort = 11434,
    # 'ROOT' when the local AI serves /models at the root, '/v1' when it serves
    # /v1/models. The public address always ends in /v1 (that is what the
    # game's Endpoint field expects), so the two are not the same thing, and
    # the site sends paths with that /v1 already taken off.
    [string]$BasePath = '/v1',
    [int]$ListenPort = 11500,
    # Announce image-generation capability: route free-image jobs
    # to this machine so they run client-side.
    [switch]$Image,
    [int]$ImagePort = 8002,
    # Announce free-gateway text-chat capability: route the free AI's text
    # completions to this machine's chat worker so they leave from THIS
    # machine's IP instead of the site's shared pool. No Camoufox: tryingopen
    # text has no Turnstile, so it is a plain relay. Ignored unless -Chat.
    [switch]$Chat,
    [int]$ChatPort = 8003
)

# ---------------------------------------------------------------------------
# Relay mode: a tiny HTTP relay in front of the local AI, for the tunnel
# fallback. It rewrites Host to a local one and passes everything else through.
# ---------------------------------------------------------------------------
if ($Mode -eq 'relay') {
    # Three things it must get right, all learned the hard way:
    #
    #  * Concurrency. The browser sends a chat request that streams for many
    #    seconds. A relay that handles one connection at a time cannot answer
    #    the connector's own liveness check while that runs, so the connector
    #    thinks the link died and kills the tunnel mid-answer.
    #  * Streaming. The site asks for stream:true and reads the answer as it
    #    arrives. The reply body must be copied byte for byte as it comes, with
    #    its transfer encoding untouched - otherwise the browser's fetch rejects
    #    and the user only sees "Failed to fetch".
    #  * CORS. The page comes from the site and the model from a tunnel domain,
    #    so every reply needs CORS headers and OPTIONS has to be answered.

    # One connection is served in its own runspace, so a long streaming answer
    # never blocks the connector's health check. Everything the handler needs is
    # therefore inside this one script block.
    $Handler = {
        param($Client, $TargetPort)

        $ErrorActionPreference = 'Stop'

        function Read-Head {
            param([System.IO.Stream]$Stream)

            $buffer = New-Object byte[] 16384
            $acc = New-Object byte[] 16384
            $len = 0
            $end = -1

            while ($true) {
                $n = $Stream.Read($buffer, 0, $buffer.Length)
                if ($n -le 0) { break }
                if ($len + $n -gt $acc.Length) {
                    $acc = New-Object byte[] ([Math]::Max($acc.Length * 2, $len + $n))
                }
                [Array]::Copy($buffer, 0, $acc, $len, $n)
                $len += $n

                $text = [Text.Encoding]::ASCII.GetString($acc, 0, $len)
                $end = $text.IndexOf("`r`n`r`n")
                if ($end -ge 0) { break }
            }

            if ($end -lt 0) {
                return [pscustomobject]@{ Head = ''; Rest = (New-Object byte[] 0) }
            }

            $rest = New-Object byte[] ([Math]::Max($len - $end - 4, 0))
            if ($rest.Length -gt 0) { [Array]::Copy($acc, $end + 4, $rest, 0, $rest.Length) }

            return [pscustomobject]@{
                Head = [Text.Encoding]::ASCII.GetString($acc, 0, $end + 4)
                Rest = $rest
            }
        }

        function Build-Head {
            param($Head, $Drop, $Replace, $Add)

            $lines = $Head -split "`r`n"
            $out = New-Object System.Collections.Generic.List[string]
            [void]$out.Add($lines[0])

            for ($i = 1; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ([string]::IsNullOrWhiteSpace($line)) { continue }

                $name = ($line -split ':', 2)[0].Trim()
                if ($Drop -contains $name) { continue }
                if ($Replace.ContainsKey($name)) { [void]$out.Add($Replace[$name]); continue }

                [void]$out.Add($line)
            }

            if ($Add) { foreach ($a in $Add) { [void]$out.Add($a) } }

            return ($out -join "`r`n") + "`r`n`r`n"
        }

        $Cors = @(
            'Access-Control-Allow-Origin: *',
            'Access-Control-Allow-Methods: GET, POST, OPTIONS',
            'Access-Control-Allow-Headers: *',
            'Access-Control-Max-Age: 86400'
        )

        $upstream = $null
        try {
            $Client.NoDelay = $true
            $down = $Client.GetStream()

            $incoming = Read-Head -Stream $down
            if ([string]::IsNullOrWhiteSpace($incoming.Head)) { return }

            $requestLine = ($incoming.Head -split "`r`n")[0]

            # The CORS preflight carries no body and needs no model, so answer it
            # here instead of spending a round trip on the local AI.
            if ($requestLine -match '^OPTIONS\s') {
                $head = Build-Head "HTTP/1.1 204 No Content`r`n`r`n" @() @{} ($Cors + @('Connection: close'))
                $bytes = [Text.Encoding]::ASCII.GetBytes($head)
                $down.Write($bytes, 0, $bytes.Length)
                $down.Flush()
                return
            }

            $upstream = New-Object System.Net.Sockets.TcpClient
            $upstream.NoDelay = $true
            $upstream.Connect('127.0.0.1', $TargetPort)
            $up = $upstream.GetStream()

            # Origin and Referer are dropped on purpose. Ollama (and several other
            # local servers) answer 403 to a request carrying a web origin they
            # do not know, before the browser ever sees it - which showed up as
            # "Failed to fetch" with no error anywhere. The browser does not need
            # them either: this relay answers the preflight itself and puts the
            # CORS headers on every reply, so the local AI never learns that the
            # caller was a web page.
            $requestHead = Build-Head $incoming.Head `
                @('Connection', 'Proxy-Connection', 'Origin', 'Referer') `
                @{ 'Host' = "Host: 127.0.0.1:$TargetPort" } @('Connection: close')

            $headBytes = [Text.Encoding]::ASCII.GetBytes($requestHead)
            $up.Write($headBytes, 0, $headBytes.Length)
            $up.Flush()

            # The request body usually arrives in later reads than the headers,
            # so whatever came with them is only part of it. Sending just that
            # would leave the local AI waiting for the rest of the prompt until
            # the socket broke - so the body is forwarded by Content-Length.
            $contentLength = 0
            foreach ($line in ($incoming.Head -split "`r`n")) {
                if ($line -match '^\s*Content-Length:\s*(\d+)\s*$') { $contentLength = [int]$Matches[1] }
            }

            $sent = 0
            if ($incoming.Rest.Length -gt 0) {
                $up.Write($incoming.Rest, 0, $incoming.Rest.Length)
                $sent = $incoming.Rest.Length
            }
            $up.Flush()

            if ($contentLength -gt $sent) {
                $need = $contentLength - $sent
                while ($need -gt 0) {
                    $want = [int][Math]::Min(65536, $need)
                    $chunk = New-Object byte[] $want
                    $got = $down.Read($chunk, 0, $want)
                    if ($got -le 0) { break }
                    $up.Write($chunk, 0, $got)
                    $need -= $got
                }
                $up.Flush()
            }

            $response = Read-Head -Stream $up
            if ([string]::IsNullOrWhiteSpace($response.Head)) { return }

            # The transfer encoding is left exactly as it arrived: the body below
            # is copied raw, so rewriting chunked framing here would corrupt the
            # stream the browser is reading.
            $responseHead = Build-Head $response.Head @('Connection', 'Proxy-Connection') `
                @{} ($Cors + @('Connection: close'))

            $outBytes = [Text.Encoding]::ASCII.GetBytes($responseHead)
            $down.Write($outBytes, 0, $outBytes.Length)
            if ($response.Rest.Length -gt 0) { $down.Write($response.Rest, 0, $response.Rest.Length) }
            $down.Flush()

            $buffer = New-Object byte[] 16384
            while ($true) {
                $n = $up.Read($buffer, 0, $buffer.Length)
                if ($n -le 0) { break }
                $down.Write($buffer, 0, $n)
                $down.Flush()
            }
        }
        catch {
            # Across a tunnel a closed socket is all the browser ever sees, so
            # say something instead of failing in silence.
            try {
                $down = $Client.GetStream()
                $msg = [Text.Encoding]::ASCII.GetBytes(
                    "HTTP/1.1 502 Bad Gateway`r`nAccess-Control-Allow-Origin: *`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                $down.Write($msg, 0, $msg.Length)
                $down.Flush()
            }
            catch { }
        }
        finally {
            if ($upstream) { $upstream.Close() }
            $Client.Close()
        }
    }

    $HandlerText = $Handler.ToString()

    $pool = [runspacefactory]::CreateRunspacePool(1, 16)
    $pool.Open()

    $listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $ListenPort)
    $listener.Start()
    Write-Output "listening $ListenPort -> $TargetPort"

    $jobs = New-Object System.Collections.ArrayList

    while ($true) {
        $client = $listener.AcceptTcpClient()

        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($HandlerText).AddArgument($client).AddArgument($TargetPort)
        $handle = $ps.BeginInvoke()
        [void]$jobs.Add(@{ PS = $ps; Handle = $handle })

        for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
            if (-not $jobs[$i].Handle.IsCompleted) { continue }
            try { $jobs[$i].Handle.EndInvoke($jobs[$i].Handle) } catch { }
            $jobs[$i].PS.Dispose()
            $jobs.RemoveAt($i)
        }
    }
}

# ===========================================================================
# Agent mode
# ===========================================================================

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 still offers TLS 1.0 on some systems, and a site that
# only speaks TLS 1.2+ would be unreachable - with a bare "the request was
# aborted" instead of anything a player could act on.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Say {
    param([string]$Message)

    # The parentheses are not decoration. The comma operator binds looser than
    # -f, so without them this parses as "format the first argument, then make
    # an array of two" and every line the player should read fails with a
    # FormatError instead of being printed.
    try {
        [Console]::Out.WriteLine(("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message))
        [Console]::Out.Flush()
    }
    catch {
        # A log line is never worth taking the connector down over.
    }
}

# A frame is a one-line JSON object. ConvertTo-Json escapes everything outside
# plain ASCII, so no header or token can accidentally break the line, and one
# frame per line keeps the other end's reader trivial.
function New-Frame {
    param([string]$Type, [long]$Id = 0, $Extra)

    $frame = [ordered]@{ t = $Type }
    if ($Id -gt 0) { $frame['id'] = $Id }
    if ($Extra) { foreach ($key in $Extra.Keys) { $frame[$key] = $Extra[$key] } }
    return ($frame | ConvertTo-Json -Depth 6 -Compress)
}

function Send-Frame {
    param($Socket, [string]$Frame)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Frame)
    $segment = New-Object System.ArraySegment[byte] (,$bytes)
    # [void]: SendAsync returns Task<VoidTaskResult>, and without it every
    # sent frame is echoed into the console as "System.Threading.Tasks.VoidTaskResult".
    [void]$Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $connect.Token).GetAwaiter().GetResult()
}

# ---------------------------------------------------------------------------
# The worker: one local HTTP request, streamed back as frames.
#
# It runs in its own runspace so a reply that takes minutes cannot stop the
# socket from being read. Everything it needs is handed over as an argument, and
# what it produces goes into the shared outbox that the socket thread drains.
# New-Frame is prepended to the worker text because a runspace has no access to
# the functions of the one that started it.
# ---------------------------------------------------------------------------
$Worker = {
    param($Id, $Method, $Path, $Headers, $Body, $Queue, $Live, $TargetPort, $Prefix)

    $ErrorActionPreference = 'Stop'

    # New-Frame lives INSIDE the worker, not beside it. A runspace has no access
    # to the functions of the runspace that started it, so it has to travel with
    # the text - but it cannot be prepended to it either: "param" has to be the
    # very first thing in a script, and prepending puts a function in front of
    # it, which PowerShell refuses with "param is not recognized". Hence here,
    # after the parameters and before anything that uses it.
    function New-Frame {
        param([string]$Type, [long]$Id = 0, $Extra)

        $frame = [ordered]@{ t = $Type }
        if ($Id -gt 0) { $frame['id'] = $Id }
        if ($Extra) { foreach ($key in $Extra.Keys) { $frame[$key] = $Extra[$key] } }
        return ($frame | ConvertTo-Json -Depth 6 -Compress)
    }

    function Push-Chunk {
        param([byte[]]$Bytes)

        $part = New-Object byte[] $Bytes.Length
        [Array]::Copy($Bytes, 0, $part, 0, $Bytes.Length)
        $Queue.Enqueue((New-Frame 'chunk' $Id @{ data = [Convert]::ToBase64String($part) }))
    }

    $request = $null
    $response = $null

    try {
        $authorization = $null
        $accept = $null
        $contentType = $null
        $textProvider = $null
        if ($null -ne $Headers) {
            if ($Headers.PSObject.Properties['Authorization']) { $authorization = $Headers.Authorization }
            if ($Headers.PSObject.Properties['Accept']) { $accept = $Headers.Accept }
            if ($Headers.PSObject.Properties['Content-Type']) { $contentType = $Headers.'Content-Type' }
            # The free-chat worker chooses its upstream adapter from this header
            # (deepseek / tryingopen); it is meaningless to a local model, so it
            # is forwarded only when the site sent one.
            if ($Headers.PSObject.Properties['X-Text-Provider']) { $textProvider = [string]$Headers.'X-Text-Provider' }
        }

        # $Prefix arrives as '/v1' and $Path as '/models', so joining them with
        # a slash would ask the local AI for '/v1//models'. Ollama answers that
        # with 404, and a 404 from the local model is a confusing thing to see
        # when the game asked for something perfectly ordinary. One slash.
        $localPath = "$Prefix/$Path" -replace '/{2,}', '/'
        if (-not $TargetPort -or $TargetPort -le 0) {
            throw 'No local AI is configured on this computer.'
        }
        $uri = "http://127.0.0.1:$TargetPort$localPath"

        # HttpWebRequest rather than a raw socket, because it handles the header
        # parsing and the chunked decoding for us. That matters: the site writes
        # what arrives straight onto a fresh HTTP response of its own, so a
        # transfer-encoding header surviving in the raw bytes would corrupt it.
        # It also sets Host to 127.0.0.1 by itself, which is exactly what Ollama
        # and friends insist on, and sends no Origin or Referer at all - the
        # caller is a WebSocket, not a web page.
        $request = [Net.HttpWebRequest]::Create($uri)
        $request.Method = $Method
        $request.AllowAutoRedirect = $false
        $request.UserAgent = 'aim-connector'
        $request.ProtocolVersion = [Net.HttpVersion]::Version11
        # Not a limit on the whole generation: the reply is read in a loop below
        # and may take as long as the model needs. This only covers getting the
        # connection and the first byte of the answer.
        $request.Timeout = 300000
        $request.ReadWriteTimeout = 300000

        if ($authorization) { $request.Headers['Authorization'] = $authorization }
        if ($accept) { $request.Accept = $accept }
        if ($textProvider) { $request.Headers['X-Text-Provider'] = $textProvider }

        if ($Body -and $Body.Length -gt 0) {
            $bytes = [byte[]]$Body
            $request.ContentLength = $bytes.Length
            if ($contentType) { $request.ContentType = $contentType }
            $out = $request.GetRequestStream()
            $out.Write($bytes, 0, $bytes.Length)
            $out.Flush()
            $out.Close()
        }

        # Registered before the call, so that a "cancel" arriving while the model
        # is still thinking can abort it. Otherwise a player who pressed Stop
        # would still be paying for a full generation nobody will read.
        $Live.TryAdd($Id, $request)

        $response = $request.GetResponse()
        $Queue.Enqueue((New-Frame 'res' $Id @{
            status  = [int]$response.StatusCode
            headers = @{ 'Content-Type' = [string]$response.ContentType }
        }))

        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 65536
        while ($true) {
            try {
                $n = $stream.Read($buffer, 0, $buffer.Length)
            }
            catch [System.IO.IOException] {
                break
            }
            if ($n -le 0) { break }
            $slice = New-Object byte[] $n
            [Array]::Copy($buffer, 0, $slice, 0, $n)
            Push-Chunk $slice
        }
        $stream.Close()

        $Queue.Enqueue((New-Frame 'end' $Id))
    }
    catch [System.Net.WebException] {
        # An HTTP error status is NOT a failure here. A router that wants an API
        # key answers 401, and the game wants that 401 with its body, because
        # that is the answer it knows how to explain to the player.
        # A cancel aborts the request from the outside, and that surfaces as a
        # WebException with no response attached. Reporting it as "cannot reach
        # the local AI" would blame the player's setup for their own Stop press,
        # so cancellation is recognised here and passed over in silence - the
        # site already knows about it, it is the one that sent the cancel.
        $aborted = ($_.Exception.Status -eq 'RequestCanceled') -or ($_.Exception.Status -eq 'Aborted')

        $errorResponse = $_.Exception.Response
        if ($null -ne $errorResponse) {
            try {
                $Queue.Enqueue((New-Frame 'res' $Id @{
                    status  = [int]$errorResponse.StatusCode
                    headers = @{ 'Content-Type' = [string]$errorResponse.ContentType }
                }))
                $errorStream = $errorResponse.GetResponseStream()
                $errorBuffer = New-Object byte[] 65536
                while ($true) {
                    try {
                        $n = $errorStream.Read($errorBuffer, 0, $errorBuffer.Length)
                    }
                    catch [System.IO.IOException] {
                        break
                    }
                    if ($n -le 0) { break }
                    $eslice = New-Object byte[] $n
                    [Array]::Copy($errorBuffer, 0, $eslice, 0, $n)
                    Push-Chunk $eslice
                }
                $errorStream.Close()
                $Queue.Enqueue((New-Frame 'end' $Id))
            }
            catch {
                $Queue.Enqueue((New-Frame 'err' $Id @{ message = $_.Exception.Message }))
            }
        }
        elseif (-not $aborted) {
            # No response at all: the local AI is not running, or refused the
            # connection. This is the message the player can act on.
            $Queue.Enqueue((New-Frame 'err' $Id @{ message = "Cannot reach the local AI on port $TargetPort." }))
        }
    }
    catch [System.Threading.ThreadInterruptedException] {
    }
    catch [System.OperationCanceledException] {
        # Aborted on purpose, because the player pressed Stop.
    }
    catch {
        $Queue.Enqueue((New-Frame 'err' $Id @{ message = $_.Exception.Message }))
    }
    finally {
        $Live.TryRemove($Id, $null)
        if ($response) { try { $response.Close() } catch { } }
        if ($request) { try { $request.Abort() } catch { } }
    }
}

$WorkerText = $Worker.ToString()

# A path that reads well in the log and in the frame: '/v1' or ''.
$prefix = ''
if ($BasePath -ne 'ROOT') { $prefix = '/' + $BasePath.Trim('/') }

$pool = [runspacefactory]::CreateRunspacePool(1, 8)
$pool.Open()

# Shared between the socket thread and the workers: a queue because several
# workers finish at once, a dictionary so a "cancel" frame can find the request
# it belongs to. Built here so every runspace holds the SAME objects.
$outbox = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$live = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[int,object]'
$workers = New-Object System.Collections.ArrayList

function Start-Worker {
    param([long]$Id, [string]$Method, [string]$Path, $Headers, $Body,
          [int]$Port = 0, [string]$PathPrefix = $prefix)

    # $Port can be handed explicitly (the image/chat branches pass their worker
    # ports) or left at 0 to mean "the detected AI port".
    if ($Port -le 0) { $Port = $TargetPort }

    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($WorkerText).
        AddArgument($Id).AddArgument($Method).AddArgument($Path).AddArgument($Headers).
        AddArgument($Body).AddArgument($outbox).AddArgument($live).
        AddArgument($Port).AddArgument($PathPrefix)
    [void]$workers.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
}

# One incoming frame, one action. Anything unrecognised is ignored on purpose:
# the other end may be a newer build that sends frame types this one has never
# heard of, and a chat in progress must not die over that.
function Handle-Incoming {
    param([string]$Text)

    try { $frame = ConvertFrom-Json $Text } catch { return }
    if ($null -eq $frame -or $null -eq $frame.t) { return }

    switch ($frame.t) {
        'ping' {
            $outbox.Enqueue((New-Frame 'pong'))
        }
        'req' {
            $bytes = $null
            if ($frame.body) { $bytes = [Convert]::FromBase64String([string]$frame.body) }
            if (([string]$frame.kind) -eq 'image') {
                Start-Worker ([long]$frame.id) ([string]$frame.method) ([string]$frame.path) $frame.headers $bytes $ImagePort ''
            }
            elseif (([string]$frame.kind) -eq 'chat') {
                Start-Worker ([long]$frame.id) ([string]$frame.method) ([string]$frame.path) $frame.headers $bytes $ChatPort ''
            }
            else {
                Start-Worker ([long]$frame.id) ([string]$frame.method) ([string]$frame.path) $frame.headers $bytes
            }
        }
        'cancel' {
            # The site is no longer reading this answer: it was a Stop button, a
            # closed tab, or a request that hit a limit. Abort the local call so
            # the GPU stops working on a reply nobody will see.
            if ($live.ContainsKey([int]$frame.id)) {
                try { $live[[int]$frame.id].Abort() } catch { }
            }
        }
        'pong' {
        }
        default {
        }
    }
}

# http:// has to become ws:// and https:// wss://. ClientWebSocket refuses a
# plain http address outright, so without this every http:// site - including a
# developer's own machine, and the acceptance run - fails at once with an
# "invalid URI" that says nothing about the cause.
$hostAndPath = $Site -replace '^(?i)https?://', ''
$scheme = if ($Site -match '^(?i)https://') { 'wss' } else { 'ws' }
$endpoint = ('{0}://{1}/ai-agent?v=1&t={2}' -f $scheme, $hostAndPath, $Token)
if ($TargetPort -gt 0) {
    Say "agent starting: site $Site, local AI on port $TargetPort$prefix"
}
else {
    Say "agent starting: site $Site, no local AI (offloaded work only)"
}
if ($Image.IsPresent) {
    Say "image offload on: image generation jobs go to local worker on port $ImagePort"
}
if ($Chat.IsPresent) {
    Say "chat offload on: the free AI's text completions go to local worker on port $ChatPort"
}

# ---------------------------------------------------------------------------
# "Connect automatically": the loopback token door.
#
# The Settings page on THIS computer reads the connector token straight from
# this window, so nobody has to copy an address out of a console and paste it
# into a field. The file answers one request on 127.0.0.1 (loopback only,
# never the network) on one of the ports below, and the page scans that exact
# range. A loopback address is special to browsers: an https page may fetch it
# (potentially trustworthy, so no mixed-content block), yet the call arrives
# with the page's Origin — and the token is only ever revealed to an origin
# that IS this site (the one this file was downloaded from) or another
# loopback page (the player's own machine). The secret never rides in a header
# or a URL, only in the body of this one path.
#
# The agent connector owns 11510-11513. 11500 is deliberately skipped — it
# is PROXYPORT, the relay-mode doorway.
#
# The image generator ships this same file with -Image and is skipped here on
# purpose: its token is not a local-model address and must never be offered to
# the Settings page as one. This is the only gate the flag gets.
# ---------------------------------------------------------------------------

# The JSON the page reads. kind says which Settings field the address belongs
# to; the page rebuilds https://<site>/ai/<token>/v1 from site+token, byte for
# byte the address the console prints.
$infoPayload = ConvertTo-Json -Compress -InputObject @{
    ok    = $true
    kind  = 'agent'
    site  = $Site
    token = $Token
}

# The one non-loopback origin allowed to read the token: scheme + host (+ port,
# when the site uses a non-default one; Uri.Port fills default ports in and a
# browser's Origin omits them, so both sides meet in the middle).
$infoSiteUri = $null
$infoSiteScheme = ''
$infoSiteHost = ''
$infoSitePort = -1
if ([Uri]::TryCreate($Site, [UriKind]::Absolute, [ref]$infoSiteUri) -and $infoSiteUri.Scheme -match '^(?i)https?$') {
    $infoSiteScheme = $infoSiteUri.Scheme.ToLowerInvariant()
    $infoSiteHost = $infoSiteUri.Host.ToLowerInvariant()
    $infoSitePort = $infoSiteUri.Port
}

# One connection, one short answer. It runs in its own runspace so the agent
# loop below is never blocked by a slow or hostile local request; everything
# it needs arrives as an argument, because a runspace has no access to the
# variables of the one that started it.
$InfoHandler = {
    param($Client, $Payload, $AllowedScheme, $AllowedHost, $AllowedPort)

    $ErrorActionPreference = 'Stop'

    function Read-Head {
        param([System.IO.Stream]$Stream)

        $buffer = New-Object byte[] 16384
        $acc = New-Object byte[] 16384
        $len = 0

        while ($true) {
            $n = $Stream.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { break }
            if ($len + $n -gt $acc.Length) {
                $acc = New-Object byte[] ([Math]::Max($acc.Length * 2, $len + $n))
            }
            [Array]::Copy($buffer, 0, $acc, $len, $n)
            $len += $n
            if ([Text.Encoding]::ASCII.GetString($acc, 0, $len).IndexOf("`r`n`r`n") -ge 0) { break }
        }

        return [Text.Encoding]::ASCII.GetString($acc, 0, $len)
    }

    function Send-Reply {
        param([string]$Status, [string]$Body, [string]$Origin)

        $bodyBytes = New-Object byte[] 0
        if ($Body) { $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body) }

        $head = New-Object System.Collections.Generic.List[string]
        [void]$head.Add("HTTP/1.1 $Status")
        [void]$head.Add('Connection: close')
        [void]$head.Add('Cache-Control: no-store')
        [void]$head.Add('Access-Control-Allow-Methods: GET, OPTIONS')
        [void]$head.Add('Access-Control-Allow-Headers: *')
        # Chrome's local-network preflight insists on this explicit nod before
        # it lets a page fetched from a public site call a loopback address at
        # all. Sent on every answer, the refusal included, so the objection
        # cannot be mistaken for its own failure.
        [void]$head.Add('Access-Control-Allow-Private-Network: true')
        [void]$head.Add('Access-Control-Max-Age: 600')
        if ($Origin) {
            # The origin is echoed, never granted as '*': the body carries the
            # token, so a page may read it only after the Origin check below
            # has proved who the caller is. A foreign page gets no ACAO and
            # cannot read a single byte of the answer.
            [void]$head.Add("Access-Control-Allow-Origin: $Origin")
            [void]$head.Add('Vary: Origin')
        }
        if ($bodyBytes.Length -gt 0) { [void]$head.Add('Content-Type: application/json; charset=utf-8') }
        [void]$head.Add("Content-Length: $($bodyBytes.Length)")
        [void]$head.Add('')

        $down = $Client.GetStream()
        # A join on the trailing empty line leaves one \r\n at the end; HTTP
        # marks the header's end with two (\r\n\r\n), so one more is appended.
        $headBytes = [Text.Encoding]::ASCII.GetBytes(($head -join "`r`n") + "`r`n")
        $down.Write($headBytes, 0, $headBytes.Length)
        if ($bodyBytes.Length -gt 0) { $down.Write($bodyBytes, 0, $bodyBytes.Length) }
        $down.Flush()
    }

    # Who may read the token: pages served from this very site, any loopback
    # page (the player's own machine — dev server, another tab), and callers
    # with no Origin at all (local tools like curl; the token lies in plaintext
    # files on this machine anyway, so that is not a leak).
    function Origin-Allows([string]$Origin) {
        if ([string]::IsNullOrWhiteSpace($Origin)) { return $true }
        $o = $null
        if (-not [Uri]::TryCreate($Origin, [UriKind]::Absolute, [ref]$o)) { return $false }
        if ($o.Scheme -notmatch '^(?i)https?$') { return $false }
        if ($o.Host.ToLowerInvariant() -in @('localhost', '127.0.0.1', '[::1]')) { return $true }
        if (-not $AllowedScheme) { return $false }
        if ($o.Scheme.ToLowerInvariant() -ne $AllowedScheme) { return $false }
        if ($o.Host.ToLowerInvariant() -ne $AllowedHost) { return $false }
        if ($o.Port -ne $AllowedPort) { return $false }
        return $true
    }

    try {
        $Client.NoDelay = $true
        $raw = Read-Head -Stream $Client.GetStream()
        if ([string]::IsNullOrWhiteSpace($raw)) { return }

        $lines = $raw -split "`r`n"
        if ($lines[0] -notmatch '^(GET|OPTIONS)\s+(\S+)\s+HTTP/1\.[01]$') { return }
        $method = $Matches[1]
        $path = ($Matches[2] -split '\?')[0]

        # Only this one path ever answers; everything else gets the connection
        # closed without a byte, so a port scan of the range learns nothing.
        if ($path -ne '/aim/connector') { return }

        $origin = ''
        foreach ($line in $lines) {
            if ($line -match '^Origin:\s*(\S+)') { $origin = $Matches[1].Trim(); break }
        }
        $allowed = Origin-Allows $origin

        if ($method -eq 'OPTIONS') {
            # The preflight (CORS, and Chrome's private-network preflight)
            # carries no body and needs only the headers above. A refused
            # origin is closed without a grant, exactly like a GET.
            if ($allowed) { Send-Reply '204 No Content' '' $origin }
            return
        }

        if (-not $allowed) {
            Send-Reply '403 Forbidden' '{"error":"refused"}' $origin
            return
        }

        Send-Reply '200 OK' $Payload $origin
    }
    catch { }
    finally { try { $Client.Close() } catch { } }
}

$InfoHandlerText = $InfoHandler.ToString()

if (-not $Image.IsPresent) {
    # The first free port of the range is taken; the page scans the whole
    # range, so the exact port is its business, not ours. A port held by some
    # other program is a skip, not a failure.
    $infoPorts = 11510..11513
    $infoListener = $null
    foreach ($p in $infoPorts) {
        $trial = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $p)
        try {
            $trial.Start()
            $infoListener = $trial
            break
        }
        catch {
            try { $trial.Stop() } catch { }
        }
    }

    if ($null -ne $infoListener) {
        $InfoLoop = {
            param($Listener, $HandlerText, $Payload, $AllowedScheme, $AllowedHost, $AllowedPort)

            # A tiny pool so two page scans cannot block each other; per
            # connection one short-lived command, answered and closed.
            $pool = [runspacefactory]::CreateRunspacePool(1, 8)
            $pool.Open()
            try {
                while ($true) {
                    $client = $Listener.AcceptTcpClient()
                    $ps = [powershell]::Create()
                    $ps.RunspacePool = $pool
                    [void]$ps.AddScript($HandlerText).
                        AddArgument($client).AddArgument($Payload).
                        AddArgument($AllowedScheme).AddArgument($AllowedHost).AddArgument($AllowedPort)
                    [void]$ps.BeginInvoke()
                }
            }
            catch { }
        }

        $infoRun = [runspacefactory]::CreateRunspace()
        $infoRun.Open()
        $infoPs = [powershell]::Create()
        $infoPs.Runspace = $infoRun
        [void]$infoPs.AddScript($InfoLoop).
            AddArgument($infoListener).AddArgument($InfoHandlerText).AddArgument($infoPayload).
            AddArgument($infoSiteScheme).AddArgument($infoSiteHost).AddArgument($infoSitePort)
        [void]$infoPs.BeginInvoke()
        Say "connect automatically: the site's Settings page finds this window by itself - nothing to type in"
    }
}

$attempt = 0
while ($true) {
    $attempt++
    $socket = $null
    $connect = New-Object System.Threading.CancellationTokenSource
    $workers = New-Object System.Collections.ArrayList

    try {
        $buffer = New-Object byte[] 65536
        $segment = New-Object System.ArraySegment[byte] (,$buffer)
        $partial = New-Object System.Collections.Generic.List[byte]

        $socket = New-Object System.Net.WebSockets.ClientWebSocket
        # Protocol-level keep-alive, so a NAT that quietly drops an idle
        # connection is noticed within a minute instead of at the next request.
        $socket.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)

        # A deadline for the handshake only. It is switched off straight after,
        # because the same token then has to survive the whole session - a
        # receive loop that dies on its own deadline would drop the player out
        # of a chat every twenty seconds.
        $connect.CancelAfter(20000)
        $socket.ConnectAsync([Uri]$endpoint, $connect.Token).GetAwaiter().GetResult()
        $connect.CancelAfter([Threading.Timeout]::Infinite)
        Say "connected to $Site"

        Send-Frame $socket (New-Frame 'hello' 0 @{
            port     = $TargetPort
            basePath = $prefix
            needsKey = $false
            image    = [bool]$Image
            chat     = [bool]$Chat
            chatPort = [int]$ChatPort
        })

        # Exactly one receive in flight at a time, and never waited on: while it
        # is pending this loop sends whatever the workers produced. That is what
        # lets a long streaming reply and the next request travel over the same
        # socket at the same time.
        $receiveTask = $socket.ReceiveAsync($segment, $connect.Token)
        $running = $true

        while ($running) {
            if ($receiveTask.IsCompleted) {
                $result = $receiveTask.GetAwaiter().GetResult()
                if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }

                if ($result.Count -gt 0) {
                    $chunk = New-Object byte[] $result.Count
                    [Array]::Copy($buffer, 0, $chunk, 0, $result.Count)
                    $partial.AddRange($chunk)
                }

                if ($result.EndOfMessage) {
                    Handle-Incoming ([Text.Encoding]::UTF8.GetString($partial.ToArray()))
                    $partial.Clear()
                }

                $receiveTask = $socket.ReceiveAsync($segment, $connect.Token)
            }
            else {
                $frame = $null
                while ($outbox.TryDequeue([ref]$frame)) { Send-Frame $socket $frame }

                # Retire finished workers. Their output went into the outbox as
                # it was produced, so nothing of theirs is read here.
                for ($i = $workers.Count - 1; $i -ge 0; $i--) {
                    if (-not $workers[$i].Handle.IsCompleted) { continue }
                    try { $workers[$i].Handle.EndInvoke($workers[$i].Handle) } catch { }
                    $workers[$i].PS.Dispose()
                    $workers.RemoveAt($i)
                }

                Start-Sleep -Milliseconds 20
            }
        }
    }
    catch {
        # ConnectAsync reports failures wrapped, and the inner message is the
        # one that says whether this was a refused connection, a wrong token, or
        # the site being down.
        $reason = $_.Exception
        while ($reason.InnerException) { $reason = $reason.InnerException }
        Say ("connection lost: " + $reason.Message)
    }
    finally {
        # Stop any generation still running for this socket: the site is not
        # there to receive it, and a busy GPU for nobody is a waste.
        foreach ($pair in $live) { if ($pair.Value) { try { $pair.Value.Abort() } catch { } } }
        foreach ($job in $workers) {
            try { $job.PS.Stop() } catch { }
            try { $job.PS.Dispose() } catch { }
        }

        try { $connect.Cancel() } catch { }
        try { $connect.Dispose() } catch { }
        if ($socket) { try { $socket.Abort() } catch { } try { $socket.Dispose() } catch { } }
    }

    # Reconnect forever. The address the player pasted into Settings does not
    # contain this socket, so nothing they typed has to change - which is the
    # entire point of doing it this way.
    $pause = [Math]::Min(30, 2 + $attempt * 2)
    Say "reconnecting in $pause second(s)"
    Start-Sleep -Seconds $pause
}