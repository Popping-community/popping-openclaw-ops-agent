#!/bin/bash

echo "=== PoppingOps Entrypoint ==="
echo "Checking environment variables..."

# Check required env vars
if [ -z "$DISCORD_TOKEN" ]; then
  echo "ERROR: DISCORD_TOKEN is not set"
fi
if [ -z "$FIREWORKS_API_KEY" ]; then
  echo "ERROR: FIREWORKS_API_KEY is not set"
fi
if [ -z "$SSH_PRIVATE_KEY" ]; then
  echo "ERROR: SSH_PRIVATE_KEY is not set"
fi
if [ -z "$DISCORD_DBA_TOKEN" ]; then
  echo "ERROR: DISCORD_DBA_TOKEN is not set"
fi
if [ -z "$DISCORD_DEV_TOKEN" ]; then
  echo "ERROR: DISCORD_DEV_TOKEN is not set"
fi
if [ -z "$DISCORD_WEBHOOK_URL" ]; then
  echo "WARNING: DISCORD_WEBHOOK_URL is not set — health-check alerts will only be logged"
fi
if [ -z "$GATEWAY_TOKEN" ]; then
  echo "ERROR: GATEWAY_TOKEN is not set"
  exit 1
fi

echo "Environment variables OK"

# --- SSH Key ---
echo "Setting up SSH key..."
mkdir -p /root/.ssh
echo "$SSH_PRIVATE_KEY" > /root/.ssh/ec2-key.pem
chmod 600 /root/.ssh/ec2-key.pem
ssh-keyscan -H -p 2222 52.79.56.222 >> /root/.ssh/known_hosts 2>/dev/null || true
echo "SSH key ready ($(wc -l < /root/.ssh/ec2-key.pem) lines)"

# --- SSH Test ---
echo "Testing SSH connection to EC2 (port 2222)..."
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p 2222 ec2-user@52.79.56.222 "echo SSH_OK" 2>&1
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

# --- Start Gateway ---
GATEWAY_PORT="${PORT:-18789}"
echo "Starting OpenClaw Gateway on port $GATEWAY_PORT..."
openclaw gateway --port "$GATEWAY_PORT" &
GATEWAY_PID=$!

# 어느 한쪽이 죽으면 컨테이너 종료
wait -n $GATEWAY_PID $HEALTH_CHECK_PID $DAILY_SUMMARY_PID $FULL_REPORT_PID 2>/dev/null
echo "Process exited, shutting down..."
kill $GATEWAY_PID $HEALTH_CHECK_PID $DAILY_SUMMARY_PID $FULL_REPORT_PID 2>/dev/null || true
wait
