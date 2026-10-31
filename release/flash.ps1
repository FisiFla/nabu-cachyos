#Requires -Version 5.1
<#
.SYNOPSIS
  CachyOS Nabu flasher for Windows hosts (flash step only).

  Tested once on Windows 11 / PowerShell 5.1 with Google platform-tools
  37.0.1 and a real nabu (31 Oct 2026, release v1.5.0). The maintainer
  normally flashes from macOS/Linux with flash.sh, so still treat this as
  new code and report problems. Slot A stays untouched until the final
  set_active, so `fastboot set_active a` is always the way back.

  There is NO Windows version of the partition scripts
  (relabel-partition / carve-linux-partition): preparing the GPT still
  needs a macOS/Linux host. See README, "Windows hosts".

  Differences from flash.sh:
  - SSH key injection is not supported (add a key after first boot).
  - The rootfs is converted to Android sparse format in-script before
    flashing (like the macOS img2simg step): Google's Windows
    fastboot.exe is a 32-bit binary and `fastboot -S ... flash` of the
    ~10 GB raw image dies with std::bad_alloc trying to buffer it
    (measured on platform-tools 37.0.1, Windows 11).

  Switches (environment variables, same names as flash.sh):
    FORCE_FLASH=1        skip the confirmation prompt
    SKIP_SHA256_CHECK=1  skip SHA256SUMS verification (not recommended)
#>
$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

function Fail([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Invoke-Fastboot([string[]]$ArgumentList) {
    & fastboot @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        Fail ("fastboot " + ($ArgumentList -join " ") + " failed (exit $LASTEXITCODE). Slot B was NOT set active; slot A still boots.")
    }
}

function Read-TextFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $text) { return "" }
    return $text
}

# nabu's ABL firmware can block forever on getvar probes, so every getvar
# runs in a child process with a kill-on-timeout watchdog (flash.sh does the
# same in bash). fastboot writes getvar answers to stderr; Start-Process
# file redirection captures both streams without PowerShell wrapping
# stderr lines as errors. Never use `getvar all` on this device.
function Get-FastbootVar([string]$Var, [int]$TimeoutSec = 10) {
    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath "fastboot" -ArgumentList @("getvar", $Var) `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $timedOut = -not $proc.WaitForExit($TimeoutSec * 1000)
        if ($timedOut) {
            try { $proc.Kill() } catch { }
            try { $proc.WaitForExit() } catch { }
        }
        $text = (Read-TextFile $outFile) + (Read-TextFile $errFile)
        return [pscustomobject]@{ TimedOut = $timedOut; Text = $text }
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

# Returns "present", "absent" or "timeout" for a partition name.
function Test-FastbootPartition([string]$Name) {
    foreach ($var in @("partition-size:$Name", "partition-type:$Name")) {
        $result = Get-FastbootVar $var 10
        if ($result.TimedOut) { return "timeout" }
        if ($result.Text -match "FAILED" -or $result.Text -match "not found") { continue }
        $pattern = "partition-(size|type):\s*" + [regex]::Escape($Name) + "\s*:"
        if ($result.Text -match $pattern) { return "present" }
    }
    return "absent"
}

# Value of a getvar (text after the last colon of the matching line), or "".
function Get-FastbootVarValue([string]$Var) {
    $result = Get-FastbootVar $Var 10
    if ($result.TimedOut) { return "" }
    $namePat = (($Var -split ":") | ForEach-Object { [regex]::Escape($_) }) -join ":\s*"
    $line = ($result.Text -split "`r?`n") | Where-Object { $_ -match $namePat } | Select-Object -Last 1
    if (-not $line) { return "" }
    return (($line -split ":\s*")[-1]).Trim()
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

function Find-Zstd {
    $cmd = Get-Command zstd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $local = Join-Path $ScriptDir "zstd.exe"
    if (Test-Path -LiteralPath $local) { return $local }
    return $null
}

function Expand-Rootfs {
    $zstd = Find-Zstd
    if (-not $zstd) {
        Fail "zstd not found. Install zstd and put it on PATH, or drop zstd.exe next to this script."
    }
    & $zstd -d -f $ImgZstPath -o $ImgPath
    if ($LASTEXITCODE -ne 0) { Fail "zstd decompression failed (exit $LASTEXITCODE)." }
}

# Streaming raw -> Android sparse conversion (img2simg equivalent), compiled
# in-process so no extra tools are needed. Memory stays at one 4 KiB block;
# all-zero blocks become DONT_CARE chunks, data blocks RAW chunks capped at
# 16384 blocks (64 MiB) each.
$SparseCode = @"
using System;
using System.IO;
public static class NabuSparse
{
    const uint Magic = 0xED26FF3A;
    const ushort RawChunk = 0xCAC1;
    const ushort DontCareChunk = 0xCAC3;
    static bool IsZero(byte[] buf, int len)
    {
        for (int i = 0; i < len; i += 8)
            if (BitConverter.ToInt64(buf, i) != 0) return false;
        return true;
    }
    public static void Convert(string inPath, string outPath, int blkSz, int maxRawBlocks)
    {
        using (var inp = new FileStream(inPath, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
        using (var outp = new FileStream(outPath, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
        {
            var w = new BinaryWriter(outp);
            long totalBlks = (inp.Length + blkSz - 1) / blkSz;
            w.Write(Magic); w.Write((ushort)1); w.Write((ushort)0);
            w.Write((ushort)28); w.Write((ushort)12); w.Write((uint)blkSz);
            w.Write((uint)totalBlks); w.Write(0u); w.Write(0u);
            int chunkCount = 0;
            var block = new byte[blkSz];
            long rawRunBlocks = 0, rawChunkHdrPos = -1, zeroRun = 0;
            Action flushRaw = delegate
            {
                if (rawRunBlocks == 0) return;
                long end = outp.Position;
                outp.Position = rawChunkHdrPos + 4;
                w.Write((uint)rawRunBlocks);
                w.Write((uint)(12 + rawRunBlocks * blkSz));
                outp.Position = end;
                rawRunBlocks = 0; rawChunkHdrPos = -1;
            };
            Action flushZeros = delegate
            {
                if (zeroRun == 0) return;
                w.Write(DontCareChunk); w.Write((ushort)0);
                w.Write((uint)zeroRun); w.Write(12u);
                chunkCount++; zeroRun = 0;
            };
            for (long b = 0; b < totalBlks; b++)
            {
                int read = 0;
                while (read < blkSz)
                {
                    int n = inp.Read(block, read, blkSz - read);
                    if (n == 0) { Array.Clear(block, read, blkSz - read); break; }
                    read += n;
                }
                if (IsZero(block, blkSz)) { flushRaw(); zeroRun++; }
                else
                {
                    flushZeros();
                    if (rawRunBlocks == 0)
                    {
                        rawChunkHdrPos = outp.Position;
                        w.Write(RawChunk); w.Write((ushort)0); w.Write(0u); w.Write(0u);
                        chunkCount++;
                    }
                    w.Write(block, 0, blkSz);
                    rawRunBlocks++;
                    if (rawRunBlocks >= maxRawBlocks) flushRaw();
                }
            }
            flushRaw(); flushZeros();
            outp.Position = 20; w.Write((uint)chunkCount);
            w.Flush();
        }
    }
}
"@

function ConvertTo-SparseImage([string]$RawPath, [string]$SparsePath) {
    try { Add-Type -TypeDefinition $SparseCode -ErrorAction Stop }
    catch { Fail "Could not build the sparse converter: $($_.Exception.Message)" }
    [NabuSparse]::Convert($RawPath, $SparsePath, 4096, 16384)
}

function Get-ImageSizeValue([string]$Key) {
    $sizeFile = Join-Path $ScriptDir "image-size.txt"
    if (-not (Test-Path -LiteralPath $sizeFile)) { return "" }
    $value = ""
    foreach ($line in Get-Content -LiteralPath $sizeFile) {
        if ($line -match ("^" + $Key + "=(\d+)$")) { $value = $Matches[1] }
    }
    return $value
}

$ImgZstPath = Join-Path $ScriptDir "linux.img.zst"
$ImgPath = Join-Path $ScriptDir "linux.img"

Write-Host "=== CachyOS Nabu Flasher (Windows) ==="
Write-Host ""
Write-Host "This will install CachyOS ARM on your Xiaomi Pad 5."
Write-Host "The existing contents of the linux partition will be erased. Slot A is preserved as fallback."
Write-Host "Windows path tested once on Windows 11 + nabu (v1.5.0); see README."
Write-Host ""

if (-not (Get-Command fastboot -ErrorAction SilentlyContinue)) {
    Fail "fastboot not found. Install Google platform-tools and put fastboot.exe on PATH."
}
foreach ($f in @("boot.img", "linux.img.zst", "vbmeta_disabled.img")) {
    if (-not (Test-Path -LiteralPath (Join-Path $ScriptDir $f))) {
        Fail "$f not found in $ScriptDir"
    }
}

Test-BundleHashes

Write-Host "Checking device connection..."
$devices = & fastboot devices
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($devices -join ""))) {
    Fail "No device found. Boot tablet into fastboot (Vol Down + Power)."
}
Write-Host "  Device found."
Write-Host ""

$partState = Test-FastbootPartition "linux"
if ($partState -eq "timeout") {
    Write-Host "WARNING: the bootloader did not answer 'fastboot getvar'."
    Write-Host "         Skipping the partition-table check - fastboot itself fails"
    Write-Host "         loudly if the 'linux' partition is missing."
    Write-Host ""
}
elseif ($partState -ne "present") {
    Write-Host "ERROR: this device has no partition named 'linux'." -ForegroundColor Red
    Write-Host ""
    Write-Host "The nabu kernel boots with root=PARTLABEL=linux, but the stock"
    Write-Host "Xiaomi partition table names that partition 'userdata'. Creating or"
    Write-Host "renaming it (README Options A/B) needs a macOS/Linux host - there"
    Write-Host "are no Windows partition scripts yet. Prepare the tablet there,"
    Write-Host "then come back to this script just for the flash."
    exit 1
}
else {
    Write-Host "  Found 'linux' partition."
}
Write-Host ""

$requiredMbText = Get-ImageSizeValue "IMG_SIZE_MB"
if ($requiredMbText) {
    $requiredMb = [Int64]$requiredMbText
    $partHex = Get-FastbootVarValue "partition-size:linux"
    if ($partHex -match "^0x[0-9a-fA-F]+$") {
        $partBytes = [Convert]::ToInt64($partHex.Substring(2), 16)
        $partMb = [Int64][Math]::Floor($partBytes / 1MB)
        if ($partMb -lt $requiredMb) {
            Fail "The 'linux' partition is ${partMb}MB but the image needs ${requiredMb}MB. Enlarge it with the tool that created it (see README, Option C)."
        }
        Write-Host "  Size check OK: partition ${partMb}MB >= image ${requiredMb}MB."
    }
    else {
        Write-Host "WARNING: could not read the partition size (got '$partHex') - skipping the size check."
    }
}
else {
    Write-Host "WARNING: image-size.txt missing or unparsable - skipping the partition-size check."
}
Write-Host ""

if ($env:FORCE_FLASH -eq "1") {
    Write-Host "FORCE_FLASH=1 set, skipping confirmation."
}
else {
    $reply = Read-Host "Ready to flash? This will erase the linux partition. [y/N]"
    if ($reply -notmatch "^[Yy]$") { exit 0 }
}

Write-Host ""
Write-Host "[1/5] Erasing dtbo_b + flashing vbmeta..."
Invoke-Fastboot @("erase", "dtbo_b")
Invoke-Fastboot @("flash", "vbmeta_b", (Join-Path $ScriptDir "vbmeta_disabled.img"))

Write-Host "[2/5] Flashing CachyOS kernel..."
Invoke-Fastboot @("flash", "boot_b", (Join-Path $ScriptDir "boot.img"))

Write-Host "[3/5] Preparing rootfs..."
$needDecompress = $false
if (-not (Test-Path -LiteralPath $ImgPath)) {
    $needDecompress = $true
}
elseif ((Get-Item -LiteralPath $ImgZstPath).LastWriteTime -gt (Get-Item -LiteralPath $ImgPath).LastWriteTime) {
    Write-Host "  linux.img is stale (older than linux.img.zst) - re-decompressing."
    $needDecompress = $true
}
if ($needDecompress) { Expand-Rootfs }

# A stale linux.img from another build must not be reused silently.
$requiredBytesText = Get-ImageSizeValue "IMG_SIZE_BYTES"
if ($requiredBytesText) {
    if ((Get-Item -LiteralPath $ImgPath).Length -ne [Int64]$requiredBytesText) {
        Write-Host "  linux.img size does not match image-size.txt - stale image. Re-decompressing."
        Remove-Item -LiteralPath $ImgPath -Force
        Expand-Rootfs
    }
}
elseif ($requiredMbText) {
    if ((Get-Item -LiteralPath $ImgPath).Length -lt ([Int64]$requiredMbText * 1MB)) {
        Write-Host "  linux.img is smaller than image-size.txt declares - stale image. Re-decompressing."
        Remove-Item -LiteralPath $ImgPath -Force
        Expand-Rootfs
    }
}

Write-Host "  SSH key injection is not supported by the Windows flasher - skipping."
Write-Host "  (SSH is key-only; add a key after first boot, or flash from macOS/Linux.)"

# Windows fastboot.exe is 32-bit: it cannot sparse-convert a ~10 GB raw
# image in memory (`-S` dies with std::bad_alloc). Pre-sparse instead,
# mirroring the Darwin img2simg path in flash.sh.
$SparsePath = Join-Path $ScriptDir "linux.sparse.img"
$needSparse = $false
if (-not (Test-Path -LiteralPath $SparsePath)) {
    $needSparse = $true
}
elseif ((Get-Item -LiteralPath $ImgPath).LastWriteTime -gt (Get-Item -LiteralPath $SparsePath).LastWriteTime) {
    Write-Host "  linux.sparse.img is stale (older than linux.img) - reconverting."
    $needSparse = $true
}
if ($needSparse) {
    Write-Host "  Converting rootfs to Android sparse format..."
    ConvertTo-SparseImage $ImgPath $SparsePath
}

Write-Host "[4/5] Flashing rootfs (this takes a while)..."
Invoke-Fastboot @("flash", "linux", $SparsePath)

Write-Host "[5/5] Setting boot slot and rebooting..."
Invoke-Fastboot @("set_active", "b")
Invoke-Fastboot @("reboot")

Write-Host ""
Write-Host "=== Flash complete! ==="
Write-Host ""
Write-Host "CachyOS will boot in ~60 seconds."
Write-Host ""
Write-Host "Default login: nabu (no password - SSH is key-only, see README)"
Write-Host ""
Write-Host "If it doesn't boot: hold Vol Down + Power -> fastboot set_active a"
