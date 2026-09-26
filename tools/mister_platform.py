#!/usr/bin/env python3
"""mister-platform: render a port's device files from its mister-port.toml.

    tools/mister_platform.py render <mister-port.toml> --out <dir> [--hook-binary MiSTer_hybrid]
    tools/mister_platform.py validate <mister-port.toml>

`render` writes a tree that mirrors /media/fat, ready to merge into a release zip:

    games/<name>/launch.sh                  thin launcher -> platform/launch_lib.sh
    games/<name>/platform/                  launch_lib.sh, mem_wc_load.sh, profile .env,
                                            mister_mem_wc.env, mister_cores.tsv, mem_wc/*.ko
    linux/hybrid.d/<corename>.conf          MiSTer_hybrid registry entry
    linux/MiSTer_hybrid                     only with --hook-binary
    Scripts/<name>.sh, Scripts/<name>_CoresMenu.sh
    _Other/<name>.mgl

Manifest (mister-port.toml):

    [port]
    name     = "CashCowDX"      # games/<name>, logs/<name>, Scripts/<name>.sh, RBF prefix
    title    = "Cash Cow DX"
    corename = "CashCowDX"      # CONF_STR name (/tmp/CORENAME); default: name
    profile  = "gm-fabric"      # spec/profiles/<profile>.toml; must list corename
    engine   = "godot4"         # informational

    [launch]
    process       = "cashcowdx"               # engine process name (comm)
    command       = ["./cashcowdx", "--main-pack", "CashCowDX.pck"]
    ready_pattern = "fabric bring-up"         # optional
    cpu_isolate   = true                      # default true
    mem_wc        = true                      # default true
    fabric_gate   = true                      # default: true when the profile has a fabric
    env           = { MISTER_JOY = "1", XDG_DATA_HOME = "$MH_GAMEDIR/data" }

    [scripts]
    required_files = [ ["CashCowDX.pck", "copy it from your GOG install (see README.md)"] ]
    extra          = "dist/scripts-extra.sh"  # optional snippet, relative to the manifest

Command arguments and env values are emitted inside double quotes, so $MH_GAMEDIR
and other launcher variables expand; ", \\ and ` are escaped.
"""
from __future__ import annotations

import argparse
import re
import shutil
import stat
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "spec"))
from mister_spec import load_all  # noqa: E402

TEMPLATES = ROOT / "device" / "templates"
NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,40}$")
ENV_RE = re.compile(r"^[A-Z_][A-Z0-9_]*$")


class ManifestError(Exception):
    pass


def dq(s: str) -> str:
    """Double-quote for bash, keeping $VAR expansion."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("`", "\\`") + '"'


def platform_version() -> str:
    try:
        return subprocess.run(["git", "-C", str(ROOT), "describe", "--tags", "--always", "--dirty"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def load_manifest(path: Path) -> dict:
    with path.open("rb") as f:
        m = tomllib.load(f)
    port = m.get("port", {})
    launch = m.get("launch", {})
    for key in ("name", "profile"):
        if key not in port:
            raise ManifestError(f"[port] {key} is required")
    for key in ("process", "command"):
        if key not in launch:
            raise ManifestError(f"[launch] {key} is required")
    name = port["name"]
    if not NAME_RE.match(name):
        raise ManifestError(f"[port] name {name!r}: letters, digits, _ only (it becomes paths and a CORENAME match)")
    port.setdefault("corename", name)
    port.setdefault("title", name)
    if not NAME_RE.match(port["corename"]):
        raise ManifestError(f"[port] corename {port['corename']!r} is not a valid CONF_STR name")
    if not re.match(r"^[A-Za-z0-9_.+-]+$", launch["process"]):
        raise ManifestError(f"[launch] process {launch['process']!r} is not a process name")
    if not isinstance(launch["command"], list) or not launch["command"]:
        raise ManifestError("[launch] command must be a non-empty list")
    for k in launch.get("env", {}):
        if not ENV_RE.match(k):
            raise ManifestError(f"[launch] env key {k!r} is not a shell variable name")
    profiles = load_all()
    prof = profiles.get(port["profile"])
    if prof is None:
        raise ManifestError(f"[port] profile {port['profile']!r} unknown; have {sorted(profiles)}")
    if port["corename"] not in prof.cores:
        raise ManifestError(f"core {port['corename']!r} is not listed in spec/profiles/{prof.name}.toml cores; "
                            f"add it there so launchers can verify the loaded core's DDR map")
    m["_profile"] = prof
    m["_dir"] = path.resolve().parent
    return m


def subst(text: str, values: dict[str, str]) -> str:
    def rep(mt):
        key = mt.group(1)
        if key not in values:
            raise ManifestError(f"template placeholder @{key}@ has no value")
        return values[key]
    return re.sub(r"@([A-Z_]+)@", rep, text)


def write(path: Path, text: str, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable:
        path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def render(m: dict, out: Path, hook_binary: Path | None) -> list[Path]:
    port, launch, scripts = m["port"], m["launch"], m.get("scripts", {})
    prof = m["_profile"]
    name = port["name"]
    gamedir = f"/media/fat/games/{name}"
    logdir = f"/media/fat/logs/{name}"
    has_fabric = "fabric_ctrl" in prof.roles
    gate = launch.get("fabric_gate", has_fabric)
    if gate and not has_fabric:
        raise ManifestError(f"fabric_gate = true but profile {prof.name} has no fabric")

    env_lines = [f"    export {k}={dq(str(v))}" for k, v in launch.get("env", {}).items()]
    req = []
    for entry in scripts.get("required_files", []):
        f, hint = (entry + [""])[:2] if isinstance(entry, list) else (entry, "")
        req.append(f'[ -f "$GAMEDIR/{f}" ] || die {dq(f"missing $GAMEDIR/{f}" + (f" -- {hint}" if hint else ""))}')
    extra = ""
    if "extra" in scripts:
        extra = "\n# --- port-specific (mister-port.toml [scripts] extra) ---\n" + (m["_dir"] / scripts["extra"]).read_text()
    values = {
        "NAME": name, "TITLE": port["title"], "CORENAME": port["corename"], "PROFILE": prof.name,
        "GAMEDIR": gamedir, "LOGDIR": logdir, "PROCESS": launch["process"],
        "NAME_FIRST": name[0], "NAME_REST": name[1:],
        "COMMAND": " ".join(dq(str(a)) for a in launch["command"]),
        "READY_PATTERN": dq(launch.get("ready_pattern", "")),
        "CPU_ISOLATE": "1" if launch.get("cpu_isolate", True) else "0",
        "MEM_WC": "1" if launch.get("mem_wc", True) else "0",
        "FABRIC_GATE_LINE": "" if gate else "MH_FABRIC_GATE=0",
        "ENV_EXPORTS": "\n".join(env_lines),
        "REQUIRED_FILES": "\n".join(req),
        "SCRIPTS_EXTRA": extra,
        "PLATFORM_VERSION": platform_version(),
    }
    written: list[Path] = []

    def emit(rel: str, template: str, executable: bool = False):
        p = out / rel
        write(p, subst((TEMPLATES / template).read_text(), values), executable)
        written.append(p)

    emit(f"games/{name}/launch.sh", "launch.sh.in", True)
    emit(f"linux/hybrid.d/{port['corename']}.conf", "hybrid.conf.in")
    emit(f"Scripts/{name}.sh", "Scripts.sh.in", True)
    emit(f"Scripts/{name}_CoresMenu.sh", "CoresMenu.sh.in", True)
    emit(f"_Other/{name}.mgl", "mgl.in")

    plat = out / "games" / name / "platform"
    gen = ROOT / "spec" / "generated"
    for src in [ROOT / "device/sh/launch_lib.sh", ROOT / "device/sh/mem_wc_load.sh",
                gen / f"mister_map_{prof.name.replace('-', '_')}.env", gen / "mister_mem_wc.env",
                gen / "mister_cores.tsv"]:
        plat.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, plat / src.name)
        written.append(plat / src.name)
    if launch.get("mem_wc", True) and prof.mem_wc:
        (plat / "mem_wc").mkdir(exist_ok=True)
        for ko in sorted((ROOT / "device/mem_wc/prebuilt").glob("*.ko")):
            shutil.copy2(ko, plat / "mem_wc" / ko.name)
            written.append(plat / "mem_wc" / ko.name)
    if hook_binary:
        dst = out / "linux" / "MiSTer_hybrid"
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(hook_binary, dst)
        dst.chmod(0o755)
        written.append(dst)
    return written


def main() -> int:
    ap = argparse.ArgumentParser(prog="mister-platform", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render")
    r.add_argument("manifest", type=Path)
    r.add_argument("--out", type=Path, required=True)
    r.add_argument("--hook-binary", type=Path)
    v = sub.add_parser("validate")
    v.add_argument("manifest", type=Path)
    a = ap.parse_args()
    try:
        m = load_manifest(a.manifest)
        if a.cmd == "validate":
            print(f"{a.manifest}: ok ({m['port']['name']}, profile {m['_profile'].name})")
            return 0
        files = render(m, a.out, a.hook_binary)
        print(f"rendered {len(files)} files for {m['port']['name']} into {a.out}")
        return 0
    except (ManifestError, tomllib.TOMLDecodeError, FileNotFoundError) as e:
        print(f"mister-platform: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
