import io
import json
import signal
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import readout
from wire import MAGIC, HEADER, EVENT, Decoder, frame, json_frame


WORDS = [123, 0x12345678, (4 << 16) | 65535, (-123) & 0xffffffff,
         987654, (4096 << 16) | ((-13) & 0xffff), 1, (3125 << 16) | 250]
META = {"type": "metadata", "mode": "fpga_in1_mca"}


def sample_stream():
    return (MAGIC + json_frame(b"META", META) + frame(b"EVNT", EVENT.pack(*WORDS)) +
            json_frame(b"STAT", {"type": "status", "read_events": 1}) +
            json_frame(b"DONE", {"type": "summary", "read_events": 1}))


class WireTests(unittest.TestCase):
    def test_arbitrary_chunks_preserve_exact_event_fields(self):
        data = sample_stream()
        for size in (1, 3, 7, 32, 4096):
            decoder = Decoder()
            rows = []
            for start in range(0, len(data), size):
                rows.extend(decoder.feed(data[start:start + size]))
            decoder.finish()
            self.assertEqual(rows[1], readout.decode(WORDS))
            self.assertEqual([r["type"] for r in rows], ["metadata", "event", "status", "summary"])
            self.assertEqual(rows[1]["timestamp_ticks"], (WORDS[1] << 32) + WORDS[0])

    def test_truncation_and_trailing_data_rejected(self):
        data = sample_stream()
        for length in range(len(data)):
            decoder = Decoder()
            list(decoder.feed(data[:length]))
            with self.assertRaises(ValueError):
                decoder.finish()
        decoder = Decoder()
        list(decoder.feed(data + b"garbage"))
        with self.assertRaises(ValueError):
            decoder.finish()

    def test_malformed_streams_rejected(self):
        for data in (
            b"not MCA!",
            MAGIC + HEADER.pack(b"EVNT", 2**30),
            MAGIC + frame(b"EVNT", EVENT.pack(*WORDS)),
            MAGIC + json_frame(b"META", META) + frame(b"EVNT", b"short"),
            MAGIC + json_frame(b"META", META) + json_frame(b"DONE", {"type": "summary", "read_events": 1}),
            sample_stream() + json_frame(b"STAT", {"type": "status"}),
        ):
            with self.assertRaises(ValueError):
                list(Decoder().feed(data))

    def test_four_channel_reader_drains_20khz_and_reports_idle_at_10hz(self):
        for rate, duration in ((0,1),(5000,1),(0,0)):
            now=[0.0]
            class FakeRegisters:
                def __init__(self):
                    self.config={};self.queue={c:[] for c in range(1,5)}
                    self.enabled={c:False for c in range(1,5)}
                    self.produced={c:0 for c in range(1,5)};self.dropped=0
                    self.starts={c:0 for c in range(1,5)};self.lives={c:0 for c in range(1,5)}
                def generate(self):
                    for c in range(1,5):
                        if not self.enabled[c]:continue
                        total=int((now[0]-self.starts[c])*rate)
                        while self.produced[c]<total:
                            self.produced[c]+=1;words=WORDS.copy();words[6]=self.produced[c]
                            words[0]=int(now[0]*125000000);words[1]=0
                            if len(self.queue[c])<128:self.queue[c].append(words)
                            else:self.dropped+=1
                def read(self,offset):
                    self.generate();c,reg=divmod(offset,4096)
                    if c==0:
                        return {0:0x4d434134,4:0x20000,0x44:int(now[0]*125000000),0x48:0}.get(reg,0)
                    if reg==0x0c:return 2 if self.queue[c] else 0
                    if reg>=0x100:return self.queue[c][0][(reg-0x100)//4]
                    return 0
                def write(self,offset,value):
                    self.generate();self.config[offset]=value;c,reg=divmod(offset,4096)
                    if c and reg==8:
                        if value==1:self.starts[c]=now[0];self.enabled[c]=True
                        elif self.enabled[c]:
                            self.lives[c]=int((now[0]-self.starts[c])*125000000);self.enabled[c]=False
                    elif c and reg==0x20:self.queue[c].pop(0)
                def snapshot(self,c):
                    return dict(clock_ticks=int(now[0]*125000000),enabled_ticks=int(now[0]*125000000),
                                live_ticks=int((now[0]-self.starts[c])*125000000) if self.enabled[c] else self.lives[c],
                                triggered_events=self.produced[c],fifo_dropped_events=self.dropped,fifo_stored_events=self.produced[c])
                def close(self):pass
            regs=FakeRegisters()
            class Output(io.BytesIO):
                def __init__(self):super().__init__();self.deliveries=[]
                def flush(self):self.deliveries.append((now[0],len(self.getvalue())))
            output=Output();stdout=type("Stdout",(),{"buffer":output})()
            def sleep(seconds):
                now[0]+=seconds
                if duration==0 and now[0]>=.12:signal.getsignal(signal.SIGTERM)(signal.SIGTERM,None)
            with patch.object(readout,"Registers",return_value=regs),patch.object(readout,"open",return_value=io.StringIO(),create=True),patch.object(readout.fcntl,"flock"),patch.object(readout.sys,"stdout",stdout),patch.object(readout.sys,"argv",["readout.py","--custom-bitstream-loaded","--channels","1,2,3,4","--seconds",str(duration)]),patch.object(readout.time,"monotonic",side_effect=lambda:now[0]),patch.object(readout.time,"sleep",side_effect=sleep):
                readout.main()
            decoder=Decoder();rows=list(decoder.feed(output.getvalue()));decoder.finish()
            events=[r for r in rows if r["type"]=="event"];statuses=[r for r in rows if r["type"]=="status"]
            self.assertEqual(len(events),sum(regs.produced.values()));self.assertEqual(regs.dropped,0)
            for c in range(1,5):
                self.assertEqual(regs.config[c*4096+0x14],3125)
                self.assertEqual(sum(r["channel"]==c for r in events),regs.produced[c])
            self.assertGreaterEqual(len(statuses),9 if duration else 1)
            deliveries=[t for t,length in output.deliveries if length>len(MAGIC)]
            self.assertLessEqual(max(b-a for a,b in zip(deliveries,deliveries[1:])),.102)
            if rate:
                self.assertGreaterEqual(len(events),19960)
                self.assertLess(len(output.getvalue()),760000)


if __name__ == "__main__":
    unittest.main()
