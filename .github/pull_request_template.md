<!--
Keep the PR description honest and specific. State non-obvious tradeoffs and which pillar they
serve: Security → Compliance → Efficiency → Cost (Founding CLAUDE.md §2).
-->

## What & why

## Compliance & security review

<!--
This block is not paperwork. SOC 2 Type II is graded by sampling real changes and asking for
evidence that review happened; GDPR expects data-protection questions to be asked at design time,
not at incident time. Answering here is what turns "we review changes" from a claim into a record.

This repository deserves the sharpest version of these questions. It is the only component that
runs on an end user's personal device, inside someone else's app, where we cannot ship a fix on our
own schedule — an App Store release cycle stands between a mistake and its correction. And it owns
the device identifier, which Founding §6.1 classifies as pseudonymous personal data and which is
simultaneously the linchpin of the billing model.

Tick every box that applies — or tick the last one. A block with nothing ticked is an unfinished
PR, not a PR with nothing to declare: that is the whole point of the last box.
-->

- [ ] **Device identity** — touches how the device ID is derived, stored, persisted, or reset
      (Founding §6.1). *It must not be derived from or reversible to IDFV, IDFA, serial numbers,
      or any end-user PII. It is pseudonymous personal data, not an anonymous token.*
- [ ] **Personal data** — collects, stores, transmits, or logs anything about the end user beyond
      what the customer explicitly configures (Founding §7.3, CLAUDE.md).
- [ ] **On-device storage** — changes what the SDK persists to the device, or where. *Cached flag
      values are a correctness feature (§8.4); anything beyond them needs justifying.*
- [ ] **Network surface** — changes what the SDK sends, to where, or how often. *The SDK receives
      only its own device's values — never the full ruleset, never another device's data.*
- [ ] **Host-app impact** — could affect the host app's stability, launch time, binary size, or
      battery. *A flagging outage must never take down a customer app (§8.1).*
- [ ] **Public API** — changes the SDK's public surface. *Backward compatibility on public SDK
      APIs is sacred (§8.3). We cannot recall a shipped version.*
- [ ] **None of the above.** I checked, and this change touches none of them.

<!-- For every box ticked above, answer here: what changed, which control covers it, and what you
     updated. Device-identity and personal-data changes also update
     docs/compliance/data-inventory.md in FortressFlag_Backend. -->

## Fallback behaviour

<!--
Founding §8.4 mandates the cascade: last recorded value, then `false`. If this change touches
resolution, caching, or any error path, state how the cascade still holds — including on first
launch with no connectivity, and after an app restart.
-->

## Testing

<!-- What you ran and what it proved, including offline and cold-start paths where relevant. -->

## Tradeoffs

<!-- What this gives up, and why that is the right call. Delete if genuinely none. -->
