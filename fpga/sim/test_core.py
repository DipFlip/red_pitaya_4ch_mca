#!/usr/bin/env python3
"""Run actual HDL against independently calculated sums and timing references."""
import csv
import os
import json
from pathlib import Path
import subprocess
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "sim"
BUILD.mkdir(parents=True, exist_ok=True)
subprocess.run(["iverilog", "-g2012", "-Wall", "-s", "core_tb", "-o", str(BUILD / "core.vvp"),
                str(ROOT / "rtl/mca_core.sv"), str(ROOT / "sim/core_tb.sv")], check=True)


def run(name, samples, baseline=0, short=250, long=6250, auto=False):
    samples = np.asarray(samples, dtype=np.int64)
    assert np.max(samples) <= 8191 and np.min(samples) >= -8192
    stimulus = BUILD / f"{name}.hex"
    stimulus.write_text("".join(f"{x & 0x3fff:04x}\n" for x in samples))
    result = BUILD / f"{name}.csv"
    args = ["vvp", str(BUILD / "core.vvp"), f"+INPUT={stimulus}", f"+OUTPUT={result}",
            f"+N={len(samples)}", f"+BASE={baseline}", f"+SHORT={short}", f"+LONG={long}"]
    if auto:
        args.append("+AUTO")
    subprocess.run(args, check=True, capture_output=True, text=True)
    events = [{k: int(v) for k, v in row.items()} for row in csv.DictReader(result.open())]
    for event in events:
        start = event["trigger"] - 64
        for key, gate in [("short", short), ("long", long)]:
            expected = int(np.sum(samples[start:start + gate] - event["baseline"]))
            assert event[key] == expected, (name, key, expected, event)
        assert event["short"] == event["long"] or short != long
    return events


def shape(height):
    return np.rint(np.concatenate((np.linspace(0, height, 26), np.full(40, height),
                                  height * np.exp(-np.arange(1, 4501) / 500)))).astype(int)


report = {"checks": [], "amplitude_walk": [], "real_waveforms": []}
stimulus = np.full(5 * 10000, 123, dtype=int)
for j, height in enumerate([503, 907, 2027, 4001, 7293]):
    pulse = shape(height)
    start = j * 10000 + 1000
    stimulus[start:start + len(pulse)] += pulse
events = run("scaled_shape", stimulus, baseline=123)
assert len(events) == 5, events
for j, e in enumerate(events):
    assert e["flags"] == 0, e
    offset = e["tick"] + e["fraction"] / 65536 - (j * 10000 + 1000)
    report["amplitude_walk"].append({"peak_counts": e["peak"], "cfd_offset_ns": offset * 8,
                                    "threshold_offset_ns": (e["trigger"] - (j*10000+1000)) * 8})
walk = np.ptp([row["cfd_offset_ns"] for row in report["amplitude_walk"]])
assert walk < 0.5, walk
report["checks"].append(f"Five pulse amplitudes: CFD walk {walk:.4f} ns (synthetic fixed shape)")

equal = run("equal_gates", stimulus[:10000], baseline=123, short=800, long=800)
assert len(equal) == 1
report["checks"].append("Both signed integrals match independent sample sums; equal gates match")

clip = np.zeros(10000, dtype=int)
clip[1000:1000+len(shape(8191))] = shape(8191)
e = run("clip", clip)[0]
assert e["flags"] & 1, e
pileup = np.zeros(10000, dtype=int)
pileup[1000:1000+len(shape(2000))] += shape(2000)
pileup[2500:2500+len(shape(1000))] += shape(1000)
e = run("pileup", pileup)[0]
assert e["flags"] & 2, e
report["checks"].append("Clipping and a second pulse in the long gate are flagged")

noise = np.full(10000, -250, dtype=int) + np.tile([-5, 5], 5000)
assert not run("noise", noise, baseline=-250)
noise[2000:2000+len(shape(1500))] += shape(1500)
e = run("auto_baseline", noise, auto=True)[0]
assert abs(e["baseline"] + 250) <= 2, e
assert not e["flags"], e
report["checks"].append("Noise alone produces no events; automatic negative baseline tracks to two counts")

noisy_pulse = np.tile([-5, 5], 5000)
noisy_pulse[1000:1000+len(shape(1500))] += shape(1500)
e = run("noisy_early_peak", noisy_pulse)[0]
assert not e["flags"], e
report["checks"].append("A noisy pulse retains valid CFD when the peak-window endpoint is negative")

recovery = np.zeros(140000, dtype=int)
recovery[:1000] = 300
recovery[130000:130000+len(shape(300))] += shape(300)
recovered = run("baseline_recovery", recovery, auto=True)
assert len(recovered) == 1 and abs(recovered[0]["baseline"]) <= 1, recovered
report["checks"].append("Reset during a flat pulse recovers the baseline instead of remaining blind")

late = np.zeros(12000, dtype=int)
late[1000:1801] = np.linspace(0, 3000, 801).astype(int)
late[1801:2500] = 3000
e = run("late_peak", late)[0]
assert e["flags"] & 16, e
report["checks"].append("A rise exceeding the early-peak window is flagged")

# Exercise the RAM/search pipeline near its longest traversal at the minimum
# long gate. The fraction crossing precedes the qualified trigger by ~58 ticks.
deep = np.zeros(3000, dtype=int)
deep[900:950] = 80
deep[950:1000] = 100
deep[1000:1261] = 180
deep[1261] = 300
e = run("deep_pretrigger_cfd", deep, short=250, long=672)[0]
expected = 949 + ((300 * 77 / 256) - 80) / 20
actual = e["tick"] + e["fraction"] / 65536
assert not e["flags"] and abs(actual - expected) <= 1 / 65536, e
report["checks"].append("Deep pretrigger CFD traversal completes correctly at the minimum long gate")

missing = np.zeros(10000, dtype=int)
missing[1000:1300] = np.minimum(np.arange(300), 200)
e = run("missing_pretrigger_cfd", missing)[0]
assert e["flags"] & 4 and e["tick"] == e["trigger"] and e["fraction"] == 0, e
report["checks"].append("A fraction crossing outside captured prehistory retains the trigger timestamp and is flagged")

# Replay captured pulses. Calibration is nominal here; the acquisition files contain volts.
capture_root = Path(os.environ["MCA_CAPTURE_FIXTURES"]) if os.getenv("MCA_CAPTURE_FIXTURES") else None
for filename in (["tuned-run", "radxa-live-50us"] if capture_root else []):
    rows = [r for line in (capture_root / filename / "records.jsonl").open()
            if (r := json.loads(line)).get("waveform_v")]
    rows.sort(key=lambda r: r["peak_v"], reverse=True)
    for i, record in enumerate(rows[:3]):
        raw = np.rint(np.asarray(record["waveform_v"]) * 8192).astype(int)
        base = int(np.rint(record["baseline_v"] * 8192))
        # Extra quiet data warms up the hardware and supplies a complete 50 us gate.
        data = np.concatenate((np.full(3000, base), raw, np.full(7000, base)))
        replay = run(f"real_{filename}_{i}", data, baseline=base)
        assert replay, (filename, i)
        e = max(replay, key=lambda e: e["peak"])
        report["real_waveforms"].append({"source": filename, "peak_v": e["peak"]/8192,
             "short_v_us": e["short"] /8192*.008, "long_v_us": e["long"]/8192*.008,
             "flags": e["flags"]})
if capture_root:
    report["checks"].append("Six external detector waveforms replayed through HDL; integrals match exact reference sums")
(BUILD / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
