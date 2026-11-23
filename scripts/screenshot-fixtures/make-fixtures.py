#!/usr/bin/env python3
"""Generate only synthetic audio and packets, with reserved demo identifiers."""
import array, json, math, random, socket, struct, sys, wave
from pathlib import Path
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
epoch = 1795435200  # Fixed demo clock; unrelated to a real call.
duration = 36
random.seed(42)
# Alternating, speech-shaped harmonic bursts; no human voice or existing recording.
rate = 16000
channels = [array.array('h'), array.array('h')]
for i in range(rate * duration):
    t = i / rate
    for c in range(2):
        phase = (t + c * 3.1) % 6.2
        gate = max(0, math.sin(math.pi * (phase - .25) / 2.4)) if .25 < phase < 2.65 else 0
        syllable = .35 + .65 * (math.sin(t * 17 + c) ** 2)
        f0 = (130 if c == 0 else 180) + 15 * math.sin(t * 1.8)
        signal = sum(math.sin(2 * math.pi * t * f0 * h) / h * (1 + .4 * math.sin(t * (h + 1))) for h in range(1, 14))
        v = gate * syllable * (.18 * signal + .015 * random.uniform(-1, 1))
        channels[c].append(int(max(-.95, min(.95, v)) * 32767))
for c, samples in enumerate(channels):
    with wave.open(str(out / f'channel-{c}.wav'), 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(samples.tobytes())
stereo = array.array('h')
for a, b in zip(*channels): stereo.extend((a, b))
with wave.open(str(out / 'demo-audio.wav'), 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate); w.writeframes(stereo.tobytes())
# Documentation-only IP ranges; example.com SIP identities.
caller, agent = '192.0.2.10', '198.51.100.20'
records = []
def packet(t, data, reverse=False, media=False):
    src, dst = (agent, caller) if reverse else (caller, agent)
    sp, dp = (6000, 4000) if reverse else (4000, 6000)
    if not media: sp = dp = 5060
    udp = struct.pack('!HHHH', sp, dp, len(data) + 8, 0) + data
    ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, len(udp) + 20, 0, 0, 64, 17, 0, socket.inet_aton(src), socket.inet_aton(dst)) + udp
    records.append((t, bytes.fromhex('0200000000010200000000020800') + ip))
def sip(t, line, seq, reverse=False, sdp=False):
    host, port = (agent, 6000) if reverse else (caller, 4000)
    body = f'v=0\r\nc=IN IP4 {host}\r\nm=audio {port} RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n' if sdp else ''
    text = f'{line}\r\nVia: SIP/2.0/UDP {host}:5060;branch=z9hG4bK-demo-{seq[0]}\r\nFrom: <sip:caller@example.com>;tag=demo-caller\r\nTo: <sip:assistant@example.com>;tag=demo-agent\r\nCall-ID: demo-support-call@example.com\r\nCSeq: {seq}\r\nContent-Type: application/sdp\r\nContent-Length: {len(body)}\r\n\r\n{body}'
    packet(t, text.encode(), reverse)
sip(0, 'INVITE sip:assistant@example.com SIP/2.0', '1 INVITE', sdp=True)
sip(.02, 'SIP/2.0 100 Trying', '1 INVITE', True)
sip(.09, 'SIP/2.0 180 Ringing', '1 INVITE', True)
sip(.35, 'SIP/2.0 200 OK', '1 INVITE', True, True)
sip(.37, 'ACK sip:assistant@example.com SIP/2.0', '1 ACK')
for reverse in (False, True):
    prev = 0
    for i in range(1750):
        t = .6 + i * .02 + (.01 if reverse else 0) + .0003 * math.sin(i * .37)
        if not reverse and i == 610: t += .66
        t = max(t, prev + .005); prev = t
        if not reverse and 1000 <= i <= 1002: continue
        ssrc = 0x10203040 if reverse else (0x50607080 if i < 1100 else 0x50607081)
        rtp = struct.pack('!BBHII', 0x80, 0, i, i * 160, ssrc) + bytes([0xff] * 160)
        packet(t, rtp, reverse, True)
sip(35.7, 'BYE sip:assistant@example.com SIP/2.0', '2 BYE')
sip(35.72, 'SIP/2.0 200 OK', '2 BYE', True)
with (out / 'support-call-demo.pcap').open('wb') as f:
    f.write(struct.pack('<IHHIIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
    for t, data in sorted(records):
        us = round(t * 1e6)
        f.write(struct.pack('<IIII', epoch + us // 1000000, us % 1000000, len(data), len(data)) + data)
(out / 'fixture.json').write_text(json.dumps({'epoch': epoch, 'duration': duration}))
