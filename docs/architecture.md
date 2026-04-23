# PoppingOps Architecture

PoppingOps는 반복적인 서버 감시는 deterministic script가 처리하고, 해석이 필요한 보고만 LLM이 맡는 구조다.
목표는 운영 신호를 빠르게 수집하면서도 정상 상태에서는 LLM 비용과 알림 노이즈를 만들지 않는 것이다.

## Layer Overview

```text
EC2 exporters / Spring Boot actuator
  -> Detection layer: scripts/health-check.sh
  -> State layer: /tmp/health-check-alerts/status-current.env
  -> Analysis layer: PoppingOps LLM
  -> Notification layer: Discord Webhook
  -> Interaction layer: Discord bot
```

## Detection Layer

`scripts/health-check.sh`가 Railway 컨테이너에서 백그라운드로 실행된다.
10분마다 EC2에 SSH로 접속해 Spring Boot health, node-exporter, mysqld-exporter, actuator metrics를 수집한다.

임계값 판단과 상태 전이 감지는 LLM 없이 bash에서 직접 처리한다.
WARN/CRITICAL 알림이 실제 전송되면 백그라운드에서 권장 조치를 후속 Discord 메시지로 보낸다. `config/runbook-recommendations.json`에 매칭되는 알림은 LLM 없이 권장 조치를 사용하고, 그 외 알림만 Gateway `/v1/responses` LLM fallback을 호출한다. 이 후속 단계는 알림 판단에 영향을 주지 않으며, 실패해도 1차 알림 자체에는 영향을 주지 않는다.

주요 자동 판단 기준:

| Metric | WARN | CRITICAL |
|--------|------|----------|
| Memory | 80% 이상 | 95% 이상 |
| CPU Load1 | 1.0 초과 | 2.0 초과 |
| Disk | 80% 이상 | 90% 이상 |
| Avg Response | 1s 초과 | 3s 초과 |
| Error Rate | 1% 초과 | 5% 초과 |

RPS 급감은 트래픽 패턴에 따른 오탐 가능성이 커서 현재 자동 알림 기준에 넣지 않는다.

health-check 자체도 감시 대상이다. health SSH, resource SSH, resource parse, snapshot write 실패가 같은 항목에서 2회 연속 발생하면 서버 장애와 별도로 "모니터링 장애" WARN을 보낸다.

## State Layer

최신 수집 결과는 `/tmp/health-check-alerts/status-current.env`에 snapshot으로 저장된다.
PoppingOps는 사용자 질문, Full Report, Daily Summary에서 이 snapshot을 우선 읽는다.

주요 상태 파일:

| Path | Purpose |
|------|---------|
| `/tmp/health-check-alerts/status-current.env` | 최신 서버/DB/트래픽 snapshot |
| `/tmp/health-check-alerts/last_success.state` | 마지막 snapshot 갱신 성공 시각 |
| `/tmp/health-check-alerts/*.state` | metric 상태, 중복 알림, scheduler 실행 상태 |

Snapshot freshness 기준:

| Snapshot age | Status | Meaning |
|--------------|--------|---------|
| 20분 미만 | OK | 최신 데이터 |
| 20분 이상 | WARN | 오래된 snapshot |
| 30분 이상 | CRITICAL | 수집 중단 가능성 |

보고서에는 측정 시각과 freshness를 함께 표시한다.

```text
측정시각: 2026-04-21 14:00 KST
데이터 상태: 오래됨, 67분 전 snapshot
```

`/tmp` 기반 상태는 컨테이너 재시작 시 초기화될 수 있다. 재시작 직후 첫 rate 계산은 `init` 상태가 될 수 있으며, 이는 정상 동작이다.
이 경우 복구 상태 기억, 중복 알림 상태, CRITICAL reminder 상태도 초기화될 수 있다.

## Analysis Layer

PoppingOps LLM은 모든 체크를 직접 수행하지 않는다.
LLM은 이미 수집된 snapshot과 helper output을 해석해 운영자가 읽을 수 있는 보고서로 바꾸는 역할을 맡는다.

LLM이 사용되는 경로:

| Flow | Trigger | Input |
|------|---------|-------|
| User request | Discord bot interaction | 최신 snapshot 또는 실시간 SSH gauge |
| Full Report | `scripts/full-report-scheduler.sh` | `heartbeat-context.sh full-report` output |
| Daily Summary | `scripts/daily-summary-scheduler.sh` | `heartbeat-context.sh daily-summary` output |
| Alert recommendation | `health-check.sh` WARN/CRITICAL 알림 전송 성공 후 | runbook mapping 또는 알림 메시지 + 현재 snapshot |

자동 작업의 LLM 호출은 스크립트가 OpenClaw Gateway `/v1/responses`를 호출하는 방식이다. 구조화 runbook recommendation에 매칭되는 반복 알림은 LLM 없이 처리하고, 매칭이 없는 fallback만 Gateway를 사용한다.

`heartbeat-context.sh`는 snapshot age, freshness status, last_success age, GitHub Actions context를 deterministic하게 만든 뒤 LLM input으로 넘긴다.
Full Report는 snapshot stale WARN/CRITICAL도 보고 필요 조건으로 본다.

정기 health-check의 임계값 판단은 이 레이어를 거치지 않는다. WARN/CRITICAL 알림 전송 성공 시 `config/runbook-recommendations.json`에 있는 권장 조치는 health-check가 LLM 없이 생성하고, 그 외 알림만 Gateway를 통해 LLM fallback을 호출한다. Full Report와 Daily Summary도 같은 JSON을 payload에 넣어 권장 조치 섹션의 우선 기준으로 사용한다.

## Notification Layer

자동 알림은 Discord Webhook으로 전송된다.
`DISCORD_WEBHOOK_URL`은 WARN/CRITICAL/복구 알림에 사용하고, 리포트는 전용 webhook이 있으면 우선 사용한다.

Webhook 알림 정책:

| Event | Behavior |
|-------|----------|
| OK 유지 | 알림 없음 |
| OK -> WARN/CRITICAL | 즉시 전송 |
| WARN 유지 | 반복 알림 억제 |
| CRITICAL 유지 | 2시간 또는 3회 체크마다 재알림 |
| WARN/CRITICAL -> OK | 복구 알림 전송 |

WARN/CRITICAL 알림이 실제 전송되면 백그라운드에서 권장 조치를 후속 Discord 메시지로 보낸다. 중복 억제된 알림과 복구 알림에는 권장 조치를 붙이지 않는다. 권장 조치 생성 실패는 알림 자체에 영향을 주지 않는다.

알림은 두 종류로 분리한다.

| Alert Type | Source | Example |
|------------|--------|---------|
| 서버 장애 | metric 상태 전이 | memory WARN, app health DOWN, error rate CRITICAL |
| 모니터링 장애 | health-check self-monitoring | resource SSH 2회 실패, resource parse 2회 실패, snapshot write 실패 |

## Interaction Layer

Discord bot은 사용자의 질문과 운영 요청을 받는 대화 인터페이스다.
사용자가 "서버 상태 확인"을 요청하면 PoppingOps는 최신 snapshot을 읽어 빠르게 답한다.
"실시간"이 명시되면 SSH로 현재 gauge metric을 다시 수집하고, rate 기반 지표는 최신 snapshot 값을 함께 사용한다.
snapshot이 오래됐으면 정상 수치처럼 보이더라도 freshness WARN/CRITICAL을 먼저 드러낸다.

역할별 에이전트:

| Agent | Scope |
|-------|-------|
| PoppingOps | 서버, 인프라, 트래픽 모니터링 |
| PoppingDBA | MySQL/InnoDB 분석 |
| PoppingDev | CI/CD와 배포 상태 분석 |

## Design Boundary

핵심 경계는 수집/판단과 해석/대화의 분리다.

- `health-check.sh`: 빠른 수집, 임계값 판단, snapshot 저장, webhook 알림, WARN/CRITICAL 시 runbook 기반 권장 조치 후속 전송
- `heartbeat-context.sh`: LLM에 넣을 deterministic context 생성
- PoppingOps LLM: context 요약, 원인 후보 정리, 운영자용 설명
- Discord bot: 사용자의 질문을 받아 적절한 에이전트와 분석 흐름으로 연결

이 구조 덕분에 정상 상태의 반복 체크는 토큰을 쓰지 않는다. WARN/CRITICAL 권장 조치도 `config/runbook-recommendations.json`에 매칭되면 토큰을 쓰지 않으며, LLM은 사용자 요청, Full Report, Daily Summary, 그리고 mapping에 없는 알림의 fallback에서 사용한다.
장애 대응 절차는 [runbook](runbook.md)에 분리되어 있다.
모니터링 대상인 Popping-community 서버의 런타임 환경과 운영 해석 기준은 [target-system](target-system.md)에 분리되어 있다.

## Deployment Pipeline

`main` branch push 이후 GitHub Actions가 shell script 문법을 검증한다.
Railway service는 GitHub repository와 연결되어 있고, `Wait for CI`가 켜진 상태에서 CI 성공 commit만 배포한다.

## Startup Guardrail

컨테이너 시작 시 `entrypoint.sh`는 필수 Railway Variables를 먼저 검증한다.
`DISCORD_TOKEN`, `DISCORD_DBA_TOKEN`, `DISCORD_DEV_TOKEN`, `FIREWORKS_API_KEY`, `SSH_PRIVATE_KEY`, `DISCORD_WEBHOOK_URL`, `GATEWAY_TOKEN` 중 하나라도 없으면 background process를 시작하지 않고 종료한다.
