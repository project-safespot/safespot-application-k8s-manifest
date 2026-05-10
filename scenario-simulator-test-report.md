# Scenario Simulator Test Report

## 1. 테스트 일시
- 시작: 2026-05-10 17:30:56 KST
- 종료: 2026-05-10 17:30:57 KST

## 2. 환경
- baseUrl: http://localhost:18080
- kubectl: not used
- curl: used
- jq: used
- HTTP client: curl
- port-forward: assumed pre-opened by operator

## 3. Health Check
- /actuator/health: HTTP 200, {"status":"UP","groups":["liveness","readiness"]}
- /actuator/health/readiness: HTTP 200, {"status":"UP"}
- /actuator/health/liveness: HTTP 200, {"status":"UP"}

## 4. 테스트 결과 요약

| 단계 | 이름 | 결과 | HTTP status | scenarioId | cleanup | 비고 |
|---|---|---:|---:|---|---|---|
| 1 | SMOKE_TEST_10_NO_EVENTS | PASS | 200 | c6a47e1a-3edd-402c-bf6d-b0faec5398f9 |  | {"status":null,"message":null,"error":null,"scenarioId":"c6a47e1a-3edd-402c-bf6d-b0faec5398f9"} |
| 2 | CLEANUP_SMOKE | PASS | 200 | c6a47e1a-3edd-402c-bf6d-b0faec5398f9 | PASS | {"status":null,"message":null,"error":null,"scenarioId":"c6a47e1a-3edd-402c-bf6d-b0faec5398f9"} |
| 3 | LOAD_TEST_1000_NO_EVENTS | PASS | 200 | 3f8486b0-5d94-48b0-b94d-f86cb9af2bb9 |  | {"status":null,"message":null,"error":null,"scenarioId":"3f8486b0-5d94-48b0-b94d-f86cb9af2bb9"} |
| 4 | CLEANUP_LOAD_1000 | PASS | 200 | 3f8486b0-5d94-48b0-b94d-f86cb9af2bb9 | PASS | {"status":null,"message":null,"error":null,"scenarioId":"3f8486b0-5d94-48b0-b94d-f86cb9af2bb9"} |
| 5 | EVENT_TEST_100 | PASS | 200 | 236852e5-21be-4bf8-8679-9c3d91569729 |  | {"status":null,"message":null,"error":null,"scenarioId":"236852e5-21be-4bf8-8679-9c3d91569729"} |
| 6 | CLEANUP_EVENT_100 | PASS | 200 | 236852e5-21be-4bf8-8679-9c3d91569729 | PASS | {"status":null,"message":null,"error":null,"scenarioId":"236852e5-21be-4bf8-8679-9c3d91569729"} |
| 7 | PROACTIVE_SCALE_HIGH_EARTHQUAKE | SKIP |  |  |  | kubectl not used |

## 5. 상세 응답
- /tmp/scenario-health.json: 
- /tmp/scenario-health-readiness.json: 
- /tmp/scenario-health-liveness.json: 
- /tmp/scenario-smoke-10-response.json: 
- /tmp/scenario-cleanup-smoke-10-response.json: 
- /tmp/scenario-load-1000-response.json: 
- /tmp/scenario-cleanup-load-1000-response.json: 
- /tmp/scenario-event-100-response.json: 
- /tmp/scenario-cleanup-event-100-response.json: 

## 6. 발견된 문제
- HTTP 500: none
- missing scenarioId: none
- cleanup failure: none
- event publish error: none

## 7. 정리된 테스트 데이터
- cleanup success scenarioId: c6a47e1a-3edd-402c-bf6d-b0faec5398f9, 3f8486b0-5d94-48b0-b94d-f86cb9af2bb9, 236852e5-21be-4bf8-8679-9c3d91569729
- cleanup failed scenarioId: none
- possibly uncleaned scenarioId: none

## 8. 다음 조치
- 필요한 코드 수정: 실패한 응답 본문과 HTTP status 기준으로 확인
- 필요한 manifest 수정: 이 스크립트는 manifest를 변경하지 않음
- 운영자가 kubectl logs로 확인해야 할 항목: HTTP 500, missing scenarioId, cleanup failure, event publish error가 있었다면 해당 시점의 scenario-simulator 및 연관 워커 로그
