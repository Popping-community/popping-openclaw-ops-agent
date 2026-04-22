#!/bin/bash

echo "=== PoppingOps Entrypoint ==="
echo "Checking environment variables..."

EC2_HOST="${EC2_HOST:-52.79.56.222}"
EC2_SSH_PORT="${EC2_SSH_PORT:-2222}"
EC2_SSH_USER="${EC2_SSH_USER:-ec2-user}"
APP_ACTUATOR_PORT="${APP_ACTUATOR_PORT:-8081}"
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"
MYSQL_EXPORTER_PORT="${MYSQL_EXPORTER_PORT:-9104}"
export EC2_HOST EC2_SSH_PORT EC2_SSH_USER APP_ACTUATOR_PORT NODE_EXPORTER_PORT MYSQL_EXPORTER_PORT

wait_for_gateway() {
  local url="$1"
  local pid="$2"
  local timeout="${GATEWAY_READY_TIMEOUT_SECONDS:-120}"
  local elapsed=0
  local http_code

  echo "Waiting for OpenClaw Gateway readiness (${url}, timeout: ${timeout}s)..."
  while [ "$elapsed" -lt "$timeout" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "ERROR: OpenClaw Gateway exited before becoming ready"
      return 1
    fi

    http_code=$(curl -s -o /dev/null -w "%{http_code}" "${url}/" 2>/dev/null || true)
    http_code="${http_code:-000}"
    if [ "$http_code" != "000" ]; then
      echo "OpenClaw Gateway is ready (http=${http_code})"
      return 0
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  echo "ERROR: OpenClaw Gateway did not become ready within ${timeout}s"
  return 1
}

# Check required env vars before starting any background processes.
missing_required_env=0
require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "ERROR: ${name} is not set"
    missing_required_env=1
  fi
}

require_env "DISCORD_TOKEN"
require_env "FIREWORKS_API_KEY"
require_env "SSH_PRIVATE_KEY"
require_env "DISCORD_DBA_TOKEN"
require_env "DISCORD_DEV_TOKEN"
require_env "DISCORD_WEBHOOK_URL"
require_env "GATEWAY_TOKEN"

if [ "$missing_required_env" -ne 0 ]; then
  echo "Fatal: required environment variables are missing; refusing to start"
  exit 1
fi

echo "Environment variables OK"

# --- SSH Key ---
echo "Setting up SSH key..."
mkdir -p /root/.ssh
echo "$SSH_PRIVATE_KEY" > /root/.ssh/ec2-key.pem
chmod 600 /root/.ssh/ec2-key.pem
ssh-keyscan -H -p "$EC2_SSH_PORT" "$EC2_HOST" >> /root/.ssh/known_hosts 2>/dev/null || true
echo "SSH key ready ($(wc -l < /root/.ssh/ec2-key.pem) lines)"

# --- SSH Test ---
echo "Testing SSH connection to EC2 (${EC2_SSH_USER}@${EC2_HOST}:${EC2_SSH_PORT})..."
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$EC2_SSH_PORT" "${EC2_SSH_USER}@${EC2_HOST}" "echo SSH_OK" 2>&1
echo "SSH test done (exit code: $?)"

# --- Inject secrets into openclaw.json ---
echo "Injecting secrets into config..."
CONFIG="/root/.openclaw/openclaw.json"
sed -i "s|DISCORD_TOKEN_PLACEHOLDER|${DISCORD_TOKEN}|g" "$CONFIG"
sed -i "s|DISCORD_DBA_TOKEN_PLACEHOLDER|${DISCORD_DBA_TOKEN}|g" "$CONFIG"
sed -i "s|DISCORD_DEV_TOKEN_PLACEHOLDER|${DISCORD_DEV_TOKEN}|g" "$CONFIG"
sed -i "s|FIREWORKS_API_KEY_PLACEHOLDER|${FIREWORKS_API_KEY}|g" "$CONFIG"
sed -i "s|GATEWAY_TOKEN_PLACEHOLDER|${GATEWAY_TOKEN}|g" "$CONFIG"
echo "Config ready"

# --- GitHub CLI (optional) ---
if [ -n "$GH_TOKEN" ]; then
  echo "GH_TOKEN set; GitHub CLI will use environment token"
  if gh run list --repo Popping-community/popping-server --limit 1 >/dev/null 2>&1; then
    echo "GitHub CLI auth: OK (Actions read access)"
  else
    echo "WARNING: GitHub CLI Actions check failed"
    gh auth status || true
  fi
else
  echo "GH_TOKEN not set; GitHub Actions context disabled"
fi

# --- Register Multi-Agent ---
echo "Setting up multi-agent routing..."

# Add PoppingDBA agent (if not exists)
openclaw agents add dba \
  --workspace /root/.openclaw/workspace-dba \
  --model "fireworks/accounts/fireworks/models/deepseek-v3p2" \
  --non-interactive 2>/dev/null || true

# Add PoppingDev agent (if not exists)
openclaw agents add dev \
  --workspace /root/.openclaw/workspace-dev \
  --model "fireworks/accounts/fireworks/models/deepseek-v3p2" \
  --non-interactive 2>/dev/null || true

# Clear existing bindings first
openclaw agents unbind --agent main --bind "discord:main" 2>/dev/null || true
openclaw agents unbind --agent dba --bind "discord:dba" 2>/dev/null || true
openclaw agents unbind --agent dev --bind "discord:dev" 2>/dev/null || true

# Set up channel routing (each agent binds to its own Discord bot account)
# main (PoppingOps) = discord:main account → #monitoring and all other channels
openclaw agents bind --agent main --bind "discord:main" 2>/dev/null || true
# dba (PoppingDBA) = discord:dba account → #database channel
openclaw agents bind --agent dba --bind "discord:dba" 2>/dev/null || true
# dev (PoppingDev) = discord:dev account → #cicd channel
openclaw agents bind --agent dev --bind "discord:dev" 2>/dev/null || true

echo "Multi-agent routing configured"
openclaw agents list 2>/dev/null || true

# --- Start Health Check (background) ---
echo "Starting background health check..."
/scripts/health-check.sh &
HEALTH_CHECK_PID=$!
echo "Health check started (PID: $HEALTH_CHECK_PID)"

# --- Start Gateway ---
GATEWAY_PORT="${PORT:-18789}"
GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-http://127.0.0.1:${GATEWAY_PORT}}"
echo "Starting OpenClaw Gateway on port $GATEWAY_PORT..."
openclaw gateway --port "$GATEWAY_PORT" &
GATEWAY_PID=$!

if ! wait_for_gateway "$GATEWAY_URL" "$GATEWAY_PID"; then
  echo "Gateway readiness failed, shutting down..."
  kill $GATEWAY_PID $HEALTH_CHECK_PID 2>/dev/null || true
  wait
  exit 1
fi

# --- Start Daily Summary Scheduler (background) ---
echo "Starting daily summary scheduler..."
/scripts/daily-summary-scheduler.sh &
DAILY_SUMMARY_PID=$!
echo "Daily summary scheduler started (PID: $DAILY_SUMMARY_PID)"

# --- Start Full Report Scheduler (background) ---
echo "Starting full report scheduler..."
/scripts/full-report-scheduler.sh &
FULL_REPORT_PID=$!
echo "Full report scheduler started (PID: $FULL_REPORT_PID)"

# 어느 한쪽이 죽으면 컨테이너 종료
wait -n $GATEWAY_PID $HEALTH_CHECK_PID $DAILY_SUMMARY_PID $FULL_REPORT_PID 2>/dev/null
echo "Process exited, shutting down..."
kill $GATEWAY_PID $HEALTH_CHECK_PID $DAILY_SUMMARY_PID $FULL_REPORT_PID 2>/dev/null || true
wait
