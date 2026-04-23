#!/bin/bash
# Deterministic context builder for OpenClaw heartbeat reports.
# Usage: /scripts/heartbeat-context.sh full-report|daily-summary

MODE="${1:-full-report}"
STATE_DIR="/tmp/health-check-alerts"
SNAPSHOT_FILE="${STATE_DIR}/status-current.env"
FULL_REPORT_STATE_FILE="${STATE_DIR}/full-report.state"
LAST_SUCCESS_FILE="${STATE_DIR}/last_success.state"
REPO="Popping-community/popping-server"
SNAPSHOT_STALE_WARN_MIN="${SNAPSHOT_STALE_WARN_MIN:-20}"
SNAPSHOT_STALE_CRITICAL_MIN="${SNAPSHOT_STALE_CRITICAL_MIN:-30}"
RUNBOOK_RECOMMENDATIONS_FILE="${RUNBOOK_RECOMMENDATIONS_FILE:-/root/.openclaw/config/runbook-recommendations.json}"

mkdir -p "$STATE_DIR"

print_kv() {
  printf '%s="%s"\n' "$1" "$2"
}

read_snapshot() {
  if [ ! -f "$SNAPSHOT_FILE" ]; then
    print_kv "snapshot_unavailable" "true"
    print_kv "snapshot_freshness_status" "CRITICAL"
    print_kv "snapshot_freshness_label" "수집 중단 가능성"
    print_kv "snapshot_age_min" "NA"
    return 1
  fi

  cat "$SNAPSHOT_FILE"

  local collected_at_epoch now_epoch snapshot_age_min
  collected_at_epoch=$(grep '^collected_at_epoch=' "$SNAPSHOT_FILE" | cut -d= -f2 | tr -d '"')
  now_epoch=$(date +%s)

  if [ -n "$collected_at_epoch" ]; then
    snapshot_age_min=$(( (now_epoch - collected_at_epoch) / 60 ))
    print_kv "snapshot_age_min" "$snapshot_age_min"
    if [ "$snapshot_age_min" -ge "$SNAPSHOT_STALE_CRITICAL_MIN" ]; then
      print_kv "snapshot_freshness_status" "CRITICAL"
      print_kv "snapshot_freshness_label" "수집 중단 가능성"
    elif [ "$snapshot_age_min" -ge "$SNAPSHOT_STALE_WARN_MIN" ]; then
      print_kv "snapshot_freshness_status" "WARN"
      print_kv "snapshot_freshness_label" "오래됨"
    else
      print_kv "snapshot_freshness_status" "OK"
      print_kv "snapshot_freshness_label" "최신"
    fi
  else
    print_kv "snapshot_freshness_status" "WARN"
    print_kv "snapshot_freshness_label" "측정시각 누락"
    print_kv "snapshot_age_min" "NA"
  fi
}

metric_bucket() {
  local value="$1"
  local warn="$2"
  local critical="$3"
  awk "BEGIN {
    v = ${value:-0};
    if (v >= $critical) print \"CRITICAL\";
    else if (v >= $warn) print \"WARN\";
    else print \"OK\";
  }"
}

load_bucket() {
  local value="$1"
  awk "BEGIN {
    v = ${value:-0};
    if (v > 2.0) print \"CRITICAL\";
    else if (v > 1.0) print \"WARN\";
    else print \"OK\";
  }"
}

ci_context() {
  if ! command -v gh >/dev/null 2>&1; then
    print_kv "github_actions_available" "false"
    print_kv "github_actions_unavailable" "gh_not_installed"
    print_kv "github_actions_fingerprint" "gh_not_installed"
    return
  fi

  local runs latest_status error_file error_message
  error_file="$(mktemp)"

  runs=$(gh run list --repo "$REPO" --limit 3 --json status,conclusion,name,createdAt,headBranch 2>"$error_file")
  if [ "$?" -eq 0 ] && [ -n "$runs" ]; then
    latest_status=$(gh run list --repo "$REPO" --limit 1 --json status,conclusion --jq '.[0] | "\(.status):\(.conclusion)"' 2>/dev/null)
    print_kv "github_actions_available" "true"
    printf 'github_actions_runs_json=%s\n' "$runs"
    print_kv "github_actions_fingerprint" "${latest_status:-unknown}"
    rm -f "$error_file"
    return
  fi

  error_message=$(tr '\n' ' ' < "$error_file" | sed 's/"/'\''/g' | cut -c1-180)
  rm -f "$error_file"

  print_kv "github_actions_available" "false"
  print_kv "github_actions_unavailable" "${error_message:-gh_run_list_failed}"
  print_kv "github_actions_fingerprint" "unavailable"
}

runbook_recommendation_context() {
  node - "$SNAPSHOT_FILE" "$RUNBOOK_RECOMMENDATIONS_FILE" <<'NODE'
const fs = require("fs");
const path = require("path");
const [, , snapshotPath, recommendationsPath] = process.argv;

function readEnv(filePath) {
  const values = {};
  try {
    for (const line of fs.readFileSync(filePath, "utf8").split(/\r?\n/)) {
      const match = line.match(/^([A-Za-z0-9_]+)="?(.*?)"?$/);
      if (match) values[match[1]] = match[2];
    }
  } catch (_) {}
  return values;
}

function readJson(filePath) {
  const candidates = [
    filePath,
    path.resolve(process.cwd(), "config/runbook-recommendations.json"),
    "/root/.openclaw/config/runbook-recommendations.json"
  ].filter(Boolean);

  for (const candidate of candidates) {
    try {
      return JSON.parse(fs.readFileSync(candidate, "utf8"));
    } catch (_) {}
  }
  return {};
}

function metricBucket(value, warn, critical) {
  const number = Number(value);
  if (!Number.isFinite(number)) return "OK";
  if (number >= critical) return "CRITICAL";
  if (number >= warn) return "WARN";
  return "OK";
}

const snapshot = readEnv(snapshotPath);
const data = readJson(recommendationsPath);
const recommendations = Array.isArray(data.recommendations) ? data.recommendations : [];
const candidates = [
  { alert_key: "memory", severity: metricBucket(snapshot.memory_pct, 80, 95) },
  { alert_key: "app_health", severity: snapshot.health === "DOWN" ? "CRITICAL" : "OK" },
  { alert_key: "avg_response", severity: snapshot.avg_response_status || "OK" },
  { alert_key: "error_rate", severity: snapshot.error_rate_status || "OK" }
].filter((item) => item.severity === "WARN" || item.severity === "CRITICAL");

const matches = [];
for (const candidate of candidates) {
  const match = recommendations.find((item) => {
    return item
      && item.alert_key === candidate.alert_key
      && Array.isArray(item.severities)
      && item.severities.map((entry) => String(entry).toUpperCase()).includes(candidate.severity);
  });
  if (match) matches.push({ alert_key: candidate.alert_key, severity: candidate.severity, recommendation: match });
}

process.stdout.write(`runbook_active_recommendations_json=${JSON.stringify(matches)}\n`);
NODE
}

monitor_context() {
  if [ -f "$LAST_SUCCESS_FILE" ]; then
    local last_success_epoch last_success_utc last_success_file now age_min
    IFS='|' read -r last_success_epoch last_success_utc last_success_file < "$LAST_SUCCESS_FILE"
    now=$(date +%s)
    age_min=$(( (now - ${last_success_epoch:-0}) / 60 ))
    print_kv "monitor_last_success_epoch" "$last_success_epoch"
    print_kv "monitor_last_success_utc" "$last_success_utc"
    print_kv "monitor_last_success_age_min" "$age_min"
    print_kv "monitor_last_success_file" "$last_success_file"
  else
    print_kv "monitor_last_success_epoch" "NA"
    print_kv "monitor_last_success_age_min" "NA"
  fi
}

build_full_report_decision() {
  local overall_status health memory_pct disk_pct load1 response_status error_rate_status freshness ci_fingerprint
  overall_status=$(grep '^overall_status=' "$SNAPSHOT_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
  health=$(grep '^health=' "$SNAPSHOT_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
  memory_pct=$(grep '^memory_pct=' "$SNAPSHOT_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "0")
  disk_pct=$(grep '^disk_pct=' "$SNAPSHOT_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "0")
  load1=$(grep '^load1=' "$SNAPSHOT_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "0")
  response_status=$(grep '^avg_response_status=' "$SNAPSHOT_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "OK")
  error_rate_status=$(grep '^error_rate_status=' "$SNAPSHOT_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "OK")
  freshness=$(grep '^snapshot_freshness_status=' "$STATE_DIR/heartbeat-context.tmp" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "CRITICAL")
  ci_fingerprint=$(grep '^github_actions_fingerprint=' "$STATE_DIR/heartbeat-context.tmp" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unavailable")

  local memory_bucket disk_bucket load_bucket_value fingerprint previous_fingerprint
  memory_bucket=$(metric_bucket "$memory_pct" 80 95)
  disk_bucket=$(metric_bucket "$disk_pct" 80 90)
  load_bucket_value=$(load_bucket "$load1")

  fingerprint="overall=${overall_status:-UNKNOWN}|health=${health:-UNKNOWN}|mem=${memory_bucket}|disk=${disk_bucket}|load=${load_bucket_value}|response=${response_status}|error_rate=${error_rate_status}|freshness=${freshness}|ci=${ci_fingerprint}"
  previous_fingerprint=$(cat "$FULL_REPORT_STATE_FILE" 2>/dev/null || true)

  print_kv "full_report_fingerprint" "$fingerprint"
  print_kv "full_report_previous_fingerprint" "$previous_fingerprint"

  if [ ! -f "$SNAPSHOT_FILE" ]; then
    print_kv "full_report_should_report" "true"
    print_kv "full_report_reason" "snapshot_unavailable"
  elif [ "$freshness" = "CRITICAL" ]; then
    print_kv "full_report_should_report" "true"
    print_kv "full_report_reason" "snapshot_stale_critical"
  elif [ "$overall_status" = "CRITICAL" ]; then
    print_kv "full_report_should_report" "true"
    print_kv "full_report_reason" "server_critical"
  elif [ "$freshness" = "WARN" ]; then
    print_kv "full_report_should_report" "true"
    print_kv "full_report_reason" "snapshot_stale_warn"
  elif [ "$fingerprint" != "$previous_fingerprint" ]; then
    print_kv "full_report_should_report" "true"
    print_kv "full_report_reason" "new_or_changed_issue"
  else
    print_kv "full_report_should_report" "false"
    print_kv "full_report_reason" "unchanged"
  fi

  printf '%s' "$fingerprint" > "$FULL_REPORT_STATE_FILE"
}

TMP_CONTEXT="${STATE_DIR}/heartbeat-context.tmp"
: > "$TMP_CONTEXT"

{
  print_kv "heartbeat_mode" "$MODE"
  print_kv "heartbeat_context_collected_at_utc" "$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')"
  read_snapshot
  monitor_context
  ci_context
  runbook_recommendation_context
} | tee "$TMP_CONTEXT"

if [ "$MODE" = "full-report" ]; then
  build_full_report_decision
elif [ "$MODE" = "daily-summary" ]; then
  print_kv "daily_summary_should_report" "true"
else
  print_kv "heartbeat_context_error" "unknown_mode"
fi
