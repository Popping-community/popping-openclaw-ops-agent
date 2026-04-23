#!/bin/bash
# daily-summary-scheduler.sh — trigger PoppingOps Daily Summary via OpenClaw Gateway HTTP API

STATE_DIR="/tmp/health-check-alerts"
STATE_FILE="${STATE_DIR}/daily-summary.state"
ATTEMPT_FILE="${STATE_DIR}/daily-summary.attempt"
CHECK_INTERVAL_SECONDS=300
MAX_ATTEMPTS_PER_DAY="${DAILY_SUMMARY_MAX_ATTEMPTS_PER_DAY:-3}"
TARGET_HOUR_KST="${DAILY_SUMMARY_HOUR_KST:-09}"
GATEWAY_PORT="${PORT:-18789}"
GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-http://127.0.0.1:${GATEWAY_PORT}}"
REPORT_WEBHOOK_URL="${DISCORD_DAILY_SUMMARY_WEBHOOK_URL:-${DISCORD_REPORT_WEBHOOK_URL:-${DISCORD_WEBHOOK_URL:-}}}"
RUNBOOK_RECOMMENDATIONS_FILE="${RUNBOOK_RECOMMENDATIONS_FILE:-/root/.openclaw/config/runbook-recommendations.json}"

mkdir -p "$STATE_DIR"

log() {
  echo "$(date -u '+%Y-%m-%dT%H:%M:%S+00:00') [daily-summary] $*"
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

already_sent_today() {
  local today="$1"
  [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE" 2>/dev/null)" = "$today" ]
}

attempts_today() {
  local today="$1"
  local attempt_day attempt_count

  if [ ! -f "$ATTEMPT_FILE" ]; then
    echo "0"
    return
  fi

  IFS='|' read -r attempt_day attempt_count < "$ATTEMPT_FILE"
  if [ "$attempt_day" = "$today" ]; then
    echo "${attempt_count:-0}"
  else
    echo "0"
  fi
}

record_attempt() {
  local today="$1"
  local count

  count=$(attempts_today "$today")
  count=$((count + 1))
  echo "${today}|${count}" > "$ATTEMPT_FILE"
  echo "$count"
}

write_request_payload() {
  local file="$1"
  local context_file="$2"

  node - "$context_file" "$RUNBOOK_RECOMMENDATIONS_FILE" > "$file" <<'NODE'
const fs = require("fs");
const contextPath = process.argv[2];
const recommendationsPath = process.argv[3];
const context = fs.readFileSync(contextPath, "utf8");
let recommendationData = {};
try {
  recommendationData = JSON.parse(fs.readFileSync(recommendationsPath, "utf8"));
} catch (_) {
  try {
    recommendationData = JSON.parse(fs.readFileSync("config/runbook-recommendations.json", "utf8"));
  } catch (_) {}
}
const runbookRecommendations = JSON.stringify(recommendationData && Object.keys(recommendationData).length ? recommendationData : {}, null, 2);
const targetSystem = Array.isArray(recommendationData.target_system_summary)
  ? recommendationData.target_system_summary.map((item) => `- ${item}`)
  : [
      "- Amazon Linux 2 single EC2",
      "- 1 vCPU, about 952 MiB memory",
      "- Docker Compose: Spring Boot app + MySQL",
      "- Nginx reverse proxy",
      "- Actuator/node-exporter/mysqld-exporter metrics"
    ];
const input = [
  "Daily Summary를 실행해줘.",
  "",
  "아래는 /scripts/heartbeat-context.sh daily-summary 의 출력이야.",
  "이 context를 우선 사용해서 workspace/HEARTBEAT.md 의 Daily Summary 형식으로 Discord에 올릴 최종 보고서만 작성해.",
  "",
  "규칙:",
  "- HEARTBEAT_OK를 반환하지 마.",
  "- 임의로 SSH raw metric을 다시 수집하지 말고 아래 context와 최신 snapshot을 우선해.",
  "- 측정시각, 데이터 상태, 트래픽 지표 기준을 포함해.",
  "- 오늘의 조치는 runbook을 우선하고, runbook에 직접 절차가 없으면 아래 Target system 요약과 현재 snapshot/realtime metric만 근거로 추론 기반 권장 조치를 제안해.",
  "- 없는 정보는 단정하지 말고 확인 항목으로 분리해. 상태 변경 작업은 운영자가 검토할 조치로만 제안해.",
  "- github_actions_available=true이면 CI/CD를 수집 제외라고 쓰지 말고 github_actions_runs_json을 요약해.",
  "- github_actions_available=false일 때만 github_actions_unavailable 값을 근거로 수집 제외/수집 실패를 명시해.",
  "- 데이터가 없으면 추측하지 말고 수집 제외/수집 실패를 명시해.",
  "",
  "- Recommendation actions must first match issues against Runbook recommendation data by `alert_key` and `severities`.",
  "- If a recommendation matches, summarize its `immediate_checks` and `operator_review_actions` and do not mix in target-system fallback speculation.",
  "- Use Target system + current context fallback only for issues with no matching recommendation.",
  "",
  "Runbook recommendation data:",
  runbookRecommendations,
  "",
  "Target system:",
  ...targetSystem,
  "",
  "Context:",
  context
].join("\n");

process.stdout.write(JSON.stringify({
  model: "openclaw:main",
  user: "poppingops-daily-summary",
  max_output_tokens: 2200,
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
    log "No daily summary webhook configured; skipping Discord delivery"
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
      "$REPORT_WEBHOOK_URL" >/dev/null 2>&1 || log "Discord daily summary send failed"
  done
}

trigger_daily_summary() {
  local token context_file payload_file response_file text_file http_code

  token="$(gateway_token)"
  if [ -z "$token" ]; then
    log "Gateway token unavailable; cannot call OpenClaw Gateway"
    return 1
  fi

  context_file="$(mktemp)"
  payload_file="$(mktemp)"
  response_file="$(mktemp)"
  text_file="$(mktemp)"

  /scripts/heartbeat-context.sh daily-summary > "$context_file"

  if grep -q '^github_actions_available="true"' "$context_file"; then
    log "Daily Summary context: GitHub Actions available"
  else
    log "Daily Summary context: GitHub Actions unavailable ($(grep '^github_actions_unavailable=' "$context_file" | tail -1 | cut -d= -f2- | tr -d '"'))"
  fi

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
    log "Gateway daily summary request failed (http=${http_code})"
    rm -f "$context_file" "$payload_file" "$response_file" "$text_file"
    return 1
  fi

  extract_response_text "$response_file" > "$text_file"

  if [ ! -s "$text_file" ]; then
    log "Gateway returned empty daily summary"
    rm -f "$context_file" "$payload_file" "$response_file" "$text_file"
    return 1
  fi

  send_discord_message "$text_file"
  rm -f "$context_file" "$payload_file" "$response_file" "$text_file"
}

log "Starting daily summary scheduler (target: ${TARGET_HOUR_KST}:00 KST, interval: ${CHECK_INTERVAL_SECONDS}s)"

while true; do
  today_kst="$(TZ=Asia/Seoul date '+%Y-%m-%d')"
  hour_kst="$(TZ=Asia/Seoul date '+%H')"
  minute_kst="$(TZ=Asia/Seoul date '+%M')"

  if [ $((10#$hour_kst)) -ge $((10#$TARGET_HOUR_KST)) ] && ! already_sent_today "$today_kst"; then
    attempt_count=$(attempts_today "$today_kst")
    if [ "$attempt_count" -ge "$MAX_ATTEMPTS_PER_DAY" ]; then
      log "Daily Summary skipped for ${today_kst} KST; max attempts reached (${attempt_count}/${MAX_ATTEMPTS_PER_DAY})"
      sleep "$CHECK_INTERVAL_SECONDS"
      continue
    fi

    attempt_count=$(record_attempt "$today_kst")
    log "Triggering Daily Summary for ${today_kst} KST (now ${hour_kst}:${minute_kst})"
    log "Daily Summary attempt ${attempt_count}/${MAX_ATTEMPTS_PER_DAY}"
    if trigger_daily_summary; then
      echo "$today_kst" > "$STATE_FILE"
      log "Daily Summary sent for ${today_kst} KST"
    else
      log "Daily Summary failed for ${today_kst} KST; will retry"
    fi
  fi

  sleep "$CHECK_INTERVAL_SECONDS"
done
