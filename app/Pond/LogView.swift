import PondKit
import SwiftUI

/// The log (docs/concepts.md, Stream): your entries, newest first, as the stream at teoyujie.org/log shows them.
/// The phone lists its own journal, so an entry shows at once, also while it waits to be sent. A tap opens the entry sheet.
struct LogView: View {
    @Environment(Store.self) private var store
    let open: (Record) -> Void

    var body: some View {
        let records = store.journal.records.filter { !$0.removed }
            .enumerated().sorted { ($0.element.entry.date, $0.offset) > ($1.element.entry.date, $1.offset) }.map(\.element)
        VStack(alignment: .leading, spacing: 0) {
            Text("Log").font(.serif(32))
            Text("What you read, watch, attend and make, newest first. Other people follow it on the web and with RSS.")
                .font(.system(size: 15)).foregroundStyle(Color.muted).padding(.top, 4)
            HStack(spacing: 8) {
                Link("teoyujie.org/log ↗", destination: store.server.appending(path: "log/"))
                Link("RSS ↗", destination: store.server.appending(path: "log/feed.xml"))
            }
            .buttonStyle(PillStyle(kind: .quiet, size: 15)).padding(.top, 12).padding(.bottom, 16)
            if records.isEmpty {
                Text("Nothing yet. \"Done\" on a choice puts it here.").font(.system(size: 15)).foregroundStyle(Color.muted)
            }
            ForEach(records) { record in
                Button { open(record) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind(record)).font(.system(size: 13)).foregroundStyle(Color.muted)
                        Text(record.entry.title).font(.serif(18.5)).multilineTextAlignment(.leading)
                        if let made = record.entry.made {
                            Text(made).font(.system(size: 15)).multilineTextAlignment(.leading)
                        }
                        if let host = record.entry.link?.host() {
                            Text(host.replacing(/^www\./, with: "")).font(.system(size: 13)).foregroundStyle(Color.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: tap, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("log \(record.entry.title)")
            }
        }
    }

    /// "28 Oct · Paper · Math", "27 Oct · Noticed" or "26 Oct · Music · live", as on the stream, and the state of the send.
    private func kind(_ record: Record) -> String {
        let entry = record.entry
        var parts = [LogView.date(entry.date)]
        if entry.kind == .note {
            parts.append("Noticed")
        } else if let interest = entry.interest {
            parts += ["Paper", interest]
        } else {
            parts += [store.domainName(entry.domain), entry.mode?.label].compactMap { $0 }
        }
        if record.refused { parts.append("not accepted") } else if record.waiting { parts.append("waiting") }
        return parts.joined(separator: " · ")
    }

    /// The stream at teoyujie.org/log is in English, so the log is too.
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "2026-10-28" gives "28 Oct".
    static func date(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return day }
        return "\(parts[2]) \(months[parts[1] - 1])"
    }
}
