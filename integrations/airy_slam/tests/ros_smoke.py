#!/usr/bin/env python3
"""Isolated ROS + recorded MCA + gamma HTTP smoke test (requires ROS setup).

Run against the alternate gamma image in ROS domain 142 on port 18082;
do not run against an operator's active gamma UI.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

import rclpy
from geometry_msgs.msg import PoseStamped
from rclpy.node import Node


def request(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request("http://127.0.0.1:18082" + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=Path)
    parser.add_argument("--expected", type=int, default=15)
    args = parser.parse_args()
    rclpy.init(args=[])
    node = Node("redpitaya_test_pose")
    publisher = node.create_publisher(PoseStamped, "/lightning/pose", 50)
    start = time.monotonic()
    def pose():
        msg = PoseStamped()
        msg.header.frame_id = "odom"
        msg.header.stamp = node.get_clock().now().to_msg()
        msg.pose.position.x = .02 * (time.monotonic() - start)
        msg.pose.orientation.w = 1.0
        publisher.publish(msg)
    node.create_timer(.05, pose)
    result = request("/api/measure/start", {"notes": "Red Pitaya integration smoke test",
                                           "mode": "reduced", "fresh_slam": False})
    assert result["ok"], result
    # Discovery before the first source events.
    until = time.monotonic() + 2
    while time.monotonic() < until:
        rclpy.spin_once(node, timeout_sec=.05)
    reader = Path(__file__).resolve().parents[1] / "reader.py"
    child = subprocess.Popen([sys.executable, str(reader), "--input", str(args.capture)])
    try:
        until = time.monotonic() + 25
        while child.poll() is None and time.monotonic() < until:
            rclpy.spin_once(node, timeout_sec=.05)
        assert child.wait(timeout=2) == 0
        until = time.monotonic() + 1
        while time.monotonic() < until:
            rclpy.spin_once(node, timeout_sec=.05)
        spectrum = request("/api/spectrum")
        assert spectrum["calibrated"] is False, spectrum
        assert sum(spectrum["counts"]) == 0, "Unknown energies must not form a keV spectrum"
        stop = request("/api/measure/stop", {})
        assert stop["ok"], stop
        assert stop["result"]["events"] == args.expected, stop
        rates = request("/api/rates?window=120")
        assert any(v is not None and v > 0 for v in rates["gross"]), rates
        print(json.dumps({"accepted_events": args.expected, "unknown_energy_spectrum_empty": True,
                          "live_s": spectrum["live_s"], "saved": stop["result"],
                          "positive_rate_bins": sum(v is not None and v > 0 for v in rates["gross"])}))
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
