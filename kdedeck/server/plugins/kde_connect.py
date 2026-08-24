import logging
import re
from kdedeck.server.plugins.base import run_command_async, run_command_sync

logger = logging.getLogger("kdedeck.kdeconnect")

class KDEConnectPlugin:
    @staticmethod
    def get_paired_devices():
        output = run_command_sync("kdeconnect-cli -l --name-only 2>/dev/null")
        devices = [d.strip() for d in output.splitlines() if d.strip()]
        return devices

    @staticmethod
    async def ring_phone():
        # Rings first reachable paired device
        cmd = "kdeconnect-cli -l --id-only | head -n1 | xargs -I {} kdeconnect-cli -d {} --ring 2>/dev/null"
        await run_command_async(cmd)

    @staticmethod
    async def get_battery():
        # Get battery level of first connected device via kdeconnect-cli
        output = await run_command_async("kdeconnect-cli -l --id-only | head -n1 | xargs -I {} kdeconnect-cli -d {} --battery 2>/dev/null")
        match = re.search(r"(\d+)%", output)
        if match:
            return int(match.group(1))
        return "N/A"

    @staticmethod
    async def sync_clipboard():
        # Trigger clipboard sync
        await run_command_async("kdeconnect-cli -l --id-only | head -n1 | xargs -I {} kdeconnect-cli -d {} --share-text '$(wl-paste 2>/dev/null || xclip -o)' 2>/dev/null")
