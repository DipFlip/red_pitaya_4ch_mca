#!/usr/bin/env python3
"""Export FPGA list mode to CSV and an integral histogram, preserving flags."""
import argparse
import csv
import json
from pathlib import Path


def export(source, destination, bins=512, max_area=25.0):
    with Path(source).open() as f:
        records = [json.loads(line) for line in f if line.strip()]
    if not records or records[0].get("mode") not in ("fpga_in1_mca", "fpga_multichannel_mca") or records[-1].get("type") != "summary":
        raise ValueError("Expected a complete FPGA MCA JSONL run with metadata and summary")
    if bins <= 0 or max_area <= 0:
        raise ValueError("Histogram settings must be positive")
    output = Path(destination)
    output.mkdir(parents=True, exist_ok=False)
    events = [row for row in records if row.get("type") == "event"]
    columns = ["channel", "sequence", "timestamp_ticks", "timestamp_fraction_65536", "timestamp_ns",
               "short_adc_samples", "long_adc_samples", "short_nominal_v_us", "long_nominal_v_us",
               "short_over_long", "baseline_adc_counts", "peak_adc_counts", "short_samples",
               "long_samples", "flags_bits", "flags", "accepted"]
    with (output / "listmode.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, columns)
        writer.writeheader()
        for event in events:
            row = {key: event.get(key) for key in columns}
            row["flags"] = ";".join(event["flags"])
            writer.writerow(row)
    counts = [0] * bins
    below, above, flagged = 0, 0, 0
    for event in events:
        if not event["accepted"]:
            flagged += 1
            continue
        area = event["long_nominal_v_us"]
        if area < 0:
            below += 1
        elif area >= max_area:
            above += 1
        else:
            counts[int(area / max_area * bins)] += 1
    with (output / "histogram.csv").open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["lower_nominal_v_us", "upper_nominal_v_us", "events"])
        for i, count in enumerate(counts):
            writer.writerow([i * max_area / bins, (i + 1) * max_area / bins, count])
    for name, value in [("metadata", records[0]), ("summary", records[-1]),
                        ("histogram_metadata", {"bins": bins, "max_nominal_v_us": max_area,
                           "underflow": below, "overflow": above, "flagged_excluded": flagged,
                           "read_events": len(events), "in_range_accepted": sum(counts)})]:
        (output / (name + ".json")).write_text(json.dumps(value, indent=2) + "\n")
    return len(events)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input")
    parser.add_argument("output")
    args = parser.parse_args()
    print(f"Exported {export(args.input, args.output)} candidates")
