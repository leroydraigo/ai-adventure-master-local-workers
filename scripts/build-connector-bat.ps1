# Regenerates wwwroot\downloads\StartLocalAI-v1.5.3.bat from its two sources:
#
#   tools\StartLocalAI-connector.ps1   the PowerShell half, kept readable
#   tools\StartLocalAI.bat.in          the batch shell, with @@BASE64@@ in it
#
# Why a generator instead of editing the .bat directly: the PowerShell half has
# to travel inside the .bat as base64, because batch cannot carry a script block
# with its braces and quotes intact - the shell eats them. Re-typing ~500 lines
# of base64 by hand is how that file drifts out of sync with the code it claims
# to contain, and a player then runs a version that is one release behind with
# no way to tell. So the readable file is the source of truth and this script is
# the only thing that writes the .bat.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-connector-bat.ps1
#
# It also checks its own work: the base64 that ends up in the .bat is decoded
# again and compared byte for byte with the source. A truncated or mangled block
# is the one failure here that would otherwise only show up on a player's
# machine, as a connector that does nothing.

#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-connector-bat.ps1
#
# It builds ONE download from a source pair:
#
#   StartLocalAI-v1.5.3.bat    <- StartLocalAI-connector.ps1 + StartLocalAI.bat.in
#                                the local-AI connector (scans for a running model)
#
# It also checks its own work: the base64 that ends up in the .bat is decoded
# again and compared byte for byte with the source. A truncated or mangled block
# is the one failure here that would otherwise only show up on a player's
# machine, as a connector that does nothing.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

# One build: readable .ps1 + template with @@BASE64@@ -> a plain-ASCII .bat,
# then a byte-for-byte round-trip check of the embedded script.
function Build-Bat {
    param(
        [string]$ConnectorName,   # tools\<name>.ps1
        [string]$TemplateName,    # tools\<name>.bat.in
        [string]$TargetName       # wwwroot\downloads\<name>
    )

    $source = Join-Path $root ("tools\" + $ConnectorName)
    $template = Join-Path $root ("tools\" + $TemplateName)
    $target = Join-Path $root ("wwwroot\downloads\" + $TargetName)

    foreach ($path in @($source, $template)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing source file: $path" }
    }

    # A byte-order mark in front of the decoded script. Windows PowerShell 5.1
    # reads a .ps1 that has no BOM as the system ANSI code page, so every em dash
    # in a comment would arrive as a different character - harmless in a comment,
    # but the day one lands inside a string the file stops parsing.
    $text = [IO.File]::ReadAllText($source)
    $text = $text -replace "`r`n", "`n"
    $text = $text -replace "`n", "`r`n"
    $expected = [Text.Encoding]::UTF8.GetBytes([char]0xFEFF + $text)

    $marker = '@@BASE64@@'
    $body = [IO.File]::ReadAllText($template)

    $markerCount = ([regex]::Matches($body, [regex]::Escape($marker))).Count
    if ($markerCount -ne 1) {
        throw "The template must contain $marker exactly once, found $markerCount."
    }

    $base64 = [Convert]::ToBase64String($expected)

    # 76 characters a line: short enough that no line approaches cmd's limit,
    # long enough that the file stays a sensible size.
    $width = 76
    $lines = for ($offset = 0; $offset -lt $base64.Length; $offset += $width) {
        $base64.Substring($offset, [Math]::Min($width, $base64.Length - $offset))
    }

    $block = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # The first line truncates the file, the rest append: base64 tolerates the
        # newlines being removed again before decoding.
        $redirection = if ($i -eq 0) { '>' } else { '>>' }
        $block.Add("$redirection`"%PS1%.b64`" echo $($lines[$i])")
    }

    $bat = $body -replace [regex]::Escape($marker), ($block -join "`r`n")

    # The .bat is served as a download, so it must survive being a text file
    # everywhere on the way. Anything outside ASCII is refused here rather than
    # turning into a mojibake line in the middle of a batch file.
    $nonAscii = [regex]::Matches($bat, '[^\x00-\x7F]')
    if ($nonAscii.Count -gt 0) {
        $first = $nonAscii[0].Index
        $around = $bat.Substring([Math]::Max(0, $first - 40), 80)
        throw "$TargetName would not be plain ASCII, near: $around"
    }

    $bat = $bat -replace "`r`n", "`n"
    $bat = $bat -replace "`n", "`r`n"

    [IO.File]::WriteAllText($target, $bat, (New-Object Text.UTF8Encoding($false)))

    # The self-check: pull the base64 back out of the file just written and decode
    # it. This is what makes running this script a promise rather than a hope.
    $written = [IO.File]::ReadAllText($target)
    $found = [regex]::Matches($written, '(?m)^>>?"%PS1%\.b64" echo (\S+)\r?$')
    if ($found.Count -ne $lines.Count) {
        throw "Wrote $TargetName with $($found.Count) base64 lines, expected $($lines.Count)."
    }

    $joined = ($found | ForEach-Object { $_.Groups[1].Value }) -join ''
    $decoded = [Convert]::FromBase64String($joined)

    if ($decoded.Length -ne $expected.Length) {
        throw "$TargetName : embedded script decodes to $($decoded.Length) bytes, expected $($expected.Length)."
    }

    for ($i = 0; $i -lt $expected.Length; $i++) {
        if ($decoded[$i] -ne $expected[$i]) {
            throw "$TargetName : embedded script differs from the source at byte $i."
        }
    }

    Write-Output ("wrote {0}" -f $target)
    Write-Output ("  batch file  {0:N0} bytes, {1} lines" -f (Get-Item -LiteralPath $target).Length, ($written -split "`n").Count)
    Write-Output ("  script      {0:N0} bytes in {1} base64 lines, round trip verified" -f $expected.Length, $lines.Count)
}

Build-Bat -ConnectorName 'StartLocalAI-connector.ps1' -TemplateName 'StartLocalAI.bat.in' -TargetName 'StartLocalAI-v1.5.3.bat'