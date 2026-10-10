#!/usr/bin/env python3
"""Propagate CoreText framework requirements to native macOS consumers."""

import json
import os
import sys


def main() -> int:
    json.load(sys.stdin)
    if (
        os.environ.get("MOON_HOST_OS") == "macos"
        and os.environ.get("MOON_BACKEND") == "native"
    ):
        output = {
            "link_configs": [
                {
                    "package": "f4ah6o/gpui/platform/macos_text",
                    "link_flags": (
                        "-framework CoreText -framework CoreGraphics "
                        "-framework CoreFoundation"
                    ),
                }
            ]
        }
    else:
        output = {}
    print(json.dumps(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
