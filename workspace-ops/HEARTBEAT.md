# HEARTBEAT.md - PoppingOps Periodic Checks

## Non-LLM Monitoring Boundary

10분 health/resource 체크는 OpenClaw Heartbeat 작업이 아니다.
반복적인 감지와 알림은 OpenClaw 밖의 `/scripts/health-check.sh`가 담당한다.

If Captain Hook or OpenClaw invokes this agent on a 30-minute heartbeat, do not collect metrics, do not run SSH, and do not send a server status report. Return only:

```text
HEARTBEAT_OK
```

Reason:
- `/scripts/health-check.sh` already refreshes `/tmp/health-check-alerts/status-current.env` every 10 minutes by default.
- WARN/CRITICAL/recovery alerts are sent directly through `DISCORD_WEBHOOK_URL`.
- Delivered WARN/CRITICAL alerts may trigger a separate non-blocking recommendation follow-up. Alerts matching `/root/.openclaw/config/runbook-recommendations.json` by `alert_key + severity` use LLM-free recommendations; unmatched alerts call Gateway `/v1/responses` LLM fallback after readiness.
- Repeating the same WARN as an LLM report on every check wastes tokens and creates alert noise.

## External Bash Monitoring

`/scripts/health-check.sh` runs independently from OpenClaw.

Collected data:
- Spring Boot health: `http://localhost:${APP_ACTUATOR_PORT}/actuator/health`
- Spring Boot metrics: `http://localhost:${APP_ACTUATOR_PORT}/actuator/prometheus`
- Node metrics: `http://localhost:${NODE_EXPORTER_PORT}/metrics`
- MySQL metrics: `http://localhost:${MYSQL_EXPORTER_PORT}/metrics`

Actions:
- health, SSH, resource parsing 상태 확인
- memory, CPU Load, disk 임계값 판단
- 평균 응답시간, HTTP 에러율 임계값 판단
- Tomcat, HikariCP, JVM heap, GC, MySQL, network, uptime 수집
- HTTP RPS, 평균 응답시간, 에러율, MySQL QPS를 이전 sample과 현재 counter delta로 계산
- `/tmp/health-check-alerts/status-current.env` snapshot 갱신
- snapshot 갱신 성공 시 `/tmp/health-check-alerts/last_success.state` 갱신
- health SSH, resource SSH, resource parse, snapshot write 실패를 모니터링 파이프라인 장애로 별도 추적
- 모니터링 파이프라인 실패가 2회 연속 발생하면 Webhook 알림
- WARN/CRITICAL/복구 상태 변경 시 Webhook 알림
- WARN/CRITICAL 알림 전송 성공 시 `/root/.openclaw/config/runbook-recommendations.json`의 `alert_key + severity` 기반 권장 조치 후속 메시지 전송. 매칭이 없는 알림만 Gateway `/v1/responses` LLM fallback 사용
- CRITICAL 지속 시 2시간 또는 3회 체크마다 Webhook 재알림

Thresholds:

| Metric | WARN | CRITICAL | Recovery |
|--------|------|----------|----------|
| Memory | >= 80% | >= 95% | < 70% |
| CPU Load1 (1 vCPU) | > 1.0 | > 2.0 | < 0.8 |
| Disk | >= 80% | >= 90% | < 75% |
| Avg Response | > 1s | > 3s | <= 1s |
| Error Rate | > 1% | > 5% | <= 1% |

Traffic thresholds are evaluated only when rate calculation status is `ok`. If counter samples are `init`, `missing`, or `reset`, do not alert on traffic metrics.

Alert policy for the external bash script:

| State | Action |
|-------|--------|
| OK 유지 | 조용히 로그만 기록 |
| OK -> WARN/CRITICAL | 즉시 Webhook 알림 |
| WARN 유지 | 반복 알림 없음 |
| CRITICAL 유지 | 2시간 또는 3회 체크마다 Webhook 재알림 |
| WARN/CRITICAL -> OK | 즉시 복구 알림 |

Monitoring pipeline alert policy:

| Failure | Alert |
|---------|-------|
| health SSH check 실패 1회 | 로그만 기록 |
| resource SSH collection 실패 1회 | 로그만 기록 |
| resource metric parse 실패 1회 | 로그만 기록 |
| snapshot write 실패 1회 | 로그만 기록 |
| 동일 failure 2회 연속 | WARN Webhook 알림 |
| failure 후 성공 | 복구 알림 |

## User Requested Server Status

사용자가 `서버 상태 확인해줘`라고 직접 요청하면 PoppingOps LLM은 최신 snapshot을 읽고 요약한다.

```bash
cat /tmp/health-check-alerts/status-current.env
```

Rules:
- `collected_at_kst`를 측정시각으로 먼저 표시한다.
- snapshot age가 45분 이상이면 데이터 상태를 `오래됨`으로 표시하고 전체 severity를 최소 WARN으로 올린다.
- snapshot age가 90분 이상이면 데이터 상태를 `수집 중단 가능성`으로 표시하고 전체 severity를 CRITICAL로 올린다.
- RPS, 평균 응답시간, 에러율은 최근 `snapshot_interval_min`분 평균/delta임을 표시한다.
- `rate_status_*`가 `ok`가 아니면 해당 rate 지표는 계산 대기 또는 수집 실패로 보고한다.

사용자가 `실시간 서버 상태 확인해줘`라고 직접 요청하면 현재 gauge는 SSH로 다시 수집하고, rate 지표는 최신 snapshot을 사용한다.
응답에는 현재값 측정시각과 snapshot 측정시각을 둘 다 표시한다.

## OpenClaw LLM Heartbeat Tasks

Only these periodic LLM tasks are allowed:

| Task | Frequency | Behavior |
|------|-----------|----------|
| Full Report | Every 6 hours | Triggered by `/scripts/full-report-scheduler.sh`. It runs `/scripts/heartbeat-context.sh full-report` first and calls Gateway `/v1/responses` only when `full_report_should_report=true`. |
| Daily Summary | Daily 9AM KST | Triggered by `/scripts/daily-summary-scheduler.sh`. It runs `/scripts/heartbeat-context.sh daily-summary` first, injects that context into Gateway `/v1/responses`, and always reports. |

## Full Report - Every 6 Hours

Goal: periodic analysis, not repeated alert spam.

Trigger:
- `/scripts/full-report-scheduler.sh` runs every `FULL_REPORT_INTERVAL_SECONDS` seconds. Default is 6 hours.
- It runs `/scripts/heartbeat-context.sh full-report` before any LLM call.
- If `full_report_should_report=false`, it logs and exits without calling Gateway.
- If `full_report_should_report=true`, it calls local Gateway `POST /v1/responses` targeting `main`.
- The scheduler sends the final response to `DISCORD_FULL_REPORT_WEBHOOK_URL`, `DISCORD_REPORT_WEBHOOK_URL`, or `DISCORD_WEBHOOK_URL`.

Use this flow:

1. Run the deterministic context helper.
2. If `full_report_should_report="false"`, return only `HEARTBEAT_OK`.
3. If `full_report_should_report="true"`, summarize only the reason and important current issues.
4. Prefer helper output over ad hoc SSH/raw exporter parsing.

Command:

```bash
/scripts/heartbeat-context.sh full-report
```

The helper prints:
- latest snapshot values
- `snapshot_age_min`
- `snapshot_freshness_status`
- `github_actions_available`
- `github_actions_runs_json` or `github_actions_unavailable`
- `full_report_should_report`
- `full_report_reason`
- `full_report_fingerprint`

The helper also stores the previous Full Report fingerprint in `/tmp/health-check-alerts/full-report.state`.

Report conditions:

| Condition | Action |
|-----------|--------|
| `snapshot_unavailable=true` | Report WARN/CRITICAL, recommend checking `health-check.sh` |
| `snapshot_freshness_status=WARN` | Report WARN |
| `snapshot_freshness_status=CRITICAL` | Report CRITICAL |
| `overall_status=CRITICAL` | Report CRITICAL |
| `full_report_should_report=true` | Report with `full_report_reason` |
| `full_report_should_report=false` | `HEARTBEAT_OK` |

Full Report format:

```text
📊 [severity] 6시간 서버 점검

▸ 기준
  측정시각: {collected_at_kst}
  데이터 상태: {snapshot_freshness_label}, {snapshot_age_min}분 전 snapshot
  트래픽 지표 기준: 최근 {snapshot_interval_min}분 평균

▸ 핵심 상태
  서버: {overall_status}
  CI/CD: {latest status or 수집 제외}

▸ 주요 이슈
  - {new or severe issue only}

▸ 권장 조치
  - {concrete action}
```

Recommended actions in Full Report must be recommendation-data-first:
- If the provided Runbook recommendation data has a matching `alert_key + severity`, summarize its immediate checks and operator-reviewed actions.
- If no provided recommendation matches, say `runbook에 직접 절차 없음` and provide `추론 기반 권장 조치` based only on the provided Target system summary plus the current snapshot/realtime metrics.
- Split fallback recommendations into `즉시 확인할 조치` and `운영자가 검토할 조치`.
- Do not execute restart, config change, deploy, delete, or other write operations.

Do not include a full metric table in the 6-hour Full Report unless the user explicitly asks. The full metric table belongs to user-requested `서버 상태 확인해줘` or Daily Summary.

## Daily Summary - Daily 9AM KST

Goal: daily operational digest. Always report once at 9AM KST, even if everything is normal.

Trigger:
- `/scripts/daily-summary-scheduler.sh` runs `/scripts/heartbeat-context.sh daily-summary` before calling Gateway.
- The scheduler injects the helper output into `POST /v1/responses` on the local OpenClaw Gateway.
- The request targets `main` via `x-openclaw-agent-id: main`.
- The scheduler sends the final response to `DISCORD_DAILY_SUMMARY_WEBHOOK_URL`, `DISCORD_REPORT_WEBHOOK_URL`, or `DISCORD_WEBHOOK_URL`.

Use this flow:

1. Run the deterministic context helper.
2. Summarize current health, traffic, resources, MySQL, CI/CD, and notable alert state.
3. If data is missing, say which source is missing. Do not guess.

Command:

```bash
/scripts/heartbeat-context.sh daily-summary
```

Daily Summary format:

```text
📊 [INFO/WARN/CRITICAL] 일일 서버 요약

▸ 기준
  측정시각: {collected_at_kst}
  데이터 상태: {snapshot_freshness_label}, {snapshot_age_min}분 전 snapshot
  트래픽 지표 기준: 최근 {snapshot_interval_min}분 평균

▸ 서버
  상태: {overall_status}
  메모리: {memory_pct}%
  디스크: {disk_pct}%
  Load Avg: {load1}/{load5}/{load15}

▸ 애플리케이션/DB
  JVM 힙: {jvm_heap_pct}%
  Tomcat 스레드: {tomcat_busy}/{tomcat_max}
  DB 연결: {mysql_connected}/{mysql_max_connections}

▸ 트래픽
  RPS: {http_rps or 계산 대기}
  평균 응답시간: {avg_response_sec or 계산 대기}
  에러율: {error_rate_pct or 계산 대기}

▸ CI/CD
  {latest GitHub Actions status or "수집 제외: gh 인증 필요"}

▸ 오늘의 조치
  - {required action, or 없음}
```

Daily Summary actions must also be recommendation-data-first. If no provided Runbook recommendation matches, say `runbook에 직접 절차 없음` and base `추론 기반 권장 조치` only on the provided Target system summary plus the current snapshot/realtime metrics.

Daily Summary should not return `HEARTBEAT_OK`.

## Cost Boundary

- 10분 자동 체크의 수집/임계값 판단: `/scripts/health-check.sh`, LLM 사용 금지
- WARN/CRITICAL 알림 후 권장 조치: `/root/.openclaw/config/runbook-recommendations.json`에 `alert_key + severity`가 매칭되면 LLM 사용 금지, 매칭이 없을 때만 `/scripts/health-check.sh`가 Gateway `/v1/responses`로 LLM fallback 사용. Full Report와 Daily Summary도 같은 JSON을 payload에 포함해 권장 조치를 먼저 매칭한다.
- 복구 알림: Discord Webhook, LLM 사용 금지
- 사용자 요청: LLM 사용 가능
- 6시간 Full Report: LLM 사용 가능
- Daily Summary: LLM 사용 가능
