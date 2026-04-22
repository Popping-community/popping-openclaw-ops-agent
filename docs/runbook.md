# PoppingOps 운영 Runbook

장애 알림이 왔을 때 먼저 확인할 절차를 정리한다. 자동 알림은 `scripts/health-check.sh`가 Discord Webhook으로 보낸다. 정기 체크는 LLM을 사용하지 않고, 사용자 요청/Full Report/Daily Summary에서만 LLM이 분석한다.

## 공통 확인

최근 health-check 로그를 먼저 확인한다.

```bash
railway logs > railway.log 2>&1
grep -Ei "health-check|Running resource check|Rate metrics|Alert sent|Webhook send failed|Monitor" railway.log
```

최신 snapshot을 확인한다.

```bash
railway shell
cat /tmp/health-check-alerts/status-current.env
```

snapshot이 없거나 오래됐으면 `snapshot stale 대응`을 먼저 본다.

## 메모리 WARN 대응

기준:

- WARN: memory >= 80%
- CRITICAL: memory >= 95%
- 복구: memory < 70%

1. Discord 보고서 또는 snapshot에서 JVM heap과 system memory를 같이 본다.

```bash
grep -E "mem_usage|jvm_heap|collected_at" /tmp/health-check-alerts/status-current.env
```

2. JVM heap이 낮고 system memory만 높으면 EC2의 다른 프로세스 또는 Docker 레벨 사용량을 확인한다.

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "free -m && ps aux --sort=-%mem | head -15 && docker stats --no-stream"
```

3. 메모리 증가가 일시적이면 다음 10분 체크까지 관찰한다. WARN 유지 상태에서는 반복 알림이 오지 않는 것이 정상이다.

4. 원인이 애플리케이션이면 최근 배포/트래픽/배치 작업을 확인한다.

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker logs --tail=200 popping-community"
```

## 메모리 CRITICAL 대응

1. 즉시 EC2 메모리 상태와 OOM 흔적을 확인한다.

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "free -m && dmesg -T | tail -80 | grep -Ei 'oom|killed process|out of memory' || true"
```

2. 가장 큰 메모리 사용 프로세스를 확인한다.

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "ps aux --sort=-%mem | head -20 && docker stats --no-stream"
```

3. JVM heap이 CRITICAL이면 heap dump 또는 GC 로그 확인을 우선한다. JVM heap은 정상인데 system memory만 높으면 MySQL, Docker, OS cache, 다른 프로세스를 의심한다.

4. 서비스 영향이 있으면 애플리케이션 재시작을 검토한다. 재시작 전후로 Discord에 조치 내용을 남긴다.

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker restart popping-community"
```

5. CRITICAL이 지속되면 2시간 또는 3회 체크마다 재알림이 오는 것이 정상이다.

## SSH 실패 대응

알림 예:

- `SSH 연결 실패`
- `모니터링 장애 — resource SSH collection 연속 2회 실패`

1. Railway 로그에서 실패 범위를 확인한다.

```bash
grep -Ei "SSH 연결|resource SSH|health SSH|Monitor" railway.log
```

2. 로컬 또는 Railway shell에서 SSH 연결을 확인한다.

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p 2222 ec2-user@52.79.56.222 "echo ok"
```

3. 실패하면 아래 항목을 확인한다.

- EC2 인스턴스 실행 상태
- Security Group inbound `2222/tcp`
- EC2의 sshd 상태
- Railway 환경변수 `SSH_PRIVATE_KEY`
- EC2 IP 변경 여부

4. SSH가 복구되면 health-check가 다음 주기에 `모니터링 복구됨`을 보낼 수 있다.

## Spring Boot Health DOWN 대응

알림 예:

- `Spring Boot Health DOWN`
- actuator `/actuator/health`가 `UP`이 아님

1. EC2에서 actuator health를 직접 확인한다.

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "curl -s http://localhost:8081/actuator/health"
```

2. 컨테이너 상태와 포트 리스닝을 확인한다.

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker ps && ss -ltnp | grep -E ':8080|:8081' || true"
```

3. 애플리케이션 로그를 확인한다.

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker logs --tail=300 popping-community"
```

4. DB 연결 문제라면 MySQL 컨테이너와 connection 수를 확인한다.

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker ps | grep -i mysql && curl -s http://localhost:9104/metrics | grep -E '^mysql_global_(status_threads_connected|variables_max_connections)'"
```

5. 최근 배포 직후라면 GitHub Actions/배포 로그도 같이 본다.

## GitHub push 후 Railway 배포가 시작되지 않음

Railway service는 GitHub `main` branch와 연결되어 있고, `Wait for CI`가 켜져 있으면 GitHub Actions 검증이 성공한 commit만 배포한다.
따라서 GitHub Actions 실패로 Railway 배포가 시작되지 않는 것은 정상적인 차단 동작이다.

1. GitHub Actions `Validate` workflow가 성공했는지 확인한다.

2. 실패했다면 `bash -n` 오류가 난 script를 수정하고 다시 push한다.

3. Railway service가 GitHub `main` branch에 연결되어 있는지 확인한다.

4. Railway deployment 설정에서 `Wait for CI`가 켜져 있는지 확인한다.

5. CI는 성공했는데 배포가 없으면 Railway dashboard에서 최신 deployment 이벤트를 확인한다.

## Webhook 알림 실패 대응

로그 예:

- `Webhook send failed`
- `WEBHOOK_URL not set, skipping Discord alert`
- `Fatal: required environment variables are missing; refusing to start`

`DISCORD_WEBHOOK_URL`은 운영 알림 필수 변수다. 현재 `entrypoint.sh`는 이 값이 없으면 컨테이너를 시작하지 않는다.

1. Railway 환경변수가 있는지 확인한다.

```bash
railway variables | grep DISCORD_WEBHOOK_URL
```

2. Webhook URL을 직접 테스트한다. URL은 공개 채팅에 남기지 않는다.

```bash
curl -i -H "Content-Type: application/json" -d '{"content":"webhook test"}' "$DISCORD_WEBHOOK_URL"
```

정상이면 Discord 채널에 메시지가 오고 HTTP `204 No Content`가 반환된다.

3. 실패하거나 누락됐으면 Discord Webhook을 새로 발급하고 Railway 변수만 교체한다.

```bash
railway variables set DISCORD_WEBHOOK_URL="새_WEBHOOK_URL"
railway up
```

## Snapshot Stale 대응

기준:

- 20분 이상 오래됨: WARN
- 30분 이상 오래됨: CRITICAL 또는 수집 중단 가능성

1. snapshot 측정 시각을 확인한다.

```bash
railway shell
grep -E "collected_at|snapshot_interval_min|overall_status" /tmp/health-check-alerts/status-current.env
cat /tmp/health-check-alerts/last_success.state
```

2. health-check 루프가 살아 있는지 로그를 확인한다.

```bash
grep -Ei "Starting health check|Running health check|Running resource check|Resource check done|Snapshot updated|Monitor" railway.log
```

3. `Running resource check`는 있는데 `Snapshot updated`가 없으면 SSH, exporter, parse, snapshot write 실패를 확인한다.

```bash
grep -Ei "resource SSH|resource parse|snapshot|Monitor|failed|FAIL" railway.log
```

4. Railway 컨테이너가 재시작된 직후라면 첫 rate 계산이 `init`일 수 있다. 이것만으로 장애로 판단하지 않는다.

5. health-check 프로세스가 죽은 것으로 보이면 Railway 배포를 재시작한다.

```bash
railway up
```

## 트래픽 알림 대응

기준:

- 평균 응답시간 WARN: > 1s
- 평균 응답시간 CRITICAL: > 3s
- HTTP 에러율 WARN: > 1%
- HTTP 에러율 CRITICAL: > 5%

1. 최신 rate 상태를 확인한다.

```bash
grep -E "http_rps|avg_response|error_rate|rate_status" /tmp/health-check-alerts/status-current.env
```

2. `rate_status_*`가 `init`, `missing`, `reset`이면 트래픽 알림 판단 대상이 아니다.

3. 응답시간이 높으면 애플리케이션 로그, DB lock, slow query를 같이 확인한다.

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker logs --tail=300 popping-community && curl -s http://localhost:9104/metrics | grep -E '^mysql_global_status_(slow_queries|innodb_row_lock_waits|table_locks_waited)'"
```

4. 에러율이 높으면 최근 예외 로그와 HTTP 5xx 원인을 확인한다.

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker logs --tail=500 popping-community | grep -Ei 'error|exception|5[0-9][0-9]'"
```

## 복구 확인

복구 기준을 만족하면 다음 health-check에서 복구 알림이 전송된다.

```bash
grep -Ei "복구됨|OK ->|WARN/CRITICAL|Alert sent" railway.log
```

복구 알림이 없더라도 Railway 컨테이너가 재시작되어 이전 상태가 초기화된 경우일 수 있다. 이때는 최신 snapshot의 metric status를 기준으로 판단한다.
