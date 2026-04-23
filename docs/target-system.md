# Target System

이 문서는 PoppingOps가 모니터링하는 대상 시스템인 Popping-community 서버의 런타임 환경과 운영 해석 기준을 정리한다.

PoppingOps 자체 구조는 `docs/architecture.md`에, 장애 유형별 대응 절차는 `docs/runbook.md`에 분리되어 있다.

## Verification Source

- 로컬 코드 기준: `C:\popping-community\popping-server`
- 배포 서버 기준: Railway Variables의 `EC2_HOST`, `EC2_SSH_PORT`, `EC2_SSH_USER`, `SSH_PRIVATE_KEY`로 read-only SSH 확인
- 최종 확인일: 2026-04-23 KST

## Runtime Environment

- 대상 서버는 AWS EC2 단일 인스턴스에서 실행된다.
- OS는 Amazon Linux 2다.
- 확인 시점 기준 vCPU는 1개, 메모리는 약 952 MiB, root disk는 30 GiB다.
- Spring Boot 애플리케이션과 MySQL이 같은 EC2 host의 CPU, memory, disk, network 자원을 공유한다.
- 서비스는 Docker Compose로 실행된다.
- 외부 HTTPS 트래픽은 EC2 host의 Nginx가 TLS termination 후 Spring Boot `localhost:8080`으로 reverse proxy한다.
- Railway 컨테이너는 PoppingOps 모니터링/Agent 실행 환경이며, 사용자 트래픽을 직접 처리하지 않는다.

## Docker Services

| Service | Container | Image | Role |
|---------|-----------|-------|------|
| Spring Boot app | `popping-community` | `chooh1010/popping-community:latest` | 사용자 요청 처리, MVC/API/WebSocket, actuator metrics 제공 |
| MySQL | `mysql` | `mysql:8` | Popping-community 영속 데이터 저장 |
| node-exporter | `node-exporter` | `prom/node-exporter:latest` | EC2 host resource metrics 제공 |
| mysqld-exporter | `mysqld-exporter` | `prom/mysqld-exporter:v0.15.1` | MySQL status/variable/performance metrics 제공 |

## Network And Ports

| Port | Binding | Component | Purpose |
|------|---------|-----------|---------|
| `443` | host public bind | Nginx | 사용자 HTTPS 트래픽, TLS termination |
| `8080` | host bind | Spring Boot app | Nginx reverse proxy target |
| `8081` | `127.0.0.1` bind | Spring Boot management server | actuator health/prometheus |
| MySQL port | host bind, Security Group restricted | MySQL | database connection |
| `9100` | `127.0.0.1` bind | node-exporter | EC2 host metrics |
| `9104` | `127.0.0.1` bind | mysqld-exporter | MySQL metrics |

운영 보안상 MySQL host bind의 실제 접근 허용 범위는 EC2 Security Group에서 제한되어야 한다.

## External Traffic Path

- public domain은 운영 도메인을 사용한다.
- Nginx가 `443 ssl`로 HTTPS 요청을 수신한다.
- TLS 인증서는 Let's Encrypt 인증서를 사용한다.
- Nginx는 `/` 요청을 `http://localhost:8080`으로 proxy한다.
- Spring Boot container는 host `8080`에 bind되어 Nginx의 upstream target으로 동작한다.

```text
Client
  -> https://{public-domain}:443
  -> Nginx TLS reverse proxy
  -> http://localhost:8080
  -> Spring Boot app container
  -> MySQL container
```

## Application Runtime

- Java 21, Spring Boot 3.4.3 기반이다.
- Docker image는 Jib로 생성된다.
- 컨테이너 JVM 설정은 container support 기반이며 `-Xms200m`, `-Xmx240m`, `MaxMetaspaceSize=128m`로 제한된다.
- 활성 profile은 `dev`다.
- `SERVER_PORT=8080`으로 Nginx가 전달한 사용자 트래픽을 처리한다.
- `MANAGEMENT_SERVER_PORT=8081`로 actuator를 애플리케이션 포트와 분리한다.
- actuator 노출 endpoint는 `health,prometheus`다.
- HTTP server request histogram/percentile metrics가 활성화되어 있다.
- Tomcat MBean registry가 활성화되어 Tomcat thread metrics를 수집할 수 있다.
- HikariCP maximum pool size는 30이다.
- JPA `open-in-view=false`, Hibernate DDL auto는 `update`다.
- 댓글 첫 페이지 캐시는 Caffeine `maximumSize=500,expireAfterWrite=10m,recordStats`를 사용한다.
- 이미지 저장은 AWS S3 설정을 사용한다.

## Observability Sources

PoppingOps는 Railway에서 EC2로 SSH 접속한 뒤 localhost endpoint를 조회한다.

| Source | Endpoint | Main Signals |
|--------|----------|--------------|
| Spring Boot health | `http://localhost:${APP_ACTUATOR_PORT}/actuator/health` | app UP/DOWN |
| Spring Boot prometheus | `http://localhost:${APP_ACTUATOR_PORT}/actuator/prometheus` | HTTP count/sum, JVM memory, Tomcat threads, HikariCP |
| node-exporter | `http://localhost:${NODE_EXPORTER_PORT}/metrics` | memory, swap, load, disk, network, uptime |
| mysqld-exporter | `http://localhost:${MYSQL_EXPORTER_PORT}/metrics` | connections, max connections, queries, slow queries, table locks, row lock waits |

## Operational Interpretation

- node-exporter memory/load/disk 지표는 Spring Boot와 MySQL이 공유하는 EC2 host 전체 상태다.
- 외부 접속 장애는 Nginx/TLS/443 계층과 Spring Boot `8080` 계층을 분리해서 확인해야 한다.
- HTTPS 접속이 실패하지만 actuator health가 UP이면 Nginx listener, TLS certificate, Nginx error log, EC2 Security Group 443 허용 여부를 먼저 본다.
- Nginx가 `localhost:8080` proxy에 실패하면 Spring Boot container 상태와 host `8080` bind 상태를 확인한다.
- EC2 memory가 높을 때는 Spring Boot JVM heap뿐 아니라 MySQL memory, OS page cache, swap 사용량을 함께 봐야 한다.
- MySQL 부하가 높아지면 HikariCP active connection, HTTP response time, EC2 load가 함께 악화될 수 있다.
- actuator health가 DOWN이어도 SSH와 node-exporter가 정상이라면 host 장애가 아니라 Spring Boot app 장애일 가능성이 높다.
- node-exporter가 수집되지 않으면 EC2 host resource 판단을 신뢰할 수 없으므로 resource snapshot completeness를 우선 확인한다.
- mysqld-exporter가 수집되지 않으면 MySQL connection/slow query/table lock 판단을 보류하고 HikariCP, actuator, application log로 교차 확인한다.
- actuator prometheus가 수집되지 않으면 HTTP rate/response/error metrics와 JVM/Tomcat/HikariCP 판단을 보류한다.
- snapshot이 stale이면 현재 상태가 아니라 마지막 수집 상태이므로 `snapshot_age_min`과 health-check 실행 상태를 먼저 확인한다.
- traffic rate metrics는 counter delta 기반이므로 `rate_status_*`가 `ok`가 아닐 때는 장애로 단정하지 않는다.
