#!/usr/bin/env python3
"""Check that a port's hand-written DDR constants match its spec profile.

Generalises solarus-mister scripts/tests/test_wire_constants.py (issue #88):
each port lists the places a DDR constant is still typed by hand (C, SV, shell)
in a conformance file, and this fails on any value that disagrees with
spec/profiles/<profile>.toml. When a constant is later replaced by an include
of spec/generated/, its check is deleted.

    spec/conform.py <conformance.toml> [--root <port checkout>]

Conformance file:

    profile = "gm-fabric"
    [[check]]
    file    = "fpga/rtl/blitter_defs.vh"           # relative to --root
    pattern = "`define\\s+BLTCTRL_QW\\s+29'h([0-9A-Fa-f]+)"   # group 1 = the value
    expect  = "fabric.BLTCTRL"
    unit    = "qw"            # phys (default) | off | qw | qw_off | size | int
    radix   = 16              # optional; default: Python int(x, 0)

expect forms: "region.FIELD" | "region" (its base) | "ctrl.WORD" |
"mem_wc.base" | "mem_wc.size" | "fb_default.w" | "fb_default.h" | "audio.rate".
unit "size" on "region" gives the region size and on "region.FIELD" the field size.
unit "qw_off" is the qword offset from the region base.
"""
from __future__ import annotations

import argparse
import re
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mister_spec import Profile, SpecError, load_all  # noqa: E402


def expected(p: Profile, expect: str, unit: str) -> int:
    head, _, tail = expect.partition(".")
    if head == "ctrl":
        return p.ctrl[tail]
    if head == "mem_wc":
        return p.mem_wc[tail]
    if head == "fb_default":
        return p.fb_default[{"w": 0, "h": 1}[tail]]
    if head == "audio":
        return p.audio[tail]
    if head not in p.regions:
        raise SpecError(f"unknown region {head!r}")
    r = p.regions[head]
    if not tail:
        return {"phys": r.base, "size": r.size, "qw": r.base >> 3}[unit]
    f = r.fields[tail]
    phys = r.base + f.off
    return {"phys": phys, "off": f.off, "qw": phys >> 3, "qw_off": f.off >> 3, "size": f.size}[unit]


def run(conf_path: Path, root: Path) -> int:
    with conf_path.open("rb") as fh:
        conf = tomllib.load(fh)
    profiles = load_all()
    p = profiles[conf["profile"]]
    fails = 0
    for i, c in enumerate(conf.get("check", [])):
        where = f"{c['file']}: {c.get('expect', c.get('value'))}"
        path = root / c["file"]
        if not path.exists():
            print(f"FAIL {where}: file missing")
            fails += 1
            continue
        m = re.search(c["pattern"], path.read_text(errors="replace"), re.M)
        if not m:
            print(f"FAIL {where}: pattern not found: {c['pattern']}")
            fails += 1
            continue
        raw = m.group(1)
        got = int(raw, c["radix"]) if "radix" in c else int(raw, 0)
        want = c["value"] if "value" in c else expected(p, c["expect"], c.get("unit", "phys"))
        if got != want:
            print(f"FAIL {where}: file has 0x{got:X}, spec {p.name} says 0x{want:X}")
            fails += 1
        else:
            print(f"ok   {where} = 0x{got:X}")
    n = len(conf.get("check", []))
    print(f"{conf_path.name}: {n - fails}/{n} constants match {p.name}")
    return 1 if fails else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("conformance", type=Path)
    ap.add_argument("--root", type=Path, default=Path("."))
    a = ap.parse_args()
    try:
        return run(a.conformance, a.root)
    except (SpecError, KeyError) as e:
        print(f"conformance error: {e!r}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
