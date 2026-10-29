import PondKit
import SwiftUI

/// The plan editor (#plan in the mock-up): each slot of the menu, edited in place, with its 7 day buttons
/// (docs/concepts.md, Plan). Each change goes to media-plan.md in the site repo, with no "save" step.
struct PlanView: View {
    @Environment(Store.self) private var store
    @State private var token = ""
    let undo: (String, @escaping @MainActor () -> Void) -> Void

    private var sync: PlanSync { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Plan").font(.serif(32))
            Text("Each slot is a choice on the days that you tap. Tap a slot to change its words. A slot with \"one paper\" offers a paper from your interests.")
                .font(.system(size: 15)).foregroundStyle(Color.muted).padding(.top, 4)
            Text(sync.text).font(.system(size: 13)).foregroundStyle(Color.muted)
                .accessibilityIdentifier("planStatus").padding(.top, 8)
            heading("Every day")
            Text("Daily reads: a row of buttons on Today, on the days that you tap.")
                .font(.system(size: 13)).foregroundStyle(Color.muted).padding(.bottom, 8)
            slots(core: true)
            Button("+ Add a daily read") {
                sync.change { $0.addSlot("New daily read", days: Weekday.workdays, part: .core) }
            }
            .buttonStyle(PillStyle(kind: .quiet, size: 15)).padding(.top, 12)
            heading("Some days")
            slots(core: false)
            Button("+ Add a slot") {
                let today = Weekday(calendarWeekday: Calendar.current.component(.weekday, from: .now))
                sync.change { $0.addSlot("New slot", days: [today]) }
            }
            .buttonStyle(PillStyle(kind: .quiet, size: 15)).padding(.top, 12)
            InterestsSection(undo: undo)
            EventsSection(undo: undo)
            heading("GitHub token")
            if sync.hasToken {
                HStack {
                    Text("Saved in the Keychain, behind Face ID.").font(.system(size: 15)).foregroundStyle(Color.muted)
                    Spacer()
                    Button("Remove token") { sync.removeToken() }.buttonStyle(PillStyle(kind: .quiet, size: 15))
                }
            } else {
                Text("Make a fine-grained token with \"Contents: read and write\" on \(PlanRepo.repo) only.")
                    .font(.system(size: 13)).foregroundStyle(Color.muted).padding(.bottom, 8)
                SecureField("", text: $token).accessibilityLabel("Token").textInputAutocapitalization(.never)
                    .autocorrectionDisabled().modifier(FieldStyle())
                Button("Save token") {
                    let text = token
                    token = ""
                    Task { await sync.saveToken(text) }
                }
                .buttonStyle(PillStyle(kind: .primary, size: 15)).padding(.top, 8)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

extension PlanView {
    /// The weekday core is the "Every day" row (R13). The other slots are the choices of the menu.
    private func slots(core: Bool) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(store.plan.slots.enumerated()).filter { ($0.element.part == .core) == core }, id: \.element.line) { index, slot in
                SlotRow(slot: slot) { text in
                    sync.change { $0.editSlot(index, text: text) }
                } days: { days in
                    sync.change { $0.setDays(index, days) }
                } remove: {
                    let before = sync.plan
                    sync.change { $0.removeSlot(index) }
                    undo(core ? "Daily read removed" : "Slot removed") { sync.change { $0 = before } }
                }
            }
        }
    }
}

func heading(_ text: String) -> some View {
    Text(text).font(.serif(20)).padding(.top, 28).padding(.bottom, 8)
}

/// One slot: its words in place, what you make, its 7 day buttons and "Remove".
private struct SlotRow: View {
    let slot: Slot
    let edit: (String) -> Void
    let days: (Set<Weekday>) -> Void
    let remove: () -> Void
    @State private var draft: String
    @FocusState private var focused: Bool

    init(slot: Slot, edit: @escaping (String) -> Void, days: @escaping (Set<Weekday>) -> Void, remove: @escaping () -> Void) {
        self.slot = slot
        self.edit = edit
        self.days = days
        self.remove = remove
        _draft = State(initialValue: slot.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                TextField("", text: $draft, axis: .vertical)
                    .font(.serif(17)).focused($focused).submitLabel(.done)
                    .accessibilityLabel("Slot")
                    .padding(.top, 10)
                    .onChange(of: draft) {
                        // Return ends the edit: a slot is one line of the file.
                        if draft.contains("\n") {
                            draft = draft.replacingOccurrences(of: "\n", with: "")
                            focused = false
                        }
                    }
                    .onChange(of: focused) {
                        guard !focused else { return }
                        let text = draft.trimmingCharacters(in: .whitespaces)
                        if text.isEmpty { draft = slot.text } else if text != slot.text { edit(text) }
                    }
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.muted)
                        .frame(width: tap, height: tap)
                }
                .accessibilityLabel("Remove slot")
            }
            if let made = slot.made {
                Text("You make: \(made)").font(.system(size: 13)).foregroundStyle(Color.muted)
            }
            DayButtons(days: slot.weekdays, set: days)
        }
        .padding(.leading, 14).padding(.trailing, 4).padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(focused ? Color.ink : Color.line))
        .accessibilityElement(children: .contain).accessibilityIdentifier(slot.text)
        .onChange(of: slot.text) { if !focused { draft = slot.text } }
    }
}

/// The 7 day buttons of a slot, or of the "old" days of the interests. A tap adds the day or takes it away.
struct DayButtons: View {
    let days: Set<Weekday>
    let set: (Set<Weekday>) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Weekday.allCases, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    set(on ? days.subtracting([day]) : days.union([day]))
                } label: {
                    Text(day.rawValue.prefix(1).uppercased()).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(on ? Color.pondBackground : Color.ink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(on ? Color.ink : Color.card))
                        .overlay(Circle().strokeBorder(on ? Color.ink : Color.line))
                        .frame(maxWidth: .infinity, minHeight: tap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.rawValue.capitalized)
                .accessibilityValue(on ? "on" : "off")
            }
        }
    }
}
