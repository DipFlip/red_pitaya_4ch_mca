#!/usr/bin/env python3
"""Check the FPGA part and binary byte order before a Red Pitaya upload."""
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parent


def bit_metadata(path):
    with Path(path).open("rb") as f:
        def number(fmt):
            size = struct.calcsize(fmt)
            data = f.read(size)
            if len(data) != size:
                raise ValueError("Truncated bitstream header")
            return struct.unpack(fmt, data)[0]
        magic_length = number(">H")
        if magic_length != 9 or f.read(9) != bytes.fromhex("0ff00ff00ff00ff000"):
            raise ValueError("Unexpected Xilinx bitstream header")
        if number(">H") != 1:
            raise ValueError("Unexpected Xilinx tag length")
        fields = {}
        for expected in b"abcd":
            if f.read(1) != bytes([expected]):
                raise ValueError("Unexpected Xilinx metadata tag")
            fields[chr(expected)] = f.read(number(">H")).rstrip(b"\0").decode("ascii")
        if f.read(1) != b"e":
            raise ValueError("Missing bitstream payload")
        size = number(">I")
        payload = f.read(size)
        if len(payload) != size or f.read(1):
            raise ValueError("Bitstream payload length mismatch")
    return fields, payload


def validate(bit_path, bin_path):
    fields, payload = bit_metadata(bit_path)
    if fields["b"] not in ("7z020clg400", "7z020clg400-1", "xc7z020clg400-1"):
        raise ValueError(f"Wrong FPGA part: {fields['b']}")
    if not fields["a"].startswith("red_pitaya_top_4ADC;"):
        raise ValueError("Bitstream does not identify the four-ADC top")
    binary = Path(bin_path).read_bytes()
    # A dedicated, compressed MCA design can be much smaller than stock scope.
    if not (65_536 < len(binary) < 8_000_000 and len(payload) % 4 == 0):
        raise ValueError("Unexpected binary length")
    if bytes.fromhex("aa995566") not in payload:
        raise ValueError("Missing Xilinx configuration synchronization word")
    # Vendor write_cfgmem SMAPx32 stores each configuration word little-endian.
    expected = bytearray(len(payload))
    for byte in range(4):
        expected[byte::4] = payload[3-byte::4]
    if binary != expected:
        raise ValueError("Binary does not match the bitstream in Red Pitaya byte order")
    return {"design": fields["a"], "part": fields["b"], "build_date": fields["c"],
            "build_time": fields["d"], "bytes": len(binary),
            "bin_sha256": hashlib.sha256(binary).hexdigest(),
            "bit_sha256": hashlib.sha256(Path(bit_path).read_bytes()).hexdigest()}


if __name__ == "__main__":
    out = ROOT / "vendor/redpitaya-fpga/prj/v0.94/out"
    result = validate(out / "red_pitaya.bit", out / "red_pitaya.bin")
    result["source_manifest"] = json.loads((ROOT / "build/source_manifest.json").read_text())
    (ROOT / "build/artifact_manifest.json").write_text(json.dumps(result, indent=2)+"\n")
    print(json.dumps(result, indent=2))
