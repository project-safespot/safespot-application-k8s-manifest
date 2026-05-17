#!/usr/bin/env bash

set -u

BASE_URL="http://localhost:18080"
REPORT_PATH="scenario-simulator-test-report.md"

START_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"
END_TIME=""

HEALTH_FILE="/tmp/scenario-health.json"
READINESS_FILE="/tmp/scenario-health-readiness.json"
LIVENESS_FILE="/tmp/scenario-health-liveness.json"
SMOKE_FILE="/tmp/scenario-smoke-10-response.json"
CLEANUP_SMOKE_FILE="/tmp/scenario-cleanup-smoke-10-response.json"
LOAD_FILE="/tmp/scenario-load-1000-response.json"
CLEANUP_LOAD_FILE="/tmp/scenario-cleanup-load-1000-response.json"
EVENT_FILE="/tmp/scenario-event-100-response.json"
CLEANUP_EVENT_FILE="/tmp/scenario-cleanup-event-100-response.json"

STEP1_RESULT="SKIP"
STEP1_STATUS=""
STEP1_SCENARIO_ID=""
STEP1_CLEANUP=""
STEP1_NOTE=""

STEP2_RESULT="SKIP"
STEP2_STATUS=""
STEP2_SCENARIO_ID=""
STEP2_CLEANUP="SKIP"
STEP2_NOTE=""

STEP3_RESULT="SKIP"
STEP3_STATUS=""
STEP3_SCENARIO_ID=""
STEP3_CLEANUP=""
STEP3_NOTE=""

STEP4_RESULT="SKIP"
STEP4_STATUS=""
STEP4_SCENARIO_ID=""
STEP4_CLEANUP="SKIP"
STEP4_NOTE=""

STEP5_RESULT="SKIP"
STEP5_STATUS=""
STEP5_SCENARIO_ID=""
STEP5_CLEANUP=""
STEP5_NOTE=""

STEP6_RESULT="SKIP"
STEP6_STATUS=""
STEP6_SCENARIO_ID=""
STEP6_CLEANUP="SKIP"
STEP6_NOTE=""

STEP7_RESULT="SKIP"
STEP7_STATUS=""
STEP7_SCENARIO_ID=""
STEP7_CLEANUP=""
STEP7_NOTE="kubectl not used"

HEALTH_STATUS=""
HEALTH_SUMMARY=""
READINESS_STATUS=""
READINESS_SUMMARY=""
LIVENESS_STATUS=""
LIVENESS_SUMMARY=""

HTTP_500_ISSUES=""
MISSING_SCENARIO_ID_ISSUES=""
CLEANUP_FAILURE_ISSUES=""
EVENT_PUBLISH_ISSUES=""

CLEANUP_SUCCESS_IDS=""
CLEANUP_FAILED_IDS=""
POSSIBLY_UNCLEANED_IDS=""


append_csv() {
  local current="$1"
  local value="$2"
  if [ -z "$value" ]; then
    printf '%s' "$current"
  elif [ -z "$current" ]; then
    printf '%s' "$value"
  else
    printf '%s, %s' "$current" "$value"
  fi
}


extract_scenario_id() {
  local file="$1"
  jq -r '.scenarioId // .data.scenarioId // empty' "$file" 2>/dev/null
}


extract_summary() {
  local file="$1"
  jq -c '{
    status: .status,
    message: .message,
    error: .error,
    scenarioId: (.scenarioId // .data.scenarioId // empty)
  }' "$file" 2>/dev/null | grep -v '^null$' || true
}


http_get() {
  local path="$1"
  local output_file="$2"
  local body_file
  local status

  body_file="$(mktemp)"
  status="$(curl -sS -o "$body_file" -w '%{http_code}' "$BASE_URL$path" 2>"${body_file}.err" || true)"

  cat > "$output_file" <<EOF
{
  "httpStatus": $(
    if [ -n "$status" ] && [ "$status" != "000" ]; then
      printf '%s' "$status"
    else
      printf 'null'
    fi
  ),
  "responseBody": $(jq -Rs '.' < "$body_file"),
  "curlError": $(jq -Rs '.' < "${body_file}.err")
}
EOF

  rm -f "$body_file" "${body_file}.err"
}


http_post() {
  local path="$1"
  local payload="$2"
  local output_file="$3"
  local body_file
  local status

  body_file="$(mktemp)"
  status="$(curl -sS -X POST "$BASE_URL$path" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    -o "$body_file" \
    -w '%{http_code}' 2>"${body_file}.err" || true)"

  cat > "$output_file" <<EOF
{
  "httpStatus": $(
    if [ -n "$status" ] && [ "$status" != "000" ]; then
      printf '%s' "$status"
    else
      printf 'null'
    fi
  ),
  "requestBody": $payload,
  "responseBody": $(jq -Rs '.' < "$body_file"),
  "curlError": $(jq -Rs '.' < "${body_file}.err")
}
EOF

  rm -f "$body_file" "${body_file}.err"
}


load_http_result() {
  local file="$1"
  local status_var="$2"
  local summary_var="$3"

  local status
  local body
  local curl_error
  local parsed_summary

  status="$(jq -r '.httpStatus // empty' "$file" 2>/dev/null)"
  body="$(jq -r '.responseBody // empty' "$file" 2>/dev/null)"
  curl_error="$(jq -r '.curlError // empty' "$file" 2>/dev/null)"
  parsed_summary="$(printf '%s' "$body" | jq -c '{status: .status, message: .message, error: .error, scenarioId: (.scenarioId // .data.scenarioId // empty)}' 2>/dev/null || true)"

  if [ -n "$curl_error" ]; then
    printf -v "$summary_var" '%s' "$curl_error"
  elif [ -n "$parsed_summary" ] && [ "$parsed_summary" != "null" ]; then
    printf -v "$summary_var" '%s' "$parsed_summary"
  elif [ -n "$body" ]; then
    printf -v "$summary_var" '%s' "$body"
  else
    printf -v "$summary_var" '%s' "(empty body)"
  fi

  printf -v "$status_var" '%s' "$status"
}


mark_blocked_steps() {
  if [ "$STEP3_RESULT" = "SKIP" ] && [ -z "$STEP3_NOTE" ]; then
    STEP3_NOTE="blocked by previous failure"
  fi
  if [ "$STEP4_RESULT" = "SKIP" ] && [ -z "$STEP4_NOTE" ]; then
    STEP4_NOTE="blocked by previous failure"
  fi
  if [ "$STEP5_RESULT" = "SKIP" ] && [ -z "$STEP5_NOTE" ]; then
    STEP5_NOTE="blocked by previous failure"
  fi
  if [ "$STEP6_RESULT" = "SKIP" ] && [ -z "$STEP6_NOTE" ]; then
    STEP6_NOTE="blocked by previous failure"
  fi
}


run_cleanup() {
  local scenario_id="$1"
  local output_file="$2"
  local result_var="$3"
  local status_var="$4"
  local cleanup_var="$5"
  local note_var="$6"

  if [ -z "$scenario_id" ]; then
    printf -v "$result_var" '%s' "SKIP"
    printf -v "$cleanup_var" '%s' "SKIP"
    printf -v "$note_var" '%s' "scenarioId missing"
    return
  fi

  http_post "/internal/test/cleanup" "{\"scenarioId\":\"$scenario_id\"}" "$output_file"
  load_http_result "$output_file" "$status_var" "$note_var"

  if [ "${!status_var}" = "500" ]; then
    HTTP_500_ISSUES="$(append_csv "$HTTP_500_ISSUES" "cleanup:$scenario_id")"
  fi

  if [ -n "${!status_var}" ] && [ "${!status_var}" -ge 200 ] && [ "${!status_var}" -lt 300 ]; then
    printf -v "$result_var" '%s' "PASS"
    printf -v "$cleanup_var" '%s' "PASS"
    CLEANUP_SUCCESS_IDS="$(append_csv "$CLEANUP_SUCCESS_IDS" "$scenario_id")"
  else
    printf -v "$result_var" '%s' "FAIL"
    printf -v "$cleanup_var" '%s' "FAIL"
    CLEANUP_FAILED_IDS="$(append_csv "$CLEANUP_FAILED_IDS" "$scenario_id")"
    CLEANUP_FAILURE_ISSUES="$(append_csv "$CLEANUP_FAILURE_ISSUES" "$scenario_id")"
    POSSIBLY_UNCLEANED_IDS="$(append_csv "$POSSIBLY_UNCLEANED_IDS" "$scenario_id")"
  fi
}


write_report() {
  END_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"

  cat > "$REPORT_PATH" <<EOF
# Scenario Simulator Test Report

## 1. 테스트 일시
- 시작: $START_TIME
- 종료: $END_TIME

## 2. 환경
- baseUrl: $BASE_URL
- kubectl: not used
- curl: used
- jq: used
- HTTP client: curl
- port-forward: assumed pre-opened by operator

## 3. Health Check
- /actuator/health: HTTP ${HEALTH_STATUS:-N/A}, ${HEALTH_SUMMARY:-N/A}
- /actuator/health/readiness: HTTP ${READINESS_STATUS:-N/A}, ${READINESS_SUMMARY:-N/A}
- /actuator/health/liveness: HTTP ${LIVENESS_STATUS:-N/A}, ${LIVENESS_SUMMARY:-N/A}

## 4. 테스트 결과 요약

| 단계 | 이름 | 결과 | HTTP status | scenarioId | cleanup | 비고 |
|---|---|---:|---:|---|---|---|
| 1 | SMOKE_TEST_10_NO_EVENTS | $STEP1_RESULT | ${STEP1_STATUS} | ${STEP1_SCENARIO_ID} | ${STEP1_CLEANUP} | ${STEP1_NOTE} |
| 2 | CLEANUP_SMOKE | $STEP2_RESULT | ${STEP2_STATUS} | ${STEP2_SCENARIO_ID} | ${STEP2_CLEANUP} | ${STEP2_NOTE} |
| 3 | LOAD_TEST_1000_NO_EVENTS | $STEP3_RESULT | ${STEP3_STATUS} | ${STEP3_SCENARIO_ID} | ${STEP3_CLEANUP} | ${STEP3_NOTE} |
| 4 | CLEANUP_LOAD_1000 | $STEP4_RESULT | ${STEP4_STATUS} | ${STEP4_SCENARIO_ID} | ${STEP4_CLEANUP} | ${STEP4_NOTE} |
| 5 | EVENT_TEST_100 | $STEP5_RESULT | ${STEP5_STATUS} | ${STEP5_SCENARIO_ID} | ${STEP5_CLEANUP} | ${STEP5_NOTE} |
| 6 | CLEANUP_EVENT_100 | $STEP6_RESULT | ${STEP6_STATUS} | ${STEP6_SCENARIO_ID} | ${STEP6_CLEANUP} | ${STEP6_NOTE} |
| 7 | PROACTIVE_SCALE_HIGH_EARTHQUAKE | $STEP7_RESULT | ${STEP7_STATUS} | ${STEP7_SCENARIO_ID} | ${STEP7_CLEANUP} | ${STEP7_NOTE} |

## 5. 상세 응답
- /tmp/scenario-health.json: $(extract_summary "$HEALTH_FILE")
- /tmp/scenario-health-readiness.json: $(extract_summary "$READINESS_FILE")
- /tmp/scenario-health-liveness.json: $(extract_summary "$LIVENESS_FILE")
- /tmp/scenario-smoke-10-response.json: $(extract_summary "$SMOKE_FILE")
- /tmp/scenario-cleanup-smoke-10-response.json: $(test -f "$CLEANUP_SMOKE_FILE" && extract_summary "$CLEANUP_SMOKE_FILE")
- /tmp/scenario-load-1000-response.json: $(test -f "$LOAD_FILE" && extract_summary "$LOAD_FILE")
- /tmp/scenario-cleanup-load-1000-response.json: $(test -f "$CLEANUP_LOAD_FILE" && extract_summary "$CLEANUP_LOAD_FILE")
- /tmp/scenario-event-100-response.json: $(test -f "$EVENT_FILE" && extract_summary "$EVENT_FILE")
- /tmp/scenario-cleanup-event-100-response.json: $(test -f "$CLEANUP_EVENT_FILE" && extract_summary "$CLEANUP_EVENT_FILE")

## 6. 발견된 문제
- HTTP 500: ${HTTP_500_ISSUES:-none}
- missing scenarioId: ${MISSING_SCENARIO_ID_ISSUES:-none}
- cleanup failure: ${CLEANUP_FAILURE_ISSUES:-none}
- event publish error: ${EVENT_PUBLISH_ISSUES:-none}

## 7. 정리된 테스트 데이터
- cleanup success scenarioId: ${CLEANUP_SUCCESS_IDS:-none}
- cleanup failed scenarioId: ${CLEANUP_FAILED_IDS:-none}
- possibly uncleaned scenarioId: ${POSSIBLY_UNCLEANED_IDS:-none}

## 8. 다음 조치
- 필요한 코드 수정: 실패한 응답 본문과 HTTP status 기준으로 확인
- 필요한 manifest 수정: 이 스크립트는 manifest를 변경하지 않음
- 운영자가 kubectl logs로 확인해야 할 항목: HTTP 500, missing scenarioId, cleanup failure, event publish error가 있었다면 해당 시점의 scenario-simulator 및 연관 워커 로그
EOF
}


run_tests() {
  local smoke_payload
  local load_payload
  local event_payload
  local blocked="false"
  local body

  smoke_payload='{
    "scenarioName": "SMOKE_TEST_10_NO_EVENTS",
    "disaster": {
      "disasterType": "EARTHQUAKE",
      "region": "SEOUL",
      "level": "HIGH",
      "publishEvents": false
    },
    "residents": {
      "count": 10,
      "distribution": "RANDOM",
      "publishEvents": false
    },
    "cache": {
      "triggerRegeneration": false
    },
    "scale": {
      "triggerProactiveScale": false
    }
  }'

  load_payload='{
    "scenarioName": "LOAD_TEST_1000_NO_EVENTS",
    "disaster": {
      "disasterType": "EARTHQUAKE",
      "region": "SEOUL",
      "level": "HIGH",
      "publishEvents": false
    },
    "residents": {
      "count": 1000,
      "distribution": "WEIGHTED_BY_CAPACITY",
      "publishEvents": false
    },
    "cache": {
      "triggerRegeneration": false
    },
    "scale": {
      "triggerProactiveScale": false
    }
  }'

  event_payload='{
    "scenarioName": "EVENT_TEST_100",
    "disaster": {
      "disasterType": "EARTHQUAKE",
      "region": "SEOUL",
      "level": "HIGH",
      "publishEvents": true
    },
    "residents": {
      "count": 100,
      "distribution": "WEIGHTED_BY_CAPACITY",
      "publishEvents": true
    },
    "cache": {
      "triggerRegeneration": true
    },
    "scale": {
      "triggerProactiveScale": false
    }
  }'

  http_get "/actuator/health" "$HEALTH_FILE"
  load_http_result "$HEALTH_FILE" HEALTH_STATUS HEALTH_SUMMARY

  http_get "/actuator/health/readiness" "$READINESS_FILE"
  load_http_result "$READINESS_FILE" READINESS_STATUS READINESS_SUMMARY

  http_get "/actuator/health/liveness" "$LIVENESS_FILE"
  load_http_result "$LIVENESS_FILE" LIVENESS_STATUS LIVENESS_SUMMARY

  http_post "/internal/test/scenarios/run" "$smoke_payload" "$SMOKE_FILE"
  load_http_result "$SMOKE_FILE" STEP1_STATUS STEP1_NOTE
  STEP1_SCENARIO_ID="$(jq -r '.responseBody | fromjson? | .scenarioId // .data.scenarioId // empty' "$SMOKE_FILE" 2>/dev/null)"

  if [ "$STEP1_STATUS" = "500" ]; then
    HTTP_500_ISSUES="$(append_csv "$HTTP_500_ISSUES" "SMOKE_TEST_10_NO_EVENTS")"
    STEP1_RESULT="FAIL"
    blocked="true"
  elif [ -n "$STEP1_STATUS" ] && [ "$STEP1_STATUS" -ge 200 ] && [ "$STEP1_STATUS" -lt 300 ]; then
    STEP1_RESULT="PASS"
  else
    STEP1_RESULT="FAIL"
    blocked="true"
  fi

  if [ "$STEP1_RESULT" = "PASS" ] && [ -z "$STEP1_SCENARIO_ID" ]; then
    MISSING_SCENARIO_ID_ISSUES="$(append_csv "$MISSING_SCENARIO_ID_ISSUES" "SMOKE_TEST_10_NO_EVENTS")"
  fi

  STEP2_SCENARIO_ID="$STEP1_SCENARIO_ID"
  run_cleanup "$STEP1_SCENARIO_ID" "$CLEANUP_SMOKE_FILE" STEP2_RESULT STEP2_STATUS STEP2_CLEANUP STEP2_NOTE
  if [ "$STEP2_RESULT" = "FAIL" ]; then
    blocked="true"
  fi

  if [ "$STEP1_RESULT" != "PASS" ] || [ "$STEP2_RESULT" != "PASS" ]; then
    blocked="true"
  fi

  if [ "$blocked" = "false" ]; then
    http_post "/internal/test/scenarios/run" "$load_payload" "$LOAD_FILE"
    load_http_result "$LOAD_FILE" STEP3_STATUS STEP3_NOTE
    STEP3_SCENARIO_ID="$(jq -r '.responseBody | fromjson? | .scenarioId // .data.scenarioId // empty' "$LOAD_FILE" 2>/dev/null)"

    if [ "$STEP3_STATUS" = "500" ]; then
      HTTP_500_ISSUES="$(append_csv "$HTTP_500_ISSUES" "LOAD_TEST_1000_NO_EVENTS")"
      STEP3_RESULT="FAIL"
      blocked="true"
    elif [ -n "$STEP3_STATUS" ] && [ "$STEP3_STATUS" -ge 200 ] && [ "$STEP3_STATUS" -lt 300 ]; then
      STEP3_RESULT="PASS"
    else
      STEP3_RESULT="FAIL"
      blocked="true"
    fi

    if [ "$STEP3_RESULT" = "PASS" ] && [ -z "$STEP3_SCENARIO_ID" ]; then
      MISSING_SCENARIO_ID_ISSUES="$(append_csv "$MISSING_SCENARIO_ID_ISSUES" "LOAD_TEST_1000_NO_EVENTS")"
    fi

    STEP4_SCENARIO_ID="$STEP3_SCENARIO_ID"
    run_cleanup "$STEP3_SCENARIO_ID" "$CLEANUP_LOAD_FILE" STEP4_RESULT STEP4_STATUS STEP4_CLEANUP STEP4_NOTE
    if [ "$STEP4_RESULT" = "FAIL" ]; then
      blocked="true"
    fi

    if [ "$STEP3_RESULT" != "PASS" ] || [ "$STEP4_RESULT" != "PASS" ]; then
      blocked="true"
    fi
  fi

  if [ "$blocked" = "false" ]; then
    http_post "/internal/test/scenarios/run" "$event_payload" "$EVENT_FILE"
    load_http_result "$EVENT_FILE" STEP5_STATUS STEP5_NOTE
    STEP5_SCENARIO_ID="$(jq -r '.responseBody | fromjson? | .scenarioId // .data.scenarioId // empty' "$EVENT_FILE" 2>/dev/null)"
    body="$(jq -r '.responseBody // empty' "$EVENT_FILE" 2>/dev/null)"

    if [ "$STEP5_STATUS" = "500" ]; then
      HTTP_500_ISSUES="$(append_csv "$HTTP_500_ISSUES" "EVENT_TEST_100")"
      STEP5_RESULT="FAIL"
      blocked="true"
    elif [ -n "$STEP5_STATUS" ] && [ "$STEP5_STATUS" -ge 200 ] && [ "$STEP5_STATUS" -lt 300 ]; then
      STEP5_RESULT="PASS"
    else
      STEP5_RESULT="FAIL"
      blocked="true"
    fi

    if [ "$STEP5_RESULT" = "PASS" ] && [ -z "$STEP5_SCENARIO_ID" ]; then
      MISSING_SCENARIO_ID_ISSUES="$(append_csv "$MISSING_SCENARIO_ID_ISSUES" "EVENT_TEST_100")"
    fi

    case "$body" in
      *AccessDenied*|*SQS*)
        EVENT_PUBLISH_ISSUES="$(append_csv "$EVENT_PUBLISH_ISSUES" "EVENT_TEST_100")"
        ;;
    esac

    STEP6_SCENARIO_ID="$STEP5_SCENARIO_ID"
    run_cleanup "$STEP5_SCENARIO_ID" "$CLEANUP_EVENT_FILE" STEP6_RESULT STEP6_STATUS STEP6_CLEANUP STEP6_NOTE
  fi

  if [ "$STEP2_RESULT" = "SKIP" ] && [ -n "$STEP1_SCENARIO_ID" ]; then
    POSSIBLY_UNCLEANED_IDS="$(append_csv "$POSSIBLY_UNCLEANED_IDS" "$STEP1_SCENARIO_ID")"
  fi
  if [ "$STEP4_RESULT" = "SKIP" ] && [ -n "$STEP3_SCENARIO_ID" ]; then
    POSSIBLY_UNCLEANED_IDS="$(append_csv "$POSSIBLY_UNCLEANED_IDS" "$STEP3_SCENARIO_ID")"
  fi
  if [ "$STEP6_RESULT" = "SKIP" ] && [ -n "$STEP5_SCENARIO_ID" ]; then
    POSSIBLY_UNCLEANED_IDS="$(append_csv "$POSSIBLY_UNCLEANED_IDS" "$STEP5_SCENARIO_ID")"
  fi

  mark_blocked_steps
  write_report

  echo "$REPORT_PATH"
  echo "1:$STEP1_RESULT, 2:$STEP2_RESULT, 3:$STEP3_RESULT, 4:$STEP4_RESULT, 5:$STEP5_RESULT, 6:$STEP6_RESULT, 7:$STEP7_RESULT"
  echo "${CLEANUP_FAILED_IDS:-none}"
  echo "${POSSIBLY_UNCLEANED_IDS:-none}"
}


run_tests
