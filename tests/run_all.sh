#!/bin/sh
# Run every host test. Needs python3 >= 3.11, dash, bash >= 4, shellcheck, a C compiler;
# iverilog optional.
set -eu
cd "$(dirname "$0")/.."
BASH4=${BASH4:-bash}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 spec/gen.py --check
python3 -m unittest discover -s tests -p 'test_*.py'
dash tests/test_mem_wc_load.sh
dash tests/test_ini_main.sh
"$BASH4" tests/test_launch_lib.sh
"$BASH4" tests/test_render.sh
cc -std=c11 -Wall -Wextra -Werror -Idevice/main-hook/overlay \
   device/main-hook/overlay/hybrid_registry.c device/main-hook/test/test_registry.c -o "$T/treg"
"$T/treg"
sh tests/test_build_flags.sh
sh tests/test_sv_headers.sh
shellcheck -s sh device/sh/mem_wc_load.sh device/sh/ini_main.sh tests/test_ini_main.sh tests/test_mem_wc_load.sh tests/test_build_flags.sh tests/test_sv_headers.sh tests/run_all.sh
shellcheck -s bash device/sh/launch_lib.sh tests/test_launch_lib.sh tests/test_render.sh
shellcheck build/scripts/*.sh device/mem_wc/build.sh device/main-hook/build-hps.sh
echo "all host tests passed"
