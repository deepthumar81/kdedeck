import logging
import webbrowser
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
            await run_command_async("loginctl lock-session 2>/dev/null || qdbus org.freedesktop.ScreenSaver /ScreenSaver Lock")
        elif action_name == "toggle_nightlight":
            await run_command_async("qdbus org.kde.KWin /org/kde/KWin/NightLight toggle 2>/dev/null")
        elif action_name == "present_windows":
            await run_command_async("qdbus org.kde.kglobalaccel /component/kwin invokeShortcut 'Expose' 2>/dev/null")
