//
//  DeepSeekAPIKeyStore.swift
//  kiki-desktop-agent
//
//  Keychain-backed storage for the user's DeepSeek API key.

import Foundation
import Security

/// Stores the DeepSeek API key the user types into the settings panel. It lives in the
/// Keychain rather than in `UserDefaults`, an unencrypted plist in the user's home directory
/// that any process running as this user — and any backup of it — can read. `@unchecked
/// Sendable` because it crosses an isolation boundary, made safe by the lock around its only
/// mutable state.
final class DeepSeekAPIKeyStore: @unchecked Sendable {
    /// Keychain items are addressed by a service/account pair; the bundle identifier keeps
    /// this app's items namespaced away from every other app's entries.
    private static let apiKeyKeychainService = Bundle.main.bundleIdentifier ?? "com.smarty.kiki"
    private static let apiKeyKeychainAccount = "deepseek-api-key"

    /// The last value read from or written to the Keychain. Every request reads the key, so
    /// caching it keeps the streaming path from paying a Keychain round trip on each turn.
    private var cachedAPIKey: String?

    /// Guards `cachedAPIKey`. The settings panel writes on the main actor while a request in
    /// flight reads from a background task, and a torn read of a Swift `String` can crash.
    private let cachedAPIKeyLock = NSLock()

    init() {
        // Safe to assign directly: nothing else can reach this instance yet.
        self.cachedAPIKey = Self.readAPIKeyFromKeychain()
    }

    /// The user's DeepSeek API key, or `nil` when they haven't entered one yet.
    var apiKey: String? {
        cachedAPIKeyLock.lock()
        defer { cachedAPIKeyLock.unlock() }
        return cachedAPIKey
    }

    /// Whether a key has been saved. Drives the settings panel's status text.
    var hasAPIKey: Bool {
        apiKey != nil
    }

    /// Saves `apiKey`, replacing any key stored previously. A `nil`, empty or whitespace-only
    /// value clears the stored key instead, so emptying the field and saving reads as removal.
    ///
    /// - Returns: `true` when the Keychain reflects the requested change.
    @discardableResult
    func saveAPIKey(_ apiKey: String?) -> Bool {
        let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let trimmedAPIKey, !trimmedAPIKey.isEmpty else {
            return clearAPIKey()
        }

        guard let apiKeyData = trimmedAPIKey.data(using: .utf8) else {
            return false
        }

        // `SecItemUpdate` only succeeds when a matching item already exists, so
        // delete-then-add is the standard way to upsert. The delete matches on service and
        // account only, so a second key overwrites the first rather than leaving a stale
        // duplicate that would shadow this one.
        Self.deleteAPIKeyFromKeychain()

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.apiKeyKeychainService,
            kSecAttrAccount as String: Self.apiKeyKeychainAccount,
            kSecValueData as String: apiKeyData,
            // "After first unlock" is the least permissive accessibility that still lets a
            // background request read the key — never readable at the login window.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            return false
        }

        cachedAPIKeyLock.lock()
        cachedAPIKey = trimmedAPIKey
        cachedAPIKeyLock.unlock()
        return true
    }

    /// Removes any stored key. Called when the user clears the settings field; returns `true`
    /// when no key is left in the Keychain afterwards.
    @discardableResult
    func clearAPIKey() -> Bool {
        let didDeleteKeychainItem = Self.deleteAPIKeyFromKeychain()
        cachedAPIKeyLock.lock()
        cachedAPIKey = nil
        cachedAPIKeyLock.unlock()
        return didDeleteKeychainItem
    }

    private static func readAPIKeyFromKeychain() -> String? {
        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyKeychainService,
            kSecAttrAccount as String: apiKeyKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var keychainLookupResult: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(lookupQuery as CFDictionary, &keychainLookupResult)

        // `errSecItemNotFound` is the normal first-launch state rather than a failure, so it
        // falls through to the same `nil`.
        guard lookupStatus == errSecSuccess,
              let apiKeyData = keychainLookupResult as? Data,
              let storedAPIKey = String(data: apiKeyData, encoding: .utf8) else {
            return nil
        }

        return storedAPIKey
    }

    /// The callers that don't branch on the result only care that the Keychain ends up empty.
    @discardableResult
    private static func deleteAPIKeyFromKeychain() -> Bool {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyKeychainService,
            kSecAttrAccount as String: apiKeyKeychainAccount
        ]

        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)

        // Deleting an item that was never there leaves the Keychain in the state asked for.
        return deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound
    }
}
