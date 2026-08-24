import logging
import json
import subprocess
from kdedeck.server.plugins.base import run_command_sync, run_command_async

logger = logging.getLogger("kdedeck.kwin_taskbar")

class KWinTaskbarPlugin:
    @staticmethod
    def get_open_windows():
        """
        Gets list of open windows with titles and app icons on KDE Plasma.
        """
        windows = []
        
        # Try kdotool if available
        kdotool_out = run_command_sync("kdotool search --onlyvisible '.' 2>/dev/null")
        if kdotool_out:
            for win_id in kdotool_out.splitlines():
                if not win_id.strip():
                    continue
                name = run_command_sync(f"kdotool getwindowname {win_id} 2>/dev/null")
                if name:
                    windows.append({
                        "id": win_id.strip(),
                        "title": name[:24],
                        "full_title": name,
                        "icon": "window"
                    })
            if windows:
                return windows

        # Fallback to wmctrl (XWayland) or krunner D-Bus
        wmctrl_out = run_command_sync("wmctrl -l 2>/dev/null")
        if wmctrl_out:
            for line in wmctrl_out.splitlines():
                parts = line.split(maxsplit=3)
                if len(parts) >= 4:
                    win_id = parts[0]
                    title = parts[3]
                    # Filter out desktop/panels
                    if title not in ["Desktop", "plasma-desktop"]:
                        windows.append({
                            "id": win_id,
                            "title": title[:24],
                            "full_title": title,
                            "icon": "app-window"
                        })
            if windows:
                return windows

        # Graceful fallback: list running graphical desktop applications via ps
        ps_out = run_command_sync("ps -u $USER -o comm= | sort -u")
        common_apps = ["firefox", "chrome", "konsole", "dolphin", "code", "spotify", "vlc", "obs", "discord", "steam"]
        for comm in ps_out.splitlines():
            comm = comm.strip().lower()
            if comm in common_apps:
                windows.append({
                    "id": f"app_{comm}",
                    "title": comm.capitalize(),
                    "full_title": comm,
                    "icon": comm if comm in ["firefox", "spotify", "terminal", "folder"] else "box"
                })

        return windows

    @staticmethod
    async def focus_window(win_id, app_name=""):
        if win_id.startswith("app_"):
            comm = win_id.replace("app_", "")
            await run_command_async(f"{comm} &")
            return

        # Try kdotool windowactivate
        res = await run_command_async(f"kdotool windowactivate {win_id} 2>/dev/null")
        if not res:
            await run_command_async(f"wmctrl -i -a {win_id} 2>/dev/null")
