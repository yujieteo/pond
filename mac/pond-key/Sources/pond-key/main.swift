import Foundation
import PondKey

let usage = """
    usage: pond-key create <name>   make a Secure Enclave key; print keys/<name>.pub
           pond-key sign <file>     print the Signature header value for the body in <file>
    """

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments.dropFirst()
do {
    switch (arguments.first, arguments.count) {
    case ("create", 2):
        let name = arguments.last!
        let key = try PondKey.create(name)
        FileHandle.standardError.write(Data("Put this line in /var/www/pond/keys/\(PondKey.serverFileName(name)) on the server:\n".utf8))
        print(PondKey.publicKeyFile(key), terminator: "")
    case ("sign", 2):
        let body = try Data(contentsOf: URL(filePath: arguments.last!))
        print(try PondKey.signatureHeader(body: body, signer: PondKey.load(PondKey.keyName(body: body))))
    default:
        fail(usage)
    }
} catch {
    fail("pond-key: \(error)")
}
