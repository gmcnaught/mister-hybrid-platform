#!/usr/bin/env python3
"""mister-platform: render a port's device files from its mister-port.toml.

    tools/mister_platform.py render <mister-port.toml> --out <dir> [--hook-binary MiSTer_hybrid]
    tools/mister_platform.py validate <mister-port.toml>

`render` writes a tree that mirrors /media/fat, ready to merge into a release zip:

    games/<gamedir>/launch.sh               thin launcher -> platform/launch_lib.sh
    games/<gamedir>/platform/                  launch_lib.sh, mem_wc_load.sh, ini_main.sh, profile .env,
                                            mister_mem_wc.env, mister_cores.tsv, mem_wc/*.ko
    games/<gamedir>/platform/hybrid.d/<corename>.conf   MiSTer_hybrid registry entry
    games/<gamedir>/platform/MiSTer_hybrid  only with --hook-binary

Everything a port installs stays under its own games/<gamedir>/ (the wiki's
standard core path), Scripts/ and _Other/. Nothing goes under linux/: the
Downloader refuses that root folder for every database but distribution_mister,
so update_all could not install the port. MiSTer_hybrid reads hybrid.d/ next to
itself, so each port's copy only sees its own entry.
    Scripts/<name>.sh, Scripts/<name>_CoresMenu.sh
    _Other/<name>.mgl

Manifest (mister-port.toml):

    [port]
    name     = "CashCowDX"      # games/<name>, logs/<name>, Scripts/<name>.sh, RBF prefix
    title    = "Cash Cow DX"
    corename = "CashCowDX"      # CONF_STR name (/tmp/CORENAME, MiSTer.ini section); may contain
                                # spaces ("Maldita Castilla"), not at either end; default: name
    gamedir  = "CashCowDX"      # games/<gamedir>: launcher + engine payload; default: name
    mgl      = "CashCowDX"      # _Other/<mgl>.mgl, may contain spaces; default: name
    profile  = "gm-fabric"      # spec/profiles/<profile>.toml; must list corename
    engine   = "godot4"         # informational

    [launch]
    process       = "cashcowdx"               # engine process name (comm)
    command       = ["./cashcowdx", "--main-pack", "CashCowDX.pck"]
    ready_pattern = "fabric bring-up"         # optional
    fail_pattern  = "fabric bring-up SOFT-FAILED"  # optional: engine reports a dead fabric;
                                              # the gate reloads the core as for a wedge
    cpu_isolate   = true                      # default true
    engine_cpus   = 2                         # taskset mask the engine starts on; default 2
                                              # (CPU1: the engine pins its own main thread to CPU0).
                                              # 3 for an engine that does not pin, with cpu_isolate = false
    stall_timeout = 6                         # optional: reload the core when the fabric stays
                                              # wedged this many seconds mid-game (0/absent = off)
    mem_wc        = true                      # default true
    fabric_gate   = true                      # default: true when the profile has a fabric
    env           = { MISTER_JOY = "1", XDG_DATA_HOME = "$MH_GAMEDIR/data" }
    engine_log    = "maldita.log"             # file in logs/<name>/; default <name lowercased>.log
    test_env      = "$MH_GAMEDIR/bench.env"   # optional: sourced before and after the port env
    osd_reset     = 19                        # optional: CONF_STR "T" status bit whose OSD pulse
                                              # makes MiSTer_hybrid restart the launcher

    [scripts]
    required_files = [ ["CashCowDX.pck", "copy it from your GOG install (see README.md)"] ]
    extra          = "dist/scripts-extra.sh"  # optional snippet, relative to the manifest
    legacy_main    = ["/media/fat/games/CashCowDX/MiSTer_CashCowDX"]
                     # pre-platform per-game main= wrappers: the Scripts entry moves
                     # [corename] main= from one of these to MiSTer_hybrid, then deletes it.
                     # LEGACY_SHARED_HOOK (platform v0.3.x) is always handled too.

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
# CONF_STR core names may contain spaces (hybrid_registry.c accepts the same set).
FILE_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
ENV_RE = re.compile(r"^[A-Z_][A-Z0-9_]*$")
# CONF_STR names as MiSTer writes them to /tmp/CORENAME, e.g. "Cursed Castilla".
CORENAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 _.+-]{0,63}$")


# Platform v0.3.x installed one shared hook and registry under linux/, which no
# database can install. The Scripts entry moves main= off it and removes it once
# no MiSTer.ini section uses it.
LEGACY_SHARED_HOOK = "/media/fat/linux/MiSTer_hybrid"
LEGACY_SHARED_REGISTRY = "/media/fat/linux/hybrid.d"


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
    port.setdefault("gamedir", name)
    if not CORENAME_RE.match(port["corename"]) or port["corename"].endswith(" "):
        raise ManifestError(f"[port] corename {port['corename']!r} is not a valid CONF_STR name")
    if port["corename"] != port["corename"].strip():
        raise ManifestError(f"[port] corename {port['corename']!r} is not a valid CONF_STR name")
    if not NAME_RE.match(port["gamedir"]):
        raise ManifestError(f"[port] gamedir {port['gamedir']!r}: letters, digits, _ only")
    port.setdefault("mgl", name)
    if not CORENAME_RE.match(port["mgl"]) or port["mgl"] != port["mgl"].strip():
        raise ManifestError(f"[port] mgl {port['mgl']!r}: letters, digits, space, _ . - only")
    if "engine_log" in launch and not FILE_RE.match(launch["engine_log"]):
        raise ManifestError(f"[launch] engine_log {launch['engine_log']!r}: a file name, not a path")
    bit = launch.get("osd_reset")
    if bit is not None and (isinstance(bit, bool) or not isinstance(bit, int) or not 0 <= bit <= 31):
        raise ManifestError(f"[launch] osd_reset {bit!r}: the CONF_STR T option's status bit, 0..31")
    if not re.match(r"^[A-Za-z0-9_.+-]+$", launch["process"]):
        raise ManifestError(f"[launch] process {launch['process']!r} is not a process name")
    if not isinstance(launch["command"], list) or not launch["command"]:
        raise ManifestError("[launch] command must be a non-empty list")
    for key, lo, hi in (("engine_cpus", 1, 3), ("stall_timeout", 0, 600)):
        v = launch.get(key)
        if v is not None and (not isinstance(v, int) or isinstance(v, bool) or not lo <= v <= hi):
            raise ManifestError(f"[launch] {key} = {v!r}: expected an integer {lo}..{hi}")
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
    gdir = port["gamedir"]
    gamedir = f"/media/fat/games/{gdir}"
    logdir = f"/media/fat/logs/{name}"
    has_fabric = "fabric_ctrl" in prof.roles
    gate = launch.get("fabric_gate", has_fabric)
    if gate and not has_fabric:
        raise ManifestError(f"fabric_gate = true but profile {prof.name} has no fabric")
    if launch.get("stall_timeout", 0) and not gate:
        raise ManifestError("stall_timeout needs the fabric gate (a profile with a fabric, fabric_gate not false)")
    # Optional launcher settings: ${VAR:-value}, so the environment can still override them.

    env_lines = [f"    export {k}={dq(str(v))}" for k, v in launch.get("env", {}).items()]
    req = []
    for entry in scripts.get("required_files", []):
        f, hint = (entry + [""])[:2] if isinstance(entry, list) else (entry, "")
        req.append(f'[ -f "$GAMEDIR/{f}" ] || die {dq(f"missing $GAMEDIR/{f}" + (f" -- {hint}" if hint else ""))}')
    extra = ""
    if "extra" in scripts:
        extra = "\n# --- port-specific (mister-port.toml [scripts] extra) ---\n" + (m["_dir"] / scripts["extra"]).read_text()
    legacy = scripts.get("legacy_main", [])
    for p in legacy:
        if not re.match(r"^/media/fat/[A-Za-z0-9_./-]+$", p):
            raise ManifestError(f"[scripts] legacy_main {p!r}: expected an absolute /media/fat path")
    legacy = [*legacy, LEGACY_SHARED_HOOK]
    pats = "|".join(legacy)
    legacy_main = (
        "\n# --- older main= targets -> this port's MiSTer_hybrid (mister-port.toml legacy_main,\n"
        "# plus the platform v0.3.x shared hook under linux/) ---\n"
        "if [ -x \"$HOOK\" ] && [ -f \"$REGISTRY\" ]; then\n"
        "\told_main=$(mh_ini_main)\n"
        f"\tcase \"$old_main\" in {pats})\n"
        "\t\tmh_ini_set_main \"$HOOK\" && echo \"launcher: MiSTer.ini [$CORENAME] main=$old_main -> $HOOK\" ;;\n"
        "\tesac\n"
        "\t# shellcheck disable=SC2043  # one entry when the port has no legacy_main\n"
        f"\tfor w in {' '.join(legacy)}; do\n"
        "\t\t[ -f \"$w\" ] && ! grep -q \"^main=$w\" \"$MH_INI_FILE\" 2>/dev/null && rm -f \"$w\" && echo \"launcher: removed $w\"\n"
        "\tdone\n"
        f"\tif [ \"$(mh_ini_main)\" != {LEGACY_SHARED_HOOK} ] && [ -f \"{LEGACY_SHARED_REGISTRY}/$CORENAME.conf\" ]; then\n"
        f"\t\trm -f \"{LEGACY_SHARED_REGISTRY}/$CORENAME.conf\" && echo \"launcher: removed {LEGACY_SHARED_REGISTRY}/$CORENAME.conf\"\n"
        f"\t\trmdir {LEGACY_SHARED_REGISTRY} 2>/dev/null\n"
        "\tfi\n"
        "fi\n")
    # Optional launcher variables (launch_lib.sh defaults apply when absent).
    opt = [f"MH_{var}=${{MH_{var}:-{launch[key]}}}"
           for key, var in (("engine_cpus", "ENGINE_CPU"), ("stall_timeout", "STALL_S")) if key in launch]
    if "engine_log" in launch:
        opt.append(f'MH_LOG="${{MH_ROOT:-}}{logdir}/{launch["engine_log"]}"')
    if "test_env" in launch:
        opt.append(f"MH_TEST_ENV={dq(launch['test_env'])}")
    # OSD Reset: MiSTer_hybrid restarts the launcher on the T option's pulse, first
    # clearing launch_lib's retry mark and lock (MH_STATE_DIR/<name>.*) so the fresh
    # launcher neither inherits a spent retry budget nor stands down on the lock.
    reset_lines = ""
    if launch.get("osd_reset") is not None:
        st = f"/tmp/mister-hybrid/{name}"
        reset_lines = (f"osd_reset={launch['osd_reset']}\n"
                       f"reset_clear={st}.retry\nreset_clear={st}.lock/pid\nreset_clear={st}.lock\n")
    values = {
        "NAME": name, "TITLE": port["title"], "CORENAME": port["corename"], "PROFILE": prof.name,
        "GAMEDIR": gamedir, "LOGDIR": logdir, "PROCESS": launch["process"],
        "HOOK": f"{gamedir}/platform/MiSTer_hybrid", "REGISTRY_DIR": f"{gamedir}/platform/hybrid.d",
        "LEGACY_HOOK": LEGACY_SHARED_HOOK,
        "GDIR": gdir, "GDIR_FIRST": gdir[0], "GDIR_REST": gdir[1:],
        "OPTIONAL_VARS": "\n".join(opt), "OSD_RESET_LINES": reset_lines,
        "COMMAND": " ".join(dq(str(a)) for a in launch["command"]),
        "READY_PATTERN": dq(launch.get("ready_pattern", "")),
        "FAIL_PATTERN": dq(launch.get("fail_pattern", "")),
        "CPU_ISOLATE": "1" if launch.get("cpu_isolate", True) else "0",
        "MEM_WC": "1" if launch.get("mem_wc", True) else "0",
        "FABRIC_GATE_LINE": "" if gate else "MH_FABRIC_GATE=0",
        "ENV_EXPORTS": "\n".join(env_lines),
        "REQUIRED_FILES": "\n".join(req),
        "SCRIPTS_EXTRA": extra,
        "LEGACY_MAIN": legacy_main,
        "PLATFORM_VERSION": platform_version(),
    }
    written: list[Path] = []

    def emit(rel: str, template: str, executable: bool = False):
        p = out / rel
        write(p, subst((TEMPLATES / template).read_text(), values), executable)
        written.append(p)

    emit(f"games/{gdir}/launch.sh", "launch.sh.in", True)
    emit(f"games/{gdir}/platform/hybrid.d/{port['corename']}.conf", "hybrid.conf.in")
    emit(f"Scripts/{name}.sh", "Scripts.sh.in", True)
    emit(f"Scripts/{name}_CoresMenu.sh", "CoresMenu.sh.in", True)
    emit(f"_Other/{port['mgl']}.mgl", "mgl.in")

    plat = out / "games" / gdir / "platform"
    gen = ROOT / "spec" / "generated"
    for src in [ROOT / "device/sh/launch_lib.sh", ROOT / "device/sh/mem_wc_load.sh", ROOT / "device/sh/ini_main.sh",
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
        dst = plat / "MiSTer_hybrid"
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
