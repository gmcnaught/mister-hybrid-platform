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

    def test_corename_with_space(self):
        m = mp.load_manifest(manifest(name="MalditaCastilla", extra_port='corename = "Maldita Castilla"'))
        self.assertEqual(m["port"]["gamedir"], "MalditaCastilla")
        for bad in (" Maldita Castilla", "Maldita Castilla ", "Maldita/Castilla", "Maldita;C"):
            with self.assertRaisesRegex(mp.ManifestError, "CONF_STR name"):
                mp.load_manifest(manifest(name="MalditaCastilla", extra_port=f'corename = "{bad}"'))

    def test_gamedir(self):
        m = mp.load_manifest(manifest(extra_port='gamedir = "gmloader"'))
        self.assertEqual(m["port"]["gamedir"], "gmloader")
        self.assertEqual(mp.load_manifest(manifest())["port"]["gamedir"], "CashCowDX")
        for bad in ("games/x", "Maldita Castilla", "..", "a;b"):
            with self.assertRaisesRegex(mp.ManifestError, "gamedir"):
                mp.load_manifest(manifest(extra_port=f'gamedir = "{bad}"'))

    def test_osd_reset(self):
        out = Path(tempfile.mkdtemp())
        mp.render(mp.load_manifest(manifest(extra_launch="osd_reset = 19")), out, None)
        conf = (out / "linux/hybrid.d/CashCowDX.conf").read_text()
        self.assertIn("\nosd_reset=19\n", conf)
        self.assertIn("reset_clear=/tmp/mister-hybrid/CashCowDX.retry\n", conf)
        self.assertIn("reset_clear=/tmp/mister-hybrid/CashCowDX.lock/pid\nreset_clear=/tmp/mister-hybrid/CashCowDX.lock\n", conf)
        out2 = Path(tempfile.mkdtemp())
        mp.render(mp.load_manifest(manifest()), out2, None)
        self.assertNotIn("osd_reset", (out2 / "linux/hybrid.d/CashCowDX.conf").read_text())
        for bad in ("32", "-1", "true", '"19"'):
            with self.assertRaisesRegex(mp.ManifestError, "osd_reset"):
                mp.load_manifest(manifest(extra_launch=f"osd_reset = {bad}"))

    def test_engine_log_is_a_name(self):
        with self.assertRaisesRegex(mp.ManifestError, "engine_log"):
            mp.load_manifest(manifest(extra_launch='engine_log = "../x.log"'))

    def test_maldita_example_validates(self):
        m = mp.load_manifest(ROOT / "examples/maldita.castilla/mister-port.toml")
        self.assertEqual(m["port"]["corename"], "Maldita Castilla")

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
