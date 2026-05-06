#!/usr/bin/env bash
# Fetches non-sensitive SSM String parameters and renders values-dev.infra.generated.yaml.
# Run from repo root. Requires: aws CLI, envsubst (gettext).
# AWS credentials must be configured before running.
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-2}"
TEMPLATE="charts/safespot/values-dev.infra.template.yaml"
OUTPUT="charts/safespot/values-dev.infra.generated.yaml"

# Explicit allowlist prevents accidental substitution of credentials or other env vars.
ALLOWED_VARS='$AWS_REGION $API_HOST $RDS_WRITER_ENDPOINT $RDS_READER_ENDPOINT $REDIS_ENDPOINT $READMODEL_QUEUE_URL $CACHE_REFRESH_QUEUE_URL $ENV_CACHE_QUEUE_URL $DLQ_QUEUE_URL $ACM_CERTIFICATE_ARN'

fetch() {
  aws ssm get-parameter --region "$REGION" --name "$1" --query "Parameter.Value" --output text
}

echo "Fetching SSM parameters (region: $REGION)..."

export AWS_REGION="$REGION"

export RDS_WRITER_ENDPOINT
RDS_WRITER_ENDPOINT=$(fetch /safespot/dev/rds/writer-endpoint)

export RDS_READER_ENDPOINT
RDS_READER_ENDPOINT=$(fetch /safespot/dev/rds/reader-endpoint)

export REDIS_ENDPOINT
REDIS_ENDPOINT=$(fetch /safespot/dev/elasticache/endpoint)

export READMODEL_QUEUE_URL
READMODEL_QUEUE_URL=$(fetch /safespot/dev/sqs/readmodel-queue-url)

export CACHE_REFRESH_QUEUE_URL
CACHE_REFRESH_QUEUE_URL=$(fetch /safespot/dev/sqs/cache-refresh-queue-url)

export ENV_CACHE_QUEUE_URL
ENV_CACHE_QUEUE_URL=$(fetch /safespot/dev/sqs/env-cache-queue-url)

export DLQ_QUEUE_URL
DLQ_QUEUE_URL=$(fetch /safespot/dev/sqs/dlq-url)

export ACM_CERTIFICATE_ARN
ACM_CERTIFICATE_ARN=$(fetch /safespot/dev/acm/certificate-arn 2>/dev/null || echo "")

export API_HOST
API_HOST=$(fetch /safespot/dev/domain/api-host)

echo "Rendering $OUTPUT..."
# shellcheck disable=SC2016
envsubst "$ALLOWED_VARS" < "$TEMPLATE" > "$OUTPUT"

echo "Validating $OUTPUT..."
# shellcheck disable=SC2016
if grep -E 'PENDING_|PLACEHOLDER|CHANGE_ME|\$\{[A-Z0-9_]+\}' "$OUTPUT"; then
  echo "ERROR: unresolved placeholder remains in $OUTPUT"
  exit 1
fi

echo "Done: $OUTPUT"
