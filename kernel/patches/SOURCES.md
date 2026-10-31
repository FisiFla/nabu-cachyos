# Kernel patch provenance

Patch set rebased and `git apply --check`-verified **sequentially** against
Kumar-Jy/linux `nabu/7.3.y` @ `d3bc957cf96c` on 2026-10-31. Re-verify after
any upstream bump with `../verify-patches.sh <kernel-tree>`. Every patch is
critical by default in `build-kernel.sh` (`KERNEL_CRITICAL_PATCHES` relaxes
this for other trees) — a patch that stops applying must fail the build,
not silently fall out of the shipped kernel.

| Patch | Upstream source | Notes |
|---|---|---|
| `0001-bore-cachy.patch` | [CachyOS/kernel-patches](https://github.com/CachyOS/kernel-patches) `7.3/sched/0001-bore-cachy.patch` @ `5429485ec36c` (BORE 7.3.2) | 5 context hunks rebased onto the nabu scheduler/debug state |
| `0002-bbr3.patch` | [CachyOS/linux](https://github.com/CachyOS/linux) `net/ipv4` cherry-pick series (`5b121d2f38a1`, `a52f7242dab6`, intermediate squash) | Registers its own `bbr3` module next to mainline BBR; Kconfig/Makefile wires hand-merged |
| `0003-adios.patch` | ADIOS v3.3.0, `block/adios.c` blob `e55d966a` from CachyOS/linux master | Kernel-side only; DKMS packaging hunks dropped |
| `0004-v4l2loopback.patch` | Carved out of the former `0004-cachy-arm.patch` squash | Only surviving content of that squash; the rest was zlib/x86/frame-vector leftovers and was dropped |
| `0005-fastrpc-fix-init-create-static-pageslen.patch` | Own patch (NAS-247) | Rebased 2026-10-31: upstream reworked the function; same fix expressed at the new call site |
| `0006-iris-sm8150-hfi-init.patch` | Own patch, reduced 2026-10-31 | Upstream `legacy_vpu5` support superseded most of the original; only the two remaining deltas are carried. Needs on-device decode retest |

The former `0004-cachy-arm.patch` also carried zlib `DEFLATE_PREFER_RISCV`
wiring and an x86 frame-vector revert — both no-ops or wrong-arch on arm64 —
plus wild over-broad include context. Nothing else from it is needed.
