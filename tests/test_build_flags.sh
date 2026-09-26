#!/bin/sh
# The CMake toolchain and the make fragment must declare identical arch flags.
set -eu
cd "$(dirname "$0")/.."
c=$(sed -n 's/^set(MISTER_ARCH_FLAGS "\(.*\)")$/\1/p' build/cmake/arm-linux-gnueabihf.toolchain.cmake)
m=$(sed -n 's/^MISTER_ARCH_FLAGS := \(.*\)$/\1/p' build/make/mister-flags.mk)
[ -n "$c" ] && [ "$c" = "$m" ] || { echo "FAIL: cmake '$c' != make '$m'"; exit 1; }
case "$c" in *neon-vfpv4*) echo "FAIL: neon-vfpv4 SIGILLs on Cortex-A9"; exit 1;; esac
echo "build flags: ok ($c)"
