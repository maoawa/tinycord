"""Ephemeral Discord gateway sessions, controlled exclusively through HTTPS.

No Discord token is retained after IDENTIFY. A lost socket requires a fresh
authentication request from the Watch; this service deliberately never resumes.
"""

import asyncio
from collections import deque
from contextlib import suppress
import hashlib
import json
import os
import random
import re
import time
from urllib.parse import urlsplit

from aiohttp import ClientSession, ClientTimeout, WSMsgType, web
from stickers import RENDERER, StickerRenderer, sticker_image

LEASE_SECONDS = 10
CONNECT_TIMEOUT_SECONDS = 25
EVENT_LIMIT = 128
EVENT_BYTES_LIMIT = 2 * 1024 * 1024
SESSION_LIMIT = 100
CREATE_LIMIT_PER_MINUTE = 30
PRESENCE_TEXT = "Active on Apple Watch"
EVENT_TYPES = {"MESSAGE_CREATE", "MESSAGE_DELETE", "TYPING_START"}

CLIENT = web.AppKey("client", ClientSession)
SESSIONS = web.AppKey("sessions", dict)
GATEWAY_URL = web.AppKey("gateway_url", str)
LIMITS = web.AppKey("limits", dict)
CREATION_ATTEMPTS = web.AppKey("creation_attempts", deque)
CANCELLED_SESSIONS = web.AppKey("cancelled_sessions", dict)


def presence(status="online"):
    # A regular activity is separate from the account's Custom Status (type 4).
    activity = {"name": PRESENCE_TEXT, "type": 0}
    return {"status": status, "since": 0, "afk": False, "activities": [activity]}


class GatewaySession:
    def __init__(self, client, gateway_url):
        self.client = client
        self.gateway_url = gateway_url
        self.ws = None
        self.reader = None
        self.heartbeat = None
        self.sequence = None
        self.acked = True
        self.state = "connecting"
        self.error = None
        self.created_at = time.monotonic()
        self.deadline = time.monotonic() + CONNECT_TIMEOUT_SECONDS + 5
        self.ready = asyncio.Event()
        self.changed = asyncio.Event()
        self.events = deque()
        self.event_bytes = 0
        self.cursor = 0
        self.dropped_through = 0
        self.polling = False
        self.user_id = None
        self.availability = "online"

    async def start(self, token, is_bot):
        try:
            self.ws = await self.client.ws_connect(
                self.gateway_url, max_msg_size=32 * 1024 * 1024,
                headers={"Origin": "https://discord.com"},
            )
            hello = await self.ws.receive_json(timeout=10)
            if hello.get("op") != 10:
                raise ValueError("Expected HELLO")
            interval = float(hello["d"]["heartbeat_interval"]) / 1000
            if not 1 <= interval <= 120:
                raise ValueError("Invalid heartbeat interval")
            properties = {"os": "iOS", "browser": "Discord iOS", "device": "iPhone"}
            # User availability is read from READY before publishing activity.
            identify = {"token": token, "properties": properties}
            if is_bot:
                identify["presence"] = presence()
                identify["intents"] = (1 << 12) | (1 << 13) | (1 << 14) | (1 << 15)
                identify["properties"] = {"os": "linux", "browser": "TinyCord", "device": "TinyCord"}
            try:
                await self.ws.send_json({"op": 2, "d": identify})
            finally:
                identify.clear()
                token = None
            self.reader = asyncio.create_task(self.read_events())
            self.heartbeat = asyncio.create_task(self.send_heartbeats(interval))
            await asyncio.wait_for(self.ready.wait(), timeout=15)
            if self.state != "connected":
                raise ValueError("Gateway rejected session")
            # Refresh activity explicitly after READY; never write account settings
            # or a Custom Status activity (type 4).
            await self.ws.send_json({"op": 3, "d": presence(self.availability)})
        finally:
            token = None

    async def read_events(self):
        try:
            async for message in self.ws:
                if message.type not in (WSMsgType.TEXT, WSMsgType.BINARY):
                    break
                payload = json.loads(message.data)
                op = payload.get("op")
                if payload.get("s") is not None:
                    self.sequence = payload["s"]
                if op == 11:
                    self.acked = True
                elif op == 1:
                    await self.ws.send_json({"op": 1, "d": self.sequence})
                elif op in (7, 9):
                    break  # Re-authentication must come from the Watch.
                elif op == 0:
                    name, data = payload.get("t"), payload.get("d")
                    if name == "READY":
                        self.user_id = data["user"]["id"]
                        settings = data.get("user_settings") or {}
                        status = settings.get("status") if isinstance(settings, dict) else None
                        if status in {"online", "idle", "dnd", "invisible", "offline"}:
                            self.availability = "invisible" if status == "offline" else status
                        self.state = "connected"
                        self.ready.set()
                    elif name == "USER_SETTINGS_UPDATE" and isinstance(data, dict):
                        status = data.get("status")
                        if status in {"online", "idle", "dnd", "invisible", "offline"}:
                            self.availability = "invisible" if status == "offline" else status
                            await self.ws.send_json({"op": 3, "d": presence(self.availability)})
                    elif name in EVENT_TYPES:
                        self.cursor += 1
                        event = {"id": self.cursor, "type": name, "data": data}
                        size = len(json.dumps(event).encode())
                        if size > EVENT_BYTES_LIMIT:
                            self.dropped_through = self.cursor
                            self.events.clear()
                            self.event_bytes = 0
                        else:
                            self.events.append((event, size))
                            self.event_bytes += size
                            while len(self.events) > EVENT_LIMIT or self.event_bytes > EVENT_BYTES_LIMIT:
                                removed, count = self.events.popleft()
                                self.dropped_through = removed["id"]
                                self.event_bytes -= count
                        self.changed.set()
                # READY can itself contain refreshed credentials. Don't leave
                # decoded payloads or raw frames in the suspended reader locals.
                payload = data = message = settings = status = None
        except (Exception, asyncio.CancelledError):
            pass  # Never log gateway payloads or exception details.
        finally:
            self.state = "disconnected"
            self.error = "Gateway disconnected; open a new session."
            self.ready.set()
            self.changed.set()
            if self.heartbeat:
                self.heartbeat.cancel()
            await self.ws.close()

    async def send_heartbeats(self, interval):
        try:
            await asyncio.sleep(interval * random.random())
            while self.state in ("connecting", "connected"):
                if not self.acked:
                    await self.ws.close()
                    return
                self.acked = False
                await self.ws.send_json({"op": 1, "d": self.sequence})
                await asyncio.sleep(interval)
        except (Exception, asyncio.CancelledError):
            if self.ws and not self.ws.closed:
                await self.ws.close()

    async def close(self):
        self.state = "disconnected"
        self.ready.set()
        self.changed.set()
        tasks = [task for task in (self.reader, self.heartbeat) if task]
        for task in tasks:
            task.cancel()
        if self.ws:
            await self.ws.close()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        self.events.clear()
        self.event_bytes = 0


def session_key(request):
    bearer = request.headers.get("Authorization", "")
    if not re.fullmatch(r"Bearer [A-Za-z0-9_-]{40,128}", bearer):
        raise web.HTTPUnauthorized(text="Session credential required")
    # Store only a digest of the random relay credential, never a Discord token.
    return hashlib.sha256(bearer[7:].encode()).hexdigest()


@web.middleware
async def secure_requests(request, handler):
    # The container has no published port. Only Caddy can reach this listener;
    # Caddy overwrites this header rather than trusting a client-supplied value.
    if request.headers.get("X-Forwarded-Proto") != "https":
        return web.json_response({"error": "HTTPS required"}, status=426,
                                 headers={"Cache-Control": "no-store"})
    try:
        response = await handler(request)
    except web.HTTPException as exc:
        response = web.json_response({"error": exc.text}, status=exc.status)
    except Exception:
        response = web.json_response({"error": "Presence service unavailable"}, status=502)
    response.headers["Cache-Control"] = "no-store"
    return response


async def create_session(request):
    key = session_key(request)
    sessions = request.app[SESSIONS]
    if key in request.app[CANCELLED_SESSIONS]:
        raise web.HTTPConflict(text="Session cancelled; use a new session credential")
    # Idempotent retries don't open duplicate Discord sessions or renew leases.
    if key in sessions:
        item = sessions[key]
        return web.json_response({"state": item.state, "leaseSeconds": LEASE_SECONDS})
    if len(sessions) >= request.app[LIMITS]["sessions"]:
        raise web.HTTPServiceUnavailable(text="Presence service at capacity")
    attempts = request.app[CREATION_ATTEMPTS]
    now = time.monotonic()
    while attempts and attempts[0] < now - 60:
        attempts.popleft()
    if len(attempts) >= CREATE_LIMIT_PER_MINUTE:
        raise web.HTTPTooManyRequests(text="Too many connection attempts; try again later")
    attempts.append(now)
    # Do not use request.json/read: aiohttp caches those bytes on the request.
    raw = bytearray()
    async with asyncio.timeout(10):
        async for chunk in request.content.iter_chunked(1024):
            raw.extend(chunk)
            if len(raw) > 8192:
                raw.clear()
                raise web.HTTPRequestEntityTooLarge(max_size=8192, actual_size=8193)
    # The loop's final chunk can contain the token too.
    chunk = None
    try:
        body = json.loads(raw)
    except (ValueError, UnicodeError):
        raise web.HTTPBadRequest(text="Invalid JSON") from None
    finally:
        raw.clear()
    if (not isinstance(body, dict) or not isinstance(body.get("token"), str)
            or not 1 <= len(body["token"]) <= 4096 or not isinstance(body.get("isBot", False), bool)):
        if isinstance(body, dict):
            body.clear()
        raise web.HTTPBadRequest(text="A token and boolean isBot are required")
    # Recheck after reading the body; concurrent creation must not exceed capacity.
    if (key in sessions or key in request.app[CANCELLED_SESSIONS]
            or len(sessions) >= request.app[LIMITS]["sessions"]):
        body.clear()
        raise web.HTTPConflict(text="Retry session creation")
    item = GatewaySession(request.app[CLIENT], request.app[GATEWAY_URL])
    sessions[key] = item
    try:
        async with asyncio.timeout(CONNECT_TIMEOUT_SECONDS):
            await item.start(body.pop("token"), body.get("isBot", False))
        if sessions.get(key) is not item:
            raise ValueError("Session cancelled")
        if request.transport is None or request.transport.is_closing():
            raise ValueError("Watch disconnected")
        if any(other.user_id == item.user_id and other.created_at > item.created_at
               for other in sessions.values() if other is not item):
            raise ValueError("A newer session already connected")
        # A single live relay per Discord account; replacing one closes the old socket.
        for old_key, old_item in list(sessions.items()):
            if old_key != key and old_item.user_id == item.user_id:
                sessions.pop(old_key, None)
                await old_item.close()
        item.deadline = time.monotonic() + LEASE_SECONDS
        return web.json_response({"state": "connected", "leaseSeconds": LEASE_SECONDS}, status=201)
    except (Exception, asyncio.CancelledError):
        if sessions.get(key) is item:
            sessions.pop(key, None)
        await item.close()
        raise web.HTTPBadGateway(text="Discord authentication or connection failed") from None
    finally:
        body.clear()


def get_session(request):
    key = session_key(request)
    item = request.app[SESSIONS].get(key)
    if item is None or item.deadline <= time.monotonic():
        raise web.HTTPNotFound(text="Session expired; authenticate again")
    return item


async def renew_session(request):
    item = get_session(request)
    if item.state != "connected":
        raise web.HTTPConflict(text="Gateway disconnected; authenticate again")
    item.deadline = time.monotonic() + LEASE_SECONDS
    return web.json_response({"state": item.state, "leaseSeconds": LEASE_SECONDS})


async def delete_session(request):
    key = session_key(request)
    # DELETE may overtake a cancelled POST on a different HTTP connection.
    # A short, bounded tombstone prevents that late POST from going online.
    cancelled = request.app[CANCELLED_SESSIONS]
    cancelled[key] = time.monotonic() + 120
    while len(cancelled) > 4096:
        cancelled.pop(next(iter(cancelled)))
    item = request.app[SESSIONS].pop(key, None)
    if item:
        await item.close()
    return web.Response(status=204)


async def poll_events(request):
    item = get_session(request)
    try:
        after = int(request.query.get("after", "0"))
        if after < 0 or after > item.cursor:
            raise ValueError()
    except ValueError:
        raise web.HTTPBadRequest(text="Invalid event cursor") from None
    if item.polling:
        raise web.HTTPConflict(text="Only one event poll per session")
    item.polling = True
    try:
        item.changed.clear()
        if item.cursor <= after and item.state == "connected":
            with suppress(asyncio.TimeoutError):
                await asyncio.wait_for(item.changed.wait(), timeout=20)
        return web.json_response({
            "state": item.state,
            "events": [event for event, _ in item.events if event["id"] > after],
            "cursor": item.cursor,
            "reset": after < item.dropped_through,
        })
    finally:
        item.polling = False


async def reap_sessions(app):
    while True:
        await asyncio.sleep(0.25)
        for key, deadline in list(app[CANCELLED_SESSIONS].items()):
            if deadline <= time.monotonic():
                app[CANCELLED_SESSIONS].pop(key, None)
        for key, item in list(app[SESSIONS].items()):
            if item.deadline <= time.monotonic():
                app[SESSIONS].pop(key, None)
                await item.close()


async def lifecycle(app):
    async with ClientSession(timeout=ClientTimeout(total=25, sock_connect=10)) as client:
        app[CLIENT] = client
        app[RENDERER] = StickerRenderer(client)
        reaper = asyncio.create_task(reap_sessions(app))
        yield
        reaper.cancel()
        with suppress(asyncio.CancelledError):
            await reaper
        await asyncio.gather(*(item.close() for item in app[SESSIONS].values()))
        app[SESSIONS].clear()
        await app[RENDERER].close()


async def health_check(_):
    return web.json_response({"status": "ok"})


def create_app(gateway_url="wss://gateway.discord.gg/?v=10&encoding=json", session_limit=SESSION_LIMIT):
    app = web.Application(middlewares=[secure_requests], client_max_size=8192)
    app[GATEWAY_URL] = gateway_url
    app[SESSIONS] = {}
    app[CREATION_ATTEMPTS] = deque()
    app[CANCELLED_SESSIONS] = {}
    app[LIMITS] = {"sessions": session_limit}
    app.cleanup_ctx.append(lifecycle)
    app.router.add_post("/v1/session", create_session)
    app.router.add_put("/v1/session", renew_session)
    app.router.add_delete("/v1/session", delete_session)
    app.router.add_get("/v1/events", poll_events)
    app.router.add_get("/v1/stickers/{sticker_id}.png", sticker_image)
    app.router.add_get("/healthz", health_check)
    return app


if __name__ == "__main__":
    gateway = os.environ.get("DISCORD_GATEWAY_URL", "wss://gateway.discord.gg/?v=10&encoding=json")
    parts = urlsplit(gateway)
    if parts.scheme != "wss" or not parts.hostname or parts.username or parts.password or parts.fragment:
        raise SystemExit("DISCORD_GATEWAY_URL must be a wss:// URL without credentials")
    # No access logs, body logging, persisted state, or exception tracebacks.
    web.run_app(create_app(gateway), host=os.environ.get("BIND_HOST", "127.0.0.1"),
                port=int(os.environ.get("PORT", "8080")), access_log=None, print=None)
