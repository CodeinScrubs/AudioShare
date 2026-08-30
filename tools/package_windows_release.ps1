[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $BundleDirectory,

    [Parameter(Mandatory = $true)]
    [string] $OutputZip,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bundle = (Resolve-Path -LiteralPath $BundleDirectory).Path
$validator = Join-Path $PSScriptRoot 'verify_windows_bundle.ps1'
$output = [IO.Path]::GetFullPath($OutputZip)
$checksumOutput = "$output.sha256"
$bundlePrefix = $bundle.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if ($output.StartsWith($bundlePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Output ZIP must be outside the bundle directory being archived.'
}
if ((Test-Path -LiteralPath $output) -and -not $Force) {
    throw "Output ZIP already exists: '$output'. Use -Force to replace it."
}
$outputParent = Split-Path -Parent $output
$null = New-Item -ItemType Directory -Force -Path $outputParent
if ($Force) {
    Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $checksumOutput -Force -ErrorAction SilentlyContinue
}

function Invoke-BundleValidator {
    param(
        [Parameter(Mandatory = $true)] [string] $Directory,
        [Parameter(Mandatory = $true)] [bool] $ExpectSuccess
    )
    $exitCode = 0
    try {
        # Invoke in-process so an expected validator exception can be observed
        # consistently in both Windows PowerShell 5.1 and pwsh 7. Child-process
        # stderr is otherwise promoted to a terminating native-command error.
        $validationOutput = @(& $validator -BundleDirectory $Directory 2>&1)
    } catch {
        $validationOutput = @($_)
        $exitCode = 1
    }
    if ($ExpectSuccess -and $exitCode -ne 0) {
        throw "Bundle validation failed: $($validationOutput -join [Environment]::NewLine)"
    }
    if (-not $ExpectSuccess -and $exitCode -eq 0) {
        throw 'Bundle validator accepted a deliberately damaged package.'
    }
    if ($ExpectSuccess) { $validationOutput | Write-Output }
}

Invoke-BundleValidator -Directory $bundle -ExpectSuccess $true
Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $output -CompressionLevel Optimal

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("AudioShare release verification " + [guid]::NewGuid().ToString('N'))
try {
    $extracted = Join-Path $temporaryRoot 'extracted bundle with spaces'
    $missing = Join-Path $temporaryRoot 'missing file case'
    $altered = Join-Path $temporaryRoot 'altered file case'
    $null = New-Item -ItemType Directory -Force -Path $extracted, $missing, $altered
    Expand-Archive -LiteralPath $output -DestinationPath $extracted
    Invoke-BundleValidator -Directory $extracted -ExpectSuccess $true

    Copy-Item -Path (Join-Path $extracted '*') -Destination $missing -Recurse
    Remove-Item -LiteralPath (Join-Path $missing 'LICENSE.txt') -Force
    Invoke-BundleValidator -Directory $missing -ExpectSuccess $false

    Copy-Item -Path (Join-Path $extracted '*') -Destination $altered -Recurse
    [IO.File]::AppendAllText((Join-Path $altered 'README.md'), "`r`nCI tamper probe")
    Invoke-BundleValidator -Directory $altered -ExpectSuccess $false
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

$zipHash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(
    $checksumOutput,
    "$zipHash  $([IO.Path]::GetFileName($output))$([Environment]::NewLine)",
    [Text.UTF8Encoding]::new($false)
)
Write-Output "WINDOWS_RELEASE_ZIP_OK sha256=$zipHash path=$output"
