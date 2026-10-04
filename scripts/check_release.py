#!/usr/bin/env python3
"""Check shipped image provenance and duplicate board/FPGA Python sources."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / 'redpitaya/bitstream'
manifest = json.loads((ARTIFACTS / 'artifact_manifest.json').read_text())
source = manifest['source_manifest']
assert source == json.loads((ARTIFACTS / 'source_manifest.json').read_text())
image = (ARTIFACTS / 'red_pitaya.bin').read_bytes()
assert len(image) == manifest['bytes']
assert hashlib.sha256(image).hexdigest() == manifest['bin_sha256']
for section in ['rtl_sha256', 'constraints_sha256']:
    for name, expected in source[section].items():
        assert hashlib.sha256((ROOT / 'fpga/rtl' / name).read_bytes()).hexdigest() == expected, name
for name in ['readout.py', 'wire.py']:
    assert (ROOT / 'fpga' / name).read_bytes() == (ROOT / 'redpitaya/board' / name).read_bytes(), name
print('PASS: supplied BIN, source manifest, RTL/constraints and board decoder copies')
