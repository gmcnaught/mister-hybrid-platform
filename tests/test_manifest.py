"""Manifest validation in tools/mister_platform.py."""
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import mister_platform as mp  # noqa: E402

BASE = """
[port]
name = "{name}"
profile = "{profile}"
{extra_port}
[launch]
process = "engine"
command = ["./engine"]
{extra_launch}
"""


def manifest(name="CashCowDX", profile="gm-fabric", extra_port="", extra_launch=""):
    d = Path(tempfile.mkdtemp())
    p = d / "mister-port.toml"
    p.write_text(BASE.format(name=name, profile=profile, extra_port=extra_port, extra_launch=extra_launch))
    return p


class Manifest(unittest.TestCase):
    def test_example_validates(self):
        m = mp.load_manifest(ROOT / "examples/cash.cow.dx/mister-port.toml")
        self.assertEqual(m["_profile"].name, "gm-fabric")

    def test_donut_example_validates(self):
        m = mp.load_manifest(ROOT / "examples/donut.dodo/mister-port.toml")
        self.assertEqual(m["launch"]["stall_timeout"], 6)

    def test_minimal(self):
        m = mp.load_manifest(manifest())
        self.assertEqual(m["port"]["corename"], "CashCowDX")

    def test_core_must_be_in_profile(self):
        with self.assertRaisesRegex(mp.ManifestError, "not listed in spec/profiles/gm-fabric.toml"):
            mp.load_manifest(manifest(name="NewGame"))

    def test_core_in_wrong_profile(self):
        with self.assertRaisesRegex(mp.ManifestError, "not listed"):
            mp.load_manifest(manifest(profile="solarus-fabric"))

    def test_unknown_profile(self):
        with self.assertRaisesRegex(mp.ManifestError, "unknown"):
            mp.load_manifest(manifest(profile="nope"))

    def test_bad_name(self):
        with self.assertRaisesRegex(mp.ManifestError, "letters, digits"):
            mp.load_manifest(manifest(name="Cash Cow"))

    def test_bad_env_key(self):
        with self.assertRaisesRegex(mp.ManifestError, "env key"):
            mp.load_manifest(manifest(extra_launch='env = { "bad-key" = "1" }'))

    def test_fabric_gate_needs_fabric(self):
        m = mp.load_manifest(manifest(name="OpenBOR", profile="openbor-classic", extra_launch="fabric_gate = true"))
        with self.assertRaisesRegex(mp.ManifestError, "has no fabric"):
            mp.render(m, Path(tempfile.mkdtemp()), None)

    def test_engine_cpus_range(self):
        with self.assertRaisesRegex(mp.ManifestError, "engine_cpus"):
            mp.load_manifest(manifest(extra_launch="engine_cpus = 4"))
        with self.assertRaisesRegex(mp.ManifestError, "stall_timeout"):
            mp.load_manifest(manifest(extra_launch='stall_timeout = "6"'))

    def test_stall_timeout_needs_fabric(self):
        m = mp.load_manifest(manifest(extra_launch="fabric_gate = false\nstall_timeout = 6"))
        with self.assertRaisesRegex(mp.ManifestError, "stall_timeout needs the fabric gate"):
            mp.render(m, Path(tempfile.mkdtemp()), None)

    def test_optional_lines(self):
        out = Path(tempfile.mkdtemp())
        mp.render(mp.load_manifest(manifest(extra_launch="engine_cpus = 3\nstall_timeout = 6")), out, None)
        text = (out / "games/CashCowDX/launch.sh").read_text()
        self.assertIn("MH_ENGINE_CPU=${MH_ENGINE_CPU:-3}", text)
        self.assertIn("MH_STALL_S=${MH_STALL_S:-6}", text)
        out = Path(tempfile.mkdtemp())
        mp.render(mp.load_manifest(manifest()), out, None)
        self.assertNotIn("MH_STALL_S", (out / "games/CashCowDX/launch.sh").read_text())

    def test_quoting(self):
        self.assertEqual(mp.dq('a "b" `c` \\d $E'), '"a \\"b\\" \\`c\\` \\\\d $E"')


if __name__ == "__main__":
    unittest.main()
