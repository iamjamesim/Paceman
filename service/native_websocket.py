"""Bounded RFC 6455 text transport for a local, already-owned Unix socket.

No TCP, redirects, compression, cookies, or provider credentials. The caller
checks socket ownership before connecting. Protocol errors close the channel.
"""
import base64
import hashlib
import json
import os
import socket
import struct
import threading

MAX_MESSAGE = 16 * 1024 * 1024


class UnixWebSocket:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.lock = threading.Lock()
        try:
            self.socket.settimeout(5)
            self.socket.connect(str(path))
            key = base64.b64encode(os.urandom(16)).decode('ascii')
            self.socket.sendall(('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
                'Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ' + key + '\r\n\r\n').encode('ascii'))
            header = bytearray()
            while not header.endswith(b'\r\n\r\n'):
                if len(header) >= 8192:
                    raise ValueError('oversized native handshake')
                header.extend(self._exact(1))
            lines = header.decode('ascii').split('\r\n')
            if lines[0].split(' ', 2)[:2] != ['HTTP/1.1', '101']:
                raise ValueError('native upgrade refused')
            fields = {}
            for line in lines[1:]:
                if not line:
                    continue
                k, v = line.split(':', 1)
                k = k.lower()
                if k in fields:
                    raise ValueError('duplicate handshake field')
                fields[k] = v.strip()
            expected = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            if (fields.get('upgrade', '').lower() != 'websocket'
                    or 'upgrade' not in [v.strip().lower() for v in fields.get('connection', '').split(',')]
                    or fields.get('sec-websocket-accept') != expected
                    or 'sec-websocket-extensions' in fields or 'sec-websocket-protocol' in fields):
                raise ValueError('invalid native upgrade')
            self.socket.settimeout(None)
        except BaseException:
            self.close()
            raise

    def _exact(self, count):
        data = bytearray()
        while len(data) < count:
            chunk = self.socket.recv(count - len(data))
            if not chunk:
                raise EOFError()
            data.extend(chunk)
        return bytes(data)

    def _send(self, opcode, data):
        size = len(data)
        if size > MAX_MESSAGE:
            raise ValueError('oversized native message')
        header = bytes([0x80 | opcode, 0x80 | size]) if size < 126 else (
            bytes([0x80 | opcode, 0xfe]) + struct.pack('!H', size) if size < 65536 else
            bytes([0x80 | opcode, 0xff]) + struct.pack('!Q', size))
        mask = os.urandom(4)
        frame = header + mask + bytes(v ^ mask[i % 4] for i, v in enumerate(data))
        with self.lock:
            self.socket.sendall(frame)

    def send(self, message):
        self._send(1, json.dumps(message, ensure_ascii=False, allow_nan=False).encode('utf-8'))

    def receive(self):
        message, fragmented = bytearray(), False
        while True:
            first, second = self._exact(2)
            final, opcode = bool(first & 0x80), first & 0x0f
            if first & 0x70 or second & 0x80:
                raise ValueError('unsupported native frame flags')
            size = second & 0x7f
            if size == 126:
                size = struct.unpack('!H', self._exact(2))[0]
                if size < 126:
                    raise ValueError('noncanonical native frame length')
            elif size == 127:
                size = struct.unpack('!Q', self._exact(8))[0]
                if size < 65536:
                    raise ValueError('noncanonical native frame length')
            if size > MAX_MESSAGE or opcode >= 8 and (size > 125 or not final):
                raise ValueError('oversized or fragmented control frame')
            payload = self._exact(size)
            if opcode == 8:
                raise EOFError()
            if opcode == 9:
                self._send(10, payload)
                continue
            if opcode == 10:
                continue
            if opcode not in (0, 1) or (opcode == 0) != fragmented:
                raise ValueError('unexpected native fragment')
            if len(message) + size > MAX_MESSAGE:
                raise ValueError('oversized native message')
            message.extend(payload)
            if final:
                result = json.loads(message.decode('utf-8'))
                if not isinstance(result, dict):
                    raise ValueError('invalid native message')
                return result
            fragmented = True

    def close(self):
        try:
            self.socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.socket.close()
