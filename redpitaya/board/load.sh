#!/usr/bin/env bash
# Run on the board only after build signoff and transfer validation.
set -euo pipefail
if [[ $# != 2 || ! "$2" =~ ^[0-9a-f]{64}$ ]]; then
  echo 'Usage: load.sh /root/mca-fpga/red_pitaya.bin expected-sha256' >&2
  exit 2
fi
task_binary=$1
task_expected_sha=$2
task_model=$(/opt/redpitaya/bin/profiles -f)
[[ "$task_model" == z20_125_4ch ]] || { echo "Wrong board model: $task_model" >&2; exit 1; }
task_actual_sha=$(sha256sum "$task_binary")
[[ "${task_actual_sha%% *}" == "$task_expected_sha" ]] || { echo 'Upload checksum mismatch' >&2; exit 1; }

# This OS's overlay.sh uses /opt/<name>/fpga.bin for a custom image, even
# though its help describes an arbitrary path argument. Use a separate folder.
task_stock=/opt/redpitaya/fpga/z20_125_4ch/v0.94
test -r "$task_stock/fpga.bin" && test -r "$task_stock/fpga.dtbo"
mkdir -p /opt/mca-fpga
cp "$task_binary" /opt/mca-fpga/fpga.bin
cp "$task_stock/fpga.dtbo" /opt/mca-fpga/fpga.dtbo
sha256sum "$task_stock/fpga.bin" "$task_stock/fpga.dtbo" > /root/mca-fpga/stock_sha256.txt

restore_on_error() {
  echo 'Custom load failed; restoring stock FPGA' >&2
  /opt/redpitaya/sbin/overlay.sh v0.94
}
trap restore_on_error ERR
# Stopping the active app can close the first HTTP connection before a reply.
# Repeat the idempotent stop before attempting to replace its FPGA personality.
curl --fail --silent --show-error --max-time 5 --retry 2 --retry-delay 1 \
  --retry-all-errors 'http://127.0.0.1/bazaar?stop=scopegenpro'
/opt/redpitaya/sbin/overlay.sh mca-fpga custom custom
[[ "$(cat /sys/class/fpga_manager/fpga0/state)" == operating ]]
task_id=$(/opt/redpitaya/bin/monitor 0x40700000)
[[ "$task_id" == *4d434134* || "$task_id" == *4D434134* ]] || {
  echo "MCA ID verification failed: $task_id" >&2; false;
}
sha256sum -c /root/mca-fpga/stock_sha256.txt
trap - ERR
echo 'Custom MCA loaded temporarily. Stock files and boot settings preserved.'
