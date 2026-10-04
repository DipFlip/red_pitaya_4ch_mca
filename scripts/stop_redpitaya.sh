#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
docker compose stop redpitaya
echo 'Reader stopped; check logs for the final summary and stock FPGA restoration.'
