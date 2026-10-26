"""Keep the removed Shepherd Design design-system bundle out of the shipping app."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class NoBundledDesignSystemTests(unittest.TestCase):
    def test_shepherd_design_is_only_a_test_fixture(self):
        app = ROOT / "Sources" / "ShepherdApp"
        self.assertFalse((app / "ShepherdDesignSystem.swift").exists())
        for source in app.glob("*.swift"):
            with self.subTest(source=source.name):
                self.assertNotIn("ShepherdDesignSystem", source.read_text())
        self.assertTrue((ROOT / "Tests/ShepherdTestSupport/ShepherdDesignSystemFixture.swift").is_file())
