import Foundation
import LocalAuthentication
import Security

/// Secure Touch ID and Keychain service for biometric VM login.
@MainActor
public final class TouchIDService {
    public static let shared = TouchIDService()

    private let serviceName = "app.lumen.vm.guest-credentials"

    public var isTouchIDAvailable: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    public var biometricTypeDescription: String {
        let context = LAContext()
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            return "Touch ID"
        }
        return "Mac Password"
    }

    public func hasSavedPassword(for machineID: UUID) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: machineID.uuidString,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public func savePassword(_ password: String, for machineID: UUID) throws {
        guard let data = password.data(using: .utf8) else { return }

        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                          .userPresence, &error) else {
            throw error?.takeRetainedValue() as Error? ?? NSError(domain: "LumenTouchID", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create Keychain access control."])
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: machineID.uuidString
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access
        ]

        // Update in place: a failed update must not erase the user's previous credential.
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "LumenTouchID", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Could not save guest password in macOS Keychain (error \(status))."
            ])
        }
    }

    public func deletePassword(for machineID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: machineID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Authenticates using Touch ID (or Mac passcode fallback) and returns the decrypted password.
    public func authenticateAndRetrievePassword(for machineID: UUID, machineName: String) async throws -> String {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedReason = "Unlock and log into \(machineName)"

        var authError: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication

        let success = try await context.evaluatePolicy(policy, localizedReason: "Unlock and log into \(machineName)")
        guard success else {
            throw NSError(domain: "LumenTouchID", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Touch ID authentication was cancelled or failed."
            ])
        }

        // Retrieve decrypted password from Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: machineID.uuidString,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "LumenTouchID", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "No saved password found for \(machineName). Configure Touch ID password in VM settings."
            ])
        }

        return password
    }
}
