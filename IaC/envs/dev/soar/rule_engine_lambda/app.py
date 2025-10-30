import os, json, time, boto3
ses = boto3.client("ses"); ddb = boto3.client("dynamodb"); cw = boto3.client("cloudwatch")

SES_FROM = os.environ.get("SES_FROM")
SES_TO   = os.environ.get("SES_TO")
TABLE = os.environ.get("ACTIONS_TABLE")
if not TABLE:
    raise RuntimeError("ACTIONS_TABLE env var is required")

NS = "SOAR"

def decide(evt):
    sev = (evt.get("severity") or "low").lower()
    acts = ["log"]
    if sev in ("high","critical") and SES_FROM and SES_TO:
        acts.append("email")
    return acts


def decide(evt):
    sev = (evt.get("severity") or "low").lower()
    acts = ["log"]
    if sev in ("high","critical"):
        acts.append("email")
    return acts

def metric(name, value=1, dims=None):
    cw.put_metric_data(
        Namespace=NS,
        MetricData=[{
            "MetricName": name,
            "Value": value,
            "Unit": "Count",
            "Dimensions": [{"Name":k,"Value":v} for k,v in (dims or {}).items()]
        }]
    )

def log_action(evt, action, status, detail=""):
    ddb.put_item(
        TableName=TABLE,
        Item={
            "id":    {"S": evt.get("type","evt")+":"+str(int(time.time()*1000))},
            "ts":    {"N": str(int(time.time()))},
            "action":{"S": action},
            "status":{"S": status},
            "event": {"S": json.dumps(evt)},
            "detail":{"S": detail},
        }
    )

def send_email(evt):
    ses.send_email(
        Source=SES_FROM,
        Destination={"ToAddresses":[SES_TO]},
        Message={
          "Subject":{"Data":f"[SOAR] {evt.get('severity','low').upper()} - {evt.get('type','event')}"},
          "Body":{"Text":{"Data":json.dumps(evt, indent=2)}}
        }
    )

def handler(event, context):
    processed = 0
    for r in event.get("Records", []):
        evt = json.loads(r["body"])
        processed += 1
        metric("EventsProcessed")
        for a in decide(evt):
            try:
                if a == "email":
                    send_email(evt)
                log_action(evt, a, "ok")
                metric("ActionSuccess", dims={"Action": a})
            except Exception as e:
                log_action(evt, a, "error", str(e))
                metric("ActionFailure", dims={"Action": a})
    return {"statusCode": 200, "body": f"processed {processed}"}
