import logging
import webbrowser
import asyncio
from kdedeck.server.plugins.base import run_command_async

logger = logging.getLogger("kdedeck.exec_cmd")

class ExecCmdPlugin:
    @staticmethod
    async def launch_app(app_cmd):
        logger.info(f"Launching application: {app_cmd}")
        await run_command_async(f"{app_cmd} >/dev/null 2>&1 &")

    @staticmethod
    async def open_url(url):
        logger.info(f"Opening URL: {url}")
        webbrowser.open(url)

    @staticmethod
    async def run_shell(cmd):
        logger.info(f"Executing shell command: {cmd}")
        await run_command_async(cmd)

    @staticmethod
    async def kde_action(action_name):
        logger.info(f"Executing KDE action: {action_name}")
        if action_name == "lock_screen":
            await run_command_async("loginctl lock-session 2>/dev/null")
        elif action_name == "toggle_nightlight":
            # Direct KWin NightLight D-Bus call
            cmd = (
                "dbus-send --session --dest=org.kde.KWin --print-reply /org/kde/KWin/NightLight "
                "org.freedesktop.DBus.Properties.Get string:'org.kde.KWin.NightLight' string:'inhibited' | "
                "grep -q true && "
                "dbus-send --session --dest=org.kde.KWin /org/kde/KWin/NightLight "
                "org.freedesktop.DBus.Properties.Set string:'org.kde.KWin.NightLight' string:'inhibited' variant:boolean:false || "
                "dbus-send --session --dest=org.kde.KWin /org/kde/KWin/NightLight "
                "org.freedesktop.DBus.Properties.Set string:'org.kde.KWin.NightLight' string:'inhibited' variant:boolean:true"
            )
            await run_command_async(cmd)
        elif action_name == "mute_mic":
            await run_command_async("pactl set-source-mute @DEFAULT_SOURCE@ toggle")
        elif action_name == "screenshot":
            await run_command_async("spectacle >/dev/null 2>&1 &")
        elif action_name == "show_desktop":
            await run_command_async("dbus-send --session --dest=org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component.invokeShortcut string:'Toggle Showing Desktop' 2>/dev/null")
        elif action_name == "overview":
            await run_command_async("dbus-send --session --dest=org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component.invokeShortcut string:'Overview' 2>/dev/null")
        elif action_name == "present_windows":
            await run_command_async("dbus-send --session --dest=org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component.invokeShortcut string:'Expose' 2>/dev/null")
        elif action_name == "sleep_suspend":
            await run_command_async("systemctl suspend")
