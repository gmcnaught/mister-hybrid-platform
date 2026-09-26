#!/bin/bash
# collect_runtime_libs.sh -- ship the armhf shared-library closure of an engine.
#
#   collect_runtime_libs.sh --out deploy/libs [--search DIR]... SEED...
#
# Walks DT_NEEDED transitively from the SEED binaries/libraries, copies every
# library the MiSTer does not already provide into --out (keeping the soname as
# the filename), and fails if any shipped library needs GLIBC > 2.31 (MiSTer's
# glibc). Run inside mister-armhf-base or an engine image built FROM it.
#
# --search dirs are tried FIRST, in order, before the multiarch dirs. Put a
# from-source lean library (e.g. an SDL2 built without X11/Wayland) there so it
# wins over the stock :armhf package that exports the same soname -- otherwise
# the stock one's heavyweight DT_NEEDED subtree gets shipped.
#
# Generalised from solarus-mister scripts/collect_runtime_libs.sh (task 006).
set -euo pipefail

OUT=""
SEARCH_DIRS=()
SEEDS=()
MAX_GLIBC=${MAX_GLIBC:-2.31}
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=$2; shift 2 ;;
    --search) SEARCH_DIRS+=("$(cd "$2" && pwd)"); shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) SEEDS+=("$1"); shift ;;
  esac
done
if [ -z "$OUT" ] || [ ${#SEEDS[@]} -eq 0 ]; then
  echo "usage: $0 --out DIR [--search DIR]... SEED..." >&2; exit 2
fi
# /lib/arm-linux-gnueabihf matters: some sonames (libdbus-1.so.3) live only there.
SEARCH_DIRS+=(/usr/lib/arm-linux-gnueabihf /lib/arm-linux-gnueabihf)
mkdir -p "$OUT"

# Provided by the MiSTer rootfs -- never ship (glibc core + libstdc++/libgcc_s/z/expat).
SKIP_RE='^(ld-linux|libc|libm|libdl|libpthread|librt|libresolv|libutil|libstdc\+\+|libgcc_s|libz|libexpat)\.'

locate_soname() {
  local name="$1" d cand
  for d in "${SEARCH_DIRS[@]}"; do
    if [ -e "$d/$name" ]; then echo "$d/$name"; return 0; fi
    # shellcheck disable=SC2012  # sonames are simple; ls-glob piped to head is fine
    cand=$(ls "$d/$name"* 2>/dev/null | head -1 || true)
    if [ -n "$cand" ]; then echo "$cand"; return 0; fi
  done
  return 1
}

needed() {
  arm-linux-gnueabihf-readelf -d "$1" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/{print $2}'
}

declare -A seen
queue=()
for f in "${SEEDS[@]}"; do
  [ -f "$f" ] || { echo "ERROR: seed $f not found" >&2; exit 1; }
  while read -r n; do queue+=("$n"); done < <(needed "$f")
done

missing=0
while [ ${#queue[@]} -gt 0 ]; do
  name="${queue[0]}"; queue=("${queue[@]:1}")
  [ -n "${seen[$name]:-}" ] && continue
  seen[$name]=1
  path="$(locate_soname "$name" || true)"
  if echo "$name" | grep -Eq "$SKIP_RE"; then
    echo "skip (on device): $name"
  elif [ -n "$path" ]; then
    cp -L "$path" "$OUT/$name"
  else
    echo "ERROR: cannot locate $name in ${SEARCH_DIRS[*]}" >&2
    missing=1
  fi
  if [ -n "$path" ]; then
    while read -r n; do queue+=("$n"); done < <(needed "$path")
  fi
done

echo ""
echo "=== shipped ($OUT) -- max GLIBC symbol version, must be <= $MAX_GLIBC ==="
too_new=0
for so in "$OUT"/*; do
  [ -e "$so" ] || continue
  v=$(arm-linux-gnueabihf-objdump -T "$so" 2>/dev/null \
      | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -V | tail -1)
  printf '  %-32s %s\n' "$(basename "$so")" "${v:-none}"
  if [ -n "$v" ] && [ "$(printf '%s\n%s\n' "${v#GLIBC_}" "$MAX_GLIBC" | sort -V | tail -1)" != "$MAX_GLIBC" ]; then
    echo "ERROR: $(basename "$so") needs $v > GLIBC_$MAX_GLIBC" >&2
    too_new=1
  fi
done
[ $missing -eq 0 ] && [ $too_new -eq 0 ]
