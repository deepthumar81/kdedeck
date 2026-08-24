import os
import json
import logging
import asyncio
from kdedeck.server.plugins.base import run_command_sync, run_command_async

logger = logging.getLogger("kdedeck.kwin_taskbar")

class KWinTaskbarPlugin:
    _cached_windows = []

    @classmethod
    def get_open_windows(cls):
        windows = []

        # 1. KWin D-Bus Scripting for Plasma 6 Wayland
        script_code = """
var clients = workspace.windowList();
var list = [];
for (var i = 0; i < clients.length; i++) {
    var c = clients[i];
    if (c.normalWindow && !c.skipTaskbar) {
        list.push({
            id: String(c.internalId || c.windowId || i),
            title: String(c.caption || 'Window'),
            app: String(c.resourceClass || c.desktopFileName || 'app')
        });
    }
}
print("KDEDECK_WINS:" + JSON.stringify(list));
"""
        script_path = "/tmp/kdedeck_taskbar.js"
        try:
            with open(script_path, "w") as f:
                f.write(script_code)
            
            # Load script into KWin
            run_command_sync(f"dbus-send --session --dest=org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript string:'{script_path}' >/dev/null 2>&1")
        except Exception:
            pass

        # 2. Try kdotool search
        kdotool_out = run_command_sync("kdotool search --onlyvisible '.' 2>/dev/null")
        if kdotool_out:
            for win_id in kdotool_out.splitlines():
                win_id = win_id.strip()
                if not win_id:
                    continue
                name = run_command_sync(f"kdotool getwindowname {win_id} 2>/dev/null")
                app_class = run_command_sync(f"kdotool getwindowclassname {win_id} 2>/dev/null") or "window"
                if name:
                    windows.append({
                        "id": win_id,
                        "title": name[:22],
                        "full_title": name,
                        "icon": app_class.lower()
                    })
            if windows:
                cls._cached_windows = windows
                return windows

        # 3. Fallback: wmctrl (XWayland)
        wmctrl_out = run_command_sync("wmctrl -l -x 2>/dev/null")
        if wmctrl_out:
            for line in wmctrl_out.splitlines():
                parts = line.split(maxsplit=4)
                if len(parts) >= 5:
                    win_id = parts[0]
                    wm_class = parts[2].split(".")[0].lower()
                    title = parts[4]
                    if title not in ["Desktop", "plasma-desktop"]:
                        windows.append({
                            "id": win_id,
                            "title": title[:22],
                            "full_title": title,
                            "icon": wm_class
                        })
            if windows:
                cls._cached_windows = windows
                return windows

        # 4. Fallback: ps running graphical apps
        ps_out = run_command_sync("ps -u $USER -o comm= | sort -u")
        known_apps = ["firefox", "chrome", "konsole", "dolphin", "code", "spotify", "vlc", "obs", "discord", "steam"]
        for comm in ps_out.splitlines():
            comm = comm.strip().lower()
            if comm in known_apps:
                windows.append({
                    "id": f"app_{comm}",
                    "title": comm.capitalize(),
                    "full_title": comm,
                    "icon": comm
                })

        cls._cached_windows = windows
        return windows

    @classmethod
    async def focus_window(cls, win_id):
        if win_id.startswith("app_"):
            comm = win_id.replace("app_", "")
            await run_command_async(f"{comm} &")
            return

        # Try kdotool windowactivate
        res = await run_command_async(f"kdotool windowactivate {win_id} 2>/dev/null")
        if not res:
            await run_command_async(f"wmctrl -i -a {win_id} 2>/dev/null")
