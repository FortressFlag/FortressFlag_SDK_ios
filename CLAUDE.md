# FortressFlag_SDK_ios — Agent & Contributor Guide

> **This repo inherits the FortressFlag founding principles.** The canonical, source-of-truth
> document lives in the backend repo. Read it before making architectural or design decisions:
>
> - GitHub: <https://github.com/FortressFlag/FortressFlag_Backend/blob/development/CLAUDE.md>
> - Local clone: `~/Workspace/FortressFlag_Backend/CLAUDE.md`
>
> When anything here conflicts with the founding document, the founding document wins.
> Priority order when in doubt: **Security → Compliance → Efficiency → Cost.**

## This repo

The **iOS client SDK** — FortressFlag's first client SDK and the reference for future mobile
SDKs. It embeds in a customer's app, resolves flag values for a single device/user context, and
must never take that app down.

## Non-negotiable rules (see founding doc for the full set)

### Fail-safe evaluation (Founding §8.1, §8.4)
- The SDK **never throws to the caller** and **never crashes the host app.** A flagging outage
  must be invisible to the end user's core experience.
- **Fallback cascade, in this exact order:**
  1. **Last recorded value** — persist the most recent known-good value per flag to durable
     device storage and return it on any fetch failure (offline, timeout, cold start).
  2. **`false`** — if no value was ever recorded for a flag, return `false` (features ship gated
     off; a device that has never heard otherwise behaves as disabled).
- The local cache is a **correctness feature, not an optimization** — it must survive app restarts.

### Data minimization (Founding §2.1, §7.3)
- The SDK **must not download the full ruleset** or any other device's data. It receives only the
  values for its own device context from the edge.
- No secrets or PII in anything the SDK stores or transmits beyond what the customer configures.

### Device identity = billing (Founding §6.1)
- The SDK mints a **stable, privacy-respecting device identifier** that is consistent across *all*
  of the customer's apps on the same device — this is what makes "1 device = 1 seat" work.
- The device ID is a **GDPR pseudonymous identifier**: do **not** derive it from hardware IDs
  (IDFV/IDFA/serial) or end-user PII, and do not make it reversible to them.
- This derivation strategy is the highest-leverage decision in this repo (Founding §12) — design
  it deliberately, test it early, and document the chosen approach here.

### The chosen derivation (settles Founding §12 — ratified cross-platform)

> **No longer a proposal.** Founding §12 held this contract open "until a second mobile SDK
> ratifies it"; `FortressFlag_SDK_android` ratified it on 2026-08-18 (backend ADR-0013) by
> implementing the same format, semantics and vectors. Changes now go through a backend ADR
> and land canonically in `FortressFlag_Standards/contracts/device-identity.md`.

**`dev_` + unpadded base64url of 16 bytes from `SecRandomCopyBytes`** — or **`sim_`** with the
identical body when the build targets a simulator (`#if targetEnvironment(simulator)`,
compile-time-exact; device metering, M5): the server serves `sim_` identities flags normally
but excludes them from seat metering, so a customer's simulators are never billed, and tallies
sim traffic server-side to spot builds that lie. Acceptance covers BOTH prefixes regardless of
which one this build mints — a stored `dev_` id later read in a simulator is kept, because
identity stability wins over prefix purity. Random, never derived.

Not IDFV, not IDFA, not a serial — and specifically **not a hash of any of those**, which is the
tempting wrong answer: the input space is small enough to enumerate, so the "one-way" function is
reversible in practice and the result is not a pseudonym at all. Random has no preimage.

Stored in a **shared keychain access group** (`kSecClassGenericPassword`, service
`com.fortressflag.sdk.device`, account `v1`) with:

- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — `AfterFirstUnlock` because the SDK resolves
  flags during background launches; `ThisDeviceOnly` because an identity riding an iCloud backup
  onto a second physical device breaks "one device, one seat" *and* silently turns a per-device
  pseudonym into a cross-device one.
- `kSecAttrSynchronizable = false`
- **Add-then-read-on-conflict.** On `errSecDuplicateItem`, adopt the existing value; never
  overwrite. The keychain has no compare-and-swap, so two of a customer's apps launching together
  will both find nothing and both mint — the loser must adopt the winner, or the two apps sit on
  different identities and one device bills as two, permanently.
- Team prefix resolved at runtime (add an item with no group, read back `kSecAttrAccessGroup`), so
  customers pass `com.acme.fortressflag` rather than a build-time-expanded string.

Without a configured access group the identity is per app. That still works; it costs the customer
money, and the SDK logs that once.

**Cross-platform contract:** *128 bits of CSPRNG output, base64url, prefix `dev_` — or `sim_`
when the build targets a simulator/emulator, so the server can serve test traffic without
billing it — stored in platform-shared secure storage scoped to the vendor, never synced
across devices.* Same format, same semantics; only the storage mechanism differs, and
simulator detection is compile-time-exact on iOS and best-effort on Android. The canonical
statement of this contract — including the per-platform storage table and the machine-readable
accept/reject vectors — lives in
`FortressFlag_Standards/contracts/device-identity.md` (backend ADR-0013); this section is the
iOS implementation of it.

See `docs/threat-model.md` and `docs/contract-v1.md`.

## Workflow

- Default branch: `development`. Changes go via PR with review. (Founding §7.5)
- **Commits and PRs are authored as FortressFlag, never a personal identity.** Local commits
  carry `FortressFlag <noreply@fortressflag.com>` (the `~/Workspace/FortressFlag_*` gitconfig
  include); PRs are opened and merged via the `fortressflag` GitHub App, because GitHub
  authors a squash commit as the PR opener's account regardless of branch authorship.
- Public SDK API and the consumed ruleset contract are **backward-compatibility sacred** — never
  break a shipped SDK. (Founding §5, §8.3)
