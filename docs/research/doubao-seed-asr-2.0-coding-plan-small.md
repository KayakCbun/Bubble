# Doubao Seed ASR 2.0 on Volcengine Small plans

Date: 2026-09-02

Question: if Bubble Record switched from on-device SpeechAnalyzer to `doubao-seed-asr-2.0`, how much audio would the Volcengine **Small** Agent/Coding Plan actually cover?

## Short answer

On **Agent Plan 个人版 Small** (¥40/month, 20,000 AFP), Seed ASR 2.0 is included. ASR is billed as **450 AFP per hour of audio**. That is about **44 hours/month**, with a **~22 hour/day** cap. Voice models do **not** have the 5-hour or weekly windows that coding calls have.

If the same Small plan is also used for coding, those 44 hours share the 20,000 AFP pool. Two hours of meetings per workday for a month roughly empties Small by itself.

Official pages:

- [套餐内 AFP 抵扣规则](https://www.volcengine.com/docs/82379/2516283) (the console doc linked in the question)
- [Agent Plan 个人版 套餐概览](https://www.volcengine.com/docs/82379/2366394)
- [超额后付费规则](https://www.volcengine.com/docs/82379/2516284)

## Which “Small” this is

The console groups **Agent Plan** and **Coding Plan** under one “Agent/Coding Plan” subscription. Two Small-shaped products exist:

| Product | Price | Meter | Seed ASR 2.0 |
| --- | --- | --- | --- |
| **Agent Plan 个人版 Small** | ¥40/month | 20,000 AFP / month | Yes |
| **Agent Plan 企业版 Team Small** | ¥120/month | 40,000 AFP / month | Yes |
| **Coding Plan Lite** (older coding-only SKU) | ¥40/month | ~18,000 *requests* | Not the AFP speech table; coding-tool quota |

The doc at `82379/2516283` is the **Agent Plan AFP** rulebook. `doubao-seed-asr-2.0` is listed as supported on personal Small. If the subscribed SKU is still the older **Coding Plan Lite** (request-count, programming tools only), do not assume ASR rides that quota — use Agent Plan Small, or Ark pay-as-you-go.

## Deduction rule

From the AFP rules page:

```
doubao-seed-asr-2.0 AFP = audio_hours × 450
```

TTS on the same page is `characters / 10,000 × 1350` (example: 2,000 characters → 270 AFP). ASR is duration, not tokens.

Pay-as-you-go if the plan is exhausted and overage is enabled: **¥1 / hour** for `doubao-seed-asr-2.0`. The separate speech-console file ASR 2.0 list price is ¥0.8/hour; streaming ASR 2.0 is ¥1/hour. The Ark plan overage line is the ¥1/hour figure.

## Small quota if spent only on ASR

Personal Small (the ¥40 “Small”):

| Window | AFP | ASR hours |
| --- | --- | --- |
| Month | 20,000 | **44.4 h** |
| Day (half of month; speech uses this + month, not 5h/week) | 10,000 | **22.2 h** |
| Week / 5-hour | 7,000 / 2,000 | **does not apply to speech** |

Team Small (¥120) is 2× that: 88.9 h/month, 44.4 h/day.

Speech has no 5-hour or weekly cap. Daily cap is half the monthly AFP. For one person recording meetings, **the month is the real limit**, not the day.

## What that means for Bubble Record

| Record length | AFP | Share of personal Small month |
| --- | --- | --- |
| 10 min | 75 | 0.4% |
| 30 min | 225 | 1.1% |
| 1 h | 450 | 2.3% |
| 2 h/workday × 22 days | 19,800 | **99%** |
| 8 h continuous | 3,600 | 18% |

A 1-hour meeting is cheap in yuan (~¥1 list, ~¥0.9 if you convert 450/20,000 of a ¥40 plan ≈ ¥0.90). It is **not** cheap relative to a Small coding budget: 450 AFP is hundreds of typical short text calls on `doubao-seed-2.0-lite` (AFP = `(in_tokens × in_coeff + out_tokens × out_coeff) / 10,000`; lite ≤32k is about `0.5×0.67` in / `0.5` out).

So:

- **ASR-only on Small**: comfortable for ~one hour of meetings a day, tight for a full calendar of 2-hour calls.
- **ASR + coding on the same Small**: a few long Records will crowd out coding. Split: keep Agent/Coding Small for text, buy speech hours (or enable ASR overage at ¥1/h) if Record becomes daily.
- **Live captions** (streaming) and **flush-on-stop** (file) both count duration. Silence still counts; the speech product bills accumulated audio time to the millisecond, then hours.

## Access notes for a Bubble integration

- Model id on Ark: `doubao-seed-asr-2.0`.
- Personal Small includes it; no extra endpoint purchase is required *if* the call goes through the Agent Plan key/base URL the same way other plan models do.
- TPM on Agent Plan is “enough for normal development”; the docs say very high TPM should use pay-as-you-go API instead. Live Record is one long stream, not a token flood — duration quota matters more than TPM.
- Overage: if enabled, speech switches to ¥1/h only after the **monthly** AFP is gone (not after a 5-hour window).

## Sources

- [套餐内 AFP 抵扣规则](https://www.volcengine.com/docs/82379/2516283) — formula `hours × 450`, TTS example
- [Agent Plan 个人版 套餐概览](https://www.volcengine.com/docs/82379/2366394) — Small ¥40, 20,000 AFP, speech listed, no 5h/week for voice
- [Team 套餐概览](https://www.volcengine.com/docs/82379/2374452) — Team Small ¥120, 40,000 AFP
- [超额后付费规则](https://www.volcengine.com/docs/82379/2516284) — ASR overage ¥1/hour; voice ignores 5h/week
- [LAS Seed-ASR 2.0 计费](https://www.volcengine.com/docs/6492/2165140) — file ASR 2.0 ¥0.8/hour on that product
