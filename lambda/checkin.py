import os
import time
import hmac
import boto3
from botocore.exceptions import ClientError

TABLE_NAME = os.environ.get("TABLE", "deadman-state")
TOKEN_PARAM = os.environ.get("TOKEN_PARAM", "/deadman/checkin_token")

T = boto3.resource("dynamodb").Table(TABLE_NAME)
ssm = boto3.client("ssm")
_tok = None

def get_secret_token():
    global _tok
    if _tok is None:
        resp = ssm.get_parameter(Name=TOKEN_PARAM, WithDecryption=True)
        _tok = resp["Parameter"]["Value"]
    return _tok

def page(status_code, body_html):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "no-store, no-cache, must-revalidate",
            "X-Robots-Tag": "noindex, nofollow"
        },
        "body": (
            "<!doctype html>"
            "<html>"
            "<head>"
            "<meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width, initial-scale=1'>"
            "<title>Dead Man's Switch Check-in</title>"
            "<style>"
            "body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; "
            "       max-width: 28rem; margin: 4rem auto; padding: 0 1.5rem; text-align: center; color: #333; }"
            ".btn { background-color: #0066cc; color: white; border: none; font-size: 1.4rem; "
            "       padding: 1rem 2.5rem; border-radius: 8px; cursor: pointer; font-weight: bold; width: 100%; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }"
            ".btn:hover { background-color: #0052a3; }"
            ".card { border: 1px solid #e1e4e8; border-radius: 12px; padding: 2rem; background: #fafbfc; }"
            ".success { color: #28a745; }"
            ".error { color: #dc3545; }"
            "</style>"
            "</head>"
            "<body>"
            "<div class='card'>"
            + body_html +
            "</div>"
            "</body>"
            "</html>"
        )
    }

def handler(event, context):
    http_ctx = event.get("requestContext", {}).get("http", {})
    method = http_ctx.get("method", "GET").upper()
    query_params = event.get("queryStringParameters") or {}
    provided_token = query_params.get("t", "")
    
    expected_token = get_secret_token()
    if not provided_token or not hmac.compare_digest(provided_token.encode("utf-8"), expected_token.encode("utf-8")):
        return page(404, "<h2 class='error'>404 Not Found</h2><p>Invalid or missing authentication token.</p>")
    
    # GET shows confirmation form to protect against email crawlers & link previewers
    if method != "POST":
        return page(
            200,
            "<h2>Personal Safety Check-in</h2>"
            "<p>Press the button below to reset the timer and confirm you are safe.</p>"
            f"<form method='POST' action='?t={provided_token}'>"
            "<button type='submit' class='btn'>I am OK (Reset Timer)</button>"
            "</form>"
        )
    
    now_ms = int(time.time() * 1000)
    try:
        T.update_item(
            Key={"pk": "STATE"},
            UpdateExpression="SET #s=:ok, last_checkin_ms=:n REMOVE final_notice_ms, last_reminder_ms",
            ConditionExpression="attribute_not_exists(#s) OR NOT (#s IN (:a, :b))",
            ExpressionAttributeNames={"#s": "state"},
            ExpressionAttributeValues={
                ":ok": "OK",
                ":n": now_ms,
                ":a": "TRIGGERING",
                ":b": "TRIGGERED"
            }
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return page(409, "<h2 class='error'>Already Triggered</h2><p>Switch is in TRIGGERED or TRIGGERING state. Re-arm using the CLI (ctl.py rearm).</p>")
        raise e

    return page(200, "<h2 class='success'>Checked In &#10004;</h2><p>Your timer has been successfully reset.</p>")
