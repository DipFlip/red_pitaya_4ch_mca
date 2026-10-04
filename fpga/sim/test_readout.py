import importlib.util
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
spec = importlib.util.spec_from_file_location("readout", Path(__file__).resolve().parents[1] / "readout.py")
readout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(readout)


class DecodeTests(unittest.TestCase):
    def test_signed_fields_fraction_and_flags(self):
        words = [1234, 2, (5 << 16) | 32768, (-100) & 0xffffffff, 50000,
                 (7000 << 16) | ((-32) & 0xffff), 9, (6250 << 16) | 250]
        e = readout.decode(words)
        self.assertEqual(e["timestamp_ticks"], (2 << 32) + 1234)
        self.assertEqual(e["timestamp_fraction_65536"], 32768)
        self.assertEqual(e["short_adc_samples"], -100)
        self.assertEqual(e["baseline_adc_counts"], -32)
        self.assertEqual(e["flags"], ["near_full_scale", "invalid_cfd"])
        self.assertFalse(e["accepted"])
        self.assertEqual(e["short_samples"], 250)
        self.assertEqual(e["long_samples"], 6250)


if __name__ == "__main__":
    unittest.main()
