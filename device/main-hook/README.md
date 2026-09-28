# MiSTer_hybrid — the shared `main=` hook

This is upstream Main_MiSTer with one call inserted after `scheduler_wait_fpga_ready()`
in `scheduler_co_poll()`. The call:

1. reads `/tmp/CORENAME` (via `user_io_get_core_name()`);
2. looks up `<CORENAME>.conf` in the `hybrid.d/` directory next to its own executable
   (`/proc/self/exe`, `overlay/hybrid_registry.c`);
3. if an entry exists and the `noengine` flag file is absent, spawns `launcher=` detached,
   with stdout/stderr going to `log=`.

A core with no entry behaves as stock MiSTer. Each port installs its own copy of the
binary and entry in `games/<gamedir>/platform/`. They are not under `linux/`, which the
Downloader refuses for every database but `distribution_mister`. `MiSTer.ini` routes each
hybrid core to its port's copy:

```ini
[CashCowDX]
main=/media/fat/games/CashCowDX/platform/MiSTer_hybrid
```

The entry is then read from `/media/fat/games/CashCowDX/platform/hybrid.d/CashCowDX.conf`.
`$MISTER_HYBRID_REGISTRY` overrides the directory (host tests).

The port's `Scripts/<Name>_CoresMenu.sh`, rendered by `mister-platform`, toggles that line.

## Why the call sits after the FPGA-ready wait

Maldita measured a hook that spawned the engine before the wait: it wedged the fabric on
frame 1 in 3 of 5 launches. After moving the call below the wait, it was 0 of 5.

## Build and test

```sh
device/main-hook/build-hps.sh          # -> build/main-hook/MiSTer_hybrid
UPSTREAM_COMMIT=<sha> device/main-hook/build-hps.sh
```

The build fails if the scheduler or user_io anchors are missing upstream, or if the hook
strings are not linked in. `test/test_registry.c` is the host test for the registry parser; it runs
from `tests/run_all.sh`.

## OSD Reset restart (opt-in per core)

Ported from maldita's `maldita_reset.*`. A core opts in with a status bit in its registry
entry; entries without `osd_reset=` never read the trigger latch and behave as before
(Cash Cow, Donut).

Manifest (`mister-port.toml`) and the registry lines it renders:

```toml
[launch]
osd_reset = 19          # CONF_STR "TJ,Reset;" -> status bit 19 (letter J = 19)
```

```ini
# games/<gamedir>/platform/hybrid.d/<CORENAME>.conf
osd_reset=19                                         # 0..31, else the entry is rejected
reset_clear=/tmp/mister-hybrid/<name>.retry          # launch_lib fabric-retry mark
reset_clear=/tmp/mister-hybrid/<name>.lock/pid       # launch_lib lock (file, then dir)
reset_clear=/tmp/mister-hybrid/<name>.lock
```

Behaviour, when MiSTer_hybrid itself spawned the launcher and the entry has `osd_reset=`:

1. `build-hps.sh` adds `user_io_status_trigger_take()` to upstream `user_io.cpp`: a sticky
   latch of single-bit sets of the 32-bit (non-extended) status word, i.e. CONF_STR `T`/`R`
   pulses, which are set and cleared inside one `HandleUI()` call. Anchored like the
   scheduler edit; the build fails if an anchor is missing or matches twice.
2. `hybrid_hook_poll()` drains the latch every scheduler iteration. A pulse on the bit:
   SIGTERM to the launcher's process group (it `setsid`s, so the engine it runs as a job
   gets it too) -> SIGKILL after 3 s -> after 2 s more, or as soon as the child is reaped:
   remove the `reset_clear=` paths in order (unlink, or rmdir a directory) and respawn
   `launcher=`. Presses during a restart are dropped, never queued. If the engine had
   already exited, a press respawns directly. Stepped per iteration (`hybrid_reset.c`), so
   the OSD never blocks. Nothing touches the FPGA; the RBF stays loaded.
3. Log lines (`log=`, the port's launch.log): `OSD Reset armed on status bit N`,
   `OSD Reset - restarting the engine (SIGTERM group PID)`,
   `OSD Reset - respawning the launcher (restart #N)`.

Host tests: `test/test_reset.c` (state machine), `test/test_registry.c` (parser).

## Other registry/manifest keys for pre-platform installs

For installs that predate the platform layout (maldita, cursed): `[port] corename` may
contain spaces (`"Maldita Castilla"`; the registry file is `hybrid.d/Maldita Castilla.conf`),
`[port] gamedir` (games/<gamedir> holds launch.sh, platform/ and the engine payload;
default name), `[port] mgl` (`_Other/<mgl>.mgl`), and `[launch]` `fail_pattern`,
`engine_log`, `test_env`. See `examples/maldita.castilla/mister-port.toml`.

## Replaces

MiSTer_Maldita, MiSTer_CursedCastilla, MiSTer_DonutDodo and MiSTer_CashCowDX. Each of those
was a separate Main_MiSTer build that differed only in compiled-in strings.
