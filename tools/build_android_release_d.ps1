$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = "D:\Yurich Connect\BuildCache"
$flutter = "D:\Yurich Connect\SDK\flutter_windows_3.41.9-stable\flutter\bin\flutter.bat"

$mySoft = [string]::Concat(
    [char]0x041C, [char]0x043E, [char]0x0439, " ",
    [char]0x0441, [char]0x043E, [char]0x0444, [char]0x0442
)
$androidApps = [string]::Concat(
    [char]0x0410, [char]0x043D, [char]0x0434, [char]0x0440,
    [char]0x043E, [char]0x0439, [char]0x0434, " ",
    [char]0x043F, [char]0x0440, [char]0x0438, [char]0x043B,
    [char]0x043E, [char]0x0436, [char]0x0435, [char]0x043D,
    [char]0x0438, [char]0x044F
)
$apkOut = Join-Path "D:\" (Join-Path $mySoft $androidApps)

$env:GRADLE_USER_HOME = Join-Path $buildRoot "gradle-user-home"
$env:PUB_CACHE = Join-Path $buildRoot "pub-cache"

New-Item -ItemType Directory -Force -Path $env:GRADLE_USER_HOME | Out-Null
New-Item -ItemType Directory -Force -Path $env:PUB_CACHE | Out-Null
New-Item -ItemType Directory -Force -Path $apkOut | Out-Null

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Step,
        [Parameter(Mandatory = $true)]
        [scriptblock] $Command
    )

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

function Clear-FlutterAotCache {
    $flutterBuild = Join-Path $repoRoot ".dart_tool\flutter_build"
    if (Test-Path -LiteralPath $flutterBuild) {
        Remove-Item -LiteralPath $flutterBuild -Recurse -Force
    }
}

Push-Location $repoRoot
try {
    Invoke-Checked "flutter pub get" { & $flutter pub get }
    Invoke-Checked "flutter analyze" { & $flutter analyze }
    Invoke-Checked "flutter test" { & $flutter test --reporter compact }

    Clear-FlutterAotCache
    Invoke-Checked "flutter build apk --release" { & $flutter build apk --release }

    Clear-FlutterAotCache
    Invoke-Checked "flutter build apk --release --split-per-abi" {
        & $flutter build apk --release --split-per-abi
    }

    $versionLine = Select-String -LiteralPath "pubspec.yaml" -Pattern "^version:\s*(.+)$" |
        Select-Object -First 1
    $versionName = if ($versionLine) {
        ($versionLine.Matches[0].Groups[1].Value -split "\+")[0].Trim()
    } else {
        "unknown"
    }

    Copy-Item -LiteralPath "build\app\outputs\flutter-apk\app-release.apk" `
        -Destination (Join-Path $apkOut "app-release.apk") -Force
    Copy-Item -LiteralPath "build\app\outputs\flutter-apk\app-release.apk" `
        -Destination (Join-Path $apkOut "YurichConnect-android-release.apk") -Force
    Copy-Item -LiteralPath "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk" `
        -Destination (Join-Path $apkOut "YurichConnect-android-arm64-v8a-v$versionName.apk") -Force
    Copy-Item -LiteralPath "build\app\outputs\flutter-apk\app-armeabi-v7a-release.apk" `
        -Destination (Join-Path $apkOut "YurichConnect-android-armeabi-v7a-v$versionName.apk") -Force
    Copy-Item -LiteralPath "build\app\outputs\flutter-apk\app-x86_64-release.apk" `
        -Destination (Join-Path $apkOut "YurichConnect-android-x86_64-v$versionName.apk") -Force

    Get-ChildItem -LiteralPath $apkOut -Filter "*$versionName*.apk" |
        Select-Object Name, Length, LastWriteTime
} finally {
    Pop-Location
}
