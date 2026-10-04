#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_VENDOR="$TASK_ROOT/vendor/redpitaya-fpga"
TASK_REV=728a4f37e9c0a9b5ba1d9b7a0d44c38bbd2dc674
mkdir -p "$TASK_ROOT/vendor" "$TASK_ROOT/build"
if [[ ! -d "$TASK_VENDOR/.git" ]]; then
  git clone https://github.com/RedPitaya/RedPitaya-FPGA.git "$TASK_VENDOR"
  git -C "$TASK_VENDOR" checkout --detach "$TASK_REV"
fi
[[ "$(git -C "$TASK_VENDOR" rev-parse HEAD)" == "$TASK_REV" ]] || {
  echo 'Existing vendor checkout has the wrong revision; no files changed.' >&2; exit 1;
}
echo "Pinned vendor checkout: $TASK_REV"
