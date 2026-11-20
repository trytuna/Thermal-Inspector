#!/usr/bin/env python3
"""Summarizes a high-speed USB capture of the camera (pcapng from Alex Taradov's
USB Sniffer, link type "USB 2.0 packets").

Low-level captures are huge – mostly the host polling endpoints and the camera
answering NAK. This script rebuilds the transactions and prints only what is
interesting:

* every SETUP (control) transfer with its data,
* every OUT transfer (what the host – Mac or iPhone – sends to the camera),
* IN transfers on all endpoints except the image stream, which is only
  summarized (bytes per second, frame start markers).

Usage:  Tools/usb-capture-summary.py capture.pcapng [--stream-endpoint 1] [--max-in-bytes 64]
"""
import argparse
import struct
import sys
from collections import defaultdict

PID_NAMES = {
    0xE1: "OUT", 0x69: "IN", 0xA5: "SOF", 0x2D: "SETUP",
    0xC3: "DATA0", 0x4B: "DATA1", 0x87: "DATA2", 0x0F: "MDATA",
    0xD2: "ACK", 0x5A: "NAK", 0x1E: "STALL", 0x96: "NYET",
    0xB4: "PING", 0x78: "SPLIT", 0x3C: "PRE/ERR",
}
TOKENS = {0xE1, 0x69, 0x2D, 0xB4}
DATA = {0xC3, 0x4B, 0x87, 0x0F}
HANDSHAKES = {0xD2, 0x5A, 0x1E, 0x96}
LINKTYPES_USB_2_0 = {288, 293, 294, 295}  # any speed


def packets(path):
    """Yields (timestamp in seconds, raw USB packet, original length) from a pcapng file.

    Packets shortened by usb-capture-filter are shorter than their original length."""
    link_types = []
    with open(path, "rb") as f:
        while True:
            header = f.read(8)
            if len(header) < 8:
                return
            block_type, length = struct.unpack("<II", header)
            body = f.read(length - 8)
            if len(body) < length - 8:
                return  # cut short
            if block_type == 0x00000001:  # interface description
                link_types.append(struct.unpack("<H", body[:2])[0])
            elif block_type == 0x00000006:  # enhanced packet
                interface, ts_high, ts_low, cap_len, orig_len = struct.unpack("<IIIII", body[:20])
                if link_types[interface] not in LINKTYPES_USB_2_0:
                    continue
                ticks = (ts_high << 32) | ts_low
                yield ticks / 1e9, body[20:20 + cap_len], orig_len


def token_fields(packet):
    value = packet[1] | (packet[2] << 8)
    return value & 0x7F, (value >> 7) & 0x0F  # address, endpoint


def hexdump(data, limit):
    shown = data[:limit].hex(" ")
    return shown + (f" … ({len(data)} bytes)" if len(data) > limit else "")


def describe_setup(data):
    request_type, request, value, index, length = struct.unpack("<BBHHH", data[:8])
    direction = "IN " if request_type & 0x80 else "OUT"
    kind = ["std", "class", "vendor", "?"][(request_type >> 5) & 3]
    return (f"bmRequestType=0x{request_type:02x} ({direction} {kind}) bRequest=0x{request:02x} "
            f"wValue=0x{value:04x} wIndex=0x{index:04x} wLength={length}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("capture")
    parser.add_argument("--stream-endpoint", type=int, default=1,
                        help="IN endpoint carrying the image stream (only summarized)")
    parser.add_argument("--max-in-bytes", type=int, default=64)
    args = parser.parse_args()

    token = None        # (time, pid, address, endpoint)
    data = None         # payload of the current transaction
    start = None
    stream_bytes = defaultdict(int)   # second → bytes on the stream endpoint
    stream_started = None
    pending_setup = None
    control_in = bytearray()
    # Bytes of the current transfer on the stream endpoint. A transfer ends with a
    # short packet; short transfers are not image data but answers to commands.
    stream_transfer = bytearray()
    stream_transfer_start = 0.0
    stream_transfer_length = 0
    data_length = 0

    for time, packet, original_length in packets(args.capture):
        if not packet:
            continue
        if start is None:
            start = time
        t = time - start
        pid = packet[0]

        if pid in TOKENS and len(packet) >= 3:
            address, endpoint = token_fields(packet)
            token = (t, pid, address, endpoint)
            data = None
        elif pid in DATA:
            # Without PID and CRC16 – a shortened packet has lost its CRC already.
            data = bytes(packet[1:-2]) if len(packet) == original_length else bytes(packet[1:])
            data_length = original_length - 3
        elif pid in HANDSHAKES or (pid in DATA and token and token[1] == 0x69):
            pass
        else:
            continue

        # A transaction is complete with its handshake – or, for IN, with the data
        # packet (the host's ACK follows, isochronous has none).
        if token is None:
            continue
        t0, token_pid, address, endpoint = token
        if pid == 0x5A or (pid == 0x96 and token_pid != 0xE1):  # NAK – nothing transferred
            token = None
            continue
        if pid == 0x1E:
            print(f"{t0:10.6f}  {address}.{endpoint}  {PID_NAMES[token_pid]:5}  STALL")
            token = None
            continue
        if pid not in (0xD2, 0x96):
            continue  # wait for the handshake (NYET after OUT data means: accepted)
        payload = data or b""
        length = data_length if data else 0
        token = None

        if token_pid == 0x2D:
            pending_setup = payload
            control_in = bytearray()
            print(f"{t0:10.6f}  {address}.{endpoint}  SETUP  {describe_setup(payload)}")
        elif token_pid == 0xE1:
            if endpoint == 0 and pending_setup is not None:
                label = "ctrl OUT data" if payload else "status (OUT)"
                print(f"{t0:10.6f}  {address}.0  {label}  {hexdump(payload, 256)}")
                if not payload and control_in:
                    pending_setup = None
            else:
                print(f"{t0:10.6f}  {address}.{endpoint}  OUT    {hexdump(payload, 256)}")
        elif token_pid == 0x69:
            if endpoint == args.stream_endpoint and endpoint != 0:
                if stream_started is None:
                    stream_started = t0
                    print(f"{t0:10.6f}  {address}.{endpoint}  IN     first stream data: {hexdump(payload, 32)}")
                stream_bytes[int(t0)] += length
                if not stream_transfer_length:
                    stream_transfer_start = t0
                stream_transfer += payload
                stream_transfer_length += length
                if length < 512:
                    if stream_transfer_length < 1024:
                        print(f"{stream_transfer_start:10.6f}  {address}.{endpoint}  IN     short transfer: "
                              f"{hexdump(bytes(stream_transfer), 256)}")
                    stream_transfer = bytearray()
                    stream_transfer_length = 0
                if payload[:2] in (b"\x0c\x8c", b"\x0c\x8d") and len(payload) >= 12 and stream_bytes[int(t0)] <= length:
                    print(f"{t0:10.6f}  {address}.{endpoint}  IN     frame marker {hexdump(payload, 12)}")
            elif endpoint == 0:
                control_in += payload
                print(f"{t0:10.6f}  {address}.0  ctrl IN data  {hexdump(payload, 256)}")
            else:
                print(f"{t0:10.6f}  {address}.{endpoint}  IN     {hexdump(payload, args.max_in_bytes)}")

    if stream_bytes:
        print("\nImage stream (bytes per second):")
        for second in sorted(stream_bytes):
            print(f"  {second:4d} s  {stream_bytes[second]:>10,}")
    else:
        print("\nNo data on the stream endpoint.")


if __name__ == "__main__":
    main()
