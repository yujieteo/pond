import CryptoKit
import Foundation
import Testing
@testable import PondKey

let body = Data(#"{"entry":{"date":"2026-10-28","title":"a test entry"},"id":"mac-test","key":"mac","op":"put","rev":1,"v":1}"#.utf8)

@Test func keyNamesFollowTheProtocol() {
    #expect(PondKey.isValidName("mac"))
    #expect(PondKey.isValidName("Mac-2026"))
    #expect(PondKey.isValidName(String(repeating: "a", count: 64)))
    #expect(!PondKey.isValidName(""))
    #expect(!PondKey.isValidName(String(repeating: "a", count: 65)))
    #expect(!PondKey.isValidName("../mac"))
    #expect(!PondKey.isValidName("mac.pub"))
    #expect(!PondKey.isValidName("mäc"))
    #expect(PondKey.serverFileName("mac") == "mac.pub")
}

@Test func publicKeyFileIsBase64OfTheDER() throws {
    let key = P256.Signing.PrivateKey().publicKey
    let text = PondKey.publicKeyFile(key)
    #expect(text.hasSuffix("\n"))
    #expect(!text.dropLast().contains { $0.isWhitespace })
    let der = try #require(Data(base64Encoded: String(text.dropLast())))
    #expect(der == key.derRepresentation)
}

@Test func signReadsTheKeyNameFromTheBody() throws {
    #expect(try PondKey.keyName(body: body) == "mac")
    #expect(throws: PondKey.Failure.self) { try PondKey.keyName(body: Data(#"{"id":"e1"}"#.utf8)) }
    #expect(throws: PondKey.Failure.self) { try PondKey.keyName(body: Data(#"{"key":"../x"}"#.utf8)) }
    #expect(throws: PondKey.Failure.self) { try PondKey.keyName(body: Data("not json".utf8)) }
}

@Test func signatureHeaderVerifies() throws {
    let key = P256.Signing.PrivateKey()
    let header = try PondKey.signatureHeader(body: body, signer: key)
    let signature = try P256.Signing.ECDSASignature(derRepresentation: #require(Data(base64Encoded: header)))
    #expect(key.publicKey.isValidSignature(signature, for: body))
    #expect(!key.publicKey.isValidSignature(signature, for: body + Data(" ".utf8)))
}

@Test(.enabled(if: SecureEnclave.isAvailable)) func secureEnclaveKeySignsInTheSameFormat() throws {
    let key = try SecureEnclave.P256.Signing.PrivateKey()
    let header = try PondKey.signatureHeader(body: body, signer: key)
    let signature = try P256.Signing.ECDSASignature(derRepresentation: #require(Data(base64Encoded: header)))
    #expect(key.publicKey.isValidSignature(signature, for: body))
}

/// The server reads the key file and checks the header. Run server/build.sh first.
@Test func serverAcceptsTheKeyFileAndTheHeader() throws {
    let program = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../server/pond_save").standardized
    try #require(FileManager.default.isExecutableFile(atPath: program.path()), "run server/build.sh first")
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appending(path: "entries"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appending(path: "keys"), withIntermediateDirectories: true)
    let key = P256.Signing.PrivateKey()
    try PondKey.publicKeyFile(key.publicKey).write(to: dir.appending(path: "keys/" + PondKey.serverFileName("mac")), atomically: true, encoding: .utf8)

    func post(_ signature: String) throws -> String {
        let process = Process()
        process.executableURL = program
        process.environment = ["REQUEST_METHOD": "POST", "CONTENT_LENGTH": "\(body.count)",
                               "HTTP_SIGNATURE": signature, "POND_DIR": dir.path()]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(body)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    #expect(try post(PondKey.signatureHeader(body: body, signer: P256.Signing.PrivateKey())).hasPrefix("Status: 403"))
    #expect(try post(PondKey.signatureHeader(body: body, signer: key)).hasPrefix("Status: 201"))
}
