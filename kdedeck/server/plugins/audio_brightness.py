import logging
import re
from kdedeck.server.plugins.base import run_command_sync, run_command_async

logger = logging.getLogger("kdedeck.audio_brightness")

class AudioBrightnessPlugin:
    @staticmethod
    def get_volume():
        output = run_command_sync("pactl get-sink-volume @DEFAULT_SINK@")
        match = re.search(r"(\d+)%", output)
        if match:
            return int(match.group(1))
        return 50

    @staticmethod
    async def set_volume(level):
        level = max(0, min(100, int(level)))
        await run_command_async(f"pactl set-sink-volume @DEFAULT_SINK@ {level}%")
        return level

    @staticmethod
    async def toggle_mute():
        await run_command_async("pactl set-sink-mute @DEFAULT_SINK@ toggle")
        output = run_command_sync("pactl get-sink-mute @DEFAULT_SINK@")
        return "yes" in output.lower()

    @staticmethod
    def get_brightness():
        # Try brightnessctl first
        out = run_command_sync("brightnessctl g 2>/dev/null")
        max_b = run_command_sync("brightnessctl m 2>/dev/null")
        if out and max_b and int(max_b) > 0:
            return int((int(out) / int(max_b)) * 100)
        
        # Fallback to ddcutil
        out = run_command_sync("ddcutil getvcp 10 2>/dev/null")
        match = re.search(r"current value =\s*(\d+)", out)
        if match:
            return int(match.group(1))
        return 70

    @staticmethod
    async def set_brightness(level):
        level = max(5, min(100, int(level)))
        # Try brightnessctl
        res = await run_command_async(f"brightnessctl s {level}% 2>/dev/null")
        if not res:
            # Fallback to ddcutil for external monitors
            await run_command_async(f"ddcutil setvcp 10 {level} 2>/dev/null")
        return level
