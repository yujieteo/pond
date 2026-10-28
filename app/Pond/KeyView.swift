import SwiftUI

/// "Show key": the public key of this phone in the server's key-file format, to enrol it by hand.
struct KeyView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This phone").font(.serif(24))
            switch store.key {
            case .success(let key):
                Text("Put this text in `/var/www/pond/keys/\(key.fileName)` on the server. The server then accepts this phone's entries.")
                    .font(.system(size: 15)).foregroundStyle(Color.muted)
                    .accessibilityIdentifier("keyFile")
                Text(key.publicKeyFile.trimmingCharacters(in: .newlines))
                    .font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    .accessibilityIdentifier("publicKey")
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.line))
                HStack {
                    Button("Copy") { UIPasteboard.general.string = key.publicKeyFile }.buttonStyle(PillStyle(kind: .primary))
                    ShareLink("Share", item: key.publicKeyFile, subject: Text(key.fileName)).buttonStyle(PillStyle(kind: .quiet))
                }
            case .failure(let error):
                Text("No key: \(error.localizedDescription)").foregroundStyle(Color.muted)
            case nil:
                ProgressView()
            }
            Spacer()
        }
        .foregroundStyle(Color.ink)
        .padding(16).padding(.top, 16)
        .presentationDetents([.medium])
        .presentationBackground(Color.card)
        .onAppear { store.loadKey() }
    }
}
