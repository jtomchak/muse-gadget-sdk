#!/usr/bin/env python3
"""Loopback-only Muse fixture using the independent upstream Python Noise SDK.

No Muse credentials, account traffic, transcription or model inference occur.
Swift integration tests use real URLSession WebSockets and CryptoKit against it.
"""
import argparse
import base64
import hashlib
import json
import pathlib
import socketserver
import struct
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'linux/src'))
from musegadget.noise.noise_xx import NoiseXXResponder
from musegadget.noise.framing import NoiseFrameDecoder, encode_noise_frames
from musegadget.noise.transport import decode_request_envelope, encode_response_envelope
from musegadget.noise.envelope import ServiceFrame, ApplicationResponse, BodyChunk, Reset


class Handler(socketserver.BaseRequestHandler):
    def exact(self, n):
        data = b''
        while len(data) < n:
            more = self.request.recv(n - len(data))
            if not more:
                raise EOFError()
            data += more
        return data

    def read_ws(self):
        header = self.exact(2)
        length = header[1] & 127
        if length == 126:
            length = struct.unpack('!H', self.exact(2))[0]
        elif length == 127:
            length = struct.unpack('!Q', self.exact(8))[0]
        if length > 65535:
            raise ValueError('oversize client frame')
        mask = self.exact(4) if header[1] & 128 else b'\0' * 4
        data = bytes(x ^ mask[i % 4] for i, x in enumerate(self.exact(length)))
        if header[0] & 15 == 8:
            raise EOFError()
        if header[0] & 15 != 2:
            raise ValueError('binary frames required')
        return data

    def write_ws(self, data):
        header = b'\x82' + (bytes([len(data)]) if len(data) < 126 else b'\x7e' + struct.pack('!H', len(data)))
        self.request.sendall(header + data)

    def handle(self):
        try:
            self.request.settimeout(15)
            header = b''
            while not header.endswith(b'\r\n\r\n'):
                header += self.exact(1)
                if len(header) > 32768:
                    raise ValueError('header too large')
            lines = header.decode().split('\r\n')
            scenario = lines[0].split()[1].split('?')[0].strip('/')
            fields = dict(line.split(': ', 1) for line in lines[1:] if ': ' in line)
            if scenario == 'redirect-target':
                raise ValueError('credentialed WebSocket followed a redirect')
            if scenario == 'redirect':
                location = f'ws://127.0.0.1:{self.server.server_address[1]}/redirect-target'
                self.request.sendall(('HTTP/1.1 307 Temporary Redirect\r\nLocation: ' + location + '\r\nContent-Length: 0\r\nConnection: close\r\n\r\n').encode())
                return
            if scenario == 'auth':
                self.request.sendall(b'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                return
            if fields.get('Authorization') != 'Bearer fixture-vm-token':
                raise ValueError('wrong test bearer')
            key = fields['Sec-WebSocket-Key']
            accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
            self.request.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
            noise = NoiseXXResponder()
            noise.initialize()
            self.write_ws(noise.read_message1_and_write_message2(self.read_ws()))
            noise.read_message3(self.read_ws())
            send, recv = noise.split()
            decoder = NoiseFrameDecoder()

            def read():
                while True:
                    envelope = decoder.decode(recv.decrypt_with_ad(b'', self.read_ws()))
                    if envelope is not None:
                        return decode_request_envelope(envelope)

            def emit(frame, corrupt=False):
                for packet in encode_noise_frames(encode_response_envelope(frame)):
                    cipher = send.encrypt_with_ad(b'', packet)
                    if corrupt:
                        cipher = cipher[:-1] + bytes([cipher[-1] ^ 1])
                    self.write_ws(cipher)

            sub = read()
            if sub.kind != 'request' or sub.value.path != '/chat/subscribe' or sub.value.body != b'{}':
                raise ValueError('subscription must come first')
            emit(ServiceFrame.response(1, ApplicationResponse(status=200, body=b'{}\n', end_body=False)))
            chat = read()
            if chat.kind != 'request' or chat.value.path != '/chat/stream' or chat.value.end_body:
                raise ValueError('streamed chat expected')
            body = chat.value.body
            while True:
                chunk = read()
                if chunk.kind != 'body_chunk' or chunk.stream_id != 2:
                    raise ValueError('chat chunk expected')
                body += chunk.value.data
                if len(body) > 700000:
                    raise ValueError('request bound exceeded')
                if chunk.value.end_body:
                    break
            content = json.loads(body)
            if content['output_modality'] != 'text':
                raise ValueError('text output required')
            if 'items' in content:
                item = content['items'][0]
                wav = base64.b64decode(item['data_base64'], validate=True)
                if item['type'] != 'file' or item['mime_type'] != 'audio/wav' or wav[:4] != b'RIFF' or not 9644 <= len(wav) <= 480044:
                    raise ValueError('invalid WAV attachment')
                reply = 'Muse fixture received the voice note.'
            else:
                if content['message'] != 'Hello Muse':
                    raise ValueError('wrong typed fixture request')
                reply = 'Muse fixture received the text.'
            if scenario == 'disconnect':
                return
            if scenario == 'timeout':
                time.sleep(2)
                return
            if scenario == 'reset':
                emit(ServiceFrame.reset(2, Reset(reason='fixture reset')))
                return
            ack = json.dumps({'result': {'message_id': 'user-fixture'}}).encode()
            if scenario != 'early':
                emit(ServiceFrame.response(2, ApplicationResponse(status=200, body=ack, end_body=True)))
            events = [
                {'type': 'event', 'seq': 1, 'event': 'message.assistant', 'payload': {'id': 'other', 'reply_to_message_id': 'other-user', 'content': 'DO NOT SPEAK'}},
                {'type': 'event', 'seq': 2, 'event': 'delta.message_start', 'payload': {'message_id': 'reply-fixture', 'reply_to_message_id': 'user-fixture'}},
                {'type': 'event', 'seq': 3, 'event': 'delta.text_append', 'payload': {'message_id': 'reply-fixture', 'text': reply}},
                {'type': 'event', 'seq': 4, 'event': 'delta.message_done', 'payload': {'message_id': 'reply-fixture'}},
            ]
            # Split NDJSON mid-line to exercise stream boundaries independently
            # of protobuf / WebSocket packet boundaries.
            events = b''.join(json.dumps(event).encode() + b'\n' for event in events)
            for part in [events[:53], events[53:]]:
                emit(ServiceFrame.body_chunk(1, BodyChunk(data=part)), corrupt=scenario == 'tamper')
            if scenario == 'early':
                emit(ServiceFrame.response(2, ApplicationResponse(status=200, body=ack, end_body=True)))
            # Server intentionally keeps subscribe open: client uses the SDK's
            # settle interval instead of requiring a nonexistent turn-end event.
            try:
                self.read_ws()
            except EOFError:
                pass
        except (EOFError, ConnectionError, TimeoutError):
            pass
        except Exception as error:
            print('fixture error:', type(error).__name__, str(error), file=sys.stderr)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port-file', required=True)
    args = parser.parse_args()
    with Server(('127.0.0.1', 0), Handler) as server:
        pathlib.Path(args.port_file).write_text(str(server.server_address[1]))
        server.serve_forever()
