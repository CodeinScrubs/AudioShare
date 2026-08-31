[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-SingleVersion {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Pattern,

        [Parameter(Mandatory)]
        [string] $Description
    )

    $content = Get-Content -LiteralPath $Path -Raw
    $matches = [regex]::Matches($content, $Pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one $Description in '$Path'; found $($matches.Count)."
    }
    return [int] $matches[0].Groups[1].Value
}

$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$configPath = Join-Path $root 'client\companion-release.json'
$dartPath = Join-Path $root 'client\lib\services\adb_service.dart'
$cmakePath = Join-Path $root 'client\windows\CMakeLists.txt'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$configVersion = [int] $config.versionCode
$dartVersion = Read-SingleVersion `
    -Path $dartPath `
    -Pattern 'const bundledCompanionVersionCode\s*=\s*(\d+)\s*;' `
    -Description 'Dart companion version pin'
$cmakeVersion = Read-SingleVersion `
    -Path $cmakePath `
    -Pattern '-ExpectedVersionCode\s+(\d+)' `
    -Description 'CMake companion version pin'

if ($configVersion -ne $dartVersion -or $configVersion -ne $cmakeVersion) {
    throw "Companion version pins disagree: release=$configVersion Dart=$dartVersion CMake=$cmakeVersion."
}
if ($config.tag -notmatch '^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
    throw "Invalid companion release tag '$($config.tag)'."
}
if ($config.asset -cne "AudioShare-USB-Companion-$($config.tag).apk") {
    throw "Companion asset '$($config.asset)' does not match tag '$($config.tag)'."
}

Write-Output "COMPANION_VERSION_PINS_OK versionCode=$configVersion tag=$($config.tag)"
