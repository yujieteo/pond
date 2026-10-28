import CryptoKit
import Foundation
import PondKit
import Security

/// The Mac enrol key (R7 in docs/concepts.md): a Secure Enclave key, with the files of docs/protocol.md.
public enum PondKey {
    public enum Failure: Error, CustomStringConvertible {
        case badName(String), exists(URL), cannotWrite(URL), noKey(URL), noKeyInBody

        public var description: String {
            switch self {
            case .badName(let name): "the key name must be 1 to 64 of A-Z a-z 0-9 -, not \"\(name)\""
            case .exists(let file): "\(file.path(percentEncoded: false)) exists: delete it to make a new key"
            case .cannotWrite(let file): "cannot write \(file.path(percentEncoded: false))"
            case .noKey(let file): "no key at \(file.path(percentEncoded: false)): run pond-key create first"
            case .noKeyInBody: "the body has no valid \"key\" field"
            }
        }
    }

    /// The rule for `key` in docs/protocol.md. The name is also a file name, on the Mac and on the server.
    public static func isValidName(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count)
            && name.utf8.allSatisfy { $0 == UInt8(ascii: "-") || (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
    }

    /// The file for the key in keys/ of a local test server. The enrol key never goes in /var/www/pond/keys.
    public static func serverFileName(_ name: String) -> String { "\(name).pub" }

    /// The text of keys/<name>.pub: base64 of the SubjectPublicKeyInfo DER.
    public static func publicKeyFile(_ key: P256.Signing.PublicKey) -> String {
        key.derRepresentation.base64EncodedString() + "\n"
    }

    /// The `key` field of a request body: the key that must sign it.
    public static func keyName(body: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let name = object["key"] as? String, isValidName(name) else { throw Failure.noKeyInBody }
        return name
    }

    /// The value of the Signature header for these exact body bytes.
    public static func signatureHeader(body: Data, signer: Signer) throws -> String {
        try signer.signature(for: body).base64EncodedString()
    }

    /// The Secure Enclave keeps the private key. The file holds only a handle that works on this Mac only.
    public static func handleFile(_ name: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "pond-key/\(name).key")
    }

    public static func create(_ name: String) throws -> P256.Signing.PublicKey {
        guard isValidName(name) else { throw Failure.badName(name) }
        let file = handleFile(name)
        guard !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { throw Failure.exists(file) }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .userPresence], &error)
        else { throw error!.takeRetainedValue() as Error }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: key.dataRepresentation,
                                             attributes: [.posixPermissions: 0o600]) else { throw Failure.cannotWrite(file) }
        return key.publicKey
    }

    public static func load(_ name: String) throws -> SecureEnclave.P256.Signing.PrivateKey {
        let file = handleFile(name)
        guard let data = try? Data(contentsOf: file) else { throw Failure.noKey(file) }
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
    }
}
