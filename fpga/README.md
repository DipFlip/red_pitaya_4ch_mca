# Four-channel FPGA MCA — hardware prototype

Hardware target: **STEMlab 125-14 4-Input V1R3**, Zynq **xc7z020clg400-1**.
This directory contains custom RTL, a four-input vendor integration, Docker build
environment, and list-mode reader. **The custom image has been built, checked and
tested on the board.** Vivado 2025.1 ran in the AMD64 Docker container on an Apple Silicon Mac.
The current four-channel 125 MHz implementation passes setup (0.049 ns margin) and hold (0.051 ns)
checks; bitstream-generation DRC passed with zero errors. The stock ADC front-end
constraints omit external input delays, so this is a prototype hardware check,
not ADC timing characterization or a complete production signoff.

Current four-channel hardware check: all four inputs enabled for 15 seconds,
18 IN1 candidates (17 accepted), zero FIFO drops on all channels. Other inputs
were quiet; their live counters and baseline/noise readings worked. A selective
IN1/IN3 run stopped cleanly and restored the stock scope. Four concurrent pulses
were verified in simulation; hardware pulses on IN2–IN4 and split-pulse timing
calibration remain to be measured. The Radxa reader now defaults to IN1 only.

## Implemented processing

Each active input has an independent 125 MHz baseline/noise tracker, pulse processor and 128-event FIFO. IN1–IN2 stay in ADC01’s clock domain, IN3–IN4 in ADC23’s domain; raw samples never cross domains. A free-running primary-clock Gray counter supplies a shared timestamp reference, with two-stage synchronization and local decode for ADC23. IN1–IN2 have a nominally matching reference delay. Inter-channel offsets, cross-pair sample phase and jitter remain unmeasured. Resetting a channel clears its processor/FIFO/counters but does not reset the common clock. Every pulse retains its own CFD time; there is no forced trigger or timestamp sharing. Coincidence matching is deferred to the receiver.
The baseline is an exponential moving average with a 1024-sample time constant;
it freezes outside a quiet band and during an event.
If no quiet band is found for 1 ms while idle, automatic mode reacquires the
baseline and warms up again; this avoids remaining blind after reset during a
flat pulse or a DC-offset step. The recovery does not run in fixed-baseline mode.
The detector requires eight consecutive samples above
`max(threshold_floor, 8 × mean_absolute_noise)`.
The default floor is 164 ADC counts, nominally 20 mV on the LV range. This noise
estimate is mean absolute residual, not a measured Gaussian standard deviation.
Threshold and quiet-band limits are registered, following this slow noise estimate
with one ADC-clock cycle of latency.

Two **signed**, baseline-subtracted sums are recorded for every candidate:

- Short: 250 samples, **2 µs**.
- Long: 3125 samples, **25 µs** with the current reader default.
- Both start **64 samples (512 ns) before the qualified threshold trigger**.
  The gate lengths include this prehistory. They are configurable while disabled.
  Gates are anchored to the threshold trigger, so their endpoints can move with
  amplitude even when the constant-fraction timestamp is stable.
  The first hardware trial used 50 µs. The bitstream's reset value remains 50 µs;
  the reader sets 25 µs before enabling acquisition, without an FPGA rebuild.

The early peak is measured over the first 256 samples after the trigger. The
processor searches backward from that peak to its nearest upward crossing of
`77/256` of the peak (about 30%). Prehistory permits a crossing earlier than the
threshold trigger. Raw samples are captured in a circular block RAM, with
synchronous reads and a pipeline for the backward search. The crossing decision
and timestamp addition run in separate cycles. A serial divider interpolates;
the timestamp has a 64-bit 8 ns tick counter and a 16-bit fractional tick.
This is a retrospective **early-peak constant-fraction pickoff**, rather than
the delayed bipolar-signal implementation sometimes also called digital CFD.
It can reduce amplitude-dependent time walk when pulse shapes are consistent.
Fractional representation does **not** establish sub-nanosecond hardware accuracy.
ADC noise, shape changes, analog bandwidth, clock jitter and calibration remain.

Each 32-byte event contains timestamp, short/long integral, peak, baseline,
sequence, gate lengths and flags. The FIFO holds 128 records. It preserves the
oldest records, increments an overflow counter when full, and requires an
explicit pop after reading the whole head record. ARM readout runs independently
of integration. Snapshot registers provide coherent 64-bit clock/live counters.

Flags: bit 0 near full scale; bit 1 possible pile-up; bit 2 invalid CFD (trigger
time retained); bit 3 final sample still above threshold; bit 4 peak still rising
at the end of the early-peak window. Pile-up and tail flags are heuristics.

**One event per channel can be in flight at a time.** Pulses overlapping the long gate are
not separate list-mode entries; some cause a pile-up flag. After a gate, the
processor waits for 125 quiet samples before rearming. Live ticks exclude busy
time, warmup and rearming. They do not count missed detector pulses or by
themselves establish a dead-time-corrected source rate. Configuration changes
are rejected while enabled. Disabling aborts an unfinished gate; FIFO records
already completed remain readable. Reset clears processing, FIFO and counters.

## Tests performed

Run from the project root:

```sh
PYTHON=python3 bash fpga/sim/run.sh
```

Or run the same HDL and reference calculations in the x86-64 Docker container:

```sh
docker build --platform linux/amd64 -t redpitaya-vivado-env:2025.1 fpga/docker
docker run --rm --platform linux/amd64 \
  --mount "type=bind,source=$PWD,target=/work" \
  redpitaya-vivado-env:2025.1 bash fpga/sim/run.sh
```

Tests calculate expected integrals independently from the exact input samples;
exercise five amplitudes, equal gates, signed baseline/noise, clipping, pile-up
and a peak window too short; exercise a deep pretrigger fraction crossing at
the minimum long gate and a missing crossing; optionally replay external saved detector waveforms; check FIFO
ordering, overflow accounting, held bus strobes, immutable head reads, reset and
invalid configuration. Optional 25 µs captures are padded with their baseline for
the remainder of the 50 µs test gate; this cannot validate an unrecorded tail.
The report is `build/sim/report.json`. Simulation tests are not a hardware test.

## Vivado build

The official vendor checkout is pinned to
`728a4f37e9c0a9b5ba1d9b7a0d44c38bbd2dc674`; its recommended tool is Vivado 2025.1.
Fetch the pinned checkout before building:

```sh
git clone https://github.com/RedPitaya/RedPitaya-FPGA.git fpga/vendor/redpitaya-fpga
git -C fpga/vendor/redpitaya-fpga checkout --detach 728a4f37e9c0a9b5ba1d9b7a0d44c38bbd2dc674
```

`prepare_vendor.py` adds the core, MMIO, four-channel wrapper and held-payload CDC mailbox, connects all four raw signed sample inputs in **red_pitaya_top_4ADC.sv**, and makes this a dedicated MCA personality.
The vendor ARM/ADC bus crossing, ADC setup, housekeeping and PS are retained.
Scope and daisy peripherals are stubbed, their IRQ/AXI outputs are idle, and
synchronized scope writes are disabled. This avoids carrying the stock scope
pair’s independent-clock bus/state/AXI paths into MCA timing signoff.
To use the oscilloscope, reload the original stock image; its SD files are untouched.
Preparation writes `build/source_manifest.json` with source SHA-256 values.
The Tcl patch runs post-route physical optimization when needed, refuses to
emit a bitstream with failing setup/hold timing or DRC errors, and saves the
final checkpoint, timing and utilization reports. The first successful build
completed bitstream/BIN generation, then crashed during optional XSA export.
Future builds omit this export because the board uses its existing Linux/DT.

Docker runs the installed Vivado 2025.1 under `linux/amd64` emulation on this
Apple Silicon Mac. The selective Standard/Zynq-7000 installation completed.
The launcher preloads the Ubuntu system `libudev.so.1` to avoid a mixed-ABI
crash during Vivado host enumeration. AMD does not list this Mac/Docker
combination as a supported platform.
Use the **2025.1 Linux Self Extracting Web Installer (335.53 MB)** from
[AMD](https://www.amd.com/en/support/downloads/adaptive-socs-and-fpgas/development-tools/2025-1.html).
Select Vivado Standard with **Zynq-7000** device support, minimizing unrelated
families/components. The full unified archive is about 110 GB; do not download
that archive onto the Mac's limited free space. Lab Edition cannot synthesize.
The selective installer reports its actual download/install size. Prefer an
external SSD with ample space for installer cache, tool and implementation runs.

AMD login, installer selection and license acceptance must be completed before
the build. Keep credentials out of the project and container image. Mount the
installed tool directory at `/tools` and run:

```sh
bash fpga/docker/run_build.sh /path/to/installed-AMD-tools
# For RTL-only changes after a full build, preserve completed support IP:
bash fpga/docker/run_build.sh /path/to/installed-AMD-tools --reuse-project
```

It requests only the vendor `.bin` target with `MODEL=Z20_4`; it does not require
building a new Linux image or bootloader. Expected output:
`vendor/redpitaya-fpga/prj/v0.94/out/red_pitaya.bin` and implementation reports.
Loading still requires review of timing, DRC, unconstrained paths, utilization,
exact part and the four-channel device-tree/overlay compatibility. The script
does not deploy. Preserve the stock image and use a volatile load for the first
hardware test. A normal Linux FPGA-manager load does not need a JTAG cable.

## Readout after successful build and volatile load

`readout.py` uses `/dev/mem` at **0x40700000**. It should only run after this
custom image is loaded; accessing that address with an incompatible image can
raise a bus error. It requires root, explicit confirmation and matching MCA4 ID
and ABI. It does not load a bitstream, start services or alter boot settings.

```sh
python3 /root/mca-fpga/readout.py --custom-bitstream-loaded \
  --channels 1,2,3,4 --seconds 30 --short-us 2 --long-us 25 --fraction .30 \
  --threshold-v .020 --format binary --output /root/mca-fpga/run.mca
```

The output preserves candidate events including flagged ones, plus run metadata
and a final statistics snapshot. Nominal LV conversion is `counts/8192` volts;
integrals multiply by `0.008 µs/sample`. Factory ADC calibration and detector
energy/charge calibration are **not applied**. Timestamps are relative to the
FPGA reset, not Unix time. The reader was tested in the first hardware run.
Receiver tools are in `../redpitaya`; the optional Airy-SLAM integration is in `../integrations/airy_slam`. The starter’s `--channels 1,2,3,4` argument selects active inputs; the default is IN1 only.

### Compact transport

The reader defaults to a binary stream over the existing SSH/TCP connection.
There are **two integrals per event**. The eight
32-bit FPGA words also hold timestamp, fraction, flags, peak, baseline, sequence
and gate lengths. A ninth unsigned word adds the physical channel number 1..4, forming 36-byte little-endian records;
volts, nanoseconds, ratios and text descriptions are calculated on the receiver.
At 3,000 events/s per detector and four detectors the raw event payload is
432,000 bytes/s, plus framing/status/SSH overhead. Sustained few-kHz hardware
readout remains to be measured; the deterministic reader test exercises four
simulated FIFOs at 5,000 events/s each (20,000 total).

Each FPGA FIFO is drained every approximately 1 ms into ARM memory. Events are
sent in nominal 100-ms batches (`--batch-ms 100`), with a statistics snapshot
on that cadence even when there are no events. Scheduling/network delays can
extend delivery; this is not a hard real-time guarantee. A 4096-event buffer
limit also forces an early flush. A stalled receiver can eventually block ARM
readout and cause counted FIFO drops. Do not change FIFO polling to 100 ms:
the hardware queue holds only 128 events. Acquisition dead time and missed
overlapping pulses are independent of transport and its drop counter.

`wire.py` writes stream version 2: eight-byte magic `RPMCA\x00\x02\n`, followed by
frames with a four-byte tag and unsigned little-endian 32-bit payload length.
`META` carries UTF-8 JSON run metadata, `EVN4` one or more raw 36-byte channel-tagged events,
`STAT` UTF-8 JSON counters, and `DONE` the final JSON summary. The decoder rejects
unknown versions, malformed frames, truncated runs and mismatched event counts.
Flagged candidates and exact integer/fractional timestamps are preserved. The decoder also supports legacy version-1 captures with `EVNT` 32-byte records.
`--format jsonl` remains available for debugging and also flushes periodically.
For a JSONL file, pass `--format jsonl --output /root/mca-fpga/run.jsonl`.

After capturing a complete run, export every event to list-mode CSV and a
512-bin histogram of accepted long-gate integrals:

```sh
python3 fpga/export_run.py first-run.jsonl results/first-fpga-run
```

Flagged events remain in the CSV; histogram underflow and overflow are counted.
The output directory must be new. The board load/restore helpers are in
`../redpitaya/board/`; they were exercised in the first hardware trial. The loader verifies the board
profile and upload checksum, preserves stock files, and restores the stock image
if custom configuration or ID verification fails. The first implementation and stock device-tree compatibility were reviewed;
`../redpitaya/bitstream/implementation_review.json` records the checks and remaining vendor limitations.

## Registers (32-bit aligned full-word access)

Global base `0x40700000`: offset 0 is `MCA4` (`0x4d434134`), offset 4 is
ABI 2.0 (`0x00020000`), offset 8 is channel capacity 4, offset 0x30 is clock Hz,
write offset 0x40 snapshots the common clock, and read 0x44/0x48 returns low/high.
Channel bases are global base + `channel * 0x1000`, for physical channels 1..4.
The following table is relative to each channel base. Only selected channels
are enabled by the reader. The common clock runs from FPGA load, while channel
counters reset per acquisition; metadata records the initial clock snapshots.

| Offset | Access | Meaning |
|---|---|---|
| 0x00 | R | ID 0x4d434131 (`MCA1`) |
| 0x04 | R | ABI 0x00010000 |
| 0x08 | RW | bit 0 enable; write bit 1 to reset and disable |
| 0x0c | R | bits 0 enabled, 1 head valid, 2 ready, 3 busy, 4 config valid |
| 0x10, 0x14 | RW disabled | short/long gate samples |
| 0x18, 0x1c | RW disabled | threshold floor counts, fraction/256 |
| 0x20 | R/W | FIFO occupancy; write 1 to pop one record |
| 0x24 | R | threshold high 16 bits, mean absolute noise low 16 bits |
| 0x28 | R | signed current baseline |
| 0x2c | RW disabled | bit 16 fixed-baseline mode; signed low 16 baseline |
| 0x30, 0x34 | R | clock Hz, FIFO depth |
| 0x40 | W | latch all statistics |
| 0x44/48, 0x4c/50, 0x54/58 | R | latched clock/enabled/live ticks, low/high |
| 0x5c, 0x60, 0x64 | R | latched trigger/drop/stored counts |
| 0x100–0x11c | R | eight words of current head; no implicit pop |

Event words: timestamp low, timestamp high, flags-high/fraction-low, signed
short sum, signed long sum, peak-high/signed-baseline-low, sequence, long-gate-high/
short-gate-low. Gate range: `64 < short <= long <= 16384` and `long >= 672`.

References: [official FPGA sources](https://github.com/RedPitaya/RedPitaya-FPGA),
[four-input target](https://redpitaya.readthedocs.io/en/latest/developerGuide/fpga/projects/top.html),
[vendor baseline project](https://redpitaya.readthedocs.io/en/latest/developerGuide/fpga/projects/v0_94.html),
[FPGA loading](https://redpitaya.readthedocs.io/en/latest/developerGuide/fpga/getting_started/reprogram_fpga.html).
