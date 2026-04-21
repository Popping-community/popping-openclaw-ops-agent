---
name: cicd-analyzer
description: "Analyze GitHub Actions CI/CD pipeline failures, build errors, and deployment issues for the Popping Community repo."
metadata:
  {
    "openclaw":
      {
        "emoji": "🔧",
        "requires": { "bins": ["gh"] },
        "install": [],
      },
  }
---

# CI/CD Analyzer Skill

Analyze GitHub Actions workflow runs for the Popping Community server repository.

## Trigger Phrases

- "CI 실패 확인해줘", "빌드 실패 원인"
- "배포 상태 확인", "워크플로우 확인"
- "github actions", "CI/CD"

## Repository

`Popping-community/popping-server`

## Check Recent Workflow Runs

```bash
gh run list --repo Popping-community/popping-server --limit 10
```

## Check Failed Runs

```bash
gh run list --repo Popping-community/popping-server --status failure --limit 5
```

## View Specific Run Logs

```bash
# Get run details
gh run view <run-id> --repo Popping-community/popping-server

# Get failed job logs
gh run view <run-id> --repo Popping-community/popping-server --log-failed
```

## Check Latest Run Status

```bash
gh run list --repo Popping-community/popping-server --limit 1 --json status,conclusion,name,createdAt,headBranch
```

## View Workflow File

```bash
gh api repos/Popping-community/popping-server/contents/.github/workflows/build.yml --jq '.content' | base64 -d
```

## Analysis Format

```
🔧 [WARN] CI/CD Failure Detected
- Workflow: Build & Deploy
- Branch: main
- Failed step: Gradle Build
- Error: Test failure in CommentServiceTest.java:45
- Suggestion: Check recent changes to CommentService
```

## Common Failure Patterns

1. **Test failures** — Check test output, identify failing assertions
2. **Build failures** — Dependency issues, compilation errors
3. **Docker push failures** — Registry auth, image size limits
4. **Deploy failures** — SSH connection to EC2, docker-compose issues
5. **SonarCloud failures** — Quality gate not met, coverage threshold

## Analysis Checklist

1. Identify which step failed
2. Extract error message from logs
3. Check if failure is flaky (compare with previous runs)
4. Identify related code changes (`gh pr list --state merged --limit 5`)
5. Suggest fix or investigation direction
