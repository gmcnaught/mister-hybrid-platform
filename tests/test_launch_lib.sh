#!/usr/bin/env bash
# shellcheck disable=SC2015  # "cond && ok || bad": ok always returns 0
# Host test for device/sh/launch_lib.sh (bash >= 4; MiSTer ships bash 5).
# Fakes /tmp/CORENAME, /proc, /dev/MiSTer_cmd and /media/fat under MH_ROOT and
# stubs devmem / taskset / pidof / setsid on PATH.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PLAT=$(cd "$HERE/.." && pwd)
T=$(mktemp -d)
BG=()
cleanup() { for p in "${BG[@]}"; do kill "$p" 2>/dev/null; done; [ -n "${KEEP:-}" ] && { echo "kept $T"; return; }; rm -rf "$T"; }
trap cleanup EXIT
pass=0 fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL $*"; }
has()  { if grep -q -- "$2" "$1" 2>/dev/null; then ok; else bad "$3: '$2' not in $1"; sed 's/^/    | /' "$1" 2>/dev/null | tail -20; fi; }
hasnt(){ if grep -q -- "$2" "$1" 2>/dev/null; then bad "$3: '$2' unexpectedly in $1"; else ok; fi; }

# --- stubs --------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/devmem" <<'EOF'
#!/bin/sh
# devmem ADDR 32: value from $MH_ROOT/devmem/ADDR; C_DONE auto-increments if $MH_ROOT/devmem/advance exists
f="$MH_ROOT/devmem/$1"
v=$(cat "$f" 2>/dev/null || echo 0x00000000)
echo "$v"
if [ -e "$MH_ROOT/devmem/advance" ] && [ "$1" = 0x3B000028 ]; then printf '0x%08X\n' $((v + 1)) > "$f"; fi
EOF
cat > "$T/bin/taskset" <<'EOF'
#!/bin/sh
echo "taskset $*" >> "$MH_ROOT/taskset.log"
case "$1" in -p|-a) exit 0 ;; esac
shift; exec "$@"
EOF
cat > "$T/bin/pidof" <<'EOF'
#!/bin/sh
for n in "$@"; do cat "$MH_ROOT/pidof/$n" 2>/dev/null; done
EOF
cat > "$T/bin/setsid" <<'EOF'
#!/bin/sh
exec "$@"
EOF
cat > "$T/bin/uname" <<'EOF'
#!/bin/sh
echo 6.18.38-MiSTer
EOF
cat > "$T/bin/insmod" <<'EOF'
#!/bin/sh
echo "insmod $*" >> "$MH_ROOT/insmod.log"
EOF
chmod +x "$T/bin/"*

# --- fixture ------------------------------------------------------------------
# fresh <corename>: new fake device with CashCowDX installed
fresh() {
    R="$T/r$((pass + fail))_$RANDOM"
    G="$R/media/fat/games/CashCowDX"
    mkdir -p "$R/tmp" "$R/devmem" "$R/pidof" "$R/dev" "$R/media/fat/_Other" "$R/proc/4242/task" \
             "$R/proc/irq/45" "$G/platform/mem_wc"
    echo "$1" > "$R/tmp/CORENAME"
    cp "$PLAT"/spec/generated/mister_map_gm_fabric.env "$PLAT"/spec/generated/mister_mem_wc.env \
       "$PLAT"/spec/generated/mister_cores.tsv "$PLAT"/device/sh/*.sh "$G/platform/"
    : > "$G/platform/mem_wc/mem_wc-6.18.38-MiSTer.ko"
    : > "$R/media/fat/_Other/CashCowDX_20260924.rbf"
    echo 0x00000000 > "$R/devmem/0xFF706014"          # FPGA ready
    printf 'MiSTer\0' > "$R/proc/4242/cmdline"; echo bash > "$R/proc/4242/comm"
    printf 'Name:\tbash\nCpus_allowed:\t00000003\n' > "$R/proc/4242/status"
    printf ' 45:  100  0  GIC-0  dwc2_hsotg:usb1\n' > "$R/proc/interrupts"
    echo 3 > "$R/proc/irq/45/smp_affinity"
    # engine stub: prints the ready line, runs until killed, logs its args
    cat > "$G/engine" <<'EOF'
#!/bin/sh
echo "engine args: $*"
echo "engine env joy=$TEST_JOY_BASE"
echo "fabric bring-up ok"
trap 'echo engine got TERM; exit 0' TERM
while :; do sleep 0.2; done
EOF
    chmod +x "$G/engine"
    cat > "$G/launch.sh" <<EOF
#!/usr/bin/env bash
MH_NAME=CashCowDX MH_CORENAME=CashCowDX MH_PROFILE=\${TEST_PROFILE:-gm-fabric}
MH_GAMEDIR=$G MH_ENGINE=engine
MH_READY_PATTERN="fabric bring-up" MH_GATE_WINDOW=\${TEST_GATE:-0} MH_READY_TIMEOUT=10
MH_SELECT_FILE=\${TEST_SELECT:+$R/media/fat/config/CashCowDX.s0} MH_SELECT_EXT=pck
mh_port_env() {
    MH_ENGINE_CMD=(./engine --main-pack "\${MH_SELECTED:-CashCowDX.pck}")
    export TEST_JOY_BASE="\$MISTER_GM_FABRIC_FB_BASE"
}
. "$G/platform/launch_lib.sh"
mh_main
EOF
    chmod +x "$G/launch.sh"
    LOG="$R/media/fat/logs/CashCowDX/cashcowdx.log"
}
launch() { # runs the launcher in the background; sets LPID
    env PATH="$T/bin:$PATH" MH_ROOT="$R" MH_DEVMEM=devmem "$@" bash "$G/launch.sh" &
    LPID=$!; BG+=("$LPID")
}
wait_for() { # file pattern seconds
    local i=0
    while [ $i -lt $(($3 * 10)) ]; do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; i=$((i+1)); done
    return 1
}
wait_count() { # file pattern count seconds
    local i=0
    while [ $i -lt $(($4 * 10)) ]; do [ "$(grep -c -- "$2" "$1" 2>/dev/null)" -ge "$3" ] && return 0; sleep 0.1; i=$((i+1)); done
    return 1
}
finish() { # wait for launcher exit, return its rc
    local i=0
    while kill -0 "$LPID" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.1; i=$((i+1)); done
    wait "$LPID" 2>/dev/null
}

# 1. not our core -> exit 0, nothing started
fresh MENU
launch; finish; rc=$?
[ $rc = 0 ] && ok || bad "wrong core rc=$rc"
has "$R/media/fat/logs/CashCowDX/launch.log" "not starting" "wrong core logged"
[ ! -e "$LOG" ] && ok || bad "wrong core: engine log created"

# 2. our core but the launcher was built for another profile -> refuse
fresh CashCowDX
launch TEST_PROFILE=solarus-fabric; finish; rc=$?
[ $rc = 1 ] && ok || bad "profile mismatch rc=$rc"
has "$R/media/fat/logs/CashCowDX/launch.log" "refusing (DDR map mismatch)" "profile mismatch logged"

# 3. happy path: start, isolate, gate passes, watchdog stops on core change, cleanup
fresh CashCowDX
: > "$R/devmem/advance"
launch
wait_for "$LOG" "fabric gate: done" 15 || bad "happy: gate never ran"
has "$LOG" "engine args: --main-pack CashCowDX.pck" "happy: engine started with args"
has "$LOG" "engine env joy=0x3BF40000" "happy: mh_port_env sees profile vars"
has "$R/taskset.log" "taskset 2 ./engine" "happy: engine started on CPU1 mask"
has "$R/taskset.log" "taskset -a -p 2 4242" "happy: other process moved to CPU1"
[ "$(cat "$R/proc/irq/45/smp_affinity")" = 2 ] && ok || bad "happy: USB IRQ not moved"
has "$R/insmod.log" "phys_base=0x3B000000 phys_size=0x01200000" "happy: mem_wc loaded with union window"
[ -e "$R/tmp/mister-hybrid/engine.claim" ] && ok || bad "happy: no claim file"
echo MENU > "$R/tmp/CORENAME"
finish; rc=$?
has "$LOG" "watchdog: core changed to 'MENU'" "happy: watchdog fired"
has "$LOG" "engine got TERM" "happy: engine terminated"
has "$R/taskset.log" "taskset -a -p 3 4242" "happy: process affinity restored"
[ "$(cat "$R/proc/irq/45/smp_affinity")" = 3 ] && ok || bad "happy: USB IRQ not restored"
[ ! -e "$R/tmp/mister-hybrid/engine.claim" ] && ok || bad "happy: claim not released"
[ ! -d "$R/tmp/mister-hybrid/CashCowDX.lock" ] && ok || bad "happy: lock not released"

# 4. fabric wedged -> reload core via MiSTer_cmd, retry mark 1, engine stopped
fresh CashCowDX
echo 0x00000005 > "$R/devmem/0x3B000028"; echo 0x00000009 > "$R/devmem/0x3B000000"
echo "main=/media/fat/linux/MiSTer_hybrid" > "$R/media/fat/MiSTer.ini"
mkfifo "$R/dev/MiSTer_cmd"
( exec 3<>"$R/dev/MiSTer_cmd"
  read -r l1 <&3; echo "$l1" >> "$R/cmd.log"; echo MENU > "$R/tmp/CORENAME"
  read -r l2 <&3; echo "$l2" >> "$R/cmd.log"; echo CashCowDX > "$R/tmp/CORENAME" ) &
BG+=("$!")
launch TEST_GATE=1
finish; rc=$?
[ $rc = 1 ] && ok || bad "wedged rc=$rc"
has "$LOG" "fabric gate: WEDGED -- reloading the core, attempt 1/4" "wedged: logged"
[ "$(cat "$R/tmp/mister-hybrid/CashCowDX.retry" 2>/dev/null)" = 1 ] && ok || bad "wedged: retry mark not 1"
wait_for "$R/cmd.log" "load_core $R/media/fat/_Other/CashCowDX_20260924.rbf" 5 || bad "wedged: core not reloaded"
has "$R/cmd.log" "load_core /media/fat/menu.rbf" "wedged: menu round-trip"
[ ! -e "$R/tmp/mister-hybrid/engine.claim" ] && ok || bad "wedged: claim not released"

# 5. a previous engine holding the claim is stopped before we start
fresh CashCowDX
: > "$R/devmem/advance"
sleep 60 & OLD=$!; BG+=("$OLD")
mkdir -p "$R/tmp/mister-hybrid"; echo "$OLD gmloader MalditaCastilla" > "$R/tmp/mister-hybrid/engine.claim"
launch
wait_for "$LOG" "fabric gate: done" 15 || bad "claim: engine never started"
kill -0 "$OLD" 2>/dev/null && bad "claim: previous engine still alive" || ok
echo MENU > "$R/tmp/CORENAME"; finish

# 6. a legacy engine found by name (no claim file) is stopped too
fresh CashCowDX
: > "$R/devmem/advance"
sleep 60 & OLD=$!; BG+=("$OLD")
echo "$OLD" > "$R/pidof/frt_3.5.2"
launch
wait_for "$LOG" "fabric gate: done" 15 || bad "legacy: engine never started"
kill -0 "$OLD" 2>/dev/null && bad "legacy: frt_3.5.2 still alive" || ok
echo MENU > "$R/tmp/CORENAME"; finish

# 7. second launcher while one runs -> stands down
fresh CashCowDX
: > "$R/devmem/advance"
launch; FIRST=$LPID
wait_for "$LOG" "fabric gate: done" 15 || bad "lock: first never started"
env PATH="$T/bin:$PATH" MH_ROOT="$R" MH_DEVMEM=devmem bash "$G/launch.sh" > "$R/second.out" 2>&1; rc=$?
[ $rc = 0 ] && ok || bad "lock: second rc=$rc"
has "$R/second.out" "standing down" "lock: second stood down"
kill -0 "$FIRST" 2>/dev/null && ok || bad "lock: first launcher died"
LPID=$FIRST; echo MENU > "$R/tmp/CORENAME"; finish

# 8. engine dies during start-up -> exit 1, cleanup ran
fresh CashCowDX
printf '#!/bin/sh\necho boom\nexit 3\n' > "$G/engine"
launch; finish; rc=$?
[ $rc = 1 ] && ok || bad "early exit rc=$rc"
has "$LOG" "engine exited during start-up" "early exit logged"
[ ! -d "$R/tmp/mister-hybrid/CashCowDX.lock" ] && ok || bad "early exit: lock not released"

# 9. OSD file select: stale pick ignored, pick starts, same pick is a no-op, a new
#    pick restarts, engine exit -> idle, next pick starts again, core change exits
fresh CashCowDX
: > "$R/devmem/advance"
mkdir -p "$R/media/fat/config" "$R/media/fat/games/CashCowDX/q"
: > "$R/media/fat/games/CashCowDX/q/a.pck"; : > "$R/media/fat/games/CashCowDX/q/b.pck"
S0="$R/media/fat/config/CashCowDX.s0"
printf 'games/CashCowDX/q/a.pck' > "$S0"                 # left over from an earlier session
sleep 0.05
launch TEST_SELECT=1
wait_for "$LOG" "select: waiting for a pick" 10 || bad "select: never waited"
sleep 1.2
hasnt "$LOG" "engine args" "select: stale pick started the engine"
printf 'games/CashCowDX/q/a.pck\0\0junk' > "$S0"          # Main_MiSTer may leave trailing bytes
wait_for "$LOG" "fabric gate: done" 15 || bad "select: pick did not start the engine"
has "$LOG" "engine args: --main-pack $R/media/fat/games/CashCowDX/q/a.pck" "select: engine got the resolved pick"
printf 'games/CashCowDX/q/a.pck' > "$S0"
wait_for "$LOG" "picked again -- already running" 5 || bad "select: same pick not recognised"
printf 'games/CashCowDX/q/missing.pck' > "$S0"
wait_for "$LOG" "does not name a file -- keeping" 5 || bad "select: bad pick not ignored"
printf 'games/CashCowDX/q/b.pck' > "$S0"
wait_for "$LOG" "engine args: --main-pack $R/media/fat/games/CashCowDX/q/b.pck" 15 || bad "select: new pick did not restart"
has "$LOG" "engine got TERM" "select: old engine stopped on switch"
wait_count "$LOG" "fabric gate: done" 2 10 && ok || bad "select: gate did not run per start (count-based ready)"
kill "$(awk '{print $1}' "$R/tmp/mister-hybrid/engine.claim")"
wait_count "$LOG" "cpu: restored" 2 5 || bad "select: cpu not restored after engine exit"
wait_count "$LOG" "select: waiting for a pick" 2 5 || bad "select: not back to waiting"
printf 'games/CashCowDX/q/a.pck' > "$S0"
wait_count "$LOG" "select: starting" 3 5 && ok || bad "select: re-pick after exit ignored"
[ "$(grep 'select: starting' "$LOG" | tail -1)" = "[CashCowDX] select: starting $R/media/fat/games/CashCowDX/q/a.pck" ] && ok || bad "select: third start not a.pck"
wait_count "$LOG" "fabric gate: done" 3 15
echo MENU > "$R/tmp/CORENAME"
finish; rc=$?
[ $rc = 0 ] && ok || bad "select: rc=$rc after core change"
[ ! -e "$R/tmp/mister-hybrid/engine.claim" ] && ok || bad "select: claim not released"
[ ! -d "$R/tmp/mister-hybrid/CashCowDX.lock" ] && ok || bad "select: lock not released"
[ "$(cat "$R/proc/irq/45/smp_affinity")" = 3 ] && ok || bad "select: USB IRQ not restored"

# 10. select: another core while idle -> exit 0 without starting anything
fresh CashCowDX
launch TEST_SELECT=1
wait_for "$LOG" "select: waiting for a pick" 10 || bad "select idle: never waited"
echo MENU > "$R/tmp/CORENAME"
finish; rc=$?
[ $rc = 0 ] && ok || bad "select idle: rc=$rc"
has "$LOG" "select: core changed to 'MENU' -- exiting" "select idle: exit logged"
hasnt "$LOG" "engine args" "select idle: engine started"

echo "launch_lib: $pass passed, $fail failed"
[ "$fail" = 0 ]
