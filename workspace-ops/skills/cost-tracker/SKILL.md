---
name: cost-tracker
description: "Track and report LLM API usage costs. Estimates daily/monthly spending based on Fireworks API pricing for DeepSeek V3.2."
metadata:
  {
    "openclaw":
      {
        "emoji": "💰",
        "requires": { "bins": ["curl"] },
        "install": [],
      },
  }
---

# Cost Tracker Skill

Monitor and report LLM API usage costs for the PoppingOps bot.

## Trigger Phrases

- "비용 확인해줘", "사용량 확인해줘", "토큰 사용량"
- "cost", "usage", "billing"
- "이번 달 얼마 썼어?"

## Pricing (DeepSeek V3.2 via Fireworks)

| Type | Price |
|------|-------|
| Input (uncached) | $0.56 / 1M tokens |
| Input (cached) | $0.28 / 1M tokens |
| Output | $1.68 / 1M tokens |

## Fireworks 사용량 확인

Fireworks `/v1/usage` API는 존재하지 않는다. 실제 사용량은 **Fireworks 웹 대시보드**(fireworks.ai/account/billing)에서만 확인 가능하다.
봇이 보고하는 수치는 아래 추정 공식 기반이며, 반드시 "추정치"임을 명시해야 한다.

## Estimation Formula

### 현재 구조 (외부 bash snapshot 분리 후)

30분마다 실행되는 health/resource snapshot은 `/scripts/health-check.sh`가 OpenClaw 외부에서 실행한다.
**정기 체크, 임계값 판단, Webhook 알림, 복구 알림은 LLM을 사용하지 않으므로 토큰 비용이 0이다.**

LLM을 사용하는 것은 아래 항목뿐:

Per interaction estimate:
- 6hr Full Report: ~3,000 input + ~1,500 output = ~4,500 tokens ≈ $0.0042 (≈ 6원)
- Daily 9AM Summary: ~3,000 input + ~2,000 output = ~5,000 tokens ≈ $0.0050 (≈ 7원)
- Snapshot server status query: ~2,000 input + ~1,000 output = ~3,000 tokens ≈ $0.0028 (≈ 4원)
- Realtime server status query: ~3,000 input + ~2,000 output = ~5,000 tokens ≈ $0.0045 (≈ 6.5원)
- User query (simple): ~2,000 input + ~1,000 output = ~3,000 tokens ≈ $0.0028 (≈ 4원)
- User query (detailed report): ~3,000 input + ~2,000 output = ~5,000 tokens ≈ $0.0045 (≈ 6.5원)

### Daily Cost Estimate

```
LLM Heartbeat (OpenClaw):
- 6hr Full Report: 4 calls × $0.0042 = $0.017
- Daily 9AM Summary: 1 call × $0.0050 = $0.005
Heartbeat subtotal: ~$0.022/day (≈ 31원/일)

Bash Heartbeat (외부 스크립트, LLM 미사용):
- 30min Health Check: 48회/일 → 토큰 비용 $0
- 30min Resource Snapshot: 48회/일 → 토큰 비용 $0
- Webhook Alert/Recovery: 상태 변경 시 → 토큰 비용 $0

User queries (estimated 5-10/day):
- 10 queries × $0.004 = $0.04/day (≈ 55원/일)

Total estimated: ~$0.06/day (≈ 86원/일)
Monthly estimated: ~$1.8/month (≈ 2,600원/월)
```

**주의:** 이 수치는 추정치이다. 실제 비용은 Fireworks 대시보드에서 확인할 것.

## Report Format

```
💰 [INFO] LLM 비용 리포트

▸ 모델: DeepSeek V3.2 (Fireworks)
▸ 가격: 입력 $0.56/1M | 출력 $1.68/1M

▸ 오늘 예상 비용
  - Heartbeat 호출: {count}회 ≈ ${amount} (≈ {krw}원)
  - 사용자 쿼리: {count}회 ≈ ${amount} (≈ {krw}원)
  - 합계: ≈ ${total} (≈ {krw}원)

▸ 이번 달 예상
  - 일 평균: ≈ ${daily_avg}
  - 월 예상: ≈ ${monthly} (≈ {krw}원)

▸ 절약 팁
  - 현재 Heartbeat 주기가 적정한지 확인
  - 불필요한 반복 조회가 있는지 확인
```

## Cost Optimization Tips

Report these when costs exceed expectations:
1. 30분 자동 체크와 Webhook 알림은 이미 외부 bash로 분리됨 (토큰 0) — 추가 절감 여지 적음
2. 긴 메트릭 출력을 grep으로 필터링해서 입력 토큰 절감
3. 실제 비용 확인은 Fireworks 대시보드에서 할 것을 안내
