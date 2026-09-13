import asyncio
import io
import json
from types import SimpleNamespace
import unittest

from PIL import Image
from aiohttp import web

from sticker_renderer import render
from stickers import StickerRenderer


def vector_document():
    # Synthetic animated red square; no downloaded artwork is checked in.
    return json.dumps({"v": "5.6.2", "w": 100, "h": 100, "fr": 20, "ip": 0, "op": 20,
        "assets": [], "layers": [{"ty": 4, "ind": 1, "ip": 0, "op": 20, "st": 0,
            "ks": {"o": {"a": 0, "k": 100}, "r": {"a": 0, "k": 0},
                   "p": {"a": 0, "k": [50, 50, 0]}, "a": {"a": 0, "k": [0, 0, 0]},
                   "s": {"a": 0, "k": [100, 100, 100]}},
            "shapes": [{"ty": "rc", "p": {"a": 0, "k": [0, 0]},
                        "s": {"a": 0, "k": [50, 50]}, "r": {"a": 0, "k": 0}},
                       {"ty": "fl", "c": {"a": 0, "k": [1, 0, 0, 1]},
                        "o": {"a": 0, "k": 100}, "r": 1}]}]}).encode()


class Response:
    status = 200
    content = None

    def __init__(self):
        self.content = self

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        pass

    async def iter_chunked(self, _):
        yield vector_document()


class StickerTests(unittest.IsolatedAsyncioTestCase):
    def test_transparent_watch_sized_png(self):
        image = Image.open(io.BytesIO(render(vector_document())))
        self.assertEqual(image.size, (160, 160))
        self.assertEqual(image.convert("RGBA").getpixel((80, 80)), (255, 0, 0, 255))
        self.assertEqual(image.convert("RGBA").getpixel((0, 0))[3], 0)

    def test_external_assets_rejected(self):
        data = json.loads(vector_document())
        data["assets"] = [{"id": "image", "u": "/etc/", "p": "passwd"}]
        with self.assertRaises(ValueError):
            render(json.dumps(data))

    async def test_public_sticker_render_is_cached_and_deduplicated(self):
        urls = []
        def get(url, **kwargs):
            urls.append(url)
            self.assertFalse(kwargs["allow_redirects"])
            return Response()
        renderer = StickerRenderer(SimpleNamespace(get=get))
        try:
            one, two = await asyncio.gather(renderer.render("12345678901234567"),
                                             renderer.render("12345678901234567"))
            self.assertEqual(one, two)
            self.assertEqual(one, await renderer.render("12345678901234567"))
            self.assertEqual(len(urls), 1)
            self.assertEqual(urls[0], "https://cdn.discordapp.com/stickers/12345678901234567.json")
            self.assertTrue(one.startswith(b"\x89PNG"))
        finally:
            await renderer.close()

    async def test_arbitrary_urls_and_invalid_ids_rejected(self):
        renderer = StickerRenderer(None)
        for value in ("https://example.com", "../12345678901234567", "abc", "123"):
            with self.assertRaises(web.HTTPBadRequest):
                await renderer.render(value)
