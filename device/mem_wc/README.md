# mem_wc — write-combining `/dev/mem` for fabric-shared DDR

`mem_wc.c` is vendored unmodified from [skmp/minicast](https://github.com/skmp/minicast)
(GPL-2.0) via `gmcnaught/mamester` PR #5. This is the single copy for the suite. It replaces the
byte-identical copies that were in solarus-mister, maldita/cursed.castilla-mister,
donut.dodo-mister and cash.cow.dx-mister.

## Why it exists

A `/dev/mem` mmap of fabric DDR (above `System RAM`, which ends at `0x1FEFFFFF` on the
DE10-Nano) is **always Strongly-Ordered**, whatever the `open()` flags. ARM's
`phys_mem_access_prot()` returns `pgprot_noncached()` when `pfn_valid()` is false.
Strongly-Ordered stores never merge. This driver maps with `pgprot_writecombine()`.

Measured on the device:

| Mapping | Throughput | Source |
|---|---|---|
| `/dev/mem` | 80–91 MB/s | solarus `docs/superpowers/data/ddr-write-bench-2026-08-07.md` |
| `/dev/mem_wc` | 814–866 MB/s | same |

That is a 9–18× gain.

## Ordering rules the engine must keep

- **Barrier before the doorbell.** Every store the fabric polls (the doorbell) must be
  preceded by `dsb sy`. `__sync_synchronize()` is `dmb ish` on ARMv7 and does NOT order
  against the f2h ports.
- **Control page stays Strongly-Ordered.** Only the profile's `wc_ranges` (see
  `spec/profiles/*.toml`) are overlaid write-combining, page-exactly, with `MAP_FIXED`.
- **Probe before overlaying.** Probe each range at a kernel-chosen address first. A
  rejected `MAP_FIXED` leaves a hole in the mapping, not the old mapping.

## Loading

Use `device/sh/mem_wc_load.sh`; do not hand-roll `insmod`. It:

- loads the module once, with the suite-wide union allowlist
  (`spec/generated/mister_mem_wc.env`, currently `0x3B000000 + 18 MiB`), so a gm-fabric
  port and Solarus never need different allowlists;
- never force-unloads, and never unloads while anything maps `/dev/mem_wc`.

The module is optional by design. Engines fall back to `/dev/mem` on their own.

## Prebuilt objects

Prebuilt modules are in `prebuilt/mem_wc-<uname -r>.ko`: 5.15.1-MiSTer and 6.18.38-MiSTer.
These are the objects shipped in solarus-mister v1.2.0.

To build for a new MiSTer kernel:

```
bash device/mem_wc/build.sh --host <mister-ip>          # config + release read from the device
bash device/mem_wc/build.sh --config cfg --release 6.18.38-MiSTer
```

The build runs in `debian:bookworm` with the ARM 10.2-2020.11 toolchain (the one named in
the device's `/proc/version`). It fails unless the vermagic matches and every imported
symbol is exported. The final check is an `insmod` on the device. After that, commit the
new `prebuilt/` file and bump the platform tag.
