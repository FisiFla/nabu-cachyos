# CachyOS parity notes

Short answer: this build was never very behind. The kernel tracks
Kumar-Jy/linux `nabu/7.3.y` (rolling), the userland is rolling Arch Linux
ARM, and the CachyOS package pins in `rootfs/upstream-pins.sh` were about
a month old at last refresh. The parity gaps were specific, not general
"oldness":

## Fixed in this batch

- **Kernel patch content.** The 6.17-era BORE/BBR3/ADIOS/v4l2loopback
  patches no longer applied to 7.3 and were silently skipped, so the
  shipped "CachyOS kernel" ran without them. The set now comes from
  CachyOS/kernel-patches 7.3 (plus the nabu device patches, rebased),
  every patch is build-critical, and `kernel/verify-patches.sh` checks
  the whole set against a checkout in seconds. See
  `kernel/patches/SOURCES.md`.
- **Ananicy.** `cachyos-settings` was installed `--nodeps`, so Ananicy
  (a dependency, not part of that package) was never installed. Now
  `ananicy-cpp` + `cachyos-ananicy-rules` are installed and enabled,
  with CachyOS's own aarch64 source pins.
- **Existing-user update helper.** `cachy-update` is now built in-image;
  it manages Arch + Chaotic-AUR updates (plus any enabled repo). It does
  not update this project's kernel until the signed repo exists.
- **Kernel updates without a host PC.** `nabu-kernel-flash` can assemble
  (and, with explicit `--yes`, flash) a boot image on the tablet itself,
  matching the image-build artifacts exactly (no ramdisk; direct boot on
  `boot_b` with Android slot A untouched).
- **Package plumbing.** `packaging/` + `.github/workflows/repo.yml` +
  `packaging/publish-repo.sh` provide the signed-repo pipeline. The
  `[nabu-cachyos]` stanza ships commented in `pacman.conf` until the
  maintainer generates a key and publishes. See `packaging/README.md`.
- **Package builds.** `cachyos-packageinstaller` now has its Qt6/Polkit
  and Rust/scdoc makedepends available in the builder image.

## Deliberately not pursued on nabu

- CachyOS's x86-64-v3/v4 repositories (architecture different; Arch Linux
  ARM remains the base).
- Calamares installer, btrfs/snapper layout, desktop gaming metapackages.
- Desktop tuning constants (1000 Hz, full preemption, `NO_HZ_FULL`,
  THP-always) — real battery costs on a tablet, need on-device data.
- sched-ext (`scx-scheds` is installed, nothing enabled). Candidates
  `scx_lavd` / `scx_bpfland` need latency + battery measurement first;
  `docs/scx-scheds.md` covers clean enable/disable.

## Still open (needs a tablet, not code)

- Benchmark BORE vs stock scheduler with/without `scx_lavd`.
- Re-test hardware video decode after the rebased iris patch (upstream
  superseded most of the old one; two deltas remain).
- Minute-level latency/power comparison before considering CachyOS
  desktop `sysctl` defaults wholesale.
