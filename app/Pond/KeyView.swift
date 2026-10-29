import SwiftUI

/// "Show key": the public key of this phone in the server's key-file format, to enrol it by hand, and the address of the desktop.
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
            @Bindable var store = store
            Text("Desktop over the VPN").font(.system(size: 15, weight: .semibold)).padding(.top, 8)
            Text("When the server is down, the phone saves to the desktop. Turn on WireGuard on the phone.")
                .font(.system(size: 15)).foregroundStyle(Color.muted)
            TextField("http://10.0.0.2:8788", text: $store.desktop)
                .font(.system(size: 15, design: .monospaced))
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("desktop")
                .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.line))
            Spacer()
        }
        .foregroundStyle(Color.ink)
        .padding(16).padding(.top, 16)
        .presentationDetents([.medium])
        .presentationBackground(Color.card)
        .onAppear { store.loadKey() }
    }
}
