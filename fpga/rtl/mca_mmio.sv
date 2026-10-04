// Region 7 of the stock four-ADC v0.94 design: physical base 0x40700000.
// Full-word transactions only. Event head reads do not consume the record.
`timescale 1ns/1ps
module mca_mmio #(
  parameter integer FIFO_LOG2 = 7,
  parameter integer WARMUP = 2048,
  parameter integer EXTERNAL_TIME = 0
) (
  input wire clk, rstn, input wire signed [13:0] adc,
  input wire [63:0] timestamp_ticks,
  input wire [31:0] addr, wdata,
  input wire [3:0] wstrb,
  input wire wen, ren,
  output reg [31:0] rdata, output reg ack, err
);
  localparam integer DEPTH = 1 << FIFO_LOG2;
  reg enable, reset_pulse, manual_baseline;
  reg signed [15:0] baseline_setting;
  reg [15:0] short_gate, long_gate, threshold_floor;
  reg [7:0] fraction;
  wire busy, ready, event_valid;
  wire [255:0] event_data;
  wire signed [15:0] baseline;
  wire [15:0] noise_abs, threshold;
  wire [63:0] ticks, enabled_ticks, live_ticks;
  wire [31:0] triggers;
  mca_core #(.WARMUP(WARMUP), .EXTERNAL_TIME(EXTERNAL_TIME)) core (
    .clk(clk), .rstn(rstn && !reset_pulse), .enable(enable), .adc(adc), .timestamp_ticks(timestamp_ticks),
    .short_gate(short_gate), .long_gate(long_gate), .threshold_floor(threshold_floor),
    .fraction(fraction), .manual_baseline(manual_baseline), .baseline_setting(baseline_setting),
    .busy(busy), .ready(ready), .baseline(baseline), .noise_abs(noise_abs), .threshold(threshold),
    .ticks(ticks), .enabled_ticks(enabled_ticks), .live_ticks(live_ticks), .triggers(triggers),
    .event_valid(event_valid), .event_data(event_data)
  );
  (* ram_style = "block" *) reg [255:0] fifo [0:DEPTH-1];
  reg [FIFO_LOG2-1:0] wrptr, rdptr;
  reg [FIFO_LOG2:0] count;
  reg [255:0] head;
  reg head_valid, seen;
  reg [31:0] dropped, stored;
  reg [63:0] snap_ticks, snap_enabled, snap_live;
  reg [31:0] snap_triggers, snap_dropped, snap_stored;
  wire request = (wen || ren) && !seen;
  wire pop = request && wen && !ren && addr[19:0] == 20'h0020 &&
             wstrb == 4'hf && wdata[0] && head_valid;
  wire push = event_valid && (count < DEPTH || pop);
  wire config_ok = short_gate > 64 && short_gate <= long_gate &&
                  long_gate >= 672 && long_gate <= 16384 &&
                  threshold_floor > 0 && threshold_floor <= 4095 && fraction != 0 &&
                  (!manual_baseline || (baseline_setting >= -8192 && baseline_setting <= 8191));

  always @(posedge clk) begin
    if (!rstn || reset_pulse) begin
      wrptr <= 0; rdptr <= 0; count <= 0;
      head <= 0; head_valid <= 0; dropped <= 0; stored <= 0;
      snap_ticks <= 0; snap_enabled <= 0; snap_live <= 0;
      snap_triggers <= 0; snap_dropped <= 0; snap_stored <= 0;
    end else begin
      // Synchronous read permits BRAM inference; invalidate for one cycle on pop.
      head <= fifo[rdptr];
      head_valid <= count != 0 && !pop;
      if (push) begin
        fifo[wrptr] <= event_data; wrptr <= wrptr + 1; stored <= stored + 1;
      end else if (event_valid) dropped <= dropped + 1;
      if (pop) rdptr <= rdptr + 1;
      case ({push,pop})
        2'b10: count <= count + 1;
        2'b01: count <= count - 1;
        default: count <= count;
      endcase
      if (request && wen && !ren && addr[19:0] == 20'h0040 && wstrb == 4'hf) begin
        snap_ticks <= EXTERNAL_TIME ? timestamp_ticks : ticks; snap_enabled <= enabled_ticks; snap_live <= live_ticks;
        snap_triggers <= triggers; snap_dropped <= dropped; snap_stored <= stored;
      end
    end
  end

  always @(posedge clk) begin
    if (!rstn) begin
      enable <= 0; reset_pulse <= 0; manual_baseline <= 0; baseline_setting <= 0;
      short_gate <= 250; long_gate <= 6250; threshold_floor <= 164; fraction <= 77;
      seen <= 0; ack <= 0; err <= 0; rdata <= 0;
    end else begin
      ack <= 0; err <= 0; reset_pulse <= 0;
      if (!wen && !ren) seen <= 0;
      if (request) begin
        seen <= 1; ack <= 1; rdata <= 0;
        if ((wen && ren) || addr[1:0] != 0 || (wen && wstrb != 4'hf)) err <= 1;
        else if (ren) begin
          case (addr[19:0])
            20'h0000: rdata <= 32'h4d434131; // "MCA1"
            20'h0004: rdata <= 32'h00010000; // ABI 1.0
            20'h0008: rdata <= {31'b0,enable};
            20'h000c: rdata <= {27'b0,config_ok,busy,ready,head_valid,enable};
            20'h0010: rdata <= short_gate;
            20'h0014: rdata <= long_gate;
            20'h0018: rdata <= threshold_floor;
            20'h001c: rdata <= fraction;
            20'h0020: rdata <= count;
            20'h0024: rdata <= {threshold,noise_abs};
            20'h0028: rdata <= {{16{baseline[15]}},baseline};
            20'h002c: rdata <= {15'b0,manual_baseline,baseline_setting};
            20'h0030: rdata <= 125000000;
            20'h0034: rdata <= DEPTH;
            20'h0044: rdata <= snap_ticks[31:0];
            20'h0048: rdata <= snap_ticks[63:32];
            20'h004c: rdata <= snap_enabled[31:0];
            20'h0050: rdata <= snap_enabled[63:32];
            20'h0054: rdata <= snap_live[31:0];
            20'h0058: rdata <= snap_live[63:32];
            20'h005c: rdata <= snap_triggers;
            20'h0060: rdata <= snap_dropped;
            20'h0064: rdata <= snap_stored;
            default: begin
              if (addr[19:5] == 15'h0008 && head_valid) // 0x100..0x11c
                rdata <= head[addr[4:2]*32 +: 32];
              else err <= 1;
            end
          endcase
        end else if (wen) begin
          case (addr[19:0])
            20'h0008: begin
              if (wdata[1]) begin enable <= 0; reset_pulse <= 1; end
              else if (wdata[0] && !config_ok) err <= 1;
              else enable <= wdata[0];
            end
            20'h0010: if (!enable) short_gate <= wdata[15:0]; else err <= 1;
            20'h0014: if (!enable) long_gate <= wdata[15:0]; else err <= 1;
            20'h0018: if (!enable) threshold_floor <= wdata[15:0]; else err <= 1;
            20'h001c: if (!enable) fraction <= wdata[7:0]; else err <= 1;
            20'h0020: if (wdata[0] && !head_valid) err <= 1;
            20'h002c: if (!enable) begin
              manual_baseline <= wdata[16]; baseline_setting <= wdata[15:0];
            end else err <= 1;
            20'h0040: begin end // snapshot handled above
            default: err <= 1;
          endcase
        end
      end
    end
  end
endmodule
