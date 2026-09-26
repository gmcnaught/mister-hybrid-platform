#!/bin/sh
# Host test for device/sh/ini_main.sh (POSIX sh; run under dash like busybox ash).
# shellcheck disable=SC2034,SC1091,SC2016  # MH_INI_* are read by the sourced helper; awk text is literal
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../device/sh/ini_main.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 fail=0
eq() { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $3: got '$1' want '$2'"; cat "$MH_INI_FILE" | sed 's/^/    | /'; fi; }
H=/media/fat/linux/MiSTer_hybrid
MH_INI_FILE="$T/MiSTer.ini"

# Another port already on the shared hook must not read as "ours".
printf '[MiSTer]\nvideo_mode=8\n\n[DonutDodo]\nmain=%s\n' "$H" > "$MH_INI_FILE"
MH_INI_SECTION=CashCowDX
eq "$(mh_ini_main)" "" "other section's main= is not ours"
mh_ini_set_main "$H"; eq $? 0 "append rc"
eq "$(mh_ini_main)" "$H" "appended section"
eq "$(grep -c '^\[CashCowDX\]$' "$MH_INI_FILE")" 1 "one header"
mh_ini_disable_main "$H" CashCowDX_CoresMenu
eq "$(mh_ini_main)" "" "disabled"
MH_INI_SECTION=DonutDodo
eq "$(mh_ini_main)" "$H" "disable left the other section alone"
MH_INI_SECTION=CashCowDX
mh_ini_set_main "$H"
eq "$(mh_ini_main)" "$H" "re-enabled"
eq "$(grep -c "main=$H" "$MH_INI_FILE")" 2 "re-enable reused the commented line"

# Legacy per-game wrapper -> hook, in place; a duplicate active line is commented.
printf '[CashCowDX]\nmain=/media/fat/games/CashCowDX/MiSTer_CashCowDX\nvga_scaler=1\nmain=/x/y\n[Other]\nmain=/z\n' > "$MH_INI_FILE"
mh_ini_set_main "$H"
eq "$(mh_ini_main)" "$H" "legacy replaced"
eq "$(sed -n 2p "$MH_INI_FILE")" "main=$H" "replaced in place"
eq "$(sed -n 3p "$MH_INI_FILE")" "vga_scaler=1" "other keys kept"
eq "$(grep -c '^main=/x/y' "$MH_INI_FILE")" 0 "second active main= commented"
MH_INI_SECTION=Other; eq "$(mh_ini_main)" "/z" "other section untouched"

# Section without main=: inserted under the header.
MH_INI_SECTION=CashCowDX
printf '[CashCowDX]\nvga_scaler=0\n' > "$MH_INI_FILE"
mh_ini_set_main "$H"
eq "$(sed -n 2p "$MH_INI_FILE")" "main=$H" "inserted under header"

# No file yet.
rm -f "$MH_INI_FILE"
mh_ini_set_main "$H"; eq "$(mh_ini_main)" "$H" "created file"
ls "$T"/MiSTer.ini.bak.* >/dev/null 2>&1; eq $? 0 "backups written"

echo "ini_main: $pass passed, $fail failed"
[ "$fail" = 0 ]
