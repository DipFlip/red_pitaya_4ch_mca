`timescale 1ns/1ps
module core_tb;
  wire [63:0] timestamp_ticks = 0;
  reg clk=0; always #4 clk=~clk;
  reg rstn=0, enable=0;
  reg signed [13:0] adc=0;
  reg [15:0] short_gate=250, long_gate=6250, threshold_floor=164;
  reg [7:0] fraction=77;
  reg manual_baseline=1;
  reg signed [15:0] baseline_setting=0;
  wire busy, ready, event_valid;
  wire signed [15:0] baseline;
  wire [15:0] noise_abs, threshold;
  wire [63:0] ticks, enabled_ticks, live_ticks;
  wire [31:0] triggers;
  wire [255:0] event_data;
  mca_core #(.WARMUP(256)) dut (.*);
  reg signed [13:0] samples[0:199999];
  reg [1023:0] input_path, output_path;
  integer n, i, out, ignored, trigger_index;
  reg old_busy;
  initial begin
    ignored=$value$plusargs("INPUT=%s",input_path);
    ignored=$value$plusargs("OUTPUT=%s",output_path);
    ignored=$value$plusargs("N=%d",n);
    ignored=$value$plusargs("BASE=%d",baseline_setting);
    ignored=$value$plusargs("SHORT=%d",short_gate);
    ignored=$value$plusargs("LONG=%d",long_gate);
    ignored=$value$plusargs("AUTO=%d",ignored);
    if ($test$plusargs("AUTO")) manual_baseline=0;
    $readmemh(input_path,samples,0,n-1);
    out=$fopen(output_path,"w");
    $fdisplay(out,"trigger,tick,fraction,flags,short,long,baseline,peak,sequence");
    repeat(4) @(negedge clk);
    rstn=1; enable=1; old_busy=0; trigger_index=0;
    for(i=0;i<n;i=i+1) begin
      adc=samples[i];
      @(posedge clk); #1;
      if (busy && !old_busy) trigger_index=i;
      old_busy=busy;
      if(event_valid) $fdisplay(out,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
        trigger_index,event_data[63:0],event_data[79:64],event_data[95:80],
        $signed(event_data[127:96]),$signed(event_data[159:128]),
        $signed(event_data[175:160]),event_data[191:176],event_data[223:192]);
      @(negedge clk);
    end
    $fclose(out);
    $display("samples=%0d triggers=%0d live_ticks=%0d",n,triggers,live_ticks);
    $finish;
  end
endmodule
