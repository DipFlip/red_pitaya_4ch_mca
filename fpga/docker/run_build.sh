#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 || ! -d "$1" || ( $# -eq 2 && "$2" != --reuse-project ) ]]; then
  echo 'Usage: run_build.sh /path/to/installed-AMD-tools [--reuse-project]' >&2
  exit 2
fi
task_fpga_root=$(cd "$(dirname "$0")/.." && pwd)
task_tools_root=$(cd "$1" && pwd)
python3 "$task_fpga_root/prepare_vendor.py"
task_reuse=0
if [[ ${2:-} == --reuse-project ]]; then
  task_reuse=1
  python3 - "$task_fpga_root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
vendor = root / 'vendor/redpitaya-fpga'
if not (vendor / 'prj/v0.94/build/redpitaya.xpr').exists():
    raise SystemExit('No existing project; use a full build first')
tail = (vendor / 'red_pitaya_vivado_Z20_4.tcl').read_text().split('open_run impl_1\n', 1)[1]
header = '''open_project build/redpitaya.xpr
if {[get_property PART [current_project]] ne "xc7z020clg400-1"} {error "Wrong existing project part"}
if {[get_property TOP [current_fileset]] ne "red_pitaya_top_4ADC"} {error "Wrong existing project top"}
if {[lsearch -exact [get_property verilog_define [current_fileset]] Z20_4] < 0} {error "Wrong existing model"}
set path_out out
set path_sdk sdk
add_files -norecurse rtl/mca_four.sv rtl/mca_bus_cdc.sv
add_files -fileset constrs_1 rtl/mca_cdc.xdc
update_compile_order -fileset sources_1
reset_run synth_1
launch_runs synth_1 -jobs 2
wait_on_run synth_1
launch_runs impl_1
wait_on_run impl_1
open_run impl_1
'''
(root / 'build/rebuild.tcl').write_text(header + tail)
PY
fi
docker run --rm --platform linux/amd64 --shm-size=2g \
  --env "MCA_REUSE_PROJECT=$task_reuse" \
  --mount "type=bind,source=$task_fpga_root,target=/work" \
  --mount "type=bind,source=$task_tools_root,target=/tools,readonly" \
  redpitaya-vivado-env:2025.1 bash -lc '
    set -euo pipefail
    settings=$(find /tools -name settings64.sh -path "*/Vivado/*" -print -quit)
    test -n "$settings" || { echo "Vivado settings64.sh absent in /tools" >&2; exit 2; }
    set +u
    source "$settings"
    set -u
    # Keep all udev calls on the system ABI. Host-info collection in Vivado can
    # otherwise crash in realloc() when mixed udev symbols load in a container.
    export LD_PRELOAD=/lib/x86_64-linux-gnu/libudev.so.1
    vivado -version
    git config --global --add safe.directory /work/vendor/redpitaya-fpga
    cd /work/vendor/redpitaya-fpga
    if [[ "$MCA_REUSE_PROJECT" == 1 ]]; then
      cd prj/v0.94
      vivado -nojournal -mode batch -source /work/build/rebuild.tcl
    else
      make -B prj/v0.94/out/red_pitaya.bin PRJ=v0.94 MODEL=Z20_4 FPGA_VERSION=z20_125_4ch
    fi
  '
