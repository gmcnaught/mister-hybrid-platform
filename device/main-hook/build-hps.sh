#!/usr/bin/env bash
# Build MiSTer_hybrid: upstream Main_MiSTer at UPSTREAM_COMMIT + overlay/ + one
# inserted call in scheduler.cpp. One binary for every hybrid port; the port is
# chosen at runtime from /media/fat/linux/hybrid.d/<CORENAME>.conf.
#
# Upstream edits, inserted at build time at anchors; the build fails if an anchor
# is missing or matches more than once:
#   scheduler.cpp  hybrid_hook_poll() after the first `scheduler_wait_fpga_ready();`
#                  in scheduler_co_poll()
#   user_io.cpp    a sticky latch of CONF_STR T/R pulses in user_io_status_set(),
#                  drained by user_io_status_trigger_take() (OSD Reset, osd_reset=)
#   user_io.h      that function's declaration
# Moving upstream is: UPSTREAM_COMMIT=<sha> build-hps.sh.
# (Generalised from cash.cow.dx-mister / maldita tools/mister-wrapper/build-hps.sh.)
#
#   device/main-hook/build-hps.sh        -> build/main-hook/MiSTer_hybrid
#   BUILD_IMAGE=<img>                    cross image (default mister-armhf-base:bullseye,
#                                        built from build/docker/Dockerfile.base if absent)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/MiSTer-devel/Main_MiSTer.git}"
# Device-validated pin shared by maldita/cursed/donut/cash.cow wrappers.
UPSTREAM_COMMIT="${UPSTREAM_COMMIT:-3380931329b8acb442bd3d35a24d89f88641b7cf}"
OUT="${OUTPUT_DIR:-$ROOT/build/main-hook}"
SRC="$OUT/src"
IMAGE="${BUILD_IMAGE:-mister-armhf-base:bullseye}"
PRJ=MiSTer_hybrid
# Upstream's release toolchain (arm-none-linux-gnueabihf) defaults to Cortex-A9 +
# NEON; Debian's armhf gcc defaults to vfpv3-d16. Upstream code from ~2026-09
# (scaler.cpp) no longer compiles without __ARM_NEON. Same flags as
# build/make/mister-flags.mk (neon, NOT neon-vfpv4: SIGILL on the A9).
ARCH_FLAGS="-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard"

mkdir -p "$OUT"
if [ ! -d "$SRC/.git" ]; then
    git clone -q --filter=blob:none --no-checkout "$UPSTREAM_URL" "$SRC"
fi
git -C "$SRC" fetch -q origin "$UPSTREAM_COMMIT" 2>/dev/null || true
git -C "$SRC" checkout -q -f "$UPSTREAM_COMMIT"
git -C "$SRC" clean -qfdx

# --- upstream edits ------------------------------------------------------------
awk '
    /^static void scheduler_co_poll\(void\)/ { inpoll = 1 }
    { print }
    inpoll && !done && /^[ \t]*scheduler_wait_fpga_ready\(\);[ \t]*$/ {
        print "\t\thybrid_hook_poll(); // mister-hybrid-platform main= hook"
        done = 1; inserts++
    }
    END { if (inserts != 1) exit 3 }
' "$SRC/scheduler.cpp" > "$SRC/scheduler.cpp.new" || {
    echo "build-hps.sh: anchor 'scheduler_wait_fpga_ready();' in scheduler_co_poll() not found in" >&2
    echo "  Main_MiSTer@$UPSTREAM_COMMIT scheduler.cpp - re-check the hook position before building." >&2
    exit 1
}
{ echo '#include "hybrid_hook.h"'; cat "$SRC/scheduler.cpp.new"; } > "$SRC/scheduler.cpp"
rm "$SRC/scheduler.cpp.new"

# OSD Reset trigger latch. A CONF_STR "T" option is a pulse: menu.cpp calls
# user_io_status_set(opt, 1) then (opt, 0) inside one HandleUI() call, so nothing
# outside it sees the bit set. Latch single-bit sets of the 32-bit (ex == 0)
# status word; hybrid_hook.cpp drains the latch for cores with osd_reset=.
# (From maldita.castilla-mister's vendored user_io.cpp.)
awk '
    /^void user_io_status_set\(const char \*opt, uint32_t value, int ex\)$/ {
        print "// mister-hybrid-platform: OSD Reset trigger latch (see hybrid_hook.cpp)."
        print "static volatile uint32_t g_status_trigger_flags = 0;"
        print "uint32_t user_io_status_trigger_take()"
        print "{"
        print "\tuint32_t flags = g_status_trigger_flags;"
        print "\tg_status_trigger_flags = 0;"
        print "\treturn flags;"
        print "}"
        print ""
        inset = 1; heads++
    }
    { print }
    inset && /^[ \t]*if \(!size\) return;[ \t]*$/ {
        print "\tif (!ex && size == 1 && value == 1) g_status_trigger_flags |= (1u << start); // mister-hybrid-platform"
        inset = 0; latches++
    }
    END { if (heads != 1 || latches != 1) exit 3 }
' "$SRC/user_io.cpp" > "$SRC/user_io.cpp.new" || {
    echo "build-hps.sh: anchors 'void user_io_status_set(const char *opt, uint32_t value, int ex)' /" >&2
    echo "  'if (!size) return;' not found exactly once in Main_MiSTer@$UPSTREAM_COMMIT user_io.cpp." >&2
    exit 1
}
mv "$SRC/user_io.cpp.new" "$SRC/user_io.cpp"
awk '
    { print }
    /^void user_io_status_set\(const char \*opt, uint32_t value, int ex = 0\);$/ {
        print "uint32_t user_io_status_trigger_take(); // mister-hybrid-platform: consume latched T/R pulses"
        n++
    }
    END { if (n != 1) exit 3 }
' "$SRC/user_io.h" > "$SRC/user_io.h.new" || {
    echo "build-hps.sh: anchor 'void user_io_status_set(..., int ex = 0);' not found exactly once in user_io.h" >&2
    exit 1
}
mv "$SRC/user_io.h.new" "$SRC/user_io.h"
cp "$HERE"/overlay/* "$SRC/"
sed 's/^PRJ = MiSTer$/PRJ = '"$PRJ"'/' "$SRC/Makefile" > "$SRC/Makefile.hybrid"
grep -q "^PRJ = $PRJ\$" "$SRC/Makefile.hybrid" || { echo "build-hps.sh: no 'PRJ = MiSTer' line in upstream Makefile" >&2; exit 1; }

# --- build (Debian armhf cross toolchain, host-native: no QEMU) -----------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build -q -t "$IMAGE" -f "$ROOT/build/docker/Dockerfile.base" "$ROOT"
fi
docker run --rm -u "$(id -u):$(id -g)" -v "$SRC:/src" -w /src "$IMAGE" \
    make -f Makefile.hybrid BASE=arm-linux-gnueabihf \
    CC="arm-linux-gnueabihf-gcc $ARCH_FLAGS" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

cp "$SRC/bin/$PRJ" "$OUT/$PRJ"
# A stock Main_MiSTer renamed MiSTer_hybrid runs fine and never starts a game;
# gate on the hook's strings being linked in.
for s in "hybrid_hook: " "/media/fat/linux/hybrid.d" "OSD Reset armed on status bit"; do
    grep -q "$s" "$OUT/$PRJ" || { echo "hook string '$s' missing from $PRJ" >&2; exit 1; }
done
echo "built $OUT/$PRJ (Main_MiSTer@${UPSTREAM_COMMIT:0:7})"
