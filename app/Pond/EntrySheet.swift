import PondKit
import SwiftUI

/// The entry sheet (#entry in the mock-up): only the title, with "Remove" and "Done".
/// The app fills the other fields, and they are under "More" (R4).
struct EntrySheet: View {
    enum Result { case done(Entry), remove }

    @Environment(Store.self) private var store
    @State private var entry: Entry
    @State private var link: String
    @State private var more = false
    private let finish: (Result) -> Void

    init(editing: Editing, finish: @escaping (Result) -> Void) {
        _entry = State(initialValue: editing.entry)
        _link = State(initialValue: editing.entry.link?.absoluteString ?? "")
        self.finish = finish
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                label("Title")
                TextField("", text: $entry.title, axis: .vertical)
                    .accessibilityLabel("Title")
                    .modifier(FieldStyle())
                HStack {
                    Button("Remove") { finish(.remove) }.buttonStyle(PillStyle(kind: .quiet))
                    Spacer()
                    Button("Done") { finish(.done(filled)) }
                        .buttonStyle(PillStyle(kind: .primary))
                        .frame(minWidth: 128)
                        .disabled(entry.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 12)
                DisclosureGroup("More", isExpanded: $more) {
                    VStack(alignment: .leading, spacing: 0) {
                        label("Link")
                        TextField("", text: $link).keyboardType(.URL).textInputAutocapitalization(.never)
                            .autocorrectionDisabled().accessibilityLabel("Link").modifier(FieldStyle())
                        label("What I made")
                        TextField("", text: Binding { entry.made ?? "" } set: { entry.made = $0.isEmpty ? nil : $0 },
                                  axis: .vertical)
                            .lineLimit(3...6).accessibilityLabel("What I made").modifier(FieldStyle())
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 0) {
                                label("Domain")
                                Picker("Domain", selection: $entry.domain) {
                                    Text("None").tag(Int?.none)
                                    ForEach(store.plan.domains, id: \.number) { Text("\($0.number) \($0.name)").tag(Int?.some($0.number)) }
                                }
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                label("Mode")
                                Picker("Mode", selection: $entry.mode) {
                                    Text("None").tag(Mode?.none)
                                    ForEach(Mode.allCases, id: \.self) { Text($0.label.capitalized).tag(Mode?.some($0)) }
                                }
                            }
                        }
                        .tint(Color.ink)
                    }
                }
                .font(.system(size: 15)).foregroundStyle(Color.muted).tint(Color.muted)
                .frame(minHeight: tap)
                .padding(.top, 12)
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 16).padding(.top, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(280), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(22)
        .presentationBackground(Color.card)
    }

    /// The entry with the link from its field. A link that is not a web link is not kept.
    private var filled: Entry {
        var entry = entry
        entry.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = link.trimmingCharacters(in: .whitespaces)
        entry.link = URL(string: text).flatMap { ["http", "https"].contains($0.scheme) ? $0 : nil }
        return entry
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.muted).padding(.top, 12).padding(.bottom, 4)
    }
}

private struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(minHeight: tap)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.line))
    }
}
