# shellcheck shell=sh
# mem_wc_load.sh -- load the write-combining /dev/mem_wc driver for a hybrid core.
#
# SOURCE this file (busybox ash / POSIX sh), then call:
#
#   mh_mem_wc_load <ko_dir> <need_base> <need_size>
#
# <ko_dir> holds mem_wc-<uname -r>.ko files (release layout) and/or a flat
# mem_wc.ko (deploy.py layout). <need_base>/<need_size> is the window THIS
# engine will map write-combining (the profile's [mem_wc] base/size).
#
# Returns 0 when /dev/mem_wc is present and its allowlist covers the need,
# 1 otherwise. Never fatal: every engine falls back to the strongly-ordered
# /dev/mem mapping on its own, so a failure here costs frame rate, not boot.
# One line explaining the outcome goes to stderr (redirect it to the port log).
#
# POLICY (merged from maldita mem_wc_load.sh and solarus solarus_run.sh):
#  * Insert with the SUITE-WIDE union window (MISTER_MEM_WC_BASE/SIZE from
#    spec/generated/mister_mem_wc.env), not this engine's own window, so no
#    other port ever finds an allowlist too small for it and has to reload.
#  * Reload a foreign instance only when its allowlist misses our window AND
#    nothing maps /dev/mem_wc. The module refcount only protects an OPEN fd; a
#    process that mapped it and closed the fd holds a live VMA with no
#    reference, and unloading under that hung a device (2026-08-06). Hence the
#    /proc/*/maps check, and never `rmmod -f`.
#
# Test seam: MH_ROOT prefixes /dev, /sys and /proc (host tests use a fake tree).

MH_ROOT=${MH_ROOT:-}

_mh_log() { echo "mem_wc: $*" >&2; }

# Does the loaded module's allowlist cover [base, base+size)?
# phys_size == 0 means unrestricted.
mh_mem_wc_covers() {
    _p="$MH_ROOT/sys/module/mem_wc/parameters"
    [ -r "$_p/phys_size" ] || return 1
    _sz=$(cat "$_p/phys_size" 2>/dev/null) || return 1
    _bs=$(cat "$_p/phys_base" 2>/dev/null) || return 1
    [ "$_sz" -eq 0 ] 2>/dev/null && return 0
    [ "$_bs" -le $(($1)) ] 2>/dev/null || return 1
    [ $((_bs + _sz)) -ge $(($1 + $2)) ] 2>/dev/null || return 1
    return 0
}

# Is any process mapping /dev/mem_wc right now?
mh_mem_wc_mapped() {
    grep -qs /dev/mem_wc "$MH_ROOT"/proc/[0-9]*/maps
}

mh_mem_wc_load() {
    _dir=$1 _nb=$2 _ns=$3
    _ub=${MISTER_MEM_WC_BASE:-$_nb}
    _us=${MISTER_MEM_WC_SIZE:-$_ns}
    # The union must contain our own need; otherwise the spec is inconsistent
    # with this engine and we insert our own window instead.
    if [ $((_ub)) -gt $((_nb)) ] || [ $((_ub + _us)) -lt $((_nb + _ns)) ]; then
        _ub=$_nb _us=$_ns
    fi

    _ko="$_dir/mem_wc-$(uname -r).ko"
    [ -f "$_ko" ] || _ko="$_dir/mem_wc.ko"

    if [ -e "$MH_ROOT/dev/mem_wc" ]; then
        if mh_mem_wc_covers "$_nb" "$_ns"; then
            _mh_log "already loaded, allowlist covers $_nb+$_ns"
            return 0
        fi
        if mh_mem_wc_mapped; then
            _mh_log "loaded with an allowlist missing $_nb+$_ns and mapped by another process; leaving it (strongly-ordered this run)"
            return 1
        fi
        if ! rmmod mem_wc 2>/dev/null; then
            _mh_log "loaded with an allowlist missing $_nb+$_ns and in use; leaving it (strongly-ordered this run)"
            return 1
        fi
        _mh_log "replaced an instance whose allowlist missed $_nb+$_ns"
    fi

    if [ ! -f "$_ko" ]; then
        _mh_log "no module for kernel $(uname -r) in $_dir -- DDR stays strongly-ordered"
        return 1
    fi
    insmod "$_ko" phys_base="$_ub" phys_size="$_us" 2>/dev/null
    if [ -e "$MH_ROOT/dev/mem_wc" ] && mh_mem_wc_covers "$_nb" "$_ns"; then
        _mh_log "loaded $(basename "$_ko") for [$_ub, +$_us)"
        return 0
    fi
    _mh_log "insmod $_ko failed (see dmesg) -- DDR stays strongly-ordered"
    return 1
}
