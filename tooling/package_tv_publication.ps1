[CmdletBinding()]
param(
    [string]$OutputName = 'YurichConnect-TV-publication-v1.0.128-tv.20261003.1.zip',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = '1.0.128-tv.20261003.1'
$apkName = "YurichConnect-TV-arm-v$version.apk"
$expectedApkHash = 'fe2325e85b71a2244c84581cadedbb7893e9e94358773f595a5b393de8682291'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-PngInfo([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 33 -or $bytes.Length -gt 16MB) {
        throw "Invalid publication image size: $Path"
    }
    if ([System.BitConverter]::ToString($bytes, 0, 8) -ne '89-50-4E-47-0D-0A-1A-0A') {
        throw "Not a PNG: $Path"
    }
    $allowedChunks = @('IHDR', 'PLTE', 'IDAT', 'IEND', 'cHRM', 'gAMA', 'sRGB', 'pHYs', 'tRNS', 'sBIT', 'iCCP', 'caBX')
    $position = 8
    $width = 0
    $height = 0
    $hasImageData = $false
    $hasEnd = $false
    while ($position + 12 -le $bytes.Length) {
        $length = [long]$bytes[$position] * 16777216 + [long]$bytes[$position + 1] * 65536 +
            [long]$bytes[$position + 2] * 256 + [long]$bytes[$position + 3]
        $type = [System.Text.Encoding]::ASCII.GetString($bytes, $position + 4, 4)
        if ($length + $position + 12 -gt $bytes.Length) { throw "Truncated PNG: $Path" }
        if ($type -notin $allowedChunks) {
            throw "Unreviewed PNG metadata/chunk '$type': $Path"
        }
        if ($type -eq 'caBX') {
            # Preserve reviewed C2PA provenance, but reject source ingredients or private markers.
            $metadata = [System.Text.Encoding]::UTF8.GetString($bytes, $position + 8, [int]$length)
            $privateMarkers = '(?i)(c2pa\.ingredient|GPSLatitude|GPSLongitude|GPSPosition|photo_2026|13\.12\.2027|' +
                'plus-dns\.tech|connect\.yurichconnect\.ru|vless://|hy2://|hysteria2://|naive\+https://|' +
                '[a-z]:[\\/](Users|Downloads|Pictures|Yurich Connect)[\\/])'
            if (-not $metadata.Contains('c2pa.claim.v2') -or $metadata -match $privateMarkers) {
                throw "C2PA metadata needs manual privacy review: $Path"
            }
        }
        if ($type -eq 'IHDR') {
            if ($position -ne 8 -or $length -ne 13) { throw "Invalid PNG header: $Path" }
            $width = [long]$bytes[$position + 8] * 16777216 + [long]$bytes[$position + 9] * 65536 +
                [long]$bytes[$position + 10] * 256 + [long]$bytes[$position + 11]
            $height = [long]$bytes[$position + 12] * 16777216 + [long]$bytes[$position + 13] * 65536 +
                [long]$bytes[$position + 14] * 256 + [long]$bytes[$position + 15]
        }
        if ($type -eq 'IDAT') { $hasImageData = $true }
        $position += [int]$length + 12
        if ($type -eq 'IEND') {
            if ($length -ne 0) { throw "Invalid PNG end: $Path" }
            $hasEnd = $true
            break
        }
    }
    if (-not $hasImageData -or -not $hasEnd -or $position -ne $bytes.Length -or
        $width -le $height -or $width -gt 10000 -or $height -lt 300) {
        throw "Incomplete or non-landscape publication PNG: $Path"
    }
    [pscustomobject]@{ width = $width; height = $height; bytes = $bytes.Length }
}

if ($OutputName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$') {
    throw 'OutputName must be a ZIP filename without directory components.'
}

# Only explicitly reviewed public material is copied; never traverse build or the worktree.
$files = [ordered]@{
    "build/tv/$apkName" = "assets/$apkName"
    'docs/ANDROID_TV.md' = 'docs/ANDROID_TV.md'
    'docs/TV_PUBLICATION.md' = 'docs/TV_PUBLICATION.md'
    "docs/releases/v$version.md" = "docs/releases/v$version.md"
    'promo/screenshots/tv/README.md' = 'promo/screenshots/tv/README.md'
    'promo/screenshots/tv/tv-settings.png' = 'promo/screenshots/tv/tv-settings.png'
    'promo/screenshots/tv/tv-profiles.png' = 'promo/screenshots/tv/tv-profiles.png'
    'promo/screenshots/tv/tv-import.png' = 'promo/screenshots/tv/tv-import.png'
    'promo/screenshots/tv/tv-launcher-selected.png' = 'promo/screenshots/tv/tv-launcher-selected.png'
    'promo/screenshots/tv/tv-launcher-tile.png' = 'promo/screenshots/tv/tv-launcher-tile.png'
    'promo/screenshots/tv/tv-launcher-overview.png' = 'promo/screenshots/tv/tv-launcher-overview.png'
}
$records = @()
foreach ($entry in $files.GetEnumerator()) {
    $source = Join-Path $root $entry.Key
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing publication input: $source" }
    $hash = Get-Sha256 $source
    if ($entry.Value -eq "assets/$apkName" -and $hash -ne $expectedApkHash) {
        throw 'The APK does not match the reviewed TV artifact.'
    }
    $record = [ordered]@{ path = $entry.Value; sha256 = $hash; bytes = (Get-Item -LiteralPath $source).Length }
    if ($source.EndsWith('.png', [System.StringComparison]::OrdinalIgnoreCase)) {
        $info = Read-PngInfo $source
        $record.width = $info.width
        $record.height = $info.height
    }
    $records += [pscustomobject]$record
}
$mainReadme = [System.IO.File]::ReadAllText((Join-Path $root 'README.md'))
$readmeFragment = [regex]::Match($mainReadme, '(?ms)^## Yurich Connect TV\r?\n.*?(?=^## |\z)')
if (-not $readmeFragment.Success) { throw 'The TV section is missing from README.md.' }
if ($VerifyOnly) {
    $records | Format-Table path, bytes, width, height, sha256 -AutoSize
    Write-Output 'Publication inputs verified; no files written.'
    return
}

$outputRoot = Join-Path $root 'build/publication'
$archivePath = Join-Path $outputRoot $OutputName
$packageRoot = Join-Path $outputRoot ([System.IO.Path]::GetFileNameWithoutExtension($OutputName))
if ((Test-Path -LiteralPath $archivePath) -or (Test-Path -LiteralPath $packageRoot) -or
    (Test-Path -LiteralPath "$archivePath.sha256")) {
    throw 'Output already exists. Use a different OutputName; existing files are never overwritten.'
}
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
foreach ($entry in $files.GetEnumerator()) {
    $destination = Join-Path $packageRoot $entry.Value
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $entry.Key) -Destination $destination
}

$readme = @"
# Yurich Connect TV - Publication Kit

Preview version: $version. Prepared for publication; this ZIP does not publish a release.

- [Russian release text](RELEASE-BODY.md)
- [Ready-to-use GitHub README section](README-GITHUB-FRAGMENT.md)
- [Installation, compatibility and rollback](docs/ANDROID_TV.md)
- [Six privacy-redacted illustrations](promo/screenshots/tv/README.md)
- [GitHub publication checklist](docs/TV_PUBLICATION.md)
- [Signed ARM32/ARM64 TV APK](assets/$apkName)
- [APK SHA-256](assets/SHA256SUMS.txt)
- [Bundle checksums](SHA256SUMS.txt)

Images were edited with a generative editor and may have retouched details. They are
interface illustrations, not original photographs or network/soak-test evidence.
Original photos, subscriptions, signing keys, private logs and source code are excluded.
The repository-only build/packaging commands in the docs are not runnable from this kit.

Android 7.0/API 24 or newer. Package online.dnsai.ivanvpn is shared with the phone app;
the two APKs replace each other on one device. Update with the same signature and a
higher versionCode; do not uninstall or clear profiles merely to update or roll back.
TV updates are manual. XHTTP remains experimental; 24/7 stability is not certified.

Author: Ivan Yuryevich
[Website](https://ivan-it.net/) | [VK](https://vk.ru/ivanyurievichtv) |
[Telegram](https://t.me/ivan_it_net) | [Email](mailto:hello@ivan-it.net)
"@
[System.IO.File]::WriteAllText((Join-Path $packageRoot 'README.md'), $readme + "`n", $utf8)
[System.IO.File]::WriteAllText((Join-Path $packageRoot 'README-GITHUB-FRAGMENT.md'), $readmeFragment.Value.TrimEnd() + "`n", $utf8)
[System.IO.File]::WriteAllText((Join-Path $packageRoot 'RELEASE-TITLE.txt'), 'Yurich Connect TV 1.0.128 - Preview' + "`n", $utf8)
Copy-Item -LiteralPath (Join-Path $root "docs/releases/v$version.md") -Destination (Join-Path $packageRoot 'RELEASE-BODY.md')
[System.IO.File]::WriteAllText((Join-Path $packageRoot 'assets/SHA256SUMS.txt'), "$expectedApkHash  $apkName`n", $utf8)
$manifest = [ordered]@{
    format = 1
    version = $version
    versionCode = 43141
    releaseStatus = 'preview'
    publicationPerformed = $false
    imageTreatment = 'screen crop, generative retouching, opaque personal-data redaction'
    imageUse = 'interface illustrations, not test evidence'
    imageMetadata = 'reviewed C2PA provenance retained; no EXIF or source ingredients'
    excludes = @('original photos', 'subscriptions', 'signing keys', 'private diagnostics', 'source code')
    files = $records
}
[System.IO.File]::WriteAllText((Join-Path $packageRoot 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6) + "`n", $utf8)

$expectedNames = @($files.Values) + @('README.md', 'README-GITHUB-FRAGMENT.md', 'RELEASE-TITLE.txt', 'RELEASE-BODY.md', 'assets/SHA256SUMS.txt', 'manifest.json')
$sums = foreach ($relative in ($expectedNames | Sort-Object)) {
    "$(Get-Sha256 (Join-Path $packageRoot $relative))  $relative"
}
[System.IO.File]::WriteAllText((Join-Path $packageRoot 'SHA256SUMS.txt'), ($sums -join "`n") + "`n", $utf8)
$expectedNames += 'SHA256SUMS.txt'

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($packageRoot, $archivePath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
$archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $entries = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
    $differences = @(Compare-Object ($expectedNames | Sort-Object) ($entries.FullName | Sort-Object))
    if ($differences.Count -ne 0) { throw 'ZIP entries do not match the publication allowlist.' }
    foreach ($entry in $entries) {
        $stream = $entry.Open()
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $actual = [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
            if ($actual -ne (Get-Sha256 (Join-Path $packageRoot $entry.FullName))) {
                throw "ZIP checksum mismatch: $($entry.FullName)"
            }
        } finally { $sha.Dispose(); $stream.Dispose() }
    }
} finally { $archive.Dispose() }
$archiveHash = Get-Sha256 $archivePath
[System.IO.File]::WriteAllText("$archivePath.sha256", "$archiveHash  $OutputName`n", $utf8)
Write-Output "Archive: $archivePath"
Write-Output "Files: $($expectedNames.Count)"
Write-Output "Bytes: $((Get-Item -LiteralPath $archivePath).Length)"
Write-Output "SHA256: $archiveHash"
