#!/bin/sh
# Optional, explicit route when this executor has a real Debian13 root/apt.
# Does not change repositories, sandbox policy, credentials, or permissions.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$(id -u)" != 0 ]; then
  echo "Run this helper only in an authorized Debian13 root/apt context. It does not escalate itself." >&2
  exit 1
fi
if [ ! -r /var/lib/dpkg/status ] || ! command -v apt-get >/dev/null 2>&1; then
  echo "No usable system package database/apt in this executor; prefix-only Mozc conversion remains blocked." >&2
  exit 1
fi
. /etc/os-release
if [ "${ID:-}" != debian ] || [ "${VERSION_ID:-}" != 13 ] || [ "$(dpkg --print-architecture)" != amd64 ]; then
  echo "The reviewed lock targets Debian13 amd64. Do not mix these pins with another distribution." >&2
  exit 1
fi
version=$(python3 - "$here/profile.lock.json" <<'PY'
import json, sys
print(next(x['version'] for x in json.load(open(sys.argv[1]))['packages'] if x['name'] == 'mozc-server'))
PY
)
apt-get update
apt-get install --no-install-recommends -y "mozc-server=$version" "mozc-data=$version"
dpkg-query -W -f='${Package} ${Version}\n' mozc-server mozc-data
test -x /usr/lib/mozc/mozc_server
echo "The compiled Mozc server path is installed. Conversion still needs the interactive baseline check."
