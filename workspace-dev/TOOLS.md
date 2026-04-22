# TOOLS.md - PoppingDev Environment

## Architecture

```
GitHub Actions → Gradle Build + SonarCloud → Jib Docker Push → SSH Deploy → EC2
```

## Repository

`Popping-community/popping-server`

## Key Commands

```bash
# Recent workflow runs
gh run list --repo Popping-community/popping-server --limit 10

# Failed runs
gh run list --repo Popping-community/popping-server --status failure --limit 5

# View specific run
gh run view <run-id> --repo Popping-community/popping-server

# Failed job logs
gh run view <run-id> --repo Popping-community/popping-server --log-failed

# Recent merged PRs
gh pr list --repo Popping-community/popping-server --state merged --limit 5
```

## Application Logs (EC2)

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p "$EC2_SSH_PORT" "${EC2_SSH_USER}@${EC2_HOST}" "docker logs popping-community --tail 100"
```
