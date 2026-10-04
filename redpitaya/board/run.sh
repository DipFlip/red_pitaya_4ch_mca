#!/usr/bin/env bash
# Stdout is exclusively binary list mode; setup/restore logs go to stderr.
set -euo pipefail
cd /root/mca-fpga
exec 9>/run/redpitaya-mca-owner.lock
flock -n 9 || { echo 'Another MCA owner is running' >&2; exit 1; }
child=
attempted=0
umask 077
task_token=${4:-manual}
printf '%s %s\n' "$$" "$task_token" > /run/redpitaya-mca-owner.pid
cleanup() {
  trap - EXIT
  trap '' HUP INT TERM
  if [[ -n "$child" ]]; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  if [[ "$attempted" == 1 ]]; then
    # Restoration must finish even if the SSH stderr pipe has disappeared.
    {
      bash restore.sh
      curl --fail --silent --max-time 5 --retry 2 --retry-all-errors \
        'http://127.0.0.1/bazaar?start=scopegenpro' || true
    } > /root/mca-fpga/last_restore.log 2>&1
  fi
  rm -f /run/redpitaya-mca-owner.pid
  cat /root/mca-fpga/last_restore.log >&2 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
attempted=1
bash load.sh red_pitaya.bin "$(cat expected_sha256)" >&2
python3 readout.py --custom-bitstream-loaded --format binary --batch-ms 100 \
  --channels "${5:-1}" --seconds "${1:-0}" --short-us "${2:-2}" --long-us "${3:-25}" &
child=$!
wait "$child"
child=
