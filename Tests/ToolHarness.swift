// Headless check of the store and agent tools: scripts/test.sh
import Foundation

@main
struct ToolHarness {
    @MainActor static func main() {
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
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
