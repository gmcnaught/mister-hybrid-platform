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
printf 'ELF...hybrid_hook: ...MiSTer_hybrid registry: <binary dir>/hybrid.d...' > "$T/MiSTer_hybrid"
python3 "$PLAT/tools/mister_platform.py" render "$PLAT/examples/cash.cow.dx/mister-port.toml" \
    --out "$F" --hook-binary "$T/MiSTer_hybrid" > /dev/null && ok || bad "render failed"

for f in games/CashCowDX/launch.sh Scripts/CashCowDX.sh Scripts/CashCowDX_CoresMenu.sh games/CashCowDX/platform/MiSTer_hybrid; do
    [ -x "$F/$f" ] && ok || bad "$f not executable"
done
if command -v shellcheck >/dev/null; then
    shellcheck -s bash "$F/games/CashCowDX/launch.sh" "$F"/Scripts/*.sh && ok || bad "shellcheck on rendered scripts"
fi
# Nothing under linux/: the Downloader refuses that root folder for every database.
[ ! -e "$F/linux" ] && ok || bad "render wrote under linux/"
has "$F/games/CashCowDX/platform/hybrid.d/CashCowDX.conf" "^launcher=/media/fat/games/CashCowDX/launch.sh$" "registry launcher"
has "$F/games/CashCowDX/platform/hybrid.d/CashCowDX.conf" "^profile=gm-fabric$" "registry profile"
has "$F/_Other/CashCowDX.mgl" "<rbf>_Other/CashCowDX</rbf>" "mgl rbf prefix"
has "$F/Scripts/CashCowDX.sh" "missing \$GAMEDIR/CashCowDX.pck -- copy it from your GOG install" "required file check"

# --- CoresMenu toggle: on, off, on again (re-enables the commented line) --------
INI="$T/MiSTer.ini"
# Another port on the platform v0.3.x shared hook: its section must not read as ours.
printf '[MiSTer]\nvideo_mode=8\n[DonutDodo]\nmain=/media/fat/linux/MiSTer_hybrid\n' > "$INI"
H="$F/games/CashCowDX/platform/MiSTer_hybrid"
cm() { env MH_HOOK="$H" MH_INI="$INI" MH_REGISTRY="$F/games/CashCowDX/platform/hybrid.d" \
    MH_PLATFORM_DIR="$F/games/CashCowDX/platform" bash "$F/Scripts/CashCowDX_CoresMenu.sh" >/dev/null 2>&1; }
cm && ok || bad "toggle on rc"
has "$INI" "^\[CashCowDX\]$" "toggle on: section"
has "$INI" "^main=$H$" "toggle on: main line"
cm && ok || bad "toggle off rc"
has "$INI" "^;main=$H  ; disabled by CashCowDX_CoresMenu" "toggle off: commented"
cm && ok || bad "toggle on again rc"
[ "$(grep -c '^\[CashCowDX\]$' "$INI")" = 1 ] && ok || bad "toggle: duplicated section"
has "$INI" "^main=$H$" "toggle on again: main line"
ls "$INI".bak.* >/dev/null 2>&1 && ok || bad "toggle: no backup"
has "$INI" "^main=/media/fat/linux/MiSTer_hybrid$" "toggle touched the DonutDodo section"
# Pre-platform wrapper in the section: toggle-on replaces it in place.
printf '[CashCowDX]\nmain=/media/fat/games/CashCowDX/MiSTer_CashCowDX\n' > "$INI"
cm && ok || bad "toggle over legacy rc"
has "$INI" "^main=$H$" "toggle over legacy: main line"
has "$INI" "^\[CashCowDX\]$" "toggle over legacy: section kept"
grep -q "^main=/media/fat/games/CashCowDX/MiSTer_CashCowDX" "$INI" && bad "legacy main= still active" || ok
# Platform v0.3.x shared hook in the section: replaced in place too.
printf '[CashCowDX]\nmain=/media/fat/linux/MiSTer_hybrid\n' > "$INI"
cm && ok || bad "toggle over v0.3 hook rc"
has "$INI" "^main=$H$" "toggle over v0.3 hook: main line"
grep -q "^main=/media/fat/linux/MiSTer_hybrid" "$INI" && bad "v0.3 hook main= still active" || ok
has "$F/Scripts/CashCowDX.sh" 'case "$old_main" in /media/fat/games/CashCowDX/MiSTer_CashCowDX|/media/fat/linux/MiSTer_hybrid)' "Scripts: legacy migration"
has "$F/Scripts/CashCowDX.sh" '^HOOK="/media/fat/games/CashCowDX/platform/MiSTer_hybrid"$' "Scripts: per-port hook path"
has "$F/Scripts/CashCowDX.sh" 'rm -f "/media/fat/linux/hybrid.d/$CORENAME.conf"' "Scripts: removes the v0.3 registry entry"
printf 'stock MiSTer' > "$T/stock"
env MH_HOOK="$T/stock" MH_INI="$T/other.ini" MH_REGISTRY="$F/games/CashCowDX/platform/hybrid.d" MH_PLATFORM_DIR="$F/games/CashCowDX/platform" bash "$F/Scripts/CashCowDX_CoresMenu.sh" >/dev/null 2>&1 \
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
# The stub engine exits 0 on TERM; before the saved-pid fix this read "exited (1)" (wait "").
has "$LOG" "engine: exited (0)" "rendered: engine exit status"

# --- maldita: core name with a space, gamedir, mgl, engine_log, test_env, OSD Reset
has "$F/games/CashCowDX/platform/hybrid.d/CashCowDX.conf" "^noengine=/media/fat/games/CashCowDX/NOENGINE$" "registry noengine"
grep -q "osd_reset" "$F/games/CashCowDX/platform/hybrid.d/CashCowDX.conf" && bad "cash cow registry has osd_reset (not opted in)" || ok
M="$T/maldita"; MF="$M/media/fat"; MG="$MF/games/gmloader"
python3 "$PLAT/tools/mister_platform.py" render "$PLAT/examples/maldita.castilla/mister-port.toml" \
    --out "$MF" --hook-binary "$T/MiSTer_hybrid" > /dev/null && ok || bad "maldita render failed"
MREG="$MG/platform/hybrid.d/Maldita Castilla.conf"
[ -x "$MG/platform/MiSTer_hybrid" ] && ok || bad "maldita: hook not in games/gmloader/platform"
[ ! -e "$MF/linux" ] && ok || bad "maldita render wrote under linux/"
has "$MREG" "^launcher=/media/fat/games/gmloader/launch.sh$" "maldita registry launcher"
has "$MREG" "^noengine=/media/fat/games/gmloader/NOENGINE$" "maldita registry noengine"
has "$MREG" "^osd_reset=19$" "maldita registry osd_reset"
has "$MREG" "^reset_clear=/tmp/mister-hybrid/MalditaCastilla.lock/pid$" "maldita registry reset_clear"
[ -f "$MF/_Other/Maldita Castilla.mgl" ] && ok || bad "maldita mgl name"
has "$MF/Scripts/MalditaCastilla.sh" "grep -q '\[g\]mloader/launch.sh'" "maldita Scripts: launcher_running pattern"
if command -v shellcheck >/dev/null; then
    shellcheck -s bash "$MG/launch.sh" "$MF"/Scripts/*.sh && ok || bad "shellcheck on rendered maldita scripts"
fi
# CoresMenu on a section whose name has a space
printf '[MiSTer]\nvideo_mode=8\n[Maldita Castilla]\nmain=/media/fat/games/gmloader/MiSTer_Maldita\n' > "$INI"
env MH_HOOK="$MG/platform/MiSTer_hybrid" MH_INI="$INI" MH_REGISTRY="$MG/platform/hybrid.d" \
    MH_PLATFORM_DIR="$MG/platform" bash "$MF/Scripts/MalditaCastilla_CoresMenu.sh" >/dev/null 2>&1 && ok || bad "maldita toggle rc"
has "$INI" "^main=$MG/platform/MiSTer_hybrid$" "maldita toggle: main line"
[ "$(grep -c '^\[Maldita Castilla\]$' "$INI")" = 1 ] && ok || bad "maldita toggle: duplicated section"

# The rendered launcher: cwd = gamedir, engine log name, test env after the port env,
# fail pattern -> wedged.
mkdir -p "$M/tmp" "$M/proc" "$MF/games/gmloader" "$MF/_Other"
printf '#!/bin/sh\n[ "$1" = -n ] && shift 2\nexec "$@"\n' > "$T/bin/nice"; chmod +x "$T/bin/nice"
cat > "$MF/games/gmloader/gmloader" <<'EOS'
#!/bin/sh
echo "gmloader $* cwd=$(pwd) blitter=$GMLOADER_BLITTER ld=$LD_LIBRARY_PATH"
echo "fabric bring-up ${STUB_BRINGUP:-ok}"
trap 'exit 0' TERM
while :; do sleep 0.2; done
EOS
chmod +x "$MF/games/gmloader/gmloader"
echo 'export GMLOADER_BLITTER=0' > "$MF/games/gmloader/bench.env"
: > "$MF/_Other/MalditaCastilla_20260925.rbf"
echo "Maldita Castilla" > "$M/tmp/CORENAME"
mrun() { env PATH="$T/bin:$PATH" MH_ROOT="$M" MH_DEVMEM=devmem MH_CPU_ISOLATE=0 MH_GATE_WINDOW=0 "$@" bash "$MG/launch.sh"; }
MLOG="$MF/logs/MalditaCastilla/maldita.log"
mrun & LPID=$!
for _ in $(seq 1 100); do grep -q "fabric gate" "$MLOG" 2>/dev/null && break; sleep 0.1; done
has "$MLOG" "gmloader -c gmloader.json cwd=$MF/games/gmloader blitter=0 ld=$MF/games/gmloader/mesa:$MF/games/gmloader" "maldita: cwd, env, test env overrides"
has "$MLOG" "fabric gate: done" "maldita: gate sampled"
echo MENU > "$M/tmp/CORENAME"
for _ in $(seq 1 100); do kill -0 "$LPID" 2>/dev/null || break; sleep 0.1; done
wait "$LPID" 2>/dev/null; LPID=""
echo "Maldita Castilla" > "$M/tmp/CORENAME"
rm -f "$MLOG"; mrun STUB_BRINGUP=SOFT-FAILED MH_MAX_RETRIES=0 & LPID=$!
for _ in $(seq 1 100); do grep -q "fabric gate:" "$MLOG" 2>/dev/null && break; sleep 0.1; done
has "$MLOG" "fabric gate: engine reports 'fabric bring-up SOFT-FAILED'" "maldita: fail pattern"
echo MENU > "$M/tmp/CORENAME"
for _ in $(seq 1 100); do kill -0 "$LPID" 2>/dev/null || break; sleep 0.1; done
wait "$LPID" 2>/dev/null; LPID=""

# --- a CONF_STR name with a space and a game dir that differs from the name -----
S="$T/spaced"; SF="$S/media/fat"; mkdir -p "$S"
cat > "$S/mister-port.toml" <<'EOS'
[port]
name     = "CursedCastilla"
corename = "Cursed Castilla"
gamedir  = "cursedcastilla"
profile  = "gm-fabric"
[launch]
process       = "gmloader"
command       = ["./gmloader", "-c", "gmloader.json"]
ready_pattern = "fabric bring-up"
fail_pattern  = "fabric bring-up SOFT-FAILED"
EOS
python3 "$PLAT/tools/mister_platform.py" render "$S/mister-port.toml" --out "$SF" >/dev/null && ok || bad "spaced: render failed"
has "$SF/games/cursedcastilla/platform/hybrid.d/Cursed Castilla.conf" "^launcher=/media/fat/games/cursedcastilla/launch.sh$" "spaced: registry"
has "$SF/games/cursedcastilla/platform/hybrid.d/Cursed Castilla.conf" "^noengine=/media/fat/games/cursedcastilla/NOENGINE$" "spaced: noengine"
has "$SF/games/cursedcastilla/launch.sh" '^MH_CORENAME="Cursed Castilla"$' "spaced: quoted corename"
has "$SF/games/cursedcastilla/launch.sh" '^MH_FAIL_PATTERN="fabric bring-up SOFT-FAILED"$' "spaced: fail pattern"
has "$SF/Scripts/CursedCastilla.sh" '^MH_INI_SECTION="Cursed Castilla"$' "spaced: ini section"
has "$SF/Scripts/CursedCastilla.sh" "\[c\]ursedcastilla/launch.sh" "spaced: launcher_running grep"
[ -f "$SF/games/cursedcastilla/platform/launch_lib.sh" ] && ok || bad "spaced: platform/ under gamedir"
[ -f "$SF/_Other/CursedCastilla.mgl" ] && ok || bad "spaced: mgl named after name"
if command -v shellcheck >/dev/null; then
    shellcheck -s bash "$SF/games/cursedcastilla/launch.sh" "$SF"/Scripts/*.sh && ok || bad "spaced: shellcheck"
fi
INI="$T/spaced.ini"; printf '[Cursed Castilla]\nmain=/media/fat/games/cursedcastilla/MiSTer_CursedCastilla\n' > "$INI"
env MH_HOOK="$H" MH_INI="$INI" MH_REGISTRY="$SF/games/cursedcastilla/platform/hybrid.d" \
    MH_PLATFORM_DIR="$SF/games/cursedcastilla/platform" bash "$SF/Scripts/CursedCastilla_CoresMenu.sh" >/dev/null 2>&1 \
    && ok || bad "spaced: toggle rc"
has "$INI" "^main=$H$" "spaced: toggle replaced the legacy main="
[ "$(grep -c '^\[Cursed Castilla\]$' "$INI")" = 1 ] && ok || bad "spaced: duplicated section"

echo "render: $pass passed, $fail failed"
[ "$fail" = 0 ]
