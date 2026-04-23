# OpenClaw 기반 서버 운영 에이전트 구축기

## LLM이 모든 것을 하는 봇이 아니라, 운영 가능한 에이전트로 만들기

PoppingOps는 OpenClaw 기반 Discord 운영 에이전트다.
Spring Boot, MySQL, EC2 환경을 모니터링하고, 서버 상태 보고, 6시간 Full Report, Daily Summary, DB/CI/CD 분석을 Discord에서 수행한다.

처음 목표는 단순했다.
Discord에서 "서버 상태 확인해줘"라고 말하면 OpenClaw 봇이 서버 상태를 확인하고 답변하는 것이었다.
하지만 실제로 운영해보니 중요한 문제는 "LLM이 명령을 잘 수행하는가"가 아니었다.

운영 시스템에서는 다음 문제가 더 중요했다.

- 정상 상태에서도 반복 체크가 LLM 토큰을 계속 소비하지 않는가
- 오래된 데이터를 최신 상태처럼 보고하지 않는가
- 서버 장애와 모니터링 장애를 구분할 수 있는가
- LLM이 누적 지표를 현재 문제로 오해하지 않는가
- 알림 이후 사람이 어떤 절차로 대응할 수 있는가

그래서 PoppingOps를 "LLM이 모든 것을 직접 하는 봇"이 아니라, deterministic monitoring과 LLM analysis를 분리한 운영 에이전트로 다시 설계했다.

## 전체 아키텍처

PoppingOps는 다섯 개 레이어로 나뉜다.

```text
Detection layer: scripts/health-check.sh
State layer: /tmp/health-check-alerts/status-current.env
Analysis layer: PoppingOps LLM
Notification layer: Discord Webhook
Interaction layer: Discord bot
```

각 레이어의 책임은 명확하다.

| Layer | Responsibility |
|---|---|
| Detection | 서버 health, resource, traffic metric을 수집하고 임계값을 판단한다. |
| State | 최신 snapshot과 상태 전이 정보를 저장한다. |
| Analysis | 이미 수집된 context를 바탕으로 LLM이 운영 보고서를 작성한다. |
| Notification | WARN, CRITICAL, 복구 알림을 Discord Webhook으로 보낸다. |
| Interaction | Discord bot이 사용자의 질문과 운영 요청을 받는다. |

핵심은 LLM이 metric 수집과 반복 판단을 직접 하지 않는다는 점이다.
반복적이고 결정론적인 작업은 bash script가 처리하고, LLM은 사람이 읽을 수 있는 분석과 요약에 집중한다.

## 문제 1. 정상 반복 체크에도 LLM 비용이 발생했다

초기에는 OpenClaw heartbeat를 이용해 30분마다 서버 상태를 확인하려고 했다.
문서에는 "정상이면 조용히 넘어간다"는 규칙을 적었다.

하지만 실제 구조에서는 문제가 있었다.
OpenClaw heartbeat 자체가 LLM 기반으로 동작하기 때문에, "정상인지 판단하라"는 단계부터 이미 LLM context가 로드된다.
즉 정상 상태에서도 토큰 비용과 지연이 계속 발생했다.

해결은 프롬프트를 더 잘 쓰는 것이 아니라 구조를 바꾸는 것이었다.

```text
Before
30분 heartbeat
  -> OpenClaw LLM 호출
  -> LLM이 health check 명령 판단
  -> metric 수집
  -> LLM이 정상/이상 판단

After
30분 health-check.sh
  -> bash가 SSH로 metric 수집
  -> bash가 임계값 판단
  -> 정상이면 아무것도 하지 않음
  -> 이상/복구 시 Discord Webhook 알림
```

이 변경으로 정상 반복 체크는 LLM을 호출하지 않게 되었다.
LLM은 사용자 요청, Full Report, Daily Summary처럼 사람이 읽는 보고서가 필요한 경우에만 사용한다.

## 문제 2. 오래된 snapshot을 최신 상태처럼 믿을 수 있었다

서버 상태 보고는 빠르게 응답해야 한다.
그래서 health-check가 30분마다 수집한 결과를 snapshot으로 저장하고, PoppingOps는 그 파일을 우선 읽는다.

```bash
/tmp/health-check-alerts/status-current.env
```

하지만 snapshot 기반 구조에는 위험이 있다.
health-check가 죽거나 SSH 수집이 실패하면 마지막 정상 snapshot이 계속 남아 있을 수 있다.
이때 봇이 해당 값을 최신 상태처럼 말하면 운영 판단이 틀어진다.

이를 막기 위해 snapshot freshness를 보고서에 포함했다.

| Snapshot age | 데이터 상태 | 보고 severity |
|---|---|---|
| 45분 미만 | 최신 | 기존 metric severity 유지 |
| 45분 이상 | 오래됨 | 최소 WARN |
| 90분 이상 | 수집 중단 가능성 | CRITICAL |

보고서에는 측정 시각과 데이터 상태를 먼저 표시한다.

```text
측정시각: 2026-04-21 14:00 KST
데이터 상태: 오래됨, 67분 전 snapshot
```

이 규칙 덕분에 마지막 정상값을 최신 상태처럼 믿는 문제를 줄일 수 있었다.

## 문제 3. 서버 장애와 모니터링 장애를 구분해야 했다

운영 시스템은 서버만 감시하면 부족하다.
감시 스크립트 자체도 실패할 수 있다.

PoppingOps는 health-check 파이프라인도 별도로 감시한다.

- health SSH 실패
- resource SSH 실패
- metric parse 실패
- snapshot write 실패

같은 항목이 2회 연속 실패하면 서버 장애와 별도로 "모니터링 장애" 알림을 보낸다.
반대로 실패 이후 정상화되면 "모니터링 복구됨"을 보낸다.

예를 들어 Spring Boot health가 DOWN이면 서버 장애다.
하지만 EC2 SSH 수집이 2회 연속 실패하면 서버가 죽은 것인지, 네트워크나 권한 문제로 감시가 실패한 것인지 먼저 분리해서 봐야 한다.

이 구분은 장애 대응 시간을 줄이는 데 중요했다.

## 문제 4. 리소스가 정상이어도 사용자 경험은 나쁠 수 있다

초기 자동 알림은 memory, CPU load, disk 중심이었다.
하지만 실제 사용자 영향은 응답시간과 에러율에서 먼저 드러날 수 있다.

그래서 actuator counter delta를 이용해 최근 30분 기준 트래픽 지표를 계산했다.

| Metric | WARN | CRITICAL |
|---|---:|---:|
| Avg Response | > 1s | > 3s |
| Error Rate | > 1% | > 5% |

RPS 급감도 고려했지만, 서비스 특성이나 시간대 패턴에 따라 오탐이 많을 수 있어서 자동 알림 기준에서는 제외했다.
대신 RPS는 보고서에 참고 지표로 노출하고, 자동 알림은 평균 응답시간과 HTTP 에러율부터 적용했다.

## LLM은 helper-first context로만 분석한다

PoppingOps에서 LLM은 직접 모든 명령을 실행하는 주체가 아니다.
먼저 deterministic helper가 context를 만들고, LLM은 그 context를 해석한다.

대표적인 helper는 다음과 같다.

```bash
/scripts/heartbeat-context.sh full-report
/scripts/heartbeat-context.sh daily-summary
```

Full Report는 6시간마다 실행되지만, 매번 LLM을 호출하지 않는다.
먼저 helper가 현재 snapshot, freshness, severity, CI/CD 상태를 보고 `full_report_should_report`를 결정한다.
변화가 없으면 LLM 호출 자체를 건너뛴다.

Daily Summary는 매일 9AM KST에 실행된다.
scheduler가 helper output을 먼저 만들고, 그 결과를 Gateway `/v1/responses` input으로 넣는다.
LLM에게 "스크립트를 실행해봐"라고 맡기지 않고, 이미 구조화된 context를 넘겨주는 방식이다.

이 방식은 비용과 안정성 모두에 유리했다.

## 역할별 멀티 에이전트

처음에는 PoppingOps 하나가 서버, DB, CI/CD를 모두 담당했다.
하지만 하나의 에이전트가 모든 도메인을 처리하면 prompt가 커지고, 각 영역의 분석 깊이가 떨어진다.

그래서 역할을 분리했다.

| Agent | Role |
|---|---|
| PoppingOps | 서버, 인프라, 트래픽 모니터링 |
| PoppingDBA | MySQL/InnoDB 분석 |
| PoppingDev | CI/CD와 배포 상태 분석 |

각 에이전트는 별도 workspace, SOUL.md, SKILL.md를 가진다.
PoppingOps는 SRE처럼 수치와 임계값을 중심으로 보고하고, PoppingDBA는 쿼리와 InnoDB 상태를 분석하며, PoppingDev는 GitHub Actions와 배포 상태를 본다.

이 구조는 AI Agent Manager 관점에서 중요하다.
에이전트를 많이 만드는 것이 목표가 아니라, 각 에이전트가 책임지는 도메인과 context boundary를 명확히 나누는 것이 핵심이다.

## 운영 문서화

운영 에이전트는 알림을 보내는 것에서 끝나면 안 된다.
알림 이후 사람이 어떤 절차로 확인하고 조치할 수 있는지가 중요하다.

그래서 문서를 역할별로 분리했다.

| Document | Purpose |
|---|---|
| README.md | 전체 사용법, 운영 방식, 환경변수 |
| docs/architecture.md | 레이어 기반 아키텍처와 책임 분리 |
| docs/runbook.md | 장애 알림 이후 대응 절차 |
| docs/prompt-engineering-history.md | 시행착오와 개선 히스토리 |

runbook에는 메모리 WARN/CRITICAL, SSH 실패, Spring Boot Health DOWN, Webhook 실패, snapshot stale, 트래픽 알림 대응을 정리했다.

## 배포도 CI 뒤에 자동화했다

처음에는 GitHub에 코드를 올리는 것과 Railway 배포를 분리했다.
수동 배포는 통제감은 있지만, 운영 스크립트가 자주 바뀌는 봇에서는 커밋과 실제 운영 상태가 어긋날 수 있었다.

그래서 Railway service를 GitHub `main` 브랜치에 연결하고, GitHub Actions 검증이 성공한 commit만 배포되도록 바꿨다.

검증은 단순하지만 운영상 중요하다.

```bash
bash -n entrypoint.sh
bash -n scripts/health-check.sh
bash -n scripts/heartbeat-context.sh
bash -n scripts/full-report-scheduler.sh
bash -n scripts/daily-summary-scheduler.sh
```

또한 컨테이너 시작 시 필수 환경변수를 먼저 확인한다.
Discord token, Fireworks API key, SSH private key, Webhook URL, Gateway token이 없으면 봇이 불완전하게 뜨지 않고 즉시 종료된다.

## 권장 조치는 runbook-first로 제한했다

운영 에이전트가 위험해지는 지점은 상태를 알려주는 것보다 조치를 추천하는 순간이다.
LLM은 그럴듯한 해결책을 말할 수 있지만, 운영 환경에서는 그 조치가 검증된 절차인지, LLM의 추론인지 구분되어야 한다.

그래서 PoppingOps의 권장 조치는 runbook-first로 설계했다.

- WARN/CRITICAL 상태 또는 "어떻게 조치해?" 질문이 오면 먼저 `docs/runbook.md`를 기준으로 답한다.
- runbook에 직접 대응 절차가 있으면 해당 절차를 우선 제안한다.
- runbook 기반 권장 조치도 기본적으로 안내이며, 에이전트가 자동으로 실행하지 않는다.
- 재시작, 설정 변경, 배포, write operation은 `운영자가 검토할 조치`로 분리한다.
- runbook에 없으면 `runbook에 직접 절차 없음`을 먼저 밝힌다.
- 그 다음 target-system 문서의 실제 서버 환경/아키텍처와 현재 서버 메트릭을 근거로 `추론 기반 권장 조치`를 제안한다.

예를 들어 runbook에 없는 이상 패턴이 발견되면 다음처럼 답하도록 했다.

```text
runbook에 직접 절차 없음.

추론 기반 권장 조치:

즉시 확인할 조치
1. 같은 시각의 Railway health-check 로그 확인
2. snapshot의 collected_at_kst와 snapshot_age_min 확인
3. 외부 접속 장애라면 Nginx 443 listener, TLS 인증서, Nginx access/error log 확인
4. EC2 exporter 포트 8081/9100/9104 응답 여부 확인
5. 관련 metric의 rate_status_* 값이 init/missing/reset인지 확인

운영자가 검토할 조치
1. Spring Boot app 재시작
2. MySQL connection/pool 설정 조정
3. Nginx 설정 reload 또는 TLS 인증서 갱신
4. exporter 포트 또는 Security Group 설정 확인

재시작이나 설정 변경은 에이전트가 직접 수행하지 않고 운영자가 검토할 조치로만 제시한다.
```

이 방식은 LLM의 유용성을 막지 않으면서도, 검증된 절차와 추론 기반 제안을 명확히 구분한다.
운영 에이전트에서 중요한 것은 "그럴듯한 답"이 아니라, 어떤 근거로 어느 수준의 조치를 제안하는지 통제하는 것이라고 봤다.

## 가장 어려웠던 문제

가장 어려웠던 문제는 LLM 호출을 줄였다고 생각했지만 실제로는 줄지 않았던 점이다.

처음에는 HEARTBEAT.md에 "정상 상태면 LLM 호출 없이 넘어간다"고 적으면 비용이 줄 것이라고 생각했다.
하지만 OpenClaw heartbeat 자체가 LLM 기반으로 동작하기 때문에, 사전 체크를 하라는 판단 자체에도 LLM context가 들어갔다.

즉 문제는 프롬프트가 아니라 실행 경계였다.

해결은 다음과 같았다.

- health-check를 OpenClaw 외부 bash script로 분리
- 정상 판단과 Webhook 알림은 bash가 직접 처리
- LLM은 snapshot을 읽고 보고서를 작성하는 역할로 제한
- Full Report와 Daily Summary는 scheduler가 helper output을 먼저 만들고 LLM에게 전달

이 경험을 통해 AI Agent 운영에서 중요한 것은 LLM에게 더 많은 일을 시키는 것이 아니라, LLM이 개입해야 할 지점과 deterministic system이 책임져야 할 지점을 나누는 것이라는 점을 배웠다.

## 결과

PoppingOps는 단순한 Discord 챗봇이 아니라 운영 에이전트로 발전했다.

얻은 효과는 다음과 같다.

- 정상 반복 체크는 LLM 토큰을 사용하지 않는다.
- 서버 장애와 모니터링 장애를 분리해서 볼 수 있다.
- snapshot freshness를 표시해 오래된 데이터를 최신처럼 말하지 않는다.
- 평균 응답시간과 에러율 기반으로 사용자 영향도를 감지한다.
- Full Report는 변화가 있을 때만 LLM을 호출한다.
- Daily Summary는 helper-first context로 매일 생성된다.
- 역할별 에이전트로 서버, DB, CI/CD 분석을 분리했다.
- runbook과 architecture 문서로 운영 절차를 명확히 했다.
- runbook-first 정책으로 권장 조치의 근거와 실행 경계를 분리했다.
- GitHub Actions 검증 후 Railway 자동 배포로 운영 반영 누락을 줄였다.

## 배운 점

AI Agent Manager의 역할은 에이전트에게 모든 일을 시키는 사람이 아니라, 에이전트가 잘 판단할 수 있는 환경과 경계를 설계하는 사람에 가깝다.

이번 프로젝트에서 가장 중요했던 설계는 다음과 같다.

- deterministic monitoring
- snapshot state layer
- stale data guardrail
- self-monitoring
- traffic quality alert
- helper-first LLM context
- multi-agent role split
- runbook 기반 운영 절차
- runbook-first recommendation guardrail
- CI-gated deployment

결국 좋은 AI 운영 에이전트는 "LLM이 얼마나 똑똑한가"보다 "LLM이 믿을 수 있는 입력을 받고, 적절한 순간에만 개입하는가"에 달려 있었다.
