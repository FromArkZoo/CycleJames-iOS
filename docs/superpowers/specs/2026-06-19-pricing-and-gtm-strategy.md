# CycleJames — Pricing & Go-To-Market Strategy

**Date:** 2026-06-19
**Status:** Decided (strategy); execution pending
**Owner:** James Browne

## Problem

CycleJames (v1.1.x, live on the App Store) has sold **one** unit since launch — and
that sale was a colleague who was personally told about the app. Organic sales and
organic discovery are effectively **zero**. App Store Connect shows no meaningful
funnel data (impressions / product-page views are not chartable — i.e. ~nil traffic).

## Diagnosis — it is not a price problem

The app is **$2.99 paid-upfront**, with no free tier and no trial. That is a *hard
paywall* on an unknown indie app in a category fronted by Zwift, TrainerRoad, and a
genuinely-free MyWhoosh. The result is a **paid-upfront doom loop**:

- Hard wall → nobody can try it → no word-of-mouth.
- No installs → no ratings/reviews → invisible in search, never featured.
- No ratings → no ranking → no impressions → no installs. (Loop.)

Lowering the price ($1.99 / $0.99) changes nothing: the problem is that a wall
*exists*, not how much it costs. Price resistance shows up as "many views, few buys";
we have ~zero views, so the bottleneck is **discovery + the model**, not the number.

## Goal (decided)

**Traction first.** For the next few months, optimise for installs, reviews, and
funnel data — not revenue. There is essentially no revenue to lose, and the traction
also doubles as a real GTM case study.

## Positioning (decided)

Banner: **"No subscription, ever."** This beats the *paid* incumbents (Zwift /
TrainerRoad), but **not** free MyWhoosh on its own — so it is paired with a product leg:

> **Structured indoor training you own. No subscription, no account, no cloud —
> connect your smart bike and ride.**

This differentiates on both fronts: against paid apps (you own it, never rent) and
against free MyWhoosh (no account, no cloud, no game world — clean, private, yours).

**Target rider:** the smart-bike owner who wants TrainerRoad-style structured workouts
but refuses the ~$20/mo, and doesn't want a game world or a cloud account.

The model and the message rhyme: **free → one-time Pro unlock → never a subscription**
*is* "no subscription, ever" made concrete.

## Pricing model (decided)

- **Now:** go **fully free**, no gating. With zero users, friction is the enemy and we
  don't yet know which features people would pay for. Free is an App Store Connect
  *metadata* change — no new build, no review wait.
- **Later (Phase 2):** add a **one-time "Pro" unlock** for power features once there is a
  real funnel (≈ hundreds of installs + reviews + signal on which features are valued).
  **Grandfather early users into Pro for free** (same pattern already shipped in JB
  Glossary) so early adopters become advocates, not bait-and-switch victims.
- **Subscription:** explicitly off the table until proven retention justifies it.

## Action plan

| # | Move | Effort | Why |
|---|------|--------|-----|
| 1 | Set price to **Free** in App Store Connect | 5 min, no build | Breaks the doom loop |
| 2 | **Sharpen the listing (ASO)** — subtitle states the positioning; keywords: indoor cycling, smart trainer, ERG, structured workout, FTP, no subscription | ~1 hr | Converts impressions once installs start |
| 3 | **In-app review prompt** (SKStoreReviewController) after a completed ride | small code task | Reviews are the #1 discovery/ranking lever; folds into the in-ride product work |
| 4 | **Community seeding** — honest "solo dev, free, no subscription, want feedback" posts in r/Velo, smart-bike Facebook groups, indie-trainer Discords, DCRainmaker comment sphere | ongoing | This *is* the distribution; free is what makes people try & recommend |
| 5 | **Measure the funnel** — App Analytics: impressions → views → installs → completed-rides → reviews; tag which posts drive installs | passive | GTM case-study data |
| 6 | **Phase 2: one-time Pro unlock** with early-adopter grandfathering | later | Monetise the hooked minority without breaking trust |

## Key principle

**Pricing is downstream of distribution.** Even free, an app nobody hears about stays
at zero. Going free *enables* the distribution motion (community word-of-mouth); it is
not the motion itself. The work is the seeding + the listing + the reviews loop.

## Relationship to product work

The three in-ride features being designed alongside this (ELAPSED-overflow fix, manual
mode, whole-ride intensity scaling) support the positioning: manual mode in particular
widens *who the app is for* (free-riders, not only structured-workout users), and the
review prompt (#3 above) is implemented as part of that product stream.
