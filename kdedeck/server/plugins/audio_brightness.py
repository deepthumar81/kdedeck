import logging
import re
import asyncio
from kdedeck.server.plugins.base import run_command_sync, run_command_async

logger = logging.getLogger("kdedeck.audio_brightness")

class AudioBrightnessPlugin:
    _cached_volume = 50
    _cached_brightness = 70
    _brightness_lock = asyncio.Lock()
    _last_brightness_target = None

    @classmethod
    def get_volume(cls):
        try:
            output = run_command_sync("pactl get-sink-volume @DEFAULT_SINK@")
            match = re.search(r"(\d+)%", output)
            if match:
                cls._cached_volume = int(match.group(1))
        except Exception:
            pass
        return cls._cached_volume

    @classmethod
    async def set_volume(cls, level):
        level = max(0, min(100, int(level)))
        cls._cached_volume = level
        # Run non-blocking in thread pool
        asyncio.create_task(run_command_async(f"pactl set-sink-volume @DEFAULT_SINK@ {level}%"))
        return level

    @classmethod
    async def toggle_mute(cls):
        await run_command_async("pactl set-sink-mute @DEFAULT_SINK@ toggle")
        output = run_command_sync("pactl get-sink-mute @DEFAULT_SINK@")
        return "yes" in output.lower()

    @classmethod
    def get_brightness(cls):
        try:
            out = run_command_sync("brightnessctl g 2>/dev/null")
            max_b = run_command_sync("brightnessctl m 2>/dev/null")
            if out and max_b and int(max_b) > 0:
                cls._cached_brightness = int((int(out) / int(max_b)) * 100)
                return cls._cached_brightness

            out = run_command_sync("ddcutil getvcp 10 2>/dev/null")
            match = re.search(r"current value =\s*(\d+)", out)
            if match:
                cls._cached_brightness = int(match.group(1))
        except Exception:
            pass
        return cls._cached_brightness

    @classmethod
    async def set_brightness(cls, level):
        level = max(5, min(100, int(level)))
        cls._cached_brightness = level
        cls._last_brightness_target = level

        # Asynchronous non-blocking worker queue to prevent ddcutil from freezing system
        asyncio.create_task(cls._apply_brightness_worker(level))
        return level

    @classmethod
    async def _apply_brightness_worker(cls, level):
        async with cls._brightness_lock:
            # If target changed while waiting, use latest target
            target = cls._last_brightness_target or level
            # Try fast brightnessctl first
            res = await run_command_async(f"brightnessctl s {target}% 2>/dev/null")
            if not res:
                # Run ddcutil in thread pool without blocking event loop
                await asyncio.to_thread(run_command_sync, f"ddcutil setvcp 10 {target} --noverify 2>/dev/null")
