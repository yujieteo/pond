import PondKit
import SwiftUI

/// Experiments (#experiment in the mock-up): the starter set, at most one active run, and one optional
/// "What did you notice?" line at the end (docs/concepts.md, Experiment). All of it stays on the phone (R10).
struct ExperimentsView: View {
    @Environment(Store.self) private var store
    @State private var closing = false
    let undo: (String, @escaping @MainActor () -> Void) -> Void

    var body: some View {
        let active = store.experiments.active
        VStack(alignment: .leading, spacing: 0) {
            Text("Experiments").font(.serif(32))
            Text("Try one small practice for a few days, and notice what changes. It is a choice on Today while it runs.")
                .font(.system(size: 15)).foregroundStyle(Color.muted).padding(.top, 4).padding(.bottom, 16)
            VStack(spacing: 12) {
                if let active, let experiment = Experiment.starter(active.experiment) {
                    card(experiment) {
                        Text(progress(active)).font(.system(size: 13)).foregroundStyle(Color.muted)
                            .accessibilityIdentifier("experimentProgress")
                        Button("Close") { closing = true }.buttonStyle(PillStyle(kind: .quiet))
                    }
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.ink, lineWidth: 2))
                }
                ForEach(Experiment.starter.filter { $0.id != active?.experiment }) { experiment in
                    card(experiment) {
                        if active == nil {
                            Button("Start for \(ExperimentLog.days) days") { store.startExperiment(experiment.id) }
                                .buttonStyle(PillStyle(kind: .primary, size: 15))
                        }
                    }
                }
            }
            let earlier = store.experiments.runs.filter { $0.closed != nil }.reversed()
            if !earlier.isEmpty {
                Text("Earlier").font(.serif(20)).padding(.top, 28).padding(.bottom, 8)
                ForEach(Array(earlier.enumerated()), id: \.offset) { _, run in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Experiment.starter(run.experiment)?.title ?? run.experiment) · \(run.start)")
                            .font(.system(size: 13)).foregroundStyle(Color.muted)
                        if let notice = run.notice {
                            Text(notice).font(.serif(17))
                            Text(run.published == nil ? "Private" : "In your log").font(.system(size: 13)).foregroundStyle(Color.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
                }
            }
        }
        .sheet(isPresented: $closing) {
            NoticeSheet { notice, publish in
                closing = false
                store.closeExperiment(notice: notice, publish: publish, undo: 6)
                undo("Experiment closed") { store.reopenExperiment() }
            }
        }
    }

    private func progress(_ run: Run) -> String {
        let done = run.done.count == 1 ? "done on 1 day" : "done on \(run.done.count) days"
        guard let day = run.day(of: store.today) else { return "The \(run.days) days are over · \(done)" }
        return "Day \(day) of \(run.days) · \(done)"
    }

    /// "After How To Get Unstuck, Experiments", with each title as a link. One text, so that it wraps as words.
    private func credit(_ experiment: Experiment) -> AttributedString {
        var text = AttributedString("After ")
        for (index, credit) in experiment.credit.enumerated() {
            if index > 0 { text += AttributedString(", ") }
            var link = AttributedString(credit.title)
            link.link = credit.link
            link.underlineStyle = .single
            link.foregroundColor = Color.ink
            text += link
        }
        return text
    }

    private func card(_ experiment: Experiment, @ViewBuilder controls: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(experiment.title).font(.serif(20))
            if let intro = experiment.intro {
                Text(intro).font(.system(size: 15))
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(experiment.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(experiment.pickOne || experiment.steps.count == 1 ? "•" : "\(index + 1).")
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 15))
                }
            }
            Text(credit(experiment)).font(.system(size: 13)).foregroundStyle(Color.muted).tint(Color.ink)
            controls()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.line))
        .accessibilityElement(children: .contain).accessibilityIdentifier(experiment.id)
    }
}

/// "What did you notice?", asked once when you close a run (docs/concepts.md, sync 8). A swipe down does not close the run.
private struct NoticeSheet: View {
    @State private var line = ""
    let finish: (String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What did you notice?").font(.serif(24))
            TextField("", text: $line, axis: .vertical).lineLimit(2...5).accessibilityLabel("Notice").modifier(FieldStyle())
            Text("An empty line is fine. \"Keep private\" keeps it on this phone. \"Publish\" puts it in your log.")
                .font(.system(size: 13)).foregroundStyle(Color.muted)
            HStack {
                Button("Keep private") { finish(line, false) }.buttonStyle(PillStyle(kind: .quiet))
                Spacer()
                Button("Publish") { finish(line, true) }.buttonStyle(PillStyle(kind: .primary))
                    .disabled(line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Spacer()
        }
        .foregroundStyle(Color.ink)
        .padding(16).padding(.top, 16)
        .presentationDetents([.medium])
        .presentationBackground(Color.card)
    }
}
