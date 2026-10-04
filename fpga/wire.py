"""Versioned binary MCA stream: raw FPGA events with framed run information."""
import json
import struct

MAGIC = b"RPMCA\x00\x01\n"
MAGIC4 = b"RPMCA\x00\x02\n"
EVENT4 = struct.Struct("<9I")
HEADER = struct.Struct("<4sI")
EVENT = struct.Struct("<8I")
MAX_PAYLOAD = 1024 * 1024
KINDS = {b"META": "metadata", b"STAT": "status", b"DONE": "summary"}


def frame(kind, payload):
    if kind not in (*KINDS, b"EVNT", b"EVN4") or len(payload) > MAX_PAYLOAD:
        raise ValueError("Invalid MCA frame")
    return HEADER.pack(kind, len(payload)) + payload


def json_frame(kind, row):
    return frame(kind, json.dumps(row, allow_nan=False, separators=(",", ":")).encode())


class Decoder:
    """Incremental decoder; accepts arbitrary TCP/SSH chunk boundaries."""
    def __init__(self, decode_events=True):
        self.buffer = bytearray()
        self.started = False
        self.metadata = False
        self.done = False
        self.events = 0
        self.decode_events = decode_events
        self.version = None

    def feed(self, data):
        # Import lazily so the board's writer does not need event JSON decoding.
        if self.decode_events:
            from readout import decode
        self.buffer.extend(data)
        if not self.started:
            if len(self.buffer) < len(MAGIC):
                return
            magic = bytes(self.buffer[:len(MAGIC)])
            if magic not in (MAGIC, MAGIC4):
                raise ValueError("Unsupported MCA stream version or magic")
            self.version = 1 if magic == MAGIC else 2
            del self.buffer[:len(MAGIC)]
            self.started = True
        while len(self.buffer) >= HEADER.size:
            kind, length = HEADER.unpack_from(self.buffer)
            if kind not in (*KINDS, b"EVNT", b"EVN4") or length > MAX_PAYLOAD:
                raise ValueError("Invalid MCA frame header")
            if self.done or (not self.metadata and kind != b"META"):
                raise ValueError("Unexpected MCA frame order")
            if len(self.buffer) < HEADER.size + length:
                return
            payload = bytes(self.buffer[HEADER.size:HEADER.size + length])
            del self.buffer[:HEADER.size + length]
            if kind in (b"EVNT", b"EVN4"):
                if kind != (b"EVNT" if self.version == 1 else b"EVN4"):
                    raise ValueError("Event version disagrees with stream")
                record = EVENT if self.version == 1 else EVENT4
                if not length or length % record.size:
                    raise ValueError("Incomplete MCA event batch")
                for words in record.iter_unpack(payload):
                    if self.version == 2 and not 1 <= words[8] <= 4:
                        raise ValueError("Invalid detector channel")
                    self.events += 1
                    yield decode(words) if self.decode_events else {"type": "event", "words": words, "channel": words[8] if self.version == 2 else 1}
            else:
                row = json.loads(payload)
                if not isinstance(row, dict) or row.get("type") != KINDS[kind]:
                    raise ValueError("MCA frame type disagrees with payload")
                if kind == b"META":
                    if self.metadata or row.get("mode") != ("fpga_in1_mca" if self.version == 1 else "fpga_multichannel_mca"):
                        raise ValueError("Unexpected MCA metadata")
                    self.metadata = True
                elif kind == b"DONE":
                    if row.get("read_events") != self.events:
                        raise ValueError("MCA summary event count disagrees with stream")
                    self.done = True
                yield row

    def finish(self):
        if self.buffer or not self.started or not self.done:
            raise ValueError("Truncated MCA stream; final summary required")
