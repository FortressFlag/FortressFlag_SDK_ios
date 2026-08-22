import FortressFlag
import FortressFlagDebugUI
import SwiftUI

/// The example host for `FlagListView`: a real iOS app reading real flags from the local backend.
///
/// This app is a development fixture. Run the backend first
/// (`FortressFlag_Backend`: `make db-up && make migrate && make seed && make dev`), then run this
/// in the iOS Simulator — the simulator shares the Mac's loopback interface, so
/// `http://localhost:8080` reaches `make dev` directly. A physical device does not share it and
/// is out of scope here; see the repo README.
@main
struct FlagListExampleApp: App {
    init() {
        FortressFlag.start(
            Configuration(
                // The key `make seed` installs — a committed fixture guarding a database on a
                // laptop, deliberately hardcoded so this app runs with zero setup. A production
                // app would paste its own key from the dashboard's Settings → SDK keys.
                sdkKey: "ffc_dev_seedseedseedseedseedseedseedseedseedseed000",
                environment: .development,
                // Local development only; production uses the default HTTPS edge URL.
                baseURL: Self.localBaseURL,
                // nil = per-app device identity. Fine HERE ONLY: sharing an identity across an
                // app family needs a Keychain Sharing entitlement, and this example has no
                // family. A production app should pass the same group string in every app it
                // ships (e.g. "com.acme.fortressflag") with the Keychain Sharing capability
                // enabled — that is what makes one phone one billable seat instead of one per
                // app. See README "Set up the keychain access group".
                keychainAccessGroup: nil,
                // The backend does not sign payloads until M4 lands. `.disabled` is the designed
                // local-development path, not a shortcut — production keeps `.required`.
                signaturePolicy: .disabled,
                // The SDK's enforced minimum, so dashboard changes show up within half a minute.
                refreshInterval: .seconds(30),
                // Permits plaintext HTTP to loopback hosts only. Production never sets this.
                allowsInsecureLocalTransport: true,
                // Verbose logs name flag keys in the device log — a dev tool, never for shipping.
                logging: .verbose
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                FlagListView()
            }
        }
    }

    /// `http://localhost:8080`, built from components — no force-unwrapped URL string literals,
    /// even in an example (house rule; examples get copied).
    private static var localBaseURL: URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = 8080
        return components.url ?? URL(fileURLWithPath: "/")
    }
}
