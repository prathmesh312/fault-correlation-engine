# Network Fault Correlation Engine

Automated POP & Region Fault Detection with Noise Suppression.

Scales from 18 to 350 POPs without alarm storm. Reduces operational load by 28.8% by correlating device-level alarms into single scoped fault events.

## Problem

At 18 POPs, a regional DC outage generated 2 device alarms. Manageable.
At 350 POPs, the same event generates 15+ device alarms — engineers receive a storm of pages for a single fault.

## Solution

Correlate device → POP → region. One page per real fault.

```
On-prem devices (SNMP/syslog)
  → EC2 collector per POP (or local NMS)
  → Kinesis Stream 1 (raw signals, device_id partition key)
  → Lambda enrichment (adds pop_id, region_id, fault_threshold)
  → Kinesis Data Analytics / Flink (60s tumbling window correlation)
  → Kinesis Stream 2 (correlated fault events)
  → Lambda alerting
  → SNS (PagerDuty / NOC / ITSM)
```

## Cost

| Architecture | Monthly | Annual |
|---|---|---|
| EC2 collector per POP | $2,755 | $33,060 |
| Local NMS (existing infra) | ~$255 | ~$3,060 |

## Repo structure

```
.github/workflows/        CI/CD pipelines
terraform/
  modules/                reusable Terraform modules
  regions/                per-region deployments
  global/                 global VPC and Kinesis
lambda/
  enrichment/             Kinesis Stream 1 consumer
  alerting/               Kinesis Stream 2 consumer
docs/                     architecture and runbooks
```

## Prerequisites

- AWS CLI configured
- Terraform >= 1.7.0
- Python >= 3.12
- GitHub OIDC role configured in each target account

## Quick start

```bash
# Install Python dependencies
pip install -r lambda/enrichment/requirements.txt

# Run unit tests
pytest lambda/enrichment/tests/ -v
pytest lambda/alerting/tests/ -v

# Deploy to dev
cd terraform/regions/ap-southeast-2
terraform init
terraform apply -var-file="dev.tfvars"
```
