param(
    [string]$FlutterSdk = "D:\FlutterSDK",
    [string]$BuildName = "1.0.128-tv.20261003.1",
    [int]$BuildNumber = 43141
)

$ErrorActionPreference = "Stop"
$project = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$flutter = Join-Path $FlutterSdk "bin\flutter.bat"
if (-not (Test-Path -LiteralPath $flutter -PathType Leaf)) {
    throw "Flutter SDK not found: $flutter"
}
if ($BuildNumber -le 0 -or $BuildName -notmatch '^[A-Za-z0-9.+-]+$') {
    throw "Invalid APK version."
}

Push-Location $project
try {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }
    & $flutter analyze --no-pub
    if ($LASTEXITCODE -ne 0) { throw "flutter analyze failed" }
    & $flutter test --no-pub
    if ($LASTEXITCODE -ne 0) { throw "flutter test failed" }
    & $flutter build apk --release --flavor tv --no-pub `
        --target-platform android-arm,android-arm64 `
        --build-name $BuildName --build-number $BuildNumber
    if ($LASTEXITCODE -ne 0) { throw "TV APK build failed" }

    $source = Join-Path $project "build\app\outputs\flutter-apk\app-tv-release.apk"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($source)
    try {
        $abis = @($archive.Entries |
            Where-Object { $_.FullName.StartsWith("lib/") } |
            ForEach-Object { $_.FullName.Split('/')[1] } |
            Sort-Object -Unique)
        if ($abis.Count -ne 2 -or $abis -notcontains "armeabi-v7a" -or
            $abis -notcontains "arm64-v8a") {
            throw "TV APK must contain exactly ARM32 and ARM64: $($abis -join ', ')"
        }
        foreach ($abi in $abis) {
            foreach ($library in @("libapp.so", "libflutter.so", "libbox.so", "libgojni.so", "libdartjni.so")) {
                if ($null -eq $archive.GetEntry("lib/$abi/$library")) {
                    throw "TV APK has an incomplete native runtime: $abi/$library"
                }
            }
        }
    } finally {
        $archive.Dispose()
    }
    $artifacts = Join-Path $project "build\tv"
    New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
    $destination = Join-Path $artifacts "YurichConnect-TV-arm-v$BuildName.apk"
    Copy-Item -LiteralPath $source -Destination $destination -Force
    Get-FileHash -LiteralPath $destination -Algorithm SHA256
    Write-Output "TV APK: $destination"
} finally {
    Pop-Location
}
