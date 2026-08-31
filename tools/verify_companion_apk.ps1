[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Apk,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedPackage,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $MinimumVersionCode,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedCertificateSha256
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

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return -join ($algorithm.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
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

$debuggableOutput = @(Invoke-CheckedAndroidTool -Tool $apkAnalyzer `
    -Arguments @('manifest', 'debuggable', $resolvedApk) `
    -Description 'Read companion debuggable flag')
if ($debuggableOutput[-1].ToLowerInvariant() -cne 'false') {
    throw 'Release companion must declare android:debuggable=false.'
}

$permissionOutput = @(Invoke-CheckedAndroidTool -Tool $apkAnalyzer `
    -Arguments @('manifest', 'permissions', $resolvedApk) `
    -Description 'Read companion permissions')
$actualPermissions = @(
    $permissionOutput |
        Where-Object { $_ -match '^android[.]permission[.]' } |
        Select-Object -Unique
)
$allowedPermissions = @(
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
    'android.permission.POST_NOTIFICATIONS',
    'android.permission.WAKE_LOCK'
)
$unexpectedPermissions = @(
    $actualPermissions | Where-Object { $_ -cnotin $allowedPermissions }
)
if ($unexpectedPermissions.Count -ne 0) {
    throw "Release companion requests forbidden permissions: $($unexpectedPermissions -join ', ')."
}
foreach ($requiredPermission in @(
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
    'android.permission.WAKE_LOCK'
)) {
    if ($requiredPermission -cnotin $actualPermissions) {
        throw "Release companion is missing required permission '$requiredPermission'."
    }
}

$normalizedExpectedCertificate = ($ExpectedCertificateSha256 -replace '[^0-9A-Fa-f]', '').ToLowerInvariant()
if ($normalizedExpectedCertificate -notmatch '^[0-9a-f]{64}$') {
    throw 'Expected certificate SHA-256 must contain exactly 64 hexadecimal digits.'
}

$signatureOutput = @(Invoke-CheckedAndroidTool -Tool $apkSigner `
    -Arguments @('verify', '--verbose', '--print-certs', $resolvedApk) `
    -Description 'Verify companion APK signature')
$parsedCertificates = @(
    foreach ($line in $signatureOutput) {
        if ($line -match '(?i)certificate SHA-256 digest:\s*([0-9a-f][0-9a-f:\s-]*)$') {
            ($Matches[1] -replace '[^0-9A-Fa-f]', '').ToLowerInvariant()
        }
    }
)
$actualCertificates = @($parsedCertificates | Where-Object { $_ } | Select-Object -Unique)
if ($actualCertificates.Count -ne 1) {
    throw "Expected exactly one APK signer certificate, found $($actualCertificates.Count)."
}
if ($actualCertificates[0] -cne $normalizedExpectedCertificate) {
    throw "Wrong companion signing certificate. Expected '$normalizedExpectedCertificate', found '$($actualCertificates[0])'."
}
$sha256 = Get-Sha256Hex -Path $resolvedApk
Write-Output "Verified signed companion: package=$actualPackage versionCode=$actualVersion debuggable=false permissions=$($actualPermissions.Count) certificateSha256=$normalizedExpectedCertificate sha256=$sha256"
