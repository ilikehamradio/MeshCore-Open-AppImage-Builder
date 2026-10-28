#!/usr/bin/env python3
"""Unit tests for strip_nags.py (AAA)."""

from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

import strip_nags


class StripNagsPrefsTests(unittest.TestCase):
    def test_force_map_prefs_sets_upload_off_and_prompt_shown(self) -> None:
        # Arrange
        with TemporaryDirectory() as tmp:
            prefs_path = Path(tmp) / "shared_preferences.json"
            prefs_path.write_text(
                json.dumps(
                    {
                        "flutter.app_settings": json.dumps(
                            {
                                "network_map_upload_enabled": True,
                                "network_map_prompt_shown": False,
                                "keep_me": 1,
                            }
                        )
                    }
                ),
                encoding="utf-8",
            )

            # Act
            settings = strip_nags.force_map_prefs(prefs_path)

            # Assert
            self.assertFalse(settings["network_map_upload_enabled"])
            self.assertTrue(settings["network_map_prompt_shown"])
            self.assertEqual(settings["keep_me"], 1)
            disk = json.loads(prefs_path.read_text(encoding="utf-8"))
            nested = json.loads(disk["flutter.app_settings"])
            self.assertFalse(nested["network_map_upload_enabled"])
            self.assertTrue(nested["network_map_prompt_shown"])


class StripNagsSourceTests(unittest.TestCase):
    def test_patch_upstream_sources_removes_banner_and_map_prompt(self) -> None:
        # Arrange
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            scanner = root / "lib" / "screens" / "scanner_screen.dart"
            scanner.parent.mkdir(parents=True)
            scanner.write_text(
                "import '../widgets/get_node_banner.dart';\n"
                "bottomNavigationBar: const GetNodeBanner(),\n"
                "floatingActionButton: null,\n",
                encoding="utf-8",
            )
            banner = root / "lib" / "widgets" / "get_node_banner.dart"
            banner.parent.mkdir(parents=True)
            banner.write_text("class GetNodeBanner {}", encoding="utf-8")
            opt_in = root / "lib" / "widgets" / "network_map_opt_in_dialog.dart"
            opt_in.write_text(
                "Future<void> maybeShowNetworkMapOptInDialog(BuildContext context) async {\n"
                "  final x = 1;\n"
                "}\n",
                encoding="utf-8",
            )
            settings = root / "lib" / "models" / "app_settings.dart"
            settings.parent.mkdir(parents=True)
            settings.write_text(
                "this.networkMapUploadEnabled = false,\n"
                "this.networkMapPromptShown = false,\n"
                "networkMapPromptShown:\n"
                "          json['network_map_prompt_shown'] as bool? ?? false,\n",
                encoding="utf-8",
            )

            # Act
            stats = strip_nags.patch_upstream_sources(root)

            # Assert
            self.assertTrue(stats["scanner_screen"])
            self.assertTrue(stats["get_node_banner"])
            self.assertTrue(stats["network_map_opt_in_dialog"])
            self.assertTrue(stats["app_settings_defaults"])
            scanner_text = scanner.read_text(encoding="utf-8")
            self.assertIn("bottomNavigationBar: null,", scanner_text)
            self.assertNotIn("GetNodeBanner", scanner_text)
            self.assertIn("SizedBox.shrink()", banner.read_text(encoding="utf-8"))
            self.assertIn(
                "appimage-builder: no map upload prompt",
                opt_in.read_text(encoding="utf-8"),
            )
            settings_text = settings.read_text(encoding="utf-8")
            self.assertIn("this.networkMapPromptShown = true,", settings_text)
            self.assertIn(
                "json['network_map_prompt_shown'] as bool? ?? true,",
                settings_text,
            )


if __name__ == "__main__":
    unittest.main()
