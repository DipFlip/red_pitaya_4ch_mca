import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from reader import Session, BATCH, BATCH_MAGIC
from wire import MAGIC, EVENT, frame, json_frame


def capture():
    meta = dict(type="metadata", mode="fpga_in1_mca", clock_hz=125000000,
                short_samples=250, long_samples=3125)
    event = [6250000, 0, 32768, (-100) & 0xffffffff, 600000,
             (4096 << 16) | ((-20) & 0xffff), 1, (3125 << 16) | 250]
    flagged = event.copy()
    flagged[2] |= 4 << 16
    flagged[6] = 2
    return (MAGIC + json_frame(b"META", meta) + frame(b"EVNT", EVENT.pack(*event) + EVENT.pack(*flagged)) +
            json_frame(b"STAT", dict(type="status", clock_ticks=12500000, live_ticks=12000000, read_events=2)) +
            json_frame(b"DONE", dict(type="summary", clock_ticks=25000000, live_ticks=24000000, read_events=2)))


class ReaderTests(unittest.TestCase):
    def test_fragmentation_preserves_raw_data_filters_counts_and_keeps_quiet_exposure(self):
        for size in (1, 5, 64, 8192):
            session = Session()
            data = capture()
            received = []
            for i in range(0, len(data), size):
                received.extend(session.feed(data[i:i + size], 1000000000))
            session.decoder.finish()
            packets = [v for kind, v, n in received if kind == "batch"]
            counts = [n for kind, v, n in received if kind == "batch"]
            self.assertEqual(counts, [1, 0])
            header = BATCH.unpack_from(packets[0])
            self.assertEqual(header, (BATCH_MAGIC, 12500000, 0, 900000000, 12000000, 2, 31))
            raw = list(EVENT.iter_unpack(packets[0][BATCH.size:]))
            self.assertEqual(raw[0][3], (-100) & 0xffffffff)
            self.assertEqual(raw[0][2], 32768)
            self.assertEqual(raw[1][2] >> 16, 4)
            self.assertEqual((session.accepted, session.rejected), (1, 1))
            self.assertEqual(session.sequence_gaps, 0)

    def test_sequence_gap_is_reported_and_clock_regression_rejected(self):
        session = Session()
        rows = list(session.feed(capture(), 1000000000))
        self.assertEqual(rows[-1][1]["energy_calibrated"], False)
        session = Session()
        # An out-of-order exposure must not silently add negative live time.
        prefix = capture().split(b"DONE")[0]
        list(session.feed(prefix, 1000000000))
        bad = json_frame(b"STAT", dict(type="status", clock_ticks=1, live_ticks=1))
        with self.assertRaises(ValueError):
            list(session.feed(bad, 1000000000))


if __name__ == "__main__":
    unittest.main()

class FourReaderTests(unittest.TestCase):
    def capture(self):
        from wire import MAGIC4, EVENT4
        meta=dict(type="metadata",mode="fpga_multichannel_mca",clock_hz=125000000,
                  short_samples=250,long_samples=3125,active_channels=[1,4],
                  start_clock_ticks=1000000000,channel_start_clocks={"1":1000000000,"4":1000000000})
        events=[]
        for c,t,seq in [(4,1000500000,1),(1,1000600000,1),(4,1000700000,3)]:
            events.extend([EVENT4.pack(t,0,32768,100,500,0,seq,(3125<<16)|250,c)])
        row=dict(type="summary",clock_ticks=1012500000,read_events=3,
                 channels=[dict(channel=c,clock_ticks=1012500000,live_ticks=12000000) for c in [1,4]])
        return MAGIC4+json_frame(b"META",meta)+frame(b"EVN4",b"".join(events))+json_frame(b"DONE",row)
    def test_per_channel_sequences_raw_ids_and_exposure(self):
        from reader import BATCH4_EXTRA,BATCH4_MAGIC
        from wire import EVENT4
        for size in [1,17,4096]:
            s=Session();rows=[];data=self.capture()
            for i in range(0,len(data),size):rows.extend(s.feed(data[i:i+size],20000000000))
            s.decoder.finish();self.assertEqual(s.sequence_gaps,1)
            self.assertEqual(s.channel_accepted,{1:1,4:2})
            packets=[v for k,v,a in rows if k=="channel_batch"]
            self.assertEqual([c for c,p in packets],[1,4])
            main=next(v for k,v,a in rows if k=="batch")
            self.assertEqual(BATCH.unpack_from(main)[0],BATCH4_MAGIC)
            self.assertEqual(BATCH4_EXTRA.unpack_from(main,48),(9,0,12000000,0,0,12000000))
            self.assertEqual([w[8] for w in EVENT4.iter_unpack(main[88:])],[4,1,4])
    def test_inactive_ids_and_clock_regression_fail(self):
        from wire import EVENT4,MAGIC4
        data=self.capture();s=Session();list(s.feed(data,20000000000))
        # An inactive detector cannot silently contaminate the selected set.
        meta=json_frame(b"META",dict(type="metadata",mode="fpga_multichannel_mca",clock_hz=125000000,
             short_samples=250,long_samples=3125,active_channels=[1],start_clock_ticks=0,channel_start_clocks={"1":0}))
        bad=EVENT4.pack(1,0,0,0,0,0,1,(3125<<16)|250,2)
        with self.assertRaises(ValueError):list(Session().feed(MAGIC4+meta+frame(b"EVN4",bad),0))
