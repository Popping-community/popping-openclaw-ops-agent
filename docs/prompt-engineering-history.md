# PoppingOps 프롬프트 엔지니어링 개선 히스토리

PoppingOps 봇의 SOUL.md, SKILL.md, HEARTBEAT.md를 반복 개선하며 정확도와 신뢰성을 높인 과정을 기록한다.

---

## 1. 할루시네이션 방지 — 누적 데이터 오보 문제

### 문제 상황
봇에게 "슬로우 쿼리 확인해줘"를 요청했을 때, **이미 해결된 좋아요 풀스캔 쿼리**를 현재 문제로 보고함.

```
🐢 [WARN] 두 개의 무거운 UPDATE 쿼리 발견
- 댓글 좋아요 집계 업데이트: 총 실행 시간 56.6초
- 게시글 좋아요 집계 업데이트: 총 실행 시간 26.9초
```

### 원인 분석
`performance_schema.events_statements_summary_by_digest`는 **MySQL 재시작 이후 누적** 데이터를 저장한다.
봇은 누적 합계(SUM_TIMER_WAIT)를 보고 "현재 문제"로 판단했으나, 실제로는 과거에 해결된 이슈의 잔여 데이터였다.

### Before (slow-query-analyzer/SKILL.md)
```markdown
## Analysis Checklist
1. Identify queries with Query_time > 1s
2. Check Rows_examined vs Rows_sent ratio
3. Look for missing index patterns
```

### After
```markdown
## Important: Cumulative vs Current

performance_schema.events_statements_summary_by_digest stores **cumulative** data since last MySQL restart.
High total time does NOT mean a current problem — it may be a resolved issue.

When reporting:
- Clearly state that stats are **cumulative since last restart**
- Focus on AVG_TIMER_WAIT (average per execution) rather than SUM_TIMER_WAIT (total)
- Check slow query **log** (Method 1) for **recent** slow queries — this is the real-time indicator
- If the log only shows exporter queries, report "no recent user slow queries detected"
```

### 결과
- 봇이 누적 데이터와 현재 문제를 구분하여 보고
- `SUM_TIMER_WAIT` 대신 `AVG_TIMER_WAIT` 기준으로 분석
- 슬로우 쿼리 로그에 실제 최근 쿼리가 없으면 "최근 사용자 슬로우 쿼리 없음"으로 보고

---

## 2. 알림 기준 부재 — 과잉/과소 보고 문제

### 문제 상황
봇이 Heartbeat 체크 시 **언제 알림을 보내고 언제 조용히 할지** 기준이 없었다.
정상 상태에서도 불필요한 보고를 하거나, 반대로 중요한 경고를 놓칠 수 있는 구조였다.

### Before (HEARTBEAT.md)
```markdown
## Every 30 minutes
- Check Spring Boot actuator health
- If health is DOWN or unreachable, alert immediately on Discord
```
→ DOWN일 때만 알림 기준이 있고, WARN/INFO 등 중간 단계 기준 없음

### After
```markdown
## Alert Rules

| Level | Action | Example |
|-------|--------|---------|
| CRITICAL | 즉시 알림 | Health DOWN, SSH 불가, 디스크 90%+, 메모리 95%+ |
| WARN | 즉시 알림 | 메모리 80%+, CPU Load > 1.0, 슬로우 쿼리 발견, CI 실패 |
| INFO | 하루 1회 요약 (오전 9시 KST) | 모든 지표 정상 |
| 정상 | 조용히 (HEARTBEAT_OK) | 모든 게 정상이고 요약 시간이 아닐 때 |

핵심 원칙:
- WARN/CRITICAL은 발견 즉시 보고. 절대 건너뛰지 않는다.
- 모든 게 정상이면 조용히 넘어간다.
- 매일 오전 9시에는 정상이어도 전체 상태 요약을 한 번 보고한다.
- 같은 WARN을 30분 내 반복 보고하지 않는다 (중복 방지).
```

### 결과
- 명확한 4단계 알림 기준으로 과잉 보고 방지
- 중복 알림 방지 (30분 내 동일 WARN 반복 차단)
- 하루 1회 정상 상태 요약으로 "봇이 살아있나?" 불안 해소

---

## 3. 안전장치 부재 — 위험 명령 실행 가능성

### 문제 상황
SOUL.md에 "read-only access"라고만 적혀있었으나, 구체적으로 어떤 명령이 허용/차단되는지 명시하지 않았다.
LLM이 문맥에 따라 `docker restart`나 `rm` 같은 위험한 명령을 실행할 가능성이 있었다.

### Before (SOUL.md - Boundaries)
```markdown
## Boundaries
- Do NOT modify production code or configs
- Do NOT restart services without explicit permission
- Do NOT store or display credentials in chat
- Read-only access to logs and metrics only
```

### After (SOUL.md - Guardrails)
```markdown
## Guardrails (Hallucination & Safety Prevention)

### 1. Command Allowlist — STRICTLY ENFORCED
Allowed: curl, cat, tail, head, grep, docker logs/stats/ps, gh run list/view, echo, uptime, df, free
BLOCKED: rm, docker stop/restart/rm, kill, sudo (write), DROP/DELETE/UPDATE/INSERT, reboot, shutdown

### 2. Data Validation — CHECK BEFORE REPORTING
| Metric | Valid Range | If Out of Range |
| CPU % | 0–100% | Flag as "데이터 오류 가능성" |
| Memory % | 0–100% | Flag as "데이터 오류 가능성" |
| Response time | > 0ms | 0ms = "데이터 누락 가능성" |

### 3. Source Transparency — ALWAYS CITE SOURCE
Every metric must include its source: (source: node-exporter:9100)
If unavailable: "수집 실패 (SSH 연결 타임아웃)"

### 4. Cross-validation — DETECT CONTRADICTIONS
health=UP but HTTP requests=0 → "Health UP이나 트래픽 없음 — 확인 필요"
CPU=0% but Load Avg > 1.0 → "CPU/Load 데이터 불일치"
```

### 결과
- 명령 화이트리스트로 위험 명령 원천 차단
- 비정상 데이터 자동 플래그 (CPU > 100% 등)
- 모든 수치에 출처 명시 → 신뢰성 향상
- 데이터 모순 시 양쪽 값 모두 보고 → 은폐 방지

---

## 4. 인프라 환경 전환 — Prometheus → Direct Exporter Access

### 문제 상황
로컬에서는 Prometheus가 있어서 PromQL로 메트릭을 조회했으나,
Railway 배포 시 로컬 Prometheus에 접근 불가.

### Before (grafana-monitor/SKILL.md)
```bash
# Prometheus PromQL 쿼리
curl -s 'http://localhost:9090/api/v1/query?query=sum(rate(http_server_requests_seconds_count{job="popping-prod"}[1m]))'
```

### After
```bash
# SSH로 EC2 exporter 직접 조회
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 \
  "curl -s http://localhost:8081/actuator/prometheus | grep -E '^http_server_requests_seconds_(count|sum)'"
```

### 변경 이유
- Railway → EC2 간 Prometheus 없이 직접 exporter 접근
- Raw Prometheus exposition format을 grep으로 파싱
- 단일 SSH 세션으로 3개 exporter (actuator:8081, node:9100, mysql:9104) 동시 조회

### 결과
- Prometheus 의존성 제거 → Railway에서 독립적으로 동작
- SSH 1회 연결로 전체 메트릭 수집 → 네트워크 효율성 향상

---

## 5. SSH 포트 차단 대응 — 네트워크 제약 해결

### 문제 상황
Railway 컨테이너에서 EC2로 SSH(포트 22) 연결 시 타임아웃 발생.
Railway 플랫폼이 아웃바운드 포트 22를 차단하고 있었다.

### 디버깅 과정
1. entrypoint.sh에 SSH 디버그 로그 추가 (`ssh -v`)
2. `debug1: connect to address 52.79.56.222 port 22: Connection timed out` 확인
3. EC2 보안 그룹은 0.0.0.0/0 허용 → 보안 그룹 문제 아님
4. Railway 아웃바운드 포트 22 차단으로 결론

### 해결
EC2 sshd에 포트 2222 추가 (기존 22번도 유지):
```bash
sudo sed -i 's/#Port 22/Port 22\nPort 2222/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```
모든 스킬 파일의 SSH 명령에 `-p 2222` 추가.

### 교훈
- 클라우드 PaaS는 보안상 아웃바운드 포트 22를 차단할 수 있음
- SSH를 비표준 포트로 설정하면 대부분의 네트워크 제약을 우회 가능
- 443(HTTPS)은 nginx와 충돌할 수 있으므로 2222 같은 전용 포트 권장

---

## 6. 시크릿 관리 — Docker 이미지 보안

### 문제 상황
초기 openclaw.json에 API key, Discord token이 하드코딩되어 있었다.
Docker 이미지에 포함되면 이미지 레이어에서 시크릿 추출 가능.

### Before
```json
{
  "channels": {
    "discord": {
      "token": "REDACTED_DISCORD_TOKEN"
    }
  },
  "models": {
    "providers": {
      "fireworks": {
        "apiKey": "REDACTED_FIREWORKS_API_KEY"
      }
    }
  }
}
```

### After
```json
{
  "channels": {
    "discord": {
      "token": "DISCORD_TOKEN_PLACEHOLDER"
    }
  },
  "models": {
    "providers": {
      "fireworks": {
        "apiKey": "FIREWORKS_API_KEY_PLACEHOLDER"
      }
    }
  }
}
```
```bash
# entrypoint.sh에서 런타임 주입
sed -i "s|DISCORD_TOKEN_PLACEHOLDER|${DISCORD_TOKEN}|g" "$CONFIG"
sed -i "s|FIREWORKS_API_KEY_PLACEHOLDER|${FIREWORKS_API_KEY}|g" "$CONFIG"
```

### 결과
- Docker 이미지에 시크릿 없음 (플레이스홀더만 존재)
- Railway 환경변수로 런타임 주입 → 업계 표준 방식
- 이미지 유출 시에도 시크릿 안전

---

## 7. Heartbeat 비용 최적화 — LLM 호출 87% 절감

### 문제 상황
Heartbeat가 30분마다 실행될 때 **매번 LLM을 호출**하여 메트릭을 분석했다.
서버가 정상인 경우(대부분)에도 LLM 토큰을 소비하여 불필요한 비용 발생.
하루 약 77회 LLM 호출 → 월 ~$5.4 예상.

### Before (HEARTBEAT.md)
```markdown
## Every 30 minutes
- Check Spring Boot actuator health
- If health is DOWN or unreachable, alert immediately on Discord
```
→ 매번 LLM이 SSH 명령 실행 + 결과 분석 = 항상 토큰 소비

### After
```markdown
## Cost-Efficient Heartbeat Strategy
원칙: 단순 체크는 스크립트로, 분석이 필요할 때만 LLM 호출

## Every 30 minutes — Health Quick Check
사전 체크 (LLM 불필요):
  curl -sf .../actuator/health | grep -q UP && echo HEALTHY || echo DOWN
- HEALTHY → HEARTBEAT_OK (LLM 호출 없음)
- DOWN → CRITICAL 알림 (LLM으로 상세 분석)

## Every 1 hour — Resource Quick Check
사전 체크로 mem/load/disk 수치를 수집하고 임계값 비교.
정상이면 HEARTBEAT_OK, 이상이면 LLM 분석.
```

### 한계
HEARTBEAT.md에 "사전 스크립트로 LLM 호출 절감"이라고 설계했으나, **OpenClaw 런타임 자체가 LLM을 통해 동작**하므로 사전 체크 판단 자체에도 토큰이 소비되었다.
실제로는 매 하트비트마다 HEARTBEAT.md + SOUL.md + TOOLS.md가 컨텍스트로 로드되어 입력 토큰이 발생했고, 87% 절감은 달성되지 않았다.
→ 10번에서 외부 bash 스크립트 분리로 해결

---

## 8. 비용 추적 스킬 — LLM 운영 비용 가시화

### 문제 상황
봇이 얼마나 비용을 쓰고 있는지 추적할 방법이 없었다.
Fireworks 대시보드에서만 확인 가능했고, 봇 자체적으로 비용 인식이 없었다.

### 해결
`cost-tracker` 스킬 추가:
- DeepSeek V3.2 가격 기반 비용 추정
- 체크 유형별(Heartbeat/사용자 쿼리) 토큰 사용량 산출
- "비용 확인해줘" 명령으로 일/월 예상 비용 조회
- 비용 절약 팁 자동 제안

### 한계
- Fireworks `/v1/usage` API가 존재하지 않아 **실제 사용량 조회 불가** — 웹 대시보드(fireworks.ai/account/billing)에서만 확인 가능
- 스킬이 HEARTBEAT.md의 설계 수치(~10회/일)를 하드코딩하여 추정 → 실제 빌링과 4배 이상 괴리 발생
  - 봇 보고: ~$0.7/월 (설계 의도 기반 추정)
  - 실제 Fireworks 빌링: $3.06 / 8.43M 토큰 (매 하트비트마다 LLM 호출)
- → 10번(외부 bash 분리) 적용 후 cost-tracker의 추정 공식도 실제 구조(5회/일)에 맞게 수정

### 결과
- 봇이 자체적으로 비용을 인식하고 보고 가능
- 단, 실제 빌링과의 정확도는 낮음 — 참고용 추정치로만 활용

---

## 9. 멀티 에이전트 — 역할 분리형 아키텍처

### 문제 상황
단일 에이전트(PoppingOps)가 서버 모니터링, DB 분석, CI/CD 분석을 모두 담당했다.
하나의 SOUL.md에 모든 전문성을 담으려니 프롬프트가 비대해지고, 각 영역의 분석 깊이가 얕아졌다.

### Before
```
PoppingOps (단일 에이전트)
├── SOUL.md (모니터링 + DB + CI/CD 전부)
├── grafana-monitor skill
├── slow-query-analyzer skill
├── cicd-analyzer skill
└── cost-tracker skill
```
→ 하나의 에이전트가 모든 도메인을 처리 → 전문성 분산

### After
```
PoppingOps (main) → #monitoring 채널 전용 + #openclaw 공유
├── SOUL.md: 서버 모니터링 전문 (SRE 역할)
├── grafana-monitor, cost-tracker skills
│
PoppingDBA → #database 채널 전용 + #openclaw 공유
├── SOUL.md: MySQL/InnoDB 전문 (DBA 역할)
├── slow-query-analyzer, mysql-monitor skills
│
PoppingDev → #cicd 채널 전용 + #openclaw 공유
├── SOUL.md: CI/CD/배포 전문 (DevOps 역할)
├── cicd-analyzer skill
```

### 설계 포인트

**1. 에이전트별 전문 SOUL.md:**
- PoppingOps: "Data first, SRE on Slack" — 수치와 임계값 중심
- PoppingDBA: "Query-level analysis, index-aware" — EXPLAIN, 인덱스 전략 중심
- PoppingDev: "Log-driven, root cause focus" — 빌드 로그 파싱, 에러 라인 추적

**2. Discord 채널 접근 제어:**
- 각 에이전트는 별도 Discord 봇 계정으로 동작 (OpenClaw `agents bind`로 매핑)
- 전용 채널: #monitoring(PoppingOps), #database(PoppingDBA), #cicd(PoppingDev) — 해당 에이전트만 접근
- 공유 채널: #openclaw — 모든 에이전트 접근 가능
- `requireMention: false` 설정으로 @멘션 없이도 에이전트 호출 가능

**3. 각 에이전트별 독립 가드레일:**
- PoppingDBA: `SELECT/SHOW/EXPLAIN`만 허용, DDL 차단
- PoppingDev: `gh run/pr list/view`, `gh api`, `curl`, `grep`, `docker logs` 허용, `gh pr merge`/`git push` 차단
- PoppingOps: 기존 명령 화이트리스트 유지

### 결과
- 각 에이전트가 도메인 전문 지식에 집중 → 분석 깊이 향상
- SOUL.md가 간결해져 프롬프트 효율성 향상 (입력 토큰 절감)
- 사용자가 용도에 맞는 전문 에이전트를 선택 가능
- 에이전트 추가/제거가 독립적 → 확장성 확보

### 교훈 — 멀티 에이전트 운영 시 주의점

1. **토큰 소비의 구조적 원인:** HEARTBEAT.md에서 "사전 스크립트로 LLM 호출 절감"을 설계했으나, OpenClaw 런타임 자체가 LLM을 통해 동작하므로 사전 체크 판단 자체에도 토큰이 소비된다. 진정한 토큰 절감을 위해서는 OpenClaw 외부의 순수 cron 스크립트로 분리 필요.
2. **멀티 에이전트 = 장애 영향 범위 확대:** 3개 에이전트(main, dba, dev)가 동일 Fireworks API를 공유하므로, API 장애 시 전체 봇이 동시 다운. fallback 모델 설정 또는 에이전트별 독립 모델 배정 검토 필요.

---

## 10. Heartbeat 외부 분리 — 진짜 토큰 절감

### 문제 상황
7번에서 HEARTBEAT.md에 "사전 스크립트로 LLM 호출 절감"을 설계했으나, OpenClaw 런타임이 LLM 기반으로 동작하므로 사전 체크 판단 자체에도 토큰이 소비되었다.
"정상 시 LLM 호출 0"이 설계 의도였으나, 실제로는 매 하트비트마다 LLM이 HEARTBEAT.md를 읽고 bash 명령을 결정하는 과정에서 입력 토큰이 발생했다.

### Before (7번 구조)
```
매 하트비트 트리거
  → OpenClaw가 LLM 호출 (HEARTBEAT.md + SOUL.md 컨텍스트 로드)
  → LLM이 "bash 사전 체크를 실행해야지" 판단
  → bash 명령 실행
  → LLM이 결과 해석 → "정상이니 HEARTBEAT_OK"
  → 토큰 이미 소비됨 (입력만 ~2,000+ 토큰)
```

### After
```
Railway Container
├── /scripts/health-check.sh (백그라운드 루프, OpenClaw 외부)
│   ├── 30분마다: SSH → actuator health 체크
│   ├── 30분마다: SSH → resource snapshot 갱신
│   ├── 정상 → 아무것도 안 함 (토큰 0)
│   └── 이상/복구 → Discord Webhook URL 대상 채널로 알림 (토큰 0)
│
└── openclaw gateway
    └── 6시간 Full Report + Daily 9AM Summary만 LLM 사용
```

### 변경 내용

**1. `scripts/health-check.sh` (신규):**
- HEARTBEAT.md의 bash 사전 체크를 독립 스크립트로 추출
- 순수 bash + awk로 임계값 판단 (LLM 개입 없음)
- Discord Webhook(`curl -d '{"content":"..."}' $DISCORD_WEBHOOK_URL`)으로 직접 알림
- 동일 알림 30분 내 중복 방지 (md5 해시 비교)

**2. `entrypoint.sh` (수정):**
- `exec openclaw gateway` → `openclaw gateway &` + `health-check.sh &` + `wait`
- 두 프로세스를 병렬 실행하고, 하나가 죽으면 컨테이너 종료

**3. `Dockerfile` (수정):**
- `COPY scripts/ /scripts/` + `chmod +x` 추가

### 결과

| 체크 | 빈도 | 기존 (매번 LLM) | 변경 후 (외부 bash) |
|------|------|-----------------|---------------------|
| Health | 48회/일 | 48 LLM 호출 | 0 (bash 스크립트) |
| Resource Snapshot | 48회/일 | 48 LLM 호출 가능 | 0 (bash 스크립트) |
| Full Report | 4회/일 | 4 LLM 호출 | 4 (유지) |
| Daily Summary | 1회/일 | 1 LLM 호출 | 1 (유지) |
| **합계** | | **101 호출/일 가능** | **5 호출/일 (약 95% 절감)** |

### 배포 후 발견한 버그 및 수정

**1. 디스크 100% 오보 — SSH 이스케이핑 문제:**
- `bash -c '...'` 안에서 `mountpoint="/"` 패턴의 따옴표가 다중 이스케이핑(`\\\"`)을 통과하며 깨짐
- grep이 디스크 메트릭을 못 찾아 빈 값 → 폴백 0/1 → `(1-0/1)*100 = 100%`로 오보
- **수정:** `bash -c`를 heredoc(`<<'REMOTE_SCRIPT'`)으로 교체 → 이스케이핑 불필요

**2. `set -euo pipefail`로 스크립트 전체 종료:**
- SSH 실패나 grep 매치 실패 시 `set -e`에 의해 health-check 프로세스가 죽음
- entrypoint의 `wait -n`에 의해 컨테이너 전체가 종료될 수 있었음
- **수정:** `set -euo pipefail` 제거

**3. 중복 방지가 1건만 추적:**
- 단일 파일에 마지막 알림 1건만 저장 → 메모리 WARN + 디스크 CRITICAL 동시 발생 시 중복 방지 실패
- **수정:** 알림별 해시 파일로 분리 (`/tmp/health-check-alerts/{hash}`)

**4. SSH 배너/MOTD로 인한 파싱 오류:**
- SSH 접속 시 출력되는 배너가 메트릭 결과에 섞여 파싱 실패
- **수정:** health_check는 `tail -1`로 마지막 줄만, resource_check는 `grep "^health="`로 메트릭 줄만 추출

**5. HEARTBEAT.md 6시간/일일 보고 지시 부족:**
- 30분 자동 체크가 외부로 빠지면서, OpenClaw이 6시간/일일 체크를 언제 어떻게 실행하는지 불명확
- **수정:** 수행 주체(OpenClaw Heartbeat), snapshot 우선 사용 원칙, 필요 시 실시간 gauge 보강을 명시

### 교훈
- AI 에이전트 프레임워크 위에서 "LLM 호출 절감"을 설계할 때, **프레임워크 자체가 LLM을 경유하는지** 반드시 확인해야 한다.
- 진짜 토큰 절감은 LLM 런타임 바깥에서 판단 로직을 실행해야 달성된다.
- Discord Webhook은 봇 토큰 없이도 특정 채널에 메시지를 보낼 수 있어, bash 스크립트 알림에 적합하다.
- SSH를 통한 원격 스크립트 실행 시, **다중 이스케이핑보다 heredoc을 사용**해야 안전하다.
- 모니터링 스크립트는 **어떤 실패에도 죽지 않아야** 한다 — `set -e` 금지, 모든 실패를 `|| true`로 흡수.

---

## 11. grafana-monitor SKILL.md 경량화 및 실제 프롬프트 영향 측정

### 배경

`workspace/skills/grafana-monitor/SKILL.md`가 상세 매뉴얼 형태로 길어지면 매 요청마다 LLM 입력 토큰이 증가하고 응답이 느려질 것이라는 가설을 세웠다.
이에 따라 verbose 버전과 경량 버전을 비교했다.

### 변경

**Verbose 버전:**
- 상세 아키텍처 설명
- exporter별 개별 SSH 명령 다수
- 상세 Report Format
- Counter/Gauge 해석 설명
- 확장 Threshold 표

**경량 버전:**
- 단일 SSH 세션 명령 중심
- 핵심 Trigger Phrase
- Gauge/Counter 최소 해석
- 기본 Threshold 표

최종 경량 버전:

| 항목 | 값 |
|------|----|
| 파일 | `workspace/skills/grafana-monitor/SKILL.md` |
| 줄 수 | 50 lines |
| 파일 크기 | 2,492 bytes |
| 근사 토큰 | 약 623 tokens |

### 측정 방법

OpenClaw 로그 레벨을 올려 LLM 호출 구간을 확인했다.

Railway 환경변수:

```bash
OPENCLAW_LOG_LEVEL=debug
```

로그 필터:

```bash
railway logs > railway.log 2>&1
grep -Ei "OPENCLAW_LOG_LEVEL|debug|trace|llm|model|fireworks|duration|elapsed|latency|completion|usage|tokens" railway.log
```

확인한 핵심 로그:

```text
[context-diag] pre-prompt ... systemPromptChars=... promptChars=...
embedded run prompt end ... durationMs=...
embedded run done ... durationMs=...
```

해석 기준:
- `systemPromptChars + promptChars` = 입력 프롬프트 크기 근사
- `embedded run prompt end durationMs` = LLM 호출 시간
- `embedded run done durationMs` = 전체 agent run 시간
- `historyTextChars`가 0인 새 세션만 공정 비교에 사용

### 측정 결과

**초기 새 세션 Discord 요청:**

| 항목 | 값 |
|------|----|
| `messageChannel` | `discord` |
| `historyTextChars` | 0 |
| `systemPromptChars` | 33,826 |
| `promptChars` | 891 |
| 입력 크기 근사 | 34,717 chars ≈ 8,679 tokens |
| LLM 시간 | 133,481 ms (133.5s) |
| 전체 run 시간 | 153,580 ms (153.6s) |

**Verbose 재배포 후 새 세션 Discord 요청:**

| 항목 | 값 |
|------|----|
| `messageChannel` | `discord` |
| `historyTextChars` | 0 |
| `systemPromptChars` | 33,900 |
| `promptChars` | 891 |
| 입력 크기 근사 | 34,791 chars ≈ 8,698 tokens |
| LLM 시간 | 180,951 ms (181.0s) |
| 전체 run 시간 | 213,520 ms (213.5s) |

**히스토리 누적 요청은 제외:**

```text
historyTextChars=54314
```

대화 히스토리가 붙은 요청은 SKILL.md 길이 효과와 섞이므로 비교에서 제외한다.

### 결론

`grafana-monitor/SKILL.md`를 50줄과 verbose 버전으로 바꿔도 `systemPromptChars`는 거의 변하지 않았다.

```text
33,826 chars → 33,900 chars (+74 chars)
```

따라서 현재 OpenClaw 런타임은 `SKILL.md` 전체 본문을 매 요청의 system prompt에 그대로 넣지 않는 것으로 보인다.
SKILL.md 경량화는 파일 자체 토큰은 줄였지만, 이번 측정 기준으로는 실제 LLM 입력 크기 감소 효과가 거의 없었다.

LLM 시간 차이:

```text
133.5s → 181.0s
```

이 차이는 프롬프트 크기 증가가 거의 없었기 때문에 SKILL.md 길이 때문이라고 단정할 수 없다.
모델 부하, Fireworks 응답 지연, 도구 실행, OpenClaw 런타임 오버헤드 등의 변동 가능성이 더 크다.

### 교훈

- 파일 줄 수가 아니라 **OpenClaw가 실제 LLM 요청에 주입한 `systemPromptChars`**를 봐야 한다.
- `SKILL.md` 본문 경량화가 항상 prompt token 절감으로 이어지는 것은 아니다.
- 측정 시 `historyTextChars=0`인 새 세션을 사용해야 한다.
- LLM latency는 `embedded run prompt end durationMs`, 전체 처리 시간은 `embedded run done durationMs`로 본다.
- 현재 큰 입력 크기의 주 원인은 `SOUL.md`, `TOOLS.md`, `HEARTBEAT.md`, 런타임 system prompt 등일 가능성이 높다.
- 실제 토큰 절감 목표라면 다음 후보는 workspace 전체 프롬프트 파일 경량화다.

---

## 12. Health Check 복구 알림 추가

### 문제

`health-check.sh`는 Health/Memory/Load/Disk 이상 감지 시 Discord 알림을 보냈지만, 정상 범위로 돌아왔을 때 복구 알림이 없었다.
운영자는 WARN/CRITICAL 이후 실제로 복구됐는지 직접 다시 확인해야 했다.

기존 흐름:

```text
OK → WARN/CRITICAL: 알림
WARN/CRITICAL 유지: 중복 방지
WARN/CRITICAL → OK: 알림 없음
```

### 변경

metric별 상태 파일을 추가하고, 단순 메시지 중복 방지가 아니라 상태 전이 기반 알림으로 바꿨다.

상태 저장 위치:

```text
/tmp/health-check-alerts/{key}.state
```

사용하는 상태 키:

```text
app_health.state
ssh.state
resource_parse.state
memory.state
load.state
disk.state
```

새 흐름:

```text
OK → WARN/CRITICAL: 이상 알림
WARN/CRITICAL 유지: 중복 알림 없이 로그만 기록
WARN/CRITICAL → OK: 복구 알림
```

복구 알림은 `INFO` severity와 `✅` 아이콘을 사용한다.

예시:

```text
✅ [INFO] 메모리 사용률 복구됨 — 이전 WARN, 현재 69%
```

기존 동일 메시지 30분 중복 방지는 유지했다.

### 복구 기준

flapping을 막기 위해 복구 기준은 발생 기준보다 낮게 잡았다.

| Metric | WARN | CRITICAL | 복구 |
|--------|------|----------|------|
| Memory | 80%+ | 95%+ | 70% 미만 |
| CPU Load | > 1.0 | > 2.0 | < 0.8 |
| Disk | 80%+ | 90%+ | 75% 미만 |

예시:

```text
메모리 83% → WARN 알림
메모리 78% → WARN 유지, 알림 없음
메모리 69% → 복구 알림
```

### 검증

배포 직후 컨테이너 시작 시 `resource_check`가 즉시 실행되었고, 메모리 92%가 감지되어 `OK → WARN` 상태 전이가 확인됐다.

```text
2026-04-20T19:57:00+00:00 [health-check] Running resource check...
2026-04-20T19:57:02+00:00 [health-check] Alert sent: [WARN] 메모리 사용률 92% (WARN)
2026-04-20T19:57:02+00:00 [health-check] 메모리 사용률: OK -> WARN (92%)
2026-04-20T19:57:02+00:00 [health-check] CPU Load: OK (0)
2026-04-20T19:57:02+00:00 [health-check] 디스크 사용률: OK (65%)
```

복구 알림은 이후 메모리가 70% 미만으로 내려간 다음 `resource_check`에서 전송된다.
13번 개선 이후 `resource_check`는 컨테이너 시작 직후 1회 실행되고, 이후 30분마다 실행된다.

### 교훈

- 모니터링 알림은 발생 알림만으로는 부족하고, 복구 알림까지 있어야 lifecycle이 닫힌다.
- 복구 기준은 발생 기준보다 낮게 둬야 79% ↔ 80% 같은 flapping을 막을 수 있다.
- 중복 방지는 메시지 단위, 복구 판단은 metric state 단위로 분리해야 한다.
- `/tmp` 기반 상태는 컨테이너 재시작 시 초기화된다. 재시작 직후에는 이전 WARN 상태를 모르므로 복구 알림이 나가지 않을 수 있다.

---

## 13. 30분 Snapshot 기반 서버 상태 보고 설계

### 문제

Prometheus 없이 raw exporter counter만 한 번 조회하면 RPS, 평균 응답시간, 에러율 같은 rate 지표를 계산할 수 없다.
기존 Discord 명령은 매번 SSH로 EC2 exporter를 직접 조회하는 구조였고, rate 계산을 하려면 매 요청마다 두 번 샘플링하거나 Prometheus를 재도입해야 했다.

또한 사용자에게 응답할 때 값이 언제 측정된 것인지 명확하지 않았다.

### 결정

Prometheus 재도입 전, 가벼운 방식으로 `health-check.sh`가 30분마다 모든 기본 모니터링 메트릭을 수집하고 snapshot을 저장하게 했다.

구조:

```text
health-check.sh
  ├── 30분마다 EC2 exporter 수집
  ├── 이전 counter sample과 비교해 rate 계산
  ├── /tmp/health-check-alerts/status-current.env 저장
  └── WARN/CRITICAL/복구 알림 처리

grafana-monitor
  ├── 일반 요청: snapshot 읽기
  └── 실시간 요청: SSH 현재 gauge 수집 + snapshot rate 병합
```

### Snapshot 파일

저장 위치:

```text
/tmp/health-check-alerts/status-current.env
```

주요 필드:

```bash
collected_at_epoch="..."
collected_at_utc="2026-04-20T20:30:00+00:00"
collected_at_kst="2026-04-21 05:30 KST"
snapshot_interval_min="30"
data_source="health-check snapshot"

overall_severity="WARN"
overall_status="DEGRADED"
health="HEALTHY"

memory_used_mb="..."
memory_total_mb="..."
memory_pct="..."
disk_used_gb="..."
disk_total_gb="..."
disk_pct="..."
load1="..."
load5="..."
load15="..."

http_requests_total="..."
http_rps="..."
avg_response_sec="..."
error_rate_pct="..."
mysql_qps="..."
slow_queries_delta="..."

rate_status_http="ok/init/reset/missing"
```

첫 resource check는 기준 sample만 저장하므로 rate는 `init`이 될 수 있다.
두 번째 resource check부터 최근 30분 평균 RPS/QPS와 delta가 계산된다.

### 명령 모드

**일반 요청:**

```text
서버 상태 확인해줘
```

동작:

```bash
cat /tmp/health-check-alerts/status-current.env
```

보고 기준:

```text
데이터: health-check 스냅샷
측정시각: {collected_at_kst}
수집주기: 30분
```

**실시간 요청:**

```text
실시간 서버 상태 확인해줘
```

동작:
- Railway 로컬 snapshot에서 rate 지표를 읽는다.
- EC2에 SSH로 접속해 현재 gauge 메트릭을 다시 수집한다.

보고 기준:

```text
현재값 측정시각: {realtime_collected_at_kst}
트래픽 지표 기준: {collected_at_kst} 스냅샷, 최근 {snapshot_interval_min}분 평균
```

### 응답 템플릿 변경

PoppingOps 서버 상태 보고서에 `기준` 섹션을 추가했다.

```text
▸ 기준
  데이터: health-check 스냅샷 / 실시간 SSH + 스냅샷
  측정시각: {snapshot_collected_at_kst}
  실시간 현재값 측정시각: {realtime_collected_at_kst 또는 해당 없음}
  트래픽 지표 기준: 최근 {snapshot_interval_min}분 평균
```

트래픽 항목에는 RPS와 에러율을 추가했다.

```text
▸ 트래픽
  HTTP 요청 (총): {count}
  RPS: {value} req/s
  평균 응답시간: {value}s
  에러율: {pct}%
```

### 교훈

- Prometheus 없이도 counter delta 저장으로 rate 계산은 가능하다.
- 단, 계산 값은 순간값이 아니라 snapshot 간격 평균이다.
- 사용자에게 반드시 측정 시각과 데이터 기준을 같이 보여줘야 한다.
- 일반 보고는 snapshot으로 빠르게 처리하고, 실시간 요청은 gauge만 SSH로 갱신하는 혼합 구조가 비용/속도/정확성의 균형이 좋다.
- `/tmp` 기반 snapshot은 컨테이너 재시작 시 초기화되므로 첫 체크에서는 rate가 `init`일 수 있다.

---

## 14. LLM과 health-check의 책임 경계 확정

### 문제

30분 자동 체크에서 이상이 감지될 때 LLM을 호출해 원인 분석까지 자동으로 수행할지 검토했다.
그러나 WARN/CRITICAL마다 LLM 분석을 자동 실행하면 다음 문제가 생긴다.

- 알림 지연: Webhook 즉시 알림보다 느리다.
- 비용 증가: 메모리 WARN처럼 자주 발생할 수 있는 경고가 LLM 호출로 이어진다.
- 중복 분석 위험: 같은 장애가 지속될 때 30분마다 LLM이 반복 호출될 수 있다.
- 운영 알림의 본질 훼손: 1차 알림은 빠르고 확실해야 한다.

### 결정

자동 체크 경로에서는 LLM을 사용하지 않는다.
LLM은 메트릭 수집자가 아니라, 사용자가 요청했을 때 snapshot/실시간 결과를 해석하는 분석자 역할로 둔다.

최종 책임 분리:

```text
health-check.sh
  ├── 30분마다 EC2 메트릭 수집
  ├── memory/disk/load/health 임계값 판단
  ├── RPS/응답시간/에러율/MySQL QPS 계산
  ├── status-current.env snapshot 저장
  ├── WARN/CRITICAL 즉시 Webhook 알림
  └── 복구 알림
  => LLM 미사용

PoppingOps LLM
  ├── "서버 상태 확인해줘" 요청 시 snapshot 읽기
  ├── "실시간 서버 상태 확인해줘" 요청 시 현재 gauge SSH 수집 + snapshot rate 병합
  ├── 사용자가 경고 원인 분석을 요청하면 snapshot/실시간 결과 해석
  ├── 6시간 Full Report
  └── Daily Summary
  => 분석/요약/권장 조치에만 LLM 사용
```

### 현재 사용자 명령별 동작

| 상황 | 메트릭 수집 | LLM 사용 | 비고 |
|------|-------------|----------|------|
| 30분 자동 체크 | `health-check.sh` | X | 이상/복구 알림도 Webhook 직접 전송 |
| `서버 상태 확인해줘` | snapshot 읽기 | O | LLM은 이미 계산된 값을 요약/분석 |
| `실시간 서버 상태 확인해줘` | SSH 현재 gauge + snapshot rate | O | 현재값 시각과 snapshot 시각을 둘 다 표기 |
| 경고 원인 분석 요청 | snapshot/실시간 결과 사용 | O | 사용자가 요청한 경우에만 분석 |
| 6시간 Full Report | snapshot 중심 | O | 아직 OpenClaw LLM 설계 유지 |
| Daily Summary | snapshot 중심 | O | 아직 OpenClaw LLM 설계 유지 |

### 알림 정책

자동 이상 감지:

```text
OK → WARN/CRITICAL
  health-check.sh가 즉시 Webhook 알림
  LLM 호출 없음
```

장애 지속:

```text
WARN/CRITICAL 유지
  상태 로그만 기록
  중복 Webhook/LLM 분석 없음
```

복구:

```text
WARN/CRITICAL → OK
  health-check.sh가 INFO 복구 알림
  LLM 호출 없음
```

사용자가 원인 분석 요청:

```text
"방금 메모리 경고 분석해줘"
  PoppingOps LLM이 snapshot과 필요 시 실시간 gauge를 보고 분석
```

### 교훈

- 자동 모니터링의 1차 책임은 빠른 감지와 알림이다. 이 경로에 LLM을 넣지 않는다.
- LLM은 메트릭 수집/임계값 판단이 아니라, 사람이 필요할 때 해석과 권장 조치를 제공하는 계층이다.
- snapshot을 중간 산출물로 두면 bash와 LLM의 책임을 명확히 분리할 수 있다.
- 비용 절감의 핵심은 "주기 실행"을 LLM 밖으로 빼고, "사용자 요청 기반 분석"만 LLM에 남기는 것이다.

---

## 15. 운영 문서 최신화 — snapshot/LLM 책임 경계 반영

### 배경

README, HEARTBEAT, TOOLS, cost-tracker가 서로 다른 시점의 설계를 설명하고 있었다.
특히 `Resource Quick Check 1시간`, `#monitoring 고정 Webhook`, `Prometheus + Grafana 모니터링`, `30분/1시간 체크` 같은 표현이 현재 구현과 맞지 않았다.

현재 구현은 다음이 기준이다.

- `health-check.sh`가 30분마다 health/resource snapshot을 함께 갱신한다.
- RPS, 평균 응답시간, 에러율은 Prometheus 서버 없이 snapshot 간 counter delta로 계산한다.
- Webhook 알림 채널은 `DISCORD_WEBHOOK_URL`이 결정한다. `#alerts` 분리를 권장하지만 코드에 채널명이 고정되어 있지 않다.
- 자동 체크, 임계값 판단, 이상/복구 알림은 LLM을 사용하지 않는다.
- LLM은 사용자 요청, Full Report, Daily Summary의 분석/요약 계층으로만 둔다.

### 변경

수정한 문서:

- `README.md`: 프로젝트 설명 중심으로 재작성, 운영 명령 블록 제거
- `workspace/HEARTBEAT.md`: 30분 health/resource snapshot 구조와 LLM 책임 경계로 갱신
- `workspace/TOOLS.md`: snapshot 파일, rate 계산, 실시간 gauge 수집 구조 추가
- `workspace/USER.md`: Prometheus/Grafana 기반 설명을 direct exporter snapshot 구조로 변경
- `workspace/SOUL.md`: counter rate 설명을 30분 snapshot delta 기준으로 정정
- `workspace/skills/cost-tracker/SKILL.md`: 30분 자동 체크와 Webhook 알림의 토큰 비용 0 구조로 정정

### 교훈

- 운영 문서는 구현 변경 직후 같이 맞춰야 한다. 특히 주기, 알림 채널, LLM 사용 여부는 비용과 장애 대응에 직접 영향을 준다.
- 히스토리 문서는 과거 의사결정 기록이므로 오래된 항목을 지우기보다 최신 항목을 추가해 설계 변화를 추적한다.

---

## 16. Snapshot stale 감지 — 오래된 데이터를 최신처럼 보고하지 않기

### 배경

`서버 상태 확인해줘`는 최신 `/tmp/health-check-alerts/status-current.env` snapshot을 읽어 빠르게 응답한다.
하지만 `health-check.sh`가 죽거나 Railway 컨테이너 내부 상태 갱신이 멈추면, 오래된 snapshot이 계속 남아 있을 수 있다.
이 경우 마지막 정상값을 최신 상태처럼 보고하는 것이 가장 위험하다.

### 변경

`grafana-monitor`가 snapshot을 읽을 때 현재 시각과 `collected_at_epoch` 차이를 계산해 freshness 값을 함께 출력하도록 했다.

```text
snapshot_age_min="{minutes}"
snapshot_freshness_status="OK|WARN|CRITICAL"
snapshot_freshness_label="최신|오래됨|수집 중단 가능성"
```

판단 기준:

| Snapshot age | 상태 | 보고 severity |
|--------------|------|---------------|
| < 45분 | OK / 최신 | 기존 metric severity 유지 |
| 45분 이상, 90분 미만 | WARN / 오래됨 | 최소 WARN |
| 90분 이상 | CRITICAL / 수집 중단 가능성 | CRITICAL |

반영한 문서:

- `workspace/skills/grafana-monitor/SKILL.md`: snapshot freshness 계산 명령 추가
- `workspace/SOUL.md`: 서버 상태 보고서의 `데이터 상태` 필드와 severity 승격 규칙 추가
- `workspace/HEARTBEAT.md`: 사용자 요청 보고 시 stale 판단 규칙 추가
- `README.md`: snapshot stale 정책 문서화

### 교훈

- 모니터링 값은 값 자체만큼 수집 시각이 중요하다.
- 캐시/snapshot 기반 보고에서는 stale 여부를 별도 상태로 다루어야 한다.
- 오래된 데이터는 `정상`이 아니라 `수집 신뢰도 저하`로 보고해야 한다.

---

## 17. CRITICAL 지속 재알림 — 조용한 장애 지속 방지

### 배경

상태 전이 기반 알림을 도입한 뒤에는 `OK → WARN/CRITICAL` 최초 알림과 `WARN/CRITICAL → OK` 복구 알림만 전송했다.
이 방식은 중복 알림 폭주를 막는 장점이 있지만, CRITICAL이 오래 지속될 때 추가 알림이 없어 장애가 묻힐 수 있다.

### 정책

| 상태 | 반복 알림 |
|------|-----------|
| WARN 유지 | 반복 없음 |
| CRITICAL 유지 | 2시간 또는 3회 체크마다 재알림 |
| 복구 | 즉시 알림 |

### 변경

`scripts/health-check.sh`에 metric별 CRITICAL reminder state를 추가했다.

```text
/tmp/health-check-alerts/{metric}.critical
  last_alert_epoch|checks_since_alert
```

동작:

- 상태가 처음 CRITICAL로 바뀌면 즉시 알림을 보내고 reminder state를 초기화한다.
- 다음 체크에서도 CRITICAL이면 `checks_since_alert`를 증가시킨다.
- 마지막 CRITICAL 알림 후 7200초 이상 또는 3회 체크 이상이면 `CRITICAL 지속 중` 재알림을 보낸다.
- WARN 또는 OK로 내려가면 reminder state를 제거한다.
- 복구 알림은 기존처럼 즉시 보낸다.

### 교훈

- WARN은 잡음이 많을 수 있으므로 반복하지 않는 것이 좋다.
- CRITICAL은 중복 억제만으로는 부족하다. 지속 상태를 주기적으로 다시 드러내야 한다.
- 상태 전이 알림과 지속 재알림은 별도 state로 관리하는 편이 명확하다.

---

## 18. Captain Hook 30분 LLM 보고 억제 — HEARTBEAT.md 해석 오류 방지

### 배경

`health-check.sh`는 30분마다 snapshot만 갱신하고, Discord 보고는 상태 변화가 있을 때만 하도록 설계했다.
하지만 Captain Hook/OpenClaw Heartbeat가 `workspace/HEARTBEAT.md`의 `Every 30 Minutes - Health And Resource Snapshot` 섹션을 LLM 주기 작업으로 해석해 30분마다 WARN 서버 상태 보고서를 보냈다.

증상:

```text
06:48 WARN 서버 상태 보고서
07:17 WARN 서버 상태 보고서
```

메모리 WARN이 유지될 뿐인데 LLM이 30분마다 실시간 SSH 보고서를 생성했다.
이는 Webhook 중복 억제 정책과 비용 절감 설계에 어긋난다.

### 변경

`workspace/HEARTBEAT.md`를 재작성했다.

- 30분 health/resource 체크는 OpenClaw Heartbeat 작업이 아니라고 최상단에 명시
- Captain Hook/OpenClaw가 30분 heartbeat로 호출하면 metrics 수집/SSH/보고서 생성을 하지 말고 `HEARTBEAT_OK`만 반환하도록 지시
- 30분 체크 설명은 `External Bash Monitoring` 섹션으로 이동
- LLM periodic task는 `Full Report`와 `Daily Summary`만 허용
- Full Report도 이미 알림된 WARN만 반복되는 경우 `HEARTBEAT_OK`를 반환하도록 지시

### 교훈

- HEARTBEAT.md에 `Every 30 Minutes` 같은 제목을 넣으면 OpenClaw가 실제 LLM heartbeat schedule로 해석할 수 있다.
- 외부 bash 주기 작업은 HEARTBEAT.md에서 schedule처럼 쓰지 말고, "OpenClaw 작업 아님"을 명확히 해야 한다.
- 반복 감지와 반복 보고는 다르다. 30분마다 해야 하는 것은 snapshot 갱신이지 LLM 보고서 발송이 아니다.

---

## 19. Full Report / Daily Summary 동작 구체화

### 배경

30분 LLM 보고를 막은 뒤에도 6시간 Full Report와 Daily Summary가 어떤 데이터를 읽고 언제 보고해야 하는지가 충분히 구체적이지 않았다.
이 상태에서는 Full Report가 snapshot 대신 실시간 SSH raw metric을 직접 파싱하다가 수집 실패를 많이 만들거나, 이미 알림된 WARN을 반복 보고할 수 있다.

### 변경

`workspace/HEARTBEAT.md`의 OpenClaw LLM heartbeat task를 구체화하고, deterministic helper를 추가했다.

추가 파일:

- `scripts/heartbeat-context.sh`

역할:

- snapshot 읽기
- snapshot freshness 계산
- GitHub Actions 상태 확인
- Full Report fingerprint 계산
- `/tmp/health-check-alerts/full-report.state`에 이전 fingerprint 저장
- `full_report_should_report=true|false`를 출력해 LLM의 보고 여부 판단을 단순화

Full Report:

- 6시간마다 실행 가능
- 최신 `status-current.env` snapshot을 우선 사용
- snapshot stale/unavailable, CRITICAL, 새 WARN, CI 실패, severity 상승이면 보고
- 이미 알림된 동일 WARN만 반복되면 `HEARTBEAT_OK`
- 전체 metric table을 반복하지 않고 핵심 이슈 중심의 압축 점검으로 제한
- CI는 `gh auth status`가 성공할 때만 조회하고, 실패하면 `수집 제외: gh 인증 필요`로 짧게 표기

Daily Summary:

- 매일 9AM KST 실행
- 정상이어도 항상 보고
- snapshot 측정시각, 데이터 freshness, 서버/앱/DB/트래픽/CI/CD 요약 포함
- data source가 없으면 추측하지 않고 수집 실패로 표시
- Daily Summary는 `HEARTBEAT_OK`를 반환하지 않음

`workspace/SOUL.md`에도 6시간 Full Report와 Daily Summary는 `HEARTBEAT.md` 전용 포맷을 우선하도록 추가했다.
`README.md`와 `workspace/TOOLS.md`에도 `heartbeat-context.sh`를 문서화했다.

### 교훈

- Heartbeat 문서는 schedule뿐 아니라 "보고할 조건"과 "보고하지 않을 조건"을 같이 써야 한다.
- Full Report는 반복 알림이 아니라 변화 감지 중심의 압축 점검이어야 한다.
- Daily Summary는 운영 리포트이므로 정상이어도 보고하지만, Full Report는 중복 WARN만 있으면 조용해야 한다.

---

## 20. health-check 자체 감시 — 모니터링 장애와 서버 장애 분리

### 배경

기존 구조는 서버 상태를 감시했지만, 감시 스크립트 자체가 멈추거나 snapshot 갱신에 실패하는 경우를 별도로 추적하지 않았다.
이 경우 마지막 snapshot이 남아 사용자가 오래된 값을 최신처럼 볼 수 있고, 장애 원인이 서버인지 모니터링 파이프라인인지 구분하기 어렵다.

### 변경

`scripts/health-check.sh`에 모니터링 파이프라인 상태 추적을 추가했다.

추가 상태:

```text
/tmp/health-check-alerts/last_success.state
/tmp/health-check-alerts/monitor-health_ssh.state
/tmp/health-check-alerts/monitor-resource_ssh.state
/tmp/health-check-alerts/monitor-resource_parse.state
/tmp/health-check-alerts/monitor-snapshot_write.state
```

정책:

| 항목 | 동작 |
|------|------|
| snapshot 갱신 성공 | `last_success.state` 갱신 |
| health SSH 실패 1회 | 로그만 기록 |
| resource SSH 실패 1회 | 로그만 기록 |
| resource parse 실패 1회 | 로그만 기록 |
| snapshot write 실패 1회 | 로그만 기록 |
| 동일 실패 2회 연속 | WARN Webhook 알림 |
| 실패 후 성공 | INFO 복구 알림 |

`scripts/heartbeat-context.sh`도 `last_success.state`를 읽어 다음 값을 출력한다.

```text
monitor_last_success_epoch
monitor_last_success_utc
monitor_last_success_age_min
monitor_last_success_file
```

### 교훈

- 모니터링 시스템은 서비스뿐 아니라 자기 자신도 감시해야 한다.
- 서버 장애와 모니터링 장애를 같은 알림으로 섞으면 원인 파악이 늦어진다.
- snapshot 기반 구조에서는 last_success를 별도 상태로 남겨야 stale 판단과 장애 분석이 쉬워진다.

---

## 21. 트래픽 기반 자동 알림 - 응답시간/에러율 임계값 추가

### 배경

`health-check.sh`가 30분 counter delta로 RPS, 평균 응답시간, 에러율을 계산하게 됐지만, 자동 알림 기준은 여전히 memory/load/disk 중심이었다.
트래픽 품질 문제는 리소스 사용률이 낮아도 발생할 수 있으므로 응답시간과 에러율 기준을 추가했다.

### 변경

자동 알림 기준:

| Metric | WARN | CRITICAL |
|--------|------|----------|
| Avg Response | > 1s | > 3s |
| Error Rate | > 1% | > 5% |

적용 조건:

- `rate_status_http=ok`이고 `rate_status_sum=ok`일 때만 평균 응답시간 판단
- `rate_status_http=ok`이고 `rate_status_5xx=ok`일 때만 에러율 판단
- `init`, `missing`, `reset` 상태에서는 트래픽 알림을 보내지 않음
- RPS 급감 알림은 트래픽 패턴 오탐 가능성이 커서 제외

반영:

- `scripts/health-check.sh`: `avg_response_status`, `error_rate_status` 계산 및 `handle_state_change` 연동
- snapshot에 `avg_response_status`, `error_rate_status` 저장
- `scripts/heartbeat-context.sh`: Full Report fingerprint에 traffic status 포함
- `README.md`, `workspace/HEARTBEAT.md`, `workspace/SOUL.md`, `grafana-monitor` 임계값 문서 갱신

### 교훈

- rate 기반 알림은 counter delta 상태가 정상일 때만 판단해야 한다.
- traffic quality alert는 리소스 알림과 별도로 필요하다.
- RPS 급감은 서비스 특성/시간대 패턴을 더 학습하기 전까지 자동 알림에 넣지 않는 것이 안전하다.

---

## 22. `/tmp` 상태 초기화 문제 정리

### 배경

`health-check.sh`는 `/tmp/health-check-alerts`에 snapshot, rate counter sample, metric state, 중복 알림 상태, CRITICAL reminder state, Full Report fingerprint를 저장한다.
Railway 컨테이너가 재배포되거나 재시작되면 `/tmp` 상태는 초기화될 수 있다.

### 정리

재시작 직후 예상되는 현상:

- 첫 resource check에서는 이전 counter sample이 없어서 RPS, 평균 응답시간, 에러율이 `init` 또는 `계산 대기`가 된다.
- 이전 WARN/CRITICAL 상태를 기억하지 못하므로 동일 장애가 새 알림처럼 다시 전송될 수 있다.
- 재시작 전 WARN이었다가 재시작 후 OK가 되어도 이전 상태가 없어서 복구 알림이 생략될 수 있다.
- CRITICAL 지속 재알림 카운터와 Full Report fingerprint가 초기화될 수 있다.

판단:

- 현재 단계에서는 치명적이지 않다.
- 재시작 직후 1회 rate 계산 대기와 일부 상태 기억 초기화는 운영상 허용 가능하다.
- 영구 상태가 필요해지면 Railway Volume 또는 EC2의 작은 state 파일로 옮긴다.
- 지금은 구현 복잡도를 늘리지 않고 문서화로 처리한다.

### 교훈

- 컨테이너 로컬 `/tmp`는 빠르고 단순하지만 운영 상태 기억에는 한계가 있다.
- 상태 초기화로 생기는 알림 노이즈와 구현 복잡도 사이의 비용을 비교해야 한다.
- 현재 규모에서는 persistent state보다 명확한 문서화와 stale snapshot 감지가 우선이다.

---

## 23. 운영 Runbook 추가

### 배경

자동 알림이 오더라도 운영자가 즉시 확인할 절차가 없으면 대응 품질이 흔들린다.
특히 AI 운영 봇 포트폴리오에서는 "알림을 보낸다"보다 "알림 이후 사람이 어떤 절차로 판단하고 조치하는지"까지 설계되어 있어야 완성도가 높다.

### 변경

`docs/runbook.md`를 추가했다.

포함한 대응 절차:

- 공통 로그/snapshot 확인
- 메모리 WARN 대응
- 메모리 CRITICAL 대응
- SSH 실패 대응
- Spring Boot Health DOWN 대응
- Webhook 알림 실패 대응
- snapshot stale 대응
- 트래픽 알림 대응
- 복구 확인

`README.md`에는 운영 문서 링크와 프로젝트 구조만 반영했다.

### 교훈

- 모니터링 시스템은 감지만으로 끝나지 않고, 사람의 다음 행동까지 연결되어야 한다.
- runbook은 포트폴리오 관점에서 운영 설계력을 보여주는 핵심 산출물이다.
- 자동화와 수동 조치의 경계를 문서로 분리하면 장애 대응 중 판단 비용이 줄어든다.

---

## 24. Daily Summary Gateway HTTP API 트리거 구현

### 배경

`HEARTBEAT.md`에는 Daily Summary를 매일 9AM KST에 보내라고 적혀 있었지만, 실제 9AM 스케줄러가 없었다.
즉 문서상 목표 동작은 있었지만 OpenClaw에게 daily-summary 실행을 요청하는 구현이 없어서 9시가 지나도 일일 요약이 오지 않았다.

### 변경

OpenClaw Gateway의 OpenResponses HTTP endpoint를 사용해 Daily Summary를 트리거하도록 바꿨다.

구현:

- `openclaw.json`
  - `gateway.http.endpoints.responses.enabled=true`
- `scripts/daily-summary-scheduler.sh`
  - 매 5분마다 KST 시간을 확인
  - 09시 이후이고 오늘 아직 발송하지 않았으면 Gateway `POST /v1/responses` 호출
  - 실패 시 무한 LLM 재시도를 막기 위해 `DAILY_SUMMARY_MAX_ATTEMPTS_PER_DAY`만큼만 재시도
  - `x-openclaw-agent-id: main`으로 PoppingOps main agent 지정
  - agent에게 `/scripts/heartbeat-context.sh daily-summary` 기반 Daily Summary 작성을 요청
  - 응답 text를 Discord Webhook으로 전송
  - `/tmp/health-check-alerts/daily-summary.state`에 당일 발송 여부 저장
- `entrypoint.sh`
  - `health-check.sh`, `daily-summary-scheduler.sh`, `openclaw gateway`를 함께 실행
- `README.md`, `workspace/HEARTBEAT.md`, `workspace/TOOLS.md`
  - Daily Summary 실행 주체를 OpenClaw Heartbeat 문서 지시에서 Gateway HTTP API scheduler로 갱신

환경변수:

- `DISCORD_DAILY_SUMMARY_WEBHOOK_URL`
- `DISCORD_REPORT_WEBHOOK_URL`
- `DISCORD_WEBHOOK_URL`
- `OPENCLAW_GATEWAY_TOKEN`
- `GATEWAY_TOKEN`

### 운영 검증

배포 후 첫 실행에서 Gateway 호출 자체는 성공했고 LLM도 Daily Summary 내용을 생성했지만, scheduler가 응답 JSON에서 text를 추출하지 못해 다음 로그가 발생했다.

```text
[daily-summary] Gateway returned empty daily summary
[daily-summary] Daily Summary failed ... will retry
```

원인은 `extract_response_text`가 응답 JSON을 stdin에서 읽도록 되어 있었는데, Node heredoc도 stdin을 사용하고 있어서 실제 response body를 읽지 못한 것이었다.

수정:

- response file path를 Node 인자로 넘겨 JSON을 직접 읽도록 변경
- `output_text`, `output[].content[].text`, `choices`, nested text value 등 여러 OpenResponses 형태를 파싱하도록 보강
- 실패 시 5분마다 LLM을 무한 재호출하지 않도록 `DAILY_SUMMARY_MAX_ATTEMPTS_PER_DAY` 기본값 `3` 추가

검증 결과:

```text
[daily-summary] Daily Summary attempt 2/3
[daily-summary] Daily Summary sent for 2026-04-21 KST
```

### 교훈

- 프롬프트에 "매일 9AM"이라고 적는 것만으로는 실제 스케줄이 생기지 않는다.
- 주기 작업은 문서 지시와 별도로 실행 주체, 트리거, 상태 저장, 실패 재시도 경로가 필요하다.
- LLM 분석은 Gateway `/v1/responses`로 호출하고, 스케줄링과 발송은 deterministic script가 맡는 구조가 가장 명확하다.
- LLM Gateway 응답은 provider/runtime별 JSON shape가 달라질 수 있으므로 파서는 여러 형태를 허용하고, 실패 재시도에는 비용 상한을 둬야 한다.

---

## 25. 6시간 Full Report Scheduler 구현

### 배경

Daily Summary는 Gateway HTTP API scheduler로 실제 9AM KST 실행이 보장되었지만, 6시간 Full Report는 여전히 `HEARTBEAT.md` 지시에만 남아 있었다.
OpenClaw Heartbeat가 실제로 6시간마다 실행되는지 확인되지 않았으므로 Full Report도 명시적 scheduler가 필요했다.

### 변경

`scripts/full-report-scheduler.sh`를 추가했다.

구조:

```text
full-report-scheduler.sh
  → 6시간마다 실행
  → /scripts/heartbeat-context.sh full-report 실행
  → full_report_should_report=false
      → 로그만 남기고 LLM 호출 없음
  → full_report_should_report=true
      → Gateway /v1/responses 호출
      → main agent(PoppingOps) LLM 실행
      → Discord Webhook 전송
```

구현 세부:

- `FULL_REPORT_INTERVAL_SECONDS` 기본값 `21600`
- `FULL_REPORT_MAX_ATTEMPTS_PER_WINDOW` 기본값 `3`
- `DISCORD_FULL_REPORT_WEBHOOK_URL`, `DISCORD_REPORT_WEBHOOK_URL`, `DISCORD_WEBHOOK_URL` 순서로 fallback
- Gateway token은 `OPENCLAW_GATEWAY_TOKEN`, `GATEWAY_TOKEN`, `/root/.openclaw/openclaw.json` 순서로 확인
- `entrypoint.sh`에서 `health-check.sh`, `daily-summary-scheduler.sh`, `full-report-scheduler.sh`, `openclaw gateway`를 함께 실행
- `README.md`, `workspace/HEARTBEAT.md`, `workspace/TOOLS.md`를 실제 스케줄러 기준으로 갱신

검증:

- `scripts/full-report-scheduler.sh` bash 문법 검사 통과
- `scripts/daily-summary-scheduler.sh` bash 문법 검사 통과
- `entrypoint.sh` bash 문법 검사 통과
- `openclaw.json` JSON parse 통과

### 교훈

- Full Report는 Daily Summary와 다르게 매번 LLM을 호출하면 비용과 알림 노이즈가 생긴다.
- LLM 호출 전에 deterministic helper로 보고 필요성을 판단해야 한다.
- `full_report_should_report=false` 경로는 비용 절감의 핵심이므로 scheduler에서 Gateway 호출 자체를 건너뛰어야 한다.

---

## 26. GitHub Actions 수집 인증 판단 개선

### 배경

로컬과 Railway 변수 환경에서는 `GH_TOKEN`으로 `gh run list --repo Popping-community/popping-server --limit 1`이 성공했지만, Daily Summary에는 `수집 제외: gh 인증 필요`가 표시되었다.
원인은 `heartbeat-context.sh`가 실제 필요한 `gh run list`를 실행하기 전에 `gh auth status` 선검사를 통과해야만 CI/CD 수집을 진행했기 때문이다.
환경에 따라 `GH_TOKEN`으로 API 호출은 가능한데 `gh auth status` 판단이 기대와 다르게 실패할 수 있다.

### 변경

- `scripts/heartbeat-context.sh`
  - `gh auth status` 선검사를 제거
  - `gh`가 설치되어 있으면 곧바로 `gh run list`를 실행
  - 성공하면 `github_actions_available=true`와 최근 workflow JSON/fingerprint 출력
  - 실패하면 `gh_auth_required` 같은 고정 문구 대신 실제 `gh run list` 에러 메시지를 `github_actions_unavailable`에 기록
- `entrypoint.sh`
  - `GH_TOKEN`이 있으면 `gh auth login --with-token`으로 credential store에 저장하려 하지 않음
  - GitHub CLI는 `GH_TOKEN` 환경변수를 직접 사용하므로, 실제 필요한 `gh run list`로 Actions read access만 검증
  - 성공 시 `GitHub CLI auth: OK (Actions read access)` 출력
  - 실패 시 `WARNING: GitHub CLI Actions check failed`와 `gh auth status` 출력
  - `GH_TOKEN`이 없으면 GitHub Actions context disabled 로그 출력

### 교훈

- 인증 상태를 추상적으로 확인하는 명령보다 실제 필요한 read operation을 직접 시도하는 편이 운영 진단에 더 정확하다.
- 실패 이유는 `gh_auth_required`처럼 뭉뚱그리지 말고, 실제 CLI 에러를 남겨야 다음 조치가 분명해진다.

---

## 27. Daily Summary helper-first context 주입

### 배경

`GH_TOKEN` 인증과 `heartbeat-context.sh`의 GitHub Actions 수집은 정상으로 확인되었지만, Daily Summary LLM 출력에는 계속 `수집 제외: gh 인증 필요`가 나타났다.
원인은 `daily-summary-scheduler.sh`가 helper output을 직접 Gateway 요청에 포함하지 않고, LLM에게 "helper를 실행하라"고 지시만 했기 때문이다.
이 구조에서는 agent 실행 환경이나 세션 기억에 따라 CI/CD context가 누락되거나 오래된 판단이 섞일 수 있다.

### 변경

- `scripts/daily-summary-scheduler.sh`
  - Gateway 호출 전에 `/scripts/heartbeat-context.sh daily-summary`를 직접 실행
  - helper output 전체를 `/v1/responses` input에 `Context:`로 포함
  - `github_actions_available=true`이면 CI/CD를 수집 제외로 쓰지 말고 `github_actions_runs_json`을 요약하도록 지시
  - scheduler 로그에 `Daily Summary context: GitHub Actions available/unavailable` 출력
- `README.md`, `workspace/HEARTBEAT.md`, `workspace/TOOLS.md`
  - Daily Summary도 Full Report처럼 helper-first context 주입 구조로 문서 갱신

### 교훈

- LLM에게 "스크립트를 실행하라"고 지시하는 것보다, deterministic scheduler가 먼저 context를 만들고 그 결과를 LLM input에 넣는 편이 안정적이다.
- CI/CD처럼 이미 구조화된 context는 LLM의 추론에 맡기지 말고 입력으로 고정해야 한다.

---

## 28. Architecture 문서 분리 — 레이어 기반 운영 구조 정리

### 배경

README는 사용법, 운영 방식, 환경변수, 프로젝트 구조까지 담고 있어 전체 설명에는 충분했지만, PoppingOps의 핵심 아키텍처 메시지를 빠르게 보여주기에는 길었다.
특히 이 프로젝트는 "LLM이 모든 것을 직접 하는 봇"이 아니라, deterministic monitoring과 LLM analysis를 분리한 운영 에이전트라는 점을 별도 문서에서 명확히 보여줄 필요가 있었다.

### 변경

`docs/architecture.md`를 추가하고 README보다 짧은 레이어 중심 문서로 정리했다.

레이어:

```text
Detection layer: health-check.sh
State layer: /tmp/health-check-alerts/status-current.env
Analysis layer: PoppingOps LLM
Notification layer: Discord Webhook
Interaction layer: Discord bot
```

각 레이어에는 현재 구현된 기능을 자연스럽게 포함했다.

- Detection layer: health/resource 수집, traffic quality alert, health-check self-monitoring
- State layer: snapshot freshness, last_success, `/tmp` ephemeral state 정책
- Analysis layer: helper-first context 기반 Full Report/Daily Summary/사용자 요청 분석
- Notification layer: 서버 장애와 모니터링 장애 알림 분리
- Interaction layer: Discord bot, snapshot 기반 보고, 실시간 gauge 보강

README에는 `docs/architecture.md` 링크와 프로젝트 구조 항목만 추가했다.

### 교훈

- 아키텍처 문서는 기능 히스토리보다 현재 책임 분리를 설명해야 한다.
- 최근 개선사항도 별도 "개선사항" 섹션으로 두기보다 해당 레이어의 현재 기능처럼 녹이는 편이 자연스럽다.
- 포트폴리오 문서에서는 "AI가 다 한다"보다 "deterministic system과 LLM의 경계를 설계했다"는 메시지가 더 강하다.

---

## 29. Runbook-first 권장 조치 — 조치 안내의 근거 고정

### 배경

PoppingOps가 WARN/CRITICAL 상태를 보고할 때 권장 조치를 함께 제시하지만, 이 조치가 LLM의 일반 추론인지 운영자가 검증한 runbook 기반인지 경계가 모호했다.
운영 에이전트의 조치 안내는 임의 추론보다 문서화된 절차를 우선해야 한다.

### 변경

- `Dockerfile`
  - `docs/`를 `/root/.openclaw/docs/`로 복사해 배포된 OpenClaw 에이전트가 runbook을 읽을 수 있게 했다.
- `workspace/SOUL.md`
  - WARN/CRITICAL 상태 또는 "어떻게 조치해?" 질문에는 `/root/.openclaw/docs/runbook.md`를 우선하도록 지시했다.
  - memory, SSH, Spring Boot health, Webhook, snapshot stale, traffic alert, recovery 확인을 runbook 섹션에 매핑했다.
  - runbook에 직접 절차가 없으면 `runbook에 직접 절차 없음`을 먼저 밝히고, 별도 `추론 기반 권장 확인` 목록으로 read-only 진단만 제안하도록 했다.
  - runbook 기반 권장 조치도 자동 실행이 아니라 안내이며, restart/config/deploy/write operation은 사용자 명시 승인 전에는 실행하지 않도록 했다.
- `workspace/skills/grafana-monitor/SKILL.md`
  - 서버 상태 보고의 권장 조치도 runbook-first로 작성하도록 동일한 매핑을 추가했다.
  - runbook에 없는 경우에는 restart/delete/config/deploy/write operation을 제안하지 않고, 로그/메트릭/상태 확인/cross-validation만 fallback으로 제안하도록 했다.

### 교훈

- 운영 조치 안내는 LLM의 "그럴듯한 답변"보다 검증된 runbook을 우선해야 한다.
- runbook 기반 조치와 실제 실행 권한은 분리해야 한다.
- runbook을 프롬프트에서 참조하려면 배포 이미지 안에 실제 파일도 포함되어야 한다.
- runbook에 없는 상황도 완전히 막기보다, 근거를 구분한 bounded LLM fallback으로 운영 유용성을 유지하는 편이 좋다.
- AI 운영 에이전트의 신뢰성은 답변 품질뿐 아니라 답변 근거의 고정 가능성에서 나온다.

---

## 개선 요약

| # | 문제 | 해결 | 효과 |
|---|------|------|------|
| 1 | 누적 데이터를 현재 문제로 오보 | 누적 vs 현재 구분 가이드 추가 | 오탐(False Positive) 제거 |
| 2 | 알림 기준 없음 | 4단계 알림 규칙 + 중복 방지 | 과잉/과소 보고 해결 |
| 3 | 위험 명령 실행 가능 | 명령 화이트리스트 + 데이터 검증 | 안전성 확보 |
| 4 | Prometheus 의존성 | Direct exporter 접근 | 인프라 독립성 |
| 5 | SSH 포트 차단 | 비표준 포트(2222) 사용 | 네트워크 제약 해결 |
| 6 | 이미지에 시크릿 노출 | 환경변수 런타임 주입 | 보안 강화 |
| 7 | Heartbeat 매번 LLM 호출 | 사전 스크립트 체크 설계 (한계 발견 → 10번) | 설계만, 실제 절감 미달성 |
| 8 | LLM 비용 추적 불가 | cost-tracker 스킬 추가 | 비용 가시화 |
| 9 | 단일 에이전트 전문성 분산 | 역할별 멀티 에이전트 분리 | 분석 깊이 향상 + 확장성 (장애 범위 확대 주의) |
| 10 | 7번 사전 스크립트가 실제론 LLM 경유 | 헬스체크를 OpenClaw 외부 bash로 분리 | 현재 30분 snapshot 기준 약 95% 절감 (101→5 호출/일 가능) |
| 11 | SKILL.md 경량화가 LLM 입력을 줄일 것이라는 가설 | `OPENCLAW_LOG_LEVEL=debug`로 `systemPromptChars`/LLM duration 측정 | SKILL 본문 길이는 실제 system prompt에 거의 영향 없음 확인 |
| 12 | 이상 알림 후 복구 여부를 알 수 없음 | metric별 상태 전이 추적 + 복구 알림 | 장애 lifecycle 완결, 운영 확인 비용 감소 |
| 13 | RPS/응답시간/에러율 계산과 측정시각 표기가 없음 | 30분 health-check snapshot + 일반/실시간 명령 모드 분리 | 빠른 보고, rate 계산, 측정 기준 명확화 |
| 14 | 자동 체크 이상 감지 시 LLM 분석을 붙일지 불명확 | health-check는 수집/판단/알림, LLM은 사용자 요청 분석으로 역할 분리 | 비용/지연 최소화, 운영 경계 명확화 |
| 15 | 운영 문서가 구현 변경을 따라가지 못함 | README/HEARTBEAT/TOOLS/USER/SOUL/cost-tracker 최신화 | 문서-구현 불일치 감소, 운영 혼선 방지 |
| 16 | 오래된 snapshot이 최신 서버 상태처럼 보고될 수 있음 | snapshot age 계산 + stale severity 승격 | health-check 중단/갱신 지연을 사용자에게 노출 |
| 17 | CRITICAL이 오래 지속돼도 최초 1회만 알림 | CRITICAL 지속 시 2시간 또는 3회 체크마다 재알림 | 조용한 장애 지속 방지 |
| 18 | Captain Hook이 30분 외부 체크를 LLM 보고로 해석 | HEARTBEAT.md에서 30분 OpenClaw 작업 금지 + `HEARTBEAT_OK` 지시 | 30분마다 WARN 보고서 반복 발송 방지 |
| 19 | Full Report/Daily Summary 동작 조건이 모호함 | snapshot 우선, 보고 조건/억제 조건, 전용 포맷 구체화 | 6시간 점검 품질 향상, 일일 요약 안정화 |
| 20 | health-check 자체 실패를 감지하지 못함 | last_success + 모니터링 파이프라인 실패 연속 카운터 | 서버 장애와 모니터링 장애 분리 |
| 21 | 트래픽 품질 저하 자동 알림이 없음 | 평균 응답시간/에러율 임계값 추가 | 리소스 정상이어도 사용자 영향 감지 |
| 22 | `/tmp` 상태가 재시작 때 초기화됨 | rate init/복구 누락/중복 알림 가능성 문서화 | 재시작 직후 정상 현상과 개선 방향 명확화 |
| 23 | 알림 이후 대응 절차가 분산됨 | `docs/runbook.md` 추가 | 장애 알림에서 조치까지 연결되는 운영 문서 확보 |
| 24 | Daily Summary 9AM 실행 스케줄이 문서에만 있음 | Gateway `/v1/responses` 호출 scheduler 추가 | 매일 9AM KST LLM 일일 요약 트리거 구현 |
| 25 | 6시간 Full Report 실행이 보장되지 않음 | helper-first `full-report-scheduler.sh` 추가 | 변화가 있을 때만 LLM Full Report 실행 |
| 26 | GH_TOKEN이 있어도 `gh auth status` 선검사로 CI/CD 수집 제외 | `gh run list` 직접 시도 + 실제 에러 출력 | Daily/Full Report의 GitHub Actions 수집 안정화 |
| 27 | Daily Summary가 helper 결과 없이 LLM 지시에 의존 | helper-first context 주입으로 변경 | CI/CD 수집 상태를 리포트에 안정적으로 반영 |
| 28 | README만으로는 운영 아키텍처 메시지가 분산됨 | `docs/architecture.md`를 레이어 중심으로 추가 | deterministic monitoring과 LLM analysis의 책임 분리 명확화 |
| 29 | 권장 조치가 LLM 일반 추론처럼 보일 수 있음 | runbook-first 지시와 bounded read-only fallback 추가 | 조치 안내의 근거와 운영 일관성 강화 |
| 30 | 30분 주기는 장애 감지가 늦음 | 기본 health/resource snapshot 주기 10분화 | 감지 지연 단축, LLM 호출 증가 없음 |
| 31 | 필수 Railway Variables 누락 시 컨테이너가 불완전하게 뜰 수 있음 | `entrypoint.sh` fail-fast 검증 추가 | 운영 알림/Gateway token 누락 상태로 시작 방지 |
| 32 | GitHub push와 Railway 수동 배포가 분리됨 | GitHub Actions 검증 + Railway Wait for CI 자동 배포 | 배포 피로 감소, 문법 오류 배포 방지 |
| 33 | Gateway 준비 전 scheduler가 `/v1/responses`를 호출함 | Gateway HTTP readiness 확인 후 Daily/Full Report scheduler 시작 | startup 직후 http=000 실패와 불필요한 재시도 방지 |
| 34 | Webhook payload를 문자열 JSON으로 직접 생성함 | `node` `JSON.stringify({ content })`로 payload 생성 | 따옴표/개행/백슬래시 포함 알림 메시지 전송 안정화 |
| 35 | exporter 응답 누락이 0 값처럼 snapshot에 반영될 수 있음 | core metric completeness 검증 후 snapshot 갱신 | 불완전한 메트릭을 정상 수치처럼 보고하지 않음 |

---

## 30. Snapshot 주기 10분 단축

### 문제 상황
30분 snapshot 구조는 LLM 비용을 줄이고 중복 보고를 막는 데는 효과적이었다.
하지만 실제 장애 대응 관점에서는 서버 상태 변화가 최대 30분 늦게 감지될 수 있었다.

특히 memory, disk, app health, error rate 같은 상태 전이 알림은 snapshot 갱신 시점에 의존하므로 빠른 대응을 위해 수집 주기를 줄일 필요가 있었다.

### 결정
기본 health/resource snapshot 주기를 30분에서 10분으로 줄였다.

```bash
HEALTH_CHECK_INTERVAL_SECONDS=600
```

구현은 하드코딩 대신 환경변수 기반으로 바꿨다.

- `HEALTH_CHECK_INTERVAL_SECONDS`: 기본값 600초
- `SNAPSHOT_STALE_WARN_MIN`: 기본값 20분
- `SNAPSHOT_STALE_CRITICAL_MIN`: 기본값 30분

잘못된 interval 값이 들어와도 busy loop가 생기지 않도록 숫자 검증과 최소 60초 보정을 추가했다.

### Stale 기준 조정
수집 주기가 10분으로 줄었으므로 freshness 기준도 함께 조정했다.

| Snapshot age | Status | Meaning |
|--------------|--------|---------|
| 20분 미만 | OK | 최신 데이터 |
| 20분 이상 | WARN | 오래된 snapshot |
| 30분 이상 | CRITICAL | 수집 중단 가능성 |

### 알림 정책
같은 메시지의 30분 중복 방지는 유지했다.
따라서 감지는 10분마다 빨라지지만, Discord에 같은 WARN이 반복 도배되지는 않는다.

CRITICAL 지속 재알림은 기존 정책을 유지했다.

```bash
CRITICAL_REMINDER_SECONDS=7200
CRITICAL_REMINDER_CHECKS=3
```

10분 주기에서는 3회 체크가 약 30분이므로, CRITICAL 상태가 유지되면 최초 알림 이후 약 30분마다 재알림된다.

### 효과

- 서버 상태 변화 감지 지연을 최대 30분에서 최대 10분 수준으로 단축
- 모니터링 파이프라인 장애 감지 시간을 2회 연속 실패 기준 최대 60분에서 최대 20분 수준으로 단축
- LLM 호출 수는 증가하지 않음
- SSH/exporter 조회 빈도는 증가하지만 운영 모니터링 관점에서 허용 가능한 수준

---

## 31. 필수 환경변수 fail-fast

### 문제 상황

컨테이너가 시작됐지만 운영 알림이나 Gateway token이 빠져 실제로는 불완전하게 동작할 수 있었다.
특히 `DISCORD_WEBHOOK_URL`이 없으면 WARN/CRITICAL 알림이 Discord로 전달되지 않고, `GATEWAY_TOKEN`이 없으면 OpenClaw Gateway 인증 구성이 의도와 달라질 수 있다.

### 결정

`entrypoint.sh`가 필수 Railway Variables를 먼저 검사하고, 하나라도 누락되면 background process를 시작하지 않고 종료하도록 바꿨다.

필수 변수:

- `DISCORD_TOKEN`
- `DISCORD_DBA_TOKEN`
- `DISCORD_DEV_TOKEN`
- `FIREWORKS_API_KEY`
- `SSH_PRIVATE_KEY`
- `DISCORD_WEBHOOK_URL`
- `GATEWAY_TOKEN`

### 효과

- 운영 알림과 Gateway token이 빠진 불완전한 컨테이너가 조용히 뜨지 않는다.
- 필수 secret 누락이 Railway 로그에서 명확한 startup failure로 드러난다.
- health-check, scheduler, Gateway가 잘못된 전제에서 background로 실행되지 않는다.

---

## 32. GitHub 자동 배포와 CI 검증 연결

### 문제 상황

GitHub에 코드를 올리는 작업과 Railway CLI 수동 배포가 분리되어 있었다.
운영 봇은 작은 bash script 변경이 많기 때문에, 커밋 후 별도 배포를 매번 수행하면 누락되거나 로컬 상태와 운영 상태가 어긋날 수 있다.

반대로 GitHub push만으로 즉시 배포하면 문법 오류가 있는 shell script도 운영 컨테이너에 반영될 위험이 있다.

### 결정

Railway service는 GitHub `main` 브랜치 자동 배포로 연결한다.
대신 GitHub Actions 검증 workflow를 추가하고, Railway의 `Wait for CI`를 켜서 CI 성공 후에만 배포되도록 한다.

추가한 workflow:

```text
.github/workflows/validate.yml
```

검증 항목:

```bash
bash -n entrypoint.sh
bash -n scripts/health-check.sh
bash -n scripts/heartbeat-context.sh
bash -n scripts/full-report-scheduler.sh
bash -n scripts/daily-summary-scheduler.sh
```

### 효과

- `git push` 또는 PR merge 이후 운영 배포 누락 가능성을 줄였다.
- shell script 문법 오류가 있는 commit은 CI에서 먼저 걸러진다.
- Railway Dashboard에서는 `main` branch와 `Wait for CI` 설정만 유지하면 된다.

---

## 33. Gateway readiness 이후 report scheduler 시작

### 문제 상황

컨테이너 시작 직후 `daily-summary-scheduler.sh`와 `full-report-scheduler.sh`가 OpenClaw Gateway보다 먼저 실행될 수 있었다.
이 경우 scheduler가 `/v1/responses`를 호출하는 시점에 Gateway listener가 아직 준비되지 않아 `http=000` 실패가 발생한다.

health-check는 OpenClaw 외부의 SSH/Webhook 경로라 먼저 시작해도 되지만, Daily Summary와 Full Report는 Gateway HTTP API에 의존한다.

### 결정

`entrypoint.sh` 시작 순서를 조정했다.

1. `health-check.sh`를 먼저 background로 시작한다.
2. OpenClaw Gateway를 background로 시작한다.
3. `GATEWAY_READY_TIMEOUT_SECONDS` 동안 Gateway HTTP 응답을 기다린다.
4. Gateway가 준비된 뒤 `daily-summary-scheduler.sh`, `full-report-scheduler.sh`를 시작한다.

Gateway가 timeout 안에 준비되지 않거나 먼저 종료되면 컨테이너를 종료한다.

### 효과

- startup 직후 scheduler의 `http=000` 실패를 줄인다.
- LLM report scheduler가 Gateway readiness 이후에만 `/v1/responses`를 호출한다.
- health-check의 빠른 시작은 유지하면서 Gateway 의존 작업만 늦춘다.

---

## 34. Webhook JSON payload escape 보강

### 문제 상황

`health-check.sh`의 Discord Webhook 알림은 shell heredoc으로 JSON 문자열을 직접 만들고 있었다.
알림 메시지에 따옴표, 개행, 백슬래시가 들어가면 JSON payload가 깨질 수 있다.

### 결정

Webhook payload 생성만 `node`에 맡기고, `JSON.stringify({ content })`로 직렬화하도록 바꿨다.
Daily/Full Report scheduler는 이미 Node 기반으로 Discord payload를 만들고 있으므로 health-check도 같은 안전한 방식으로 맞췄다.

### 효과

- 알림 메시지에 특수문자가 포함되어도 Discord Webhook JSON이 깨지지 않는다.
- shell string escaping에 의존하지 않는다.
- Webhook 전송 실패 원인을 실제 네트워크/API 문제와 payload 구성 문제로 더 명확히 분리할 수 있다.

---

## 35. Resource metric completeness 검증

### 문제 상황

`health-check.sh`의 resource snapshot은 exporter 응답을 awk로 집계한다.
이때 actuator prometheus, node-exporter, mysqld-exporter 응답이 비어 있으면 일부 값이 `0`처럼 계산되어 snapshot에 정상 수치처럼 기록될 수 있었다.

특히 `MEM_TOTAL`, `DISK_TOTAL`, `APP_METRICS`, `NODE_METRICS` 같은 핵심 값이 비어 있으면 이후 memory/disk/traffic 계산도 신뢰할 수 없다.

### 결정

resource metrics line에 exporter 응답 존재 여부를 함께 싣고, local parse 단계에서 core metric completeness를 검증한다.

검증 대상:

- `APP_METRICS`, `NODE_METRICS`, `MYSQL_METRICS` 응답 존재 여부
- `MEM_AVAIL`, `MEM_TOTAL`
- `DISK_AVAIL`, `DISK_TOTAL`
- `LOAD`, `NODE_TIME`, `NODE_BOOT`
- `HTTP_COUNT`, `HTTP_SUM`
- `MYSQL_QUERIES`

`MEM_TOTAL` 또는 `DISK_TOTAL`이 0 이하인 경우도 불완전한 metric으로 처리한다.

### 효과

- exporter 응답 누락을 정상 `0` 수치로 오인하지 않는다.
- core metric이 불완전하면 `resource_parse` 모니터링 장애로 기록하고 snapshot 갱신을 중단한다.
- 오래된 snapshot freshness 경고와 모니터링 장애 알림으로 수집 파이프라인 문제를 드러낸다.
