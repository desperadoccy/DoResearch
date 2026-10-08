import Foundation

/// Snapshot of research progress over a window, shared by the Review dashboard and the agent's `review_summary` tool.
struct ReviewSummary {
    let days: Int
    let since: Date
    let completed: [Item]
    let created: [Item]
    let runningExperiments: [Item]
    let analyzingExperiments: [Item]
    let plannedExperiments: [Item]
    let concludedExperiments: [Item]
    let activeCoding: [Item]
    let blocked: [Item]
    let overdue: [Item]
    let stale: [Item]
    let logs: [LogEntry]

    static let staleAfterDays = 7
}

extension Store {
    func review(days: Int) -> ReviewSummary {
        let now = Date()
        let since = Calendar.current.startOfDay(for: now).addingTimeInterval(-Double(days - 1) * 86_400)
        let staleCutoff = now.addingTimeInterval(-Double(ReviewSummary.staleAfterDays) * 86_400)
        let open = items.filter { $0.status.isOpen }
        let byRecent: (Item, Item) -> Bool = { $0.updatedAt > $1.updatedAt }

        return ReviewSummary(
            days: days,
            since: since,
            completed: items.filter { $0.status == .done && ($0.completedAt ?? .distantPast) >= since }
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) },
            created: items.filter { $0.createdAt >= since },
            runningExperiments: open.filter { $0.kind == .experiment && $0.status == .inProgress }.sorted(by: byRecent),
            analyzingExperiments: open.filter { $0.kind == .experiment && $0.status == .waiting }.sorted(by: byRecent),
            plannedExperiments: open.filter { $0.kind == .experiment && $0.status == .todo }.sorted(by: Store.sortKey),
            concludedExperiments: items.filter { $0.kind == .experiment && $0.status == .done && ($0.completedAt ?? .distantPast) >= since },
            activeCoding: open.filter { $0.kind == .coding && ($0.status == .inProgress || $0.status == .waiting) }.sorted(by: byRecent),
            blocked: open.filter { $0.status == .blocked },
            overdue: open.filter(\.isOverdue),
            stale: open.filter { [.inProgress, .waiting, .blocked].contains($0.status) && $0.updatedAt < staleCutoff },
            logs: logs(since: since)
        )
    }
}
