# TOOLS.md - PoppingOps Environment (Railway)

## Architecture

```
EC2 (52.79.56.222)
├── docker-compose.yml
│   ├── mysql (container, port 3306)
│   ├── popping-community (app, port 8080, actuator 8081)
│   ├── node-exporter (port 9100)
│   └── mysqld-exporter (port 9104)
│
↕ SSH from Railway
│
Railway (this bot)
├── OpenClaw Gateway + Discord bot
├── health-check.sh → 30min snapshot + Webhook alerts
├── heartbeat-context.sh → Full Report/Daily Summary context
├── full-report-scheduler.sh → 6hr helper-first Gateway /v1/responses trigger
├── daily-summary-scheduler.sh → 9AM KST helper-first Gateway /v1/responses trigger
└── SSH → EC2 for realtime gauges when requested
```

## SSH

- **EC2 Production** — `ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222`
- MySQL runs in Docker container named `mysql` → use `docker exec mysql` for DB access
- SSH key path: `/root/.ssh/ec2-key.pem`

## Monitoring (Direct Exporter Access via SSH)

The automatic monitoring path is `/scripts/health-check.sh`:
- Every 30 minutes it SSHes into EC2 and curls exporters directly.
- It writes the latest snapshot to `/tmp/health-check-alerts/status-current.env`.
- It writes successful snapshot update state to `/tmp/health-check-alerts/last_success.state`.
- It calculates RPS, average response time, error rate, and MySQL QPS from counter deltas between snapshots.
- It sends WARN/CRITICAL/recovery alerts directly through `DISCORD_WEBHOOK_URL` without LLM.
- It separately tracks health SSH, resource SSH, resource parse, and snapshot write failures; two consecutive failures trigger a monitoring-pipeline alert.

Exporter sources:
- **Actuator** — `curl -s http://localhost:8081/actuator/prometheus` (Spring Boot metrics)
- **Node Exporter** — `curl -s http://localhost:9100/metrics` (system metrics)
- **MySQL Exporter** — `curl -s http://localhost:9104/metrics` (MySQL metrics)
- **Actuator Health** — `curl -s http://localhost:8081/actuator/health`

User-facing server reports:
- `서버 상태 확인해줘` → read Railway-local snapshot.
- `실시간 서버 상태 확인해줘` → collect current EC2 gauges over SSH and combine with snapshot rate metrics.
- Prometheus server is not currently required.

Heartbeat reports:
- `Full Report` → `/scripts/full-report-scheduler.sh` runs `/scripts/heartbeat-context.sh full-report` first; if `full_report_should_report=false`, no LLM call
- `Daily Summary` → `/scripts/daily-summary-scheduler.sh` runs `/scripts/heartbeat-context.sh daily-summary` first, injects that context into Gateway `/v1/responses`
- Full Report retry limit: `FULL_REPORT_MAX_ATTEMPTS_PER_WINDOW` (default `3`)
- Daily Summary retry limit: `DAILY_SUMMARY_MAX_ATTEMPTS_PER_DAY` (default `3`)

## CI/CD

- **GitHub Actions** — Repository: `Popping-community/popping-server`
- Workflow file: `.github/workflows/build.yml`
- Pipeline: Gradle build + SonarCloud → Jib Docker → SSH deploy to EC2

## Application

- **App Port**: 8080 (EC2)
- **Actuator Port**: 8081 (EC2)
- **Docker Image**: `chooh1010/popping-community:latest`
- **Actuator Endpoints**: health, prometheus
