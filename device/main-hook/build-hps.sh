#!/usr/bin/env bash
# Build MiSTer_hybrid: upstream Main_MiSTer at UPSTREAM_COMMIT + overlay/ + one
# inserted call in scheduler.cpp. One binary for every hybrid port; the port is
# chosen at runtime from /media/fat/linux/hybrid.d/<CORENAME>.conf.
#
# The only upstream edit is inserted at build time after the first
# `scheduler_wait_fpga_ready();` in scheduler_co_poll(); the build fails if the
# anchor is missing. Moving upstream is: UPSTREAM_COMMIT=<sha> build-hps.sh.
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

mkdir -p "$OUT"
if [ ! -d "$SRC/.git" ]; then
    git clone -q --filter=blob:none --no-checkout "$UPSTREAM_URL" "$SRC"
fi
git -C "$SRC" fetch -q origin "$UPSTREAM_COMMIT" 2>/dev/null || true
git -C "$SRC" checkout -q -f "$UPSTREAM_COMMIT"
git -C "$SRC" clean -qfdx

# --- the one upstream edit -----------------------------------------------------
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
cp "$HERE"/overlay/* "$SRC/"
sed 's/^PRJ = MiSTer$/PRJ = '"$PRJ"'/' "$SRC/Makefile" > "$SRC/Makefile.hybrid"
grep -q "^PRJ = $PRJ\$" "$SRC/Makefile.hybrid" || { echo "build-hps.sh: no 'PRJ = MiSTer' line in upstream Makefile" >&2; exit 1; }

# --- build (Debian armhf cross toolchain, host-native: no QEMU) -----------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build -q -t "$IMAGE" -f "$ROOT/build/docker/Dockerfile.base" "$ROOT"
fi
docker run --rm -u "$(id -u):$(id -g)" -v "$SRC:/src" -w /src "$IMAGE" \
    make -f Makefile.hybrid BASE=arm-linux-gnueabihf -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

cp "$SRC/bin/$PRJ" "$OUT/$PRJ"
# A stock Main_MiSTer renamed MiSTer_hybrid runs fine and never starts a game;
# gate on the hook's strings being linked in.
for s in "hybrid_hook: " "/media/fat/linux/hybrid.d"; do
    grep -q "$s" "$OUT/$PRJ" || { echo "hook string '$s' missing from $PRJ" >&2; exit 1; }
done
echo "built $OUT/$PRJ (Main_MiSTer@${UPSTREAM_COMMIT:0:7})"
