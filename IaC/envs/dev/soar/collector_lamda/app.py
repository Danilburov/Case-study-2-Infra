import json, os, boto3
sqs = boto3.client("sqs")
QUEUE_URL = os.environ["QUEUE_URL"]

def handler(event, context):
    body = event.get("body") or "{}"
    try:
        payload = json.loads(body)
    except Exception:
        return {"statusCode": 400, "body": "Invalid JSON"}
    evt = {
        "type":      payload.get("type","unknown"),
        "severity":  str(payload.get("severity","low")).lower(),
        "source_ip": payload.get("source_ip","0.0.0.0"),
        "message":   payload.get("message","")
    }
    sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(evt))
    return {"statusCode": 202, "body": "queued"}
