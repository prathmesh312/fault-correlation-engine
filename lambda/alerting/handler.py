"""
Alerting Lambda — Kinesis Stream 2 consumer

Receives correlated fault events (device / POP / region scope),
routes to appropriate SNS topic, writes fault record to DynamoDB.
"""

import boto3
import json
import logging
import os
import time
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

AWS_REGION              = os.environ.get("AWS_REGION", "ap-southeast-2")
FAULT_STATUS_TABLE      = os.environ.get("FAULT_STATUS_TABLE", "fault-status")
SNS_DEVICE_FAULT_ARN    = os.environ.get("SNS_DEVICE_FAULT_ARN", "")
SNS_POP_FAULT_ARN       = os.environ.get("SNS_POP_FAULT_ARN", "")
SNS_REGION_FAULT_ARN    = os.environ.get("SNS_REGION_FAULT_ARN", "")

sns      = boto3.client("sns",      region_name=AWS_REGION)
dynamodb = boto3.client("dynamodb", region_name=AWS_REGION)

SCOPE_TO_TOPIC = {
    "device": SNS_DEVICE_FAULT_ARN,
    "pop":    SNS_POP_FAULT_ARN,
    "region": SNS_REGION_FAULT_ARN,
}


def determine_scope(event: dict) -> str:
    """
    Determine fault scope from correlated event.
    Returns 'device', 'pop', or 'region'.
    """
    if event.get("region_fault"):
        return "region"
    if event.get("pop_fault"):
        return "pop"
    return "device"


def publish_to_sns(scope: str, fault_event: dict) -> None:
    """Publish fault event to scoped SNS topic."""
    topic_arn = SCOPE_TO_TOPIC.get(scope)
    if not topic_arn:
        logger.warning(json.dumps({
            "event": "no_topic_configured",
            "scope": scope,
        }))
        return

    sns.publish(
        TopicArn=topic_arn,
        Message=json.dumps(fault_event),
        Subject=f"Fault Alert — {scope.upper()} — {fault_event.get('pop_id', 'unknown')}",
        MessageAttributes={
            "severity": {
                "DataType":    "String",
                "StringValue": scope,
            },
            "region_id": {
                "DataType":    "String",
                "StringValue": fault_event.get("region_id", "unknown"),
            },
        },
    )


def write_fault_status(scope: str, fault_event: dict) -> None:
    """Write fault record to DynamoDB with TTL (7 days)."""
    ttl = int(time.time()) + (7 * 24 * 60 * 60)

    dynamodb.put_item(
        TableName=FAULT_STATUS_TABLE,
        Item={
            "pop_id":           {"S": fault_event.get("pop_id", "unknown")},
            "timestamp":        {"N": str(int(time.time()))},
            "scope":            {"S": scope},
            "region_id":        {"S": fault_event.get("region_id", "unknown")},
            "affected_devices": {"SS": fault_event.get("affected_devices", ["unknown"])},
            "status":           {"S": "ACTIVE"},
            "ttl":              {"N": str(ttl)},
        },
    )


def handler(event: dict, context) -> dict:
    """Process correlated fault events from Kinesis Stream 2."""
    processed = 0
    failed    = 0

    for record in event.get("Records", []):
        try:
            import base64
            raw_data    = base64.b64decode(record["kinesis"]["data"]).decode("utf-8")
            fault_event = json.loads(raw_data)
            scope       = determine_scope(fault_event)

            publish_to_sns(scope, fault_event)
            write_fault_status(scope, fault_event)

            logger.info(json.dumps({
                "event":     "fault_event_processed",
                "scope":     scope,
                "pop_id":    fault_event.get("pop_id"),
                "region_id": fault_event.get("region_id"),
            }))

            processed += 1

        except ClientError as e:
            logger.error(json.dumps({
                "event": "alerting_failed",
                "error": str(e),
                "code":  e.response["Error"]["Code"],
            }))
            failed += 1
            raise

    return {"processed": processed, "failed": failed}
