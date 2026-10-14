import AppKit
import PlanisphereGrapheine
import SwiftUI

/// The Measure section of the graph inspector: one reading of the vault's link
/// graph, taken by Grapheine on a private copy. Headline counts, one sentence
/// of what they mean, the degree shape, the bounded ratios as tiles, then the
/// notes that carry the graph. Everything else folds under "All readings".
/// Numbers are the engine's; the view only lays them out.
struct MeasurePanel: View {
    let measurement: GraphMeasurement?
    let measuring: Bool
    let error: String?
    var onMeasure: () -> Void
    var onSelect: (String) -> Void
    @State private var detailsShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                PSSectionLabel(title: "Measure")
                Spacer()
                if measuring { ProgressView().controlSize(.small) }
                else {
                    Button(measurement == nil ? "Measure graph" : "Measure again", systemImage: "chart.bar.xaxis", action: onMeasure)
                        .buttonStyle(PSButtonStyle(primary: measurement == nil)).accessibilityIdentifier("graph-measure-inspector")
                }
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let m = measurement {
                headline(m)
                if let d = m.values.degree { degreeShape(d) }
                tiles(m)
                if let hubs = m.values.degree?.top.prefix(4), !hubs.isEmpty {
                    list(title: "Most connected", footnote: nil) {
                        let top = max(1, hubs.first?.degree ?? 1)
                        ForEach(Array(hubs)) { hub in
                            noteRow(hub.path, trailing: "\(hub.degree ?? 0)", fill: Double(hub.degree ?? 0) / Double(top))
                        }
                    }
                }
                if let bridges = m.values.dirac?.candidates.prefix(3), !bridges.isEmpty {
                    list(title: "Bridges", footnote: "Notes that sit between regions of the graph (Dirac score).") {
                        ForEach(Array(bridges)) { bridge in
                            noteRow(bridge.path, trailing: String(format: "%.2f", bridge.score ?? 0), fill: nil)
                        }
                    }
                }
                DisclosureGroup(isExpanded: $detailsShown) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(MeasurePanel.detailRows(m), id: \.0) { label, value in
                            HStack(alignment: .firstTextBaseline) {
                                Text(label).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(value).monospacedDigit()
                            }.font(.system(size: 11))
                        }
                        ForEach(m.skipped.sorted(by: { $0.key < $1.key }), id: \.key) { name, reason in
                            Text("\(name) skipped: \(reason)").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.top, 6)
                } label: {
                    Text("All readings").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .disclosureGroupStyle(.automatic)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.basis).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Engine \(m.engine) · \(String(format: "%.1f", m.elapsed)) s · scan \(m.fingerprint.prefix(8))")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            } else {
                Text("Degree, density, connectivity, communities and bridges, read from a private copy of your Markdown. Nothing is changed or uploaded.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Headline

    private func headline(_ m: GraphMeasurement) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(m.graph.nodes.formatted()).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                Text("notes").font(.system(size: 13)).foregroundStyle(.secondary)
                Text(m.graph.edges.formatted()).font(.system(size: 26, weight: .semibold)).monospacedDigit().padding(.leading, 6)
                Text("edges").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text(MeasurePanel.shapeSentence(m)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let s = m.values.spectrum, let reading = s.reading {
                HStack(spacing: 6) {
                    Circle().fill(MeasurePanel.readingTone(reading)).frame(width: 7, height: 7)
                    Text(reading.prefix(1).uppercased() + reading.dropFirst()).font(.system(size: 12, weight: .medium))
                    if let fiedler = s.fiedler {
                        Text("· λ₂ " + String(format: "%.3f", fiedler)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    static func shapeSentence(_ m: GraphMeasurement) -> String {
        var parts: [String] = []
        if let c = m.values.components { parts.append(c.components == 1 ? "One connected piece" : "\(c.components) separate pieces") }
        if let h = m.values.health {
            parts.append(h.orphans == 0 ? "no orphans" : "\(h.orphans) orphan\(h.orphans == 1 ? "" : "s")")
            parts.append(h.unresolved == 0 ? "nothing unresolved" : "\(h.unresolved) unresolved link\(h.unresolved == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ") + "."
    }

    static func readingTone(_ reading: String) -> Color {
        let lower = reading.lowercased()
        if lower.contains("healthy") || lower.contains("well") { return Color(red: 0.42, green: 0.72, blue: 0.52) }
        if lower.contains("bottleneck") || lower.contains("narrow") || lower.contains("fragment") { return Color(red: 0.86, green: 0.62, blue: 0.30) }
        return PSStyle.accent
    }

    // MARK: Degree shape

    private func degreeShape(_ d: GraphMeasurement.Degree) -> some View {
        let bins = (d.histogram ?? [:]).compactMap { key, count in Int(key).map { ($0, count) } }.sorted { $0.0 < $1.0 }
        let peak = max(1, bins.map(\.1).max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Degree").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("mean \(String(format: "%.2f", d.mean)) · median \(d.median.formatted()) · max \(d.max)")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            if !bins.isEmpty {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(bins, id: \.0) { degree, count in
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(PSStyle.accent.opacity(0.35 + 0.65 * Double(count) / Double(peak)))
                                .frame(height: max(3, 34 * CGFloat(count) / CGFloat(peak)))
                            Text("\(degree)").font(.system(size: 9)).monospacedDigit().foregroundStyle(.tertiary)
                        }.frame(maxWidth: .infinity)
                        .help("\(count) note\(count == 1 ? "" : "s") with \(degree) link\(degree == 1 ? "" : "s")")
                    }
                }
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
                .background(PSStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSStyle.border))
            }
        }
    }

    // MARK: Tiles

    private func tiles(_ m: GraphMeasurement) -> some View {
        let v = m.values
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            if let d = v.density, let density = d.density {
                tile("Density", value: String(format: "%.3f", density), fill: density, note: "of \(d.max_possible.formatted()) possible")
            }
            if let c = v.clustering {
                tile("Clustering", value: String(format: "%.3f", c.avg_local_clustering), fill: c.avg_local_clustering, note: "\(v.triangles?.triangles.formatted() ?? "—") triangles")
            }
            if let c = v.communities {
                tile("Communities", value: "\(c.communities)", fill: c.modularity.map { max(0, min(1, $0)) }, note: "modularity " + (c.modularity.map { String(format: "%.3f", $0) } ?? "—"))
            }
            if let g = v.girth {
                tile("Girth", value: g.acyclic ? "none" : "\(g.girth ?? 0)", fill: nil, note: g.acyclic ? "no cycles" : "shortest cycle")
            }
        }
    }

    private func tile(_ label: String, value: String, fill: Double?, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            if let fill {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(PSStyle.accent).frame(width: max(2, geo.size.width * CGFloat(fill)))
                    }
                }.frame(height: 3)
            }
            Text(note).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(PSStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSStyle.border))
    }

    // MARK: Lists

    private func list<Content: View>(title: String, footnote: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 2)
            content()
            if let footnote { Text(footnote).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true).padding(.top, 2) }
        }
    }

    private func noteRow(_ path: String, trailing: String, fill: Double?) -> some View {
        MeasureNoteRow(path: path, trailing: trailing, fill: fill) { onSelect(path) }
    }

    static func detailRows(_ m: GraphMeasurement) -> [(String, String)] {
        var rows: [(String, String)] = []
        let v = m.values
        if let c = v.components { rows.append(("Components · isolates", "\(c.components) · \(c.isolates)")) }
        if let h = v.health { rows.append(("Orphans · unresolved", "\(h.orphans) · \(h.unresolved)")) }
        if let h = v.health, let a = h.ambiguous_resolved_occurrences { rows.append(("Ambiguous links resolved", "\(a)")) }
        if let s = v.spectrum, let lam = s.lam_max { rows.append(("Spectrum λmax", String(format: "%.2f", lam))) }
        if let t = v.triangles { rows.append(("Triangles", t.triangles.formatted())) }
        if let b = v.bipartite { rows.append(("Bipartite", b.bipartite ? "yes" : "no (\(b.A)/\(b.B))")) }
        if let p = v.pagerank { rows.append(("PageRank damping", String(format: "%.2f", p.damping))) }
        rows.append(("Link rule", "engine LINK_RULE"))
        return rows
    }
}

private struct MeasureNoteRow: View {
    let path: String
    let trailing: String
    let fill: Double?
    let action: () -> Void
    @State private var hovered = false

    private var name: String { (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "") }
    private var folder: String { (path as NSString).deletingLastPathComponent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(Color(nsColor: GraphPalette.color(for: folder))).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    Text(folder.isEmpty ? "Vault root" : folder).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if let fill {
                    Capsule().fill(PSStyle.accent.opacity(0.75)).frame(width: max(3, 48 * CGFloat(fill)), height: 3)
                }
                Text(trailing).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 26, alignment: .trailing)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.primary.opacity(hovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .help(path).accessibilityLabel("\(name), \(trailing)")
    }
}
