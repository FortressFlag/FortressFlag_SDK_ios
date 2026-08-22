# FortressFlag for iOS

The iOS client SDK for [FortressFlag](https://github.com/FortressFlag). Reads feature flag values
for one device, and gets out of the way.

> **Status: pre-release.** The public API, evaluation cascade, device identity, durable cache and
> transport are implemented and tested, and the SDK runs against the backend's client API
> (`GET /v1/client/flags`, see [`docs/contract-v1.md`](docs/contract-v1.md)) on a local
> development stack. There is no production edge yet, and payload signing (M4) has not landed —
> local development uses `SignaturePolicy.disabled` explicitly.

## The promise

**No call in this API throws, blocks, or can crash your app.** A FortressFlag outage, a dead
network, a revoked key, a hotel Wi-Fi captive portal, a corrupt cache — all of them resolve to a
flag value, and none of them reach your code as an error.

If flagging can take an app down, it is worse than no flagging at all.

## What this is not

**Flag values are not a security boundary.** They are evaluated on a device the end user controls;
anyone willing to patch your binary can turn any flag on. Use flags to decide *what to show*, never
to decide *what someone is entitled to*. Entitlement checks belong on your server.

## Installation

```swift
.package(url: "https://github.com/FortressFlag/FortressFlag_SDK_ios.git", from: "0.1.0")
```

Requires iOS 17, macOS 14 or visionOS 1. No dependencies.

## Usage

```swift
import FortressFlag

// Once, at launch. Returns as soon as cached values are loaded.
FortressFlag.start(
    Configuration(
        sdkKey: "ffc_prod_…",
        environment: .production,
        keychainAccessGroup: "com.acme.fortressflag",  // same value in every app you ship — this is what makes one phone one seat
        tags: ["cohort": "beta"]   // optional: custom targeting tags, sent with every fetch
    )
)

// Anywhere, including inside a SwiftUI body.
if FortressFlag.isEnabled("new-checkout") {
    NewCheckoutView()
} else {
    LegacyCheckoutView()
}
```

That is the whole API you need most days. The rest:

```swift
FortressFlag.isEnabled("new-checkout", default: true)   // default applies only if never recorded
await FortressFlag.refresh()                            // -> RefreshOutcome, never throws
FortressFlag.setTags(["cohort": "internal"])            // replace custom tags; fetches immediately
let token = FortressFlag.onChange { changedKeys in … }  // unregisters on deinit
FortressFlag.resolve("new-checkout").source             // .fresh / .cached / .developerDefault / .safeDefault
FortressFlag.allFlags()                                 // [String: Resolution] — every key this device holds
FortressFlag.resetIdentity()                            // GDPR erasure
FortressFlag.diagnostics                                // for a debug screen
FortressFlag.stop()
```

## Set up the keychain access group — it costs you money not to

FortressFlag bills **per device**, not per app. One phone with three of your apps is one seat. That
only works if all three apps agree on the same device identity, which means sharing a keychain
access group.

1. In each app target: **Signing & Capabilities → + Capability → Keychain Sharing**
2. Add the same group to every one of your apps, e.g. `com.acme.fortressflag`
3. Pass that string — **without** the team prefix — as `keychainAccessGroup`. The SDK resolves your
   team prefix at runtime, so you do not have to hard-code `$(AppIdentifierPrefix)` anywhere.

Skip this and the SDK still works, but stores the identity per app: one device counts as three
billable devices. It logs a warning once when that happens.

## The debug flag list

The package ships a second library product, **`FortressFlagDebugUI`**, containing `FlagListView`:
a SwiftUI screen that lists every flag key this device has received with its effective value and
provenance, live-updates as values change, offers manual refresh, and shows the SDK's
diagnostics. It is the screen to reach for when an integration "isn't working" — it answers "is
the SDK even talking to the server?" at a glance.

```swift
import FortressFlagDebugUI

NavigationStack {
    FlagListView()   // after FortressFlag.start(...)
}
```

It is a separate product on purpose: an app that does not link `FortressFlagDebugUI` never
compiles it. It shows only what `FortressFlag.allFlags()` exposes — this device's own payload,
whose keys ship in your binary anyway — never flag names, descriptions, or other devices' data.

## Run the example app

`Examples/FlagListExample` is a minimal iOS app that renders `FlagListView` against the local
backend, with zero configuration beyond having that backend running:

1. Start the backend (`~/Workspace/FortressFlag_Backend`):
   `make db-up && make migrate && make seed && make dev`
2. Open `Examples/FlagListExample/FlagListExample.xcodeproj` in Xcode.
3. Pick any iOS Simulator and Run.

The list shows the seeded flags within a few seconds. Toggle one in the dashboard (dev
environment) and it changes here on the next poll, or immediately on pull-to-refresh. Kill
`make dev` and the values keep serving from the durable cache — which is the SDK working, not
failing.

It hardcodes the seed data's committed dev SDK key and talks plaintext HTTP to
`localhost:8080` — both local-development-only choices, commented as such in the source. The
**iOS Simulator** shares your Mac's loopback interface, so `localhost` reaches the backend
directly; a **physical device** does not, and running against one is out of scope for this
example (it needs the device pointed at your Mac's LAN address over HTTPS, which is M4+
territory).

## How a value is resolved

In this order, always (Founding CLAUDE.md §8.4):

1. **The most recent value fetched from FortressFlag**
2. **The last value this device recorded**, from durable storage that survives app restarts
3. **Your `default:`**, if you passed one
4. **`false`**

Step 2 comes before step 3 on purpose. A value this device actually received beats a compiled-in
default however old it is — the server is the authority on a flag's state, and `default:` answers
"what if this device has never heard anything about this flag at all?", not "what if we are
offline?".

New features ship gated off, so `false` is the safe floor.

## Privacy

- **No tracking.** `PrivacyInfo.xcprivacy` declares `NSPrivacyTracking: false`, so embedding
  FortressFlag does not oblige you to show an App Tracking Transparency prompt.
- **No IDFA, no IDFV, no hardware identifiers, no location, no contacts.** The device identity is
  128 random bits, generated on device — not derived from anything, and so not reversible to
  anyone.
- **No end-user PII** is collected, stored, or transmitted.
- `resetIdentity()` is a real erasure path: it deletes the identity and every cached value.
- Identity is minted lazily on first use, so you can gate it behind your own consent flow.

## Security

- TLS 1.2 minimum. **No App Transport Security exception required** — if a networking SDK asks you
  to weaken ATS, that weakens every other connection your app makes.
- Payloads carry an Ed25519 signature verified on device, so a compromised network or CDN cannot
  feed your app values FortressFlag did not sign.
- The cached payload is stored signed and re-verified on load, so the cache cannot be poisoned by
  editing a file.
- The SDK key is not a secret and is not treated as one: read-only, one environment, revocable.

The full analysis, including what is deliberately *not* defended, is in
[`docs/threat-model.md`](docs/threat-model.md). Report vulnerabilities via
[`SECURITY.md`](SECURITY.md).

## Development

```sh
swift build
swift test
```

Swift Testing ships with Xcode, not the Command Line Tools. If `swift test` reports
`no such module 'Testing'`, point at Xcode:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Four keychain tests skip on a bare `swift test` host — a process with no application identifier
cannot reach the data-protection keychain. CI runs them in a simulator, where they do not skip.

`FortressFlagTestKit` builds contract-v1 envelopes (signed, unsigned, tampered, expired) so the
backend's signer can be checked against this SDK's verifier before either side ships.
