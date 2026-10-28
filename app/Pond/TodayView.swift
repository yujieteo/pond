import PondKit
import SwiftUI

/// What the entry sheet edits: a new entry, or a record of the journal.
struct Editing: Identifiable {
    var id: String
    var entry: Entry
    var isNew: Bool
}

/// The toast layer: one line and its controls (docs/concepts.md, Undo before send).
struct Toast: Identifiable {
    enum Kind { case fun(id: String), undo(id: String) }
    let id = UUID()
    var kind: Kind
}

/// Today (#today in the mock-up): the menu (R2), "Every day" (R13) and the entries of today.
struct TodayView: View {
    @Environment(Store.self) private var store
    @State private var picked: Int?
    @State private var editing: Editing?
    @State private var toast: Toast?
    @State private var showKey = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Date.now.formatted(Date.VerbatimFormatStyle(format: "\(weekday: .wide) \(day: .defaultDigits) \(month: .wide)", locale: .current, timeZone: .current, calendar: .current)).uppercased())
                        .font(.system(size: 13, weight: .medium)).tracking(0.5).foregroundStyle(Color.muted)
                    Text("What do you want today?")
                        .font(.serif(32)).padding(.top, 4).padding(.bottom, 16)
                    choices
                    heading("Every day")
                    everyDay
                    heading("Done today")
                    done
                    heading("This phone")
                    Button("Show key") { showKey = true }.buttonStyle(PillStyle(kind: .quiet, size: 15))
                }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 110)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .zIndex(Layer.content.rawValue)
            bar.zIndex(Layer.controls.rawValue)
            if let toast {
                toastView(toast).padding(.bottom, 84).zIndex(Layer.toast.rawValue)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .foregroundStyle(Color.ink)
        .background(Color.pondBackground)
        .animation(.easeOut(duration: 0.2), value: toast?.id)
        .sheet(item: $editing) { editing in
            EntrySheet(editing: editing) { result in
                self.editing = nil
                switch result {
                case .done(let entry) where editing.isNew: recorded(store.record(entry))
                case .done(let entry): store.edit(editing.id, entry: entry)
                case .remove where !editing.isNew: removeWithUndo(editing.id)
                case .remove: break
                }
            }
        }
        .sheet(isPresented: $showKey) { KeyView() }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.serif(20)).padding(.top, 28).padding(.bottom, 8)
    }

    // MARK: the menu

    private var choices: some View {
        VStack(spacing: 12) {
            ForEach(Array(store.choices.enumerated()), id: \.offset) { index, choice in
                choiceCard(choice, picked: picked == index)
                    .opacity(picked == nil || picked == index ? 1 : 0.55)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { picked = index } }
            }
        }
    }

    private func choiceCard(_ choice: Choice, picked: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(icon(choice)).font(.system(size: 18))
                .frame(width: 36, height: 36).background(Circle().fill(Color.pondBackground))
            VStack(alignment: .leading, spacing: 4) {
                Text(choice.why).font(.system(size: 13)).foregroundStyle(Color.muted)
                Text(choice.entry.title).font(.serif(18.5)).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
                if picked {
                    HStack(spacing: 8) {
                        Button("Done") {
                            recorded(store.record(choice.entry))
                            self.picked = nil
                        }.buttonStyle(PillStyle(kind: .primary))
                        Button("Something else") { self.picked = nil }.buttonStyle(PillStyle(kind: .quiet))
                    }.padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(minHeight: 72)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.card).shadow(color: .ink.opacity(0.06), radius: 6, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(picked ? Color.ink : Color.line, lineWidth: picked ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private func icon(_ choice: Choice) -> String {
        switch choice.source {
        case .slot: choice.entry.domain == 2 ? "🎵" : choice.entry.domain == 5 ? "🎬" : "📄"
        case .enjoyed: "🎵"
        case .notVisited: choice.entry.mode == .live ? "🎟" : "🧭"
        }
    }

    // MARK: every day

    private var everyDay: some View {
        HStack(spacing: 8) {
            ForEach(Store.everyDay, id: \.self) { name in
                let on = store.everyDayRecord(name) != nil
                Button(on ? "✓ \(name)" : name) {
                    let wasOn = on
                    store.toggleEveryDay(name)
                    if !wasOn, let record = store.everyDayRecord(name) { recorded(record.id) }
                }
                .buttonStyle(PillStyle(kind: on ? .chipOn : .chip))
            }
        }
    }

    // MARK: done today

    private var done: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.doneToday) { record in
                VStack(alignment: .leading, spacing: 6) {
                    Button { editing = Editing(id: record.id, entry: record.entry, isNew: false) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.entry.title).font(.serif(17)).multilineTextAlignment(.leading)
                            Text(meta(record)).font(.system(size: 13)).foregroundStyle(Color.muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: tap, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    funButtons(record)
                }
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
            }
        }
    }

    private func meta(_ record: Record) -> String {
        var parts = [store.domainName(record.entry.domain), record.entry.mode?.label].compactMap { $0 }
        if record.refused { parts.append("not accepted") } else if record.waiting { parts.append("waiting") }
        return parts.joined(separator: " · ")
    }

    private func funButtons(_ record: Record) -> some View {
        HStack(spacing: 4) {
            ForEach(Fun.allCases, id: \.self) { fun in
                Button(fun.rawValue) { store.mark(record.id, fun: record.fun == fun ? nil : fun) }
                    .buttonStyle(PillStyle(kind: record.fun == fun ? .funOn : .fun, size: 13))
            }
        }
    }

    // MARK: the bar and the toasts

    private var bar: some View {
        HStack(spacing: 4) {
            Text("Today").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.pondBackground)
                .frame(minWidth: 64, minHeight: 48).padding(.horizontal, 8).background(Capsule().fill(Color.ink))
            Button {
                editing = Editing(id: UUID().uuidString, entry: Entry(date: store.today, title: ""), isNew: true)
            } label: {
                Text("+").font(.system(size: 24)).foregroundStyle(.white)
                    .frame(width: 48, height: 48).background(Circle().fill(Color.accent))
            }
            .accessibilityLabel("New entry")
        }
        .padding(6)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.line.opacity(0.7)))
        .shadow(color: .ink.opacity(0.16), radius: 12, y: 6)
        .padding(.bottom, 12)
    }

    /// After "Done", the fun mark is offered once, for 10 seconds (docs/concepts.md, sync 4).
    private func recorded(_ id: String) {
        show(Toast(kind: .fun(id: id)), seconds: 10)
    }

    /// The entry goes at once; "Undo" stays for 6 seconds, and the removal is sent after it.
    private func removeWithUndo(_ id: String) {
        store.remove(id, undo: 6)
        show(Toast(kind: .undo(id: id)), seconds: 6)
    }

    private func show(_ next: Toast, seconds: Double) {
        toast = next
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if toast?.id == next.id { toast = nil }
        }
    }

    private func toastView(_ toast: Toast) -> some View {
        HStack(spacing: 12) {
            switch toast.kind {
            case .fun(let id):
                Text("Fun?")
                ForEach(Fun.allCases, id: \.self) { fun in
                    Button(fun.rawValue) {
                        store.mark(id, fun: fun)
                        self.toast = nil
                    }
                    .font(.system(size: 13)).foregroundStyle(Color.pondBackground)
                    .padding(.horizontal, 8).frame(minWidth: tap, minHeight: tap)
                    .overlay(Capsule().strokeBorder(Color.pondBackground.opacity(0.4)))
                }
            case .undo(let id):
                Text("Removed")
                Button("Undo") {
                    store.restore(id)
                    self.toast = nil
                }
                .foregroundStyle(Color.pondBackground).padding(.horizontal, 16).frame(minHeight: tap)
                .overlay(Capsule().strokeBorder(Color.pondBackground))
            }
        }
        .foregroundStyle(Color.pondBackground)
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
        .background(Capsule().fill(Color.ink))
        .shadow(color: .ink.opacity(0.16), radius: 12, y: 6)
    }
}
