import PondKit
import SwiftUI

/// "Live, saved" (#plan in the mock-up, R15): the live events saved for their day, and "+ Save a live event".
/// On its day, an event is the live choice on Today, with its Live Activity on the Lock Screen.
struct EventsSection: View {
    @Environment(Store.self) private var store
    @State private var editing: Event?
    let undo: (String, @escaping @MainActor () -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Live, saved")
            ForEach(store.events) { event in
                HStack {
                    Button { editing = event } label: {
                        Text("🎟 \(event.title) · \(event.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) \(event.time())")
                            .font(.system(size: 15)).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: tap, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        store.removeEvent(event.id)
                        undo("Event removed") { store.saveEvent(event) }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.muted)
                            .frame(width: tap, height: tap)
                    }
                    .accessibilityLabel("Remove event")
                }
                .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
                .accessibilityElement(children: .contain).accessibilityIdentifier("event \(event.title)")
            }
            Button("+ Save a live event") {
                let evening = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? .now
                editing = Event(title: "", start: evening, place: "")
            }
            .buttonStyle(PillStyle(kind: .quiet, size: 15)).padding(.top, 12)
        }
        .sheet(item: $editing) { event in
            EventSheet(event: event) { saved in
                editing = nil
                store.saveEvent(saved)
            }
        }
    }
}

/// One live event: what, when, where and the cost. "Save for that day" makes it the live choice of its day.
private struct EventSheet: View {
    @Environment(Store.self) private var store
    @State private var event: Event
    @State private var link: String
    let save: (Event) -> Void

    init(event: Event, save: @escaping (Event) -> Void) {
        _event = State(initialValue: event)
        _link = State(initialValue: event.link?.absoluteString ?? "")
        self.save = save
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("A live event").font(.serif(24))
                TextField("What", text: $event.title).accessibilityLabel("Event title").modifier(FieldStyle())
                DatePicker("When", selection: $event.start, in: Calendar.current.startOfDay(for: .now)...)
                    .font(.system(size: 15)).tint(Color.ink)
                TextField("Where", text: $event.place).accessibilityLabel("Place").modifier(FieldStyle())
                TextField("Cost, for example free", text: Binding { event.cost ?? "" } set: { event.cost = $0.isEmpty ? nil : $0 })
                    .accessibilityLabel("Cost").modifier(FieldStyle())
                TextField("Link", text: $link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Event link").modifier(FieldStyle())
                Picker("Domain", selection: $event.domain) {
                    Text("Domain").tag(Int?.none)
                    ForEach(store.plan.domains, id: \.number) { Text("\($0.number) \($0.name)").tag(Int?.some($0.number)) }
                }
                .tint(Color.ink)
                Button("Save for that day") { save(filled) }
                    .buttonStyle(PillStyle(kind: .primary)).padding(.top, 8)
                    .disabled(filled.title.isEmpty || filled.place.isEmpty)
            }
            .foregroundStyle(Color.ink)
            .padding(16).padding(.top, 8)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.card)
    }

    /// The event with its link. A link guesses the domain, as a share does (docs/concepts.md, sync 10).
    private var filled: Event {
        var event = event
        event.title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.place = event.place.trimmingCharacters(in: .whitespacesAndNewlines)
        event.link = URL(string: link.trimmingCharacters(in: .whitespaces)).flatMap { ["http", "https"].contains($0.scheme) ? $0 : nil }
        if event.domain == nil, let link = event.link { event.domain = HostDomain.guess(for: link)?.domain }
        return event
    }
}
