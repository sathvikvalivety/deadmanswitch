#!/usr/bin/env python3
import json
import os
import time
import shutil
import subprocess
import logging
from awscrt import mqtt
from awsiot import mqtt_connection_builder

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
log = logging.getLogger("deadman-heartbeat")

CFG_DIR = os.environ.get("CONFIG_DIR", "/etc/deadman/")
THING = os.environ.get("THING", "deadman-pi")
TOPIC = os.environ.get("TOPIC", "deadman/heartbeat")
INTERVAL = int(os.environ.get("INTERVAL_S", "300"))
ENDPOINT = os.environ.get("IOT_ENDPOINT", "")

try:
    with open("/proc/sys/kernel/random/boot_id", "r") as f:
        BOOT_ID = f.read().strip()
except Exception:
    BOOT_ID = "unknown"

def read_metrics():
    try:
        with open("/proc/uptime", "r") as f:
            up = float(f.read().split()[0])
    except Exception:
        up = 0.0

    try:
        with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
            temp = int(f.read().strip()) / 1000.0
    except Exception:
        temp = 0.0

    try:
        du = shutil.disk_usage("/")
        disk_pct = round(du.used / du.total * 100.0, 1)
    except Exception:
        disk_pct = 0.0

    try:
        thr = subprocess.check_output(["vcgencmd", "get_throttled"], text=True, timeout=5).strip().split("=")[1]
    except Exception:
        thr = "0x0"

    return {
        "uptime_s": int(up),
        "cpu_temp_c": round(temp, 1),
        "throttled": thr,
        "disk_used_pct": disk_pct,
        "boot_id": BOOT_ID
    }

def main():
    if not ENDPOINT:
        log.error("IOT_ENDPOINT environment variable is missing!")
        time.sleep(10)
        return

    cert_path = os.path.join(CFG_DIR, "device.pem.crt")
    key_path = os.path.join(CFG_DIR, "private.pem.key")
    ca_path = os.path.join(CFG_DIR, "AmazonRootCA1.pem")

    log.info(f"Initializing AWS IoT connection to {ENDPOINT} (Thing: {THING})...")
    conn = mqtt_connection_builder.mtls_from_path(
        endpoint=ENDPOINT,
        cert_filepath=cert_path,
        pri_key_filepath=key_path,
        ca_filepath=ca_path,
        client_id=THING,
        clean_session=False,
        keep_alive_secs=30
    )

    while True:
        try:
            log.info("Attempting connection to AWS IoT Core...")
            conn.connect().result(timeout=30)
            break
        except Exception as e:
            log.warning(f"Connection failed: {e}. Retrying in 30 seconds...")
            time.sleep(30)

    log.info("Connected to AWS IoT Core successfully.")

    while True:
        try:
            payload = json.dumps(read_metrics())
            fut, _ = conn.publish(TOPIC, payload, mqtt.QoS.AT_LEAST_ONCE)
            fut.result(timeout=20)
            log.info(f"Heartbeat sent to {TOPIC}: {payload}")
        except Exception as e:
            log.warning(f"Failed to publish heartbeat: {e}")
        time.sleep(INTERVAL)

if __name__ == "__main__":
    main()
