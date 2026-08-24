import os
import re
import glob
import logging

logger = logging.getLogger("kdedeck.app_scanner")

SYSTEM_APP_DIRS = [
    "/usr/share/applications",
    "/usr/local/share/applications",
    os.path.expanduser("~/.local/share/applications")
]

ICON_THEME_DIRS = [
    "/usr/share/icons/hicolor",
    "/usr/share/icons/breeze",
    "/usr/share/icons/breeze-dark",
    "/usr/share/pixmaps",
    os.path.expanduser("~/.local/share/icons")
]

class AppScanner:
    _apps_cache = None
    _icon_cache = {}

    @classmethod
    def get_installed_apps(cls):
        if cls._apps_cache is not None:
            return cls._apps_cache

        apps = []
        seen = set()

        for app_dir in SYSTEM_APP_DIRS:
            if not os.path.exists(app_dir):
                continue
            for filepath in glob.glob(os.path.join(app_dir, "*.desktop")):
                try:
                    name = None
                    exec_cmd = None
                    icon = None
                    no_display = False

                    with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
                        for line in f:
                            line = line.strip()
                            if line.startswith("Name=") and not name:
                                name = line.split("=", 1)[1]
                            elif line.startswith("Exec=") and not exec_cmd:
                                exec_cmd = line.split("=", 1)[1]
                                # Strip field codes like %f, %u
                                exec_cmd = re.sub(r"%[a-zA-Z]", "", exec_cmd).strip()
                            elif line.startswith("Icon=") and not icon:
                                icon = line.split("=", 1)[1]
                            elif line.startswith("NoDisplay=true"):
                                no_display = True

                    if name and exec_cmd and not no_display and name not in seen:
                        seen.add(name)
                        apps.append({
                            "name": name,
                            "exec": exec_cmd,
                            "icon": icon or "box"
                        })
                except Exception as e:
                    pass

        # Sort alphabetically
        apps.sort(key=lambda x: x["name"].lower())
        cls._apps_cache = apps
        logger.info(f"Scanned {len(apps)} installed desktop applications.")
        return apps

    @classmethod
    def find_icon_file(cls, icon_name):
        if not icon_name:
            return None

        if icon_name in cls._icon_cache:
            return cls._icon_cache[icon_name]

        # If it's an absolute path
        if os.path.isabs(icon_name) and os.path.exists(icon_name):
            cls._icon_cache[icon_name] = icon_name
            return icon_name

        # Search icon themes
        for base_dir in ICON_THEME_DIRS:
            if not os.path.exists(base_dir):
                continue
            for ext in ["svg", "png", "xpm"]:
                matches = glob.glob(os.path.join(base_dir, "**", f"{icon_name}.{ext}"), recursive=True)
                if matches:
                    # Prefer scalable or large size icons
                    best_match = matches[0]
                    for m in matches:
                        if "48x48" in m or "scalable" in m or "128x128" in m:
                            best_match = m
                            break
                    cls._icon_cache[icon_name] = best_match
                    return best_match

        cls._icon_cache[icon_name] = None
        return None
