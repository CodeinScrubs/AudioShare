[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,

    [string] $GithubEnvironmentFile = $env:GITHUB_ENV
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-CheckedTool {
    param(
        [Parameter(Mandatory = $true)] [string] $Tool,
        [Parameter(Mandatory = $true)] [string[]] $Arguments,
        [Parameter(Mandatory = $true)] [string] $Description
    )
    # Windows PowerShell promotes any native stderr line to a terminating
    # NativeCommandError when ErrorActionPreference is Stop. keytool and some
    # Android SDK tools write normal progress messages to stderr, so inspect
    # the process exit code explicitly instead of treating that output as a
    # failure.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $Tool @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        throw "$Description failed: $($output -join [Environment]::NewLine)"
    }
    return @($output | ForEach-Object { $_.ToString() })
}

$sdkCandidates = @(
    $env:ANDROID_HOME,
    $env:ANDROID_SDK_ROOT,
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Android\Sdk' })
) | Where-Object { $_ } | Select-Object -Unique
$sdkRoot = $sdkCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
    Select-Object -First 1
if (-not $sdkRoot) { throw 'Android SDK not found.' }

$buildTools = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'build-tools') -Directory |
    Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending |
    Select-Object -First 1
$aapt2 = Join-Path $buildTools.FullName 'aapt2.exe'
$zipalign = Join-Path $buildTools.FullName 'zipalign.exe'
$apkSigner = Join-Path $buildTools.FullName 'apksigner.bat'
$androidJar = Join-Path $sdkRoot 'platforms\android-36\android.jar'
$keytool = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\keytool.exe' } else { $null }
foreach ($tool in @($aapt2, $zipalign, $apkSigner, $androidJar, $keytool)) {
    if (-not $tool -or -not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Required CI fixture tool is missing: '$tool'."
    }
}

$directory = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Force -Path $directory
$manifest = Join-Path $directory 'AndroidManifest.xml'
$unsignedApk = Join-Path $directory 'companion-unsigned.apk'
$alignedApk = Join-Path $directory 'companion-aligned.apk'
$signedApk = Join-Path $directory 'companion-ci-signed.apk'
$keystore = Join-Path $directory 'ci-only-keystore.jks'
[IO.File]::WriteAllText(
    $manifest,
    @'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.audioshare.usbcompanion"
    android:versionCode="2"
    android:versionName="ci-only">
    <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="36" />
    <application android:hasCode="false" android:label="AudioShare CI-only fixture" />
</manifest>
'@,
    [Text.UTF8Encoding]::new($false)
)

$null = Invoke-CheckedTool -Tool $aapt2 -Description 'Create minimal CI-only APK' -Arguments @(
    'link', '-I', $androidJar, '--manifest', $manifest, '-o', $unsignedApk
)
$null = Invoke-CheckedTool -Tool $zipalign -Description 'Align CI-only APK' -Arguments @(
    '-p', '-f', '4', $unsignedApk, $alignedApk
)
$null = Invoke-CheckedTool -Tool $keytool -Description 'Create ephemeral CI-only signer' -Arguments @(
    '-genkeypair', '-noprompt', '-keystore', $keystore,
    '-storepass', 'ci-only-password', '-keypass', 'ci-only-password',
    '-alias', 'ci-only', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '1',
    '-dname', 'CN=AudioShare CI Fixture, O=CI Only, C=US'
)
$null = Invoke-CheckedTool -Tool $apkSigner -Description 'Sign CI-only APK' -Arguments @(
    'sign', '--ks', $keystore, '--ks-key-alias', 'ci-only',
    '--ks-pass', 'pass:ci-only-password', '--key-pass', 'pass:ci-only-password',
    '--out', $signedApk, $alignedApk
)
$signatureOutput = @(Invoke-CheckedTool -Tool $apkSigner -Description 'Verify CI-only APK' -Arguments @(
    'verify', '--verbose', '--print-certs', $signedApk
))
$certificate = @(
    foreach ($line in $signatureOutput) {
        if ($line -match '(?i)certificate SHA-256 digest:\s*([0-9a-f]{64})$') {
            $Matches[1].ToLowerInvariant()
        }
    }
)
if ($certificate.Count -ne 1) {
    throw "Expected one CI-only signer certificate, found $($certificate.Count)."
}

if ($GithubEnvironmentFile) {
    [IO.File]::AppendAllText(
        $GithubEnvironmentFile,
        "AUDIOSHARE_COMPANION_APK=$signedApk$([Environment]::NewLine)" +
        "AUDIOSHARE_COMPANION_CERT_SHA256=$($certificate[0])$([Environment]::NewLine)",
        [Text.UTF8Encoding]::new($false)
    )
}
Write-Output 'Created an ephemeral CI-only APK; it is never a distributable companion.'
Write-Output "CI_COMPANION_OK certificateSha256=$($certificate[0]) path=$signedApk"
