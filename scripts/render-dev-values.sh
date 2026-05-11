#!/usr/bin/env bash
# Fetches non-sensitive SSM String parameters and renders values-dev.infra.generated.yaml.
# Run from repo root. Requires: aws CLI, envsubst (gettext).
# AWS credentials must be configured before running.
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-2}"
TEMPLATE="charts/safespot/values-dev.infra.template.yaml"
OUTPUT="charts/safespot/values-dev.infra.generated.yaml"

# Explicit allowlist: only these variables are substituted.
# AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN, DB_PASSWORD, JWT_SECRET
# and other sensitive env vars are intentionally excluded.
ALLOWED_VARS='$AWS_REGION $SPRING_PROFILE $API_HOST $API_CORE_CONTEXT_PATH $API_PUBLIC_CONTEXT_PATH $RDS_WRITER_ENDPOINT $RDS_READER_ENDPOINT $DB_NAME $DB_PORT $REDIS_ENDPOINT $REDIS_PORT $READMODEL_QUEUE_URL $CACHE_REFRESH_QUEUE_URL $ENV_CACHE_QUEUE_URL $READMODEL_REFRESH_QUEUE_URL $ALB_CERTIFICATE_ARN $API_CORE_IRSA_ROLE_ARN $API_PUBLIC_READ_IRSA_ROLE_ARN $EXTERNAL_INGESTION_IRSA_ROLE_ARN $PRE_SCALING_CONTROLLER_IRSA_ROLE_ARN'

fetch() {
  aws ssm get-parameter --region "$REGION" --name "$1" --query "Parameter.Value" --output text
}

echo "Fetching SSM parameters (region: $REGION)..."

export AWS_REGION="$REGION"

export SPRING_PROFILE
SPRING_PROFILE=$(fetch /safespot/dev/app/profile)

export API_HOST
API_HOST=$(fetch /safespot/dev/front-edge/api-origin-domain-name)

export API_CORE_CONTEXT_PATH
API_CORE_CONTEXT_PATH=$(fetch /safespot/dev/api/core/context-path)

export API_PUBLIC_CONTEXT_PATH
API_PUBLIC_CONTEXT_PATH=$(fetch /safespot/dev/api/public/context-path)

export RDS_WRITER_ENDPOINT
RDS_WRITER_ENDPOINT=$(fetch /safespot/dev/data/aurora-cluster-endpoint)

export RDS_READER_ENDPOINT
RDS_READER_ENDPOINT=$(fetch /safespot/dev/data/aurora-reader-endpoint)

export DB_NAME
DB_NAME=$(fetch /safespot/dev/data/aurora-db-name)

export DB_PORT
DB_PORT=$(fetch /safespot/dev/data/aurora-port)

export REDIS_ENDPOINT
REDIS_ENDPOINT=$(fetch /safespot/dev/data/redis-primary-endpoint)

export REDIS_PORT
REDIS_PORT=$(fetch /safespot/dev/data/redis-port)

# async-worker queue URLs — SSM path: /safespot/dev/async-worker/*
export READMODEL_QUEUE_URL
READMODEL_QUEUE_URL=$(fetch /safespot/dev/async-worker/event-queue-url)

export CACHE_REFRESH_QUEUE_URL
CACHE_REFRESH_QUEUE_URL=$(fetch /safespot/dev/async-worker/cache-refresh-queue-url)

export ENV_CACHE_QUEUE_URL
ENV_CACHE_QUEUE_URL=$(fetch /safespot/dev/async-worker/environment-cache-refresh-queue-url)

# TODO: disasterQueueUrl → readmodel-refresh-queue-url 매핑은 아키텍처 확인 필요.
# external-ingestion의 SQS_DISASTER_QUEUE_URL이 readmodel-refresh와 동일한 큐를 사용하는지
# 혹은 event-queue-url을 재사용하는지 확인 후 수정할 것.
export READMODEL_REFRESH_QUEUE_URL
READMODEL_REFRESH_QUEUE_URL=$(fetch /safespot/dev/async-worker/readmodel-refresh-queue-url)

export ALB_CERTIFICATE_ARN
ALB_CERTIFICATE_ARN=$(fetch /safespot/dev/front-edge/alb-certificate-arn)

# App Pod IRSA Role ARNs
export API_CORE_IRSA_ROLE_ARN
API_CORE_IRSA_ROLE_ARN=$(fetch /safespot/dev/api-service/irsa/api-core-role-arn)

export API_PUBLIC_READ_IRSA_ROLE_ARN
API_PUBLIC_READ_IRSA_ROLE_ARN=$(fetch /safespot/dev/api-service/irsa/api-public-read-role-arn)

export EXTERNAL_INGESTION_IRSA_ROLE_ARN
EXTERNAL_INGESTION_IRSA_ROLE_ARN=$(fetch /safespot/dev/api-service/irsa/external-ingestion-role-arn)

export PRE_SCALING_CONTROLLER_IRSA_ROLE_ARN
PRE_SCALING_CONTROLLER_IRSA_ROLE_ARN=$(fetch /safespot/dev/api-service/irsa/pre-scaling-controller-role-arn)

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
