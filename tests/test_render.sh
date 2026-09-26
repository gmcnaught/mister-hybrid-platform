#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # "cond && ok || bad" (ok returns 0); stub bodies are literal
# Render examples/cash.cow.dx/mister-port.toml into a fake /media/fat, lint the
# output, exercise the CoresMenu toggle, and run the rendered launcher.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PLAT=$(cd "$HERE/.." && pwd)
T=$(mktemp -d)
LPID=""
trap '[ -n "$LPID" ] && kill "$LPID" 2>/dev/null; rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has() { if grep -q -- "$2" "$1" 2>/dev/null; then ok; else bad "$3: '$2' not in $1"; tail -15 "$1" 2>/dev/null | sed 's/^/    | /'; fi; }

R="$T/root"; F="$R/media/fat"
# A stand-in hook binary carrying the marker string the CoresMenu toggle checks.
printf 'ELF...hybrid_hook: .../media/fat/linux/hybrid.d...' > "$T/MiSTer_hybrid"
python3 "$PLAT/tools/mister_platform.py" render "$PLAT/examples/cash.cow.dx/mister-port.toml" \
    --out "$F" --hook-binary "$T/MiSTer_hybrid" > /dev/null && ok || bad "render failed"

for f in games/CashCowDX/launch.sh Scripts/CashCowDX.sh Scripts/CashCowDX_CoresMenu.sh linux/MiSTer_hybrid; do
    [ -x "$F/$f" ] && ok || bad "$f not executable"
done
if command -v shellcheck >/dev/null; then
    shellcheck -s bash "$F/games/CashCowDX/launch.sh" "$F"/Scripts/*.sh && ok || bad "shellcheck on rendered scripts"
fi
has "$F/linux/hybrid.d/CashCowDX.conf" "^launcher=/media/fat/games/CashCowDX/launch.sh$" "registry launcher"
has "$F/linux/hybrid.d/CashCowDX.conf" "^profile=gm-fabric$" "registry profile"
has "$F/_Other/CashCowDX.mgl" "<rbf>_Other/CashCowDX</rbf>" "mgl rbf prefix"
has "$F/Scripts/CashCowDX.sh" "missing \$GAMEDIR/CashCowDX.pck -- copy it from your GOG install" "required file check"

# --- CoresMenu toggle: on, off, on again (re-enables the commented line) --------
INI="$T/MiSTer.ini"; printf '[MiSTer]\nvideo_mode=8\n' > "$INI"
cm() { env MH_HOOK="$F/linux/MiSTer_hybrid" MH_INI="$INI" MH_REGISTRY="$F/linux/hybrid.d" bash "$F/Scripts/CashCowDX_CoresMenu.sh" >/dev/null 2>&1; }
cm && ok || bad "toggle on rc"
has "$INI" "^\[CashCowDX\]$" "toggle on: section"
has "$INI" "^main=$F/linux/MiSTer_hybrid$" "toggle on: main line"
cm && ok || bad "toggle off rc"
has "$INI" "^;main=$F/linux/MiSTer_hybrid  ; disabled by CashCowDX_CoresMenu" "toggle off: commented"
cm && ok || bad "toggle on again rc"
[ "$(grep -c '^\[CashCowDX\]$' "$INI")" = 1 ] && ok || bad "toggle: duplicated section"
has "$INI" "^main=$F/linux/MiSTer_hybrid$" "toggle on again: main line"
ls "$INI".bak.* >/dev/null 2>&1 && ok || bad "toggle: no backup"
printf 'stock MiSTer' > "$T/stock"
env MH_HOOK="$T/stock" MH_INI="$T/other.ini" MH_REGISTRY="$F/linux/hybrid.d" bash "$F/Scripts/CashCowDX_CoresMenu.sh" >/dev/null 2>&1 \
    && bad "toggle accepted a stock MiSTer binary" || ok

# --- the rendered launcher, against stubs -------------------------------------
mkdir -p "$T/bin" "$R/tmp" "$R/proc"
printf '#!/bin/sh\necho 0x00000000\n' > "$T/bin/devmem"
printf '#!/bin/sh\ncase "$1" in -p|-a) exit 0;; esac\nshift; exec "$@"\n' > "$T/bin/taskset"
printf '#!/bin/sh\n' > "$T/bin/pidof"
printf '#!/bin/sh\necho 6.18.38-MiSTer\n' > "$T/bin/uname"
printf '#!/bin/sh\n' > "$T/bin/insmod"
chmod +x "$T/bin/"*
cat > "$F/games/CashCowDX/cashcowdx" <<'EOS'
#!/bin/sh
echo "cashcowdx $*"
echo "joy_base=$MISTER_JOY_BASE fabric_lib=$MISTER_FABRIC_LIB"
echo "fabric bring-up"
trap 'exit 0' TERM
while :; do sleep 0.2; done
EOS
chmod +x "$F/games/CashCowDX/cashcowdx"
run() { env PATH="$T/bin:$PATH" MH_ROOT="$R" MH_DEVMEM=devmem MH_CPU_ISOLATE=0 "$@" bash "$F/games/CashCowDX/launch.sh"; }

echo MENU > "$R/tmp/CORENAME"
run && ok || bad "rendered launcher on another core should exit 0"
has "$F/logs/CashCowDX/launch.log" "not starting" "rendered launcher: wrong core"

echo CashCowDX > "$R/tmp/CORENAME"
run MH_FABRIC_GATE=0 & LPID=$!
LOG="$F/logs/CashCowDX/cashcowdx.log"
for _ in $(seq 1 100); do grep -q "fabric bring-up" "$LOG" 2>/dev/null && break; sleep 0.1; done
has "$LOG" "cashcowdx --display-driver mister --rendering-driver opengl3_es --audio-driver MiSTer --max-fps 0 --main-pack CashCowDX.pck" "rendered: engine argv"
has "$LOG" "joy_base=0x3BF40000 fabric_lib=$F/games/CashCowDX/libmisterfabric.so" "rendered: engine env"
echo MENU > "$R/tmp/CORENAME"
for _ in $(seq 1 100); do kill -0 "$LPID" 2>/dev/null || break; sleep 0.1; done
wait "$LPID" 2>/dev/null; LPID=""
has "$LOG" "watchdog: core changed" "rendered: watchdog"

echo "render: $pass passed, $fail failed"
[ "$fail" = 0 ]
