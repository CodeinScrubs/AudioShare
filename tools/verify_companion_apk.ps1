[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Apk,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedPackage,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $MinimumVersionCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-CheckedAndroidTool {
    param(
        [Parameter(Mandatory = $true)] [string] $Tool,
        [Parameter(Mandatory = $true)] [string[]] $Arguments,
        [Parameter(Mandatory = $true)] [string] $Description
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $Tool @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        $details = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "$Description failed with exit code ${exitCode}: $details"
    }
    return @($output | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })
}

$resolvedApk = (Resolve-Path -LiteralPath $Apk).Path
$sdkCandidates = @(
    $env:ANDROID_HOME,
    $env:ANDROID_SDK_ROOT,
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Android\Sdk' })
) | Where-Object { $_ } | Select-Object -Unique
$sdkRoot = $sdkCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
    Select-Object -First 1
if (-not $sdkRoot) {
    throw 'Android SDK not found. Set ANDROID_HOME or ANDROID_SDK_ROOT.'
}

$apkAnalyzer = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'cmdline-tools') `
        -Filter 'apkanalyzer.bat' -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1 -ExpandProperty FullName
$apkSigner = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'build-tools') `
        -Filter 'apksigner.bat' -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $apkAnalyzer -or -not $apkSigner) {
    throw 'Android SDK cmdline-tools (apkanalyzer) and build-tools (apksigner) are required.'
}

$packageOutput = @(Invoke-CheckedAndroidTool -Tool $apkAnalyzer `
    -Arguments @('manifest', 'application-id', $resolvedApk) `
    -Description 'Read companion application ID')
$actualPackage = $packageOutput[-1]
if ($actualPackage -cne $ExpectedPackage) {
    throw "Wrong companion package. Expected '$ExpectedPackage', found '$actualPackage'."
}

$versionOutput = @(Invoke-CheckedAndroidTool -Tool $apkAnalyzer `
    -Arguments @('manifest', 'version-code', $resolvedApk) `
    -Description 'Read companion version code')
$actualVersion = 0
if (-not [int]::TryParse($versionOutput[-1], [ref] $actualVersion)) {
    throw "Invalid companion version code: '$($versionOutput[-1])'."
}
if ($actualVersion -lt $MinimumVersionCode) {
    throw "Companion version code $actualVersion is below required $MinimumVersionCode."
}

$null = Invoke-CheckedAndroidTool -Tool $apkSigner `
    -Arguments @('verify', '--verbose', '--print-certs', $resolvedApk) `
    -Description 'Verify companion APK signature'
$sha256 = (Get-FileHash -LiteralPath $resolvedApk -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "Verified signed companion: package=$actualPackage versionCode=$actualVersion sha256=$sha256"
