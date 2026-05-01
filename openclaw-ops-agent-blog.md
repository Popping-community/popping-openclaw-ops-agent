# PoppingOps 구축기

## Discord에서 서버 상태를 묻고, 장애 알림과 권장 조치까지 받는 운영 봇 만들기

PoppingOps는 EC2에서 운영 중인 Spring Boot/MySQL 서비스를 외부에서 감시하고, Discord에서 서버 상태 조회와 장애 알림을 제공하는 운영 모니터링 시스템입니다.

처음에는 "Discord에서 `서버 상태 확인해줘`라고 말하면 LLM 봇이 알아서 보고해주면 되지 않을까?"라고 생각했습니다.  
하지만 실제로 운영해보니 더 중요한 문제는 따로 있었습니다.

- 정상 상태에서도 반복 체크가 LLM 비용을 계속 발생시키지 않는가
- 오래된 데이터를 최신 상태처럼 보고하지 않는가
- 서버 장애와 모니터링 장애를 구분할 수 있는가
- 알림만 보내고 끝나는 것이 아니라, 다음 조치를 바로 안내할 수 있는가

그래서 이 프로젝트는 단순한 챗봇이 아니라, deterministic monitoring과 LLM analysis를 분리한 운영 시스템으로 다시 설계하게 되었습니다.

## 실제로 어떻게 보이는가

README처럼 추상적인 설명만 두기보다, 실제로 Discord에서 어떻게 동작하는지가 먼저 보이는 편이 낫다고 판단했습니다.

### 1. 장애 경고와 권장 조치

메모리 WARN이 발생하면 Discord로 경고와 권장 조치를 함께 보냅니다.

![PoppingOps Discord warning](docs/images/readme/discord-warning.png)

### 2. 현재 서버 상태 조회

사용자가 서버 상태를 요청하면 최신 snapshot 기준으로 상태를 빠르게 요약해 보여줍니다.

![PoppingOps Discord server status](docs/images/readme/discord-server-status.png)

### 3. 실시간 서버 상태 조회

snapshot만 읽는 것이 아니라, 필요하면 즉시 SSH 수집 기반으로 현재 상태를 다시 확인할 수 있습니다.

![PoppingOps Discord realtime status](docs/images/readme/discord-realtime-status.png)

이 세 장의 화면이 이 프로젝트가 제공하는 핵심 경험입니다.

- 평소에는 조용히 감시합니다.
- 이상이 생기면 먼저 알려줍니다.
- 필요할 때는 바로 상태를 물어볼 수 있습니다.

## 왜 새로 만들었는가

처음 Popping-community 서버는 EC2 t2.micro 한 대에서 Spring Boot와 MySQL을 함께 운영했습니다.  
Prometheus와 Grafana를 EC2에 같이 띄우기에는 리소스가 빠듯해서, 한동안 로컬 PC에서 모니터링에 의존했습니다.

문제는 명확했습니다.

- PC를 끄면 모니터링과 알림도 함께 멈춥니다.
- 장애가 나도 늦게 알 수 있습니다.
- 로컬 환경에 의존하면 운영 구조가 불안정합니다.

즉, "서버가 죽는 것"보다 "죽었는데도 늦게 아는 것"이 더 큰 문제였습니다.  
그래서 감시 자체를 서버 외부에서 상시 실행되는 구조로 옮기는 것이 첫 번째 목표가 되었습니다.

## 전체 구조

PoppingOps는 아래 구조로 동작합니다.

![PoppingOps architecture](docs/images/readme/architecture.png)

핵심은 역할을 분리한 것입니다.

- `health-check.sh`가 SSH로 메트릭을 수집하고 임계값을 판단합니다.
- 최신 상태는 snapshot 파일에 저장합니다.
- Discord 봇은 snapshot이나 실시간 수집 결과를 바탕으로 상태를 보여줍니다.
- LLM은 이미 정리된 context를 받아 해석과 요약이 필요한 구간에서만 사용합니다.

즉, 메트릭 수집과 반복 판단은 Bash가 맡고, 설명과 요약은 LLM이 맡습니다.

## 문제 1. 정상 반복 체크에도 LLM 비용이 발생했습니다

초기에는 OpenClaw heartbeat로 주기 체크를 돌리려고 했습니다.  
문서에 "정상이면 조용히 넘어간다"고 적으면 비용도 적게 들 것이라고 생각했습니다.

하지만 실제로는 그렇지 않았습니다.

- OpenClaw heartbeat 자체가 LLM 기반으로 동작합니다.
- 따라서 "정상인지 확인해라"라는 판단 단계부터 이미 context가 로드됩니다.
- 결과적으로 정상 상태에서도 계속 토큰 비용과 지연이 발생했습니다.

문제는 프롬프트가 아니라 실행 경계였습니다.

```text
Before
30분 heartbeat
  -> OpenClaw LLM 호출
  -> LLM이 health check 명령 판단
  -> metric 수집
  -> LLM이 정상/이상 판단

After
10분 health-check.sh
  -> bash가 SSH로 metric 수집
  -> bash가 임계값 판단
  -> 정상이면 아무것도 하지 않음
  -> 이상/복구 시 Discord Webhook 알림
```

이렇게 바꾸면서 정상 반복 체크는 LLM을 아예 호출하지 않게 되었습니다.  
LLM은 사용자 요청, Full Report, Daily Summary, 그리고 deterministic rule에 없는 알림의 fallback 권장 조치에서만 쓰도록 제한했습니다.

## 문제 2. snapshot은 빠르지만, stale data를 최신처럼 보일 수 있습니다

Discord에서 상태를 물었을 때 매번 SSH로 다시 수집하면 느리고 비용도 커집니다.  
그래서 기본 응답은 health-check가 주기적으로 만든 snapshot을 읽는 방식으로 설계했습니다.

```bash
/tmp/health-check-alerts/status-current.env
```

하지만 snapshot 기반 구조는 한 가지 위험이 있습니다.  
수집이 멈췄는데 마지막 정상값이 그대로 남아 있으면, 봇이 오래된 값을 현재 상태처럼 말할 수 있습니다.

그래서 snapshot freshness를 같이 저장하고 보고서에도 노출했습니다.

| Snapshot age | 데이터 상태 | 보고 severity |
|---|---|---|
| 20분 미만 | 최신 | 기존 metric severity 유지 |
| 20분 이상 | 오래됨 | 최소 WARN |
| 30분 이상 | 수집 중단 가능성 | CRITICAL |

즉 PoppingOps는 숫자만 보여주는 게 아니라, "이 숫자가 얼마나 최신인지"도 함께 보여줍니다.

## 문제 3. 서버 장애와 모니터링 장애를 구분해야 했습니다

운영 시스템은 서버만 감시해서는 부족합니다.  
감시 파이프라인 자체가 실패할 수도 있기 때문입니다.

PoppingOps는 다음 실패를 별도로 추적합니다.

- SSH 실패
- 메트릭 파싱 실패
- 필수 메트릭 누락
- snapshot 쓰기 실패

같은 유형이 연속으로 발생하면 "서버 장애"가 아니라 "모니터링 장애"로 따로 알립니다.  
이 구분이 없으면 감시가 멈췄는데도 정상이라고 착각할 수 있습니다.

이 설계의 핵심은 단순히 알림을 많이 보내는 것이 아니라, 장애의 종류를 좁혀서 운영자가 시작점을 더 빨리 찾게 만드는 것입니다.

## 문제 4. 리소스가 정상이더라도 사용자 경험은 나쁠 수 있습니다

초기 알림 기준은 메모리, CPU, 디스크 중심이었습니다.  
하지만 실제 서비스에서는 리소스가 아직 버티고 있어도 응답시간과 에러율이 먼저 나빠질 수 있습니다.

그래서 actuator counter delta를 이용해 트래픽 품질 지표를 계산했습니다.

| Metric | WARN | CRITICAL |
|---|---:|---:|
| Avg Response | > 1s | > 3s |
| Error Rate | > 1% | > 5% |

이렇게 하면 "서버는 살아 있는데 사용자는 느리거나 실패를 겪는" 상황도 감지할 수 있습니다.  
즉 시스템 리소스 중심 모니터링에서 사용자 영향 중심 모니터링으로 한 단계 더 나아간 셈입니다.

## 알림만 보내면 부족했습니다

운영 알림이 왔을 때 사람이 다시 봇에게 "어떻게 조치해?"를 물어야 하는 구조는 번거로웠습니다.  
그래서 WARN/CRITICAL 알림이 실제 전송된 직후, 권장 조치도 후속 Discord 메시지로 자동 전송하도록 바꿨습니다.

여기서도 기준은 분명했습니다.

- `config/runbook-recommendations.json`에 매칭되는 알림은 LLM 없이 deterministic recommendation 사용
- 매칭되지 않는 알림만 Gateway `/v1/responses`를 통한 LLM fallback 사용
- 권장 조치 생성이 실패해도 알림 자체는 막지 않음

즉, 알림 파이프라인과 권장 조치 파이프라인을 분리해 "알림은 반드시 살아 있고, 해석은 그 다음"이라는 구조를 유지했습니다.

## LLM은 helper-first context로만 사용했습니다

이 프로젝트에서 LLM에게 가장 맡기고 싶지 않았던 일은 "직접 뭘 실행해서 상태를 확인하는 것"이었습니다.  
운영에서는 자유도가 높을수록 비용도 커지고, 결과도 흔들립니다.

그래서 먼저 deterministic helper가 context를 만들고, LLM은 그 결과만 해석하게 했습니다.

```bash
scripts/heartbeat-context.sh full-report
scripts/heartbeat-context.sh daily-summary
```

이 구조 덕분에:

- Full Report는 변화가 있을 때만 LLM을 호출할 수 있었고
- Daily Summary도 이미 정리된 snapshot과 CI/CD 상태를 바탕으로 생성할 수 있었고
- LLM이 메트릭을 잘못 읽거나 누적 지표를 오해할 가능성을 줄일 수 있었습니다

결국 중요한 것은 "LLM을 쓰느냐"가 아니라 "LLM에게 어떤 입력을 주느냐"였습니다.

## 역할별 멀티 에이전트로 분리했습니다

처음에는 하나의 에이전트가 서버, DB, CI/CD를 모두 처리하게 했지만 오래 가지 않았습니다.  
도메인이 섞일수록 prompt가 커지고, 각 영역의 판단이 얕아졌습니다.

그래서 역할을 다음처럼 나눴습니다.

| Agent | Role |
|---|---|
| PoppingOps | 서버, 인프라, 트래픽 모니터링 |
| PoppingDBA | MySQL/InnoDB 분석 |
| PoppingDev | GitHub Actions, 배포 상태 분석 |

이 분리는 단순한 "봇 개수 늘리기"가 아니라 context boundary를 나누는 작업이었습니다.  
AI Agent Manager 관점에서는 에이전트의 수보다, 각 에이전트가 어떤 책임과 근거를 가지는지가 더 중요하다고 봤습니다.

## 배포도 운영 방식에 맞게 바꿨습니다

운영 스크립트가 자주 바뀌는 프로젝트에서 수동 배포는 커밋 상태와 실제 운영 상태를 어긋나게 만들기 쉽습니다.  
그래서 GitHub Actions 검증을 통과한 `main` 커밋만 Railway가 자동 배포하도록 바꿨습니다.

검증 내용은 단순하지만 중요합니다.

```bash
bash -n entrypoint.sh
bash -n scripts/health-check.sh
bash -n scripts/heartbeat-context.sh
bash -n scripts/full-report-scheduler.sh
bash -n scripts/daily-summary-scheduler.sh
```

또한 컨테이너 시작 시 필수 환경변수를 먼저 검증해 불완전한 상태로 서비스가 뜨지 않게 했습니다.

## 결과

PoppingOps는 단순한 Discord 챗봇이 아니라, 실제 운영에 쓸 수 있는 감시와 보고 시스템으로 정리되었습니다.

- 로컬 PC에 의존하던 모니터링을 외부 상시 감시 구조로 전환했습니다.
- 정상 반복 체크에서 LLM 비용이 발생하지 않도록 구조를 분리했습니다.
- stale snapshot을 최신 데이터로 오인하는 문제를 막았습니다.
- 서버 장애와 모니터링 장애를 분리해서 볼 수 있게 했습니다.
- 평균 응답시간과 에러율 기반으로 사용자 영향도를 감지할 수 있게 했습니다.
- WARN/CRITICAL 알림 이후 권장 조치를 자동 후속 전송하도록 만들었습니다.
- Full Report와 Daily Summary는 helper-first context 기반으로 정리했습니다.
- 역할별 에이전트로 서버, DB, CI/CD 분석을 나눴습니다.

## 마무리

이 프로젝트를 하면서 가장 크게 배운 점은 하나였습니다.  
운영 에이전트에서 중요한 것은 "LLM이 얼마나 많은 일을 할 수 있는가"가 아니라, "LLM이 어디까지 개입해야 하는가"를 설계하는 일이라는 점입니다.

좋은 운영 에이전트는 다음을 만족해야 한다고 생각합니다.

- 정상 상태에서는 조용하고 저렴할 것
- 이상 상태에서는 먼저 알려줄 것
- 오래된 데이터와 현재 데이터를 구분할 것
- 권장 조치의 근거와 한계를 분리할 것
- LLM이 꼭 필요한 순간에만 개입할 것

PoppingOps는 그 기준을 만족시키기 위해 deterministic monitoring, snapshot state layer, self-monitoring, runbook-first recommendation, helper-first LLM context를 조합해 만든 프로젝트입니다.
