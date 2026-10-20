#!/usr/bin/env python3
"""JoshDrive encrypted gateway (runs on the 910q, next to the Immich server).

The JoshDrive app opens one WebSocket per TCP connection to wss://drive.unraujoshua.com/t (Cloudflare
-> Bigserver tunnel -> here). Everything inside is end-to-end encrypted with libsodium, so Cloudflare
only relays ciphertext:

  client -> "JD1" | client_eph_pk(32) | device_pk(32) | ts_ms(8) | sig_device(64)
            sig over b"JD1c" + client_eph_pk + ts + server_sign_pk   (device must be registered)
  server -> server_eph_pk(32) | sig_server(64)   sig over b"JD1s" + server_eph_pk + client_eph_pk
  keys    = crypto_kx session keys from the two ephemeral keys (fresh per connection)
  then each side sends its secretstream header, then one secretstream message per WebSocket frame;
  TAG_FINAL ends that direction.

After the handshake the plaintext is relayed to Immich on 127.0.0.1:2283.
"""
import asyncio
import json
import struct
import time
from pathlib import Path

import nacl.bindings as b
from nacl.signing import SigningKey, VerifyKey
from nacl.exceptions import BadSignatureError
import websockets

HOME = Path.home() / "immich" / "gateway"
DEVICES = HOME / "devices.json"          # {"<device_pk hex>": {"user": ..., "addedAt": ...}}
LISTEN = ("127.0.0.1", 8462)
UPSTREAM = ("127.0.0.1", 2283)
TELEMETRY = ("127.0.0.1", 8461)
CHUNK = 64 * 1024
TAG_MSG, TAG_FINAL = b.crypto_secretstream_xchacha20poly1305_TAG_MESSAGE, b.crypto_secretstream_xchacha20poly1305_TAG_FINAL


def server_key():
    path = HOME / "server_sign.seed"
    if not path.exists():
        HOME.mkdir(parents=True, exist_ok=True)
        path.write_bytes(bytes(SigningKey.generate()))
        path.chmod(0o600)
    return SigningKey(path.read_bytes())


SIGN = server_key()
SIGN_PK = bytes(SIGN.verify_key)


def allowed(device_pk):
    try:
        return device_pk.hex() in json.loads(DEVICES.read_text())
    except (OSError, ValueError):
        return False


async def handle(ws):
    hello = await asyncio.wait_for(ws.recv(), 15)
    if not isinstance(hello, bytes) or len(hello) != 3 + 32 + 32 + 8 + 64 or hello[:3] != b"JD1":
        return await ws.close(1008, "bad hello")
    c_eph, dev, ts_raw, sig = hello[3:35], hello[35:67], hello[67:75], hello[75:]
    if abs(time.time() * 1000 - struct.unpack(">Q", ts_raw)[0]) > 5 * 60 * 1000 or not allowed(dev):
        return await ws.close(1008, "unknown device")
    try:
        VerifyKey(dev).verify(b"JD1c" + c_eph + ts_raw + SIGN_PK, sig)
    except BadSignatureError:
        return await ws.close(1008, "bad signature")

    s_eph_pk, s_eph_sk = b.crypto_kx_keypair()
    await ws.send(s_eph_pk + SIGN.sign(b"JD1s" + s_eph_pk + c_eph).signature)
    rx, tx = b.crypto_kx_server_session_keys(s_eph_pk, s_eph_sk, c_eph)
    push = b.crypto_secretstream_xchacha20poly1305_state()
    await ws.send(b.crypto_secretstream_xchacha20poly1305_init_push(push, tx))
    pull = b.crypto_secretstream_xchacha20poly1305_state()
    b.crypto_secretstream_xchacha20poly1305_init_pull(pull, await asyncio.wait_for(ws.recv(), 15), rx)

    # The app's own log reports ride the same tunnel; send those to the telemetry collector.
    first, first_tag = b.crypto_secretstream_xchacha20poly1305_pull(pull, await ws.recv())
    upstream = TELEMETRY if first.startswith((b"POST /telemetry ", b"GET /jd-config ")) else UPSTREAM
    reader, writer = await asyncio.open_connection(*upstream)
    if first:
        writer.write(first)
        await writer.drain()

    async def phone_to_immich():
        # The phone's FINAL only means "nothing more to send". Don't pass a half-close on to Immich:
        # Node closes the whole socket on it and can drop a response it hasn't written yet.
        if first_tag == TAG_FINAL:
            return
        async for frame in ws:
            data, tag = b.crypto_secretstream_xchacha20poly1305_pull(pull, frame)
            if data:
                writer.write(data)
                await writer.drain()
            if tag == TAG_FINAL:
                break

    async def immich_to_phone():
        while data := await reader.read(CHUNK):
            await ws.send(b.crypto_secretstream_xchacha20poly1305_push(push, data, tag=TAG_MSG))
        await ws.send(b.crypto_secretstream_xchacha20poly1305_push(push, b"", tag=TAG_FINAL))

    try:
        await asyncio.gather(phone_to_immich(), immich_to_phone())
    except Exception:
        pass
    finally:
        writer.close()
        await ws.close()


async def main():
    print("server signing key", SIGN_PK.hex(), flush=True)
    async with websockets.serve(handle, *LISTEN, max_size=CHUNK + 1024, ping_interval=30, ping_timeout=60):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
