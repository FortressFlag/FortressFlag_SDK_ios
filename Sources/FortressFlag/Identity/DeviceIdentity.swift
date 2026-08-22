import Foundation
import os
import Security

/// Why the SDK has no device identity right now.
public enum IdentityFailure: Error, Sendable, Equatable {
    /// The keychain refused. Usually a missing Keychain Sharing entitlement for the configured
    /// access group, or a device that has not been unlocked since boot.
    case keychainUnavailable(OSStatus)
    /// The system CSPRNG failed. Essentially never; enumerated so it cannot be swallowed.
    case entropyUnavailable(OSStatus)
}

/// Supplies the stable device identity. A protocol so the client can be tested without a keychain.
protocol DeviceIdentityProviding: Sendable {
    /// Returns the identity, minting it on first call. Never throws, never blocks on the network.
    func identity() -> Result<String, IdentityFailure>
    /// Forgets the identity. The next call to `identity()` mints a new one.
    func reset()
}

/// The device identity: a random 128-bit pseudonym in the keychain.
///
/// **Random, never derived.** Not `identifierForVendor`, not the IDFA, not a serial, and — the
/// tempting wrong answer — not a hash of any of those either. A hash of a hardware identifier is
/// still derived from it: the input space is small enough to enumerate, so the "one-way" function
/// is reversible in practice and the result is not a pseudonym at all. 128 bits of CSPRNG output
/// has no preimage to recover, which is what Founding §6.1 means by "must not be reversible to
/// end-user PII".
///
/// **Shared across the customer's apps** via a keychain access group, because that is the entire
/// mechanism behind per-device billing: one phone with three of a customer's apps is one seat, not
/// three. Without a configured group the identity is per app, which works but costs the customer
/// money — the SDK says so, once, in the log.
///
/// The format is a cross-platform contract, not an implementation detail: a prefix followed by
/// unpadded base64url of 16 random bytes. Android must mint the same shape into its own
/// signature-shared storage so that "one device" means the same thing on both platforms.
final class KeychainDeviceIdentity: DeviceIdentityProviding {
    /// Bumping this rotates every device's identity, and would reset the customer's device counts
    /// for the billing period. It is versioned so that is a deliberate, visible act.
    private static let account = "v1"

    /// The prefix this build mints. Simulator builds mint `sim_`: the server serves them
    /// flags normally but excludes them from seat metering, so a customer's simulators are
    /// never billed — and sim traffic is tallied server-side to spot builds that lie.
    /// Compile-time, so detection is exact on iOS.
    #if targetEnvironment(simulator)
    private static let mintedPrefix = "sim_"
    #else
    private static let mintedPrefix = "dev_"
    #endif

    /// Every prefix a stored identity may carry. A device that stored a `dev_` id before the
    /// `sim_` change and then runs in a simulator keeps its stored id — identity stability wins
    /// over prefix purity, and the server accepts both.
    private static let acceptedPrefixes = ["dev_", "sim_"]

    private static let entropyBytes = 16

    private let accessGroup: String?
    private let log: Log

    /// Memoised so a per-frame `isEnabled` call never reaches the keychain, and so a device that
    /// minted an ID this launch keeps it even if the keychain later goes unavailable.
    private let memo = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let warnedAboutPerAppFallback = OSAllocatedUnfairLock(initialState: false)

    init(configuredAccessGroup: String?, log: Log) {
        self.log = log

        // Resolve `com.acme.shared` to `<TeamID>.com.acme.shared`. If the team prefix cannot be
        // read the group is unusable, so fall back to per-app storage rather than issuing queries
        // that will fail forever.
        if let configuredAccessGroup {
            if let teamPrefix = KeychainStore.resolveTeamPrefix() {
                self.accessGroup = "\(teamPrefix).\(configuredAccessGroup)"
            } else {
                self.accessGroup = nil
                log.warning(
                    """
                    Could not resolve the team prefix for keychain access group \
                    '\(configuredAccessGroup)'. Falling back to per-app device identity: this \
                    device will be counted once per app rather than once in total. Check that the \
                    Keychain Sharing capability is enabled and lists this group.
                    """
                )
            }
        } else {
            self.accessGroup = nil
        }
    }

    func identity() -> Result<String, IdentityFailure> {
        if let memoised = memo.withLock({ $0 }) {
            return .success(memoised)
        }

        if accessGroup == nil {
            warnOncePerAppFallback()
        }

        let result = loadOrCreate()
        if case let .success(value) = result {
            memo.withLock { $0 = value }
        }
        return result
    }

    func reset() {
        memo.withLock { $0 = nil }
        KeychainStore.delete(account: Self.account, accessGroup: accessGroup)
        log.debug("device identity reset")
    }

    // MARK: - Load or create

    private func loadOrCreate() -> Result<String, IdentityFailure> {
        if let existing = readValidated() {
            return .success(existing)
        }

        let minted: String
        switch Self.mint() {
        case let .success(value): minted = value
        case let .failure(failure): return .failure(failure)
        }

        guard let data = minted.data(using: .utf8) else {
            return .failure(.entropyUnavailable(errSecParam))
        }

        switch KeychainStore.add(data, account: Self.account, accessGroup: accessGroup) {
        case .added:
            log.debug("minted a new device identity")
            return .success(minted)

        case .duplicate:
            // Another of the customer's apps minted one between our read and our write. Read it
            // and use theirs — never overwrite.
            //
            // The keychain has no compare-and-swap, so this window is real: two apps of the same
            // family launched together will both find nothing and both mint. Losing this race
            // must be harmless, because the loser overwriting the winner would leave the two apps
            // on different identities and bill one device as two, permanently.
            if let existing = readValidated() {
                log.debug("lost the identity mint race; adopting the existing value")
                return .success(existing)
            }
            return .failure(.keychainUnavailable(errSecDuplicateItem))

        case let .failed(status):
            log.error(
                """
                Could not store the device identity (OSStatus \(status)). Flags will still resolve \
                from cache and defaults, but this device cannot be counted or receive fresh values.
                """
            )
            return .failure(.keychainUnavailable(status))
        }
    }

    /// Reads the stored identity, rejecting anything that is not one we would have written.
    ///
    /// A corrupt or foreign value is treated as absent rather than trusted. Sending a malformed
    /// identifier upstream would fail every request; adopting it silently would put junk in the
    /// billing path.
    private func readValidated() -> String? {
        guard let data = KeychainStore.read(account: Self.account, accessGroup: accessGroup),
              let value = String(data: data, encoding: .utf8),
              Self.isWellFormed(value)
        else {
            return nil
        }
        return value
    }

    static func isWellFormed(_ value: String) -> Bool {
        guard let prefix = acceptedPrefixes.first(where: { value.hasPrefix($0) }) else { return false }
        let body = String(value.dropFirst(prefix.count))
        guard let decoded = Base64URL.decode(body), decoded.count == entropyBytes else { return false }
        return true
    }

    private static func mint() -> Result<String, IdentityFailure> {
        var bytes = [UInt8](repeating: 0, count: entropyBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return .failure(.entropyUnavailable(OSStatus(status)))
        }
        return .success(mintedPrefix + Base64URL.encode(Data(bytes)))
    }

    private func warnOncePerAppFallback() {
        let alreadyWarned = warnedAboutPerAppFallback.withLock { warned -> Bool in
            defer { warned = true }
            return warned
        }
        guard !alreadyWarned else { return }
        log.warning(
            """
            No keychain access group configured. The device identity is stored per app, so a \
            device running several of your apps counts as several billable devices. Set \
            Configuration.keychainAccessGroup and enable Keychain Sharing to count it once.
            """
        )
    }
}
