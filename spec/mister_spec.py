"""Load and validate the DDR-map profiles in spec/profiles/*.toml.

A profile describes one FPGA core's shared-DDR contract: named regions (base +
size), named fields inside them (byte offset, optional size), the blitter
control-block word indices, the mem_wc allowlist and write-combining ranges, and
"roles" -- the engine-agnostic names (video_ctrl, joy_p1, audio_ring, ...) that
libmister and the device scripts look up instead of hard-coding an address.

Stdlib only (tomllib, Python >= 3.11) so it runs in any CI image.
"""
from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path

SPEC_DIR = Path(__file__).resolve().parent
PROFILE_DIR = SPEC_DIR / "profiles"
PAGE = 0x1000


class SpecError(Exception):
    pass


@dataclass
class Field:
    name: str
    off: int
    size: int  # 0 = unsized (a single word or an unbounded marker)


@dataclass
class Region:
    name: str
    base: int
    size: int
    within: str | None
    fields: dict[str, Field]

    @property
    def end(self) -> int:
        return self.base + self.size


@dataclass
class Profile:
    name: str
    description: str
    cores: list[str]
    fb_default: tuple[int, int]
    regions: dict[str, Region]
    ctrl: dict[str, int]
    mem_wc: dict | None
    audio: dict
    roles: dict[str, str]
    path: Path = field(repr=False)

    def resolve(self, ref: str) -> int:
        """'region.FIELD' -> physical byte address; 'region' -> region base."""
        region, _, fname = ref.partition(".")
        if region not in self.regions:
            raise SpecError(f"{self.name}: unknown region in {ref!r}")
        r = self.regions[region]
        if not fname:
            return r.base
        if fname not in r.fields:
            raise SpecError(f"{self.name}: unknown field in {ref!r}")
        return r.base + r.fields[fname].off

    def role_phys(self) -> dict[str, int]:
        return {role: self.resolve(ref) for role, ref in self.roles.items()}


def _load(path: Path) -> Profile:
    with path.open("rb") as f:
        d = tomllib.load(f)
    regions = {}
    for rname, rd in d.get("regions", {}).items():
        sizes = rd.get("sizes", {})
        unknown = set(sizes) - set(rd.get("fields", {}))
        if unknown:
            raise SpecError(f"{path.name}: sizes for undeclared fields {sorted(unknown)} in {rname}")
        fields = {n: Field(n, off, sizes.get(n, 0)) for n, off in rd.get("fields", {}).items()}
        regions[rname] = Region(rname, rd["base"], rd["size"], rd.get("within"), fields)
    p = Profile(
        name=d["name"],
        description=d.get("description", ""),
        cores=list(d.get("cores", [])),
        fb_default=tuple(d.get("fb_default", (0, 0))),
        regions=regions,
        ctrl=dict(d.get("ctrl", {})),
        mem_wc=d.get("mem_wc"),
        audio=dict(d.get("audio", {})),
        roles=dict(d.get("roles", {})),
        path=path,
    )
    if p.name != path.stem:
        raise SpecError(f"{path.name}: name {p.name!r} must equal the file stem")
    return p


def validate(p: Profile) -> None:
    errs: list[str] = []
    for r in p.regions.values():
        if r.within:
            parent = p.regions.get(r.within)
            if parent is None:
                errs.append(f"region {r.name}: within unknown region {r.within}")
            elif not (parent.base <= r.base and r.end <= parent.end):
                errs.append(f"region {r.name}: not inside {r.within}")
        spans = []
        for f in r.fields.values():
            if f.off < 0 or f.off + max(f.size, 1) > r.size:
                errs.append(f"{r.name}.{f.name}: 0x{f.off:X}+0x{f.size:X} outside region size 0x{r.size:X}")
            spans.append((f.off, f.off + max(f.size, 1), f.name))
        spans.sort()
        for (a0, a1, an), (b0, _b1, bn) in zip(spans, spans[1:]):
            if b0 < a1:
                errs.append(f"{r.name}: {an} [0x{a0:X},0x{a1:X}) overlaps {bn} at 0x{b0:X}")
    # Top-level regions must not overlap each other unless one is declared `within`.
    tops = sorted((r for r in p.regions.values() if not r.within), key=lambda r: r.base)
    for a, b in zip(tops, tops[1:]):
        if b.base < a.end:
            errs.append(f"regions {a.name} and {b.name} overlap (declare `within` if intended)")
    for role, ref in p.roles.items():
        try:
            p.resolve(ref)
        except SpecError as e:
            errs.append(f"role {role}: {e}")
    if p.ctrl:
        vals = sorted(p.ctrl.values())
        if len(set(vals)) != len(vals):
            errs.append("ctrl: duplicate word index")
        if "fabric_ctrl" not in p.roles:
            errs.append("ctrl defined but no fabric_ctrl role")
    if p.mem_wc:
        base, size = p.mem_wc["base"], p.mem_wc["size"]
        if base % PAGE or size % PAGE:
            errs.append("mem_wc base/size must be page-aligned")
        for lo, hi in p.mem_wc.get("wc_ranges", []):
            if lo % PAGE or hi % PAGE or not (base <= lo < hi <= base + size):
                errs.append(f"mem_wc range [0x{lo:X},0x{hi:X}) not page-aligned or outside allowlist")
            if "fabric_ctrl" in p.roles:
                ctrl = p.resolve(p.roles["fabric_ctrl"]) & ~(PAGE - 1)
                if lo <= ctrl < hi:
                    errs.append("mem_wc range covers the fabric control page (doorbell must stay strongly-ordered)")
    if errs:
        raise SpecError(f"{p.path.name}:\n  " + "\n  ".join(errs))


def load_all(profile_dir: Path = PROFILE_DIR) -> dict[str, Profile]:
    profiles = {}
    for path in sorted(profile_dir.glob("*.toml")):
        p = _load(path)
        validate(p)
        profiles[p.name] = p
    cores: dict[str, str] = {}
    for p in profiles.values():
        for c in p.cores:
            if c in cores:
                raise SpecError(f"core {c} claimed by both {cores[c]} and {p.name}")
            cores[c] = p.name
    return profiles


def mem_wc_union(profiles: dict[str, Profile]) -> tuple[int, int]:
    """Smallest single allowlist covering every profile's mem_wc window.

    The device loader inserts mem_wc once with this window so no port ever has
    to rmmod/reload it for a differently-sized allowlist (the reload is what
    hung a device on 2026-08-06)."""
    wins = [(p.mem_wc["base"], p.mem_wc["base"] + p.mem_wc["size"]) for p in profiles.values() if p.mem_wc]
    if not wins:
        return 0, 0
    lo = min(w[0] for w in wins)
    hi = max(w[1] for w in wins)
    return lo, hi - lo
