# Threat model — iOS client SDK

This is code that runs on end users' personal devices, inside our customers' apps. Two facts shape
everything below, and both come from `SECURITY.md`:

- **We cannot recall a shipped SDK.** A vulnerable version lives in customers' apps until they
  rebuild and ship, on their schedule and Apple's. Findings here are longer-lived than anywhere
  else in the system.
- **The end user is not our user.** People affected by a bug here have no relationship with us and
  did not choose us.

## Assets

| Asset | Why it matters |
|---|---|
| Flag values in transit and at rest on device | They control what a customer's app does |
| The device identity | Feeds per-device billing (Founding §6.1) and is a GDPR pseudonymous identifier (§7.3) |
| The customer's flag keys | Name unreleased work |
| The host app's availability | The SDK must never be the reason an app fails |

Note what is *not* on this list: end-user PII. The SDK collects none, and the cheapest way to keep
that true is to have no code path that could.

## Actors and what we do about them

### Passive network observer — **defended**

TLS 1.2 minimum, set explicitly on the session rather than inherited
(`HTTPClientAPI`). No flag values in URLs or query strings. The SDK requires no App Transport
Security exception, which is both a security property and a promise to customers: adding one to
their `Info.plist` for us would weaken every other connection their app makes.

### Active MITM with a trusted root installed — **defended**

This is the realistic TLS-bypass case: a corporate MDM profile, a debugging proxy, a user who
installed a root certificate. TLS alone does not survive it.

The envelope signature does. Payload bytes are signed with Ed25519 and verified on device against
a pinned set of public keys, independently of the transport. An attacker who terminates TLS can
replace the bytes but cannot sign them.

### Compromised CDN or edge node — **defended, by the same mechanism**

The edge serves payloads; it never holds a signing key. This is the reason signing exists at all
rather than "TLS is enough": our own data plane is a party the SDK does not have to trust.

### Replay — **defended**

The signature covers `tenant`, `environment`, `device`, `issuedAt` and `expiresAt`, so a captured
payload cannot be re-aimed at another environment or another device, and cannot be served back
indefinitely. See `contract-v1.md` for the expiry asymmetry between live responses and the cache.

### Cache poisoning — **defended**

The cache stores the signed envelope verbatim and re-verifies the signature on load. Editing the
file requires forging a signature; an unverifiable file is discarded rather than served.

### Other apps on the device — **defended**

The identity lives in the data-protection keychain with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and `kSecAttrSynchronizable = false`. Cached
values live in the app's own container, excluded from backups.

### A stolen SDK key — **bounded, and that is the design**

The key ships in every copy of the app; `strings` recovers it. So the posture must hold with the
key public: read-only, one tenant, one environment, rate-limited, revocable without an app
release. What a key-holder gains is the ability to read that environment's flag keys — which they
could already read out of the binary. Accepted and documented rather than pretended away.

### The device's owner — **not defended, deliberately**

Someone who owns the device can patch the app, patch the SDK, or edit memory. No client-side
mechanism changes that, and pretending otherwise would encourage exactly the wrong usage.

> **Flag values are not a security boundary.** Use them to decide what to show. Never use them to
> decide what someone is entitled to. Entitlement decisions belong on a server.

This is stated in the SDK's own API documentation, not just here, because the person who needs to
read it is the developer typing `isEnabled`.

### Denial of service against the host app — **defended**

The failure mode nobody thinks about until it happens: the SDK becoming the reason an app is slow
or broken.

- Response bodies are capped and the stream abandoned past the cap, so a hostile or broken server
  cannot exhaust memory
- Short request timeouts; `waitsForConnectivity` off
- Exponential backoff to a 30-minute cap; `Retry-After` honoured but clamped, so an absurd value
  cannot disable updates until force-quit
- Concurrent refreshes coalesce into one request
- No crash primitives in `Sources/` — no `try!`, `!`, `as!`, `fatalError`, `precondition` —
  enforced by SwiftLint *and* a CI grep, because a lint config is one PR away from being relaxed
- Change handlers are copied out from under the lock before being called, so a customer's
  re-entrant handler cannot deadlock

## Why no certificate pinning by default

Pinning fails **closed**. A rotated or mis-issued certificate would break flag delivery in every
installed copy of every customer's app until each one ships an update — and we cannot recall a
shipped SDK. That is a self-inflicted outage across our entire customer base, caused by a control
meant to prevent a much narrower attack.

Payload signing gives the same protection at a layer that fails **safe**: a bad signature means
"serve the last known values", not "the app is broken". Optional opt-in pinning remains available
for customers whose threat model demands it; when enabled it requires a backup pin and an expiry.

## Open: metering integrity

Device counts feed billing, so Founding §6.1 calls the metering path revenue-critical and requires
it to be tamper-resistant. Honestly: **today it is not.** A script can mint device identities and
inflate a customer's bill, or reuse one to under-report.

- **v1 mitigations:** server-side dedupe on `(tenant, device, day)`, rate limits per key and per
  device, anomaly alerting on a tenant's device-count curve.
- **The `sim_` prefix (device metering, M5) is a partial answer, honestly bounded.** Simulator
  builds mint `sim_` identities: the server serves them flags but excludes them from billing and
  tallies sim-vs-real request ratios per tenant per day, so simulator churn cannot inflate a
  bill and a fleet whose ratios look wrong is visible. The declared prefix is client-trusted —
  a hostile build can mint `dev_` in a simulator or `sim_` on a device — which is the same trust
  boundary as the identifier itself, and exactly the gap the next line closes.
- **The real answer** is Apple's App Attest, which gives a hardware-backed assertion that a request
  came from a genuine instance of the customer's app. It is free and Apple-native. The client
  contract reserves an `attestation` request field now so adopting it is not a breaking change.

This is recorded here rather than left implicit because an unstated gap is one nobody schedules.

## Privacy posture

- No IDFA, no ATT prompt, no IDFV, no location, no contacts, no advertising identifiers
- The device identity is 128 random bits — not derived from anything, so not reversible to anything
- `PrivacyInfo.xcprivacy` declares `NSPrivacyTracking: false` and Device ID for App Functionality,
  not linked to the user, not used for tracking
- `resetIdentity()` is a real erasure path: it deletes the keychain item and the cache
- Identity is minted lazily, so a customer can gate it behind their own consent flow
