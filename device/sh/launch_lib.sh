# shellcheck shell=bash
# launch_lib.sh -- the shared engine launcher for MiSTer hybrid ports.
#
# A port's launch.sh (rendered from mister-port.toml) sets the MH_* variables
# below, defines the engine command, sources this file and calls mh_main:
#
#   MH_NAME=CashCowDX  MH_CORENAME=CashCowDX  MH_PROFILE=gm-fabric
#   MH_GAMEDIR=/media/fat/games/CashCowDX  MH_ENGINE=cashcowdx
#   MH_ENGINE_CMD=(./cashcowdx --main-pack CashCowDX.pck)
#   . "$MH_GAMEDIR/platform/launch_lib.sh"; mh_main
#
# Sequence (merged from cash.cow.dx / donut.dodo / maldita launch.sh and
# solarus solarus_run.sh):
#   core check -> profile check -> lock -> stop other fabric engines ->
#   FPGA-ready wait -> mem_wc -> start engine -> (ready line) -> CPU isolate ->
#   fabric gate (reload core + retry if the blitter wedged) -> watchdog.
#
# Required:  MH_NAME MH_CORENAME MH_PROFILE MH_GAMEDIR MH_ENGINE MH_ENGINE_CMD
# Hook:      mh_port_env()  if defined, called after the profile map is loaded
#                           and before the engine starts: export the engine env here
# Optional (default):
#   MH_LOGDIR (/media/fat/logs/$MH_NAME)   MH_PLATFORM_DIR ($MH_GAMEDIR/platform)
#   MH_RBF_GLOB (/media/fat/_Other/${MH_NAME}_*.rbf)
#   MH_MEM_WC (1)  MH_CPU_ISOLATE (1)  MH_FABRIC_GATE (1 if the profile has a fabric)
#   MH_READY_PATTERN ("")  line in the engine log meaning "fabric is up"; empty =
#                          wait MH_READY_TIMEOUT seconds unless the engine exits
#   MH_READY_TIMEOUT (60)  MH_GATE_WINDOW (8)  MH_MAX_RETRIES (4)
#   MH_ENGINE_CPU (2)      taskset mask the engine starts on (it pins its own main thread)
#   MH_TEST_ENV (/tmp/<name>_test.env)  sourced if present -- measurement hook
#   MH_MAIN_HOOK (/media/fat/linux/MiSTer_hybrid)
#   MH_LEGACY_ENGINES      process names of fabric engines that predate the
#                          shared claim file (default below)
#
# Test seam: MH_ROOT prefixes /tmp/CORENAME, /proc, /dev, /media/fat paths;
# MH_DEVMEM overrides the devmem command.

MH_ROOT=${MH_ROOT:-}
MH_LEGACY_ENGINES=${MH_LEGACY_ENGINES:-"gmloader frt_3.5.2 cashcowdx solarus-run"}
MH_STATE_DIR="$MH_ROOT/tmp/mister-hybrid"
MH_CLAIM="$MH_STATE_DIR/engine.claim"

mh_log() { echo "[$MH_NAME] $*"; }
mh_nap() { sleep "$1" & wait $!; }        # interruptible: SIGTERM runs the trap now
mh_devmem() { ${MH_DEVMEM:-busybox devmem} "$1" 32 2>/dev/null; }
mh_corename() { local c=""; read -r c < "$MH_ROOT/tmp/CORENAME" 2>/dev/null; echo "$c"; }

mh_defaults() {
    : "${MH_NAME:?}" "${MH_CORENAME:?}" "${MH_PROFILE:?}" "${MH_GAMEDIR:?}" "${MH_ENGINE:?}"
    MH_LOGDIR=${MH_LOGDIR:-$MH_ROOT/media/fat/logs/$MH_NAME}
    MH_PLATFORM_DIR=${MH_PLATFORM_DIR:-$MH_GAMEDIR/platform}
    MH_RBF_GLOB=${MH_RBF_GLOB:-$MH_ROOT/media/fat/_Other/${MH_NAME}_*.rbf}
    MH_MEM_WC=${MH_MEM_WC:-1}
    MH_CPU_ISOLATE=${MH_CPU_ISOLATE:-1}
    MH_READY_PATTERN=${MH_READY_PATTERN:-}
    MH_READY_TIMEOUT=${MH_READY_TIMEOUT:-60}
    MH_GATE_WINDOW=${MH_GATE_WINDOW:-8}
    MH_MAX_RETRIES=${MH_MAX_RETRIES:-4}
    MH_ENGINE_CPU=${MH_ENGINE_CPU:-2}
    MH_TEST_ENV=${MH_TEST_ENV:-$MH_ROOT/tmp/$(echo "$MH_NAME" | tr '[:upper:]' '[:lower:]')_test.env}
    MH_MAIN_HOOK=${MH_MAIN_HOOK:-/media/fat/linux/MiSTer_hybrid}
    MH_LOG="$MH_LOGDIR/$(echo "$MH_NAME" | tr '[:upper:]' '[:lower:]').log"
    MH_LOCKDIR="$MH_STATE_DIR/$MH_NAME.lock"
    MH_RETRY_MARK="$MH_STATE_DIR/$MH_NAME.retry"
}

# Profile constants from spec/generated (shipped into $MH_PLATFORM_DIR).
mh_load_profile() {
    local p env
    p=$(echo "$MH_PROFILE" | tr '[:lower:]-' '[:upper:]_')
    env="$MH_PLATFORM_DIR/mister_map_$(echo "$MH_PROFILE" | tr '-' '_').env"
    if [ ! -r "$env" ]; then
        mh_log "profile map $env missing -- packaging error"
        return 1
    fi
    # shellcheck disable=SC1090
    . "$env"
    # shellcheck disable=SC1091
    [ -r "$MH_PLATFORM_DIR/mister_mem_wc.env" ] && . "$MH_PLATFORM_DIR/mister_mem_wc.env"
    eval "MH_C_SUBMIT=\${MISTER_${p}_C_SUBMIT:-}; MH_C_DONE=\${MISTER_${p}_C_DONE:-}"
    eval "MH_WC_BASE=\${MISTER_${p}_MEM_WC_BASE:-}; MH_WC_SIZE=\${MISTER_${p}_MEM_WC_SIZE:-}"
    [ -n "$MH_C_DONE" ] || MH_FABRIC_GATE=0
    MH_FABRIC_GATE=${MH_FABRIC_GATE:-1}
    return 0
}

# The loaded core must be ours, and must be the profile we were built for.
# A core in the wrong profile has a different DDR map: every address would be
# silently wrong (donut PLAN §1i), so refuse rather than start.
mh_check_core() {
    local cur want
    cur=$(mh_corename)
    if [ "$cur" != "$MH_CORENAME" ]; then
        mh_log "core is '$cur', not $MH_CORENAME -- not starting"
        return 1
    fi
    if [ -r "$MH_PLATFORM_DIR/mister_cores.tsv" ]; then
        want=$(awk -F'\t' -v c="$cur" '$1 == c { print $2 }' "$MH_PLATFORM_DIR/mister_cores.tsv")
        if [ "$want" != "$MH_PROFILE" ]; then
            mh_log "core $cur is profile '${want:-unknown}', engine built for '$MH_PROFILE' -- refusing (DDR map mismatch)"
            return 2
        fi
    else
        mh_log "warning: no mister_cores.tsv -- core/profile match not checked"
    fi
    return 0
}

mh_lock() {
    mkdir -p "$MH_STATE_DIR"
    if ! mkdir "$MH_LOCKDIR" 2>/dev/null; then
        local owner
        owner=$(cat "$MH_LOCKDIR/pid" 2>/dev/null)
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
            mh_log "another launcher (pid $owner) is running -- standing down"
            return 1
        fi
    fi
    echo $$ > "$MH_LOCKDIR/pid"
}

mh_kill_pid() { # pid label
    mh_log "stopping a running fabric engine ($2 pid $1)"
    kill "$1" 2>/dev/null
    mh_nap 2
    kill -9 "$1" 2>/dev/null
}

# One fabric engine at a time: two engines on one control block corrupt it.
# The claim file names the engine that owns the fabric; the legacy name list
# covers ports that do not write it yet.
mh_stop_other_engines() {
    local pid name core
    if [ -r "$MH_CLAIM" ]; then
        read -r pid name core < "$MH_CLAIM"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            mh_kill_pid "$pid" "$name/$core"
        fi
        rm -f "$MH_CLAIM"
    fi
    for name in $MH_ENGINE $MH_LEGACY_ENGINES; do
        for pid in $(pidof "$name" 2>/dev/null); do
            mh_kill_pid "$pid" "$name"
        done
    done
}

mh_claim() { echo "$1 $MH_ENGINE $MH_CORENAME" > "$MH_CLAIM"; }
mh_unclaim() {
    local pid _
    read -r pid _ < "$MH_CLAIM" 2>/dev/null
    [ "$pid" = "$1" ] && rm -f "$MH_CLAIM"
}

# Bit 31 of the HPS GPI (0xFF706014) is low once the core is configured.
mh_wait_fpga_ready() {
    local waited=0 v
    while v=$(mh_devmem 0xFF706014) && [ -n "$v" ] && [ $((v & 0x80000000)) -ne 0 ]; do
        if [ "$waited" -ge 20 ]; then mh_log "FPGA still not ready after 20s -- starting anyway"; break; fi
        mh_nap 1; waited=$((waited + 1))
    done
    # Settle only after a wait; when main= starts us the core is already configured.
    if [ "$waited" -gt 0 ]; then mh_nap 1; fi
}

mh_mem_wc() {
    if [ "$MH_MEM_WC" != 1 ] || [ -z "$MH_WC_BASE" ]; then return 0; fi
    # shellcheck disable=SC1091
    . "$MH_PLATFORM_DIR/mem_wc_load.sh"
    mh_mem_wc_load "$MH_PLATFORM_DIR/mem_wc" "$MH_WC_BASE" "$MH_WC_SIZE" 2>&1 || true
}

# --- CPU placement (from cash.cow.dx launch.sh) ----------------------------------
# CPU0 for the engine's main thread; the USB IRQ, the engine's other threads,
# this launcher and every other user process except MiSTer on CPU1. Restored on exit.
MH_MOVED=""
mh_cpu_isolate() {
    [ "$MH_CPU_ISOLATE" = 1 ] || return 0
    MH_USB_IRQ=$(awk -F: '/dwc2_hsotg/{gsub(/ /,"",$1); print $1; exit}' "$MH_ROOT/proc/interrupts" 2>/dev/null)
    MH_USB_IRQ_MASK=""
    if [ -n "$MH_USB_IRQ" ]; then
        MH_USB_IRQ_MASK=$(cat "$MH_ROOT/proc/irq/$MH_USB_IRQ/smp_affinity" 2>/dev/null)
        echo 2 > "$MH_ROOT/proc/irq/$MH_USB_IRQ/smp_affinity" 2>/dev/null
    fi
    taskset -p 2 $$ >/dev/null 2>&1
    # Builtins only per /proc entry: forking readlink/cat per process ran ~110
    # forks while the engine boots (cash.cow PLAN §6.27).
    local d pid cmd comm key old t tid
    for d in "$MH_ROOT"/proc/[0-9]*; do
        pid=${d##*/}
        [ "$pid" = "$$" ] && continue
        cmd=""; read -r -d '' cmd 2>/dev/null < "$d/cmdline"
        [ -n "$cmd" ] || continue                                  # kernel thread / exited
        comm=""; read -r comm 2>/dev/null < "$d/comm"
        case "$comm" in MiSTer|"$MH_ENGINE") continue ;; esac
        old=""
        while read -r key old; do [ "$key" = "Cpus_allowed:" ] && break; old=""; done 2>/dev/null < "$d/status"
        old=${old##*,}; old=${old#"${old%%[!0]*}"}                   # "00000003" -> "3"
        if [ -z "$old" ] || [ "$old" = "2" ]; then continue; fi
        taskset -a -p 2 "$pid" >/dev/null 2>&1 && MH_MOVED="$MH_MOVED $pid:$old"
    done
    if [ -n "${MH_ENGINE_PID:-}" ]; then
        for t in "$MH_ROOT/proc/$MH_ENGINE_PID/task/"*; do
            tid=${t##*/}
            [ "$tid" = "$MH_ENGINE_PID" ] || taskset -p 2 "$tid" >/dev/null 2>&1
        done
    fi
    mh_log "cpu: USB IRQ ${MH_USB_IRQ:-none} -> CPU1; moved $(echo "$MH_MOVED" | wc -w) processes and the engine's worker threads to CPU1"
}
mh_cpu_restore() {
    [ "$MH_CPU_ISOLATE" = 1 ] || return 0
    if [ -n "${MH_USB_IRQ:-}" ] && [ -n "${MH_USB_IRQ_MASK:-}" ]; then
        echo "$MH_USB_IRQ_MASK" > "$MH_ROOT/proc/irq/$MH_USB_IRQ/smp_affinity" 2>/dev/null
    fi
    local e
    for e in $MH_MOVED; do
        taskset -a -p "${e#*:}" "${e%%:*}" >/dev/null 2>&1
    done
    MH_MOVED=""
    mh_log "cpu: restored"
}

# --- engine ----------------------------------------------------------------------
mh_start_engine() {
    # Output goes through a pipe to a logger (moved to CPU1 with the rest):
    # /media/fat is mounted sync, and a print straight to the log would block
    # the engine's main thread on an SD write (cash.cow PLAN §6.25).
    # shellcheck disable=SC2153  # MH_ENGINE_CMD is set by the port's launch.sh
    taskset "$MH_ENGINE_CPU" "${MH_ENGINE_CMD[@]}" > >(exec cat) 2>&1 &
    MH_ENGINE_PID=$!
    mh_claim "$MH_ENGINE_PID"
    mh_log "engine: started pid $MH_ENGINE_PID: ${MH_ENGINE_CMD[*]}"
}

mh_stop_engine() {
    [ -n "${MH_ENGINE_PID:-}" ] || return 0
    kill "$MH_ENGINE_PID" 2>/dev/null; mh_nap 2; kill -9 "$MH_ENGINE_PID" 2>/dev/null
    mh_unclaim "$MH_ENGINE_PID"
    MH_ENGINE_PID=""
}

# Wait for the ready line (or the timeout); fail if the engine dies first.
mh_wait_ready() {
    local waited=0
    while [ $waited -lt "$MH_READY_TIMEOUT" ]; do
        kill -0 "$MH_ENGINE_PID" 2>/dev/null || { mh_log "engine exited during start-up"; return 1; }
        if [ -n "$MH_READY_PATTERN" ] && grep -q "$MH_READY_PATTERN" "$MH_LOG" 2>/dev/null; then return 0; fi
        [ -z "$MH_READY_PATTERN" ] && [ $waited -ge 2 ] && return 0
        mh_nap 1; waited=$((waited + 1))
    done
    [ -z "$MH_READY_PATTERN" ] || mh_log "ready line '$MH_READY_PATTERN' not seen after ${MH_READY_TIMEOUT}s -- continuing"
    return 0
}

# Blitter still retiring work? (C_DONE advances, or nothing is outstanding)
mh_fabric_ok() {
    local d0 d1 s1
    d0=$(mh_devmem "$MH_C_DONE"); mh_nap "$MH_GATE_WINDOW"
    d1=$(mh_devmem "$MH_C_DONE"); s1=$(mh_devmem "$MH_C_SUBMIT")
    mh_log "fabric gate: done $d0 -> $d1 (submit $s1)"
    [ "$d1" != "$d0" ] || [ "$d1" = "$s1" ]
}

# Reload the core via the menu core from a detached helper. If main= points at
# the shared hook, the reloaded core starts a new launcher; otherwise the helper does.
mh_reload_core() {
    local rbf waited=0
    # shellcheck disable=SC2012,SC2086  # the glob must expand; newest first
    rbf=$(ls -t $MH_RBF_GLOB 2>/dev/null | head -1)
    if [ -z "$rbf" ] || [ ! -p "$MH_ROOT/dev/MiSTer_cmd" ]; then mh_log "reload: no RBF or no MiSTer_cmd"; return 1; fi
    # shellcheck disable=SC2016  # expands in the child sh, from its positional args
    setsid sh -c '
        r=$5
        echo "load_core /media/fat/menu.rbf" > "$r/dev/MiSTer_cmd"
        w=0; while [ "$(cat "$r/tmp/CORENAME" 2>/dev/null)" != MENU ] && [ $w -lt 20 ]; do sleep 1; w=$((w+1)); done
        echo "load_core $1" > "$r/dev/MiSTer_cmd"
        w=0; while [ "$(cat "$r/tmp/CORENAME" 2>/dev/null)" != "$2" ] && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
        sleep 2
        grep -q "^main=$4" "$r/media/fat/MiSTer.ini" 2>/dev/null || exec "$3"
    ' reload "$rbf" "$MH_CORENAME" "$0" "$MH_MAIN_HOOK" "$MH_ROOT" < /dev/null >> "$MH_LOG" 2>&1 &
    # Hold until the core is gone, so this launcher exits before the next one starts.
    while [ "$(mh_corename)" = "$MH_CORENAME" ] && [ $waited -lt 20 ]; do mh_nap 1; waited=$((waited+1)); done
}

mh_cleanup() {
    # Background the slow parts: a SIGKILL of this script must not skip them.
    if [ -n "${MH_ENGINE_PID:-}" ]; then
        kill "$MH_ENGINE_PID" 2>/dev/null
        ( sleep 2; kill -9 "$MH_ENGINE_PID" 2>/dev/null ) &
        mh_unclaim "$MH_ENGINE_PID"
    fi
    mh_cpu_restore &
    rm -rf "$MH_LOCKDIR"
    wait
}

# Stop the engine when another core is loaded from the OSD.
mh_watchdog() {
    local cur
    while kill -0 "$MH_ENGINE_PID" 2>/dev/null; do
        cur=$(mh_corename)
        if [ "$cur" != "$MH_CORENAME" ]; then
            mh_log "watchdog: core changed to '$cur' -- stopping the engine"
            mh_stop_engine
            break
        fi
        mh_nap 1
    done
}

mh_main() {
    set -u
    mh_defaults
    mkdir -p "$MH_LOGDIR"
    # shellcheck disable=SC1090
    [ -f "$MH_TEST_ENV" ] && . "$MH_TEST_ENV"
    cd "$MH_GAMEDIR" || exit 1
    local out rc
    out=$(mh_check_core); rc=$?
    if [ $rc -ne 0 ]; then
        echo "$(date) $out" >> "$MH_LOGDIR/launch.log"
        [ $rc = 1 ] && exit 0      # not our core: nothing to do
        exit 1                     # our core, wrong profile: refuse
    fi
    mh_load_profile >> "$MH_LOGDIR/launch.log" || exit 1
    mh_lock || exit 0
    mh_stop_other_engines

    mv -f "$MH_LOG" "${MH_LOG%.log}.prev.log" 2>/dev/null
    exec >> "$MH_LOG" 2>&1
    mh_log "=== $(date) launcher pid $$ core=$(mh_corename) profile=$MH_PROFILE kernel=$(uname -r)"

    mh_wait_fpga_ready
    mh_mem_wc

    trap mh_cleanup EXIT
    trap 'exit 130' INT TERM HUP

    local attempt
    attempt=$(cat "$MH_RETRY_MARK" 2>/dev/null); case "$attempt" in ''|*[!0-9]*) attempt=0 ;; esac
    # The port's engine environment (rendered launch.sh), after the profile map.
    if declare -F mh_port_env >/dev/null; then mh_port_env; fi
    mh_start_engine
    mh_wait_ready || exit 1
    mh_cpu_isolate
    if [ "$MH_FABRIC_GATE" = 1 ] && ! mh_fabric_ok; then
        if [ "$attempt" -lt "$MH_MAX_RETRIES" ]; then
            echo $((attempt + 1)) > "$MH_RETRY_MARK"
            mh_log "fabric gate: WEDGED -- reloading the core, attempt $((attempt + 1))/$MH_MAX_RETRIES"
            mh_stop_engine
            mh_cpu_restore
            rm -rf "$MH_LOCKDIR"
            mh_reload_core
            exit 1
        fi
        mh_log "fabric gate: still wedged after $attempt attempts -- leaving the engine running"
    fi
    rm -f "$MH_RETRY_MARK"

    mh_watchdog
    wait "$MH_ENGINE_PID" 2>/dev/null
    mh_log "engine: exited ($?)"
}
