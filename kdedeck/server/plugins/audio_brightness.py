import logging
import re
import asyncio
from kdedeck.server.plugins.base import run_command_sync, run_command_async

logger = logging.getLogger("kdedeck.audio_brightness")

class AudioBrightnessPlugin:
    _cached_volume = 50
    _cached_brightness = 70

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
        except Exception:
            pass
        return cls._cached_brightness

    @classmethod
    async def set_brightness(cls, level):
        level = max(5, min(100, int(level)))
        cls._cached_brightness = level
        # Fast non-blocking brightnessctl call only (no ddcutil hardware I2C calls)
        asyncio.create_task(run_command_async(f"brightnessctl s {level}% 2>/dev/null"))
        return level
