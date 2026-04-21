#!/bin/bash
# full-report-scheduler.sh — trigger PoppingOps Full Report via OpenClaw Gateway only when helper says report=true

STATE_DIR="/tmp/health-check-alerts"
LAST_RUN_FILE="${STATE_DIR}/full-report-scheduler.state"
ATTEMPT_FILE="${STATE_DIR}/full-report.attempt"
CHECK_INTERVAL_SECONDS=300
FULL_REPORT_INTERVAL_SECONDS="${FULL_REPORT_INTERVAL_SECONDS:-21600}"
MAX_ATTEMPTS_PER_WINDOW="${FULL_REPORT_MAX_ATTEMPTS_PER_WINDOW:-3}"
GATEWAY_PORT="${PORT:-18789}"
GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-http://127.0.0.1:${GATEWAY_PORT}}"
REPORT_WEBHOOK_URL="${DISCORD_FULL_REPORT_WEBHOOK_URL:-${DISCORD_REPORT_WEBHOOK_URL:-${DISCORD_WEBHOOK_URL:-}}}"

mkdir -p "$STATE_DIR"

log() {
  echo "$(date -u '+%Y-%m-%dT%H:%M:%S+00:00') [full-report] $*"
}

gateway_token() {
  if [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
    printf '%s' "$OPENCLAW_GATEWAY_TOKEN"
    return
  fi

  if [ -n "${GATEWAY_TOKEN:-}" ]; then
    printf '%s' "$GATEWAY_TOKEN"
    return
  fi

  node -e 'try { const c=require("/root/.openclaw/openclaw.json"); process.stdout.write(c.gateway?.auth?.token || ""); } catch (_) {}' 2>/dev/null
}

last_run_epoch() {
  if [ -f "$LAST_RUN_FILE" ]; then
    cat "$LAST_RUN_FILE" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

should_check_now() {
  local now last
  now=$(date +%s)
  last=$(last_run_epoch)
  [ $((now - ${last:-0})) -ge "$FULL_REPORT_INTERVAL_SECONDS" ]
}

window_key() {
  local now
  now=$(date +%s)
  echo $((now / FULL_REPORT_INTERVAL_SECONDS))
}

attempts_in_window() {
  local current_window="$1"
  local attempt_window attempt_count

  if [ ! -f "$ATTEMPT_FILE" ]; then
    echo "0"
    return
  fi

  IFS='|' read -r attempt_window attempt_count < "$ATTEMPT_FILE"
  if [ "$attempt_window" = "$current_window" ]; then
    echo "${attempt_count:-0}"
  else
    echo "0"
  fi
}

record_attempt() {
  local current_window="$1"
  local count

  count=$(attempts_in_window "$current_window")
  count=$((count + 1))
  echo "${current_window}|${count}" > "$ATTEMPT_FILE"
  echo "$count"
}

kv_value() {
  local key="$1"
  local file="$2"
  grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}

write_request_payload() {
  local file="$1"
  local context_file="$2"

  node - "$context_file" > "$file" <<'NODE'
const fs = require("fs");
const contextPath = process.argv[2];
const context = fs.readFileSync(contextPath, "utf8");

const input = [
  "6시간 Full Report를 실행해줘.",
  "",
  "아래는 /scripts/heartbeat-context.sh full-report 의 출력이야.",
  "이 context를 우선 사용해서 workspace/HEARTBEAT.md 의 Full Report 형식으로 최종 보고서만 작성해.",
  "",
  "규칙:",
  "- HEARTBEAT_OK를 반환하지 마. 이 요청은 helper가 full_report_should_report=true일 때만 호출된다.",
  "- 임의로 SSH raw metric을 다시 수집하지 말고 helper output과 최신 snapshot을 우선해.",
  "- 측정시각, 데이터 상태, full_report_reason, 핵심 이슈, 권장 조치를 포함해.",
  "- 6시간 Full Report는 전체 metric table이 아니라 새 이슈/심각도 변화 중심으로 압축해.",
  "- 데이터가 없으면 추측하지 말고 수집 제외/수집 실패를 명시해.",
  "",
  "Context:",
  context
].join("\n");

process.stdout.write(JSON.stringify({
  model: "openclaw:main",
  user: "poppingops-full-report",
  max_output_tokens: 1800,
  input
}));
NODE
}

extract_response_text() {
  local response_file="$1"

  node - "$response_file" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
let raw = fs.readFileSync(path, "utf8");
let data;
try {
  data = JSON.parse(raw);
} catch (error) {
  process.stdout.write(raw.trim());
  process.exit(0);
}

const chunks = [];

function walk(value) {
  if (!value) return;
  if (typeof value === "string") {
    chunks.push(value);
    return;
  }
  if (Array.isArray(value)) {
    value.forEach(walk);
    return;
  }
  if (typeof value !== "object") return;

  if (typeof value.output_text === "string") chunks.push(value.output_text);
  if ((value.type === "output_text" || value.type === "text") && typeof value.text === "string") chunks.push(value.text);
  if (value.text && typeof value.text.value === "string") chunks.push(value.text.value);
  if (value.message && typeof value.message.content === "string") chunks.push(value.message.content);
  if (value.delta && typeof value.delta === "string") chunks.push(value.delta);

  walk(value.output);
  walk(value.content);
  walk(value.choices);
}

if (typeof data.output_text === "string") chunks.push(data.output_text);
walk(data.output);
walk(data.choices);

const seen = new Set();
const unique = chunks
  .map((chunk) => String(chunk).trim())
  .filter(Boolean)
  .filter((chunk) => {
    if (seen.has(chunk)) return false;
    seen.add(chunk);
    return true;
  });

process.stdout.write(unique.join("\n").trim());
NODE
}

send_discord_message() {
  local text_file="$1"

  if [ -z "$REPORT_WEBHOOK_URL" ]; then
    log "No full report webhook configured; skipping Discord delivery"
    return 1
  fi

  node - "$text_file" <<'NODE' | while IFS= read -r payload; do
const fs = require("fs");
const path = process.argv[2];
const text = fs.readFileSync(path, "utf8").trim();
const max = 1900;

if (!text) {
  process.exit(0);
}

for (let i = 0; i < text.length; i += max) {
  const chunk = text.slice(i, i + max);
  process.stdout.write(JSON.stringify({ content: chunk }) + "\n");
}
NODE
    curl -s -o /dev/null -w "%{http_code}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$REPORT_WEBHOOK_URL" >/dev/null 2>&1 || log "Discord full report send failed"
  done
}

trigger_full_report() {
  local context_file="$1"
  local token payload_file response_file text_file http_code

  token="$(gateway_token)"
  if [ -z "$token" ]; then
    log "Gateway token unavailable; cannot call OpenClaw Gateway"
    return 1
  fi

  payload_file="$(mktemp)"
  response_file="$(mktemp)"
  text_file="$(mktemp)"

  write_request_payload "$payload_file" "$context_file"

  http_code=$(curl -s -o "$response_file" -w "%{http_code}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "x-openclaw-agent-id: main" \
    -d @"$payload_file" \
    "${GATEWAY_URL}/v1/responses" 2>/dev/null)

  if [ "$?" -ne 0 ]; then
    http_code="000"
  fi

  if [ "$http_code" != "200" ]; then
    log "Gateway full report request failed (http=${http_code})"
    rm -f "$payload_file" "$response_file" "$text_file"
    return 1
  fi

  extract_response_text "$response_file" > "$text_file"

  if [ ! -s "$text_file" ]; then
    log "Gateway returned empty full report"
    rm -f "$payload_file" "$response_file" "$text_file"
    return 1
  fi

  send_discord_message "$text_file"
  rm -f "$payload_file" "$response_file" "$text_file"
}

run_full_report_check() {
  local context_file should_report reason current_window attempt_count

  context_file="$(mktemp)"
  /scripts/heartbeat-context.sh full-report > "$context_file"

  should_report="$(kv_value "full_report_should_report" "$context_file")"
  reason="$(kv_value "full_report_reason" "$context_file")"

  if [ "$should_report" != "true" ]; then
    log "Full Report skipped: should_report=${should_report:-unknown} reason=${reason:-unknown}"
    date +%s > "$LAST_RUN_FILE"
    rm -f "$context_file"
    return 0
  fi

  current_window="$(window_key)"
  attempt_count="$(attempts_in_window "$current_window")"
  if [ "$attempt_count" -ge "$MAX_ATTEMPTS_PER_WINDOW" ]; then
    log "Full Report skipped: max attempts reached (${attempt_count}/${MAX_ATTEMPTS_PER_WINDOW}) reason=${reason:-unknown}"
    rm -f "$context_file"
    return 1
  fi

  attempt_count="$(record_attempt "$current_window")"
  log "Triggering Full Report: reason=${reason:-unknown}"
  log "Full Report attempt ${attempt_count}/${MAX_ATTEMPTS_PER_WINDOW}"

  if trigger_full_report "$context_file"; then
    date +%s > "$LAST_RUN_FILE"
    log "Full Report sent"
    rm -f "$context_file"
    return 0
  fi

  log "Full Report failed; will retry"
  rm -f "$context_file"
  return 1
}

log "Starting full report scheduler (interval: ${FULL_REPORT_INTERVAL_SECONDS}s, check interval: ${CHECK_INTERVAL_SECONDS}s)"

while true; do
  if should_check_now; then
    run_full_report_check || true
  fi

  sleep "$CHECK_INTERVAL_SECONDS"
done
