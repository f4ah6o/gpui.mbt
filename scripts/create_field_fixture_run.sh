#!/bin/sh
# Allocate a new retained evidence directory; never overwrite an earlier run.
set -eu
if [ "$#" -ne 1 ]; then
  echo "usage: create_field_fixture_run.sh OUTPUT_ROOT" >&2
  exit 2
fi
mkdir -p "$1"
root=$(cd "$1" && pwd)
mktemp -d "$root/field-run.XXXXXX"
