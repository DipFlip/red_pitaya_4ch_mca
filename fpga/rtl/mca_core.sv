// Independent pulse processor. All inputs, control and outputs use the ADC clock.
// Gates include PRE samples before the qualified trigger. Positive pulses only.
`timescale 1ns/1ps
module mca_core #(
  parameter integer PRE = 64,
  parameter integer RISE = 256,
  parameter integer WARMUP = 2048,
  parameter integer EXTERNAL_TIME = 0
) (
  input wire clk, input wire rstn, input wire enable,
  input wire signed [13:0] adc,
  input wire [63:0] timestamp_ticks,
  input wire [15:0] short_gate, long_gate, threshold_floor,
  input wire [7:0] fraction, // fraction / 256; 1..255
  input wire manual_baseline,
  input wire signed [15:0] baseline_setting,
  output reg busy, output wire ready,
  output wire signed [15:0] baseline,
  output wire [15:0] noise_abs, threshold,
  output reg [63:0] ticks, enabled_ticks, live_ticks,
  output reg [31:0] triggers,
  output reg event_valid, output reg [255:0] event_data
);
  wire [63:0] event_ticks = EXTERNAL_TIME ? timestamp_ticks : ticks;
  localparam integer NW = PRE + RISE;
  reg signed [27:0] base_q;
  reg signed [27:0] noise_q;
  reg [15:0] warm, quiet;
  reg [16:0] unquiet;
  reg [3:0] qualification;
  reg armed;
  reg signed [13:0] history [0:PRE-1]; // oldest first
  reg signed [31:0] history_sum;
  // Duplicate a circular raw-sample RAM for two synchronous read ports. Capture
  // prehistory in place instead of copying/subtracting 64 samples in parallel.
  (* ram_style = "block" *) reg signed [13:0] wave_a [0:511];
  (* ram_style = "block" *) reg signed [13:0] wave_b [0:511];
  reg [8:0] wave_write, wave_start;
  reg signed [15:0] wave_first;
  reg signed [13:0] read_before, read_after;
  reg signed [15:0] corrected_before, corrected_after;
  reg [9:0] read_index, corrected_index, crossing_index;
  reg read_valid, corrected_valid, scan_finished;
  reg signed [15:0] frozen_base;
  reg signed [31:0] q_short, q_long;
  reg [15:0] age, flags, peak;
  reg [9:0] early_peak_index;
  reg [15:0] valley, recovery;
  reg [63:0] wave_origin, time_tick;
  reg [15:0] time_fraction;
  reg [9:0] scan;
  reg [2:0] timing_state;
  reg [23:0] target;
  reg [15:0] early_height;
  reg [24:0] remainder, denominator;
  reg [15:0] quotient;
  reg [4:0] div_steps;
  reg [31:0] sequence_number;
  reg [15:0] threshold_r, quiet_limit_r;
  reg signed [16:0] quiet_low_r;
  integer j;

  assign baseline = manual_baseline ? baseline_setting : (base_q >>> 12);
  assign noise_abs = noise_q >> 12;
  wire [19:0] noise_threshold = {4'b0, noise_abs} << 3;
  wire [15:0] next_threshold = (noise_threshold > 4095) ? 16'd4095 :
                     (noise_threshold > threshold_floor) ? noise_threshold[15:0] : threshold_floor;
  assign threshold = threshold_r;
  wire signed [16:0] residual = $signed(adc) - $signed(baseline);
  wire [16:0] magnitude = residual < 0 ? -residual : residual;
  wire signed [16:0] sample = $signed(adc) - $signed(frozen_base);
  wire [15:0] next_quiet_limit = (noise_abs * 4 > (threshold_floor >> 2)) ?
                           noise_abs * 4 : (threshold_floor >> 2);
  wire [15:0] quiet_limit = quiet_limit_r;
  wire quiet_sample = residual >= quiet_low_r && residual <= $signed({1'b0,quiet_limit});
  wire configuration_ok = short_gate > PRE && short_gate <= long_gate &&
             long_gate >= 2*NW+32 && long_gate <= 16384 &&
             threshold_floor > 0 && threshold_floor <= 4095 && fraction != 0 &&
             (!manual_baseline || (baseline_setting >= -8192 && baseline_setting <= 8191));
  assign ready = enable && configuration_ok && warm >= WARMUP && armed && !busy;
  wire [8:0] before_address = wave_start + scan - 1;
  wire [8:0] after_address = wave_start + scan;
  wire signed [24:0] scan_before = $signed(corrected_before) * 25'sd256;
  wire signed [24:0] scan_after = $signed(corrected_after) * 25'sd256;
  wire [24:0] shifted_remainder = remainder << 1;
  wire divide_bit = shifted_remainder >= denominator;
  wire [15:0] next_quotient = {quotient[14:0], divide_bit};

  always @(posedge clk) begin
    if (!busy || age < NW) begin
      wave_a[wave_write] <= adc;
      wave_b[wave_write] <= adc;
    end
    read_before <= wave_a[before_address];
    read_after <= wave_b[after_address];
    corrected_before <= $signed(read_before) - $signed(frozen_base);
    corrected_after <= $signed(read_after) - $signed(frozen_base);
    read_index <= scan;
    corrected_index <= read_index;
  end

  always @(posedge clk) begin
    if (!rstn) begin
      base_q <= 0; noise_q <= 0; warm <= 0; quiet <= 0; unquiet <= 0;
      qualification <= 0; armed <= 0; history_sum <= 0;
      ticks <= 0; enabled_ticks <= 0; live_ticks <= 0; triggers <= 0;
      busy <= 0; event_valid <= 0; event_data <= 0;
      frozen_base <= 0; q_short <= 0; q_long <= 0; age <= 0;
      flags <= 0; peak <= 0; early_peak_index <= PRE;
      valley <= 0; recovery <= 0; wave_origin <= 0;
      time_tick <= 0; time_fraction <= 0; timing_state <= 0;
      scan <= 1; target <= 0; remainder <= 0; denominator <= 1;
      early_height <= 0;
      threshold_r <= 164; quiet_limit_r <= 41;
      quiet_low_r <= -17'sd41;
      quotient <= 0; div_steps <= 0; sequence_number <= 0;
      wave_write <= 0; wave_start <= 0; wave_first <= 0;
      read_valid <= 0; corrected_valid <= 0; scan_finished <= 0; crossing_index <= 0;
      for (j=0; j<PRE; j=j+1) history[j] <= 0;
    end else begin
      ticks <= ticks + 1;
      event_valid <= 0;
      // The EMA evolves over 1024 samples; a one-cycle registered noise limit
      // removes max/clamp arithmetic from the qualification fanout path.
      threshold_r <= next_threshold;
      quiet_limit_r <= next_quiet_limit;
      quiet_low_r <= -$signed({1'b0,next_quiet_limit});
      if (!busy || age < NW) wave_write <= wave_write + 1;
      read_valid <= timing_state == 1 && !scan_finished;
      corrected_valid <= read_valid;
      history_sum <= history_sum - $signed(history[0]) + $signed(adc);
      for (j=0; j<PRE-1; j=j+1) history[j] <= history[j+1];
      history[PRE-1] <= adc;
      if (enable) enabled_ticks <= enabled_ticks + 1;
      if (ready) live_ticks <= live_ticks + 1;
      // Seed on the first sample, then use an EMA with a 1024-sample time constant.
      // Freeze the baseline and noise during a pulse and outside the quiet band.
      if (warm == 0) base_q <= $signed(adc) * 28'sd4096;
      else if (!busy && (warm < WARMUP || quiet_sample)) begin
        if (!manual_baseline)
          base_q <= base_q + (($signed(adc)*28'sd4096 - base_q) >>> 10);
        noise_q <= noise_q + (($signed({1'b0,magnitude})*28'sd4096 - $signed(noise_q)) >>> 10);
      end
      if (warm < WARMUP) warm <= warm + 1;
      if (!manual_baseline && !busy && warm >= WARMUP && !quiet_sample) begin
        if (unquiet < 125000) unquiet <= unquiet + 1;
      end else unquiet <= 0;
      if (!busy) begin
        if (quiet_sample) begin
          if (quiet < 125) quiet <= quiet + 1;
        end else if (residual < $signed({1'b0,threshold})) quiet <= 0;
      end else quiet <= 0;

      if (!enable) begin
        busy <= 0; armed <= 0; qualification <= 0; timing_state <= 0;
      end else if (!busy) begin
        if (quiet >= 125 && warm >= WARMUP) armed <= 1;
        if (ready && residual >= $signed({1'b0,threshold})) begin
          if (qualification == 7) begin
            qualification <= 0; busy <= 1; armed <= 0; triggers <= triggers + 1;
            sequence_number <= sequence_number + 1;
            frozen_base <= baseline; age <= PRE+1;
            q_long <= history_sum - $signed(baseline)*PRE + residual;
            q_short <= history_sum - $signed(baseline)*PRE + residual;
            peak <= residual > 0 ? residual : 0;
            flags <= (adc >= 8100 || adc <= -8100) ? 16'h0001 : 0;
            early_peak_index <= PRE; recovery <= 0; valley <= 0;
            wave_origin <= event_ticks - PRE;
            time_tick <= event_ticks; time_fraction <= 0; timing_state <= 0;
            wave_start <= wave_write - PRE;
            wave_first <= $signed(history[0]) - $signed(baseline);
            scan_finished <= 0;
          end else qualification <= qualification + 1;
        end else qualification <= 0;
      end else begin
        q_long <= q_long + sample;
        if (age < short_gate) q_short <= q_short + sample;
        age <= age + 1;
        if (adc >= 8100 || adc <= -8100) flags[0] <= 1;
        // Secondary rises after a sustained decline are possible pile-up only.
        if (sample > $signed({1'b0,peak})) peak <= sample;
        if (age < NW && sample > $signed({1'b0,peak})) early_peak_index <= age;
        if (age > NW && sample < $signed({1'b0,peak >> 1})) begin
          if (recovery < 32) recovery <= recovery + 1;
          if (sample < 0) valley <= 0;
          else if (recovery == 0 || sample < $signed({1'b0,valley})) valley <= sample;
        end
        if (age > NW && recovery >= 32 && sample > $signed({1'b0,valley}) + $signed({1'b0,threshold}))
          flags[1] <= 1;

        // Early-peak constant-fraction pickoff; search includes pre-trigger samples.
        // Retrospective processing recovers a crossing earlier than the trigger.
        if (age == NW-1) begin
          early_height <= sample > $signed({1'b0,peak}) ? sample[15:0] : peak;
          scan <= sample > $signed({1'b0,peak}) ? age : early_peak_index;
          timing_state <= 6;
          if (sample >= $signed({1'b0,peak})) flags[4] <= 1; // peak window too short
        end
        if (timing_state == 6) begin
          target <= early_height * fraction;
          timing_state <= 1;
        end
        if (timing_state == 1) begin
          // Search backward from the early peak for its nearest upward crossing.
          // This avoids picking an unrelated noise crossing at the history start.
          if (!scan_finished) begin
            if (scan == 1) scan_finished <= 1;
            else scan <= scan - 1;
          end
          if ($signed(wave_first)*25'sd256 >= $signed({1'b0,target})) begin
            flags[2] <= 1; timing_state <= 3;
          end else if (corrected_valid && scan_before < $signed({1'b0,target}) && scan_after >= $signed({1'b0,target})) begin
            crossing_index <= corrected_index - 1;
            remainder <= $signed({1'b0,target}) - scan_before;
            denominator <= scan_after - scan_before;
            quotient <= 0; div_steps <= 0; timing_state <= 4;
            // Exact upper endpoint is representable as the next integral tick.
            if (scan_after == $signed({1'b0,target})) begin
              crossing_index <= corrected_index; time_fraction <= 0; timing_state <= 5;
            end
          end else if (corrected_valid && corrected_index == 1) begin
            flags[2] <= 1; timing_state <= 3; // missing crossing; retain trigger time
          end
        end else if (timing_state == 4 || timing_state == 5) begin
          // Timestamp addition has its own cycle after the crossing decision.
          time_tick <= wave_origin + crossing_index;
          timing_state <= timing_state == 4 ? 2 : 3;
        end else if (timing_state == 2) begin
          remainder <= divide_bit ? shifted_remainder - denominator : shifted_remainder;
          quotient <= next_quotient;
          if (div_steps == 15) begin
            time_fraction <= next_quotient; timing_state <= 3;
          end else div_steps <= div_steps + 1;
        end
        if (age == long_gate-1) begin
          busy <= 0; qualification <= 0; quiet <= 0;
          // Last sample flag is heuristic; does not certify a clean tail.
          event_data <= {long_gate, short_gate, sequence_number,
                         (sample > $signed({1'b0,peak}) ? sample[15:0] : peak),
                         frozen_base, q_long + sample, q_short,
                         (flags | ((sample > $signed({1'b0,threshold})) ? 16'h0008 : 16'h0000) |
                           ((timing_state != 3) ? 16'h0004 : 16'h0000) |
                           ((adc >= 8100 || adc <= -8100) ? 16'h0001 : 16'h0000)),
                         time_fraction, time_tick};
          // When gates coincide, include the final sample in both.
          if (short_gate == long_gate) event_data[127:96] <= q_short + sample;
          event_valid <= 1; timing_state <= 0;
        end
      end
      // Recover a stale baseline after 1 ms without a quiet band. This handles
      // enabling/resetting during a flat pulse or a sudden DC-offset change.
      // Treat the recovery as a new warmup; it is excluded from live time.
      if (!manual_baseline && !busy && unquiet == 125000 && qualification == 0) begin
        base_q <= $signed(adc) * 28'sd4096; noise_q <= 0;
        warm <= 0; quiet <= 0; unquiet <= 0; armed <= 0; qualification <= 0;
      end
    end
  end
endmodule
