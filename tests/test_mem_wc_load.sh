#!/bin/sh
# Host test for device/sh/mem_wc_load.sh. Runs under dash (closest to busybox ash).
# Stubs insmod/rmmod/uname on PATH and fakes /dev, /sys, /proc under MH_ROOT.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$HERE/../device/sh/mem_wc_load.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0 fail=0

mkstubs() {
    mkdir -p "$T/bin"
    cat > "$T/bin/uname" <<'EOF'
#!/bin/sh
echo 6.18.38-MiSTer
EOF
    # insmod <ko> phys_base=X phys_size=Y: materialise the device + sysfs (decimal, as the kernel prints ulong)
    cat > "$T/bin/insmod" <<'EOF'
#!/bin/sh
echo "insmod $*" >> "$MH_ROOT/log"
[ -n "${STUB_INSMOD_FAIL:-}" ] && exit 1
for a in "$@"; do case $a in phys_base=*) b=${a#*=};; phys_size=*) s=${a#*=};; esac; done
mkdir -p "$MH_ROOT/dev" "$MH_ROOT/sys/module/mem_wc/parameters"
: > "$MH_ROOT/dev/mem_wc"
echo $((b)) > "$MH_ROOT/sys/module/mem_wc/parameters/phys_base"
echo $((s)) > "$MH_ROOT/sys/module/mem_wc/parameters/phys_size"
EOF
    cat > "$T/bin/rmmod" <<'EOF'
#!/bin/sh
echo "rmmod $*" >> "$MH_ROOT/log"
[ -n "${STUB_RMMOD_FAIL:-}" ] && exit 1
rm -rf "$MH_ROOT/dev/mem_wc" "$MH_ROOT/sys/module/mem_wc"
EOF
    chmod +x "$T/bin/"*
}

# fresh <ko-files...>: new fake root with the given files in ko/
fresh() {
    R="$T/root.$$.$pass.$fail"
    rm -rf "$R"; mkdir -p "$R/ko" "$R/proc/1"
    : > "$R/log"; : > "$R/proc/1/maps"
    for k in "$@"; do : > "$R/ko/$k"; done
}
preload() { # base size (decimal as sysfs shows)
    mkdir -p "$R/dev" "$R/sys/module/mem_wc/parameters"
    : > "$R/dev/mem_wc"
    echo "$1" > "$R/sys/module/mem_wc/parameters/phys_base"
    echo "$2" > "$R/sys/module/mem_wc/parameters/phys_size"
}
run() { # expected-rc name -- env/args...
    want=$1 name=$2; shift 2
    out=$(env PATH="$T/bin:$PATH" MH_ROOT="$R" "$@" dash -c ". '$LIB'; mh_mem_wc_load \"\$MH_ROOT/ko\" 0x3B000000 0x01000000" 2>&1)
    rc=$?
    if [ "$rc" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $name: rc=$rc want=$want: $out"; fi
}
expect_log() { # name pattern
    if grep -q "$2" "$R/log"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: log lacks '$2':"; cat "$R/log"; fi
}
expect_nolog() {
    if grep -q "$2" "$R/log"; then fail=$((fail+1)); echo "FAIL $1: log has '$2'"; else pass=$((pass+1)); fi
}

mkstubs
U="MISTER_MEM_WC_BASE=0x3B000000"; US="MISTER_MEM_WC_SIZE=0x01200000"

fresh mem_wc-6.18.38-MiSTer.ko
run 0 "clean load uses union window" $U $US
expect_log "union window" "phys_base=0x3B000000 phys_size=0x01200000"
expect_log "vermagic-named module chosen" "mem_wc-6.18.38-MiSTer.ko"

fresh mem_wc.ko
run 0 "flat mem_wc.ko fallback" $U $US
expect_log "flat module" "ko/mem_wc.ko"

fresh mem_wc-5.15.1-MiSTer.ko
run 1 "no module for this kernel"
expect_nolog "no insmod without module" "insmod"

fresh mem_wc-6.18.38-MiSTer.ko
preload $((0x3B000000)) $((0x01200000))
run 0 "already loaded and covering"
expect_nolog "no reload when covered" "rmmod"

fresh mem_wc-6.18.38-MiSTer.ko
preload 0 0
run 0 "unrestricted instance covers"

fresh mem_wc-6.18.38-MiSTer.ko
preload $((0x3A000000)) $((0x00400000))
run 0 "foreign too-small instance, unmapped -> replaced" $U $US
expect_log "rmmod plain" "rmmod mem_wc"
expect_nolog "never force" "rmmod -f"

fresh mem_wc-6.18.38-MiSTer.ko
preload $((0x3A000000)) $((0x00400000))
echo "b6f00000-b7000000 rw-s 3a000000 00:06 123 /dev/mem_wc" > "$R/proc/1/maps"
run 1 "foreign instance still mapped -> left alone"
expect_nolog "no rmmod under a live mapping" "rmmod"

fresh mem_wc-6.18.38-MiSTer.ko
preload $((0x3A000000)) $((0x00400000))
run 1 "rmmod refused -> left alone" STUB_RMMOD_FAIL=1
expect_nolog "no insmod after refused rmmod" "insmod"

fresh mem_wc-6.18.38-MiSTer.ko
run 1 "insmod failure is non-fatal" STUB_INSMOD_FAIL=1

fresh mem_wc-6.18.38-MiSTer.ko
run 0 "union not containing need falls back to own window" MISTER_MEM_WC_BASE=0x3A000000 MISTER_MEM_WC_SIZE=0x00100000
expect_log "own window" "phys_base=0x3B000000 phys_size=0x01000000"

echo "mem_wc_load: $pass passed, $fail failed"
[ "$fail" = 0 ]
