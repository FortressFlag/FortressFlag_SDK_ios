# Security Policy

FortressFlag holds the switches that turn our customers' production behavior on and off. A
compromise of FortressFlag is a compromise of every customer that trusts us (Founding CLAUDE.md
§2.1). We would rather hear about a problem early and awkwardly than late and publicly.

## Reporting a vulnerability

**Use GitHub private vulnerability reporting:** open the repository's **Security** tab and choose
**Report a vulnerability**. This creates a private advisory that only maintainers can see, so a
report never sits in a public issue while it is still exploitable.

Please do not open a public issue, pull request, or discussion for a suspected vulnerability.

Helpful reports usually include: what you found, how to reproduce it, which component and version,
and what an attacker gets out of it. A rough report you send today beats a polished one you send
next month.

## What to expect

| Stage | Target |
|---|---|
| Acknowledgement that a human has read it | 3 business days |
| Initial assessment and severity | 10 business days |
| Fix or documented mitigation for critical/high findings | 30 days from assessment |

These are targets for a small team, stated so you know when to chase us rather than assume
silence means indifference. If a target slips, we will tell you where the work stands.

## Scope

This repository is the **iOS client SDK** — code that runs on end users' personal devices, inside
our customers' apps. Findings we especially want to hear about:

- **Device-identity problems.** The device ID is a pseudonymous identifier under GDPR (Founding
  §6.1). Anything that makes it derivable from, or reversible to, IDFV, IDFA, a serial number or
  end-user PII is a privacy finding, not a design preference.
- **Data leaving the device that should not.** The SDK receives only its own device's flag values
   — never the full ruleset, never another device's data. Anything that widens that is serious.
- **On-device storage exposure.** Cached flag values persist across restarts by design (§8.4).
  Anything that stores more than that, or stores it somewhere other apps can read, is a finding.
- **Host-app compromise or instability.** The SDK must never crash the host app or take it down
  when flagging is unavailable (§8.1).
- **Ruleset or transport integrity** — anything letting an attacker feed the SDK values it should
  not accept.

Two notes specific to this repo:

- **We cannot recall a shipped SDK.** A vulnerable version lives in customers' apps until they
  rebuild and ship, on their schedule and Apple's. That makes findings here longer-lived than
  anywhere else in the system, and worth reporting even when they look minor.
- **The end user is not our user.** People affected by a bug here have no relationship with us and
  did not choose us. We take reports about their privacy seriously on that basis alone.

Other components live in their own repositories, each with this policy: `FortressFlag_Backend`
(control plane), `FortressFlag_Frontend` (dashboard), `FortressFlag_Infra` (infrastructure).

## Safe harbour

If you make a good-faith effort to follow this policy, we will not pursue legal action against you
for your research. Good faith means: you do not access, modify, or retain data belonging to anyone
but yourself; you do not degrade service for others; you stop when you have proven the issue rather
than exploring how far it goes; and you give us a reasonable chance to fix it before disclosing.

## Disclosure

We will credit reporters who want credit, and coordinate timing on a public advisory once a fix is
available. If a finding affects customer data, our obligations under GDPR — including the 72-hour
notification window for a personal-data breach — take precedence over any disclosure timeline
agreed here.
