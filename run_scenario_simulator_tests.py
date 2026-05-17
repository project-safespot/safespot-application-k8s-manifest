#!/usr/bin/env python3
from urllib import request, error
import json
from datetime import datetime
from pathlib import Path


BASE_URL = "http://localhost:18080"
REPORT_PATH = Path("scenario-simulator-test-report.md")
TMP_DIR = Path("/tmp")


def now_text():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def write_json_file(path, payload):
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def decode_body(raw_bytes):
    if not raw_bytes:
        return ""
    try:
        return raw_bytes.decode("utf-8")
    except UnicodeDecodeError:
        return raw_bytes.decode("utf-8", errors="replace")


def parse_json(text):
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def extract_scenario_id(parsed):
    if not isinstance(parsed, dict):
        return ""
    direct_value = parsed.get("scenarioId")
    if direct_value:
        return str(direct_value)
    data_value = parsed.get("data")
    if isinstance(data_value, dict):
        nested_value = data_value.get("scenarioId")
        if nested_value:
            return str(nested_value)
    return ""


def summarize_body(parsed, body_text):
    if isinstance(parsed, dict):
        summary = {}
        for key in ("status", "message", "error", "path", "timestamp", "scenarioId"):
            if key in parsed:
                summary[key] = parsed[key]
        data_value = parsed.get("data")
        if isinstance(data_value, dict) and "scenarioId" in data_value:
            summary["data.scenarioId"] = data_value["scenarioId"]
        if summary:
            return json.dumps(summary, ensure_ascii=False)
    if not body_text:
        return "(empty body)"
    return body_text[:500]


def http_request(method, path, response_path, payload=None):
    url = BASE_URL + path
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = request.Request(url=url, data=data, headers=headers, method=method)
    status = None
    body_text = ""
    error_text = ""

    try:
        with request.urlopen(req) as resp:
            status = resp.getcode()
            body_text = decode_body(resp.read())
    except error.HTTPError as exc:
        status = exc.code
        body_text = decode_body(exc.read())
        error_text = str(exc)
    except Exception as exc:
        error_text = str(exc)

    parsed = parse_json(body_text)
    stored = {
        "timestamp": now_text(),
        "method": method,
        "url": url,
        "httpStatus": status,
        "requestBody": payload,
        "responseBodyRaw": body_text,
        "responseBodyJson": parsed,
        "error": error_text,
    }
    write_json_file(response_path, stored)
    return {
        "status": status,
        "body_text": body_text,
        "parsed": parsed,
        "error": error_text,
        "file": str(response_path),
        "scenario_id": extract_scenario_id(parsed),
        "summary": summarize_body(parsed, body_text),
    }


def record_step(results, step, name, result, http_status="", scenario_id="", cleanup="", note=""):
    results.append(
        {
            "step": step,
            "name": name,
            "result": result,
            "http_status": http_status,
            "scenario_id": scenario_id,
            "cleanup": cleanup,
            "note": note,
        }
    )


def cleanup_for_scenario(results, step, name, scenario_id, response_file):
    if not scenario_id:
        record_step(results, step, name, "SKIP", "", "", "SKIP", "scenarioId missing")
        return {"result": "SKIP", "scenario_id": "", "response": None}

    response = http_request(
        "POST",
        "/internal/test/cleanup",
        TMP_DIR / response_file,
        {"scenarioId": scenario_id},
    )
    success = response["status"] is not None and 200 <= response["status"] < 300
    record_step(
        results,
        step,
        name,
        "PASS" if success else "FAIL",
        response["status"] if response["status"] is not None else "",
        scenario_id,
        "PASS" if success else "FAIL",
        response["summary"] if not response["error"] else response["error"],
    )
    return {"result": "PASS" if success else "FAIL", "scenario_id": scenario_id, "response": response}


def format_health_line(label, response):
    status_text = response["status"] if response["status"] is not None else "N/A"
    return f"- `{label}`: HTTP {status_text}, {response['summary'] if not response['error'] else response['error']}"


def build_report(start_time, end_time, health_results, steps, response_summaries, issues, cleanup_success_ids, cleanup_failed_ids, possible_uncleaned_ids):
    lines = [
        "# Scenario Simulator Test Report",
        "",
        "## 1. 테스트 일시",
        f"- 시작: {start_time}",
        f"- 종료: {end_time}",
        "",
        "## 2. 환경",
        f"- baseUrl: {BASE_URL}",
        "- kubectl: not used",
        "- curl: not used",
        "- HTTP client: Python urllib",
        "- port-forward: assumed pre-opened by operator",
        "",
        "## 3. Health Check",
        format_health_line("/actuator/health", health_results["health"]),
        format_health_line("/actuator/health/readiness", health_results["readiness"]),
        format_health_line("/actuator/health/liveness", health_results["liveness"]),
        "",
        "## 4. 테스트 결과 요약",
        "",
        "| 단계 | 이름 | 결과 | HTTP status | scenarioId | cleanup | 비고 |",
        "|---|---|---:|---:|---|---|---|",
    ]

    for step in steps:
        lines.append(
            f"| {step['step']} | {step['name']} | {step['result']} | {step['http_status']} | {step['scenario_id']} | {step['cleanup']} | {step['note']} |"
        )

    lines.extend(
        [
            "",
            "## 5. 상세 응답",
        ]
    )

    for item in response_summaries:
        lines.append(f"- `{item['name']}` ({item['file']}): HTTP {item['status']}, {item['summary']}")

    lines.extend(
        [
            "",
            "## 6. 발견된 문제",
            f"- HTTP 500: {issues['http_500'] if issues['http_500'] else 'none'}",
            f"- missing scenarioId: {issues['missing_scenario_id'] if issues['missing_scenario_id'] else 'none'}",
            f"- cleanup failure: {issues['cleanup_failure'] if issues['cleanup_failure'] else 'none'}",
            f"- event publish error: {issues['event_publish_error'] if issues['event_publish_error'] else 'none'}",
            "",
            "## 7. 정리된 테스트 데이터",
            f"- cleanup success scenarioId: {', '.join(cleanup_success_ids) if cleanup_success_ids else 'none'}",
            f"- cleanup failed scenarioId: {', '.join(cleanup_failed_ids) if cleanup_failed_ids else 'none'}",
            f"- possibly uncleaned scenarioId: {', '.join(possible_uncleaned_ids) if possible_uncleaned_ids else 'none'}",
            "",
            "## 8. 다음 조치",
            "- 필요한 코드 수정: 응답 결과에 따라 확인",
            "- 필요한 manifest 수정: 이번 실행에서는 확인하지 않음",
            "- 운영자가 kubectl logs로 확인해야 할 항목: HTTP 500, cleanup 실패, event publish 오류가 있었다면 해당 시점의 scenario-simulator 및 연관 워커 로그",
            "",
        ]
    )

    REPORT_PATH.write_text("\n".join(lines), encoding="utf-8")


def main():
    start_time = now_text()
    results = []
    response_summaries = []
    cleanup_success_ids = []
    cleanup_failed_ids = []
    possible_uncleaned_ids = []
    issues = {
        "http_500": [],
        "missing_scenario_id": [],
        "cleanup_failure": [],
        "event_publish_error": [],
    }

    health = http_request("GET", "/actuator/health", TMP_DIR / "scenario-health.json")
    readiness = http_request("GET", "/actuator/health/readiness", TMP_DIR / "scenario-health-readiness.json")
    liveness = http_request("GET", "/actuator/health/liveness", TMP_DIR / "scenario-health-liveness.json")

    health_results = {
        "health": health,
        "readiness": readiness,
        "liveness": liveness,
    }

    response_summaries.extend(
        [
            {"name": "health", "file": health["file"], "status": health["status"], "summary": health["summary"] if not health["error"] else health["error"]},
            {"name": "health-readiness", "file": readiness["file"], "status": readiness["status"], "summary": readiness["summary"] if not readiness["error"] else readiness["error"]},
            {"name": "health-liveness", "file": liveness["file"], "status": liveness["status"], "summary": liveness["summary"] if not liveness["error"] else liveness["error"]},
        ]
    )

    blocked = False
    for name, response in (("health", health), ("readiness", readiness), ("liveness", liveness)):
        if response["status"] == 500:
            issues["http_500"].append(name)
            blocked = True

    smoke_payload = {
        "scenarioName": "SMOKE_TEST_10_NO_EVENTS",
        "disaster": {
            "disasterType": "EARTHQUAKE",
            "region": "SEOUL",
            "level": "HIGH",
            "publishEvents": False,
        },
        "residents": {
            "count": 10,
            "distribution": "RANDOM",
            "publishEvents": False,
        },
        "cache": {"triggerRegeneration": False},
        "scale": {"triggerProactiveScale": False},
    }

    load_payload = {
        "scenarioName": "LOAD_TEST_1000_NO_EVENTS",
        "disaster": {
            "disasterType": "EARTHQUAKE",
            "region": "SEOUL",
            "level": "HIGH",
            "publishEvents": False,
        },
        "residents": {
            "count": 1000,
            "distribution": "WEIGHTED_BY_CAPACITY",
            "publishEvents": False,
        },
        "cache": {"triggerRegeneration": False},
        "scale": {"triggerProactiveScale": False},
    }

    event_payload = {
        "scenarioName": "EVENT_TEST_100",
        "disaster": {
            "disasterType": "EARTHQUAKE",
            "region": "SEOUL",
            "level": "HIGH",
            "publishEvents": True,
        },
        "residents": {
            "count": 100,
            "distribution": "WEIGHTED_BY_CAPACITY",
            "publishEvents": True,
        },
        "cache": {"triggerRegeneration": True},
        "scale": {"triggerProactiveScale": False},
    }

    smoke_response = None
    load_response = None
    event_response = None

    if not blocked:
        smoke_response = http_request("POST", "/internal/test/scenarios/run", TMP_DIR / "scenario-smoke-10-response.json", smoke_payload)
        response_summaries.append(
            {
                "name": "smoke-test",
                "file": smoke_response["file"],
                "status": smoke_response["status"],
                "summary": smoke_response["summary"] if not smoke_response["error"] else smoke_response["error"],
            }
        )
        smoke_pass = smoke_response["status"] is not None and 200 <= smoke_response["status"] < 300
        if smoke_response["status"] == 500:
            issues["http_500"].append("SMOKE_TEST_10_NO_EVENTS")
            blocked = True
        if smoke_pass and not smoke_response["scenario_id"]:
            issues["missing_scenario_id"].append("SMOKE_TEST_10_NO_EVENTS")
        record_step(
            results,
            1,
            "SMOKE_TEST_10_NO_EVENTS",
            "PASS" if smoke_pass else "FAIL",
            smoke_response["status"] if smoke_response["status"] is not None else "",
            smoke_response["scenario_id"],
            "",
            smoke_response["summary"] if not smoke_response["error"] else smoke_response["error"],
        )

        smoke_cleanup = cleanup_for_scenario(results, 2, "CLEANUP_SMOKE", smoke_response["scenario_id"], "scenario-cleanup-smoke-10-response.json")
        if smoke_cleanup["response"] is not None:
            response_summaries.append(
                {
                    "name": "cleanup-smoke",
                    "file": smoke_cleanup["response"]["file"],
                    "status": smoke_cleanup["response"]["status"],
                    "summary": smoke_cleanup["response"]["summary"] if not smoke_cleanup["response"]["error"] else smoke_cleanup["response"]["error"],
                }
            )
        if smoke_cleanup["result"] == "PASS":
            cleanup_success_ids.append(smoke_response["scenario_id"])
        elif smoke_cleanup["result"] == "FAIL":
            cleanup_failed_ids.append(smoke_response["scenario_id"])
            issues["cleanup_failure"].append(smoke_response["scenario_id"])
            possible_uncleaned_ids.append(smoke_response["scenario_id"])

        if not smoke_pass or smoke_cleanup["result"] == "FAIL":
            blocked = True
        elif smoke_cleanup["result"] == "SKIP" and smoke_response["scenario_id"]:
            possible_uncleaned_ids.append(smoke_response["scenario_id"])

    if not blocked:
        load_response = http_request("POST", "/internal/test/scenarios/run", TMP_DIR / "scenario-load-1000-response.json", load_payload)
        response_summaries.append(
            {
                "name": "load-test-1000",
                "file": load_response["file"],
                "status": load_response["status"],
                "summary": load_response["summary"] if not load_response["error"] else load_response["error"],
            }
        )
        load_pass = load_response["status"] is not None and 200 <= load_response["status"] < 300
        if load_response["status"] == 500:
            issues["http_500"].append("LOAD_TEST_1000_NO_EVENTS")
            blocked = True
        if load_pass and not load_response["scenario_id"]:
            issues["missing_scenario_id"].append("LOAD_TEST_1000_NO_EVENTS")
        record_step(
            results,
            3,
            "LOAD_TEST_1000_NO_EVENTS",
            "PASS" if load_pass else "FAIL",
            load_response["status"] if load_response["status"] is not None else "",
            load_response["scenario_id"],
            "",
            load_response["summary"] if not load_response["error"] else load_response["error"],
        )

        load_cleanup = cleanup_for_scenario(results, 4, "CLEANUP_LOAD_1000", load_response["scenario_id"], "scenario-cleanup-load-1000-response.json")
        if load_cleanup["response"] is not None:
            response_summaries.append(
                {
                    "name": "cleanup-load-1000",
                    "file": load_cleanup["response"]["file"],
                    "status": load_cleanup["response"]["status"],
                    "summary": load_cleanup["response"]["summary"] if not load_cleanup["response"]["error"] else load_cleanup["response"]["error"],
                }
            )
        if load_cleanup["result"] == "PASS":
            cleanup_success_ids.append(load_response["scenario_id"])
        elif load_cleanup["result"] == "FAIL":
            cleanup_failed_ids.append(load_response["scenario_id"])
            issues["cleanup_failure"].append(load_response["scenario_id"])
            possible_uncleaned_ids.append(load_response["scenario_id"])

        if not load_pass or load_cleanup["result"] == "FAIL":
            blocked = True
        elif load_cleanup["result"] == "SKIP" and load_response["scenario_id"]:
            possible_uncleaned_ids.append(load_response["scenario_id"])

    if not blocked:
        event_response = http_request("POST", "/internal/test/scenarios/run", TMP_DIR / "scenario-event-100-response.json", event_payload)
        response_summaries.append(
            {
                "name": "event-test-100",
                "file": event_response["file"],
                "status": event_response["status"],
                "summary": event_response["summary"] if not event_response["error"] else event_response["error"],
            }
        )
        event_pass = event_response["status"] is not None and 200 <= event_response["status"] < 300
        if event_response["status"] == 500:
            issues["http_500"].append("EVENT_TEST_100")
            blocked = True
        if event_pass and not event_response["scenario_id"]:
            issues["missing_scenario_id"].append("EVENT_TEST_100")
        if event_response["body_text"] and ("AccessDenied" in event_response["body_text"] or "SQS" in event_response["body_text"]):
            issues["event_publish_error"].append("EVENT_TEST_100")
        record_step(
            results,
            5,
            "EVENT_TEST_100",
            "PASS" if event_pass else "FAIL",
            event_response["status"] if event_response["status"] is not None else "",
            event_response["scenario_id"],
            "",
            event_response["summary"] if not event_response["error"] else event_response["error"],
        )

        event_cleanup = cleanup_for_scenario(results, 6, "CLEANUP_EVENT_100", event_response["scenario_id"], "scenario-cleanup-event-100-response.json")
        if event_cleanup["response"] is not None:
            response_summaries.append(
                {
                    "name": "cleanup-event-100",
                    "file": event_cleanup["response"]["file"],
                    "status": event_cleanup["response"]["status"],
                    "summary": event_cleanup["response"]["summary"] if not event_cleanup["response"]["error"] else event_cleanup["response"]["error"],
                }
            )
        if event_cleanup["result"] == "PASS":
            cleanup_success_ids.append(event_response["scenario_id"])
        elif event_cleanup["result"] == "FAIL":
            cleanup_failed_ids.append(event_response["scenario_id"])
            issues["cleanup_failure"].append(event_response["scenario_id"])
            possible_uncleaned_ids.append(event_response["scenario_id"])
        elif event_cleanup["result"] == "SKIP" and event_response["scenario_id"]:
            possible_uncleaned_ids.append(event_response["scenario_id"])

    if blocked:
        existing_steps = {item["step"] for item in results}
        for step, name in (
            (1, "SMOKE_TEST_10_NO_EVENTS"),
            (2, "CLEANUP_SMOKE"),
            (3, "LOAD_TEST_1000_NO_EVENTS"),
            (4, "CLEANUP_LOAD_1000"),
            (5, "EVENT_TEST_100"),
            (6, "CLEANUP_EVENT_100"),
        ):
            if step not in existing_steps:
                record_step(results, step, name, "SKIP", "", "", "SKIP", "blocked by previous failure")

    record_step(results, 7, "PROACTIVE_SCALE_HIGH_EARTHQUAKE", "SKIP", "", "", "", "kubectl not used")

    end_time = now_text()
    build_report(
        start_time,
        end_time,
        health_results,
        sorted(results, key=lambda item: item["step"]),
        response_summaries,
        issues,
        cleanup_success_ids,
        cleanup_failed_ids,
        possible_uncleaned_ids,
    )

    summary_parts = []
    for step in sorted(results, key=lambda item: item["step"]):
        summary_parts.append(f"{step['step']}:{step['result']}")

    print(str(REPORT_PATH.resolve()))
    print(", ".join(summary_parts))
    print(", ".join(cleanup_failed_ids) if cleanup_failed_ids else "none")
    print(", ".join(possible_uncleaned_ids) if possible_uncleaned_ids else "none")


if __name__ == "__main__":
    main()
