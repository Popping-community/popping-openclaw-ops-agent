FROM node:22-slim

# Install SSH client, curl, gh CLI
RUN apt-get update && \
    apt-get install -y --no-install-recommends openssh-client curl ca-certificates git && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# Install OpenClaw
RUN npm install -g openclaw@2026.4.15

# Copy workspaces and config
COPY workspace-ops/ /root/.openclaw/workspace/
COPY workspace-dba/ /root/.openclaw/workspace-dba/
COPY workspace-dev/ /root/.openclaw/workspace-dev/
COPY docs/ /root/.openclaw/docs/
COPY openclaw.json /root/.openclaw/openclaw.json

# Copy health check scripts
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 18789

CMD ["/entrypoint.sh"]
