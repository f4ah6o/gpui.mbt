#!/usr/bin/env bash
set -euo pipefail
if (($# != 4)) || [[ $EUID != 0 ]]; then echo 'Usage (sudo): run-root.sh APP_BUNDLE PROFILE HELPER_BUILD EVIDENCE_PARENT'; exit 2; fi
HERE="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$HERE/../../.." && pwd -P)"
APP="$(cd "$1" && pwd -P)"
PROFILE="$(cd "$2" && pwd -P)"
HELPERS="$(cd "$3" && pwd -P)"
PARENT="$(cd "$4" && pwd -P)"
shasum -c "$HELPERS/sources.sha256"
shasum -c "$HELPERS/binaries.sha256"
CONSOLE_UID=$(/usr/bin/stat -f '%u' /Users/fu2hito)
[[ $CONSOLE_UID == 501 ]] || { echo 'Unexpected console profile'; exit 3; }
# The producer verifies the actual primary console and GUI session via public
# APIs. This UID is the explicitly selected test profile, not /dev/console owner.
/usr/bin/systemextensionsctl list | /usr/bin/grep -F 'org.pqrs.Karabiner-DriverKit-VirtualHIDDevice' | /usr/bin/grep -Fq '[activated enabled]' || { echo 'Driver unavailable; no input sent'; exit 3; }
RUN=$(/usr/bin/mktemp -d "$PARENT/product.XXXXXX")
/usr/sbin/chown "$CONSOLE_UID:20" "$RUN"
echo "Evidence directory: $RUN"
/bin/cp "$HELPERS/binaries.sha256" "$HELPERS/sources.sha256" "$RUN/"
/bin/echo '072fa83e824c1b633f508f60cbad87b41aab3047' > "$RUN/driver-source-commit.txt"
/usr/bin/systemextensionsctl list > "$RUN/systemextensions.txt"
DAEMON='/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon'
daemon_pid=''
producer_pid=''
cleanup() {
  if [[ -n $producer_pid ]] && [[ $(/bin/ps -p "$producer_pid" -o comm= 2>/dev/null || true) == "$HELPERS/producer" ]]; then
    /bin/kill -TERM "$producer_pid" 2>/dev/null || true
    wait "$producer_pid" 2>/dev/null || true
  fi
  if [[ -n $daemon_pid ]] && [[ $(/bin/ps -p "$daemon_pid" -o comm= 2>/dev/null || true) == "$DAEMON" ]]; then
    /bin/kill -TERM "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  echo 'Session ended. Driver remains installed; no launchd job was added.'
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if ! /usr/bin/pgrep -f '^/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon$' > "$RUN/existing-daemon.txt"; then
  "$DAEMON" > "$RUN/daemon.log" 2>&1 & daemon_pid=$!
  echo "$daemon_pid" > "$RUN/owned-daemon.pid"
fi
for ((i=0;i<100;i++)); do
  [[ -S '/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock' ]] && break
  /bin/sleep 0.1
done
[[ -S '/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock' ]] || { echo 'Daemon socket unavailable; no input'; exit 3; }
"$HELPERS/producer" "$RUN/producer.sock" "$CONSOLE_UID" "$APP/Contents/MacOS/GpuiTextField" "$RUN/app.pid" > "$RUN/producer.jsonl" 2> "$RUN/producer.stderr.log" &
producer_pid=$!
echo "$producer_pid" > "$RUN/producer.pid"
for ((i=0;i<200;i++)); do
  /usr/bin/grep -Fq '"kind":"ready"' "$RUN/producer.jsonl" && break
  /bin/kill -0 "$producer_pid" 2>/dev/null || break
  /bin/sleep 0.1
done
/usr/bin/grep -Fq '"kind":"ready"' "$RUN/producer.jsonl" || { echo 'Producer setup incomplete; no fixture input sent'; exit 3; }
echo 'Virtual HID ready. Sending fixed E2E sequence automatically; do not type or change focus.'
status=0
/bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -n -u "#$CONSOLE_UID" /usr/bin/env \
  GPUI_TEST_HID_SOCKET="$RUN/producer.sock" GPUI_TEST_HID_PRODUCER_PID="$producer_pid" \
  /usr/bin/python3 "$HERE/run-user.py" "$REPO" "$APP" "$PROFILE" "$RUN" "$HELPERS/activate-owned" \
  > "$RUN/collector.stdout.log" 2> "$RUN/collector.stderr.log" || status=$?
# App exit closes the authenticated socket; give the producer bounded cleanup.
for ((i=0;i<50;i++)); do
  /bin/kill -0 "$producer_pid" 2>/dev/null || break
  /bin/sleep 0.1
done
if /bin/kill -0 "$producer_pid" 2>/dev/null; then /bin/kill -TERM "$producer_pid"; fi
producer_status=0
wait "$producer_pid" || producer_status=$?
producer_pid=''
echo "$status" > "$RUN/collector.exit"
echo "$producer_status" > "$RUN/producer.exit"
# Stop only this run's daemon before verifying cleanup, retaining preexisting services.
if [[ -n $daemon_pid ]]; then
  /bin/kill -TERM "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  daemon_pid=''
fi
/usr/bin/python3 - "$RUN" "$HELPERS/producer" "$APP/Contents/MacOS/GpuiTextField" <<'PY_CLEANUP'
import json, pathlib, subprocess, sys
run = pathlib.Path(sys.argv[1])
def same_process(pid_file, executable):
    if not pid_file.exists(): return False
    result = subprocess.run(["/bin/ps", "-p", pid_file.read_text().strip(), "-o", "comm="], capture_output=True, text=True)
    return result.returncode == 0 and result.stdout.strip() == executable
owned_daemon = run / "owned-daemon.pid"
daemon_stopped = not owned_daemon.exists() or subprocess.run(["/bin/ps", "-p", owned_daemon.read_text().strip(), "-o", "comm="], capture_output=True).returncode != 0
(run / "runtime-cleanup.json").write_text(json.dumps({"owned_daemon_stopped": daemon_stopped,
    "producer_stopped": not same_process(run / "producer.pid", sys.argv[2]),
    "app_stopped": not same_process(run / "app.pid", sys.argv[3])}, indent=2))
PY_CLEANUP
/bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -n -u "#$CONSOLE_UID" /usr/bin/python3 \
  "$HERE/validate.py" "$REPO" "$RUN" > "$RUN/validation.stdout.log" 2> "$RUN/validation.stderr.log" || status=1
/bin/cat "$RUN/validation.stdout.log"
exit "$status"
