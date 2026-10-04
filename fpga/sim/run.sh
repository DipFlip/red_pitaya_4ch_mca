#!/usr/bin/env bash
set -euo pipefail
task_sim_root=$(cd "$(dirname "$0")/.." && pwd)
task_python=${PYTHON:-python3}
"$task_python" "$task_sim_root/sim/test_core.py"
iverilog -g2012 -Wall -s mmio_tb -o "$task_sim_root/build/mmio.vvp" \
  "$task_sim_root/rtl/mca_core.sv" "$task_sim_root/rtl/mca_mmio.sv" "$task_sim_root/sim/mmio_tb.sv"
vvp "$task_sim_root/build/mmio.vvp"
iverilog -g2012 -Wall -s four_tb -o "$task_sim_root/build/four.vvp" "$task_sim_root"/rtl/*.sv "$task_sim_root/sim/four_tb.sv"
vvp "$task_sim_root/build/four.vvp"
"$task_python" "$task_sim_root/sim/test_readout.py"
"$task_python" "$task_sim_root/sim/test_export.py"
"$task_python" "$task_sim_root/sim/test_wire.py"
