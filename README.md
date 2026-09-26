# mister-hybrid-platform

Shared platform layer for MiSTer **hybrid cores**. In a hybrid core a game engine runs on
the DE10-Nano's ARM Cortex-A9 and talks to a custom FPGA core through shared DDR3: video
frames or blitter command rings, the audio ring, joystick words and a scanout counter.

Every port (Solarus, the GameMaker/gmloader games, Godot 3 via FRT, Godot 4) had been
carrying hand-copied versions of the same plumbing. This repo is the one copy. Ports pull
it in as a **git submodule pinned to a tag**, at `external/mister-hybrid-platform`.

Design, inventory and migration order: [`docs/design.md`](docs/design.md).

## What is here

| Path | Status | What it is |
|---|---|---|
| `spec/profiles/*.toml` | ✅ | One DDR-map **profile** per FPGA core: `gm-fabric`, `solarus-fabric`, `openbor-classic`. Each lists regions, fields, control-block words, the mem_wc window, and **roles** (`video_ctrl`, `joy_p1`, `audio_ring`, `scanout_counter`, …) |
| `spec/gen.py` → `spec/generated/` | ✅ | C headers, SystemVerilog `.vh`, shell `.env`, Python/JSON, the runtime `mister_profiles.h` table, `mister_cores.tsv` (CORENAME → profile) |
| `spec/conform.py` + `spec/conformance/*.toml` | ✅ | Fails when a port's hand-typed constant disagrees with its profile. It generalises solarus `test_wire_constants.py` |
| `device/mem_wc/` | ✅ | The write-combining `/dev/mem` kernel module: source, build script and prebuilt `.ko`s |
| `device/sh/mem_wc_load.sh` | ✅ | The one safe loader: suite-wide union allowlist, never unloads under a live mapping |
| `build/docker/Dockerfile.base` | ✅ | `mister-armhf-base:bullseye`: snapshot-pinned bullseye, GCC 10 armhf, glibc 2.31, SCons |
| `build/cmake`, `build/make` | ✅ | Cross toolchain file and make fragment with one set of Cortex-A9 flags |
| `build/scripts/collect_runtime_libs.sh` | ✅ | Collects the DT_NEEDED closure and enforces GLIBC ≤ 2.31 |
| `device/sh/launch_lib.sh`, `main-hook/`, templates, `mister-port.toml` | ⏳ step 2 | The launcher kit and the shared `MiSTer_hybrid` `main=` binary |
| `lib/` (libmister) | ⏳ step 3 | DDR map/WC helper, video/audio/joystick, pacing, CPU isolation |
| `fabric/` | ⏳ step 4 | One `raster_backend_mfgpu` plus the `libmisterfabric` ABI |
| reusable CI workflows | ⏳ step 5 | |

## Using it from a port

```sh
git submodule add git@github.com:gmcnaught/mister-hybrid-platform.git external/mister-hybrid-platform
```

- **C/C++:** add `-Iexternal/mister-hybrid-platform/spec/generated` and define
  `MISTER_PROFILE_GM_FABRIC` (or the profile for your core) before
  `#include "mister_map_gm_fabric.h"`. That also gives you the unprefixed `MISTER_MAP_*`
  aliases, e.g. `MISTER_MAP_ROLE_SCANOUT_COUNTER`.
- **SystemVerilog:** `` `include "mister_map_gm_fabric.vh" `` gives qword addresses such as
  `` `MISTER_GM_FABRIC_FABRIC_SRC_QW ``.
- **Device shell:**
  1. Ship `device/sh/mem_wc_load.sh`, `spec/generated/mister_mem_wc.env` and
     `device/mem_wc/prebuilt/*.ko`.
  2. In the launcher, run:
     ```sh
     . ./mister_mem_wc.env; . ./mem_wc_load.sh
     mh_mem_wc_load ./mem_wc "$MISTER_GM_FABRIC_MEM_WC_BASE" "$MISTER_GM_FABRIC_MEM_WC_SIZE"
     ```
     (source `mister_map_gm_fabric.env` for the per-profile variables).
- **Until constants move to the generated headers:** keep a conformance file and run it in CI:
  `python3 external/mister-hybrid-platform/spec/conform.py spec/conformance/<port>.toml --root .`

## Adding a new core or engine

- **New FPGA core layout:** add `spec/profiles/<name>.toml`, list its CORENAMEs, run
  `spec/gen.py`. The validator rejects overlapping fields, a write-combined doorbell page
  and a CORENAME claimed by two profiles.
- **New engine on an existing core:** needs no spec change.

## Tests

`tests/run_all.sh` needs Python ≥ 3.11, dash and shellcheck. CI (`.github/workflows/ci.yml`)
also compiles the generated headers as C11 and C++17 and builds the base image. It
publishes the image to GHCR on `main` and on tags.
