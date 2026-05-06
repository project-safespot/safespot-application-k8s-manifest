#!/usr/bin/env bash
# Fetches non-sensitive SSM String parameters and renders values-dev.generated.yaml.
# Run from repo root. Requires: aws CLI, envsubst (gettext).
# AWS credentials must be configured before running.
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-2}"
TEMPLATE="charts/safespot/values-dev.template.yaml"
OUTPUT="charts/safespot/values-dev.generated.yaml"

fetch() {
  aws ssm get-parameter --region "$REGION" --name "$1" --query "Parameter.Value" --output text
}

echo "Fetching SSM parameters (region: $REGION)..."

export RDS_WRITER_ENDPOINT
RDS_WRITER_ENDPOINT=$(fetch /safespot/dev/rds/writer-endpoint)

export RDS_READER_ENDPOINT
RDS_READER_ENDPOINT=$(fetch /safespot/dev/rds/reader-endpoint)

export REDIS_ENDPOINT
REDIS_ENDPOINT=$(fetch /safespot/dev/elasticache/endpoint)

export SQS_CORE_EVENTS_URL
SQS_CORE_EVENTS_URL=$(fetch /safespot/dev/sqs/core-events-url)

export SQS_CACHE_REGENERATION_URL
SQS_CACHE_REGENERATION_URL=$(fetch /safespot/dev/sqs/cache-regeneration-url)

export SQS_DISASTER_EVENTS_URL
SQS_DISASTER_EVENTS_URL=$(fetch /safespot/dev/sqs/disaster-events-url)

export SQS_ENVIRONMENT_EVENTS_URL
SQS_ENVIRONMENT_EVENTS_URL=$(fetch /safespot/dev/sqs/environment-events-url)

export ACM_CERTIFICATE_ARN
ACM_CERTIFICATE_ARN=$(fetch /safespot/dev/acm/certificate-arn 2>/dev/null || echo "")

export API_HOST
API_HOST=$(fetch /safespot/dev/domain/api-host)

echo "Rendering $OUTPUT..."
envsubst < "$TEMPLATE" > "$OUTPUT"

echo "Done: $OUTPUT"
