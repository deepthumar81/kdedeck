import os
import glob
import logging
from kdedeck.server.plugins.base import run_command_sync

logger = logging.getLogger("kdedeck.system_metrics")

class SystemMetricsPlugin:
    _prev_cpu = None

    @classmethod
    def get_metrics(cls):
        metrics = {
            "cpu_temp": 45,
            "cpu_load": 15,
            "gpu_temp": 50,
            "gpu_load": 20,
            "ram_used_gb": 8.0,
            "ram_total_gb": 16.0,
            "ram_percent": 50
        }

        # 1. RAM Usage from /proc/meminfo
        try:
            with open("/proc/meminfo", "r") as f:
                lines = f.readlines()
            total_kb = int(lines[0].split()[1])
            avail_kb = int(lines[2].split()[1])
            used_kb = total_kb - avail_kb

            metrics["ram_used_gb"] = round(used_kb / 1048576, 1)
            metrics["ram_total_gb"] = round(total_kb / 1048576, 1)
            metrics["ram_percent"] = int((used_kb / total_kb) * 100)
        except Exception as e:
            logger.error(f"Error reading RAM metrics: {e}")

        # 2. CPU Temperature from /sys/class/thermal
        try:
            temps = []
            for tz in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
                try:
                    with open(tz, "r") as tf:
                        t = int(tf.read().strip()) // 1000
                        if 20 < t < 110:
                            temps.append(t)
                except Exception:
                    pass
            if temps:
                metrics["cpu_temp"] = max(temps)
        except Exception as e:
            logger.error(f"Error reading CPU temp: {e}")

        # 3. CPU Load % calculation from /proc/stat
        try:
            with open("/proc/stat", "r") as f:
                fields = [int(x) for x in f.readline().split()[1:]]
            idle = fields[3] + fields[4]
            total = sum(fields)

            if cls._prev_cpu:
                prev_idle, prev_total = cls._prev_cpu
                idle_delta = idle - prev_idle
                total_delta = total - prev_total
                if total_delta > 0:
                    metrics["cpu_load"] = int((1.0 - (idle_delta / total_delta)) * 100)

            cls._prev_cpu = (idle, total)
        except Exception as e:
            logger.error(f"Error reading CPU load: {e}")

        # 4. NVIDIA GPU Metrics via nvidia-smi
        try:
            out = run_command_sync("nvidia-smi --query-gpu=temperature.gpu,utilization.gpu --format=csv,noheader,nounits 2>/dev/null")
            if out and "," in out:
                parts = [p.strip() for p in out.split(",")]
                metrics["gpu_temp"] = int(parts[0])
                metrics["gpu_load"] = int(parts[1])
        except Exception:
            pass

        return metrics
