# nabu-cachyos packaging

PKGBUILDs for the project-owned packages, shared between the image build
and the signed pacman repo the image's `pacman.conf` points at (shipped
commented out until the repo is live).

**Status: untested on hardware.** Kernel artifacts from
`linux-nabu-cachyos` need a real-device boot test before any repo enables
by default.

## Packages

| Path | What |
|---|---|
| `linux-nabu-cachyos/` | Kumar-Jy `nabu/7.3.y` tree + `kernel/patches/` + `cachyos.config` + SLPI enablement. Source build; any failed patch aborts. |
| `nabu-boot-tools/` | `nabu-kernel-flash` (stage by default; never auto-flashes), stage-only alpm hook, `/etc/nabu/boot.cmdline`. |
| `nabu-cachyos-keyring/` | Repo signing keyring; needs maintainer-supplied key files (below). |
| `nabu-pmac/`, `nabu-torch/` | Imported 2026-10-31 from Kumar-Jy/nabu-pkgs @ `0ba83295a59f2f868a5f73a50a56a69a3f1a7ea3`; local-file checksums filled. |

## Build

```bash
bash packaging/prepare-sources.sh       # copies canonical files beside PKGBUILDs
(cd packaging/nabu-torch && makepkg -f)
```

## Publishing the repo

One-time setup (maintainer, offline machine):

1. Generate a dedicated signing key, export it:
   `gpg --quick-generate-key "nabu-cachyos packaging" ed25519 sign 3y`
2. Put the public key + trust lines in `nabu-cachyos-keyring/`:
   `gpg --armor --export <fp> > nabu-cachyos.gpg`;
   `echo "<fp>:4:" > nabu-cachyos-trusted`; `touch nabu-cachyos-revoked`.
   Never commit the private key.
3. In `FisiFla/nabu-cachyos` → Settings → Secrets and variables → Actions,
   add `NABU_GPG_PRIVATE_KEY`, `NABU_GPG_PASSPHRASE`, `NABU_GPG_KEY_ID`
   (full fingerprint). Enable GitHub Pages from the `gh-pages` branch.
4. Run Actions → "Package repo" once as dry-run (all inputs off), then
   with `sign` + `publish` on.

`packaging/publish-repo.sh` does the same locally:
`NABU_GPG_KEY_ID=<fp> bash packaging/publish-repo.sh`. Signing is
mandatory; `ALLOW_UNSIGNED=1` is a local-testing escape hatch only.

On-device adoption (after a published keyring exists): uncomment the
`[nabu-cachyos]` stanza in `/etc/pacman.conf`, install
`nabu-cachyos-keyring`, then `sudo pacman -Syu`.
