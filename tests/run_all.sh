#!/bin/sh
# Run every host test. Needs python3 >= 3.11, dash, shellcheck.
set -eu
cd "$(dirname "$0")/.."
python3 spec/gen.py --check
python3 -m unittest discover -s tests -p 'test_*.py'
dash tests/test_mem_wc_load.sh
sh tests/test_build_flags.sh
sh tests/test_sv_headers.sh
shellcheck -s sh device/sh/*.sh tests/*.sh
shellcheck build/scripts/*.sh device/mem_wc/build.sh
echo "all host tests passed"
