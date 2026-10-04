#!/usr/bin/env python3
"""Plot measured FPGA list-mode integrals; no energy calibration is implied."""
import argparse
from collections import Counter
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("records", type=Path)
    args = parser.parse_args()
    rows = [json.loads(line) for line in args.records.read_text().splitlines() if line.strip()]
    events = [row for row in rows if row.get("type") == "event"]
    accepted = [row for row in events if row["accepted"]]
    metadata = next(row for row in rows if row.get("type") == "metadata")
    summary = next(row for row in rows if row.get("type") == "summary")
    fig, axes = plt.subplots(1, 2, figsize=(10, 4), constrained_layout=True)
    areas = [row["long_nominal_v_us"] for row in accepted]
    axes[0].hist(areas, bins=64, color="#2268a2")
    axes[0].set(xlabel="Long-gate integral (nominal V µs)", ylabel="Accepted events")
    axes[1].scatter(areas, [row["short_nominal_v_us"] for row in accepted], s=15, alpha=.75)
    axes[1].set(xlabel="Long-gate integral (nominal V µs)", ylabel="Short-gate integral (nominal V µs)")
    for ax in axes:
        ax.grid(alpha=.2)
        if not accepted:
            ax.text(.5, .5, "No accepted events", transform=ax.transAxes, ha="center")
    short = metadata["short_samples"] / 125
    long = metadata["long_samples"] / 125
    channels = metadata.get("active_channels", [1])
    dropped = summary.get("fifo_dropped_events", sum(c.get("fifo_dropped_events", 0) for c in summary.get("channels", [])))
    fig.suptitle(f"IN{','.join(map(str, channels))} FPGA MCA · {short:g}/{long:g} µs gates · "
                 f"{len(accepted)}/{len(events)} accepted · "
                 f"{dropped} FIFO drops\n"
                 "Nominal LV conversion; detector energy calibration not applied", fontsize=11)
    target = args.records.parent / "integrals.png"
    fig.savefig(target, dpi=180)
    fig.savefig(target.with_suffix(".pdf"))
    flags = Counter(flag for row in events for flag in row["flags"])
    print(json.dumps({"events": len(events), "accepted": len(accepted), "flags": dict(flags),
                      "summary": summary, "plot": str(target)}, indent=2))


if __name__ == "__main__":
    main()
