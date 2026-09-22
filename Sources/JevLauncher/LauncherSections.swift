import CoreGraphics

/// Result groups, in the words the list shows above each group.
enum LauncherGroup: Hashable {
    case favourites, recent, applications, commands, files, clipboard
    var title: String {
        switch self {
        case .favourites: return "Favourites"
        case .recent: return "Recent"
        case .applications: return "Applications"
        case .commands: return "Commands"
        case .files: return "Files"
        case .clipboard: return "Clipboard"
        }
    }
}

/// One table row: a non-selectable section label or a result.
enum LauncherRow: Identifiable {
    case section(LauncherGroup)
    case result(LauncherResult)
    var id: String {
        switch self {
        case .section(let group): return "section:" + group.title
        case .result(let result): return result.id
        }
    }
    var result: LauncherResult? {
        if case .result(let result) = self { return result }
        return nil
    }
    /// Cell height, without the table's row spacing.
    var height: CGFloat {
        switch self {
        case .section: return LauncherMetrics.sectionHeight
        case .result(let result): return result.isTwoLine ? LauncherMetrics.tallCellHeight : LauncherMetrics.cellHeight
        }
    }
}

enum LauncherSections {
    /// Most files a mixed (not explicitly file) search shows.
    static let mixedFileLimit = 3

    /// Groups results that arrive in rank order. The top hit's group comes
    /// first, and later groups follow the rank of their best result, so the
    /// first result in the flattened order is always the top hit. Within a
    /// group, rank order holds. `fileLimit` caps the Files group.
    static func group(_ ranked: [LauncherResult], fileLimit: Int? = nil) -> [(group: LauncherGroup, results: [LauncherResult])] {
        var order: [LauncherGroup] = []
        var members: [LauncherGroup: [LauncherResult]] = [:]
        for result in ranked {
            let group = result.group
            if group == .files, let fileLimit, members[group, default: []].count >= fileLimit { continue }
            if members[group] == nil { order.append(group) }
            members[group, default: []].append(result)
        }
        return order.map { ($0, members[$0] ?? []) }
    }

    /// Table rows for grouped results. Labels appear only when more than one group is present.
    static func rows(_ groups: [(group: LauncherGroup, results: [LauncherResult])]) -> [LauncherRow] {
        let labelled = groups.count > 1
        return groups.flatMap { entry -> [LauncherRow] in
            (labelled ? [.section(entry.group)] : []) + entry.results.map(LauncherRow.result)
        }
    }

    /// Height of the rows, including the table's per-row spacing. Past the
    /// maximum, the list stops at the last whole row, never on a section
    /// label, and scrolls for the rest.
    static func listHeight(_ rows: [LauncherRow]) -> CGFloat {
        var height: CGFloat = 0
        var lastResultEnd: CGFloat = 0
        for row in rows {
            let next = height + row.height + LauncherMetrics.rowSpacing
            guard next <= LauncherMetrics.maxListHeight else { return lastResultEnd }
            height = next
            if row.result != nil { lastResultEnd = height }
        }
        return height
    }
}
