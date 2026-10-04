import csv
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("export_run", ROOT / "export_run.py")
export_run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export_run)


class ExportTests(unittest.TestCase):
    def test_flags_and_histogram_limits_preserve_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            events = [{"type": "event", "long_nominal_v_us": area, "accepted": not flags,
                       "flags": flags, "flags_bits": int(bool(flags)), "sequence": i}
                      for i, (area, flags) in enumerate([(-1, []), (3, []), (25, []), (5, ["possible_pileup"])])]
            rows = [{"type": "metadata", "mode": "fpga_in1_mca"}, *events, {"type": "summary"}]
            source = root / "run.jsonl"
            source.write_text("".join(json.dumps(row)+"\n" for row in rows))
            self.assertEqual(export_run.export(source, root / "export"), 4)
            meta = json.loads((root / "export/histogram_metadata.json").read_text())
            self.assertEqual((meta["underflow"], meta["overflow"], meta["flagged_excluded"], meta["in_range_accepted"]),
                             (1, 1, 1, 1))
            with (root / "export/listmode.csv").open() as f:
                self.assertEqual(len(list(csv.DictReader(f))), 4)


if __name__ == "__main__":
    unittest.main()
