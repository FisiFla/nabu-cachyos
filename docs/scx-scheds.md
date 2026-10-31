# Trying sched-ext (SCX) schedulers on nabu

`scx-scheds` is installed in the image but nothing is enabled. The
in-kernel BORE scheduler (from the CachyOS patch set) is the default.
No SCX scheduler has been measured on this tablet yet; treat this page
as a safe way to experiment, not a recommendation.

## Try one manually (stops at Ctrl+C / reboot)

```bash
cat /sys/kernel/sched_ext/root/ops        # empty = in-kernel scheduler running
sudo scx_loader list                       # schedulers present in scx-scheds
systemctl status scx_loader.service        # may be inactive; that's fine

# Start e.g. scx_lavd through the loader's D-Bus API (or run scx_lavd directly):
busctl call org.scx.Loader /org/scx/Loader org.scx.Loader StartScheduler su scx_lavd 1
cat /sys/kernel/sched_ext/root/ops         # should now show lavd
```

## Make it the boot default (after testing by hand)

```bash
systemctl enable scx_loader.service
# Configure the default in /etc/scx_loader/config.toml per scx_loader docs.
```

## Turn it off / recover a bad scheduler

```bash
busctl call org.scx.Loader /org/scx/Loader org.scx.Loader StopScheduler
systemctl disable --now scx_loader.service
```

If a scheduler misbehaves, sched-ext fails safe: killing the userspace
scheduler (or rebooting) falls back to the in-kernel scheduler. Nothing
here touches the boot partition, so worst case is a laggy session.

## Worth measuring (help wanted)

- UI/input latency under BORE (default) vs `scx_lavd` vs `scx_bpfland`.
- Battery drain at idle and under mixed load for each.
- Frame pacing in Chromium/video playback (hardware decode via iris).

Report results on the issue tracker; a default enablement decision
needs tablet numbers, not desktop CachyOS defaults.
