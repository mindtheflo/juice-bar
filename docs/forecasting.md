# Global quota forecasting

Forecasts apply to the **enabled fleet**, never to an individual licence. Codex and Claude cannot substitute for one another. Account bars and numbers remain actual measurements, not simulated balances.

## 1. Measure demand without inventing activity

For quota kind \(k\), aggregate each account’s quota increments into a pooled rate:

\[
r_k(t_i)=\sum_a \frac{u_{a,k}(t_i)-u_{a,k}(t_{i-1})}{t_i-t_{i-1}}.
\]

Time is in hours; usage is in **percentage points of one licence’s quota**. Two equal-plan licences have 200 points, not 100. Every increment uses the actual provider-observation timestamps.

A valid interval requires fresh, advancing readings on every enabled account, the same quota cycle, nondecreasing usage, and at most 15 minutes between observations. Crossing a reset discards that interval instead of inventing either negative demand or an assumed 100-point spend. Duplicate cached reads provide no evidence. A completely blocked fleet censors demand, so its flat usage is not evidence of inactivity. Historical changes can include direct clients using the same subscriptions; the quota endpoint does not identify the caller.

Positive quota increments establish measured activity within that coverage. Providers that report whole percentages can remain flat between increments; the duration of positive five-minute intervals is not an estimate of how long the user worked. All-zero history still abstains, except for the learned inactive-weekend case below.

Only the current continuous fleet configuration is used. Disabled licences add neither demand nor capacity. Same-provider plans must be known and identical: percentages alone do not identify an exchange rate between different plans. Unknown/custom quota durations, stale readings and ambiguous availability cause abstention. A startup reading with missing plan/window metadata interrupts observation coverage, but does not erase prior evidence for the same enabled accounts; confirmed account, plan or limit changes still start a new fleet epoch. Saving an unchanged connection preserves history. Two fresh, advancing zero-usage readings measure zero demand even if an unused allowance reports a moving reset timestamp.

## 2. Two-timescale demand, with a local-time profile

The baseline uses at most the last 24 **comparable** observed hours, exponentially weighted with a six-hour half-life:

\[
b_k = \frac{\sum_i \Delta t_i 2^{-A_i/6}r_k(t_i)}{\sum_i \Delta t_i2^{-A_i/6}}.
\]

\(A_i\) is calendar age in comparable hours. Weekday age skips weekends; weekend age skips weekdays. This carries Friday into Monday without folding two inactive days into the weekday rate. Missing coverage never counts as observed time. At least six observed comparable hours are required, including 1.5 hours of coverage in the latest two hours and a valid observation within 15 minutes.

A fast estimate \(f_k\) uses the last two actual hours and a **30-minute** half-life. The local-hour profile uses up to 21 days, separating weekdays and weekends, normalized so older absolute activity does not replace the recent baseline. Sparse hourly estimates shrink toward that baseline; two observed hours of that local hour/day type give the profile full weight.

Before applying that profile to future hours, divide the baseline by the recency-weighted mean profile scale over the same observed intervals. This gives a daily amplitude \(a_k\) without counting the busy part of a workday twice. The expected recent rate \(e_k\) applies that amplitude and profile to the actual intervals used by the fast estimate. A normal afternoon therefore does not also become a burst.

For \(h\) hours into the future, the central prediction is:

\[
\hat r_k(h)=\max\{0,\; a_k s_k(\text{local hour, day type})+(f_k-e_k)2^{-h/6}\}.
\]

The burst adjustment applies only to the same day type. A sudden acceleration therefore influences the rest of today, without persisting through the entire week or automatically overruling an observed quiet weekend. Activity need not follow fixed office hours. Intervals are assigned to calendar periods by their midpoint, so Sunday’s final quiet interval is not mislabelled as Monday activity.

A fully observed, repeatedly inactive weekend may borrow the latest weekday amplitude while applying its learned zero-weekend profile; that also preserves a nonzero forecast when work resumes Monday. A previously unseen weekend is **bracketed between zero activity and continued work**, not presumed inactive.

## 3. Demand bounds, not invented probability

Hourly blocks prevent frequent polling from masquerading as independent evidence. The symmetric uncertainty scale is the largest of:

- 25% of the daily amplitude;
- half the observed hourly 90th–10th percentile rate spread;
- 25% of the fast/profile-expected disagreement.

The scale widens by \(1+0.1\sqrt{h/24}\) with forecast distance. Lower demand is clamped at zero. An unobserved change of day type has a zero lower bound and an upper bound covering continued current work.

These are **sensitivity bounds**. The percentile spread does not make this an empirically calibrated 80%, 90% or 95% prediction interval. No such accuracy percentage is shown. Real-world predictive coverage still needs prospective evaluation on collected observations.

## 4. Supply is a coupled renewal problem

An account has a vector of remaining balances \(q_{a,k}\), not independently transferable session and weekly pools. Its capacity for a global workload measured in rate-hours is

\[
c_a=\min_k \frac{q_{a,k}}{r_k},\qquad C=\sum_{a\text{ available}}c_a.
\]

A simulated workload of size \(x\) on account \(a\) consumes \(xr_k\) from **every** applicable limit. A licence with weekly room but no session room cannot rescue a different licence with session room but no weekly room. Cooldowns prevent allocation until they expire.

The simulator advances in steps no larger than five minutes, split exactly at known quota resets and cooldown ends. A reset restores that limit to 100 points; it does not refresh the other limit. An idle cycle starts on first simulated use and cannot bank repeated unused refills. Five-hour cycles can repeat many times before the weekly renewal. Forecast refills remain hypothetical; the measured UI does not grant quota until a fresh provider reading confirms it.

The horizon is at least 24 hours and extends through the latest currently reported weekly renewal (about one week). An idle weekly allowance with no reset timestamp gets a full-week horizon starting now, rather than silently truncating its forecast to one day. Two feasible allocations are checked: earliest-expiring capacity first, and proportional coupled-headroom allocation. A successful fluid allocation is a model-feasible schedule, not a guarantee of the proxy’s exact request routing, discrete request sizes, model mix or future provider policy.

### Why an orange prediction is stronger than a failed routing heuristic

A greedy allocation can fail even when another routing schedule succeeds. Orange therefore needs a separate necessary-condition violation. For each quota kind, construct an **optimistic** cumulative supply envelope:

\[
U_k(t)=\sum_a q_{a,k}(0)+100\sum_a N_{a,k}(t).
\]

\(N\) counts the earliest possible future renewals. This envelope even banks unused quota, so it is an upper bound on true supply. If cumulative demand in a scenario exceeds \(U_k(t)\) at any time, a shortage is unavoidable under that demand scenario regardless of allocation. A simulation failure without this certificate stays unclassified. Orange at full agreement means even the lower-bound demand has a shortage; muted orange means the central scenario has a shortage but lower-demand scenarios may not.

## 5. Colour decisions

Define pressure as the maximum cumulative demand divided by optimistic cumulative capacity, checked along the timeline, including immediately before renewal events.

The icon no longer hides every uncertain forecast behind grey. Its **hue** uses the central demand estimate. The five sensitivity scenarios interpolate from the lower bound to that estimate, then from that estimate to the upper bound. Clipping a negative lower tail at zero, or bracketing an unseen day type, must not move the center upward. This is a tentative estimate, not a promise that the whole band agrees.

| Colour | Requirement in the displayed scenario |
| --- | --- |
| **Blue** | Demand is feasible under both allocation policies and peak pressure stays below 50%. |
| **Green** | Demand is feasible under both policies, with peak pressure at least 50%. |
| **Orange** | Demand breaches the optimistic supply envelope before renewal capacity can cover it. |
| **Grey / neutral** | Missing evidence, unknown comparable capacities, ambiguous availability, or an unclassified central scenario. |
| **Red** | Actual measured exhaustion only; not a forecast. |

**Saturation** shows scenario agreement. Evaluate five sensitivity levels (0, 0.25, 0.5, 0.75, 1), with 0.5 anchored at central demand and each side interpolated separately, using both allocation policies at each level. The agreement score is the fraction classified in the same colour as the central scenario; unclassified scenarios do not count as agreement. Apply a saturation multiplier of `0.2 + 0.8 × agreement`, preserving hue, brightness and opacity. The tooltip describes tentative, mixed or strong agreement without claiming an accuracy percentage. This is an uncalibrated sensitivity score, **not** a probability that the prediction is right. Fully observed exhaustion stays fully red; unsupported or partial readings stay grey.

The diagnostic `pace` and `window_paces` fields retain the conservative whole-band decision. `prediction`, `window_predictions` and their `scenario_agreement` values describe the displayed estimate, even when `neutral_reason` is `uncertainty` for the whole band. Missing evidence still produces no prediction; six observed hours plus 1.5 recent hours remain required. `projected_points` reports central demand over the horizon, in percentage points of one plan, and `prediction_deficits` reports when that scenario exceeds each optimistic supply envelope. These are separate from `shortage_at`, which requires a deficit even at the lower bound. Hovering a provider heading shows its central forecast, any deficit date and projected weekly-plan use. If a conservative whole-band decision exists but the central routing heuristic cannot classify the scenario, that supported decision is retained.

In OpenAI + Claude mode, provider bar **height** shows pooled weekly capacity only: sum of weekly percentages remaining divided by the number of contributing enabled licences. Session limits do not reduce the fill. Provider bar **colours** still use the joint session/weekly forecast. Session/weekly icon bars use the corresponding joint-model constraint result; they never use spare Claude capacity to excuse a Codex bottleneck. All represented providers need a supported prediction before the combined bar takes a forecast colour. The combined saturation uses the weakest contributing agreement. Partial readings always remain neutral. Individual accounts remain measured levels only, with no invented pacing.

## Validation boundary

Deterministic tests cover all three forecast colours, abstention, accelerated use, quiet weekends, Friday-to-Monday continuity, repeating sessions, staggered weekly renewals, incompatible per-account constraints, provider isolation, disabled accounts, cached reads, resets, sleep gaps, private local persistence and colour propagation. These checks prove the implemented model’s scenario behaviour, **not** its measured real-world forecast accuracy. A newly installed model has no historical demand evidence and starts neutral.
