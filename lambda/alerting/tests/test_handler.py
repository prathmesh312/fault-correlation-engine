"""Unit tests for alerting Lambda."""

import base64
import json
import os
import time

import boto3
import pytest
from moto import mock_aws

os.environ["AWS_DEFAULT_REGION"]   = "ap-southeast-2"
os.environ["FAULT_STATUS_TABLE"]   = "fault-status"
os.environ["AWS_REGION"]           = "ap-southeast-2"

import handler as alerting_handler


@pytest.fixture
def sns_topics():
    with mock_aws():
        client = boto3.client("sns", region_name="ap-southeast-2")
        device = client.create_topic(Name="device-fault")["TopicArn"]
        pop    = client.create_topic(Name="pop-fault")["TopicArn"]
        region = client.create_topic(Name="region-fault")["TopicArn"]

        os.environ["SNS_DEVICE_FAULT_ARN"] = device
        os.environ["SNS_POP_FAULT_ARN"]    = pop
        os.environ["SNS_REGION_FAULT_ARN"] = region

        alerting_handler.SNS_DEVICE_FAULT_ARN = device
        alerting_handler.SNS_POP_FAULT_ARN    = pop
        alerting_handler.SNS_REGION_FAULT_ARN = region
        alerting_handler.SCOPE_TO_TOPIC = {
            "device": device,
            "pop":    pop,
            "region": region,
        }

        yield {"device": device, "pop": pop, "region": region, "client": client}


@pytest.fixture
def dynamodb_table():
    with mock_aws():
        client = boto3.client("dynamodb", region_name="ap-southeast-2")
        client.create_table(
            TableName="fault-status",
            KeySchema=[
                {"AttributeName": "pop_id",    "KeyType": "HASH"},
                {"AttributeName": "timestamp", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "pop_id",    "AttributeType": "S"},
                {"AttributeName": "timestamp", "AttributeType": "N"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        yield client


def make_fault_event(scope: str = "pop") -> dict:
    payload = {
        "pop_id":           "SYD-01",
        "region_id":        "ap-southeast-2",
        "affected_devices": ["device-000", "device-001", "device-002"],
        "pop_fault":        scope in ("pop", "region"),
        "region_fault":     scope == "region",
        "window_start":     int(time.time()) - 60,
        "window_end":       int(time.time()),
    }
    encoded = base64.b64encode(json.dumps(payload).encode()).decode()
    return {"Records": [{"kinesis": {
        "data": encoded,
        "partitionKey": "SYD-01",
        "sequenceNumber": "123",
        "approximateArrivalTimestamp": time.time(),
    }, "eventSource": "aws:kinesis"}]}


@mock_aws
@mock_aws
def test_determine_scope_region(sns_topics, dynamodb_table):
    event = {"region_fault": True, "pop_fault": True, "pop_id": "SYD-01", "region_id": "ap-southeast-2"}
    assert alerting_handler.determine_scope(event) == "region"


@mock_aws
@mock_aws
def test_determine_scope_pop(sns_topics, dynamodb_table):
    event = {"pop_fault": True, "pop_id": "SYD-01", "region_id": "ap-southeast-2"}
    assert alerting_handler.determine_scope(event) == "pop"


@mock_aws
@mock_aws
def test_determine_scope_device(sns_topics, dynamodb_table):
    event = {"pop_id": "SYD-01", "region_id": "ap-southeast-2"}
    assert alerting_handler.determine_scope(event) == "device"


@mock_aws
@mock_aws
def test_processes_pop_fault_event(sns_topics, dynamodb_table):
    alerting_handler.sns      = boto3.client("sns",      region_name="ap-southeast-2")
    alerting_handler.dynamodb = boto3.client("dynamodb", region_name="ap-southeast-2")

    event  = make_fault_event("pop")
    result = alerting_handler.handler(event, None)

    assert result["processed"] == 1
    assert result["failed"]    == 0


@mock_aws
@mock_aws
def test_processes_region_fault_event(sns_topics, dynamodb_table):
    alerting_handler.sns      = boto3.client("sns",      region_name="ap-southeast-2")
    alerting_handler.dynamodb = boto3.client("dynamodb", region_name="ap-southeast-2")

    event  = make_fault_event("region")
    result = alerting_handler.handler(event, None)

    assert result["processed"] == 1
    assert result["failed"]    == 0
