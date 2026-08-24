import logging
import re
from kdedeck.server.plugins.base import run_command_async, run_command_sync

logger = logging.getLogger("kdedeck.mpris")

class MPRISPlugin:
    @staticmethod
    async def control(action):
        """
        Sends MPRIS D-Bus action (PlayPause, Next, Previous, Stop) to all active media players.
        """
        # Find all active MPRIS D-Bus player destinations
        names_out = run_command_sync("dbus-send --session --dest=org.freedesktop.DBus --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null")
        players = re.findall(r'string "(org\.mpris\.MediaPlayer2\.[^"]+)"', names_out)

        executed = False
        for player in players:
            cmd = f"dbus-send --type=method_call --dest={player} /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player.{action} 2>/dev/null"
            await run_command_async(cmd)
            executed = True

        # Fallback to playerctl or KDE global shortcuts
        if not executed:
            await run_command_async(f"playerctl {action.lower()} 2>/dev/null")
            # Try KDE media shortcuts
            shortcut_map = {
                "PlayPause": "playpausemedia",
                "Next": "nextmedia",
                "Previous": "previousmedia",
                "Stop": "stopmedia"
            }
            if action in shortcut_map:
                sc = shortcut_map[action]
                await run_command_async(f"dbus-send --session --dest=org.kde.kglobalaccel /component/mediacontrol org.kde.kglobalaccel.Component.invokeShortcut string:'{sc}' 2>/dev/null")

    @staticmethod
    def get_metadata():
        artist = run_command_sync("playerctl metadata artist 2>/dev/null")
        title = run_command_sync("playerctl metadata title 2>/dev/null")
        if artist or title:
            return f"{artist} - {title}".strip(" - ")
        return "No Media Playing"
