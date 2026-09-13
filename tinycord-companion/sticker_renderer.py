"""Render a bounded, self-contained Lottie document to transparent animated PNG.

Runs as a short-lived subprocess, with no access to gateway credentials/state.
Input is JSON on stdin; output is PNG bytes on stdout. No files or logs.
"""
import io
import json
import math
import sys

from rlottie_python import LottieAnimation

MAX_INPUT = 2 * 1024 * 1024
MAX_OUTPUT = 2 * 1024 * 1024
SIZE = 160
FPS = 20
MAX_FRAMES = 120


def render(document):
    data = json.loads(document)
    if not isinstance(data, dict):
        raise ValueError("Invalid animation")
    # rlottie may load image assets relative to a resource path. Only vector
    # precompositions are accepted; reject embedded or external image resources.
    pending = [data]
    nodes = 0
    while pending:
        value = pending.pop()
        nodes += 1
        if nodes > 100_000:
            raise ValueError("Animation too complex")
        if isinstance(value, dict):
            if any(isinstance(value.get(key), str) for key in ("p", "u")):
                raise ValueError("External resources unsupported")
            pending.extend(value.values())
        elif isinstance(value, list):
            pending.extend(value)
    with LottieAnimation.from_data(data=json.dumps(data)) as animation:
        frame_count = animation.lottie_animation_get_totalframe()
        rate = animation.lottie_animation_get_framerate()
        width, height = animation.lottie_animation_get_size()
        if not (0 < frame_count <= 18000 and math.isfinite(rate) and 0 < rate <= 240
                and 0 < width <= 4096 and 0 < height <= 4096):
            raise ValueError("Invalid animation dimensions or timing")
        duration = frame_count / rate
        count = min(MAX_FRAMES, max(1, math.ceil(duration * min(FPS, rate))))
        size = (max(1, round(SIZE * width / max(width, height))),
                max(1, round(SIZE * height / max(width, height))))
        frames = [animation.render_pillow_frame(
            frame_num=min(frame_count - 1, int(index * frame_count / count)),
            width=size[0], height=size[1],
        ) for index in range(count)]
        output = io.BytesIO()
        frames[0].save(output, format="PNG", save_all=True, append_images=frames[1:],
                       duration=max(20, round(duration * 1000 / count)), loop=0, disposal=0, blend=0)
        result = output.getvalue()
        if len(result) > MAX_OUTPUT:
            raise ValueError("Rendered animation too large")
        return result


if __name__ == "__main__":
    try:
        # Bound CPU and address space in addition to the parent's wall timeout.
        if sys.platform == "linux":
            import resource
            resource.setrlimit(resource.RLIMIT_CPU, (8, 8))
            resource.setrlimit(resource.RLIMIT_AS, (384 * 1024 * 1024, 384 * 1024 * 1024))
        document = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(document) > MAX_INPUT:
            raise ValueError("Animation too large")
        sys.stdout.buffer.write(render(document))
    except Exception:
        sys.exit(1)
