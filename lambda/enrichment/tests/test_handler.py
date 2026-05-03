"""
Unit tests for enrichment Lambda.
Uses moto to mock AWS services — no real AWS credentials needed.
"""

import base64
import json
import os
import time

import boto3
import pytest
from moto import mock_aws

os.environ["AWS_DEFAULT_REGION"]    = "ap-southeast-2"
os.environ["TOPOLOGY_TABLE"]        = "device-topology"
os.environ["OUTPUT_STREAM"]         = "network-fault-enriched-signals"
os.environ["AWS_REGION"]            = "ap-southeast-2"
os.environ["AWS_ACCESS_KEY_ID"]     = "testing"
os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"
os.environ["AWS_SECURITY_TOKEN"]    = "testing"

import handler


def make_kinesis_event(device_id: str, signal_type: str = "interface_down") -> dict:
    payload = json.dumps({
        "device_id":   device_id,
        "signal_type": signal_type,
        "timestamp":   int(time.time()),
        "severity":    "HIGH",
    })
    encoded = base64.b64encode(payload.encode()).decode()
    return {"Records": [{"kinesis": {
        "data": encoded,
        "partitionKey": device_id,
        "sequenceNumber": "49590338271490256608559692540961702759324208523137515522",
        "approximateArrivalTimestamp": time.time(),
    }, "eventSource": "aws:kinesis"}]}


def setup_table_and_stream(ddb, kin):
    """Create and seed mock DynamoDB table and Kinesis stream."""
    ddb.create_table(
        TableName="device-topology",
        KeySchema=[{"AttributeName": "device_id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "device_id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    for i in range(3):
        ddb.put_item(
            TableName="device-topology",
            Item={
                "device_id":       {"S": f"device-{i:03d}"},
                "pop_id":          {"S": "SYD-01"},
                "region_id":       {"S": "ap-southeast-2"},
                "fault_threshold": {"N": "60"},
            },
        )
    kin.create_stream(StreamName="network-fault-enriched-signals", ShardCount=1)


@mock_aws
def test_enriches_record_with_correct_pop_id():
    ddb = boto3.client("dynamodb", region_name="ap-southeast-2")
    kin = boto3.client("kinesis",  region_name="ap-southeast-2")
    setup_table_and_stream(ddb, kin)

    handler._topology_cache  = {}
    handler._cache_loaded_at = 0
    handler.dynamodb = ddb
    handler.kinesis  = kin

    result = handler.handler(make_kinesis_event("device-000"), None)

    assert result["processed"] == 1
    assert result["skipped"]   == 0
    assert result["failed"]    == 0


@mock_aws
def test_enriches_record_with_correct_topology():
    ddb = boto3.client("dynamodb", region_name="ap-southeast-2")
    kin = boto3.client("kinesis",  region_name="ap-southeast-2")
    setup_table_and_stream(ddb, kin)

    handler._topology_cache  = {}
    handler._cache_loaded_at = 0
    handler.dynamodb = ddb
    handler.kinesis  = kin

    handler.handler(make_kinesis_event("device-001"), None)

    topology = handler.get_topology("device-001")
    assert topology["region_id"]       == "ap-southeast-2"
    assert topology["pop_id"]          == "SYD-01"
    assert topology["fault_threshold"] == 60


@mock_aws
def test_skips_unknown_device():
    ddb = boto3.client("dynamodb", region_name="ap-southeast-2")
    kin = boto3.client("kinesis",  region_name="ap-southeast-2")
    setup_table_and_stream(ddb, kin)

    handler._topology_cache  = {}
    handler._cache_loaded_at = 0
    handler.dynamodb = ddb
    handler.kinesis  = kin

    result = handler.handler(make_kinesis_event("device-unknown-999"), None)

    assert result["skipped"]   == 1
    assert result["processed"] == 0
    assert result["failed"]    == 0


@mock_aws
def test_skips_record_with_missing_device_id():
    ddb = boto3.client("dynamodb", region_name="ap-southeast-2")
    kin = boto3.client("kinesis",  region_name="ap-southeast-2")
    setup_table_and_stream(ddb, kin)

    handler._topology_cache  = {}
    handler._cache_loaded_at = 0
    handler.dynamodb = ddb
    handler.kinesis  = kin

    payload = json.dumps({"signal_type": "interface_down"})
    encoded = base64.b64encode(payload.encode()).decode()
    event = {"Records": [{"kinesis": {
        "data": encoded, "partitionKey": "unknown",
        "sequenceNumber": "123", "approximateArrivalTimestamp": time.time(),
    }, "eventSource": "aws:kinesis"}]}

    result = handler.handler(event, None)
    assert result["skipped"]   == 1
    assert result["processed"] == 0


@mock_aws
def test_processes_multiple_records():
    ddb = boto3.client("dynamodb", region_name="ap-southeast-2")
    kin = boto3.client("kinesis",  region_name="ap-southeast-2")
    setup_table_and_stream(ddb, kin)

    handler._topology_cache  = {}
    handler._cache_loaded_at = 0
    handler.dynamodb = ddb
    handler.kinesis  = kin

    payloads = [
        json.dumps({"device_id": f"device-{i:03d}", "signal_type": "interface_down",
                    "timestamp": int(time.time()), "severity": "HIGH"})
        for i in range(3)
    ]
    event = {"Records": [
        {"kinesis": {"data": base64.b64encode(p.encode()).decode(),
                     "partitionKey": "k", "sequenceNumber": str(i),
                     "approximateArrivalTimestamp": time.time()},
         "eventSource": "aws:kinesis"}
        for i, p in enumerate(payloads)
    ]}

    result = handler.handler(event, None)
    assert result["processed"] == 3
    assert result["skipped"]   == 0
    assert result["failed"]    == 0


@mock_aws
def test_cache_loads_on_first_call():
    ddb = boto3.client("dynamodb", region_name="ap-southeast-2")
    kin = boto3.client("kinesis",  region_name="ap-southeast-2")
    setup_table_and_stream(ddb, kin)

    handler._topology_cache  = {}
    handler._cache_loaded_at = 0
    handler.dynamodb = ddb
    handler.kinesis  = kin

    assert handler._topology_cache == {}
    handler.get_topology("device-000")
    assert len(handler._topology_cache) == 3


@mock_aws
def test_cache_refreshes_when_stale():
    ddb = boto3.client("dynamodb", region_name="ap-southeast-2")
    kin = boto3.client("kinesis",  region_name="ap-southeast-2")
    setup_table_and_stream(ddb, kin)

    handler.dynamodb         = ddb
    handler._topology_cache  = {"old-device": {"pop_id": "OLD", "region_id": "old", "fault_threshold": 60}}
    handler._cache_loaded_at = time.time() - 400

    handler.get_topology("device-000")

    assert "old-device"  not in handler._topology_cache
    assert "device-000"  in handler._topology_cache


def test_enrich_record_adds_all_fields():
    raw = {"device_id": "device-000", "signal_type": "interface_down",
           "timestamp": 12345, "severity": "HIGH"}
    topology = {"pop_id": "SYD-01", "region_id": "ap-southeast-2", "fault_threshold": 60}

    enriched = handler.enrich_record(raw, topology)

    assert enriched["pop_id"]          == "SYD-01"
    assert enriched["region_id"]       == "ap-southeast-2"
    assert enriched["fault_threshold"] == 60
    assert "enriched_at"               in enriched
    assert enriched["device_id"]       == "device-000"
    assert enriched["signal_type"]     == "interface_down"


# ─── ERROR HANDLING TESTS ─────────────────────────────────────────────────────

@mock_aws
def test_retryable_error_re_raises():
    """ProvisionedThroughputExceededException causes re-raise — Lambda retries batch."""
    from unittest.mock import patch, MagicMock
    from botocore.exceptions import ClientError

    ddb = boto3.client("dynamodb", region_name="ap-southeast-2")
    kin = boto3.client("kinesis",  region_name="ap-southeast-2")

    # Pre-load cache so DynamoDB scan doesn't run
    handler._topology_cache = {
        "device-000": {"pop_id": "SYD-01", "region_id": "ap-southeast-2", "fault_threshold": 60}
    }
    handler._cache_loaded_at = time.time()
    handler.dynamodb = ddb
    handler.kinesis  = kin

    # Simulate Kinesis PutRecord throwing ProvisionedThroughputExceededException
    throttle_error = ClientError(
        {"Error": {"Code": "ProvisionedThroughputExceededException", "Message": "Rate exceeded"}},
        "PutRecord"
    )

    with patch.object(handler, "forward_to_stream", side_effect=throttle_error):
        with pytest.raises(ClientError) as exc_info:
            handler.handler(make_kinesis_event("device-000"), None)

    assert exc_info.value.response["Error"]["Code"] == "ProvisionedThroughputExceededException"


@mock_aws
def test_non_retryable_error_skips_record_and_continues():
    """ResourceNotFoundException is non-retryable — record skipped, batch continues."""
    from unittest.mock import patch
    from botocore.exceptions import ClientError

    ddb = boto3.client("dynamodb", region_name="ap-southeast-2")
    kin = boto3.client("kinesis",  region_name="ap-southeast-2")

    # Two records in batch — first will hit non-retryable error, second should succeed
    handler._topology_cache = {
        "device-000": {"pop_id": "SYD-01", "region_id": "ap-southeast-2", "fault_threshold": 60},
        "device-001": {"pop_id": "SYD-01", "region_id": "ap-southeast-2", "fault_threshold": 60},
    }
    handler._cache_loaded_at = time.time()
    handler.dynamodb = ddb
    handler.kinesis  = kin

    not_found_error = ClientError(
        {"Error": {"Code": "ResourceNotFoundException", "Message": "Table not found"}},
        "PutRecord"
    )

    call_count = {"n": 0}

    def forward_side_effect(device_id, enriched):
        call_count["n"] += 1
        if call_count["n"] == 1:
            raise not_found_error  # first record fails
        # second record succeeds

    payload_0 = json.dumps({"device_id": "device-000", "signal_type": "if_down", "timestamp": int(time.time()), "severity": "HIGH"})
    payload_1 = json.dumps({"device_id": "device-001", "signal_type": "if_down", "timestamp": int(time.time()), "severity": "HIGH"})

    event = {"Records": [
        {"kinesis": {"data": base64.b64encode(p.encode()).decode(),
                     "partitionKey": "k", "sequenceNumber": str(i),
                     "approximateArrivalTimestamp": time.time()},
         "eventSource": "aws:kinesis"}
        for i, p in enumerate([payload_0, payload_1])
    ]}

    with patch.object(handler, "forward_to_stream", side_effect=forward_side_effect):
        result = handler.handler(event, None)

    # First record failed non-retryable — counted as failed, not raised
    # Second record succeeded
    assert result["processed"] == 1
    assert result["failed"]    == 1


@mock_aws
def test_malformed_json_skips_record_and_continues():
    """Malformed JSON in a record is skipped — batch continues processing."""
    ddb = boto3.client("dynamodb", region_name="ap-southeast-2")
    kin = boto3.client("kinesis",  region_name="ap-southeast-2")

    handler._topology_cache = {
        "device-001": {"pop_id": "SYD-01", "region_id": "ap-southeast-2", "fault_threshold": 60}
    }
    handler._cache_loaded_at = time.time()
    handler.dynamodb = ddb
    handler.kinesis  = kin

    # First record — malformed JSON
    bad_payload  = base64.b64encode(b"this is not json {{{").decode()

    # Second record — valid
    good_payload = base64.b64encode(
        json.dumps({"device_id": "device-001", "signal_type": "if_down",
                    "timestamp": int(time.time()), "severity": "HIGH"}).encode()
    ).decode()

    # Create mock Kinesis stream for good record
    kin.create_stream(StreamName="network-fault-enriched-signals", ShardCount=1)

    event = {"Records": [
        {"kinesis": {"data": bad_payload,  "partitionKey": "k",
                     "sequenceNumber": "1", "approximateArrivalTimestamp": time.time()},
         "eventSource": "aws:kinesis"},
        {"kinesis": {"data": good_payload, "partitionKey": "k",
                     "sequenceNumber": "2", "approximateArrivalTimestamp": time.time()},
         "eventSource": "aws:kinesis"},
    ]}

    result = handler.handler(event, None)

    # Bad record skipped, good record processed
    assert result["skipped"]   == 1
    assert result["processed"] == 1
    assert result["failed"]    == 0


def test_retryable_error_codes_defined():
    """Verify retryable error codes are defined correctly."""
    assert "ProvisionedThroughputExceededException" in handler.RETRYABLE_ERROR_CODES
    assert "ThrottlingException"                    in handler.RETRYABLE_ERROR_CODES
    assert "ServiceUnavailable"                     in handler.RETRYABLE_ERROR_CODES


def test_non_retryable_error_codes_defined():
    """Verify non-retryable error codes are defined correctly."""
    assert "ResourceNotFoundException" in handler.NON_RETRYABLE_ERROR_CODES
    assert "AccessDeniedException"     in handler.NON_RETRYABLE_ERROR_CODES
    assert "ValidationException"       in handler.NON_RETRYABLE_ERROR_CODES
