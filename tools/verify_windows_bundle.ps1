[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $BundleDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bundle = (Resolve-Path -LiteralPath $BundleDirectory).Path.TrimEnd('\', '/')
$requiredFiles = @(
    'audioshare.exe',
    'audio_capture.dll',
    'flutter_windows.dll',
    'msvcp140.dll',
    'vcruntime140.dll',
    'vcruntime140_1.dll',
    'adb.exe',
    'AdbWinApi.dll',
    'AdbWinUsbApi.dll',
    'android/audioshare-companion.apk',
    'data/app.so',
    'data/icudtl.dat',
    'data/flutter_assets/NOTICES.Z',
    'LICENSE.txt',
    'README.md',
    'SECURITY.md',
    'THIRD_PARTY_NOTICES_ADB.txt',
    'docs/PROTOCOL.md',
    'docs/TROUBLESHOOTING.md',
    'SHA256SUMS.txt'
)

foreach ($relative in $requiredFiles) {
    $path = Join-Path $bundle ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Portable bundle is missing required file '$relative'."
    }
}
if (Test-Path -LiteralPath (Join-Path $bundle 'android\audioshare-companion-poc-debug.apk')) {
    throw 'Release bundle must not contain the debug companion APK.'
}

$manifestPath = Join-Path $bundle 'SHA256SUMS.txt'
$entries = @{}
foreach ($line in Get-Content -LiteralPath $manifestPath) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
    if ($line -notmatch '^(?<hash>[0-9A-Fa-f]{64})  (?<path>.+)$') {
        throw "Malformed checksum-manifest line: '$line'."
    }
    $relative = $Matches.path
    if ($relative.Contains('\') -or [IO.Path]::IsPathRooted($relative) -or
        @($relative.Split('/')).Contains('..')) {
        throw "Unsafe checksum-manifest path '$relative'."
    }
    if ($entries.ContainsKey($relative)) {
        throw "Duplicate checksum-manifest path '$relative'."
    }
    $entries[$relative] = $Matches.hash.ToLowerInvariant()
}
if ($entries.Count -eq 0) {
    throw 'Checksum manifest contains no file entries.'
}

$bundlePrefix = $bundle + [IO.Path]::DirectorySeparatorChar
foreach ($relative in $entries.Keys) {
    $path = [IO.Path]::GetFullPath(
        (Join-Path $bundle ($relative -replace '/', [IO.Path]::DirectorySeparatorChar))
    )
    if (-not $path.StartsWith($bundlePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Checksum-manifest path escapes the bundle: '$relative'."
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Checksum-manifest file is missing: '$relative'."
    }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $entries[$relative]) {
        throw "Checksum mismatch for '$relative'."
    }
}

$actualFiles = @(
    Get-ChildItem -LiteralPath $bundle -File -Recurse |
        ForEach-Object {
            $_.FullName.Substring($bundlePrefix.Length).Replace('\', '/')
        } |
        Where-Object { $_ -cne 'SHA256SUMS.txt' } |
        Sort-Object
)
$manifestFiles = @($entries.Keys | Sort-Object)
$coverageDelta = @(Compare-Object -ReferenceObject $actualFiles -DifferenceObject $manifestFiles)
if ($coverageDelta.Count -ne 0) {
    $details = ($coverageDelta | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join '; '
    throw "Checksum manifest does not exactly cover the bundle: $details"
}

Write-Output "WINDOWS_BUNDLE_OK files=$($actualFiles.Count) path=$bundle"
