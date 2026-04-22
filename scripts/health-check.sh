#!/bin/bash
# health-check.sh — OpenClaw 외부에서 동작하는 순수 bash 헬스체크
# 정상 시 토큰 소비 0, 이상 시 Discord Webhook으로 알림

SSH_CMD="ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p 2222 ec2-user@52.79.56.222"
WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL_SECONDS:-600}"  # 10분 (초)
case "$CHECK_INTERVAL" in
  ''|*[!0-9]*)
    echo "WARNING: invalid HEALTH_CHECK_INTERVAL_SECONDS='${CHECK_INTERVAL}', using 600"
    CHECK_INTERVAL=600
    ;;
esac
if [ "$CHECK_INTERVAL" -lt 60 ]; then
  echo "WARNING: HEALTH_CHECK_INTERVAL_SECONDS must be >= 60, using 60"
  CHECK_INTERVAL=60
fi
SNAPSHOT_INTERVAL_MIN=$((CHECK_INTERVAL / 60))
if [ "$SNAPSHOT_INTERVAL_MIN" -lt 1 ]; then
  SNAPSHOT_INTERVAL_MIN=1
fi
CRITICAL_REMINDER_SECONDS=7200  # 2시간
CRITICAL_REMINDER_CHECKS=3
MONITOR_FAILURE_THRESHOLD=2

# 중복 알림 방지용 (알림별 타임스탬프 저장 디렉토리)
ALERT_STATE_DIR="/tmp/health-check-alerts"
mkdir -p "$ALERT_STATE_DIR"

log() {
  echo "$(date -u '+%Y-%m-%dT%H:%M:%S+00:00') [health-check] $*"
}

monitor_state_file() {
  echo "${ALERT_STATE_DIR}/monitor-${1}.state"
}

record_monitor_success() {
  local key="$1"
  local label="$2"
  local file
  file=$(monitor_state_file "$key")

  if [ -f "$file" ]; then
    local previous_count
    previous_count=$(cut -d'|' -f1 "$file" 2>/dev/null || echo "0")
    if [ "${previous_count:-0}" -ge "$MONITOR_FAILURE_THRESHOLD" ]; then
      send_alert "INFO" "모니터링 복구됨 — ${label}"
    fi
  fi

  echo "0|$(date +%s)|" > "$file"
  log "Monitor ${label}: OK"
}

record_monitor_failure() {
  local key="$1"
  local label="$2"
  local detail="$3"
  local file count first_failed_at previous_detail
  file=$(monitor_state_file "$key")

  if [ -f "$file" ]; then
    IFS='|' read -r count first_failed_at previous_detail < "$file"
  fi

  count=${count:-0}
  first_failed_at=${first_failed_at:-$(date +%s)}
  count=$((count + 1))
  echo "${count}|${first_failed_at}|${detail}" > "$file"

  if [ "$count" -eq "$MONITOR_FAILURE_THRESHOLD" ]; then
    send_alert "WARN" "모니터링 장애 — ${label} 연속 ${count}회 실패 (${detail})"
  elif [ "$count" -gt "$MONITOR_FAILURE_THRESHOLD" ]; then
    log "Monitor ${label}: still failing (${count} consecutive, ${detail})"
  else
    log "Monitor ${label}: failure ${count}/${MONITOR_FAILURE_THRESHOLD} (${detail})"
  fi
}

record_snapshot_success() {
  local snapshot_file="$1"
  local now_ts="$2"
  local collected_at_utc="$3"

  echo "${now_ts}|${collected_at_utc}|${snapshot_file}" > "${ALERT_STATE_DIR}/last_success.state"
  record_monitor_success "snapshot_write" "snapshot 갱신"
  log "Monitor snapshot: last_success_epoch=${now_ts}"
}

# Discord Webhook으로 메시지 전송
send_alert() {
  local severity="$1"
  local message="$2"

  if [ -z "$WEBHOOK_URL" ]; then
    log "WEBHOOK_URL not set, skipping Discord alert"
    return
  fi

  # 중복 방지: 동일 메시지를 30분 내 재전송하지 않음
  local msg_hash
  msg_hash=$(echo "$message" | md5sum | cut -d' ' -f1)
  local state_file="${ALERT_STATE_DIR}/${msg_hash}"
  if [ -f "$state_file" ]; then
    local last_time now
    last_time=$(cat "$state_file" 2>/dev/null || echo "0")
    now=$(date +%s)
    if [ $((now - last_time)) -lt 1800 ]; then
      log "Duplicate alert suppressed (same alert within 30min)"
      return
    fi
  fi

  local emoji="⚠️"
  [ "$severity" = "INFO" ] && emoji="✅"
  [ "$severity" = "CRITICAL" ] && emoji="🚨"

  local payload
  payload=$(node - "$emoji" "$severity" "$message" <<'NODE'
const [, , emoji, severity, message] = process.argv;
process.stdout.write(JSON.stringify({
  content: `${emoji} **[${severity}]** ${message}`
}));
NODE
)

  curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$WEBHOOK_URL" > /dev/null 2>&1 || log "Webhook send failed"

  date +%s > "$state_file"
  log "Alert sent: [$severity] $message"
}

get_metric_state() {
  local key="$1"
  local file="${ALERT_STATE_DIR}/${key}.state"

  if [ -f "$file" ]; then
    cut -d'|' -f1 "$file" 2>/dev/null || echo "OK"
  else
    echo "OK"
  fi
}

set_metric_state() {
  local key="$1"
  local status="$2"
  local value="$3"
  local file="${ALERT_STATE_DIR}/${key}.state"

  echo "${status}|${value}|$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')" > "$file"
}

set_critical_reminder_state() {
  local key="$1"
  local last_alert_epoch="$2"
  local checks_since_alert="$3"
  local file="${ALERT_STATE_DIR}/${key}.critical"

  echo "${last_alert_epoch}|${checks_since_alert}" > "$file"
}

clear_critical_reminder_state() {
  local key="$1"
  local file="${ALERT_STATE_DIR}/${key}.critical"

  rm -f "$file"
}

handle_critical_reminder() {
  local key="$1"
  local label="$2"
  local value="$3"
  local alert_message="$4"
  local file="${ALERT_STATE_DIR}/${key}.critical"
  local now last_alert_epoch checks_since_alert elapsed

  now=$(date +%s)

  if [ -f "$file" ]; then
    IFS='|' read -r last_alert_epoch checks_since_alert < "$file"
  fi

  if [ -z "$last_alert_epoch" ] || [ -z "$checks_since_alert" ]; then
    set_critical_reminder_state "$key" "$now" "0"
    log "${label}: CRITICAL (${value})"
    return
  fi

  checks_since_alert=$((checks_since_alert + 1))
  elapsed=$((now - last_alert_epoch))

  if [ "$elapsed" -ge "$CRITICAL_REMINDER_SECONDS" ] || [ "$checks_since_alert" -ge "$CRITICAL_REMINDER_CHECKS" ]; then
    send_alert "CRITICAL" "${alert_message} — 지속 중 (${value}, ${checks_since_alert} checks, ${elapsed}s)"
    set_critical_reminder_state "$key" "$now" "0"
    log "${label}: CRITICAL reminder sent (${value}, checks=${checks_since_alert}, elapsed=${elapsed}s)"
  else
    set_critical_reminder_state "$key" "$last_alert_epoch" "$checks_since_alert"
    log "${label}: CRITICAL (${value}) reminder pending (checks=${checks_since_alert}, elapsed=${elapsed}s)"
  fi
}

handle_state_change() {
  local key="$1"
  local label="$2"
  local current_status="$3"
  local value="$4"
  local alert_message="$5"
  local previous_status

  previous_status=$(get_metric_state "$key")

  if [ "$current_status" = "$previous_status" ]; then
    if [ "$current_status" = "CRITICAL" ]; then
      handle_critical_reminder "$key" "$label" "$value" "$alert_message"
      return
    fi
    log "${label}: ${current_status} (${value})"
    return
  fi

  if [ "$current_status" = "OK" ] && [ "$previous_status" != "OK" ]; then
    send_alert "INFO" "${label} 복구됨 — 이전 ${previous_status}, 현재 ${value}"
    clear_critical_reminder_state "$key"
  elif [ "$current_status" = "WARN" ]; then
    send_alert "WARN" "$alert_message"
    clear_critical_reminder_state "$key"
  elif [ "$current_status" = "CRITICAL" ]; then
    send_alert "CRITICAL" "$alert_message"
    set_critical_reminder_state "$key" "$(date +%s)" "0"
  else
    clear_critical_reminder_state "$key"
  fi

  set_metric_state "$key" "$current_status" "$value"
  log "${label}: ${previous_status} -> ${current_status} (${value})"
}

counter_rate() {
  local key="$1"
  local current_value="$2"
  local now_ts="$3"
  local file="${ALERT_STATE_DIR}/${key}.sample"

  if [ -z "$current_value" ]; then
    echo "NA NA missing"
    return
  fi

  if [ ! -f "$file" ]; then
    echo "${now_ts}|${current_value}" > "$file"
    echo "NA NA init"
    return
  fi

  local prev_ts prev_value
  IFS='|' read -r prev_ts prev_value < "$file"

  if [ -z "$prev_ts" ] || [ -z "$prev_value" ]; then
    echo "${now_ts}|${current_value}" > "$file"
    echo "NA NA init"
    return
  fi

  echo "${now_ts}|${current_value}" > "$file"

  awk "BEGIN {
    dt = ${now_ts} - ${prev_ts};
    delta = ${current_value} - ${prev_value};
    if (dt <= 0) {
      print \"NA NA invalid\";
    } else if (delta < 0) {
      print \"NA NA reset\";
    } else {
      printf \"%.4f %.4f ok\", delta / dt, delta;
    }
  }"
}

# --- 10분마다: Health Quick Check ---
health_check() {
  log "Running health check..."

  local result
  result=$($SSH_CMD "curl -sf http://localhost:8081/actuator/health | grep -q UP && echo HEALTHY || echo DOWN" 2>&1) || result="SSH_FAIL"

  # SSH 배너/MOTD 등이 포함될 수 있으므로 마지막 줄만 확인
  local last_line
  last_line=$(echo "$result" | tail -1 | tr -d '[:space:]')

  if [ "$last_line" = "HEALTHY" ]; then
    record_monitor_success "health_ssh" "health SSH 체크"
    handle_state_change "app_health" "Spring Boot Health" "OK" "HEALTHY" ""
    handle_state_change "ssh" "SSH 연결" "OK" "OK" ""
    log "Health: HEALTHY"
    return 0
  elif [ "$last_line" = "DOWN" ]; then
    record_monitor_success "health_ssh" "health SSH 체크"
    handle_state_change "ssh" "SSH 연결" "OK" "OK" ""
    handle_state_change "app_health" "Spring Boot Health" "CRITICAL" "DOWN" "Spring Boot Health DOWN — actuator/health가 UP이 아닙니다"
    return 1
  else
    record_monitor_failure "health_ssh" "health SSH 체크" "actuator health 조회 실패"
    handle_state_change "ssh" "SSH 연결" "CRITICAL" "FAIL" "SSH 연결 실패 — EC2 접속 불가 (result: ${result:0:100})"
    return 1
  fi
}

# --- 10분마다: Resource Quick Check + Snapshot Update ---
resource_check() {
  log "Running resource check..."

  local raw
  raw=$($SSH_CMD 'bash -s' <<'REMOTE_SCRIPT'
HEALTH=$(curl -sf http://localhost:8081/actuator/health | grep -c UP)
APP_METRICS=$(curl -s http://localhost:8081/actuator/prometheus)
NODE_METRICS=$(curl -s http://localhost:9100/metrics)
MYSQL_METRICS=$(curl -s http://localhost:9104/metrics)
MEM_AVAIL=$(echo "$NODE_METRICS" | grep "^node_memory_MemAvailable_bytes " | awk '{print $2}')
MEM_TOTAL=$(echo "$NODE_METRICS" | grep "^node_memory_MemTotal_bytes " | awk '{print $2}')
SWAP_FREE=$(echo "$NODE_METRICS" | grep "^node_memory_SwapFree_bytes " | awk '{print $2}')
SWAP_TOTAL=$(echo "$NODE_METRICS" | grep "^node_memory_SwapTotal_bytes " | awk '{print $2}')
LOAD=$(echo "$NODE_METRICS" | grep "^node_load1 " | awk '{print $2}')
LOAD5=$(echo "$NODE_METRICS" | grep "^node_load5 " | awk '{print $2}')
LOAD15=$(echo "$NODE_METRICS" | grep "^node_load15 " | awk '{print $2}')
DISK_AVAIL=$(echo "$NODE_METRICS" | grep 'node_filesystem_avail_bytes{' | grep 'fstype="xfs"' | head -1 | awk '{print $2}')
DISK_TOTAL=$(echo "$NODE_METRICS" | grep 'node_filesystem_size_bytes{' | grep 'fstype="xfs"' | head -1 | awk '{print $2}')
NODE_TIME=$(echo "$NODE_METRICS" | grep "^node_time_seconds " | awk '{print $2}')
NODE_BOOT=$(echo "$NODE_METRICS" | grep "^node_boot_time_seconds " | awk '{print $2}')
NET_RX=$(echo "$NODE_METRICS" | grep '^node_network_receive_bytes_total{' | grep 'device="eth0"' | awk '{sum += $NF} END {printf "%.0f", sum+0}')
NET_TX=$(echo "$NODE_METRICS" | grep '^node_network_transmit_bytes_total{' | grep 'device="eth0"' | awk '{sum += $NF} END {printf "%.0f", sum+0}')
TOMCAT_BUSY=$(echo "$APP_METRICS" | awk '$1 ~ /^tomcat_threads_busy/ {sum += $NF} END {printf "%.0f", sum+0}')
TOMCAT_MAX=$(echo "$APP_METRICS" | awk '$1 ~ /^tomcat_threads_config_max/ {sum += $NF} END {printf "%.0f", sum+0}')
HIKARI_ACTIVE=$(echo "$APP_METRICS" | awk '$1 ~ /^hikaricp_connections_active/ {sum += $NF} END {printf "%.0f", sum+0}')
HIKARI_MAX=$(echo "$APP_METRICS" | awk '$1 ~ /^hikaricp_connections_max/ {sum += $NF} END {printf "%.0f", sum+0}')
JVM_HEAP_USED=$(echo "$APP_METRICS" | awk '$1 ~ /^jvm_memory_used_bytes/ && $0 ~ /area="heap"/ {sum += $NF} END {printf "%.0f", sum+0}')
JVM_HEAP_MAX=$(echo "$APP_METRICS" | awk '$1 ~ /^jvm_memory_max_bytes/ && $0 ~ /area="heap"/ {sum += $NF} END {printf "%.0f", sum+0}')
GC_PAUSE_SUM=$(echo "$APP_METRICS" | awk '$1 ~ /^jvm_gc_pause_seconds_sum/ {sum += $NF} END {printf "%.6f", sum+0}')
HTTP_COUNT=$(echo "$APP_METRICS" | awk '$1 ~ /^http_server_requests_seconds_count/ {sum += $NF} END {printf "%.0f", sum+0}')
HTTP_SUM=$(echo "$APP_METRICS" | awk '$1 ~ /^http_server_requests_seconds_sum/ {sum += $NF} END {printf "%.6f", sum+0}')
HTTP_5XX_COUNT=$(echo "$APP_METRICS" | awk '$1 ~ /^http_server_requests_seconds_count/ && ($0 ~ /status="5[0-9][0-9]"/ || $0 ~ /outcome="SERVER_ERROR"/) {sum += $NF} END {printf "%.0f", sum+0}')
MYSQL_CONNECTED=$(echo "$MYSQL_METRICS" | awk '/^mysql_global_status_threads_connected / {print $2; found=1} END {if (!found) print 0}')
MYSQL_MAX_CONN=$(echo "$MYSQL_METRICS" | awk '/^mysql_global_variables_max_connections / {print $2; found=1} END {if (!found) print 0}')
MYSQL_QUERIES=$(echo "$MYSQL_METRICS" | awk '/^mysql_global_status_queries / {print $2; found=1} END {if (!found) print 0}')
MYSQL_SLOW=$(echo "$MYSQL_METRICS" | awk '/^mysql_global_status_slow_queries / {print $2; found=1} END {if (!found) print 0}')
MYSQL_TABLE_LOCKS_WAITED=$(echo "$MYSQL_METRICS" | awk '/^mysql_global_status_table_locks_waited / {print $2; found=1} END {if (!found) print 0}')
APP_METRICS_PRESENT=0
NODE_METRICS_PRESENT=0
MYSQL_METRICS_PRESENT=0
[ -n "$APP_METRICS" ] && APP_METRICS_PRESENT=1
[ -n "$NODE_METRICS" ] && NODE_METRICS_PRESENT=1
[ -n "$MYSQL_METRICS" ] && MYSQL_METRICS_PRESENT=1
echo "health=$HEALTH app_metrics_present=$APP_METRICS_PRESENT node_metrics_present=$NODE_METRICS_PRESENT mysql_metrics_present=$MYSQL_METRICS_PRESENT mem_avail=$MEM_AVAIL mem_total=$MEM_TOTAL swap_free=$SWAP_FREE swap_total=$SWAP_TOTAL load=$LOAD load5=$LOAD5 load15=$LOAD15 disk_avail=$DISK_AVAIL disk_total=$DISK_TOTAL node_time=$NODE_TIME node_boot=$NODE_BOOT net_rx=$NET_RX net_tx=$NET_TX tomcat_busy=$TOMCAT_BUSY tomcat_max=$TOMCAT_MAX hikari_active=$HIKARI_ACTIVE hikari_max=$HIKARI_MAX jvm_heap_used=$JVM_HEAP_USED jvm_heap_max=$JVM_HEAP_MAX gc_pause_sum=$GC_PAUSE_SUM http_count=$HTTP_COUNT http_sum=$HTTP_SUM http_5xx_count=$HTTP_5XX_COUNT mysql_connected=$MYSQL_CONNECTED mysql_max_conn=$MYSQL_MAX_CONN mysql_queries=$MYSQL_QUERIES mysql_slow=$MYSQL_SLOW mysql_table_locks_waited=$MYSQL_TABLE_LOCKS_WAITED"
REMOTE_SCRIPT
) || {
    record_monitor_failure "resource_ssh" "resource SSH 수집" "EC2 SSH 또는 exporter curl 실패"
    handle_state_change "ssh" "SSH 연결" "CRITICAL" "FAIL" "SSH 연결 실패 — 리소스 체크 불가"
    return 1
  }

  record_monitor_success "resource_ssh" "resource SSH 수집"
  handle_state_change "ssh" "SSH 연결" "OK" "OK" ""

  # SSH 배너/MOTD 제거 — metrics 출력은 마지막 줄
  local metrics_line
  metrics_line=$(echo "$raw" | grep "^health=" | tail -1)
  log "Raw metrics: $metrics_line"

  if [ -z "$metrics_line" ]; then
    log "ERROR: Failed to parse metrics from SSH output"
    record_monitor_failure "resource_parse" "resource metric 파싱" "SSH 출력에서 health= metric line 없음"
    handle_state_change "resource_parse" "리소스 메트릭 파싱" "WARN" "FAIL" "리소스 메트릭 파싱 실패 — SSH 출력에서 데이터를 찾을 수 없음"
    return 1
  fi

  # 파싱
  local app_metrics_present node_metrics_present mysql_metrics_present
  local health mem_avail mem_total swap_free swap_total load load5 load15 disk_avail disk_total node_time node_boot net_rx net_tx
  local tomcat_busy tomcat_max hikari_active hikari_max jvm_heap_used jvm_heap_max gc_pause_sum
  local http_count http_sum http_5xx_count mysql_connected mysql_max_conn mysql_queries mysql_slow mysql_table_locks_waited
  health=$(echo "$metrics_line" | grep -oP 'health=\K[^ ]+' || echo "0")
  app_metrics_present=$(echo "$metrics_line" | grep -oP 'app_metrics_present=\K[^ ]+' || echo "0")
  node_metrics_present=$(echo "$metrics_line" | grep -oP 'node_metrics_present=\K[^ ]+' || echo "0")
  mysql_metrics_present=$(echo "$metrics_line" | grep -oP 'mysql_metrics_present=\K[^ ]+' || echo "0")
  mem_avail=$(echo "$metrics_line" | grep -oP 'mem_avail=\K[^ ]+' || echo "")
  mem_total=$(echo "$metrics_line" | grep -oP 'mem_total=\K[^ ]+' || echo "")
  swap_free=$(echo "$metrics_line" | grep -oP 'swap_free=\K[^ ]+' || echo "0")
  swap_total=$(echo "$metrics_line" | grep -oP 'swap_total=\K[^ ]+' || echo "0")
  load=$(echo "$metrics_line" | grep -oP 'load=\K[^ ]+' || echo "")
  load5=$(echo "$metrics_line" | grep -oP 'load5=\K[^ ]+' || echo "0")
  load15=$(echo "$metrics_line" | grep -oP 'load15=\K[^ ]+' || echo "0")
  disk_avail=$(echo "$metrics_line" | grep -oP 'disk_avail=\K[^ ]+' || echo "")
  disk_total=$(echo "$metrics_line" | grep -oP 'disk_total=\K[^ ]+' || echo "")
  node_time=$(echo "$metrics_line" | grep -oP 'node_time=\K[^ ]+' || echo "")
  node_boot=$(echo "$metrics_line" | grep -oP 'node_boot=\K[^ ]+' || echo "")
  net_rx=$(echo "$metrics_line" | grep -oP 'net_rx=\K[^ ]+' || echo "0")
  net_tx=$(echo "$metrics_line" | grep -oP 'net_tx=\K[^ ]+' || echo "0")
  tomcat_busy=$(echo "$metrics_line" | grep -oP 'tomcat_busy=\K[^ ]+' || echo "0")
  tomcat_max=$(echo "$metrics_line" | grep -oP 'tomcat_max=\K[^ ]+' || echo "0")
  hikari_active=$(echo "$metrics_line" | grep -oP 'hikari_active=\K[^ ]+' || echo "0")
  hikari_max=$(echo "$metrics_line" | grep -oP 'hikari_max=\K[^ ]+' || echo "0")
  jvm_heap_used=$(echo "$metrics_line" | grep -oP 'jvm_heap_used=\K[^ ]+' || echo "0")
  jvm_heap_max=$(echo "$metrics_line" | grep -oP 'jvm_heap_max=\K[^ ]+' || echo "0")
  gc_pause_sum=$(echo "$metrics_line" | grep -oP 'gc_pause_sum=\K[^ ]+' || echo "0")
  http_count=$(echo "$metrics_line" | grep -oP 'http_count=\K[^ ]+' || echo "")
  http_sum=$(echo "$metrics_line" | grep -oP 'http_sum=\K[^ ]+' || echo "")
  http_5xx_count=$(echo "$metrics_line" | grep -oP 'http_5xx_count=\K[^ ]+' || echo "")
  mysql_connected=$(echo "$metrics_line" | grep -oP 'mysql_connected=\K[^ ]+' || echo "0")
  mysql_max_conn=$(echo "$metrics_line" | grep -oP 'mysql_max_conn=\K[^ ]+' || echo "0")
  mysql_queries=$(echo "$metrics_line" | grep -oP 'mysql_queries=\K[^ ]+' || echo "")
  mysql_slow=$(echo "$metrics_line" | grep -oP 'mysql_slow=\K[^ ]+' || echo "")
  mysql_table_locks_waited=$(echo "$metrics_line" | grep -oP 'mysql_table_locks_waited=\K[^ ]+' || echo "0")

  local completeness_errors
  completeness_errors=""
  [ "$app_metrics_present" = "1" ] || completeness_errors="${completeness_errors} APP_METRICS"
  [ "$node_metrics_present" = "1" ] || completeness_errors="${completeness_errors} NODE_METRICS"
  [ "$mysql_metrics_present" = "1" ] || completeness_errors="${completeness_errors} MYSQL_METRICS"
  [ -n "$mem_avail" ] || completeness_errors="${completeness_errors} MEM_AVAIL"
  [ -n "$mem_total" ] || completeness_errors="${completeness_errors} MEM_TOTAL"
  [ -n "$disk_avail" ] || completeness_errors="${completeness_errors} DISK_AVAIL"
  [ -n "$disk_total" ] || completeness_errors="${completeness_errors} DISK_TOTAL"
  [ -n "$load" ] || completeness_errors="${completeness_errors} LOAD"
  [ -n "$node_time" ] || completeness_errors="${completeness_errors} NODE_TIME"
  [ -n "$node_boot" ] || completeness_errors="${completeness_errors} NODE_BOOT"
  [ -n "$http_count" ] || completeness_errors="${completeness_errors} HTTP_COUNT"
  [ -n "$http_sum" ] || completeness_errors="${completeness_errors} HTTP_SUM"
  [ -n "$mysql_queries" ] || completeness_errors="${completeness_errors} MYSQL_QUERIES"

  if ! awk -v value="$mem_total" 'BEGIN { exit !(value + 0 > 0) }'; then
    completeness_errors="${completeness_errors} MEM_TOTAL_NONPOSITIVE"
  fi
  if ! awk -v value="$disk_total" 'BEGIN { exit !(value + 0 > 0) }'; then
    completeness_errors="${completeness_errors} DISK_TOTAL_NONPOSITIVE"
  fi

  if [ -n "$completeness_errors" ]; then
    local detail
    detail="missing or invalid core metrics:${completeness_errors}"
    log "ERROR: Incomplete resource metrics (${detail})"
    record_monitor_failure "resource_parse" "resource metric completeness" "$detail"
    handle_state_change "resource_parse" "리소스 메트릭 파싱" "WARN" "FAIL" "리소스 메트릭 누락 — snapshot 갱신 중단 (${completeness_errors})"
    return 1
  fi

  record_monitor_success "resource_parse" "resource metric 파싱"
  handle_state_change "resource_parse" "리소스 메트릭 파싱" "OK" "OK" ""

  # Health 체크
  if [ "$health" = "0" ]; then
    handle_state_change "app_health" "Spring Boot Health" "CRITICAL" "DOWN" "Spring Boot Health DOWN"
  else
    handle_state_change "app_health" "Spring Boot Health" "OK" "HEALTHY" ""
  fi

  # Memory 체크 (awk로 소수점 계산)
  local mem_usage mem_status prev_mem_status mem_used_mb mem_total_mb swap_usage
  mem_usage=$(awk "BEGIN { if ($mem_total > 0) printf \"%.0f\", (1 - $mem_avail / $mem_total) * 100; else print 0 }")
  mem_used_mb=$(awk "BEGIN { if ($mem_total > 0) printf \"%.0f\", ($mem_total - $mem_avail) / 1000000; else print 0 }")
  mem_total_mb=$(awk "BEGIN { if ($mem_total > 0) printf \"%.0f\", $mem_total / 1000000; else print 0 }")
  swap_usage=$(awk "BEGIN { if ($swap_total > 0) printf \"%.0f\", (1 - $swap_free / $swap_total) * 100; else print 0 }")
  prev_mem_status=$(get_metric_state "memory")
  mem_status="OK"
  if [ "$mem_usage" -ge 95 ]; then
    mem_status="CRITICAL"
  elif [ "$mem_usage" -ge 80 ]; then
    mem_status="WARN"
  elif [ "$prev_mem_status" != "OK" ] && [ "$mem_usage" -ge 70 ]; then
    mem_status="$prev_mem_status"
  fi
  handle_state_change "memory" "메모리 사용률" "$mem_status" "${mem_usage}%" "메모리 사용률 ${mem_usage}% (${mem_status})"

  # Load 체크 (awk로 소수점 비교)
  local load_critical load_warn load_recovered load_status prev_load_status
  load_critical=$(awk "BEGIN { print ($load > 2.0) ? 1 : 0 }")
  load_warn=$(awk "BEGIN { print ($load > 1.0) ? 1 : 0 }")
  load_recovered=$(awk "BEGIN { print ($load < 0.8) ? 1 : 0 }")
  prev_load_status=$(get_metric_state "load")
  load_status="OK"
  if [ "$load_critical" = "1" ]; then
    load_status="CRITICAL"
  elif [ "$load_warn" = "1" ]; then
    load_status="WARN"
  elif [ "$prev_load_status" != "OK" ] && [ "$load_recovered" != "1" ]; then
    load_status="$prev_load_status"
  fi
  handle_state_change "load" "CPU Load" "$load_status" "$load" "CPU Load ${load} (${load_status})"

  # Disk 체크
  local disk_usage disk_status prev_disk_status disk_used_gb disk_total_gb
  disk_usage=$(awk "BEGIN { if ($disk_total > 0) printf \"%.0f\", (1 - $disk_avail / $disk_total) * 100; else print 0 }")
  disk_used_gb=$(awk "BEGIN { if ($disk_total > 0) printf \"%.1f\", ($disk_total - $disk_avail) / 1000000000; else print 0 }")
  disk_total_gb=$(awk "BEGIN { if ($disk_total > 0) printf \"%.1f\", $disk_total / 1000000000; else print 0 }")
  prev_disk_status=$(get_metric_state "disk")
  disk_status="OK"
  if [ "$disk_usage" -ge 90 ]; then
    disk_status="CRITICAL"
  elif [ "$disk_usage" -ge 80 ]; then
    disk_status="WARN"
  elif [ "$prev_disk_status" != "OK" ] && [ "$disk_usage" -ge 75 ]; then
    disk_status="$prev_disk_status"
  fi
  handle_state_change "disk" "디스크 사용률" "$disk_status" "${disk_usage}%" "디스크 사용률 ${disk_usage}% (${disk_status})"

  # Counter 기반 rate 계산: 첫 실행은 sample만 저장하고 다음 resource_check부터 계산된다.
  local now_ts http_rps http_count_delta http_count_status http_sum_rate http_sum_delta http_sum_status
  local http_5xx_rps http_5xx_delta http_5xx_status mysql_qps mysql_queries_delta mysql_queries_status mysql_slow_rate mysql_slow_delta mysql_slow_status
  local avg_response error_rate response_status error_rate_status collected_at_utc collected_at_kst app_health_text overall_severity overall_status
  local tomcat_usage hikari_usage jvm_heap_usage uptime_days net_rx_mb net_tx_mb snapshot_file
  now_ts=$(date +%s)
  collected_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')
  collected_at_kst=$(date -u -d '+9 hours' '+%Y-%m-%d %H:%M KST')

  read -r http_rps http_count_delta http_count_status <<< "$(counter_rate "http_requests_count" "$http_count" "$now_ts")"
  read -r http_sum_rate http_sum_delta http_sum_status <<< "$(counter_rate "http_requests_sum" "$http_sum" "$now_ts")"
  read -r http_5xx_rps http_5xx_delta http_5xx_status <<< "$(counter_rate "http_requests_5xx_count" "$http_5xx_count" "$now_ts")"
  read -r mysql_qps mysql_queries_delta mysql_queries_status <<< "$(counter_rate "mysql_queries" "$mysql_queries" "$now_ts")"
  read -r mysql_slow_rate mysql_slow_delta mysql_slow_status <<< "$(counter_rate "mysql_slow_queries" "$mysql_slow" "$now_ts")"

  if [ "$http_count_status" = "ok" ] && [ "$http_sum_status" = "ok" ]; then
    avg_response=$(awk "BEGIN { if ($http_count_delta > 0) printf \"%.4f\", $http_sum_delta / $http_count_delta; else print \"0.0000\" }")
  else
    avg_response="NA"
  fi

  if [ "$http_count_status" = "ok" ] && [ "$http_5xx_status" = "ok" ]; then
    error_rate=$(awk "BEGIN { if ($http_count_delta > 0) printf \"%.2f\", ($http_5xx_delta / $http_count_delta) * 100; else print \"0.00\" }")
  else
    error_rate="NA"
  fi

  response_status="OK"
  if [ "$avg_response" != "NA" ]; then
    response_status=$(awk "BEGIN {
      v = $avg_response;
      if (v > 3.0) print \"CRITICAL\";
      else if (v > 1.0) print \"WARN\";
      else print \"OK\";
    }")
  fi
  handle_state_change "avg_response" "평균 응답시간" "$response_status" "${avg_response}s" "평균 응답시간 ${avg_response}s (${response_status})"

  error_rate_status="OK"
  if [ "$error_rate" != "NA" ]; then
    error_rate_status=$(awk "BEGIN {
      v = $error_rate;
      if (v > 5.0) print \"CRITICAL\";
      else if (v > 1.0) print \"WARN\";
      else print \"OK\";
    }")
  fi
  handle_state_change "error_rate" "HTTP 에러율" "$error_rate_status" "${error_rate}%" "HTTP 에러율 ${error_rate}% (${error_rate_status})"

  app_health_text="HEALTHY"
  [ "$health" = "0" ] && app_health_text="DOWN"
  overall_severity="INFO"
  overall_status="HEALTHY"
  if [ "$app_health_text" = "DOWN" ] || [ "$mem_status" = "CRITICAL" ] || [ "$load_status" = "CRITICAL" ] || [ "$disk_status" = "CRITICAL" ] || [ "$response_status" = "CRITICAL" ] || [ "$error_rate_status" = "CRITICAL" ]; then
    overall_severity="CRITICAL"
    overall_status="CRITICAL"
  elif [ "$mem_status" = "WARN" ] || [ "$load_status" = "WARN" ] || [ "$disk_status" = "WARN" ] || [ "$response_status" = "WARN" ] || [ "$error_rate_status" = "WARN" ]; then
    overall_severity="WARN"
    overall_status="DEGRADED"
  fi

  tomcat_usage=$(awk "BEGIN { if ($tomcat_max > 0) printf \"%.1f\", ($tomcat_busy / $tomcat_max) * 100; else print 0 }")
  hikari_usage=$(awk "BEGIN { if ($hikari_max > 0) printf \"%.1f\", ($hikari_active / $hikari_max) * 100; else print 0 }")
  jvm_heap_usage=$(awk "BEGIN { if ($jvm_heap_max > 0) printf \"%.1f\", ($jvm_heap_used / $jvm_heap_max) * 100; else print 0 }")
  uptime_days=$(awk "BEGIN { if ($node_time > $node_boot && $node_boot > 0) printf \"%.1f\", ($node_time - $node_boot) / 86400; else print 0 }")
  net_rx_mb=$(awk "BEGIN { printf \"%.1f\", $net_rx / 1000000 }")
  net_tx_mb=$(awk "BEGIN { printf \"%.1f\", $net_tx / 1000000 }")

  snapshot_file="${ALERT_STATE_DIR}/status-current.env"
  if ! cat > "$snapshot_file" <<EOF
collected_at_epoch="$now_ts"
collected_at_utc="$collected_at_utc"
collected_at_kst="$collected_at_kst"
snapshot_interval_min="$SNAPSHOT_INTERVAL_MIN"
data_source="health-check snapshot"
overall_severity="$overall_severity"
overall_status="$overall_status"
health="$app_health_text"
memory_used_mb="$mem_used_mb"
memory_total_mb="$mem_total_mb"
memory_pct="$mem_usage"
swap_pct="$swap_usage"
disk_used_gb="$disk_used_gb"
disk_total_gb="$disk_total_gb"
disk_pct="$disk_usage"
load1="$load"
load5="$load5"
load15="$load15"
tomcat_busy="$tomcat_busy"
tomcat_max="$tomcat_max"
tomcat_pct="$tomcat_usage"
hikari_active="$hikari_active"
hikari_max="$hikari_max"
hikari_pct="$hikari_usage"
jvm_heap_used_bytes="$jvm_heap_used"
jvm_heap_max_bytes="$jvm_heap_max"
jvm_heap_pct="$jvm_heap_usage"
gc_pause_sum_sec="$gc_pause_sum"
mysql_connected="$mysql_connected"
mysql_max_connections="$mysql_max_conn"
mysql_queries_total="$mysql_queries"
mysql_slow_queries_total="$mysql_slow"
mysql_table_locks_waited_total="$mysql_table_locks_waited"
http_requests_total="$http_count"
http_rps="$http_rps"
avg_response_sec="$avg_response"
error_rate_pct="$error_rate"
avg_response_status="$response_status"
error_rate_status="$error_rate_status"
mysql_qps="$mysql_qps"
slow_queries_delta="$mysql_slow_delta"
rate_status_http="$http_count_status"
rate_status_sum="$http_sum_status"
rate_status_5xx="$http_5xx_status"
rate_status_mysql="$mysql_queries_status"
rate_status_slow="$mysql_slow_status"
uptime_days="$uptime_days"
network_rx_mb="$net_rx_mb"
network_tx_mb="$net_tx_mb"
EOF
  then
    record_monitor_failure "snapshot_write" "snapshot 갱신" "status-current.env 쓰기 실패"
    return 1
  fi

  if [ ! -s "$snapshot_file" ]; then
    record_monitor_failure "snapshot_write" "snapshot 갱신" "status-current.env 비어 있음"
    return 1
  fi

  record_snapshot_success "$snapshot_file" "$now_ts" "$collected_at_utc"

  log "Rate metrics — http_rps=${http_rps} avg_response=${avg_response}s error_rate=${error_rate}% mysql_qps=${mysql_qps} slow_delta=${mysql_slow_delta} statuses=http:${http_count_status},sum:${http_sum_status},5xx:${http_5xx_status},mysql:${mysql_queries_status},slow:${mysql_slow_status}"
  log "Snapshot updated: $snapshot_file collected_at=${collected_at_kst} status=${overall_status}"
  log "Resource check done — mem=${mem_usage}% load=${load} disk=${disk_usage}%"
  return 0
}

# --- 메인 루프 ---
main() {
  log "Starting health check loop (interval: ${CHECK_INTERVAL}s)"

  if [ -z "$WEBHOOK_URL" ]; then
    log "WARNING: DISCORD_WEBHOOK_URL is not set. Alerts will only be logged."
  fi

  while true; do
    # 매 10분: Health Check + Resource Snapshot
    health_check || true
    resource_check || true

    sleep "$CHECK_INTERVAL"
  done
}

main
