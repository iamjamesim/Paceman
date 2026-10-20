import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import unittest
from unittest.mock import patch

from service.native_websocket import UnixWebSocket, MAX_MESSAGE
from service.codex_daemon import native_socket


def frame(payload, opcode=1, final=True):
    n = len(payload)
    header = bytes([(128 if final else 0) | opcode, n]) if n < 126 else (
        bytes([(128 if final else 0) | opcode, 126]) + struct.pack('!H', n))
    return header + payload


class Peer:
    def __init__(self):
        self.buffer = b''
        self.sent = []
    def settimeout(self, *_): pass
    def connect(self, *_): pass
    def shutdown(self, *_): pass
    def close(self): pass
    def recv(self, count):
        # Exercise short reads at every boundary.
        data, self.buffer = self.buffer[:min(count, 3)], self.buffer[min(count, 3):]
        return data
    def sendall(self, data):
        self.sent.append(data)
        if data.startswith(b'GET '):
            key = next(l.split(b': ', 1)[1] for l in data.split(b'\r\n') if l.startswith(b'Sec-WebSocket-Key:'))
            accept = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
            self.buffer += b'HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n'


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.peer = Peer()
        with patch('socket.socket', return_value=self.peer):
            self.ws = UnixWebSocket('/private/native.sock')

    def test_fragments_unicode_and_interleaved_ping_are_decoded_as_one_json_message(self):
        data = json.dumps({'question': '日本語'}, ensure_ascii=False).encode()
        self.peer.buffer = frame(data[:17], final=False) + frame(b'hello', opcode=9) + frame(data[17:], opcode=0)
        self.assertEqual(self.ws.receive(), {'question': '日本語'})
        pong = self.peer.sent[-1]
        self.assertEqual(pong[0], 0x8a)
        self.assertTrue(pong[1] & 128)

    def test_client_frames_are_masked_and_preserve_long_json(self):
        original = {'value': 'x' * 70000}
        self.ws.send(original)
        sent = self.peer.sent[-1]
        self.assertEqual(sent[:2], b'\x81\xff')
        size = struct.unpack('!Q', sent[2:10])[0]
        mask, data = sent[10:14], sent[14:]
        self.assertEqual(len(data), size)
        self.assertEqual(json.loads(bytes(v ^ mask[i % 4] for i, v in enumerate(data))), original)

    def test_masked_server_compression_binary_and_invalid_fragments_are_rejected(self):
        for data in [b'\x81\x80', b'\xc1\x00', frame(b'{}', opcode=2), frame(b'{}', opcode=0),
                     frame(b'x', opcode=9, final=False), b'\x81\xff' + struct.pack('!Q', MAX_MESSAGE + 1)]:
            with self.subTest(data=data):
                self.peer.buffer = data
                with self.assertRaises(ValueError): self.ws.receive()

    def test_wrong_handshake_accept_is_rejected(self):
        peer = Peer()
        original = peer.sendall
        def bad(data):
            original(data)
            peer.buffer = peer.buffer.replace(b'Sec-WebSocket-Accept:', b'Wrong:')
        peer.sendall = bad
        with patch('socket.socket', return_value=peer), self.assertRaises(ValueError):
            UnixWebSocket('/private/native.sock')

    def test_private_native_symlink_is_accepted_but_public_link_directory_is_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target, link = root / 'native.sock', root / 'link.sock'
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(target))
                link.symlink_to(target)
                self.assertEqual(native_socket(link), target.resolve())
                root.chmod(0o755)
                with self.assertRaises(OSError): native_socket(link)
