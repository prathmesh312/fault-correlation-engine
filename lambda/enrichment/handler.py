"""
Enrichment Lambda — Kinesis Stream 1 consumer

Receives raw device signals, enriches with POP and region topology,
forwards enriched records to Kinesis Stream 2 for Flink correlation.

Error handling strategy:
  Retryable errors   → re-raise so Lambda retries the batch.
                       BisectBatchOnFunctionError bisects down to the
                       single bad record which then goes to the DLQ.
  Non-retryable errors → log + continue. Record is skipped, batch proceeds.
  Malformed records  → log + continue. Never retry bad data.
"""

import boto3
import json
import logging
import os
import time
from botocore.exceptions import ClientError

# ─── RETRYABLE ERROR CODES ────────────────────────────────────────────────────
# These are transient AWS errors. Re-raise so Lambda retries the batch.
# BisectBatchOnFunctionError will isolate the offending record to the DLQ.
RETRYABLE_ERROR_CODES = {
    "ProvisionedThroughputExceededException",  # DynamoDB throttling
    "RequestLimitExceeded",                    # AWS API rate limit
    "ThrottlingException",                     # General throttling
    "ServiceUnavailable",                      # Temporary AWS outage
    "InternalServerError",                     # Transient AWS error
}

# Non-retryable error codes — skip and continue, retrying won't fix these
NON_RETRYABLE_ERROR_CODES = {
    "ResourceNotFoundException",   # Table doesn't exist
    "ValidationException",         # Bad request shape
    "AccessDeniedException",       # IAM permissions — fix the role
    "ConditionalCheckFailedException",  # DynamoDB condition failed
}

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

AWS_REGION      = os.environ.get("AWS_REGION", "ap-southeast-2")
TOPOLOGY_TABLE  = os.environ.get("TOPOLOGY_TABLE", "device-topology")
OUTPUT_STREAM   = os.environ.get("OUTPUT_STREAM", "network-fault-enriched-signals")

dynamodb = boto3.client("dynamodb", region_name=AWS_REGION)
kinesis  = boto3.client("kinesis",  region_name=AWS_REGION)

# ─── IN-MEMORY TOPOLOGY CACHE ─────────────────────────────────────────────────
_topology_cache: dict = {}
_cache_loaded_at: float = 0
CACHE_TTL_SECONDS = 300  # refresh every 5 minutes


def load_topology() -> None:
    """Load full device topology from DynamoDB into memory."""
    global _topology_cache, _cache_loaded_at

    try:
        paginator = dynamodb.get_paginator("scan")
        items = []
        for page in paginator.paginate(TableName=TOPOLOGY_TABLE):
            items.extend(page["Items"])

        _topology_cache = {
            item["device_id"]["S"]: {
                "pop_id":          item["pop_id"]["S"],
                "region_id":       item["region_id"]["S"],
                "fault_threshold": int(item.get("fault_threshold", {}).get("N", "60")),
            }
            for item in items
        }
        _cache_loaded_at = time.time()

        logger.info(json.dumps({
            "event":        "topology_cache_loaded",
            "device_count": len(_topology_cache),
            "table":        TOPOLOGY_TABLE,
        }))

    except ClientError as e:
        logger.error(json.dumps({
            "event": "topology_cache_load_failed",
            "error": str(e),
            "code":  e.response["Error"]["Code"],
        }))
        raise


def get_topology(device_id: str) -> dict | None:
    """Return topology for a device_id. Refreshes cache if stale."""
    if time.time() - _cache_loaded_at > CACHE_TTL_SECONDS:
        load_topology()
    return _topology_cache.get(device_id)


# ─── ENRICHMENT ───────────────────────────────────────────────────────────────
def enrich_record(raw: dict, topology: dict) -> dict:
    """Add topology fields to raw device signal."""
    return {
        **raw,
        "pop_id":          topology["pop_id"],
        "region_id":       topology["region_id"],
        "fault_threshold": topology["fault_threshold"],
        "enriched_at":     int(time.time()),
    }


def forward_to_stream(device_id: str, enriched: dict) -> None:
    """Put enriched record to Kinesis Stream 2."""
    kinesis.put_record(
        StreamName=OUTPUT_STREAM,
        Data=json.dumps(enriched),
        PartitionKey=device_id,
    )


# ─── METRICS (EMF) ────────────────────────────────────────────────────────────
def emit_metric(metric_name: str, value: float, unit: str, pop_id: str) -> None:
    """Emit CloudWatch metric via Embedded Metric Format."""
    print(json.dumps({
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [{
                "Namespace":  "/NetworkOps/FaultCorrelation",
                "Dimensions": [["PopId"]],
                "Metrics":    [{"Name": metric_name, "Unit": unit}],
            }],
        },
        "PopId":     pop_id,
        metric_name: value,
    }))


# ─── LAMBDA HANDLER ───────────────────────────────────────────────────────────
def handler(event: dict, context) -> dict:
    """
    Process a batch of Kinesis records.
    Enriches each record with topology and forwards to Stream 2.
    Re-raises on ClientError so Lambda retries the batch.
    """
    processed = 0
    skipped   = 0
    failed    = 0

    for record in event.get("Records", []):
        device_id = None
        start     = time.time()

        try:
            # Decode Kinesis record
            import base64
            raw_data  = base64.b64decode(record["kinesis"]["data"]).decode("utf-8")
            raw       = json.loads(raw_data)
            device_id = raw.get("device_id")

            if not device_id:
                logger.warning(json.dumps({
                    "event":  "missing_device_id",
                    "record": raw,
                }))
                skipped += 1
                continue

            # Get topology
            topology = get_topology(device_id)
            if not topology:
                logger.warning(json.dumps({
                    "event":     "topology_not_found",
                    "device_id": device_id,
                }))
                skipped += 1
                continue

            # Enrich and forward
            enriched = enrich_record(raw, topology)
            forward_to_stream(device_id, enriched)

            duration_ms = (time.time() - start) * 1000
            emit_metric("EnrichmentLatency", duration_ms, "Milliseconds", topology["pop_id"])

            logger.info(json.dumps({
                "event":              "record_enriched",
                "device_id":          device_id,
                "pop_id":             topology["pop_id"],
                "region_id":          topology["region_id"],
                "enrichment_ms":      round(duration_ms, 2),
            }))

            processed += 1

        except ClientError as e:
            error_code = e.response["Error"]["Code"]

            if error_code in RETRYABLE_ERROR_CODES:
                # Transient AWS error — re-raise so Lambda retries the batch.
                # BisectBatchOnFunctionError will bisect down to this record
                # and send it to the DLQ without blocking the rest of the shard.
                logger.error(json.dumps({
                    "event":      "record_failed_retryable",
                    "device_id":  device_id,
                    "error_code": error_code,
                    "action":     "retrying_batch",
                }))
                raise

            else:
                # Non-retryable — bad request, missing table, IAM issue.
                # Retrying won't fix it. Log, skip, continue processing the batch.
                logger.error(json.dumps({
                    "event":      "record_failed_non_retryable",
                    "device_id":  device_id,
                    "error_code": error_code,
                    "action":     "skipping_record",
                    "error":      str(e),
                }))
                failed += 1
                continue

        except (json.JSONDecodeError, KeyError) as e:
            # Malformed record — bad JSON or missing required field.
            # Never retry — the data itself is broken.
            logger.error(json.dumps({
                "event":     "record_malformed",
                "device_id": device_id,
                "error":     str(e),
                "action":    "skipping_record",
            }))
            skipped += 1
            continue

        except Exception as e:
            # Unexpected error — log with full detail, re-raise.
            # Better to stall the shard than silently drop unknown failures.
            logger.error(json.dumps({
                "event":     "record_failed_unexpected",
                "device_id": device_id,
                "error":     str(e),
                "action":    "retrying_batch",
            }))
            raise

    logger.info(json.dumps({
        "event":     "batch_complete",
        "processed": processed,
        "skipped":   skipped,
        "failed":    failed,
        "total":     len(event.get("Records", [])),
    }))

    return {"processed": processed, "skipped": skipped, "failed": failed}
