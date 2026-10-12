# Receiver and binary interfaces

## Standalone live dashboard

`bash scripts/start_redpitaya.sh --channels 1,2` starts the Docker receiver and
its bundled dashboard at **http://localhost:8080**. No Airy-SLAM checkout is
needed. The page overlays per-channel long-gate integral histograms, plots
accepted count rate over the last two minutes, reports flagged events and FIFO
drops, and exports histogram bins as CSV. Underflow and overflow are counted
separately. The spectrum uses 256 bins from 0 to 25 nominal V·µs; it is not an
energy calibration. Rates divide accepted counts by each batch's elapsed FPGA
time, without dead-time correction. Each new receiver process starts new plots.

`REDPITAYA_UI_PORT` defaults to `8080` in Compose. Set it to `0` to disable the
UI, or another port if 8080 is occupied. `REDPITAYA_UI_BIND` defaults to
`127.0.0.1`; use `0.0.0.0` for trusted LAN access (the UI has no authentication).
Direct ROS execution/replay can enable it with `--ui-port 8080`. The default for
direct execution is disabled, so the optional Airy UI can keep its own port.
On Docker Desktop for Mac, enable host networking as described in the root README.

The HTTP thread reads bounded in-memory statistics; it does not open another
board connection or acquire the MCA ownership lock. ROS topics and optional raw
recording continue through the same receiver. The page marks stale or lost
connections, and exits with the receiver when acquisition stops.

## Timing and coincidence preparation

IN1–IN2 run in ADC01's clock domain; IN3–IN4 run in ADC23's. Raw samples remain
in their native domains. A registered 64-bit primary-clock Gray counter is
transferred through two synchronizer stages and local decode to ADC23; ADC01's
reference has a nominally matching delay. Both pairs receive a common time
reference, rather than independently reset clocks. A channel reset does not
reset this clock. The FPGA image uses 125 MHz sampling (**8 ns/sample**) and
CFD interpolation to a 16-bit fractional tick. Fractional *representation* is
not a measurement of timing resolution.

Channel offsets, inter-pair sample phase, analog/detector delays and jitter are
unmeasured. Before interpreting a narrow coincidence window, split a suitable
pulse into channel pairs and characterize the relative-time distribution over
amplitude, rate and FPGA reloads. A later receiver can choose 3 µs or smaller
windows without changing this FPGA, provided measured timing supports it.
Compton reconstruction also needs detector energy calibrations and geometry.

The Radxa wall-time origin is anchored at the first status arrival, retaining
an unmeasured network offset and oscillator drift relative to SLAM. This does
not replace clock synchronization. For board-to-board coincidences additional
synchronization would be required; within this board use the shared integer
FPGA timestamps, not packet-arrival times or rounded Unix floating-point times.

## Topics, exposure and saved records

- `/redpitaya/events`: all candidates, including flags and physical channel IDs.
- `/redpitaya/chN/events`: each active channel's raw event batches.
- `/redpitaya/counts` and `/redpitaya/chN/counts`: accepted count **in that batch**,
  not cumulative totals or counts/s. Empty batches still arrive near 10 Hz.
- `/redpitaya/status`: active list, per-channel baseline/noise/threshold,
  trigger/drop/read counters and live ticks; accepted/rejected totals and sequence
  gaps. Native counter snapshots are retained.

Airy combines accepted counts for gross mapping. Its aggregate exposure uses
mean active-channel live fraction projected onto the shared batch interval;
this keeps combined rates comparable to the sum of detector rates. Exact
per-channel counters/exposures are available separately. The ADC23 reference
boundary can differ by a few native cycles; projected exposure is bounded to
its timestamp span with an eight-tick validation tolerance. Live ticks exclude
busy, warmup and rearming but do not count missed incident pulses. No detector
energy calibration is supplied, so energies remain NaN and the keV spectrum is
empty. Sigma50's CsI/channel calibration is not applied to MCA integrals.

The optional Airy-SLAM integration’s raw/slam recording modes include the main event/status/count topics in ROS bags,
preserving every candidate and integer timestamps. Reduced `measurement.npz`
now also saves accepted `mca_words` as an **N×9 uint32** array: the eight raw FPGA
words followed by physical channel 1..4. `mca_epoch_ns` identifies the source
clock origin for each row; keep acquisition origins separate when doing later
coincidence matching across reader restarts. Signed integrals/baseline require
two's-complement interpretation. Reduced records retain accepted candidates;
use a bag or standalone `.mca` to retain flagged candidates too.

Optional standalone recording (use a new filename each run):

```sh
REDPITAYA_RECORD=/captures/my-run.mca bash scripts/start_redpitaya.sh --channels 1,2,3,4
```

`captures/` is ignored by Git and mounted at `/captures`. The reader supports
`--input saved.mca` for paced ROS replay. Legacy single-channel captures remain
readable. The optional Airy reduced replay preserves raw integer records when present.

## Binary interfaces

SSH/TCP stream version 2 begins with `RPMCA\x00\x02\n`. Frame headers are
`<4sI>` (tag, payload bytes). META/STAT/DONE carry JSON; EVN4 carries 36-byte
`<9I>` events. Old version 1 used EVNT and 32-byte `<8I>` events. The shared decoder
checks versions, channels, framing, order and final event count.
At 3,000 events/s on each of four channels, raw payload is **432 kB/s** plus
framing/status/SSH overhead. Four 128-event FIFOs are drained approximately every
1 ms; buffered records are sent at nominal 100 ms intervals. Stalls can cause
counted FIFO drops. Hardware throughput at these rates remains to be measured.

Main ROS UInt8MultiArray version 2 uses an 88-byte header: the existing
`<8sQQqQII>` 48-byte header with magic `RPMROS02`, followed by `<II4Q>` containing
active mask (bit 0=IN1), reserved zero and four live-tick deltas. Records are
36-byte `<9I>`. Header fields are end/start shared clock, signed Radxa epoch ns,
aggregate projected live ticks, event count and quality rejection mask.
Per-channel topics use legacy `RPMROS01` with the 48-byte header and 32-byte
records; the topic supplies channel identity. `integrations/airy_slam/gamma_rs/src/redpitaya.rs` supports
both, sorts accepted records within batches by exact timestamp, and retains raw
words for saving. Coincidence analysis should accommodate FIFO/batch delivery
order independently of event time.

MCA4 ABI 2.0 lives at **0x40700000**. Global identity is `0x4d434134`, ABI
`0x00020000`; write 0x40 then read 0x44/0x48 for shared clock. Each channel's MCA1
register bank starts at global base + channel×0x1000. Settings and FIFOs are
independent. The deployer verifies the reviewed BIN SHA-256; loader verifies it
again and checks the four-input board profile and MCA4 identity. Dedicated SSH
credentials and pinned host key live in ignored `runtime/` (700, key 600).
