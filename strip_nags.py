#!/usr/bin/env python3
"""Strip MeshCore Open promo nags from upstream Dart sources before flutter build.

Patches applied under an upstream checkout:
  - Remove shop/affiliate banner from the connect screen
  - Disable DNS banner loader (when present)
  - Skip the network-map contribute opt-in dialog
  - Default map upload off; mark prompt already shown

Also can force SharedPreferences at AppImage runtime so existing installs
stop uploading / get re-prompted.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

SETTINGS_KEY = "flutter.app_settings"
UPLOAD_KEY = "network_map_upload_enabled"
PROMPT_KEY = "network_map_prompt_shown"

GET_NODE_BANNER_STUB = '''import 'package:flutter/material.dart';

/// Shop / affiliate banner removed in MeshCore-Open-AppImage-Builder builds.
class GetNodeBanner extends StatelessWidget {
  final Future<dynamic> Function()? loadConfig;
  const GetNodeBanner({super.key, this.loadConfig});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
'''


def force_map_prefs(prefs_path: Path) -> dict[str, object]:
    """Ensure map upload is off and the opt-in prompt never appears again."""
    prefs_path.parent.mkdir(parents=True, exist_ok=True)
    if prefs_path.is_file():
        prefs = json.loads(prefs_path.read_text(encoding="utf-8"))
    else:
        prefs = {}

    raw_settings = prefs.get(SETTINGS_KEY, "{}")
    if isinstance(raw_settings, str):
        settings = json.loads(raw_settings) if raw_settings else {}
    elif isinstance(raw_settings, dict):
        settings = raw_settings
    else:
        settings = {}

    settings[UPLOAD_KEY] = False
    settings[PROMPT_KEY] = True
    prefs[SETTINGS_KEY] = json.dumps(settings, separators=(",", ":"))
    prefs_path.write_text(json.dumps(prefs), encoding="utf-8")
    return settings


def default_prefs_paths() -> list[Path]:
    xdg = os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local" / "share"))
    base = Path(xdg)
    return [
        base / "com.meshcore.meshcore_open" / "shared_preferences.json",
        base / "meshcore_open" / "shared_preferences.json",
    ]


def patch_upstream_sources(source_root: Path) -> dict[str, bool]:
    """Patch MeshCore Open Dart sources before `flutter build`."""
    root = source_root
    stats: dict[str, bool] = {}

    scanner = root / "lib" / "screens" / "scanner_screen.dart"
    if scanner.is_file():
        text = scanner.read_text(encoding="utf-8")
        patched = text.replace(
            "bottomNavigationBar: const GetNodeBanner(),",
            "bottomNavigationBar: null,",
        )
        if "GetNodeBanner" not in patched:
            patched = patched.replace(
                "import '../widgets/get_node_banner.dart';\n",
                "",
            )
        stats["scanner_screen"] = patched != text
        if stats["scanner_screen"]:
            scanner.write_text(patched, encoding="utf-8")
    else:
        stats["scanner_screen"] = False

    banner_widget = root / "lib" / "widgets" / "get_node_banner.dart"
    if banner_widget.is_file():
        banner_widget.write_text(GET_NODE_BANNER_STUB, encoding="utf-8")
        stats["get_node_banner"] = True
    else:
        stats["get_node_banner"] = False

    banner_service = root / "lib" / "services" / "node_banner_service.dart"
    if banner_service.is_file():
        text = banner_service.read_text(encoding="utf-8")
        needle = "Future<NodeBannerConfig?> load() async {"
        if needle in text and "appimage-builder: strip banner" not in text:
            text = text.replace(
                needle,
                "Future<NodeBannerConfig?> load() async {\n"
                "    return null; // appimage-builder: strip banner\n"
                "  }\n\n"
                "  Future<NodeBannerConfig?> _loadOriginalDisabled() async {",
                1,
            )
            banner_service.write_text(text, encoding="utf-8")
            stats["node_banner_service"] = True
        else:
            stats["node_banner_service"] = "appimage-builder: strip banner" in text
    else:
        stats["node_banner_service"] = False

    opt_in = root / "lib" / "widgets" / "network_map_opt_in_dialog.dart"
    if opt_in.is_file():
        text = opt_in.read_text(encoding="utf-8")
        marker = (
            "Future<void> maybeShowNetworkMapOptInDialog(BuildContext context) async {"
        )
        if marker in text and "appimage-builder: no map upload prompt" not in text:
            text = text.replace(
                marker,
                marker + "\n  return; // appimage-builder: no map upload prompt",
                1,
            )
            opt_in.write_text(text, encoding="utf-8")
            stats["network_map_opt_in_dialog"] = True
        else:
            stats["network_map_opt_in_dialog"] = (
                "appimage-builder: no map upload prompt" in text
            )
    else:
        stats["network_map_opt_in_dialog"] = False

    settings_model = root / "lib" / "models" / "app_settings.dart"
    if settings_model.is_file():
        text = settings_model.read_text(encoding="utf-8")
        patched = text.replace(
            "this.networkMapPromptShown = false,",
            "this.networkMapPromptShown = true,",
        )
        patched = patched.replace(
            "json['network_map_prompt_shown'] as bool? ?? false,",
            "json['network_map_prompt_shown'] as bool? ?? true,",
        )
        stats["app_settings_defaults"] = patched != text
        if stats["app_settings_defaults"]:
            settings_model.write_text(patched, encoding="utf-8")
    else:
        stats["app_settings_defaults"] = False

    return stats


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_src = sub.add_parser(
        "patch-sources",
        help="Patch upstream Dart sources before flutter build",
    )
    p_src.add_argument("source_root", type=Path)

    p_prefs = sub.add_parser(
        "force-map-prefs",
        help="Force map opt-out in SharedPreferences (runtime)",
    )
    p_prefs.add_argument(
        "--path",
        type=Path,
        action="append",
        dest="paths",
        help="Prefs JSON path (repeatable). Default: XDG meshcore locations.",
    )

    args = parser.parse_args(argv)

    if args.cmd == "patch-sources":
        stats = patch_upstream_sources(args.source_root)
        print(json.dumps({"ok": True, "stats": stats}, sort_keys=True))
        if not any(stats.values()):
            print("warning: no upstream source patches applied", file=sys.stderr)
            return 2
        return 0

    if args.cmd == "force-map-prefs":
        paths = args.paths or default_prefs_paths()
        results = {str(path): force_map_prefs(path) for path in paths}
        print(json.dumps({"ok": True, "prefs": results}, sort_keys=True))
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
