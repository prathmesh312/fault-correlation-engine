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
