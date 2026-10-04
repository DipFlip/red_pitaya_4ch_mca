#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
docker compose -f compose.yaml -f compose.redpitaya.yaml --profile redpitaya stop redpitaya
echo 'Reader stopped; the board wrapper restores the stock FPGA and oscilloscope.'
