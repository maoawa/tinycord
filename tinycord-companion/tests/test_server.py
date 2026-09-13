import asyncio
import json
import time
import unittest
from unittest.mock import patch

from aiohttp import web, WSMsgType
from aiohttp.test_utils import TestClient, TestServer

import server


class CompanionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.identifies = []
        self.sockets = []
        self.heartbeats = 0
        self.reject = False
        self.ack_heartbeats = True
        self.ready_gates = {}
        self.presence_updates = []
        self.availability = "online"

        async def gateway(request):
            ws = web.WebSocketResponse()
            await ws.prepare(request)
            self.sockets.append(ws)
            await ws.send_json({"op": 10, "d": {"heartbeat_interval": 1000}})
            identify = await ws.receive_json()
            self.identifies.append(identify)
            if gate := self.ready_gates.get(len(self.sockets)):
                await gate.wait()
            if self.reject:
                await ws.close(code=4004)
                return ws
            await ws.send_json({"op": 0, "s": 1, "t": "READY", "d": {
                "user": {"id": "123"}, "session_id": "discord-session", "token": "not-forwarded",
                "user_settings": {"status": self.availability, "custom_status": {"text": "Keep my status"}}
            }})
            async for message in ws:
                if message.type == WSMsgType.TEXT and json.loads(message.data).get("op") == 3:
                    self.presence_updates.append(json.loads(message.data)["d"])
                if message.type == WSMsgType.TEXT and json.loads(message.data).get("op") == 1:
                    self.heartbeats += 1
                    if self.ack_heartbeats:
                        await ws.send_json({"op": 11})
            return ws

        upstream = web.Application()
        upstream.router.add_get("/gateway", gateway)
        self.gateway = TestServer(upstream)
        await self.gateway.start_server()
        self.app = server.create_app(str(self.gateway.make_url("/gateway")).replace("http:", "ws:"))
        self.client = TestClient(TestServer(self.app))
        await self.client.start_server()
        self.headers = {"X-Forwarded-Proto": "https", "Authorization": "Bearer " + "a" * 64}

    async def asyncTearDown(self):
        await self.client.close()
        await self.gateway.close()

    async def create(self, **kwargs):
        response = await self.client.post("/v1/session", headers=self.headers,
                                          json={"token": "synthetic-discord-token", "isBot": False, **kwargs})
        self.assertEqual(response.status, 201, await response.text())
        return next(iter(self.app[server.SESSIONS].values()))

    async def wait_for(self, predicate):
        async with asyncio.timeout(3):
            while not predicate():
                await asyncio.sleep(0.01)

    async def test_https_and_session_auth_required(self):
        response = await self.client.post("/v1/session", json={"token": "never-forward"})
        self.assertEqual(response.status, 426)
        response = await self.client.get("/v1/events", headers={"X-Forwarded-Proto": "https"})
        self.assertEqual(response.status, 401)
        self.assertFalse(self.identifies)

    async def test_mobile_presence_and_no_retained_discord_token(self):
        item = await self.create()
        identify = self.identifies[0]["d"]
        self.assertEqual(identify["properties"]["browser"], "Discord iOS")
        self.assertNotIn("presence", identify)
        await self.wait_for(lambda: self.presence_updates)
        activity = self.presence_updates[0]
        self.assertEqual(activity["activities"], [{"name": "Active on Apple Watch", "type": 0}])
        self.assertEqual(activity["status"], "online")
        self.assertNotIn("custom_status", activity)
        self.assertNotIn("intents", identify)
        self.assertNotIn("synthetic-discord-token", repr(vars(item)))
        self.assertFalse(hasattr(item, "token"))
        self.assertEqual(list(item.events), [])  # READY (including its token) is not buffered.
        self.assertNotIn("not-forwarded", repr(item.reader.get_coro().cr_frame.f_locals))

    async def test_events_cursor_replay_and_delete(self):
        item = await self.create()
        payload = {"id": "42", "channel_id": "7"}
        await self.sockets[0].send_json({"op": 0, "s": 2, "t": "MESSAGE_DELETE", "d": payload})
        await self.wait_for(lambda: item.cursor == 1)
        for _ in range(2):
            response = await self.client.get("/v1/events?after=0", headers=self.headers)
            data = await response.json()
            self.assertEqual(data["events"][0]["data"], payload)
            self.assertEqual(data["cursor"], 1)
            self.assertFalse(data["reset"])
            self.assertEqual(response.headers["Cache-Control"], "no-store")
        response = await self.client.delete("/v1/session", headers=self.headers)
        self.assertEqual(response.status, 204)
        self.assertFalse(self.app[server.SESSIONS])
        self.assertTrue(item.ws.closed)

    async def test_poll_does_not_extend_lease_but_active_renewal_does(self):
        item = await self.create()
        before = item.deadline
        await self.sockets[0].send_json({"op": 0, "s": 2, "t": "TYPING_START", "d": {}})
        await self.wait_for(lambda: item.cursor == 1)
        await self.client.get("/v1/events", headers=self.headers)
        self.assertEqual(item.deadline, before)
        await asyncio.sleep(0.01)
        response = await self.client.put("/v1/session", headers=self.headers)
        self.assertEqual(response.status, 200)
        self.assertGreater(item.deadline, before)

    async def test_expiry_closes_gateway_without_watch_disconnect(self):
        item = await self.create()
        item.deadline = time.monotonic() - 1
        response = await self.client.get("/v1/events", headers=self.headers)
        self.assertEqual(response.status, 404)
        await self.wait_for(lambda: not self.app[server.SESSIONS])
        await self.wait_for(lambda: item.ws.closed)

    async def test_overflow_instructs_watch_to_resync_rest(self):
        item = await self.create()
        with patch.object(server, "EVENT_LIMIT", 2):
            for seq in range(1, 4):
                await self.sockets[0].send_json({"op": 0, "s": seq, "t": "MESSAGE_DELETE", "d": {"id": str(seq)}})
            await self.wait_for(lambda: item.cursor == 3)
        response = await self.client.get("/v1/events?after=0", headers=self.headers)
        data = await response.json()
        self.assertTrue(data["reset"])
        self.assertEqual([event["id"] for event in data["events"]], [2, 3])

    async def test_disconnect_requires_watch_reauthentication(self):
        item = await self.create()
        await self.sockets[0].send_json({"op": 7})
        await self.wait_for(lambda: item.state == "disconnected")
        response = await self.client.get("/v1/events", headers=self.headers)
        self.assertEqual((await response.json())["state"], "disconnected")
        response = await self.client.put("/v1/session", headers=self.headers)
        self.assertEqual(response.status, 409)
        self.assertEqual(len(self.identifies), 1)

    async def test_failed_auth_cleans_session_and_sanitizes_errors(self):
        self.reject = True
        response = await self.client.post("/v1/session", headers=self.headers,
                                          json={"token": "synthetic-discord-token"})
        self.assertEqual(response.status, 502)
        self.assertNotIn("synthetic-discord-token", await response.text())
        self.assertFalse(self.app[server.SESSIONS])

    async def test_replacement_closes_previous_account_session(self):
        first = await self.create()
        self.headers["Authorization"] = "Bearer " + "b" * 64
        await self.create()
        self.assertTrue(first.ws.closed)
        self.assertEqual(len(self.app[server.SESSIONS]), 1)

    async def test_session_secret_isolation_and_idempotence(self):
        await self.create()
        response = await self.client.post("/v1/session", headers=self.headers, json={})
        self.assertEqual(response.status, 200)
        self.assertEqual(len(self.identifies), 1)
        other = {**self.headers, "Authorization": "Bearer " + "z" * 64}
        response = await self.client.get("/v1/events", headers=other)
        self.assertEqual(response.status, 404)
        await self.client.delete("/v1/session", headers=other)
        self.assertEqual(len(self.app[server.SESSIONS]), 1)

    async def test_invalid_and_oversized_body(self):
        for body, status in [("{}", 400), ('{"token":false}', 400), ('{"token":"' + 'a' * 9000 + '"}', 413)]:
            response = await self.client.post("/v1/session", headers=self.headers, data=body)
            self.assertEqual(response.status, status)
        self.assertFalse(self.identifies)

    async def test_missing_heartbeat_ack_disconnects(self):
        self.ack_heartbeats = False
        item = await self.create()
        await self.wait_for(lambda: self.heartbeats > 0)
        await self.wait_for(lambda: item.state == "disconnected")

    async def test_bot_also_uses_activity(self):
        await self.create(isBot=True)
        identify = self.identifies[0]["d"]
        self.assertIn("intents", identify)
        self.assertEqual(identify["presence"]["activities"], [{"name": "Active on Apple Watch", "type": 0}])

    async def test_connection_rate_and_capacity_limits(self):
        self.app[server.LIMITS]["sessions"] = 0
        response = await self.client.post("/v1/session", headers=self.headers, json={"token": "test"})
        self.assertEqual(response.status, 503)
        self.app[server.LIMITS]["sessions"] = 100
        with patch.object(server, "CREATE_LIMIT_PER_MINUTE", 0):
            response = await self.client.post("/v1/session", headers=self.headers, json={"token": "test"})
            self.assertEqual(response.status, 429)

    async def test_delete_before_create_prevents_late_authentication(self):
        await self.client.delete("/v1/session", headers=self.headers)
        response = await self.client.post("/v1/session", headers=self.headers,
                                          json={"token": "synthetic-discord-token"})
        self.assertEqual(response.status, 409)
        self.assertFalse(self.identifies)

    async def test_activity_preserves_reported_do_not_disturb(self):
        self.availability = "dnd"
        await self.create()
        await self.wait_for(lambda: self.presence_updates)
        self.assertEqual(self.presence_updates[0]["status"], "dnd")
        self.assertTrue(all(a["type"] != 4 for a in self.presence_updates[0]["activities"]))

    async def test_ten_second_lease_is_reset_after_authentication(self):
        item = await self.create()
        self.assertEqual(server.LEASE_SECONDS, 10)
        self.assertAlmostEqual(item.deadline - time.monotonic(), 10, delta=0.5)
        await self.client.put("/v1/session", headers=self.headers)
        self.assertAlmostEqual(item.deadline - time.monotonic(), 10, delta=0.5)

    async def test_slow_old_connection_cannot_replace_a_newer_session(self):
        gate = self.ready_gates[1] = asyncio.Event()
        old_request = asyncio.ensure_future(self.client.post("/v1/session", headers=self.headers,
                                              json={"token": "synthetic-discord-token"}))
        try:
            await self.wait_for(lambda: len(self.identifies) == 1)
            self.headers["Authorization"] = "Bearer " + "b" * 64
            await self.create()
            newest = max(self.app[server.SESSIONS].values(), key=lambda item: item.created_at)
            gate.set()
            response = await old_request
            self.assertEqual(response.status, 502)
            self.assertEqual(len(self.app[server.SESSIONS]), 1)
            self.assertIs(next(iter(self.app[server.SESSIONS].values())), newest)
            self.assertFalse(newest.ws.closed)
        finally:
            gate.set()
            if not old_request.done():
                old_request.cancel()
                await asyncio.gather(old_request, return_exceptions=True)


if __name__ == "__main__":
    unittest.main()
