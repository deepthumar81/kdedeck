import os
import sys
import json
import logging
import asyncio
import secrets
from aiohttp import web

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger("kdedeck.server")

# Import server components
from kdedeck.server.config_manager import ConfigManager
from kdedeck.server.app_scanner import AppScanner
from kdedeck.server.plugins.system_metrics import SystemMetricsPlugin
from kdedeck.server.plugins.audio_brightness import AudioBrightnessPlugin
from kdedeck.server.plugins.mpris import MPRISPlugin
from kdedeck.server.plugins.kde_connect import KDEConnectPlugin
from kdedeck.server.plugins.kwin_taskbar import KWinTaskbarPlugin
from kdedeck.server.plugins.exec_cmd import ExecCmdPlugin

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB_DIR = os.path.join(BASE_DIR, "web")

class KdeDeckServer:
    def __init__(self, port=8484):
        self.port = port
        self.config_mgr = ConfigManager()
        self.sockets = set()
        self.authenticated_tokens = set()
        self.pin = self.config_mgr.get_config().get("pin", "8484")

    async def index_handler(self, request):
        index_file = os.path.join(WEB_DIR, "index.html")
        return web.FileResponse(index_file, headers={"Cache-Control": "no-cache"})

    async def static_handler(self, request):
        path = request.match_info.get("path", "")
        file_path = os.path.join(WEB_DIR, path)
        if os.path.exists(file_path) and os.path.isfile(file_path):
            if file_path.endswith(('.js', '.css', '.html')):
                return web.FileResponse(file_path, headers={"Cache-Control": "no-cache"})
            return web.FileResponse(file_path)
        return web.FileResponse(os.path.join(WEB_DIR, "index.html"), headers={"Cache-Control": "no-cache"})

    async def apps_api_handler(self, request):
        """API returning installed system desktop applications."""
        apps = AppScanner.get_installed_apps()
        return web.json_response({"status": "ok", "apps": apps})

    async def icon_api_handler(self, request):
        """API serving desktop app icons (PNG/SVG)."""
        icon_name = request.match_info.get("name", "")
        icon_path = AppScanner.find_icon_file(icon_name)
        if icon_path and os.path.exists(icon_path):
            content_type = "image/svg+xml" if icon_path.endswith(".svg") else "image/png"
            return web.FileResponse(icon_path, headers={"Content-Type": content_type})
        return web.Response(status=404, text="Icon not found")

    async def auth_api_handler(self, request):
        """API verifying PIN authentication."""
        try:
            data = await request.json()
            input_pin = str(data.get("pin", "")).strip()
            if input_pin == self.pin:
                token = secrets.token_hex(16)
                self.authenticated_tokens.add(token)
                return web.json_response({"status": "ok", "token": token})
            return web.json_response({"status": "error", "message": "Invalid PIN"}, status=401)
        except Exception:
            return web.json_response({"status": "error", "message": "Bad request"}, status=400)

    async def export_config_handler(self, request):
        """Export current settings & boards JSON file."""
        config = self.config_mgr.get_config()
        return web.Response(
            body=json.dumps(config, indent=2),
            content_type="application/json",
            headers={"Content-Disposition": 'attachment; filename="kdedeck-config.json"'}
        )

    async def import_config_handler(self, request):
        """Import settings & boards JSON configuration."""
        try:
            data = await request.json()
            if "boards" in data:
                self.config_mgr.save_config(data)
                await self.broadcast({"type": "config_updated", "config": data})
                return web.json_response({"status": "ok", "message": "Configuration imported successfully"})
            return web.json_response({"status": "error", "message": "Invalid configuration format"}, status=400)
        except Exception as e:
            return web.json_response({"status": "error", "message": str(e)}, status=400)

    async def ws_handler(self, request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        self.sockets.add(ws)
        logger.info(f"New client connected from {request.remote}. Total clients: {len(self.sockets)}")

        config = self.config_mgr.get_config()
        await ws.send_json({
            "type": "init_state",
            "config": config,
            "pin_required": bool(self.pin),
            "state": {
                "volume": AudioBrightnessPlugin.get_volume(),
                "brightness": AudioBrightnessPlugin.get_brightness(),
                "open_windows": KWinTaskbarPlugin.get_open_windows(),
                "metrics": SystemMetricsPlugin.get_metrics()
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
                        logger.error(f"Error parsing message: {e}")
                elif msg.type == web.WSMsgType.ERROR:
                    logger.error(f"WebSocket error: {ws.exception()}")
        finally:
            self.sockets.discard(ws)
            logger.info(f"Client disconnected. Remaining clients: {len(self.sockets)}")
        return ws

    async def handle_client_message(self, ws, msg_type, data):
        if msg_type == "authenticate":
            token = data.get("token")
            input_pin = str(data.get("pin", "")).strip()
            if token in self.authenticated_tokens or input_pin == self.pin:
                new_token = token or secrets.token_hex(16)
                self.authenticated_tokens.add(new_token)
                await ws.send_json({"type": "auth_success", "token": new_token})
            else:
                await ws.send_json({"type": "auth_error", "message": "Invalid Security PIN"})

        elif msg_type == "trigger_action":
            action = data.get("action")
            payload = data.get("payload")
            val = data.get("value")
            item_id = data.get("item_id")

            logger.info(f"Action triggered: {action} (payload={payload}, value={val})")

            try:
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
                    devices = KDEConnectPlugin.get_paired_devices()
                    if not devices:
                        await ws.send_json({
                            "type": "action_warning",
                            "item_id": item_id,
                            "message": "KDE Connect: No paired phone found"
                        })
                    else:
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

            except Exception as err:
                logger.error(f"Error executing action {action}: {err}")
                await ws.send_json({
                    "type": "action_error",
                    "item_id": item_id,
                    "message": f"Action Failed: {str(err)}"
                })

        elif msg_type == "save_config":
            new_config = data.get("config")
            if new_config:
                if "pin" in new_config:
                    self.pin = new_config["pin"]
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
        """Polls lightweight volume, brightness, and system metrics every 4 seconds."""
        while True:
            await asyncio.sleep(4)
            if self.sockets:
                vol = AudioBrightnessPlugin.get_volume()
                bright = AudioBrightnessPlugin.get_brightness()
                metrics = SystemMetricsPlugin.get_metrics()
                await self.broadcast({
                    "type": "state_poll",
                    "state": {
                        "volume": vol,
                        "brightness": bright,
                        "metrics": metrics
                    }
                })

    async def start(self):
        app = web.Application()
        app.router.add_get("/ws", self.ws_handler)
        app.router.add_get("/api/apps", self.apps_api_handler)
        app.router.add_get("/api/icon/{name}", self.icon_api_handler)
        app.router.add_post("/api/auth", self.auth_api_handler)
        app.router.add_get("/api/config/export", self.export_config_handler)
        app.router.add_post("/api/config/import", self.import_config_handler)
        app.router.add_get("/", self.index_handler)
        app.router.add_get("/{path:.*}", self.static_handler)

        config = self.config_mgr.get_config()
        self.port = config.get("port", 8484)

        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, "0.0.0.0", self.port)
        await site.start()

        asyncio.get_event_loop().create_task(self.background_state_poll())

        logger.info("=" * 60)
        logger.info(f"🚀 KdeDeck Server running on http://0.0.0.0:{self.port}")
        logger.info(f"🔑 Security PIN: {self.pin}")
        logger.info(f"📱 Open http://<YOUR_PC_IP>:{self.port} on your phone!")
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
