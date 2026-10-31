#Requires -Version 5.1
<#
.SYNOPSIS
  Reassemble the split rootfs archive, then flash (Windows).

  Mirror of join-and-flash.sh: verifies SHA256SUMS first, concatenates
  linux.img.zst.part-* when linux.img.zst is missing or stale, then hands
  over to flash.ps1 (which verifies again before touching the device).
#>
$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

function Fail([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Test-BundleHashes {
    if ($env:SKIP_SHA256_CHECK -eq "1") {
        Write-Host "SKIP_SHA256_CHECK=1 set - skipping SHA256SUMS verification."
        return
    }
    $sumsFile = Join-Path $ScriptDir "SHA256SUMS"
    if (-not (Test-Path -LiteralPath $sumsFile)) {
        Write-Host "WARNING: SHA256SUMS missing - skipping integrity verification. Re-download the release if anything misbehaves."
        return
    }
    foreach ($line in Get-Content -LiteralPath $sumsFile) {
        $isHashLine = $line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$'
        if (-not $isHashLine) { continue }
        $expected = $Matches[1]
        $relPath = $Matches[2].Trim()
        $fullPath = Join-Path $ScriptDir $relPath
        if (-not (Test-Path -LiteralPath $fullPath)) {
            Fail "SHA256SUMS lists missing file '$relPath' - the bundle is incomplete. Re-download the release."
        }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash
        if ($actual -ne $expected) {
            Fail "SHA256 mismatch for '$relPath' - the bundle is corrupted. Re-download the release. To flash anyway (NOT recommended): SKIP_SHA256_CHECK=1"
        }
    }
    Write-Host "  SHA256SUMS verified."
}

Write-Host "=== CachyOS Nabu Installer (Windows) ==="
Write-Host ""

if (-not (Get-Command fastboot -ErrorAction SilentlyContinue)) {
    Fail "fastboot not found. Install Google platform-tools and put fastboot.exe on PATH."
}
if (-not (Get-Command zstd -ErrorAction SilentlyContinue) -and
    -not (Test-Path -LiteralPath (Join-Path $ScriptDir "zstd.exe"))) {
    Fail "zstd not found. Install zstd and put it on PATH, or drop zstd.exe next to this script."
}

Test-BundleHashes

$zstPath = Join-Path $ScriptDir "linux.img.zst"
$parts = @(Get-ChildItem -LiteralPath $ScriptDir -Filter "linux.img.zst.part-*" -File |
    Sort-Object Name)

$needJoin = $false
if (-not (Test-Path -LiteralPath $zstPath)) {
    $needJoin = $true
}
else {
    $zstTime = (Get-Item -LiteralPath $zstPath).LastWriteTime
    foreach ($part in $parts) {
        if ($part.LastWriteTime -gt $zstTime) {
            Write-Host "linux.img.zst is stale - a part file is newer. Reassembling."
            $needJoin = $true
            break
        }
    }
}

if ($needJoin) {
    if ($parts.Count -eq 0) {
        Fail "No linux.img.zst and no linux.img.zst.part-* files in $ScriptDir - download EVERY asset of the release into this folder."
    }
    Write-Host "Reassembling rootfs from parts..."
    $outStream = [IO.File]::Create($zstPath)
    try {
        foreach ($part in $parts) {
            $inStream = [IO.File]::OpenRead($part.FullName)
            try { $inStream.CopyTo($outStream) }
            finally { $inStream.Dispose() }
        }
    }
    finally { $outStream.Dispose() }
    Write-Host "  Done."
}

& (Join-Path $ScriptDir "flash.ps1")
