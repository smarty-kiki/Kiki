//
//  DeepSeekAPIKeyStore.swift
//  kiki-desktop-agent
//

import Foundation
import Security

/// Stores the key in `UserDefaults`, deliberately not the Keychain: macOS asks for the login
/// password unless the reading build is the one the item's access control records, and this app is
/// rebuilt constantly while the key is read on every request.
final class DeepSeekAPIKeyStore: @unchecked Sendable {
    private static let apiKeyUserDefaultsKey = "deepSeekAPIKey"

    private static let legacyKeychainMigrationWasTriedUserDefaultsKey = "hasTriedMigratingTheLegacyAPIKey"

    /// The Keychain item the key lived in before.
    private static let legacyAPIKeyKeychainService = Bundle.main.bundleIdentifier ?? "com.smarty.kiki"
    private static let legacyAPIKeyKeychainAccount = "deepseek-api-key"

    /// Cached because every request reads the key.
    private var cachedAPIKey: String?

    /// Guards `cachedAPIKey`: the settings panel writes on the main actor while a request in
    /// flight reads from a background task, and a torn read of a Swift `String` can crash.
    private let cachedAPIKeyLock = NSLock()

    /// A recovered key means the key step the onboarding flag records is already done.
    private(set) var didRecoverTheKeyFromTheLegacyKeychain = false

    init() {
        // Safe to assign directly: nothing else can reach this instance yet.
        if let storedAPIKey = Self.readAPIKeyFromUserDefaults() {
            self.cachedAPIKey = storedAPIKey
        } else if let recoveredAPIKey = Self.migrateAPIKeyOutOfTheKeychainIfOneIsThere() {
            self.cachedAPIKey = recoveredAPIKey
            self.didRecoverTheKeyFromTheLegacyKeychain = true
        }
    }

    var apiKey: String? {
        cachedAPIKeyLock.lock()
        defer { cachedAPIKeyLock.unlock() }
        return cachedAPIKey
    }

    var hasAPIKey: Bool {
        apiKey != nil
    }

    /// A `nil`, empty or whitespace-only value clears the stored key instead of saving one.
    @discardableResult
    func saveAPIKey(_ apiKey: String?) -> Bool {
        let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let trimmedAPIKey, !trimmedAPIKey.isEmpty else {
            return clearAPIKey()
        }

        UserDefaults.standard.set(trimmedAPIKey, forKey: Self.apiKeyUserDefaultsKey)

        cachedAPIKeyLock.lock()
        cachedAPIKey = trimmedAPIKey
        cachedAPIKeyLock.unlock()
        return true
    }

    /// Removes any stored key, and drops the Keychain item an older build may have left.
    @discardableResult
    func clearAPIKey() -> Bool {
        UserDefaults.standard.removeObject(forKey: Self.apiKeyUserDefaultsKey)
        Self.deleteTheLegacyAPIKeyFromTheKeychain()

        cachedAPIKeyLock.lock()
        cachedAPIKey = nil
        cachedAPIKeyLock.unlock()
        return true
    }

    private static func readAPIKeyFromUserDefaults() -> String? {
        guard let storedAPIKey = UserDefaults.standard.string(forKey: apiKeyUserDefaultsKey),
              !storedAPIKey.isEmpty else {
            return nil
        }
        return storedAPIKey
    }

    /// Reads the key out of the legacy Keychain item and moves it into the settings store. This is
    /// the one Keychain read left, so the one moment a login-password dialog can appear; a declined
    /// dialog or a failed read is remembered as tried.
    private static func migrateAPIKeyOutOfTheKeychainIfOneIsThere() -> String? {
        guard !UserDefaults.standard.bool(forKey: legacyKeychainMigrationWasTriedUserDefaultsKey) else {
            return nil
        }

        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyAPIKeyKeychainService,
            kSecAttrAccount as String: legacyAPIKeyKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var keychainLookupResult: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(lookupQuery as CFDictionary, &keychainLookupResult)

        if lookupStatus == errSecSuccess,
           let apiKeyData = keychainLookupResult as? Data,
           let legacyAPIKey = String(data: apiKeyData, encoding: .utf8) {
            UserDefaults.standard.set(legacyAPIKey, forKey: apiKeyUserDefaultsKey)
            deleteTheLegacyAPIKeyFromTheKeychain()
            print("DeepSeek key: moved out of the Keychain into the settings store")
            return legacyAPIKey
        }

        // `errSecItemNotFound` is ordinary and costs nothing to look again; anything else is not
        // worth asking about twice.
        if lookupStatus != errSecItemNotFound {
            print("DeepSeek key: the Keychain item was not handed over (status \(lookupStatus))")
            UserDefaults.standard.set(true, forKey: legacyKeychainMigrationWasTriedUserDefaultsKey)
        }
        return nil
    }

    @discardableResult
    private static func deleteTheLegacyAPIKeyFromTheKeychain() -> Bool {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyAPIKeyKeychainService,
            kSecAttrAccount as String: legacyAPIKeyKeychainAccount
        ]

        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)

        // An item that was never there is the state asked for.
        return deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound
    }
}
