import SwiftUI

struct ReviewView: View {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app
    @Environment(AgentSession.self) private var agent
    @AppStorage("reviewDays") private var days = 7

    var body: some View {
        let summary = store.review(days: days)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stats(summary)

                HStack(alignment: .top, spacing: 16) {
                    experiments(summary)
                    coding(summary)
                }

                attention(summary)
                projects
                activity(summary)
            }
            .padding(20)
        }
        .navigationTitle("Review")
        .navigationSubtitle("Since \(summary.since.formatted(date: .abbreviated, time: .omitted))")
        .toolbar {
            ToolbarItem {
                Picker("Range", selection: $days) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button {
                    app.showAgent = true
                    agent.send("Review my progress over the last \(days) days. Cover what moved forward, experiment results and outcomes, the state of coding work, anything blocked, stale, or overdue, and suggest what I should focus on next. Don't change any items unless I ask.")
                } label: {
                    Label("Write Review with Assistant", systemImage: "text.badge.star")
                }
                .disabled(agent.isRunning)
                .help("Have the assistant write a progress review")
            }
        }
    }

    // MARK: Cards

    private func stats(_ s: ReviewSummary) -> some View {
        HStack(spacing: 12) {
            StatTile(title: "Completed", value: s.completed.count, symbol: "checkmark.circle", color: .green)
            StatTile(title: "Added", value: s.created.count, symbol: "plus.circle", color: .blue)
            StatTile(title: "Running", value: s.runningExperiments.count, symbol: "flask", color: .purple)
            StatTile(title: "Blocked", value: s.blocked.count, symbol: "exclamationmark.octagon", color: s.blocked.isEmpty ? .secondary : .red)
            StatTile(title: "Overdue", value: s.overdue.count, symbol: "calendar.badge.exclamationmark", color: s.overdue.isEmpty ? .secondary : .orange)
        }
    }

    private func experiments(_ s: ReviewSummary) -> some View {
        Card(title: "Experiments", symbol: ItemKind.experiment.symbol, color: ItemKind.experiment.color) {
            group("Running", s.runningExperiments) { item in
                if let start = item.runStartedAt {
                    Text("since \(start.formatted(.relative(presentation: .named)))")
                }
            }
            group("Analyzing", s.analyzingExperiments) { _ in EmptyView() }
            group("Concluded", s.concludedExperiments) { item in
                Label(item.outcome.label, systemImage: item.outcome.symbol).foregroundStyle(item.outcome.color)
            }
            group("Planned", Array(s.plannedExperiments.prefix(5))) { _ in EmptyView() }
            if s.runningExperiments.isEmpty && s.analyzingExperiments.isEmpty && s.concludedExperiments.isEmpty && s.plannedExperiments.isEmpty {
                EmptyLine("No experiments in flight.")
            }
        }
    }

    private func coding(_ s: ReviewSummary) -> some View {
        Card(title: "Coding", symbol: ItemKind.coding.symbol, color: ItemKind.coding.color) {
            if s.activeCoding.isEmpty {
                EmptyLine("No coding work in progress.")
            }
            ForEach(s.activeCoding) { item in
                VStack(alignment: .leading, spacing: 3) {
                    ReviewItemLine(item: item) {
                        Text(item.statusLabel).foregroundStyle(item.status.color)
                    }
                    let p = item.checklistProgress
                    if p.total > 0 {
                        ProgressView(value: Double(p.done), total: Double(p.total)) {
                            EmptyView()
                        } currentValueLabel: {
                            Text("\(p.done)/\(p.total) steps").font(.caption2)
                        }
                        .controlSize(.small)
                        .tint(ItemKind.coding.color)
                    }
                }
            }
            let mergedCount = s.completed.filter { $0.kind == .coding }.count
            if mergedCount > 0 {
                Text("\(mergedCount) coding item\(mergedCount == 1 ? "" : "s") finished in this period")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func attention(_ s: ReviewSummary) -> some View {
        let all = (s.blocked + s.overdue + s.stale).reduce(into: [Item]()) { acc, item in
            if !acc.contains(where: { $0.id == item.id }) { acc.append(item) }
        }
        Card(title: "Needs Attention", symbol: "exclamationmark.triangle", color: all.isEmpty ? .secondary : .orange) {
            if all.isEmpty {
                EmptyLine("Nothing blocked, overdue, or stale.")
            }
            ForEach(all) { item in
                ReviewItemLine(item: item) {
                    HStack(spacing: 6) {
                        if item.status == .blocked { Text("Blocked").foregroundStyle(.red) }
                        if item.isOverdue { Text("Overdue").foregroundStyle(.orange) }
                        if s.stale.contains(where: { $0.id == item.id }) {
                            Text("No update \(item.updatedAt.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var projects: some View {
        Card(title: "Projects", symbol: "folder", color: .blue) {
            let active = store.projects.filter { $0.status == .active }
            if active.isEmpty {
                EmptyLine("No active projects.")
            }
            ForEach(ProjectType.allCases) { type in
                let group = active.filter { $0.type == type }
                if !group.isEmpty {
                    Label(type.label, systemImage: type.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(group) { project in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                app.selection = .project(project.id)
                            } label: {
                                Label(project.name, systemImage: project.symbol)
                                    .foregroundStyle(project.swiftColor)
                                    .font(.body.weight(.medium))
                            }
                            .buttonStyle(.plain)
                            ProjectProgress(project: project)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func activity(_ s: ReviewSummary) -> some View {
        Card(title: "Activity", symbol: "clock.arrow.circlepath", color: .secondary) {
            if s.logs.isEmpty {
                EmptyLine("No activity in this period.")
            }
            let grouped = Dictionary(grouping: s.logs.prefix(150)) { Calendar.current.startOfDay(for: $0.createdAt) }
            ForEach(grouped.keys.sorted(by: >), id: \.self) { day in
                Text(day.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(grouped[day] ?? []) { entry in
                    LogRow(entry: entry, itemTitle: store.item(entry.itemID)?.title ?? store.project(entry.projectID)?.name)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let id = entry.itemID, let item = store.item(id) {
                                app.selection = .kind(item.kind)
                                app.selectedItemID = id
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func group<Accessory: View>(_ title: String, _ items: [Item], @ViewBuilder accessory: @escaping (Item) -> Accessory) -> some View {
        if !items.isEmpty {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items) { item in
                ReviewItemLine(item: item) { accessory(item) }
            }
        }
    }
}

// MARK: - Building blocks

struct ReviewItemLine<Accessory: View>: View {
    let item: Item
    @ViewBuilder var accessory: Accessory
    @Environment(AppState.self) private var app
    @Environment(Store.self) private var store

    var body: some View {
        Button {
            app.selection = .kind(item.kind)
            app.selectedItemID = item.id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.kind.symbol).foregroundStyle(item.kind.color).frame(width: 16)
                Text(item.title).lineLimit(1)
                if let p = store.project(item.projectID) {
                    Text(p.name).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                accessory.font(.caption).lineLimit(1).fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    let color: Color
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(color)
        }
    }
}

struct StatTile: View {
    let title: String
    let value: Int
    let symbol: String
    let color: Color

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol).foregroundStyle(color)
                Text("\(value)").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

struct EmptyLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).foregroundStyle(.secondary).font(.callout)
    }
}
