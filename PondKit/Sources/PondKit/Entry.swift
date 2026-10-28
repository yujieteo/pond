import CryptoKit
import Foundation

/// The four ways into a domain of the grid (docs/concepts.md, Grid).
public enum Mode: String, Codable, CaseIterable, Sendable {
    case home, live, takePart = "take-part", make
}

/// One thing that you did, as the server and the stream see it.
/// Fun is private, so it is not here: the app keeps it on the phone.
public struct Entry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case media, note }

    public var date: String
    public var title: String
    public var link: URL?
    public var made: String?
    public var domain: Int?
    public var mode: Mode?
    public var kind: Kind
    public var slot: String?

    public init(date: String, title: String, link: URL? = nil, made: String? = nil,
                domain: Int? = nil, mode: Mode? = nil, kind: Kind = .media, slot: String? = nil) {
        self.date = date
        self.title = title
        self.link = link
        self.made = made
        self.domain = domain
        self.mode = mode
        self.kind = kind
        self.slot = slot
    }
}

/// A change to one entry, as docs/protocol.md gives it.
public struct Change: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable { case put, remove }

    public var v = 1
    public var op: Op
    public var id: String
    public var rev: Int
    public var key: String
    public var entry: Entry?

    public static func put(_ entry: Entry, id: String, rev: Int, key: String) -> Change {
        Change(op: .put, id: id, rev: rev, key: key, entry: entry)
    }

    public static func remove(id: String, rev: Int, key: String) -> Change {
        Change(op: .remove, id: id, rev: rev, key: key, entry: nil)
    }
}

/// A P-256 key that signs. The phone uses a Secure Enclave key; the tests use a software key.
public protocol Signer {
    func signature(for data: Data) throws -> Data
}

extension P256.Signing.PrivateKey: Signer {
    public func signature(for data: Data) throws -> Data {
        try (signature(for: data) as P256.Signing.ECDSASignature).derRepresentation
    }
}

extension SecureEnclave.P256.Signing.PrivateKey: Signer {
    public func signature(for data: Data) throws -> Data {
        try (signature(for: data) as P256.Signing.ECDSASignature).derRepresentation
    }
}

/// The exact body bytes and their signature. Send the body as it is: the signature is over these bytes.
public struct SignedChange: Sendable {
    public let body: Data
    public let signature: String

    public init(_ change: Change, signer: Signer) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        body = try encoder.encode(change)
        signature = try signer.signature(for: body).base64EncodedString()
    }

    public func request(server: URL) -> URLRequest {
        var request = URLRequest(url: server.appending(path: "pond/entry"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(signature, forHTTPHeaderField: "Signature")
        return request
    }
}
