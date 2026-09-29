#!/usr/bin/env python3
import sys
import time
import json
import os
from decimal import Decimal
import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "ap-south-1"))
TABLE_NAME = os.environ.get("TABLE", "deadman-state")

dynamodb = boto3.resource("dynamodb", region_name=REGION)
T = dynamodb.Table(TABLE_NAME)

now = lambda: int(time.time() * 1000)
H = 3_600_000

def status():
    print(f"=== Dead Man's Switch Status (Table: {TABLE_NAME}, Region: {REGION}) ===")
    for pk in ("STATE", "PI_HEARTBEAT", "CONFIG"):
        try:
            it = T.get_item(Key={"pk": pk}, ConsistentRead=True).get("Item", {})
        except ClientError as e:
            print(f"Error reading {pk}: {e}")
            continue
        if not it:
            print(f"[{pk}] Not found in DynamoDB.")
            continue
        print(f"\n[{pk}]")
        print(json.dumps(it, default=str, indent=2))
        for k in ("last_checkin_ms", "last_seen_ms", "final_notice_ms", "last_reminder_ms", "paused_until_ms", "triggered_ms"):
            if k in it and it[k] is not None:
                val = int(it[k])
                diff = (now() - val) / H
                if diff >= 0:
                    print(f"  -> {k} was {diff:.2f} hours ago ({val})")
                else:
                    print(f"  -> {k} is in {-diff:.2f} hours from now ({val})")

def reset(**extra):
    now_ms = now()
    checkin_ms = extra.get("checkin", now_ms)
    paused_ms = extra.get("paused", 0)
    print(f"Resetting STATE to OK (checkin={checkin_ms}, paused_until={paused_ms})...")
    try:
        T.update_item(
            Key={"pk": "STATE"},
            UpdateExpression="SET #s=:ok, last_checkin_ms=:n, paused_until_ms=:p "
                             "REMOVE final_notice_ms, last_reminder_ms, triggered_ms",
            ExpressionAttributeNames={"#s": "state"},
            ExpressionAttributeValues={
                ":ok": "OK",
                ":n": checkin_ms,
                ":p": paused_ms
            }
        )
        print("State successfully reset to OK.")
    except Exception as e:
        print(f"Failed to reset state: {e}")

def seed(config_path):
    if not os.path.exists(config_path):
        print(f"Error: Config file '{config_path}' not found.")
        sys.exit(1)
    with open(config_path, "r", encoding="utf-8") as f:
        cfg = json.load(f, parse_float=Decimal)
    cfg["pk"] = "CONFIG"
    print(f"Seeding CONFIG from {config_path}...")
    T.put_item(Item=cfg)
    print("CONFIG seeded.")
    try:
        T.put_item(
            Item={"pk": "STATE", "state": "OK", "last_checkin_ms": now(), "paused_until_ms": 0},
            ConditionExpression="attribute_not_exists(pk)"
        )
        print("Initialized STATE item to OK.")
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            print("STATE item already exists; left existing state untouched.")
        else:
            raise

def pause(hours):
    h = float(hours)
    until = now() + int(h * H)
    print(f"Pausing switch for {h} hours (until {until})...")
    reset(paused=until, checkin=until)

def main():
    if len(sys.argv) < 2:
        print("Usage: ctl.py <command> [args]")
        print("Commands:")
        print("  status              Show current STATE, PI_HEARTBEAT and CONFIG")
        print("  seed <config.json>  Upload config.json to DynamoDB and init state")
        print("  checkin             Simulate an immediate manual checkin (resets timer)")
        print("  rearm               Restore state to OK after a trigger or final notice")
        print("  pause <hours>       Pause monitor for N hours")
        print("  unpause             Unpause monitor and resume timer from now")
        sys.exit(0)

    cmd = sys.argv[1].lower()
    if cmd == "status":
        status()
    elif cmd == "seed":
        cfg_file = sys.argv[2] if len(sys.argv) > 2 else "config.json"
        seed(cfg_file)
    elif cmd in ("checkin", "rearm"):
        reset()
    elif cmd == "pause":
        if len(sys.argv) < 3:
            print("Error: Specify number of hours to pause, e.g.: ctl.py pause 72")
            sys.exit(1)
        pause(sys.argv[2])
    elif cmd == "unpause":
        reset()
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)

if __name__ == "__main__":
    main()
