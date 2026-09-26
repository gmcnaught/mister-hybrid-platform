# shellcheck shell=sh
# shellcheck disable=SC2016  # the single-quoted arguments are awk programs
# ini_main.sh -- read and edit the main= line of one [CORENAME] section of MiSTer.ini.
#
# Every hybrid port points main= at the same /media/fat/linux/MiSTer_hybrid, so a
# file-wide grep for "main=<hook>" matches another port's section. These helpers
# only look inside [$MH_INI_SECTION]. POSIX sh + busybox awk; each edit writes a
# temp file and renames it, after one backup per call. Lines may end in CRLF (an
# older installer wrote [Maldita Castilla] that way on .81): comparisons ignore
# the CR, and edited lines keep the ending of the line they replace.
#
#   MH_INI_FILE=/media/fat/MiSTer.ini  MH_INI_SECTION=CashCowDX
#   mh_ini_main                 -> prints the active main= value in the section ("" if none)
#   mh_ini_set_main <path>      make main=<path> the section's active line: the first
#                               active main= (any value, e.g. a pre-platform wrapper)
#                               or commented ";main=<path>" becomes it, else it goes
#                               under the header, else the section is appended
#   mh_ini_disable_main <path> <tag>     comment out main=<path> in the section

mh_ini_main() {
    awk -v sec="[$MH_INI_SECTION]" '
        { sub(/\r$/, "") }
        /^\[/ { ins = ($0 == sec); next }
        ins && /^main=/ { v = substr($0, 6); sub(/[ \t;].*$/, "", v); print v; exit }
    ' "$MH_INI_FILE" 2>/dev/null
}

mh_ini_backup() { cp "$MH_INI_FILE" "$MH_INI_FILE.bak.$(date +%s)"; }

mh_ini_rewrite() { # awk-program [awk -v args...]
    _prog=$1; shift
    _tmp="$MH_INI_FILE.tmp.$$"
    if awk "$@" -v sec="[$MH_INI_SECTION]" "$_prog" "$MH_INI_FILE" > "$_tmp" && mv "$_tmp" "$MH_INI_FILE"; then
        return 0
    fi
    rm -f "$_tmp"
    return 1
}

mh_ini_set_main() { # path
    [ -f "$MH_INI_FILE" ] || : > "$MH_INI_FILE" || return 1
    mh_ini_backup || return 1
    # One pass: the first ";main=<path>" or active "main=" line in the section
    # becomes main=<path>; later active main= lines in it are commented out. A
    # section with neither gets the line under its header; no section -> appended.
    mh_ini_rewrite '
        { cr = sub(/\r$/, "") ? "\r" : "" }
        /^\[/ { ins = ($0 == sec); if (ins) found = 1 }
        ins && !done && (/^main=/ || $0 == ";" line || index($0, ";" line " ") == 1) { print line cr; done = 1; next }
        ins && /^main=/ { print ";" $0 "  ; replaced by " line cr; next }
        { print $0 cr }
        END { if (!found) printf "\n%s\n%s\n", sec, line }
    ' -v line="main=$1" || return 1
    # Section present but it had no main= line: add one under the header.
    if [ "$(mh_ini_main)" != "$1" ]; then
        mh_ini_rewrite '{ cr = sub(/\r$/, "") ? "\r" : ""; print $0 cr } !ins_done && $0 == sec { print line cr; ins_done = 1 }' -v line="main=$1" || return 1
    fi
    [ "$(mh_ini_main)" = "$1" ]
}

mh_ini_disable_main() { # path tag
    [ -f "$MH_INI_FILE" ] || return 0
    mh_ini_backup || return 1
    mh_ini_rewrite '
        { cr = sub(/\r$/, "") ? "\r" : "" }
        /^\[/ { ins = ($0 == sec) }
        ins && $0 == line { print ";" $0 "  ; disabled by " tag cr; next }
        { print $0 cr }
    ' -v line="main=$1" -v tag="$2"
}
