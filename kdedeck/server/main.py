import os
import sys
import json
import logging
import asyncio
from aiohttp import web

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger("kdedeck.server")

# Import server components
from kdedeck.server.config_manager import ConfigManager
from kdedeck.server.plugins.audio_brightness import AudioBrightnessPlugin
from kdedeck.server.plugins.mpris import MPRISPlugin
from kdedeck.server.plugins.kde_connect import KDEConnectPlugin
from kdedeck.server.plugins.kwin_taskbar import KWinTaskbarPlugin
from kdedeck.server.plugins.exec_cmd import ExecCmdPlugin

# Absolute path to web static directory
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB_DIR = os.path.join(BASE_DIR, "web")

class KdeDeckServer:
    def __init__(self, port=8484):
        self.port = port
        self.config_mgr = ConfigManager()
        self.sockets = set()

    async def index_handler(self, request):
        index_file = os.path.join(WEB_DIR, "index.html")
        return web.FileResponse(index_file)

    async def static_handler(self, request):
        path = request.match_info.get("path", "")
        file_path = os.path.join(WEB_DIR, path)
        if os.path.exists(file_path) and os.path.isfile(file_path):
            return web.FileResponse(file_path)
        return web.FileResponse(os.path.join(WEB_DIR, "index.html"))

    async def ws_handler(self, request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        self.sockets.add(ws)
        logger.info(f"New client connected from {request.remote}. Total clients: {len(self.sockets)}")

        # Send initial config and state
        config = self.config_mgr.get_config()
        await ws.send_json({
            "type": "init_state",
            "config": config,
            "state": {
                "volume": AudioBrightnessPlugin.get_volume(),
                "brightness": AudioBrightnessPlugin.get_brightness(),
                "open_windows": KWinTaskbarPlugin.get_open_windows()
            }
        })

        try:
            async for msg in ws:
                if msg.type == web.WSMsgType.TEXT:
                    try:
                        data = json.loads(msg.data)
                        msg_type = data.get("type")
                        await self.handle_client_message(ws, msg_type, data)
                    except Exception as e:
                        logger.error(f"Error parsing message '{msg.data}': {e}")
                elif msg.type == web.WSMsgType.ERROR:
                    logger.error(f"WebSocket error: {ws.exception()}")
        finally:
            self.sockets.discard(ws)
            logger.info(f"Client disconnected. Remaining clients: {len(self.sockets)}")
        return ws

    async def handle_client_message(self, ws, msg_type, data):
        if msg_type == "trigger_action":
            action = data.get("action")
            payload = data.get("payload")
            val = data.get("value")

            logger.info(f"Action triggered: {action} (payload={payload}, value={val})")

            # Route actions
            if action == "audio_volume":
                new_vol = await AudioBrightnessPlugin.set_volume(val)
                await self.broadcast({"type": "state_update", "key": "volume", "value": new_vol})

            elif action == "audio_mute_toggle":
                is_muted = await AudioBrightnessPlugin.toggle_mute()
                await self.broadcast({"type": "state_update", "key": "muted", "value": is_muted})

            elif action == "brightness":
                new_b = await AudioBrightnessPlugin.set_brightness(val)
                await self.broadcast({"type": "state_update", "key": "brightness", "value": new_b})

            elif action == "mpris_action":
                await MPRISPlugin.control(payload)

            elif action == "kdeconnect_ring":
                await KDEConnectPlugin.ring_phone()

            elif action == "kdeconnect_clipboard":
                await KDEConnectPlugin.sync_clipboard()

            elif action == "launch_app":
                await ExecCmdPlugin.launch_app(payload)

            elif action == "open_url":
                await ExecCmdPlugin.open_url(payload)

            elif action == "kde_action":
                await ExecCmdPlugin.kde_action(payload)

            elif action == "focus_window":
                await KWinTaskbarPlugin.focus_window(payload)

        elif msg_type == "save_config":
            new_config = data.get("config")
            if new_config:
                self.config_mgr.save_config(new_config)
                await self.broadcast({"type": "config_updated", "config": new_config})

        elif msg_type == "get_taskbar":
            windows = KWinTaskbarPlugin.get_open_windows()
            await ws.send_json({"type": "taskbar_update", "windows": windows})

    async def broadcast(self, message):
        for ws in list(self.sockets):
            try:
                await ws.send_json(message)
            except Exception:
                pass

    async def background_state_poll(self):
        """Polls system state every 4 seconds and broadcasts updates."""
        while True:
            await asyncio.sleep(4)
            if self.sockets:
                windows = KWinTaskbarPlugin.get_open_windows()
                vol = AudioBrightnessPlugin.get_volume()
                bright = AudioBrightnessPlugin.get_brightness()
                await self.broadcast({
                    "type": "state_poll",
                    "state": {
                        "volume": vol,
                        "brightness": bright,
                        "open_windows": windows
                    }
                })

    async def start(self):
        app = web.Application()
        app.router.add_get("/ws", self.ws_handler)
        app.router.add_get("/", self.index_handler)
        app.router.add_get("/{path:.*}", self.static_handler)

        config = self.config_mgr.get_config()
        self.port = config.get("port", 8484)

        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, "0.0.0.0", self.port)
        await site.start()

        asyncio.create_task(self.background_state_poll())

        logger.info("=" * 60)
        logger.info(f"🚀 KdeDeck Server running on http://0.0.0.0:{self.port}")
        logger.info(f"📱 Open http://<YOUR_PC_IP>:{self.port} on your Android phone browser!")
        logger.info("=" * 60)

        await asyncio.Event().wait()

def main():
    server = KdeDeckServer()
    try:
        asyncio.run(server.start())
    except KeyboardInterrupt:
        logger.info("KdeDeck Server stopped.")

if __name__ == "__main__":
    main()
