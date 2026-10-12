import csv
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dashboard import Dashboard


def event(integral, flags=0):
    return (0, 0, flags << 16, 0, round(integral * 8192 / .008) & 0xffffffff, 0, 1, 0)


class DashboardTests(unittest.TestCase):
    def test_replay_pacing_handles_scheduler_overshoot_without_negative_sleep(self):
        from reader import pace_replay
        with patch("reader.time.monotonic", side_effect=[1.0, 1.02]), patch("reader.time.sleep") as sleep:
            pace_replay(1.01, lambda: False)
            self.assertEqual(sleep.call_count, 1)
            self.assertGreater(sleep.call_args.args[0], 0)
        with patch("reader.time.monotonic", return_value=1.02), patch("reader.time.sleep") as sleep:
            pace_replay(1.01, lambda: False)
            sleep.assert_not_called()

    def test_validated_v1_and_v2_streams_count_each_event_once(self):
        from reader import Session, update_dashboard
        from test_reader import capture, FourReaderTests
        for data, expected in [(capture(), [(1, 1, 1)]),
                               (FourReaderTests().capture(), [(1, 1, 0), (4, 2, 0)])]:
            dashboard, session = Dashboard([1]), Session()
            for offset in range(0, len(data), 17):
                for kind, value, _ in session.feed(data[offset:offset + 17], 20000000000):
                    update_dashboard(dashboard, session, kind, value)
            session.decoder.finish()
            state = dashboard.snapshot()
            self.assertEqual(state["phase"], "complete")
            self.assertEqual([(r["channel"], r["accepted"], r["rejected"]) for r in state["channels"]], expected)
            for row in state["channels"]:
                self.assertEqual(sum(row["histogram"]), row["accepted"])

    def test_spectrum_filtering_signed_integrals_range_and_elapsed_rate(self):
        dashboard = Dashboard([1, 2], bins=25)
        dashboard.batch(1, 0, 12500000, 6250000,
                        [event(2.5), event(-1), event(25), event(8, flags=4)], 31)
        row = dashboard.snapshot()["channels"][0]
        self.assertEqual((row["accepted"], row["rejected"], row["cps"]), (3, 1, 30))
        self.assertEqual(row["live_fraction"], .5)
        self.assertEqual((sum(row["histogram"]), row["underflow"], row["overflow"]), (1, 1, 1))
        self.assertEqual(row["histogram"][2], 1)
        dashboard.batch(1, 12500000, 25000000, 12500000, [], 31)
        row = dashboard.snapshot()["channels"][0]
        self.assertEqual((row["cps"], row["accepted"], len(row["history"])), (0, 3, 2))

    def test_history_is_bounded_and_snapshot_does_not_share_mutable_arrays(self):
        dashboard = Dashboard([1])
        for i in range(1250):
            dashboard.batch(1, i * 12500000, (i + 1) * 12500000, 12500000, [], 31)
        snapshot = dashboard.snapshot()
        self.assertEqual(len(snapshot["channels"][0]["history"]), 1200)
        snapshot["channels"][0]["histogram"][0] = 999
        self.assertEqual(dashboard.snapshot()["channels"][0]["histogram"][0], 0)
        dashboard.set_channels([1, 4])
        dashboard.batch(4, 0, 12500000, 12500000, [event(1)], 31)
        self.assertEqual(dashboard.snapshot()["channels"][1]["accepted"], 1)

    def test_http_state_csv_assets_and_unknown_paths(self):
        dashboard = Dashboard([1, 2], bins=25, recording="/captures/test.mca")
        dashboard.batch(2, 0, 12500000, 12500000, [event(2.5)], 31)
        dashboard.set_status(dict(type="status", fifo_dropped_events=7))
        port = dashboard.start("127.0.0.1", 0)
        self.addCleanup(dashboard.close)
        base = f"http://127.0.0.1:{port}"
        with urlopen(base + "/api/state") as response:
            state = json.load(response)
            self.assertEqual(state["phase"], "running")
            self.assertEqual(state["status"]["fifo_dropped_events"], 7)
            self.assertEqual(state["recording"], "/captures/test.mca")
        with urlopen(base + "/api/spectrum.csv") as response:
            rows = list(csv.DictReader(io.StringIO(response.read().decode())))
            self.assertEqual(len(rows), 50)
            self.assertEqual(sum(int(row["accepted_count"]) for row in rows), 1)
            peak = next(row for row in rows if row["accepted_count"] == "1")
            self.assertEqual((peak["channel"], peak["low_v_us"]), ("2", "2.0"))
        for path, mime in [("/", "text/html"), ("/app.js", "text/javascript"), ("/style.css", "text/css")]:
            with urlopen(base + path) as response:
                self.assertTrue(response.headers["Content-Type"].startswith(mime))
                self.assertGreater(len(response.read()), 100)
        for path in ["/missing", "/../reader.py", "/api/start"]:
            with self.assertRaises(HTTPError) as error:
                urlopen(base + path)
            self.assertEqual(error.exception.code, 404)


if __name__ == "__main__":
    unittest.main()
