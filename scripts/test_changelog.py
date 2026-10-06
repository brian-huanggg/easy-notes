#!/usr/bin/env python3
"""Unit tests for changelog.py: python3 scripts/test_changelog.py"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import changelog

SAMPLE = """# Changelog

說明

## [Unreleased]

### Added

- 新功能 A
  接續的一行

### Fixed

- 修好 B

## [1.1.0] - 2026-10-05

### Added

- 舊功能
"""


class ChangelogTests(unittest.TestCase):
    def test_has_unreleased(self):
        self.assertTrue(changelog.has_unreleased(SAMPLE))
        self.assertFalse(changelog.has_unreleased(SAMPLE.replace("## [Unreleased]", "## [1.2.0] - 2026-11-01")))
        self.assertFalse(changelog.has_unreleased("## [Unreleased]\n\n## [1.0.0] - x\n- a\n"))

    def test_promote(self):
        out = changelog.promote(SAMPLE, "1.2.0", "2026-11-01")
        self.assertIn("## [1.2.0] - 2026-11-01\n", out)
        self.assertNotIn("Unreleased", out)

    def test_insert_goes_above_latest_version(self):
        block = "## [1.2.0] - 2026-11-01\n\n### Added\n\n- 新\n"
        out = changelog.insert(SAMPLE.replace("## [Unreleased]", "## [1.1.5] - 2026-10-20"), block)
        self.assertLess(out.index("## [1.2.0]"), out.index("## [1.1.5]"))
        self.assertLess(out.index("說明"), out.index("## [1.2.0]"))
        self.assertIn("- 新\n\n## [1.1.5]", out)

    def test_show_json(self):
        date, body = changelog.find(SAMPLE, "Unreleased")
        self.assertIsNone(date)
        self.assertEqual(changelog.parse_body(body), [
            {"name": "Added", "items": ["新功能 A 接續的一行"]},
            {"name": "Fixed", "items": ["修好 B"]},
        ])
        self.assertEqual(changelog.find(SAMPLE, "1.1.0")[0], "2026-10-05")
        self.assertIsNone(changelog.find(SAMPLE, "9.9.9"))


if __name__ == "__main__":
    unittest.main()
