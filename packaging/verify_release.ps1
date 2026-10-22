[CmdletBinding()]
param(
    [string]$DistRoot = '',
    [switch]$RequireSigned
)

$ErrorActionPreference = 'Stop'
$AppRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $DistRoot) { $DistRoot = Join-Path $AppRoot 'dist' }
$manifestPath = Join-Path $DistRoot 'release-manifest.json'
$bundlePath = Join-Path $DistRoot 'bundle-manifest.json'
$checksumsPath = Join-Path $DistRoot 'SHA256SUMS.txt'

foreach ($path in @($manifestPath, $bundlePath, $checksumsPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Release artifact is missing: $path"
    }
}

$release = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$bundle = Get-Content -LiteralPath $bundlePath -Raw | ConvertFrom-Json
$bundleHash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).
    Hash.ToLowerInvariant()
if ($bundleHash -ne "$($release.bundleManifestSha256)".ToLowerInvariant()) {
    throw 'release-manifest.json does not match bundle-manifest.json.'
}

$checked = @()
foreach ($artifact in @($release.artifacts)) {
    $path = Join-Path $DistRoot $artifact.name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Release artifact is missing: $path"
    }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).
        Hash.ToLowerInvariant()
    if ($hash -ne "$($artifact.sha256)".ToLowerInvariant()) {
        throw "Release artifact hash mismatch: $($artifact.name)"
    }
    if ((Get-Item -LiteralPath $path).Length -ne [long]$artifact.bytes) {
        throw "Release artifact size mismatch: $($artifact.name)"
    }
    $checked += [pscustomobject]@{
        name = $artifact.name
        sha256 = $hash
        bytes = (Get-Item -LiteralPath $path).Length
    }
}

# SHA256SUMS.txt is the file a recipient can check without parsing JSON.
$sums = @{}
foreach ($line in Get-Content -LiteralPath $checksumsPath) {
    if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
        throw "Unreadable checksum line: $line"
    }
    $sums[$Matches[2].Trim()] = $Matches[1].ToLowerInvariant()
}
foreach ($artifact in $checked) {
    if (-not $sums.ContainsKey($artifact.name)) {
        throw "SHA256SUMS.txt is missing $($artifact.name)."
    }
    if ($sums[$artifact.name] -ne $artifact.sha256) {
        throw "SHA256SUMS.txt disagrees for $($artifact.name)."
    }
}
foreach ($name in @('bundle-manifest.json', 'release-manifest.json')) {
    if (-not $sums.ContainsKey($name)) {
        throw "SHA256SUMS.txt is missing $name."
    }
    $actual = (Get-FileHash -LiteralPath (Join-Path $DistRoot $name) `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sums[$name] -ne $actual) {
        throw "SHA256SUMS.txt disagrees for $name."
    }
}

if ($release.signed) {
    foreach ($artifact in $checked) {
        # Authenticode signs PE files, not ZIP archives. The ZIP is covered by
        # the manifest hash and SHA256SUMS; its contents (app and engine) are
        # signed before the archive is written.
        if ($artifact.name -notmatch '\.exe$') { continue }
        $signature = Get-AuthenticodeSignature (Join-Path $DistRoot $artifact.name)
        if ($signature.Status -ne 'Valid') {
            throw "Signature is not valid for $($artifact.name): $($signature.Status)."
        }
    }
} elseif ($RequireSigned) {
    throw 'This release is unsigned, but -RequireSigned was set.'
} else {
    Write-Warning 'This release is unsigned; SmartScreen will warn pilot users.'
}

[pscustomobject]@{
    AppVersion = $release.appVersion
    EngineVersion = $release.sidecarVersion
    SourceRevision = $release.sourceRevision
    SourceDirty = $release.sourceDirty
    Signed = $release.signed
    BundleManifestSha256 = $bundleHash
    Artifacts = @($checked)
} | ConvertTo-Json -Depth 5
