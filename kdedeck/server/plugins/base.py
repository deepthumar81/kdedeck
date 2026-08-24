import subprocess
import logging
import asyncio

logger = logging.getLogger("kdedeck.plugins")

def run_command_sync(cmd):
    try:
        res = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
        return res.stdout.strip()
    except Exception as e:
        logger.error(f"Error running command '{cmd}': {e}")
        return ""

async def run_command_async(cmd):
    try:
        proc = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await proc.communicate()
        return stdout.decode().strip()
    except Exception as e:
        logger.error(f"Error running async command '{cmd}': {e}")
        return ""
