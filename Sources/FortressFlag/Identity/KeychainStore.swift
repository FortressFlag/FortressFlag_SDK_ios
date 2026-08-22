import Foundation
import Security

/// A minimal wrapper over the data-protection keychain.
///
/// Only what the device identity needs: read one string, add one string without clobbering an
/// existing one, delete. No generic key-value store — a wider surface here would invite storing
/// things on a customer's device that we have no business storing (Founding §7.3).
enum KeychainStore {
    static let service = "com.fortressflag.sdk.device"

    /// The result of trying to write. `duplicate` is a first-class outcome, not an error: it is
    /// the signal that another of the customer's apps won the race and its value is authoritative.
    enum AddResult: Equatable {
        case added
        case duplicate
        case failed(OSStatus)
    }

    static func read(account: String, accessGroup: String?) -> Data? {
        var query = baseQuery(account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    static func add(_ value: Data, account: String, accessGroup: String?) -> AddResult {
        var query = baseQuery(account: account, accessGroup: accessGroup)
        query[kSecValueData as String] = value
        // `AfterFirstUnlock` rather than `WhenUnlocked`: the SDK must resolve an identity during a
        // background launch, when the device may not have been unlocked since boot.
        //
        // `ThisDeviceOnly` is the deliberate half. Without it the identity would ride an encrypted
        // iCloud backup onto a second physical device, which would break "one device, one seat"
        // (Founding §6.1) and would quietly make a pseudonymous per-device identifier into a
        // cross-device one — a privacy change, not just a billing bug.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return .added
        case errSecDuplicateItem: return .duplicate
        default: return .failed(status)
        }
    }

    @discardableResult
    static func delete(account: String, accessGroup: String?) -> OSStatus {
        SecItemDelete(baseQuery(account: account, accessGroup: accessGroup) as CFDictionary)
    }

    private static func baseQuery(account: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        // Opt macOS into the same keychain iOS uses, so access groups, accessibility classes and
        // `ThisDeviceOnly` mean the same thing on every platform we ship to. Without this, macOS
        // silently uses the legacy file-based keychain and the semantics diverge.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    /// Resolves the app's team prefix by asking the keychain what access group it filed an item
    /// under when we did not name one.
    ///
    /// The default group is `<TeamID>.<bundle id>`, so the first component is the team prefix. We
    /// need it because a shared access group must be written as `<TeamID>.com.acme.shared`, and
    /// the team ID is a build-time value (`$(AppIdentifierPrefix)`) that a library cannot read
    /// from its own source. Asking the system beats making every customer hard-code a string they
    /// will get wrong once and then debug for an afternoon.
    static func resolveTeamPrefix() -> String? {
        let probeAccount = "team-prefix-probe"

        var query = baseQuery(account: probeAccount, accessGroup: nil)
        query[kSecValueData as String] = Data()
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecReturnAttributes as String] = true

        var item: CFTypeRef?
        var status = SecItemAdd(query as CFDictionary, &item)

        if status == errSecDuplicateItem {
            // A previous probe was left behind — read its attributes instead of adding again.
            var readQuery = baseQuery(account: probeAccount, accessGroup: nil)
            readQuery[kSecReturnAttributes as String] = true
            readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(readQuery as CFDictionary, &item)
        }

        defer { delete(account: probeAccount, accessGroup: nil) }

        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String,
              let prefix = group.split(separator: ".").first
        else {
            return nil
        }
        return String(prefix)
    }
}
