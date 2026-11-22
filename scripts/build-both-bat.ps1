# Regenerates wwwroot\downloads\StartImage+Chat-v1.1.16.bat from its sources:
#
#   tools\StartLocalAI-connector.ps1    the WebSocket half, kept readable
#   tools\StartLocalBothWorkers.ps1     starts BOTH Python workers from one
#                                       shared Python setup
#   tools\local-chat-worker.py          the chat relay itself
#   tools\local-image-worker.py         the image worker itself
#   tools\StartImage+Chat.bat.in        the batch shell, with @@..._B64@@ markers
#
# Same generator shape as build-imagegenerator-bat.ps1 and for the same reason:
# batch cannot carry a PowerShell or Python script block with its braces and
# quotes intact, so all four scripts travel inside the .bat as base64. The
# readable files are the source of truth and this script is the only thing that
# writes the .bat.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-both-bat.ps1
#
# It also checks its own work: each base64 block that ends up in the .bat is
# decoded again and compared byte for byte with its source. A truncated or
# mangled block is the one failure here that would otherwise only show up on a
# player's machine, as a file that starts one worker or none.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

# Split a base64 string into a batch block of `>"<var>.b64" echo <line>` lines.
# The first line truncates the file, the rest append: base64 tolerates the
# newlines being removed again before decoding.
function New-Base64Block {
    param(
        [byte[]]$Bytes,
        [string]$Var      # e.g. '%PS1%' -> writes "%PS1%.b64"
    )

    $base64 = [Convert]::ToBase64String($Bytes)

    # 76 characters a line: short enough that no line approaches cmd's limit,
    # long enough that the file stays a sensible size.
    $width = 76
    $lines = for ($offset = 0; $offset -lt $base64.Length; $offset += $width) {
        $base64.Substring($offset, [Math]::Min($width, $base64.Length - $offset))
    }

    $block = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $redirection = if ($i -eq 0) { '>' } else { '>>' }
        $block.Add("$redirection`"$Var.b64`" echo $($lines[$i])")
    }
    return ,$block
}

# A .ps1 has to carry a byte-order mark. Windows PowerShell 5.1 reads a .ps1
# that has no BOM as the system ANSI code page, so every non-ASCII character in a
# comment would arrive as a different one - harmless in a comment, but the day
# one lands inside a string the file stops parsing. The .py workers must NOT have
# a BOM: Python rejects one in a UTF-8 source file.
function Get-TextBytesWithBom {
    param([string]$Path)

    $text = [IO.File]::ReadAllText($Path)
    $text = $text -replace "`r`n", "`n"
    $text = $text -replace "`n", "`r`n"
    return [Text.Encoding]::UTF8.GetBytes([char]0xFEFF + $text)
}

$template = Join-Path $root 'tools\StartImage+Chat.bat.in'
$target = Join-Path $root 'wwwroot\downloads\StartImage+Chat-v1.1.16.bat'

if (-not (Test-Path -LiteralPath $template)) { throw "Missing template: $template" }

# Each entry: the marker to replace, the readable source, the batch variable
# whose value + ".b64" receives the block, and whether the bytes need a BOM.
$sources = @(
    @{ Marker = '@@CONNECTOR_B64@@';   Source = 'tools\StartLocalAI-connector.ps1';  Var = '%PS1%';       Bom = $true },
    @{ Marker = '@@WORKERS_B64@@';     Source = 'tools\StartLocalBothWorkers.ps1';   Var = '%WORKERPS1%'; Bom = $true },
    @{ Marker = '@@CHATWORKER_B64@@';  Source = 'tools\local-chat-worker.py';        Var = '%CHATPY%';    Bom = $false },
    @{ Marker = '@@IMAGEWORKER_B64@@'; Source = 'tools\local-image-worker.py';       Var = '%IMAGEPY%';   Bom = $false }
)

foreach ($s in $sources) {
    $path = Join-Path $root $s.Source
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing source file: $path" }
    if ($s.Bom) {
        $s.Bytes = Get-TextBytesWithBom -Path $path
    } else {
        $s.Bytes = [IO.File]::ReadAllBytes($path)
    }
}

$body = [IO.File]::ReadAllText($template)

foreach ($s in $sources) {
    $count = ([regex]::Matches($body, [regex]::Escape($s.Marker))).Count
    if ($count -ne 1) {
        throw "The template must contain $($s.Marker) exactly once, found $count."
    }
    $block = New-Base64Block -Bytes $s.Bytes -Var $s.Var
    $body = $body -replace [regex]::Escape($s.Marker), ($block -join "`r`n")
    $s.Lines = $block
}

# The .bat is served as a download, so it must survive being a text file
# everywhere on the way. Anything outside ASCII is refused here rather than
# turning into a mojibake line in the middle of a batch file.
$nonAscii = [regex]::Matches($body, '[^\x00-\x7F]')
if ($nonAscii.Count -gt 0) {
    $first = $nonAscii[0].Index
    $around = $body.Substring([Math]::Max(0, $first - 40), 80)
    throw "StartImage+Chat-v1.1.16.bat would not be plain ASCII, near: $around"
}

$body = $body -replace "`r`n", "`n"
$body = $body -replace "`n", "`r`n"

[IO.File]::WriteAllText($target, $body, (New-Object Text.UTF8Encoding($false)))

# The self-check: pull each base64 block back out of the file just written and
# decode it. This is what makes running this script a promise rather than a hope.
$written = [IO.File]::ReadAllText($target)

foreach ($s in $sources) {
    $pattern = '(?m)^>>?"' + [regex]::Escape($s.Var + '.b64') + '" echo (\S+)\r?$'
    $found = [regex]::Matches($written, $pattern)
    if ($found.Count -ne $s.Lines.Count) {
        throw "Wrote $($s.Source) with $($found.Count) base64 lines, expected $($s.Lines.Count)."
    }

    $joined = ($found | ForEach-Object { $_.Groups[1].Value }) -join ''
    $decoded = [Convert]::FromBase64String($joined)

    if ($decoded.Length -ne $s.Bytes.Length) {
        throw "$($s.Source): embedded script decodes to $($decoded.Length) bytes, expected $($s.Bytes.Length)."
    }
    for ($i = 0; $i -lt $s.Bytes.Length; $i++) {
        if ($decoded[$i] -ne $s.Bytes[$i]) {
            throw "$($s.Source): embedded script differs from the source at byte $i."
        }
    }
}

$bytes = (Get-Item -LiteralPath $target).Length
Write-Output ("wrote {0}" -f $target)
Write-Output ("  batch file  {0:N0} bytes, {1} lines" -f $bytes, ($written -split "`n").Count)
foreach ($s in $sources) {
    Write-Output ("  {0,-32} {1,7:N0} bytes in {2,4} base64 lines, round trip verified" -f $s.Source, $s.Bytes.Length, $s.Lines.Count)
}
