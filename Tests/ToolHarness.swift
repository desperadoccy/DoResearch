// Headless check of the store and agent tools: scripts/test.sh
import Foundation

@main
struct ToolHarness {
    @MainActor static func main() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dr-harness-\(UUID().uuidString).sqlite")
        let store = Store(url: url)
        let tools = AgentTools(store: store)
        var failures = 0

        func call(_ name: String, _ input: [String: Any]) -> [String: Any] {
            let out = tools.run(name: name, input: input)
            print("• \(name): \(out.summary)\(out.isError ? "  [error]" : "")")
            if out.isError { print("    \(out.result)") }
            return (try? JSONSerialization.jsonObject(with: Data(out.result.utf8))) as? [String: Any] ?? ["error": out.result]
        }
        func expect(_ ok: Bool, _ what: String) {
            if !ok { failures += 1; print("  ✗ \(what)") } else { print("  ✓ \(what)") }
        }

        // Tool schemas must serialize for the API.
        expect((try? JSONSerialization.data(withJSONObject: AgentTools.definitions)) != nil, "tool definitions serialize to JSON")

        let proj = call("create_project", ["name": "Sparse Attention Paper", "deadline": "2026-11-15", "symbol": "brain"])
        let pid = ((proj["created"] as? [String: Any])?["id"] as? String) ?? ""
        expect(!pid.isEmpty, "project created")

        let code = call("create_item", ["title": "Implement block-sparse kernel", "kind": "coding", "project_id": pid,
                                        "branch": "feat/sparse", "checklist": ["forward", "backward", "tests"], "status": "in_progress"])
        let cid = ((code["created"] as? [String: Any])?["id"] as? String) ?? ""
        expect(store.item(cid)?.checklist.count == 3, "coding item has 3 checklist steps")

        let exp = call("create_item", ["title": "Ablation: sparsity 0.5 vs 0.9", "kind": "experiment", "project_id": pid,
                                       "hypothesis": "ppl within 2%", "status": "in_progress"])
        let eid = ((exp["created"] as? [String: Any])?["id"] as? String) ?? ""
        expect(store.item(eid)?.runStartedAt != nil, "running experiment gets a run start time")

        _ = call("update_checklist", ["item_id": cid, "check": ["Forward", "backward"]])
        expect(store.item(cid)?.checklistProgress.done == 2, "two steps checked (case-insensitive match)")

        _ = call("update_item", ["id": eid, "status": "waiting", "metrics": [["name": "ppl", "value": "18.9"], ["name": "speedup", "value": 1.8]],
                                 "results": "0.9 sparsity: +1.4% ppl", "log": "Run finished on 4xA100"])
        let e = store.item(eid)
        expect(e?.status == .waiting && e?.runEndedAt != nil, "experiment moved to Analyzing with run end time")
        expect(e?.metrics.count == 2 && e?.metrics.last?.value == "1.8", "numeric metric value coerced to string")
        let logs = store.logs(forItem: eid)
        expect(logs.contains { $0.author == .agent && $0.kind == "status" }, "status change logged as agent")
        expect(logs.contains { $0.kind == "note" && $0.text.contains("4xA100") }, "progress note logged")

        _ = call("update_item", ["id": eid, "due_date": "2026-10-20"])
        _ = call("update_item", ["id": eid, "due_date": ""])
        expect(store.item(eid)?.dueDate == nil, "empty string clears due date")

        // Validation errors come back as tool errors, not crashes.
        let bad1 = tools.run(name: "update_item", input: ["id": "nope"])
        expect(bad1.isError, "unknown id rejected")
        let bad2 = tools.run(name: "create_item", input: ["title": "x", "kind": "experiment", "status": "running"])
        expect(bad2.isError, "invalid status rejected")
        let bad3 = tools.run(name: "update_item", input: ["id": cid, "today": "yes"])
        expect(bad3.isError, "non-boolean today rejected")
        let bad4 = tools.run(name: "create_item", input: ["kind": "coding"])
        expect(bad4.isError, "missing title rejected")

        let list = call("list_items", ["kind": "experiment"])
        expect((list["total"] as? Int) == 1, "list_items filters by kind")
        let projects = call("list_projects", [:])
        expect(((projects["projects"] as? [[String: Any]])?.first?["progress"] as? [String: String])?["coding"] == "0/1 done", "project progress counts")

        let review = call("review_summary", ["days": 7])
        let exps = review["experiments"] as? [String: Any]
        expect((exps?["analyzing"] as? [[String: Any]])?.count == 1, "review lists analyzing experiment")
        expect(((review["coding_active"] as? [[String: Any]])?.count ?? 0) == 1, "review lists active coding")

        let detail = call("get_item", ["id": eid])
        expect((detail["log"] as? [[String: Any]])?.isEmpty == false, "get_item includes the log")

        // Reload from disk and confirm persistence.
        let reopened = Store(url: url)
        expect(reopened.items.count == 2 && reopened.item(cid)?.checklistProgress.done == 2, "data persists across reopen")

        try? FileManager.default.removeItem(at: url)

        // MARK: Ordering, moving, copying
        print("\n— ordering & clipboard —")
        let url2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dr-harness-\(UUID().uuidString).sqlite")
        let s2 = Store(url: url2)
        let a = s2.createItem(Item(id: "", title: "A", kind: .coding))
        let b = s2.createItem(Item(id: "", title: "B", kind: .coding))
        let c = s2.createItem(Item(id: "", title: "C", kind: .coding))
        func codingOrder() -> [String] { s2.items(for: .kind(.coding), order: .manual).map(\.title) }
        expect(codingOrder() == ["C", "B", "A"], "new items go on top (got \(codingOrder()))")

        s2.reorder([c.id], before: nil, within: s2.items(for: .kind(.coding), order: .manual))
        expect(codingOrder() == ["B", "A", "C"], "move to end (got \(codingOrder()))")
        s2.reorder([c.id], before: a.id, within: s2.items(for: .kind(.coding), order: .manual))
        expect(codingOrder() == ["B", "C", "A"], "move between (got \(codingOrder()))")
        s2.reorder([a.id, b.id], before: c.id, within: s2.items(for: .kind(.coding), order: .manual))
        expect(codingOrder() == ["A", "B", "C"], "multi-move keeps given order (got \(codingOrder()))")
        let updatedBefore = s2.item(a.id)!.updatedAt
        for _ in 0..<60 {  // force repeated halving until positions get renumbered
            s2.reorder([c.id], before: b.id, within: s2.items(for: .kind(.coding), order: .manual))
            s2.reorder([b.id], before: c.id, within: s2.items(for: .kind(.coding), order: .manual))
        }
        expect(codingOrder() == ["A", "B", "C"], "order survives renumbering (got \(codingOrder()))")
        expect(s2.item(a.id)!.updatedAt == updatedBefore, "reordering doesn't bump updatedAt")

        // A stale copy saved after a reorder must not undo the reorder.
        var stale = s2.item(a.id)!
        s2.reorder([a.id], before: nil, within: s2.items(for: .kind(.coding), order: .manual))
        stale.notes = "edited"
        s2.updateItem(stale)
        expect(codingOrder().last == "A", "edit from stale copy keeps new position")

        // Move into an experiment section with placement.
        let moved = s2.place([s2.item(b.id)!], copy: false, placement: Placement(kind: .experiment).merged(with: Placement(status: .inProgress)),
                             before: nil, within: s2.items(for: .kind(.experiment), order: .manual))
        let bm = s2.item(b.id)!
        expect(moved == [b.id] && bm.kind == .experiment && bm.status == .inProgress && bm.runStartedAt != nil,
               "move applies kind + status (and starts the run)")
        expect(s2.logs(forItem: b.id).contains { $0.kind == "status" }, "move logs the status change")

        // Copy into a project: original unchanged, copy placed with checklist preserved.
        let proj2 = s2.createProject(Project(id: "", name: "P"))
        s2.addChecklistEntry(to: c.id, title: "step 1")
        var cc = s2.item(c.id)!.checklist[0]; cc.done = true; s2.updateChecklistEntry(cc)
        let copies = s2.place([s2.item(c.id)!], copy: true, placement: SidebarSelection.project(proj2.id).placement, before: nil, within: nil)
        let copy = s2.item(copies.first)
        expect(copy != nil && copy!.id != c.id && copy!.projectID == proj2.id && s2.item(c.id)!.projectID == nil, "copy goes to project, original stays")
        expect(copy?.checklist.first?.done == true, "copy keeps checklist state")

        // Today placement triages inbox items.
        let inboxItem = s2.createItem(Item(id: "", title: "triage me", status: .inbox))
        s2.place([inboxItem], copy: false, placement: SidebarSelection.today.placement, before: nil, within: nil)
        expect(s2.item(inboxItem.id)!.status == .todo && s2.item(inboxItem.id)!.flaggedToday, "dropping on Today flags and triages")

        // Duplicate lands right after the original.
        let dups = s2.duplicate([a.id])
        let manual = s2.items.sorted(by: Store.manualOrder).map(\.id)
        expect(dups.count == 1 && manual.firstIndex(of: dups[0]) == manual.firstIndex(of: a.id)! + 1, "duplicate sits after original")

        // Text & clipboard formats.
        let parsed = ItemTransfer.parse("- [ ] Run ablation\n* [x] Fix loader\n\n3) Read paper\n   plain line  ")
        expect(parsed.map(\.title) == ["Run ablation", "Fix loader", "Read paper", "plain line"], "parses bullets, numbers, checkboxes")
        expect(parsed.map(\.status) == [.todo, .done, .todo, .todo], "checkbox state becomes status")
        let roundTrip = ItemTransfer.parse(ItemTransfer(items: parsed).plainText).map(\.title)
        expect(roundTrip == parsed.map(\.title), "plain text round-trips")
        let data = try? JSONEncoder().encode(ItemTransfer(items: [s2.item(c.id)!]))
        let decoded = data.flatMap { try? JSONDecoder().decode(ItemTransfer.self, from: $0) }
        expect(decoded?.items.first == s2.item(c.id), "item snapshot round-trips through JSON")
        let pasted = s2.place(parsed, copy: true, placement: SidebarSelection.inbox.placement, before: nil, within: nil)
        expect(pasted.count == 4 && pasted.allSatisfy { s2.item($0)?.status == .inbox }, "pasted text lands in inbox")
        try? FileManager.default.removeItem(at: url2)

        // MARK: Migration from schema v1 seeds positions from the old automatic order.
        let url3 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dr-harness-\(UUID().uuidString).sqlite")
        do {
            let db = try Database(url: url3)
            try db.execute("DROP INDEX idx_items_position")
            try db.execute("ALTER TABLE items DROP COLUMN position")
            try db.execute("PRAGMA user_version = 1")
            let now = Date().timeIntervalSince1970
            for (id, prio, created) in [("low", 1, now), ("high", 3, now - 100), ("mid", 2, now - 50)] {
                try db.execute("INSERT INTO items (id, title, kind, status, priority, created_at, updated_at) VALUES (?,?,?,?,?,?,?)",
                               [id, id, "task", "todo", prio, created, created])
            }
        } catch { expect(false, "set up v1 database: \(error)") }
        let migrated = Store(url: url3)
        expect(migrated.items(for: .all, order: .manual).map(\.id) == ["high", "mid", "low"], "v1 → v2 keeps priority order as manual order")
        try? FileManager.default.removeItem(at: url3)

        await ProviderHarness.run(expect: expect)

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
