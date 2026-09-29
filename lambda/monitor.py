import os
import time
import json
import boto3
from email.message import EmailMessage
from botocore.exceptions import ClientError

TABLE_NAME = os.environ.get("TABLE", "deadman-state")
TOKEN_PARAM = os.environ.get("TOKEN_PARAM", "/deadman/checkin_token")
CHECKIN_URL = os.environ.get("CHECKIN_URL", "")
DRY_RUN = os.environ.get("DRY_RUN", "true").lower() == "true"

T = boto3.resource("dynamodb").Table(TABLE_NAME)
ses = boto3.client("sesv2")
s3 = boto3.client("s3")
ssm = boto3.client("ssm")

H = 3_600_000

def get_item(pk):
    resp = T.get_item(Key={"pk": pk}, ConsistentRead=True)
    return resp.get("Item", {})

def set_state(**kw):
    update_expr = "SET " + ", ".join(f"#{k}=:{k}" for k in kw)
    expr_names = {f"#{k}": k for k in kw}
    expr_values = {f":{k}": v for k, v in kw.items()}
    T.update_item(
        Key={"pk": "STATE"},
        UpdateExpression=update_expr,
        ExpressionAttributeNames=expr_names,
        ExpressionAttributeValues=expr_values
    )

def send_mail(sender, to_list, subject, body, attach=None):
    if not to_list:
        return
    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = ", ".join(to_list)
    msg["Subject"] = subject
    msg.set_content(body)
    
    if attach:
        filename, data = attach
        msg.add_attachment(data, maintype="application", subtype="octet-stream", filename=filename)
        
    if DRY_RUN:
        print(f"[DRY_RUN] Dispatched email to {to_list} | Subject: {subject!r} | HasAttachment: {bool(attach)}")
        return

    ses.send_email(
        FromEmailAddress=sender,
        Destination={"ToAddresses": list(to_list)},
        Content={"Raw": {"Data": msg.as_bytes()}}
    )

def execute_release(cfg, sender, now_ms):
    print("Initiating release procedure...")
    try:
        T.update_item(
            Key={"pk": "STATE"},
            UpdateExpression="SET #s=:t",
            ConditionExpression="#s=:f",
            ExpressionAttributeNames={"#s": "state"},
            ExpressionAttributeValues={":t": "TRIGGERING", ":f": "FINAL_NOTICE"}
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            print("Release cancelled: state is no longer FINAL_NOTICE (user likely checked in).")
            return
        raise e

    try:
        attach = None
        bucket = cfg.get("attachment_bucket")
        key = cfg.get("attachment_key")
        if bucket and key:
            print(f"Fetching attachment from s3://{bucket}/{key}...")
            data = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
            attach = (key.split("/")[-1], data)
            
        for recipient in cfg.get("recipients", []):
            send_mail(sender, [recipient["email"]], recipient["subject"], recipient["body"], attach)
            
        set_state(state="TRIGGERED", triggered_ms=now_ms)
        send_mail(
            sender,
            list(cfg.get("owner_emails", [])),
            "[deadman] RELEASE EXECUTED",
            "The dead man's switch triggered and release messages were dispatched to your designated recipients."
        )
        print("Release successfully completed.")
    except Exception as exc:
        print(f"Error during release execution: {exc}")
        set_state(state="FINAL_NOTICE")
        raise exc

def handler(event, context):
    now_ms = int(time.time() * 1000)
    cfg = get_item("CONFIG")
    st = get_item("STATE")
    pi = get_item("PI_HEARTBEAT")

    if not cfg:
        print("Warning: CONFIG item not found in DynamoDB. Seed with ctl.py.")
        return {"status": "error", "message": "CONFIG missing"}

    state = st.get("state", "OK")
    paused_until = int(st.get("paused_until_ms", 0))

    if state in ("TRIGGERING", "TRIGGERED"):
        print(f"Monitor skipped: Switch is in terminal state '{state}'.")
        return {"state": state, "skipped": True}

    if paused_until > now_ms:
        remaining_h = (paused_until - now_ms) / H
        print(f"Monitor skipped: Switch is paused for another {remaining_h:.2f} hours.")
        return {"state": state, "paused": True, "remaining_hours": remaining_h}

    sender = cfg.get("from_email", "deadman@example.com")
    owners = list(cfg.get("owner_emails", []))
    safety = list(cfg.get("safety_contacts", []))

    # Retrieve checkin link
    tok = ssm.get_parameter(Name=TOKEN_PARAM, WithDecryption=True)["Parameter"]["Value"]
    link = f"{CHECKIN_URL}?t={tok}" if CHECKIN_URL else f"https://<CHECKIN_URL>/?t={tok}"

    # 1. Pi Health Check (Informational only, never releases secrets)
    seen_ms = int(pi.get("last_seen_ms", 0))
    pi_alert_after_ms = float(cfg.get("pi_alert_after_min", 30)) * 60_000
    pi_alert_interval_ms = float(cfg.get("pi_alert_every_h", 6)) * H
    last_pi_alert = int(st.get("last_pi_alert_ms", 0))

    if seen_ms > 0 and (now_ms - seen_ms > pi_alert_after_ms) and (now_ms - last_pi_alert > pi_alert_interval_ms):
        missing_mins = (now_ms - seen_ms) // 60_000
        send_mail(
            sender,
            owners,
            "[deadman] Pi heartbeat missing",
            f"No heartbeat received from Raspberry Pi for {missing_mins} minutes.\n"
            f"Check device power, network connection, or systemd service."
        )
        set_state(last_pi_alert_ms=now_ms)

    # 2. Human Check-in State Machine
    last_checkin = int(st.get("last_checkin_ms", now_ms))
    elapsed = now_ms - last_checkin

    remind_ms = float(cfg.get("remind_after_h", 120)) * H
    final_ms = float(cfg.get("final_after_h", 168)) * H
    cancel_window_ms = float(cfg.get("cancel_window_h", 48)) * H
    reminder_interval_ms = float(cfg.get("reminder_every_h", 24)) * H

    if state == "FINAL_NOTICE":
        final_notice_time = int(st.get("final_notice_ms", now_ms))
        if now_ms - final_notice_time >= cancel_window_ms:
            execute_release(cfg, sender, now_ms)
            return {"state": "TRIGGERED"}
        elif now_ms - int(st.get("last_reminder_ms", final_notice_time)) >= reminder_interval_ms:
            send_mail(
                sender,
                owners + safety,
                "[deadman] FINAL NOTICE: Release Pending",
                f"No check-in recorded for {elapsed // H} hours. Release will occur soon.\n"
                f"Check in here to cancel: {link}\n"
                f"Safety contacts: Please check in with the owner immediately."
            )
            set_state(last_reminder_ms=now_ms)
        return {"state": "FINAL_NOTICE"}

    if elapsed >= final_ms:
        send_mail(
            sender,
            owners + safety,
            "[deadman] FINAL NOTICE: Release Pending",
            f"No check-in for {elapsed // H} hours. Release will occur in {int(cancel_window_ms // H)} hours unless the owner checks in.\n\n"
            f"Check in to cancel: {link}\n"
            f"Safety contacts: Please try to contact the owner immediately."
        )
        set_state(state="FINAL_NOTICE", final_notice_ms=now_ms, last_reminder_ms=now_ms)
        return {"state": "FINAL_NOTICE"}

    elif elapsed >= remind_ms and (now_ms - int(st.get("last_reminder_ms", 0)) >= reminder_interval_ms):
        send_mail(
            sender,
            owners,
            "[deadman] Safety Check-in Reminder",
            f"It has been {elapsed // H} hours since your last check-in.\n\n"
            f"Please check in here: {link}"
        )
        set_state(state="REMINDER", last_reminder_ms=now_ms)
        return {"state": "REMINDER"}

    return {"state": state, "elapsed_hours": elapsed / H}
