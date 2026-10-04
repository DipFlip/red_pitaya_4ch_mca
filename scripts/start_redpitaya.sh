#!/usr/bin/env bash
set -euo pipefail
TASK_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_REPO"
if [[ -f redpitaya/runtime/connection.env ]]; then source redpitaya/runtime/connection.env; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channels) [[ $# -ge 2 ]] || { echo 'Missing channel list' >&2; exit 2; }; export REDPITAYA_CHANNELS="$2"; shift 2 ;;
    *) echo 'Usage: start_redpitaya.sh [--channels 1,2,3,4]' >&2; exit 2 ;;
  esac
done
export REDPITAYA_CHANNELS="${REDPITAYA_CHANNELS:-1}"
python3 - "$REDPITAYA_CHANNELS" <<'CHANNEL_CHECK'
import sys
sys.path.insert(0,"redpitaya/board")
from readout import parse_channels
parse_channels(sys.argv[1])
CHANNEL_CHECK
mkdir -p redpitaya/captures
docker compose build redpitaya
bash scripts/deploy_redpitaya.sh
docker compose up -d redpitaya
echo "MCA active inputs: $REDPITAYA_CHANNELS. Logs: docker compose logs -f redpitaya"
