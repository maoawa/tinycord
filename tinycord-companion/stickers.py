"""Public Discord Lottie stickers rendered for watchOS. Never accepts a URL/token."""
import asyncio
from collections import OrderedDict
from pathlib import Path
import re
import sys

from aiohttp import web

MAX_INPUT = 2 * 1024 * 1024
MAX_OUTPUT = 2 * 1024 * 1024
MAX_CACHE_BYTES = 16 * 1024 * 1024


class StickerRenderer:
    def __init__(self, client):
        self.client = client
        self.cache = OrderedDict()
        self.cache_bytes = 0
        self.jobs = {}

    async def render(self, sticker_id):
        if not re.fullmatch(r"[0-9]{17,20}", sticker_id):
            raise web.HTTPBadRequest(text="Invalid sticker ID")
        if sticker_id in self.cache:
            self.cache.move_to_end(sticker_id)
            return self.cache[sticker_id]
        if sticker_id not in self.jobs:
            if len(self.jobs) >= 1:
                raise web.HTTPServiceUnavailable(text="Sticker renderer busy; retry shortly")
            self.jobs[sticker_id] = asyncio.create_task(self._load(sticker_id))
            self.jobs[sticker_id].add_done_callback(lambda task: self._finished(sticker_id, task))
        return await asyncio.shield(self.jobs[sticker_id])

    def _finished(self, sticker_id, task):
        self.jobs.pop(sticker_id, None)
        if not task.cancelled():
            task.exception()  # Consume failures even if the requesting Watch left.

    async def _load(self, sticker_id):
        # Fixed trusted upstream; IDs cannot select hosts, paths or local files.
        async with self.client.get(f"https://cdn.discordapp.com/stickers/{sticker_id}.json",
                                   allow_redirects=False) as response:
            if response.status == 404:
                raise web.HTTPNotFound(text="Sticker not found")
            if response.status != 200:
                raise web.HTTPBadGateway(text="Sticker download failed")
            document = bytearray()
            async for chunk in response.content.iter_chunked(65536):
                document.extend(chunk)
                if len(document) > MAX_INPUT:
                    raise web.HTTPBadGateway(text="Sticker exceeds size limit")
        process = await asyncio.create_subprocess_exec(
            sys.executable, str(Path(__file__).with_name("sticker_renderer.py")),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        try:
            output, _ = await asyncio.wait_for(process.communicate(document), timeout=10)
            if process.returncode or len(output) > MAX_OUTPUT or not output.startswith(b"\x89PNG\r\n\x1a\n"):
                raise web.HTTPUnprocessableEntity(text="Sticker cannot be rendered")
        except BaseException:
            if process.returncode is None:
                process.kill()
                await process.wait()
            raise
        self.cache[sticker_id] = output
        self.cache_bytes += len(output)
        while len(self.cache) > 32 or self.cache_bytes > MAX_CACHE_BYTES:
            _, old = self.cache.popitem(last=False)
            self.cache_bytes -= len(old)
        return output

    async def close(self):
        tasks = list(self.jobs.values())
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self.cache.clear()


RENDERER = web.AppKey("sticker_renderer", StickerRenderer)


async def sticker_image(request):
    output = await request.app[RENDERER].render(request.match_info["sticker_id"])
    return web.Response(body=output, content_type="image/png")
