import PondKit
import SwiftUI

/// The interests of "One paper" (#plan in the mock-up, R14): one chip for each topic, and the days marked "old".
/// No interest has a quota: "One paper" takes the next paper from the interest that you read least lately.
struct InterestsSection: View {
    @Environment(Store.self) private var store
    @State private var open: Int?
    let undo: (String, @escaping @MainActor () -> Void) -> Void

    var body: some View {
        let interests = store.interests
        VStack(alignment: .leading, spacing: 0) {
            heading("Interests")
            FlowLayout(spacing: 8) {
                ForEach(Array(interests.topics.enumerated()), id: \.offset) { index, topic in
                    Button(topic.name) { open = index }.buttonStyle(PillStyle(kind: .chip, size: 15))
                }
                Button("+") {
                    var next = interests
                    next.topics.append(Interest(name: "New interest"))
                    store.setInterests(next)
                    open = next.topics.count - 1
                }
                .buttonStyle(PillStyle(kind: .chip, size: 15))
                .accessibilityLabel("Add an interest")
            }
            Text("Each interest has its feeds (arXiv, journals). \"One paper\" takes the next paper from the interest that you read least lately.")
                .font(.system(size: 13)).foregroundStyle(Color.muted).padding(.top, 8)
            Text("On these days, a classic from your list:").font(.system(size: 15)).padding(.top, 12)
            DayButtons(days: interests.oldDays) { days in
                var next = store.interests
                next.oldDays = days
                store.setInterests(next)
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("Old days")
        }
        .sheet(item: Binding { open.map(Open.init) } set: { open = $0?.id }) { item in
            InterestSheet(index: item.id) {
                open = nil
                let before = store.interests
                var next = before
                next.topics.remove(at: item.id)
                store.setInterests(next)
                undo("Interest removed") { store.setInterests(before) }
            }
        }
    }

    private struct Open: Identifiable { var id: Int }
}

/// One interest: its name, its feeds and its classics. Each change is kept at once.
private struct InterestSheet: View {
    @Environment(Store.self) private var store
    let index: Int
    let remove: () -> Void
    @State private var name = ""
    @State private var source = ""
    @State private var classicTitle = ""
    @State private var classicLink = ""

    var body: some View {
        let topic = store.interests.topics.indices.contains(index) ? store.interests.topics[index] : Interest(name: "")
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TextField("", text: $name).font(.serif(24)).accessibilityLabel("Interest name").modifier(FieldStyle())
                    .onSubmit { rename(topic) }
                Text("Feeds").font(.serif(20)).padding(.top, 12)
                ForEach(Array(topic.sources.enumerated()), id: \.offset) { at, source in
                    row(source.text, label: "Remove feed") { change { $0.sources.remove(at: at) } }
                }
                HStack {
                    TextField("arXiv category or feed link", text: $source).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().accessibilityLabel("Feed").modifier(FieldStyle())
                    Button("Add") {
                        guard let next = Interests.source(source) else { return }
                        source = ""
                        change { $0.sources.append(next) }
                        refetch()
                    }
                    .buttonStyle(PillStyle(kind: .quiet, size: 15)).disabled(Interests.source(source) == nil)
                }
                Text("For example math.HO, or https://www.nature.com/nature.rss").font(.system(size: 13)).foregroundStyle(Color.muted)
                Text("Classics").font(.serif(20)).padding(.top, 12)
                Text("Old papers and standards. A day marked \"old\" offers the first one that you did not read.")
                    .font(.system(size: 13)).foregroundStyle(Color.muted)
                ForEach(Array(topic.classics.enumerated()), id: \.offset) { at, paper in
                    row(paper.title, label: "Remove classic") { change { $0.classics.remove(at: at) } }
                }
                TextField("Title", text: $classicTitle).accessibilityLabel("Classic title").modifier(FieldStyle())
                HStack {
                    TextField("Link", text: $classicLink).keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().accessibilityLabel("Classic link").modifier(FieldStyle())
                    Button("Add") {
                        guard let paper = classic else { return }
                        classicTitle = ""
                        classicLink = ""
                        change { $0.classics.append(paper) }
                    }
                    .buttonStyle(PillStyle(kind: .quiet, size: 15)).disabled(classic == nil)
                }
                Button("Remove interest", action: remove).buttonStyle(PillStyle(kind: .quiet, size: 15)).padding(.top, 16)
            }
            .foregroundStyle(Color.ink)
            .padding(16).padding(.top, 8)
        }
        .onAppear { name = topic.name }
        .onDisappear { rename(topic) }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.card)
    }

    private var classic: Paper? {
        let title = classicTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, let url = URL(string: classicLink.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme) else { return nil }
        return Paper(title: title, link: url)
    }

    private func row(_ text: String, label: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Text(text).font(.system(size: 15)).lineLimit(2)
            Spacer()
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.muted)
                    .frame(width: tap, height: tap)
            }
            .accessibilityLabel(label)
        }
    }

    /// A new name keeps the fetched papers of the interest.
    private func rename(_ topic: Interest) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != topic.name, store.interests.topics.indices.contains(index),
              store.interests.topics[index].name == topic.name else { return }
        var next = store.interests
        next.topics[index].name = name
        next.papers[name] = next.papers.removeValue(forKey: topic.name)
        store.setInterests(next)
    }

    private func change(_ body: (inout Interest) -> Void) {
        guard store.interests.topics.indices.contains(index) else { return }
        var next = store.interests
        body(&next.topics[index])
        store.setInterests(next)
    }

    /// A new feed loads at once, not after the 6 hours.
    private func refetch() {
        var next = store.interests
        next.fetched = nil
        store.setInterests(next)
        Task { await store.fetchPapers() }
    }
}
