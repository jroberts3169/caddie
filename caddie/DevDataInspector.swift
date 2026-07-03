//
//  DevDataInspector.swift
//  caddie
//
//  Developer-only JSON inspector. Renders any `Encodable` value (e.g. the built
//  `OSMCourse`) as a collapsible outline tree with search, expand/collapse-all and
//  copy-to-clipboard, presented as a resizable trailing side panel over the map.
//
//  The entire file is gated behind `#if DEBUG` so none of it — the model, the views
//  or the panel — is compiled into a release build.
//

#if DEBUG

import SwiftUI

// MARK: - JSON value model

/// A parsed, order-preserving JSON value. Objects keep their keys sorted for a
/// stable tree; arrays keep their natural order. `number` is stored as its string
/// form so `1` and `1.0` render as they were serialized rather than being coerced
/// through `Double`.
indirect enum JSONValue {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    /// Encodes any `Encodable` into a `JSONValue`, or a `.string` describing the
    /// failure so the inspector always shows *something* rather than blanking out.
    static func encoding<T: Encodable>(_ value: T) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .string("<unencodable \(type(of: value))>")
        }
        return make(from: any)
    }

    private static func make(from any: Any) -> JSONValue {
        switch any {
        case let dict as [String: Any]:
            let entries = dict.keys.sorted().map { (key: $0, value: make(from: dict[$0]!)) }
            return .object(entries)
        case let array as [Any]:
            return .array(array.map { make(from: $0) })
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.stringValue)
        case let string as String:
            return .string(string)
        case is NSNull:
            return .null
        default:
            return .string(String(describing: any))
        }
    }

    var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    /// A one-line summary shown next to a collapsed container ("{5}", "[128]").
    var collapsedSummary: String {
        switch self {
        case .object(let entries): return "{\(entries.count)}"
        case .array(let items): return "[\(items.count)]"
        default: return ""
        }
    }

    /// The rendered value text for a leaf (quoted strings, bare numbers/bools/null).
    var leafText: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .object, .array: return collapsedSummary
        }
    }

    var leafColor: Color {
        switch self {
        case .string: return .green
        case .number: return .orange
        case .bool: return .purple
        case .null: return .secondary
        case .object, .array: return .secondary
        }
    }

    /// Whether this node, or any descendant, matches `term` in a key or leaf value.
    /// `key` is this node's own key (nil for the root / array elements).
    func matches(_ term: String, key: String?) -> Bool {
        if let key, key.localizedCaseInsensitiveContains(term) { return true }
        switch self {
        case .object(let entries):
            return entries.contains { $0.value.matches(term, key: $0.key) }
        case .array(let items):
            return items.contains { $0.matches(term, key: nil) }
        case .string(let s):
            return s.localizedCaseInsensitiveContains(term)
        case .number(let n):
            return n.localizedCaseInsensitiveContains(term)
        case .bool(let b):
            return (b ? "true" : "false").localizedCaseInsensitiveContains(term)
        case .null:
            return "null".localizedCaseInsensitiveContains(term)
        }
    }

    /// Collects the path of every container node under `path` for expand-all.
    func containerPaths(at path: String, into set: inout Set<String>) {
        switch self {
        case .object(let entries):
            set.insert(path)
            for entry in entries {
                entry.value.containerPaths(at: path + "/" + entry.key, into: &set)
            }
        case .array(let items):
            set.insert(path)
            for (index, item) in items.enumerated() {
                item.containerPaths(at: path + "/[\(index)]", into: &set)
            }
        default:
            break
        }
    }
}

// MARK: - Inspector state

/// Tracks which container paths are expanded, plus the live search term. Kept as an
/// `@Observable` so node rows can toggle their own disclosure without re-rendering
/// siblings, and expand/collapse-all can mutate the whole set at once.
@Observable
final class DevInspectorState {
    var expandedPaths: Set<String> = ["root"]
    var searchText: String = ""

    func isExpanded(_ path: String) -> Bool { expandedPaths.contains(path) }

    func setExpanded(_ path: String, _ expanded: Bool) {
        if expanded { expandedPaths.insert(path) } else { expandedPaths.remove(path) }
    }

    func expandAll(_ root: JSONValue) {
        var set: Set<String> = []
        root.containerPaths(at: "root", into: &set)
        expandedPaths = set
    }

    func collapseAll() {
        expandedPaths = ["root"]
    }
}

// MARK: - Panel

/// A named `Encodable` payload the inspector can display. Encoding happens up front
/// so switching sources is instant.
struct DevInspectorSource: Identifiable {
    /// Stable identity derived from the source name so re-selection survives the
    /// parent view rebuilding this list (e.g. on every map hover). A random UUID
    /// here would reset the picker to the first source on each rebuild.
    var id: String { name }
    let name: String
    let value: JSONValue
    let rawText: String

    init<T: Encodable>(name: String, _ value: T) {
        self.name = name
        self.value = .encoding(value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.rawText = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// Reference-type memo for a view's encoded inspector sources. Held in `@State` so
/// the expensive `DevInspectorSource` encoding survives `body` re-evaluations and
/// only reruns when `key` changes. A class (not a value) so mutating it during a
/// `body` read doesn't invalidate the view and cause a re-render loop.
final class InspectorSourceCache {
    var key: String = ""
    var sources: [DevInspectorSource] = []
}

/// The resizable trailing dev panel: source picker, search, tree, and a footer of
/// tree/clipboard actions.
struct DevDataInspectorPanel: View {
    let sources: [DevInspectorSource]
    @Binding var isPresented: Bool

    @State private var selectedSourceID: String?
    @State private var state = DevInspectorState()

    private var selectedSource: DevInspectorSource? {
        sources.first { $0.id == selectedSourceID } ?? sources.first
    }

    var body: some View {
        VStack {
            if let source = selectedSource {
                searchField
                treeScroll(for: source)
                footer(for: source)
            } else {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "curlybraces",
                    description: Text("Select a course to inspect its data.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .inspectorColumnWidth(min: 280, ideal: 380, max: 720)
        .onChange(of: sources.map(\.id)) {
            // Keep the selection valid as courses come and go; default to the first.
            if selectedSource == nil { selectedSourceID = sources.first?.id }
        }
        .onAppear { selectedSourceID = sources.first?.id }
    }

    @ViewBuilder
    private var searchField: some View {
        if sources.count > 1 {
            Picker("Source", selection: Binding(
                get: { selectedSource?.id ?? sources.first?.id },
                set: { selectedSourceID = $0 }
            )) {
                ForEach(sources) { source in
                    Text(source.name).tag(Optional(source.id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        TextField("Filter keys and values", text: $state.searchText)
    }

    private func treeScroll(for source: DevInspectorSource) -> some View {
        let term = state.searchText.trimmingCharacters(in: .whitespaces)
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                JSONNodeView(
                    key: source.name,
                    value: source.value,
                    path: "root",
                    depth: 0,
                    searchTerm: term.isEmpty ? nil : term,
                    state: state
                )
            }
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
        }
    }

    private func footer(for source: DevInspectorSource) -> some View {
        HStack {
            Button("Expand") { state.expandAll(source.value) }
            Button("Collapse") { state.collapseAll() }
            Spacer()
            Button("Copy JSON") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.rawText, forType: .string)
            }
        }
    }
}

// MARK: - Tree node

/// One row in the JSON tree. Containers are `DisclosureGroup`s bound to the shared
/// state; leaves are a single `key: value` line. When a search term is active, only
/// matching nodes (and their ancestors) render, and ancestors force-expand so hits
/// are always visible.
private struct JSONNodeView: View {
    let key: String
    let value: JSONValue
    let path: String
    let depth: Int
    let searchTerm: String?
    let state: DevInspectorState

    /// Cap children rendered per array so a boundary ring of thousands of points
    /// can't stall the tree; the remainder is summarized in a trailing row.
    private static let childLimit = 200

    var body: some View {
        if let term = searchTerm, !value.matches(term, key: key) {
            EmptyView()
        } else {
            switch value {
            case .object(let entries):
                container(childCount: entries.count) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        JSONNodeView(
                            key: entry.key,
                            value: entry.value,
                            path: path + "/" + entry.key,
                            depth: depth + 1,
                            searchTerm: searchTerm,
                            state: state
                        )
                    }
                }
            case .array(let items):
                container(childCount: items.count) {
                    let shown = min(items.count, Self.childLimit)
                    ForEach(0..<shown, id: \.self) { index in
                        JSONNodeView(
                            key: "\(index)",
                            value: items[index],
                            path: path + "/[\(index)]",
                            depth: depth + 1,
                            searchTerm: searchTerm,
                            state: state
                        )
                    }
                    if items.count > shown {
                        Text("… \(items.count - shown) more")
                    }
                }
            default:
                leafRow
            }
        }
    }

    @ViewBuilder
    private func container<Content: View>(childCount: Int, @ViewBuilder content: @escaping () -> Content) -> some View {
        // Force-open while searching so matched descendants are visible; otherwise
        // follow the shared expanded set.
        let binding = searchTerm == nil
            ? Binding(get: { state.isExpanded(path) }, set: { state.setExpanded(path, $0) })
            : .constant(true)
        DisclosureGroup(isExpanded: binding) {
            VStack(alignment: .leading, spacing: 2) {
                content()
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 4) {
                Text(key)
                Text(value.collapsedSummary)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var leafRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(key + ":")
                .foregroundStyle(.secondary)
            Text(value.leafText)
                .foregroundStyle(value.leafColor)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif
