import CryptoKit
import Foundation
import PondKit
import Security

/// The key of this phone (R6). The Secure Enclave keeps the private key; the Keychain keeps only a handle
/// that works on this phone only, so a backup cannot move the key to another phone.
struct DeviceKey {
    /// The `key` id of docs/protocol.md, and the name of the key file on the server.
    let name: String
    let signer: Signer
    let publicKey: P256.Signing.PublicKey

    /// The text of keys/<name>.pub, as mac/pond-key writes it: base64 of the SubjectPublicKeyInfo DER.
    var publicKeyFile: String { publicKey.derRepresentation.base64EncodedString() + "\n" }
    var fileName: String { "\(name).pub" }

    private struct Stored: Codable {
        var name: String
        var handle: Data
    }

    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "org.teoyujie.pond",
        kSecAttrAccount as String: "device-key",
    ] }

    /// The key of this phone. The first call makes it.
    static func load() throws -> DeviceKey {
        var result: AnyObject?
        var read = query
        read[kSecReturnData as String] = true
        if SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            return try make(stored)
        }
        // A random part in the name, so that two phones never share a key file.
        let stored = Stored(name: "phone-" + UUID().uuidString.prefix(8).lowercased(), handle: try newHandle())
        var add = query
        add[kSecValueData as String] = try JSONEncoder().encode(stored)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return try make(stored)
    }

    #if targetEnvironment(simulator)
    // The simulator has no Secure Enclave. A software key lets the simulator test the protocol.
    private static func newHandle() throws -> Data { P256.Signing.PrivateKey().rawRepresentation }

    private static func make(_ stored: Stored) throws -> DeviceKey {
        let key = try P256.Signing.PrivateKey(rawRepresentation: stored.handle)
        return DeviceKey(name: stored.name, signer: key, publicKey: key.publicKey)
    }
    #else
    private static func newHandle() throws -> Data {
        var error: Unmanaged<CFError>?
        // No Face ID for each entry: the entry is one tap (R4). The phone must be unlocked to sign.
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           .privateKeyUsage, &error)
        else { throw error!.takeRetainedValue() as Error }
        return try SecureEnclave.P256.Signing.PrivateKey(accessControl: access).dataRepresentation
    }

    private static func make(_ stored: Stored) throws -> DeviceKey {
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored.handle)
        return DeviceKey(name: stored.name, signer: key, publicKey: key.publicKey)
    }
    #endif
}
