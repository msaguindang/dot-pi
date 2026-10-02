import datetime as dt
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).with_name("fixtures")
MODULE_PATH = ROOT / "scripts" / "fetch_discord.py"
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("fetch_discord", MODULE_PATH)
fetch_discord = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch_discord)


class SaveToObsidianFixturesTest(unittest.TestCase):
    date = dt.datetime(2026, 4, 1)

    def load_fixture(self, name):
        with (FIXTURES / name).open(encoding="utf-8") as handle:
            return json.load(handle)

    def render_fixture(self, name):
        fixture = self.load_fixture(name)
        with tempfile.TemporaryDirectory() as temporary:
            vault = Path(temporary)
            template = vault / "template.md"
            output = vault / "logs" / "2026" / "2026-04-01 - Work Log.md"
            template.write_text(fixture["config"]["template"], encoding="utf-8")
            config = {
                "vault_path": str(vault),
                "template_path": "template.md",
                "output_folder": "logs",
                "author_header_pattern": "### {author}",
                "empty_placeholder_pattern": r"- ",
                **{key: value for key, value in fixture["config"].items() if key != "template"},
            }
            fetch_discord.save_to_obsidian(self.date, fixture["messages"], config)
            return output.read_text(encoding="utf-8"), fixture["expected"]

    def test_unknown_username_retains_live_display_name(self):
        text, expected = self.render_fixture("unknown-username.json")
        for fragment in expected["contains"]:
            self.assertIn(fragment, text)
        for fragment in expected["absent"]:
            self.assertNotIn(fragment, text)

    def test_display_name_override_is_cosmetic(self):
        text, expected = self.render_fixture("display-name-override.json")
        for fragment in expected["contains"]:
            self.assertIn(fragment, text)
        for fragment in expected["absent"]:
            self.assertNotIn(fragment, text)

    def test_self_username_routes_to_my_focus(self):
        text, expected = self.render_fixture("self-username.json")
        for fragment in expected["contains"]:
            self.assertIn(fragment, text)
        for fragment in expected["absent"]:
            self.assertNotIn(fragment, text)

    def test_normalized_output_is_byte_idempotent(self):
        fixture = self.load_fixture("duplicate-normalization.json")
        with tempfile.TemporaryDirectory() as temporary:
            vault = Path(temporary)
            (vault / "template.md").write_text(fixture["config"]["template"], encoding="utf-8")
            config = {
                "vault_path": str(vault),
                "template_path": "template.md",
                "output_folder": "logs",
                "author_header_pattern": "### {author}",
                "empty_placeholder_pattern": r"- ",
            }
            fetch_discord.save_to_obsidian(self.date, fixture["messages"], config)
            output = vault / "logs" / "2026" / "2026-04-01 - Work Log.md"
            first = output.read_bytes()
            fetch_discord.save_to_obsidian(self.date, fixture["messages"], config)
            second = output.read_bytes()
            self.assertEqual(first, second)
            self.assertEqual(first.decode().count(fixture["expected"]["count_once"]), 1)

    def test_heading_levels_bound_each_injection(self):
        text, expected = self.render_fixture("section-boundaries.json")
        for fragment in expected["contains"]:
            self.assertIn(fragment, text)
        positions = [text.index(fragment) for fragment in expected["order"]]
        self.assertEqual(positions, sorted(positions))


if __name__ == "__main__":
    unittest.main()
