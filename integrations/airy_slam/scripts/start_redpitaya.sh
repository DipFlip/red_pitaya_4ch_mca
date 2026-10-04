#!/usr/bin/env bash
# Reader + Rust gamma UI, using the current SLAM session. --reader-only skips UI.
set -euo pipefail
TASK_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_REPO"
# Per-device connection defaults; explicit environment settings take precedence.
if [[ -f redpitaya/runtime/connection.env ]]; then source redpitaya/runtime/connection.env; fi
TASK_READER_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reader-only) TASK_READER_ONLY=1; shift ;;
    --channels) [[ $# -ge 2 ]] || { echo 'Missing channel list' >&2; exit 2; }; export REDPITAYA_CHANNELS="$2"; shift 2 ;;
    *) echo 'Usage: start_redpitaya.sh [--reader-only] [--channels 1,2,3,4]' >&2; exit 2 ;;
  esac
done
export REDPITAYA_CHANNELS="${REDPITAYA_CHANNELS:-1}"
python3 - "$REDPITAYA_CHANNELS" <<'CHANNEL_CHECK'
import sys
sys.path.insert(0,"redpitaya/board")
from readout import parse_channels
parse_channels(sys.argv[1])
CHANNEL_CHECK
echo "Active MCA inputs: $REDPITAYA_CHANNELS"
TASK_COMPOSE=(docker compose -f compose.yaml -f compose.redpitaya.yaml --profile redpitaya --profile gamma-rs)
TASK_DISTRO="${ROS_DISTRO:-jazzy}"
if [[ "${BUILD:-0}" == 1 ]] || ! docker image inspect "airy-slam/redpitaya:$TASK_DISTRO" >/dev/null 2>&1; then
  "${TASK_COMPOSE[@]}" build redpitaya
fi
if [[ "$TASK_READER_ONLY" == 0 ]] && { [[ "${BUILD:-0}" == 1 ]] || ! docker image inspect "airy-slam/gamma-rs:$TASK_DISTRO-redpitaya" >/dev/null 2>&1; }; then
  TASK_GIT="$(git rev-parse --short HEAD)/$(git -C ../psl-api rev-parse --short HEAD)"
  (cd .. && docker build --build-arg "GAMMA_RS_GIT=$TASK_GIT+redpitaya" \
    -t "airy-slam/gamma-rs:$TASK_DISTRO-redpitaya" -f airy_slam/docker/gamma_rs/Dockerfile .)
fi
bash scripts/deploy_redpitaya.sh
if [[ "$TASK_READER_ONLY" == 0 ]]; then
  # Select one reconstruction implementation. Sigma50 can continue on its own topic.
  docker compose --profile gamma stop gamma >/dev/null 2>&1 || true
  if [[ "${START_SLAM:-0}" == 1 ]]; then bash scripts/start_lightning.sh; fi
  RENDER_GID="$(getent group render | cut -d: -f3)" "${TASK_COMPOSE[@]}" up -d gamma_rs
  echo 'Red Pitaya gross-count UI: http://radxa:8080 (existing SLAM; START_SLAM=1 starts it)'
fi
# Bring up the subscriber before acquisition to avoid startup batch loss.
"${TASK_COMPOSE[@]}" up -d redpitaya
echo 'Reader logs: docker compose -f compose.yaml -f compose.redpitaya.yaml logs -f redpitaya'
