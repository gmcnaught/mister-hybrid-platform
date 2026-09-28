# MiSTer hybrid-port shared platform — inventory + proposal

Date: 2026-09-26. Scope: solarus-mister, maldita.castilla-mister, cursed.castilla-mister,
gmloader-next, donut.dodo-mister, cash.cow.dx-mister, mister-fpga-blitter, mister-astgrep,
MiSTer_OpenBOR_7533, HYBRID-CORE-GUIDE.md. All findings are from read-only inspection of the
local checkouts on this date.

---

## 1. Inventory — how code actually moves between ports today

Lineage (observed from commit history, VENDOR.md files and "ported from" comments):

```
MiSTer_OpenBOR_7533 (native_video/audio_writer, openbor_video_*.sv, deploy.py)
  └─► solarus-mister  (+ mem_wc, blitter fork, patch-series, wire-constants CI)
        └─► maldita.castilla-mister  ("fork Solarus FPGA project into Maldita", 2026-07-14)
        │     ├─► cursed.castilla-mister   (rebrand fork, 2026-08-22)
        │     └─► branch donutdodo/fb-320x240 = the RBF donut + cash.cow ship
        └─► gmloader-next/gmloader/mister  (writers "lifted from solarus")
              └─► donut.dodo-mister/src/vendor   (copied 2026-08-22)
                    └─► cash.cow.dx-mister/src/vendor (copied 2026-09-23, + CPU opts)
mister-fpga-blitter ─(submodule)─► gmloader-next only; copied everywhere else
```

The only real dependency is the `3rdparty/mfgpu` submodule in gmloader-next. Everything else was copied by hand, and every copy has since been edited.

### 1.1 Duplication table

| Concern | Copies | State |
|---|---|---|
| `mem_wc.c` kernel module + prebuilt `.ko` | 6 byte-identical (solarus, maldita, cursed, donut, cash.cow, wt-maldita-present) | 3 build scripts, 3 different load snippets (`mem_wc_load.sh`, 2× inline in launch.sh, solarus_run.sh) |
| `/dev/mem` / `/dev/mem_wc` mapping code | about 15 open/mmap sites, no shared helper | WC overlay logic in 4 variants (solarus renderer, gmloader-next, donut, cash.cow) |
| DDR address constants | 5+ places per port (C, SV, shell `devmem`, Python probes, docs) | Solarus's layout is different from the GM core's layout. **0x3BF40000 means TL_BUF on the Solarus core and FB/joystick on the GM core**; scanout counter is at 0x3A070000 on Solarus and 0x3BFB0018 on the GM core |
| C↔SV constant check | solarus `test_wire_constants.py` (CI) | maldita copy points at paths that don't exist; disabled |
| native video/audio writers | 3 separate lines of copies (OpenBOR→solarus→gmloader-next→donut/cash.cow) + Godot 4 re-implementation | different sizes, 288×216 vs 320×240 set by editing `blitter_ref.h` |
| `raster_backend_mfgpu.cpp` (fabric backend) | 3 copies (gmloader-next, donut, cash.cow) | about 416 differing lines; cash.cow's CPU optimizations not upstream; uses `GMLOADER_*` env names in Godot ports |
| blitter host/RTL | Solarus: fork (801-line diff in emitter); M/C: `blitter_top.sv` 2953 lines against upstream's 530 | upstream RTL is not used as-is by any port |
| Docker build image | 5 Dockerfiles, all bullseye / gcc-10 / glibc 2.31 | 3 different workarounds for the bullseye apt EOL; maldita's copy has none (will 404); donut `FROM`s gmloader-next's local image, undocumented |
| `launch.sh` skeleton | 4 (maldita 649 lines, solarus_run 359, cash.cow 245, donut) | lock, reaping the "family" by a hand-maintained process-name list, FPGA-ready wait, mem_wc load, fabric gate, watchdog, CPU isolate — each port has a different subset |
| `main=` Main_MiSTer wrapper hook | 4 (maldita, cursed, donut, cash.cow) | identical except for the rename; pinned to Main_MiSTer `3380931` |
| Scripts/*.sh + CoresMenu toggle | 4 | rename-only |
| `deploy.py` | 2 main variants (solarus 385 lines, maldita 906); donut/cash.cow use shell scripts | shared `scp_verified` core; host `192.168.20.81` hardcoded everywhere |
| CI workflows | solarus 15, maldita 4, gmloader-next 1, donut/cash.cow 0 | `build-rbf.yml` / `release.yml` / `ast-grep.yml` diverged copies |
| ast-grep rules | `mister-astgrep` exists and is designed for submodule use | **adopted by 0 repos**; the old per-repo copies have drifted |
| Platform docs | HYBRID-CORE-GUIDE.md, solarus `CLAUDE.md` (33 KB), per-port PLAN/HANDOFF | guide predates mem_wc, libmfgpu, donut and cash.cow |

### 1.2 Engine-specific pieces (these stay per engine)

- **Solarus:** SDL software renderer → `mister_blitter_renderer.cpp` (its own blitter protocol), OpenAL loopback audio, `.s0` quest loading.
- **GameMaker (gmloader-next):** GLES → `RasterBackend` vtable → mfgpu TRILIST; joy tape; gmloader.json.
- **Godot 3 (donut):** SDL2 patches 0003/0004/0005/0007 plus `libmisterglue` (GLES2 shadow `godot_shadow.cpp`, null GL).
- **Godot 4 (cash.cow):** native `DisplayServerMister`, `audio_driver_mister`, `joypad_mister`, fabric bridge, and `libmisterfabric` C ABI (`mf_open/mf_draw/mf_present`, the cleanest engine-agnostic fabric API in the suite).

Note: donut's SDL2 drivers (audio ring, DDR joystick, DDR present, glue dlopen, null GL) are not Godot-specific. Any SDL2 engine can reuse them (LÖVE, Solarus's SDL, future ports).

---

## 2. Proposal — `mister-hybrid-platform`

A new repo, consumed by every port as a **git submodule at `external/mister-hybrid-platform`** pinned to a tag. This follows the same pattern as gmloader-next→mfgpu and the design mister-astgrep already expects. It is organised as layers, so a new engine adds one adapter and a new game adds one manifest.

```
mister-hybrid-platform/
  spec/          L0  DDR map "profiles" (YAML) → generated C / SV / sh / py
  lib/           L1  libmister: engine-agnostic C (DDR map, writers, pacing, cpu isolate)
  fabric/        L1b fabric backend + libmisterfabric ABI (links mister-fpga-blitter)
  adapters/      L2  per-engine glue: sdl2/, godot3-frt/, godot4/, gmloader/ (thin)
  device/        L3  on-MiSTer shell kit, mem_wc, main= hook, Scripts templates
  build/         L4  base Docker image, toolchain, runtime-lib collector, patch tooling
  ci/            L5  reusable GitHub workflows (workflow_call)
  tools/         L6  deploy core, probes, screenshot, joy inject
  docs/              HYBRID-CORE-GUIDE (moved here) + new-port checklist
```

### L0 — `spec/`: one source of truth for the DDR map

- Add `spec/profiles/{openbor-classic,gm-fabric,solarus-fabric}.yaml`. Each profile holds regions, offsets, control words, FB dims and the scanout-counter address.
- `spec/gen.py` emits `mister_map_<profile>.h`, `mister_map_<profile>.vh`, `.env` (for `devmem` in shell), and `.py`.
- Generalise solarus's `test_wire_constants.py` into a CI check that the generated files are up to date and that the RTL/C in each port includes the generated file instead of redefining constants.
- **Makes the 0x3BF40000 conflict explicit:** every engine binary and launcher declares its profile. The launcher checks that the loaded core (`/tmp/CORENAME` → profile table) matches before it touches DDR. This removes the "silent wrong base" trap in donut PLAN §1i.
- FB dims (288×216 / 320×240) become a profile field, instead of an edit to `blitter_ref.h` that re-vendoring silently undoes.

### L1 — `lib/`: libmister (C, static lib + CMake target + plain Makefile fragment)

| Module | Consolidates |
|---|---|
| `mister_ddr` — `mister_map(profile, region, MISTER_MAP_SO/WC)` with probe → WC overlay → SO fallback, one fd policy | about 15 ad-hoc mmaps; 4 WC-overlay variants |
| `mister_video` — RGB565 double buffer + control word | OpenBOR / solarus / gmloader-next writers, Godot 4 display-server copy |
| `mister_audio` — 48 kHz ring writer (+ optional pump thread pinned to CPU1) | 3 writers + SDL patch 0004 + Godot 4 driver |
| `mister_joy` — DDR joystick read, button bitmask, profile-aware base | `joy_ddr_reader`, SDL patch 0005, `joypad_mister`, solarus poll |
| `mister_pace` — scanout-counter or timer pacing | `mister_pace.h`, donut `pace_frame`, cash.cow `mf_pace` |
| `mister_cpu` — `cpu_isolate_sweep` | solarus + gmloader-next `cpu_isolate.c` |
| `mister_env` — `MISTER_*` names, with `GMLOADER_*`/`SOLARUS_*` read as deprecated aliases | env-name drift (`GMLOADER_NO_WC` in Godot ports) |
| `fps_overlay.h` | solarus → donut copies |

### L1b — `fabric/`

- `libmfgpu`, the emitter, refmodel and the blitter RTL contract **stay in mister-fpga-blitter**; it is the HW contract. The platform submodules it.
- `raster_backend_mfgpu.cpp` and cash.cow's `libmisterfabric` C ABI move into the platform as one library. Cash.cow's CPU optimisations get merged, `blt_emitter` optimisations go upstream to mister-fpga-blitter, and dims come from the L0 profile.
- gmloader-next, donut and cash.cow all link this library. Their `src/vendor/` trees are deleted.
- The Solarus blitter fork is **out of scope for now**. It ships v1.2.0, has its own protocol, and is recorded as the `solarus-fabric` profile. Converge it only when there is a measured reason.

### L2 — `adapters/`: where a new engine plugs in

- `adapters/sdl2/`: donut patches 0003/0004/0005/0007 as a patch series against pinned SDL2 2.32.x, built on libmister. This is the default path for any SDL2 engine.
- `adapters/godot3-frt/`: `libmisterglue`, `godot_shadow`.
- `adapters/godot4/`: display server, audio, joypad and fabric bridge, plus `apply_godot_mister.py`.
- `adapters/gmloader/`: only a build-glue doc. gmloader-next keeps its code but links libmister and the fabric library.
- **Contract for a new adapter:** implement video present (SW or fabric), audio sink, input source and pacing hook against libmister, and declare a profile. The adapter README lists this checklist.

### L3 — `device/`: on-MiSTer runtime

- `mem_wc/`: source, a single `build.sh` (solarus's vermagic-checking version), and prebuilt `.ko` files per kernel.
- `sh/launch_lib.sh`, sourced by every port's `launch.sh`. It provides:
  - `ml_lock`
  - `ml_reap_fabric_engines`, using **one shared `/var/run/mister-fabric.pid` claim** instead of the hand-maintained `gmloader frt_3.5.2 cashcowdx` list
  - `ml_wait_fpga_ready`, `ml_load_mem_wc`, `ml_fabric_gate`, `ml_watchdog`, `ml_cpu_isolate` / `ml_cpu_restore`, `ml_check_profile`
- `main-hook/`: **one shared `MiSTer_hybrid` binary** in place of one Main_MiSTer build per game.
  - Today each hook compiles in its core name, launcher path and NOENGINE path (e.g. `cash.cow.dx-mister/tools/mister-wrapper/overlay/cashcow_hook.cpp:27-35`). As a result, maldita, cursed, donut and cash.cow each build and ship their own copy of Main_MiSTer @`3380931`, differing only in those strings.
  - Proposed: the hook runs after `scheduler_wait_fpga_ready()` as it does now. It reads `/tmp/CORENAME` and looks up `hybrid.d/<CORENAME>.conf` next to its own executable, which gives `launcher=`, `noengine=` and `profile=`. If there is no entry it does nothing.
  - Installing a port means shipping the binary plus its `.conf` in `games/<gamedir>/platform/` and adding its `[Core] main=/media/fat/games/<gamedir>/platform/MiSTer_hybrid` line to MiSTer.ini. There is one binary to rebuild when the Main_MiSTer pin moves, and one `build-hps.sh`.
  - Revised in v0.4.0: v0.3.x put one shared copy at `linux/MiSTer_hybrid` with `linux/hybrid.d/`. The Downloader refuses the `linux/` root folder for every database except `distribution_mister`, so update_all blocked Maldita Castilla v0.4.0 (theypsilon/MultiDatabases_MiSTer#9). A per-port copy also avoids two databases claiming the same file.
  - The `child` reset (CPU mask / signal state before exec) and the reset-trigger poll (`user_io_status_trigger_take`) move into the same hook.
- **Start-up methods to converge:**

  | Port | How the engine starts |
  |---|---|
  | maldita, cursed, donut, cash.cow | `main=` hook |
  | solarus | `solarus_daemon.sh` polling `/tmp/CORENAME` from `user-startup.sh` (it gives way to Frontier's `Master_Daemon`) |
  | maldita (opt-in) | `mister_takeover.sh` |

  - Recommendation: `main=` is the default. It is the only one tied to FPGA-ready, and the daemon approach has caused interference between ports (cash.cow PLAN §6.18).
  - The daemon is kept only as a fallback template, for users who won't edit MiSTer.ini.
  - Solarus moves over in step 7.
- `templates/`, all rendered from the manifest:
  - `Scripts/<Name>.sh`, which loads the RBF via `/dev/MiSTer_cmd`.
  - `<Name>_CoresMenu.sh`, which toggles the `[Core] main=` line with a backup.
  - `hybrid.d/<CORENAME>.conf` and the `.mgl`.
  - A `launch.sh` of about 20 lines that sources `launch_lib.sh` and sets the port's `exec` and `env`.

### Port manifest — the extensibility hook

Each port repo holds one `mister-port.toml`:

```toml
name        = "CashCowDX"
engine      = "godot4"          # selects adapters/godot4
profile     = "gm-fabric"       # selects spec/profiles/gm-fabric.yaml
fb          = [320, 240]
rbf_glob    = "_Other/CashCowDX_*.rbf"
gamedir     = "/media/fat/games/CashCowDX"
exec        = "./cashcowdx --display-driver mister --main-pack CashCowDX.pck"
cpu_isolate = true
env         = { MISTER_JOY = "1" }
```

`mister-platform render` generates the launch.sh wrapper (a thin script that sources `launch_lib.sh`), the `hybrid.d/<CORENAME>.conf` main-hook entry, the Scripts and CoresMenu entries, the MGL, the release-zip layout and the deploy config. Adding game #7 on an existing engine then takes a manifest plus game data.

### L4 — `build/`

- One `mister-armhf-base:bullseye` image: snapshot.debian.org pin (solarus's version), gcc-10, glibc 2.31, cmake, scons 4.5.2 (hash-pinned wheel), pkg-config shim, LTO `gcc-ar` links. Publish it to GHCR, and have engine images `FROM` it. This retires the three EOL workarounds and donut's undocumented local-image dependency.
- `cmake/arm-linux-gnueabihf.toolchain.cmake` and a `mister-flags.mk` using `-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard`. This enforces the `neon-vfpv4` SIGILL lesson in one place.
- `collect_runtime_libs.sh` (from solarus; it checks GLIBC ≤ 2.31).
- Patch-series tooling (solarus `apply/export/verify_patches.sh`), with the upstream SHA as a parameter.

### L5 — `ci/`: reusable workflows

- `build-rbf.yml` (Windows self-hosted → raetro fallback → NAS, `check_quartus_gates`), `release-assemble.yml`, `ast-grep.yml` (via mister-astgrep), `spec-drift.yml`, `shellcheck.yml`, `host-tests.yml`.
- Each port's workflow becomes a roughly 10-line `uses: gmcnaught/mister-hybrid-platform/.github/workflows/x.yml@vN`. This gives donut and cash.cow CI they currently lack.

### L6 — `tools/`

- The `deploy.py` core: `scp_verified`, the `guard-host`/`PROD=1` production guard, RBF provenance via `resolve_rbf.py`, and host taken from env or a config file instead of hardcoded.
- Profile-aware probes: `fps_probe`, `audio_ring_probe`, `fb_row_probe`, `joy_inject`, and one `fabric_probe` replacing gmloader-next's 6 copies.
- Screenshot capture via `/dev/MiSTer_cmd`.

### FPGA (deferred, optional)

- Donut and cash.cow already ship the maldita core (`core_variant`). Cash.cow PLAN §6.23 proposes one shared RBF plus a per-game MRA.
- Later step: extract the GM-fabric core into its own repo that produces one RBF, with per-game branding through MRA/CONF_STR variants. Cursed stops carrying a fork of it.
- Shared RTL (sys/ patch, `openbor_video_*`, `gm_audio.sv`, jtframe provenance) would go in an `rtl/` directory in that repo.
- This is held back because RTL changes need timing closure and a visual analog check (the SDRAM-burst rollback showed that counters can pass while video is broken). It gives the least benefit per unit of risk.

---

## 3. Migration order

Ordered by value divided by risk. Each step is independently shippable; ports adopt a step when they next need it.

| Step | Work | Risk | First consumers |
|---|---|---|---|
| 0 | Create the repo, move `mem_wc`, base Docker image, toolchain file | none (byte-identical) | all |
| 1 | `spec/` + codegen + drift CI; `gm-fabric` and `solarus-fabric` profiles | low | donut, cash.cow (same profile; no CI today) |
| 2 | `device/launch_lib.sh` + `main-hook` + templates + manifest renderer | low–med (device behaviour) | cash.cow → donut → maldita/cursed |
| 3 | `lib/` libmister: DDR map, audio, joy, pace, cpu, env aliases | med | cash.cow, donut, then gmloader-next |
| 4 | `fabric/`: single raster backend + libmisterfabric ABI, merge cash.cow opts | med (perf-sensitive; A/B fps gate) | gmloader-next, donut, cash.cow |
| 5 | Reusable CI + mister-astgrep adoption | low | all |
| 6 | `adapters/sdl2` as a patch series | low | next SDL2 engine |
| 7 | Solarus migration of steps 0–3 only (not its blitter) | low after v1.2.0 | solarus |
| 8 | Shared GM-fabric core repo | high | maldita, cursed, donut, cash.cow |

Verification per step: host tests in the platform, then per port an fps A/B on the device (DDR counter), an audio ring probe, and a visual analog check whenever RTL or scanout changes.

---

## 4. Defects found during inventory (fix regardless of the platform)

1. `donut.dodo-mister/scripts/deploy_and_verify.sh` launches `'/media/fat/games/Donut Dodo/launch.sh'`. The path is now `DonutDodo`.
2. `maldita.castilla-mister/Dockerfile.solarus-build` has no snapshot pin (bullseye-security 404). It is also a Solarus leftover and should be deleted.
3. `maldita.castilla-mister/scripts/tests/test_wire_constants.py` reads `patches/mister/blitter/...`, which doesn't exist; `tests.yml:68` skips it. There is no C↔SV check on the GM core.
4. `cursed.castilla-mister` pins gmloader-next `c72967a` (6 commits behind master) and lacks the present-from-surface RTL.
5. `donutdodo_child.cpp` says "launch.sh does its own CPU placement", but donut `launch.sh` has none.
6. `solarus-mister/fpga/files.qip` lists `rtl/comp_dest_band.sv`, which doesn't exist.
7. `maldita.castilla-mister/vendor/Main_MiSTer.UPSTREAM.md` lists reverted files.
8. Committed binaries and large artefacts: solarus `libsolarus.so.1.profile` (10 MB), `*.vvp`, `bench/blit_bench`; donut vendor test binaries; maldita probe armhf binaries.
9. mister-astgrep is unadopted while per-repo rule copies drift.

## 5. Open decision

Where fabric host code lives: `mister-hybrid-platform/fabric/` (recommended; keeps mister-fpga-blitter a pure HW contract), or a `host-runtime/` directory inside mister-fpga-blitter (one fewer repo, but it mixes `/dev/mem` policy into the RTL repo). Nothing before step 4 depends on this choice.
