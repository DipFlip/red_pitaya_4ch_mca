#!/usr/bin/env python3
"""Apply a small reproducible integration patch to the pinned official checkout."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
(ROOT / "build").mkdir(parents=True, exist_ok=True)
VENDOR = ROOT / "vendor/redpitaya-fpga"
REV = "728a4f37e9c0a9b5ba1d9b7a0d44c38bbd2dc674"
actual = subprocess.check_output(["git", "-C", str(VENDOR), "rev-parse", "HEAD"], text=True).strip()
if actual != REV:
    raise SystemExit(f"Expected vendor {REV}, found {actual}; integration needs review")
rel = "prj/v0.94/rtl/red_pitaya_top_4ADC.sv"
original = subprocess.check_output(["git", "-C", str(VENDOR), "show", f"HEAD:{rel}"], text=True)
old = "for (genvar i=6; i<8; i++) begin: for_sys"
assert original.count(old) == 1
patched = original.replace(old, "for (genvar i=6; i<7; i++) begin: for_sys")
# This image is a four-channel MCA personality. Keep board setup, ADC capture, PS and
# housekeeping; load the untouched stock image to use the oscilloscope again.
# The stock second scope pair has bus/state/AXI paths crossing independent ADC
# PLL domains. Do not carry those unrelated crossings into the MCA signoff.
for n in range(1, 7):
    patched = patched.replace(f".SYNC_OUT_BUS{n} (2)", f".SYNC_OUT_BUS{n} (-1)")
scope_start = patched.index("// oscilloscope CH0 and CH1")
patched = patched[:scope_start] + """
// Unused scope and daisy peripherals acknowledge via the standard bus stub.
sys_bus_stub mca_stub_scope01 (sys[1]);
sys_bus_stub mca_stub_scope23 (sys[2]);
sys_bus_stub mca_stub_daisy   (sys[5]);
assign scope_irq_0_1 = 1'b0;
assign scope_irq_2_3 = 1'b0;
assign scope_irq_ch_0_1 = 2'b0;
assign scope_irq_ch_2_3 = 2'b0;
assign scope_trigo = 1'b0;
assign trig_asg_out = 1'b0;
assign par_dat = 16'b0;
for (genvar d=0; d<2; d++) begin: mca_idle_daisy
  OBUFDS idle_output (.I(1'b0), .O(daisy_p_o[d]), .OB(daisy_n_o[d]));
end
"""
for n in range(4):
    for signal in ("waddr", "wdata", "wsel", "wvalid", "wlen", "wfixed"):
        patched += f"assign axi{n}_sys.{signal} = '0;\n"
patched += "endmodule\n"
instance = """
// Four independent MCA channels in their native ADC domains.
mca_four four_mca (
 .clk01(adc_clk_01), .clk23(adc_clk_23), .rstn01(adc_rstn_01), .rstn23(adc_rstn_23),
 .adc0(adc_dat[0]), .adc1(adc_dat[1]), .adc2(adc_dat[2]), .adc3(adc_dat[3]),
 .addr(sys[7].addr), .wdata(sys[7].wdata), .wen(sys[7].wen), .ren(sys[7].ren),
 .rdata(sys[7].rdata), .ack(sys[7].ack), .err(sys[7].err)
);

"""
pos = patched.rfind("endmodule")
assert pos > 0
patched = patched[:pos] + instance + patched[pos:]
(VENDOR / rel).write_text(patched)
for source in (ROOT / "rtl").glob("*.sv"):
    shutil.copy2(source, VENDOR / "prj/v0.94/rtl" / source.name)

# Fail before producing an installable image if implementation violates timing.
tcl_rel = "red_pitaya_vivado_Z20_4.tcl"
tcl = subprocess.check_output(["git", "-C", str(VENDOR), "show", f"HEAD:{tcl_rel}"], text=True)
tcl = tcl.replace("add_files  -fileset sources_1 -norecurse $path_rtl_prj", "add_files -fileset constrs_1 rtl/mca_cdc.xdc\nadd_files  -fileset sources_1 -norecurse $path_rtl_prj")
shutil.copy2(ROOT / "rtl/mca_cdc.xdc", VENDOR / "prj/v0.94/rtl/mca_cdc.xdc")
tcl = tcl.replace("write_cfgmem -format", "write_cfgmem -force -format")
tcl = tcl.replace("launch_runs synth_1\n", "launch_runs synth_1 -jobs 2\n")
signoff = """
set worst_setup [get_timing_paths -delay_type max -max_paths 1]
if {[llength $worst_setup] && [get_property SLACK [lindex $worst_setup 0]] < 0} {
  phys_opt_design -directive AggressiveExplore
}
report_timing_summary -delay_type min_max -check_timing_verbose -file $path_out/mca_timing.rpt
report_timing -delay_type max -max_paths 20 -file $path_out/mca_worst_setup.rpt
report_utilization -hierarchical -file $path_out/mca_utilization.rpt
delete_waivers [get_waivers]
report_cdc -details -file $path_out/mca_cdc.rpt
report_bus_skew -file $path_out/mca_bus_skew.rpt
report_drc -file $path_out/mca_drc.rpt
report_drc -checks [get_drc_checks IOSTDTYPE-1] -file $path_out/mca_io_drc.rpt
foreach kind {max min} {
  set paths [get_timing_paths -delay_type $kind -max_paths 1]
  if {[llength $paths] == 0} {error "No $kind timing path; refusing bitstream"}
  if {[get_property SLACK [lindex $paths 0]] < 0} {error "MCA $kind timing failed; refusing bitstream"}
}
if {[llength [get_drc_violations -filter {SEVERITY == Error}]] != 0} {
  error "DRC errors; refusing bitstream"
}
write_checkpoint -force $path_out/mca_signed_off.dcp
"""
assert tcl.count("open_run impl_1\n") == 1
tcl = tcl.replace("open_run impl_1\n", "open_run impl_1\n" + signoff)
# This target only needs a PL image and uses the board existing Linux/DT.
# Avoid the optional platform export (which crashes under Mac emulation).
tcl = tcl[:tcl.index("# generate system definition")] + "exit\n"
(VENDOR / tcl_rel).write_text(tcl)
manifest = {"vendor_url": "https://github.com/RedPitaya/RedPitaya-FPGA", "vendor_commit": REV,
            "model": "Z20_4", "part": "xc7z020clg400-1", "vivado": "2025.1",
            "personality": "four-channel MCA; stock oscilloscope reloaded separately",
            "integration_sha256": {name: hashlib.sha256((VENDOR / name).read_bytes()).hexdigest()
                     for name in (rel, tcl_rel)},
            "constraints_sha256": {"mca_cdc.xdc": hashlib.sha256((ROOT / "rtl/mca_cdc.xdc").read_bytes()).hexdigest()},
            "register_base": "0x40700000", "rtl_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in sorted((ROOT / "rtl").glob("*.sv"))}}
(ROOT / "build/source_manifest.json").write_text(json.dumps(manifest, indent=2)+"\n")
print("Prepared four-input board setup + four-channel MCA; stock board files are untouched")
