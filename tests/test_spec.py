"""Tests for spec/mister_spec.py, spec/gen.py and spec/conform.py (stdlib unittest)."""
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "spec"))
import mister_spec  # noqa: E402
import gen  # noqa: E402

GOOD = """
name = "{name}"
cores = ["{core}"]
fb_default = [320, 240]
[regions.fabric]
base = 0x3B000000
size = 0x00100000
[regions.fabric.fields]
CTRL = 0x0
RING = 0x40
[regions.fabric.sizes]
RING = 0x1000
[ctrl]
C_SUBMIT = 0
C_DONE = 5
[mem_wc]
base = 0x3B000000
size = 0x00100000
wc_ranges = [[0x3B001000, 0x3B100000]]
[roles]
fabric_ctrl = "fabric.CTRL"
"""


def load_dir(**files):
    d = Path(tempfile.mkdtemp())
    for name, text in files.items():
        (d / f"{name}.toml").write_text(textwrap.dedent(text))
    return mister_spec.load_all(d)


class SpecValidation(unittest.TestCase):
    def test_real_profiles_load(self):
        ps = mister_spec.load_all()
        self.assertEqual(set(ps), {"gm-fabric", "solarus-fabric", "openbor-classic"})
        self.assertEqual(ps["gm-fabric"].role_phys()["scanout_counter"], 0x3BFB0018)
        self.assertEqual(ps["solarus-fabric"].role_phys()["scanout_counter"], 0x3A070000)

    def test_mem_wc_union_covers_every_profile(self):
        base, size = mister_spec.mem_wc_union(mister_spec.load_all())
        self.assertEqual((base, size), (0x3B000000, 0x01200000))

    def test_good_minimal(self):
        load_dir(a=GOOD.format(name="a", core="A"))

    def test_field_overlap_rejected(self):
        bad = GOOD.format(name="a", core="A").replace("RING = 0x40\n", "RING = 0x40\nX = 0x80\n")
        with self.assertRaisesRegex(mister_spec.SpecError, "overlaps"):
            load_dir(a=bad)

    def test_field_outside_region_rejected(self):
        bad = GOOD.format(name="a", core="A").replace("RING = 0x40\n", "RING = 0x40\nX = 0x200000\n")
        with self.assertRaisesRegex(mister_spec.SpecError, "outside region"):
            load_dir(a=bad)

    def test_doorbell_page_must_not_be_write_combined(self):
        bad = GOOD.format(name="a", core="A").replace("0x3B001000, 0x3B100000", "0x3B000000, 0x3B100000")
        with self.assertRaisesRegex(mister_spec.SpecError, "control page"):
            load_dir(a=bad)

    def test_core_claimed_twice_rejected(self):
        with self.assertRaisesRegex(mister_spec.SpecError, "claimed by both"):
            load_dir(a=GOOD.format(name="a", core="X"), b=GOOD.format(name="b", core="X"))

    def test_unknown_role_target_rejected(self):
        bad = GOOD.format(name="a", core="A").replace('"fabric.CTRL"', '"fabric.NOPE"')
        with self.assertRaisesRegex(mister_spec.SpecError, "unknown field"):
            load_dir(a=bad)

    def test_name_must_match_file(self):
        with self.assertRaisesRegex(mister_spec.SpecError, "file stem"):
            load_dir(a=GOOD.format(name="b", core="A"))


class Generated(unittest.TestCase):
    def test_committed_output_is_current(self):
        r = subprocess.run([sys.executable, str(ROOT / "spec/gen.py"), "--check"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_check_detects_stale(self):
        out = Path(tempfile.mkdtemp())
        subprocess.run([sys.executable, str(ROOT / "spec/gen.py"), "--out", str(out)], check=True, capture_output=True)
        p = out / "mister_cores.tsv"
        p.write_text(p.read_text() + "Bogus\tgm-fabric\n")
        r = subprocess.run([sys.executable, str(ROOT / "spec/gen.py"), "--check", "--out", str(out)],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)


class Conformance(unittest.TestCase):
    def run_conf(self, text, files):
        d = Path(tempfile.mkdtemp())
        for name, body in files.items():
            (d / name).write_text(body)
        (d / "c.toml").write_text(textwrap.dedent(text))
        return subprocess.run([sys.executable, str(ROOT / "spec/conform.py"), str(d / "c.toml"), "--root", str(d)],
                              capture_output=True, text=True)

    CONF = """
        profile = "gm-fabric"
        [[check]]
        file = "x.vh"
        pattern = "`define\\\\s+SRC_QW\\\\s+29'h([0-9A-Fa-f]+)"
        expect = "fabric.SRC"
        unit = "qw"
        radix = 16
        """

    def test_match(self):
        r = self.run_conf(self.CONF, {"x.vh": "`define SRC_QW 29'h07610000\n"})
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_mismatch_fails(self):
        r = self.run_conf(self.CONF, {"x.vh": "`define SRC_QW 29'h07620000\n"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("spec gm-fabric says 0x7610000", r.stdout)

    def test_missing_pattern_fails(self):
        r = self.run_conf(self.CONF, {"x.vh": "nothing here\n"})
        self.assertEqual(r.returncode, 1)


if __name__ == "__main__":
    unittest.main()
