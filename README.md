# PoppingOps - AI 기반 서버 모니터링 Discord 봇

> 이 저장소는 포트폴리오와 버전관리를 위한 공개 저장소입니다.
> 운영 배포는 GitHub Actions 검증을 통과한 `main` branch commit만 Railway가 자동 배포하도록 구성합니다.

Popping Community 백엔드 서버를 모니터링하는 Discord 운영 봇이다.
OpenClaw Gateway 위에서 3개의 전문 에이전트가 역할을 나누고, 반복적인 헬스체크는 LLM을 쓰지 않는 bash 스크립트가 처리한다.

## 아키텍처

```text
EC2 (`EC2_HOST`)
├── popping-community (Spring Boot actuator: `APP_ACTUATOR_PORT`)
├── mysql (Docker, port 3306)
├── node-exporter (`NODE_EXPORTER_PORT`)
└── mysqld-exporter (`MYSQL_EXPORTER_PORT`)

    ↕ SSH (`EC2_SSH_USER@EC2_HOST:EC2_SSH_PORT`)

Railway Container
├── OpenClaw Gateway (Discord 봇 3개 운영)
│   ├── PoppingOps (main) → 서버/인프라 모니터링
│   ├── PoppingDBA (dba)  → MySQL/InnoDB 분석
│   └── PoppingDev (dev)  → CI/CD 분석
│
└── health-check.sh (백그라운드, LLM 미사용)
    ├── 10분마다 health/resource 체크
    ├── /tmp/health-check-alerts/status-current.env snapshot 갱신
    └── WARN/CRITICAL/복구 알림을 Discord Webhook으로 전송
```

## 동작 방식

### 1. 자동 체크

`scripts/health-check.sh`가 Railway 컨테이너에서 백그라운드로 실행된다.
10분마다 EC2에 SSH로 접속해 actuator, node-exporter, mysqld-exporter 메트릭을 수집한다.

이 경로는 OpenClaw/LLM을 호출하지 않는다. 따라서 정기 체크와 Webhook 알림은 토큰 비용이 없다.

| 항목 | 주기 | 실행 주체 | LLM 사용 | 결과 |
|------|------|-----------|----------|------|
| Health Check | 10분 | `health-check.sh` | X | Spring Boot health, SSH 상태 확인 |
| Resource Snapshot | 10분 | `health-check.sh` | X | 메모리, Load, 디스크, JVM, MySQL, RPS 등 갱신 |
| 이상/복구 알림 | 상태 변경 시 | `health-check.sh` | X | Discord Webhook 알림 |
| Full Report | 6시간 | `full-report-scheduler.sh` → `heartbeat-context.sh full-report` → 필요 시 Gateway `/v1/responses` | 조건부 | 새 이슈/심각도 상승/stale/CI 실패 중심의 압축 점검 |
| Daily Summary | 매일 9AM KST | `daily-summary-scheduler.sh` → `heartbeat-context.sh daily-summary` → Gateway `/v1/responses` | O | 정상이어도 보고하는 일일 요약 |

### 2. Snapshot 기반 서버 상태 보고

사용자가 Discord에서 `서버 상태 확인해줘`처럼 요청하면 PoppingOps는 최신 snapshot을 읽어 빠르게 보고한다.

```bash
cat /tmp/health-check-alerts/status-current.env
```

Snapshot에는 측정 시각이 포함된다. 보고서에는 반드시 `몇 시 몇 분에 측정된 값인지` 표시한다.

RPS, 평균 응답시간, 에러율, MySQL QPS는 exporter counter의 10분 delta로 계산한다. 컨테이너가 막 시작된 첫 체크에서는 이전 sample이 없으므로 `계산 대기`가 정상이다.

Snapshot이 오래된 경우에는 서버 값이 최신처럼 보이지 않도록 데이터 상태를 함께 표시한다.

| Snapshot age | 데이터 상태 | 보고 severity |
|--------------|-------------|---------------|
| 20분 미만 | 최신 | 기존 metric severity 유지 |
| 20분 이상 | 오래됨 | 최소 WARN |
| 30분 이상 | 수집 중단 가능성 | CRITICAL |

### 3. 실시간 서버 상태 보고

사용자가 `실시간 서버 상태 확인해줘`라고 명시하면 PoppingOps가 EC2에 SSH로 접속해 현재 gauge 메트릭을 다시 수집한다.

실시간 모드에서도 RPS/응답시간/에러율 같은 rate 지표는 최신 snapshot 값을 사용한다. 단일 실시간 counter 한 번으로는 rate를 계산할 수 없기 때문이다.

보고서에는 두 시간을 분리해서 표시한다.

| 기준 | 의미 |
|------|------|
| 현재값 측정시각 | 실시간 SSH로 gauge를 수집한 시간 |
| 트래픽 지표 기준 | health-check snapshot이 계산한 최근 10분 평균/delta 시간 |

### 4. Full Report / Daily Summary

Full Report와 Daily Summary는 LLM을 사용한다. 다만 LLM이 매번 직접 메트릭을 수집하는 구조가 아니라, `scripts/heartbeat-context.sh`가 최신 snapshot과 CI/CD 상태를 정리하고 LLM은 그 결과를 요약한다.

| 항목 | 주기 | 데이터 준비 | LLM 역할 | 보고 조건 |
|------|------|-------------|----------|-----------|
| Full Report | 6시간 | `full-report-scheduler.sh`가 helper를 먼저 실행하고 `full_report_should_report=true`일 때만 Gateway 호출 | 새 이슈/심각도 변화/권장 조치 요약 | 변경 없음 또는 반복 WARN이면 LLM 호출 없음 |
| Daily Summary | 매일 9AM KST | `daily-summary-scheduler.sh`가 helper context를 만든 뒤 Gateway `/v1/responses`로 main agent 호출 | 일일 운영 요약 작성 | 정상이어도 항상 보고 |

Full Report는 반복 알림이 아니라 변화 감지용 압축 점검이다. Daily Summary는 하루 한 번 전체 상태를 요약하는 운영 리포트다.

## 운영 문서

- [아키텍처 개요](docs/architecture.md)
- [장애 대응 Runbook](docs/runbook.md)
- [프롬프트 엔지니어링 히스토리](docs/prompt-engineering-history.md)

## 에이전트

### PoppingOps (main)

서버/인프라 모니터링 담당 SRE 에이전트.

| 스킬 | 설명 | 트리거 |
|------|------|--------|
| `grafana-monitor` | health-check snapshot 또는 실시간 SSH 메트릭을 기반으로 서버 상태 보고 | `서버 상태 확인해줘`, `실시간 서버 상태 확인해줘`, `메트릭 확인` |
| `cost-tracker` | LLM API 비용 추정 및 토큰 사용량 확인 | `비용 확인해줘`, `토큰 사용량` |

### PoppingDBA (dba)

MySQL/InnoDB 분석 담당 DBA 에이전트.

| 스킬 | 설명 | 트리거 |
|------|------|--------|
| `slow-query-analyzer` | 슬로우 쿼리 로그와 performance_schema 분석 | `슬로우 쿼리 확인해줘`, `DB 성능 확인` |
| `mysql-monitor` | 커넥션, InnoDB 버퍼풀, 락, 스레드 캐시 분석 | `DB 상태`, `커넥션 확인`, `락 확인` |

### PoppingDev (dev)

CI/CD 및 배포 분석 담당 DevOps 에이전트.

| 스킬 | 설명 | 트리거 |
|------|------|--------|
| `cicd-analyzer` | GitHub Actions 워크플로우 실패와 배포 상태 분석 | `CI 실패 확인해줘`, `배포 상태 확인` |

## 알림 정책

자동 알림은 `DISCORD_WEBHOOK_URL`이 가리키는 Discord Webhook 채널로 전송된다.

| 상태 | 동작 |
|------|------|
| OK 유지 | 조용히 로그만 남김 |
| OK → WARN/CRITICAL | 즉시 Webhook 알림 |
| WARN 유지 | 반복 알림 억제 |
| CRITICAL 유지 | 2시간 또는 3회 체크마다 재알림 |
| WARN/CRITICAL → OK | 복구 알림 전송 |

모니터링 파이프라인 자체도 별도로 감시한다.

| 항목 | 정책 |
|------|------|
| snapshot 갱신 성공 | `/tmp/health-check-alerts/last_success.state` 갱신 |
| SSH/resource parse/snapshot write 실패 1회 | 로그만 기록 |
| 동일 실패 2회 연속 | WARN Webhook 알림 |
| 실패 후 성공 | 복구 알림 |

주요 임계값:

| Metric | WARN | CRITICAL | 복구 기준 |
|--------|------|----------|-----------|
| Memory | 80% 이상 | 95% 이상 | 70% 미만 |
| CPU Load1 (1 vCPU) | 1.0 초과 | 2.0 초과 | 0.8 미만 |
| Disk | 80% 이상 | 90% 이상 | 75% 미만 |
| Avg Response | 1초 초과 | 3초 초과 | 1초 이하 |
| Error Rate | 1% 초과 | 5% 초과 | 1% 이하 |

트래픽 기반 알림은 rate 계산 상태가 `ok`일 때만 판단한다. 첫 snapshot처럼 counter delta가 아직 `init`이면 알림하지 않는다.

## 권장 조치 기준

PoppingOps가 WARN/CRITICAL 상태 또는 "어떻게 조치해?" 질문에 답할 때는 `docs/runbook.md`를 우선 기준으로 사용한다.
Runbook 기반 권장 조치도 기본적으로 안내이며, 재시작/설정 변경/배포 같은 상태 변경 작업은 사용자가 명시적으로 승인하기 전에는 실행하지 않는다.
runbook에 직접 대응 절차가 없으면 `runbook에 직접 절차 없음`을 먼저 밝히고, `추론 기반 권장 확인`으로 read-only 진단만 제안한다.

Fallback 진단은 로그, 메트릭, 상태 확인, 측정시각 확인, cross-validation으로 제한한다.
재시작, 삭제, 설정 변경, 배포, write operation은 사용자가 명시적으로 승인하기 전에는 권장 조치로 제안하지 않는다.

## 프로젝트 구조

```text
├── Dockerfile
├── entrypoint.sh
├── openclaw.json
├── railway.json
├── scripts/
│   ├── health-check.sh
│   ├── heartbeat-context.sh
│   ├── full-report-scheduler.sh
│   └── daily-summary-scheduler.sh
├── workspace/
│   ├── IDENTITY.md
│   ├── SOUL.md
│   ├── TOOLS.md
│   ├── HEARTBEAT.md
│   └── skills/
│       ├── grafana-monitor/
│       └── cost-tracker/
├── workspace-dba/
│   ├── IDENTITY.md
│   ├── SOUL.md
│   ├── TOOLS.md
│   └── skills/
│       ├── slow-query-analyzer/
│       └── mysql-monitor/
├── workspace-dev/
│   ├── IDENTITY.md
│   ├── SOUL.md
│   ├── TOOLS.md
│   └── skills/
│       └── cicd-analyzer/
└── docs/
    ├── architecture.md
    ├── runbook.md
    └── prompt-engineering-history.md
```

## 환경변수

Railway Variables에 설정한다.

| 변수 | 필수 | 설명 |
|------|------|------|
| `DISCORD_TOKEN` | O | PoppingOps Discord 봇 토큰 |
| `DISCORD_DBA_TOKEN` | O | PoppingDBA Discord 봇 토큰 |
| `DISCORD_DEV_TOKEN` | O | PoppingDev Discord 봇 토큰 |
| `FIREWORKS_API_KEY` | O | Fireworks AI API 키 |
| `SSH_PRIVATE_KEY` | O | EC2 접속용 SSH private key |
| `DISCORD_WEBHOOK_URL` | O | health-check 알림용 Discord Webhook URL |
| `DISCORD_FULL_REPORT_WEBHOOK_URL` | 선택 | Full Report 전송용 Webhook URL. 없으면 `DISCORD_REPORT_WEBHOOK_URL`, `DISCORD_WEBHOOK_URL` 순서로 fallback |
| `DISCORD_DAILY_SUMMARY_WEBHOOK_URL` | 선택 | Daily Summary 전송용 Webhook URL. 없으면 `DISCORD_REPORT_WEBHOOK_URL`, `DISCORD_WEBHOOK_URL` 순서로 fallback |
| `DISCORD_REPORT_WEBHOOK_URL` | 선택 | 리포트 전송용 공용 Webhook URL |
| `GH_TOKEN` | 선택 | GitHub CLI 인증 토큰 |
| `GATEWAY_TOKEN` | O | OpenClaw Gateway token |
| `OPENCLAW_GATEWAY_TOKEN` | 선택 | OpenClaw Gateway token override. 설정 시 Daily Summary scheduler가 우선 사용 |
| `EC2_HOST` | 선택 | 모니터링 대상 EC2 host. 기본값 `52.79.56.222` |
| `EC2_SSH_PORT` | 선택 | EC2 SSH port. 기본값 `2222` |
| `EC2_SSH_USER` | 선택 | EC2 SSH user. 기본값 `ec2-user` |
| `APP_ACTUATOR_PORT` | 선택 | Spring Boot actuator port. 기본값 `8081` |
| `NODE_EXPORTER_PORT` | 선택 | node-exporter port. 기본값 `9100` |
| `MYSQL_EXPORTER_PORT` | 선택 | mysqld-exporter port. 기본값 `9104` |
| `HEALTH_CHECK_INTERVAL_SECONDS` | 선택 | health/resource snapshot 수집 주기. 기본값 `600` |
| `SNAPSHOT_STALE_WARN_MIN` | 선택 | snapshot 오래됨 WARN 기준. 기본값 `20` |
| `SNAPSHOT_STALE_CRITICAL_MIN` | 선택 | snapshot 수집 중단 CRITICAL 기준. 기본값 `30` |
| `FULL_REPORT_INTERVAL_SECONDS` | 선택 | Full Report 점검 주기. 기본값 `21600` |
| `FULL_REPORT_MAX_ATTEMPTS_PER_WINDOW` | 선택 | Full Report 실패 시 주기당 최대 재시도 횟수. 기본값 `3` |
| `DAILY_SUMMARY_MAX_ATTEMPTS_PER_DAY` | 선택 | Daily Summary 실패 시 하루 최대 재시도 횟수. 기본값 `3` |
| `OPENCLAW_LOG_LEVEL` | 선택 | `debug` 설정 시 LLM duration/context 진단 로그 확인 가능 |

## 배포 흐름

GitHub `main` branch에 push하면 GitHub Actions `Validate` workflow가 shell script 문법을 먼저 검증한다.
Railway service는 GitHub repository와 연결하고, `Wait for CI`를 켜서 CI 성공 commit만 자동 배포한다.
검증 실패 시 Railway 배포가 시작되지 않는 것이 정상 동작이다.

Dockerfile 기반으로 빌드되며, 컨테이너 시작 시 `entrypoint.sh`가 다음을 수행한다.

1. 필수 Railway Variables 누락 여부 확인. 누락 시 즉시 종료
2. SSH key 생성 및 EC2 접속 테스트
3. `openclaw.json`에 secret 주입
4. DBA/Dev 에이전트 등록 및 Discord account binding
5. `health-check.sh` 백그라운드 실행
6. OpenClaw Gateway 실행 및 HTTP readiness 확인
7. Gateway 준비 완료 후 `daily-summary-scheduler.sh`, `full-report-scheduler.sh` 백그라운드 실행

## 주의사항

- `DISCORD_WEBHOOK_URL`은 secret이다. 채팅이나 공개 로그에 노출되면 새 Webhook을 발급해서 교체한다.
- `DISCORD_WEBHOOK_URL` 또는 `GATEWAY_TOKEN`이 없으면 운영 알림/리포트가 불완전해지므로 컨테이너 시작 단계에서 실패시킨다.
- `/tmp/health-check-alerts`는 컨테이너 로컬 상태이므로 재시작 직후 첫 rate 계산은 `init`일 수 있다.
- Prometheus 서버는 현재 사용하지 않는다. Rate 지표는 `health-check.sh`가 이전 snapshot과 현재 counter 차이로 계산한다.
- 정기 이상 감지는 LLM 분석 없이 동작한다. LLM은 사용자 요청, Full Report, Daily Summary에서만 사용한다.
