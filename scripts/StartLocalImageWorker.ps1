# Local image worker for agent-based image offload
# Listens on http://127.0.0.1:8002 and draws through imagefree.net's JSON API
#
# No Python on the PC is not a dead end: a known-good interpreter is looked for
# first, and if none is found a portable Python 3.12 is downloaded once into
# this folder and used from there. Nothing is installed system-wide and the
# player never has to visit python.org.

param(
    [int]$Port = 8002
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$workerPy = Join-Path $scriptDir 'local-image-worker.py'
$venvDir = Join-Path $scriptDir '.venv-imageworker'
$pythonExe = Join-Path $venvDir 'Scripts\python.exe'
$embeddedDir = Join-Path $scriptDir 'python-embedded'
$embeddedExe = Join-Path $embeddedDir 'python.exe'
$getPipScript = Join-Path $scriptDir 'get-pip.py'

# The fallback downloads from python.org and bootstrap.pypa.io. Windows
# PowerShell 5.1 on an unpatched system may still offer only TLS 1.0, which both
# hosts refuse, and that would look like "no internet" in the log.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Every line also lands in a file, because the setup window now closes by
# itself (that is the point of this script). If something fails, StartImageGenerator
# points the player at this log so a vanished window never hides the reason.
$logFile = Join-Path $scriptDir 'image-worker.log'

function Say {
    param([string]$Message)
    $line = ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
    try { [Console]::Out.WriteLine($line); [Console]::Out.Flush() } catch { }
    try { Add-Content -LiteralPath $logFile -Value $line -ErrorAction SilentlyContinue } catch { }
}

# Log any terminating error (a throw, or a failing venv/pip step) and exit
# non-zero so StartImageGenerator reports a failure instead of closing silently.
trap {
    Say ("ERROR: {0}" -f $_)
    exit 1
}

Say "Local image worker starting..."
Say "Port: $Port"
Say "Python script: $workerPy"

if (-not (Test-Path -LiteralPath $workerPy)) {
    throw "Missing $workerPy"
}

# Closing the installer window does not kill the hidden Python child. Re-running
# the installer must therefore stop the previous worker first, otherwise the new
# process fails to bind $Port and the site keeps talking to the OLD script.
Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^python(w)?\.exe$' -and $_.CommandLine -and
    ($_.CommandLine -like ('*' + $workerPy + '*') -or
     $_.CommandLine -like '*AIAdventureMaster*local-*-worker.py*')
} | ForEach-Object {
    Say "Stopping previous worker pid $($_.ProcessId)"
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}
Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique |
    Where-Object { $_ -gt 0 } | ForEach-Object {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$_" -ErrorAction SilentlyContinue
        if ($proc -and $proc.Name -match '^python(w)?\.exe$' -and $proc.CommandLine -like '*AIAdventureMaster*') {
            Say "Freeing port $Port from pid $_"
            Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
        }
    }

# ---------------------------------------------------------------------------
# Pick an interpreter. This worker needs no browser for imagefree text, but a
# brand-new Python (3.14+) can still lack binary wheels for the transitive deps
# of fastapi/uvicorn and force a doomed source build. Prefer a known-good
# 3.11-3.13 interpreter and refuse anything newer with a readable reason; if
# there is no usable one at all, fetch a portable copy below.
$supportedMin = 11
$supportedMax = 13

# The probes below are questions, not commands that must succeed. With the
# script-wide $ErrorActionPreference='Stop' a native command's stderr becomes a
# terminating error before a probe can run, so every probe goes through this
# helper: it relaxes the preference for the call, swallows stderr, and returns
# the tool's first line of stdout or $null.
function Invoke-Quiet {
    param([scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return (& $Command 2>$null | Select-Object -First 1)
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prev
    }
}

# Same relaxation, but for commands whose exit code is the answer. get-pip and
# pip both write warnings to stderr (the Scripts folder is not on PATH, wheels
# are being downloaded), and under 'Stop' PowerShell 5.1 raises a terminating
# NativeCommandError for that before $LASTEXITCODE can be read.
function Invoke-Native {
    param([scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command *> $null
        return $LASTEXITCODE
    } catch {
        return 1
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-PyVersion {
    param([string]$Exe)
    $v = Invoke-Quiet { & $Exe -c "import sys; print('%d.%d' % sys.version_info[:2])" }
    if ($v -is [string] -and $v.Trim() -match '^(\d+)\.(\d+)$') {
        # major*100 + minor: Python 3.12 is 312, Python 3.15 is 315.
        return ([int]$Matches[1] * 100 + [int]$Matches[2])
    }
    return 0
}

function Test-PySupported {
    param([int]$Version)
    # Only a 3.x interpreter is targeted, so Python 2.7 (207) or 4.0 (400) is
    # refused outright rather than passing the minor-only bounds by accident.
    if ($Version -lt 300 -or $Version -ge 400) { return $false }
    $minor = $Version % 100
    return ($minor -ge $supportedMin -and $minor -le $supportedMax)
}

$pyCmd = $null
$useEmbedded = $false

# 1. The py launcher's known-good versions, newest first.
$pyLauncher = $null
try { $pyLauncher = (Get-Command py -ErrorAction SilentlyContinue).Source } catch { }
if ($pyLauncher) {
    foreach ($v in @('3.13', '3.12', '3.11')) {
        $exe = Invoke-Quiet { & py "-$v" -c "import sys; print(sys.executable)" }
        if (-not $exe) { continue }
        $exe = ([string]$exe).Trim()
        if ($exe -and (Test-Path -LiteralPath $exe)) { $pyCmd = $exe; break }
    }
}

# 2. Whatever "python" resolves to, if its version is supported.
if (-not $pyCmd) {
    $plain = $null
    try { $plain = (Get-Command python -ErrorAction SilentlyContinue).Source } catch { }
    if ($plain) {
        $ver = Get-PyVersion -Exe $plain
        if (Test-PySupported -Version $ver) {
            $pyCmd = $plain
        } else {
            Say ("Python at $plain reports {0}.{1}, which is newer than this worker's tools support." -f [int]($ver / 100), ($ver % 100))
        }
    }
}

# 3. Nothing usable on PATH: download the embeddable build once. It is a normal
#    zip, needs no installer, no admin rights and no PATH changes - it lives in
#    this folder and is only used by this worker.
if (-not $pyCmd) {
    $pyVersion = '3.12.8'
    $embedUrl = "https://www.python.org/ftp/python/$pyVersion/python-$pyVersion-embed-amd64.zip"
    $zipPath = Join-Path $scriptDir 'python-embed.zip'

    if (-not (Test-Path -LiteralPath $embeddedExe)) {
        Say "Python $supportedMin-$supportedMax not found on this PC."
        Say "Downloading portable Python $pyVersion once (~11 MB)..."
        try {
            $client = New-Object System.Net.WebClient
            $client.DownloadFile($embedUrl, $zipPath)
        } catch {
            throw "Failed to download Python: $($_.Exception.Message)"
        }
        Say "Extracting embedded Python..."
        Expand-Archive -Path $zipPath -DestinationPath $embeddedDir -Force
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }

    # The embeddable build ships with site disabled in pythonXY._pth, so a
    # package installed next to it cannot be imported - not even pip. Turn site
    # on once and add Lib\site-packages, which is where get-pip installs.
    $pth = Get-ChildItem -LiteralPath $embeddedDir -Filter 'python*._pth' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pth) { throw "Embedded Python is missing its ._pth file: $embeddedDir" }
    $pthText = [IO.File]::ReadAllText($pth.FullName)
    if ($pthText -notmatch '(?m)^\s*import\s+site\s*$') {
        $pthText = $pthText -replace '(?m)^\s*#\s*import\s+site\s*$', 'import site'
        if ($pthText -notmatch '(?m)^\s*import\s+site\s*$') {
            $pthText = $pthText.TrimEnd() + "`r`nimport site`r`n"
        }
        if ($pthText -notmatch '(?m)^\s*Lib\\site-packages\s*$') {
            $pthText = $pthText.TrimEnd() + "`r`nLib\site-packages`r`n"
        }
        [IO.File]::WriteAllText($pth.FullName, $pthText, (New-Object Text.ASCIIEncoding))
    }

    # pip is not part of the embeddable build either, so bootstrap it once. The
    # check makes later runs (and a half-finished earlier one) cheap.
    if ((Invoke-Native { & $embeddedExe -c "import pip" }) -ne 0) {
        if (-not (Test-Path -LiteralPath $getPipScript)) {
            Say "Downloading pip installer..."
            try {
                $client = New-Object System.Net.WebClient
                $client.DownloadFile('https://bootstrap.pypa.io/get-pip.py', $getPipScript)
            } catch {
                throw "Failed to download get-pip.py: $($_.Exception.Message)"
            }
        }
        Say "Installing pip into embedded Python..."
        $rc = Invoke-Native { & $embeddedExe $getPipScript --no-warn-script-location }
        if ($rc -ne 0) { throw "pip install into embedded Python failed (exit $rc)" }
    }

    $pyCmd = $embeddedExe
    $useEmbedded = $true
    Say "Using embedded Python: $pyCmd"
}

Say "Using Python: $pyCmd"

if ($useEmbedded) {
    # The embeddable build has no venv module, and pip installs into that tree
    # directly, so there is no virtualenv to create or repair here.
    $pythonExe = $embeddedExe
    Say "Using the embedded Python directly (no virtualenv)."
} else {
    # Rebuild the venv when it was made by an unsupported Python (a previous
    # failed run leaves exactly that behind, and reusing it would fail the same
    # way).
    $venvUsable = $false
    if (Test-Path -LiteralPath $pythonExe) {
        $venvUsable = Test-PySupported -Version (Get-PyVersion -Exe $pythonExe)
    }
    if (-not $venvUsable) {
        if (Test-Path -LiteralPath $venvDir) {
            Say "Rebuilding the virtualenv with a supported Python..."
            Remove-Item -LiteralPath $venvDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Say "Creating virtualenv..."
        }
        & $pyCmd -m venv $venvDir
        if ($LASTEXITCODE -ne 0) { throw "venv creation failed" }
    }
}

# ---------------------------------------------------------------------------
# Install only what is actually missing. This runs on every launch, so a second
# (and hundredth) run must start in seconds. Importing every required module at
# once answers it: a non-zero exit means at least one is absent and the wheels
# must be fetched.
if ((Invoke-Native { & $pythonExe -c "import httpx, fastapi, uvicorn" }) -eq 0) {
    Say "Python dependencies already present."
} else {
    Say "Installing dependencies (httpx, fastapi, uvicorn)..."
    # A failed pip self-upgrade is not fatal: the install below is what matters.
    [void](Invoke-Native { & $pythonExe -m pip install --disable-pip-version-check --upgrade pip })
    $rc = Invoke-Native { & $pythonExe -m pip install --disable-pip-version-check "httpx" "fastapi" "uvicorn[standard]" }
    if ($rc -ne 0) { throw "pip install failed (exit $rc)" }
}

# Start worker
$env:IMAGE_WORKER_PORT = $Port
Say "Starting uvicorn on http://127.0.0.1:$Port..."
Start-Process -FilePath $pythonExe -ArgumentList ('"' + $workerPy + '"') -WindowStyle Hidden
# The worker now runs in the background on its own. This setup window has done
# its job, so it closes by itself - the player keeps only the FIRST window
# (StartImageGenerator) open. Closing it does not stop the hidden child; the
# cleanup step at the top of every launch does.
Say "Worker is running in the background. This window will now close."
exit 0
