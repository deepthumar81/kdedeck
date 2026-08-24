import logging
from kdedeck.server.plugins.base import run_command_async, run_command_sync

logger = logging.getLogger("kdedeck.mpris")

class MPRISPlugin:
    @staticmethod
    async def control(action):
        # Action can be PlayPause, Next, Previous, Stop
        cmd = (
            f"dbus-send --type=method_call --dest=org.mpris.MediaPlayer2.spotify "
            f"/org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player.{action} 2>/dev/null || "
            f"dbus-send --type=method_call --dest=org.mpris.MediaPlayer2.vlc "
            f"/org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player.{action} 2>/dev/null || "
            f"playerctl {action.lower()} 2>/dev/null"
        )
        await run_command_async(cmd)

    @staticmethod
    def get_metadata():
        artist = run_command_sync("playerctl metadata artist 2>/dev/null")
        title = run_command_sync("playerctl metadata title 2>/dev/null")
        if artist or title:
            return f"{artist} - {title}".strip(" - ")
        return "No Media Playing"
