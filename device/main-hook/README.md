# MiSTer_hybrid — the shared `main=` hook

This is upstream Main_MiSTer with one call inserted after `scheduler_wait_fpga_ready()`
in `scheduler_co_poll()`. The call:

1. reads `/tmp/CORENAME` (via `user_io_get_core_name()`);
2. looks up `/media/fat/linux/hybrid.d/<CORENAME>.conf` (`overlay/hybrid_registry.c`);
3. if an entry exists and the `noengine` flag file is absent, spawns `launcher=` detached,
   with stdout/stderr going to `log=`.

A core with no entry behaves as stock MiSTer. `MiSTer.ini` routes each hybrid core here:

```ini
[CashCowDX]
main=/media/fat/linux/MiSTer_hybrid
```

The port's `Scripts/<Name>_CoresMenu.sh`, rendered by `mister-platform`, toggles that line.

## Why the call sits after the FPGA-ready wait

Maldita measured a hook that spawned the engine before the wait: it wedged the fabric on
frame 1 in 3 of 5 launches. After moving the call below the wait, it was 0 of 5.

## Build and test

```sh
device/main-hook/build-hps.sh          # -> build/main-hook/MiSTer_hybrid
UPSTREAM_COMMIT=<sha> device/main-hook/build-hps.sh
```

The build fails if the scheduler anchor is missing upstream, or if the hook strings are
not linked in. `test/test_registry.c` is the host test for the registry parser; it runs
from `tests/run_all.sh`.

## Not yet ported

Maldita's OSD "Reset" engine restart (`maldita_reset.*`). It also needs an upstream
`user_io.cpp` edit to latch the trigger bit. Until it is ported, maldita and cursed keep
their own wrapper builds; donut and cash.cow do not use the Reset restart.

## Replaces

MiSTer_Maldita, MiSTer_CursedCastilla, MiSTer_DonutDodo and MiSTer_CashCowDX. Each of those
was a separate Main_MiSTer build that differed only in compiled-in strings.
