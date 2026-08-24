import os
import json
import logging

logger = logging.getLogger("kdedeck.config")

CONFIG_DIR = os.path.expanduser("~/.config/kdedeck")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")

DEFAULT_CONFIG = {
    "version": "1.1",
    "port": 8484,
    "theme": "theme-neon-cyberdeck",
    "grid_columns": 4,
    "grid_rows": 3,
    "boards": [
        {
            "id": "board_system",
            "title": "System & Audio",
            "icon": "settings",
            "columns": 4,
            "rows": 3,
            "items": [
                {
                    "type": "slider",
                    "id": "master_volume",
                    "title": "Volume",
                    "action": "audio_volume",
                    "icon": "volume-2",
                    "color": "neon-amber"
                },
                {
                    "type": "slider",
                    "id": "brightness_display",
                    "title": "Brightness",
                    "action": "brightness",
                    "icon": "sun",
                    "color": "neon-yellow"
                },
                {
                    "type": "button",
                    "id": "toggle_mute",
                    "title": "Mute Audio",
                    "action": "audio_mute_toggle",
                    "icon": "volume-x",
                    "color": "neon-red"
                },
                {
                    "type": "button",
                    "id": "launch_konsole",
                    "title": "Konsole",
                    "action": "launch_app",
                    "payload": "konsole",
                    "icon": "terminal",
                    "color": "neon-purple"
                },
                {
                    "type": "button",
                    "id": "launch_dolphin",
                    "title": "Dolphin",
                    "action": "launch_app",
                    "payload": "dolphin",
                    "icon": "folder",
                    "color": "neon-cyan"
                },
                {
                    "type": "button",
                    "id": "kde_lock",
                    "title": "Lock Screen",
                    "action": "kde_action",
                    "payload": "lock_screen",
                    "icon": "lock",
                    "color": "neon-slate"
                },
                {
                    "type": "button",
                    "id": "kde_nightlight",
                    "title": "Night Light",
                    "action": "kde_action",
                    "payload": "toggle_nightlight",
                    "icon": "moon",
                    "color": "neon-orange"
                },
                {
                    "type": "button",
                    "id": "open_sys_settings",
                    "title": "Settings",
                    "action": "launch_app",
                    "payload": "systemsettings",
                    "icon": "sliders",
                    "color": "neon-green"
                }
            ]
        },
        {
            "id": "board_media",
            "title": "Media & Browser",
            "icon": "music",
            "columns": 4,
            "rows": 3,
            "items": [
                {
                    "type": "button",
                    "id": "media_prev",
                    "title": "Previous",
                    "action": "mpris_action",
                    "payload": "Previous",
                    "icon": "skip-back",
                    "color": "neon-green"
                },
                {
                    "type": "button",
                    "id": "media_play_pause",
                    "title": "Play / Pause",
                    "action": "mpris_action",
                    "payload": "PlayPause",
                    "icon": "play",
                    "color": "neon-green"
                },
                {
                    "type": "button",
                    "id": "media_next",
                    "title": "Next Track",
                    "action": "mpris_action",
                    "payload": "Next",
                    "icon": "skip-forward",
                    "color": "neon-green"
                },
                {
                    "type": "button",
                    "id": "open_browser",
                    "title": "Firefox",
                    "action": "launch_app",
                    "payload": "firefox",
                    "icon": "firefox",
                    "color": "neon-orange"
                },
                {
                    "type": "button",
                    "id": "open_youtube",
                    "title": "YouTube",
                    "action": "open_url",
                    "payload": "https://youtube.com",
                    "icon": "video",
                    "color": "neon-red"
                },
                {
                    "type": "button",
                    "id": "open_spotify",
                    "title": "Spotify",
                    "action": "launch_app",
                    "payload": "spotify",
                    "icon": "music",
                    "color": "neon-green"
                }
            ]
        },
        {
            "id": "board_kdeconnect",
            "title": "KDE Connect",
            "icon": "smartphone",
            "columns": 4,
            "rows": 3,
            "items": [
                {
                    "type": "button",
                    "id": "ring_phone",
                    "title": "Find Phone",
                    "action": "kdeconnect_ring",
                    "icon": "bell",
                    "color": "neon-pink"
                },
                {
                    "type": "widget",
                    "id": "phone_battery",
                    "title": "Phone Battery",
                    "action": "kdeconnect_battery",
                    "icon": "battery-charging",
                    "color": "neon-cyan"
                },
                {
                    "type": "button",
                    "id": "sync_clipboard",
                    "title": "Clip Sync",
                    "action": "kdeconnect_clipboard",
                    "icon": "clipboard",
                    "color": "neon-blue"
                }
            ]
        },
        {
            "id": "board_taskbar",
            "title": "Active Taskbar",
            "icon": "layers",
            "columns": 4,
            "rows": 3,
            "dynamic": "kwin_active_apps",
            "items": []
        }
    ]
}

class ConfigManager:
    def __init__(self):
        self.config = self.load_config()

    def load_config(self):
        if not os.path.exists(CONFIG_DIR):
            os.makedirs(CONFIG_DIR, exist_ok=True)

        if not os.path.exists(CONFIG_PATH):
            logger.info(f"Creating default config at {CONFIG_PATH}")
            self.save_config(DEFAULT_CONFIG)
            return DEFAULT_CONFIG

        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
                return data
        except Exception as e:
            logger.error(f"Error loading config file: {e}. Falling back to default.")
            return DEFAULT_CONFIG

    def save_config(self, data=None):
        if data is not None:
            self.config = data
        try:
            tmp_path = CONFIG_PATH + ".tmp"
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(self.config, f, indent=2)
            os.replace(tmp_path, CONFIG_PATH)
            logger.info("Configuration saved successfully.")
            return True
        except Exception as e:
            logger.error(f"Failed to save config: {e}")
            return False

    def get_config(self):
        return self.config
