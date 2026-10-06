#!/usr/bin/env python3
"""Observe paired CPU spans through the actual reusable command-palette slice."""

import argparse
import importlib.util
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("palette_cpu_profile", HERE / "input-hotpath.py")
profile = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(profile)
profile.WORKLOAD = profile.REPO / "testing/palette_hotpath"
profile.SCOPE = "headless command-palette input/composition/filter/visible-list/Pango/shared-scene CPU spans"
profile.PRODUCER_FILES = ["input-hotpath.py", "palette-hotpath.py"]
profile.EXPECTED_CALLS = {"text.measure": 384, "text.admit": 384,
                          "composition.update": 32, "composition.commit": 32,
                          "input.handle": 64, "picker.filter": 32, "picker.visible": 32,
                          "scene.field": 32, "scene.list": 32, "scene.build": 32}
validate_evidence = profile.validate_evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hotpath-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    # Exactly seven alternating on/off pairs, identical runtime/source and
    # behavior digests, no comparison threshold or device-latency claim.
    return profile.execute(args.hotpath_root, args.output, repeats=7)


if __name__ == "__main__":
    sys.exit(main())
