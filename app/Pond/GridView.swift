import PondKit
import SwiftUI

extension Cell: @retroactive Identifiable {
    public var id: String { "\(domain) \(mode.rawValue)" }
}

/// The yearly grid (#review in the mock-up): one row for each domain, one dot for each mode (docs/concepts.md, Grid).
/// A filled dot is a place where you have been. An empty dot is a place not visited yet: "Pick for today".
struct GridView: View {
    @Environment(Store.self) private var store
    @State private var year = String(Menu.day(.now).prefix(4))
    @State private var open: Cell?
    let picked: () -> Void

    private let column: CGFloat = 52

    var body: some View {
        let cells = Grid.entries(store.journal, year: year)
        let filled = store.plan.domains.reduce(0) { sum, domain in
            sum + Mode.allCases.filter { cells[Cell(domain: domain.number, mode: $0)] != nil }.count
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Grid").font(.serif(32))
                Spacer()
                Picker("Year", selection: $year) {
                    ForEach(Grid.years(store.journal, current: String(store.today.prefix(4))), id: \.self) { Text($0).tag($0) }
                }
                .tint(Color.ink)
            }
            Text("\(filled) of \(store.plan.domains.count * Mode.allCases.count) places in \(year)")
                .font(.serif(18.5)).padding(.top, 4).accessibilityIdentifier("gridCount")
            Text("One row for each kind of media, one dot for each way into it. A filled dot is a place where you have been. Tap a dot.")
                .font(.system(size: 15)).foregroundStyle(Color.muted).padding(.top, 4).padding(.bottom, 16)
            HStack(spacing: 0) {
                Spacer()
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(mode.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.muted)
                        .multilineTextAlignment(.center).frame(width: column)
                }
            }
            .padding(.bottom, 4)
            ForEach(store.plan.domains, id: \.number) { domain in
                HStack(spacing: 0) {
                    Text(domain.name).font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Mode.allCases, id: \.self) { mode in
                        let cell = Cell(domain: domain.number, mode: mode)
                        let count = cells[cell]?.count ?? 0
                        Button { open = cell } label: {
                            Circle().fill(count > 0 ? Color.ink : Color.clear)
                                .overlay(Circle().strokeBorder(count > 0 ? Color.ink : Color.line, lineWidth: 1.5))
                                .frame(width: 22, height: 22)
                                .frame(width: column, height: tap)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(domain.name), \(mode.label)")
                        .accessibilityValue(count > 0 ? "visited" : "not visited yet")
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
            }
        }
        .sheet(item: $open) { cell in
            CellSheet(cell: cell, year: year, records: cells[cell] ?? []) {
                open = nil
                store.pick(cell)
                picked()
            }
        }
    }
}

/// One cell (the cell sheet): its entries, or "Pick for today" for a place not visited yet this year.
private struct CellSheet: View {
    @Environment(Store.self) private var store
    let cell: Cell
    let year: String
    let records: [Record]
    let pick: () -> Void

    var body: some View {
        let domain = store.plan.domains.first { $0.number == cell.domain }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(domain?.name ?? "") · \(cell.mode.label)").font(.serif(24))
                if let examples = domain?.cells[cell.mode] {
                    Text(examples.prefix(1).uppercased() + examples.dropFirst()).font(.system(size: 15)).foregroundStyle(Color.muted)
                }
                if records.isEmpty {
                    Text("Not visited yet in \(year).").font(.system(size: 15)).padding(.top, 8)
                    if year == store.today.prefix(4) {
                        Button("Pick for today", action: pick).buttonStyle(PillStyle(kind: .primary)).padding(.top, 4)
                    }
                } else {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.entry.title).font(.serif(17))
                            Text(record.entry.date).font(.system(size: 13)).foregroundStyle(Color.muted)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .foregroundStyle(Color.ink)
            .padding(16).padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.card)
    }
}
