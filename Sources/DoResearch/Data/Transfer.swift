import AppKit
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTExportedTypeDeclarations).
    static let doResearchItems = UTType(exportedAs: "com.kr8u7k.doresearch.items", conformingTo: .data)
}

/// Items in flight, used by both drag and drop and the clipboard. Carries full snapshots, so a paste still works
/// after the originals are deleted; ids let a drop or cut-and-paste move the originals instead of copying them.
struct ItemTransfer: Codable, Transferable {
    var items: [Item]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .doResearchItems)
        // Other apps get a Markdown checklist; text dropped from other apps becomes new items.
        ProxyRepresentation(exporting: \.plainText, importing: { (text: String) in ItemTransfer(items: Self.parse(text)) })
    }

    var plainText: String {
        items.map { "- [\($0.status == .done ? "x" : " ")] \($0.title)" }.joined(separator: "\n")
    }

    /// One item per non-empty line. Understands Markdown bullets, numbered lists, and `[ ]`/`[x]` checkboxes.
    static func parse(_ text: String, limit: Int = 200) -> [Item] {
        var result: [Item] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            for prefix in ["- ", "* ", "+ ", "• "] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
                break
            }
            if let match = line.firstMatch(of: #/^\d{1,3}[.)]\s+/#) {
                line = String(line[match.range.upperBound...])
            }
            var done = false
            if let match = line.firstMatch(of: #/^\[([ xX])\]\s*/#) {
                done = match.1 != " "
                line = String(line[match.range.upperBound...])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            result.append(Item(id: "", title: String(line.prefix(500)), status: done ? .done : .todo))
            if result.count == limit { break }
        }
        return result
    }
}

/// Reads and writes items on the general pasteboard.
enum Clipboard {
    private static var pasteboard: NSPasteboard { .general }
    private static let type = NSPasteboard.PasteboardType(UTType.doResearchItems.identifier)

    static func write(_ items: [Item]) {
        let transfer = ItemTransfer(items: items)
        pasteboard.clearContents()
        if let data = try? JSONEncoder().encode(transfer) { pasteboard.setData(data, forType: type) }
        pasteboard.setString(transfer.plainText, forType: .string)
    }

    /// For SwiftUI's copy/cut commands, which write the returned providers to the pasteboard themselves.
    static func providers(_ items: [Item]) -> [NSItemProvider] {
        let transfer = ItemTransfer(items: items)
        let provider = NSItemProvider(object: transfer.plainText as NSString)
        if let data = try? JSONEncoder().encode(transfer) {
            provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return [provider]
    }

    /// Ids of DoResearch items on the clipboard (not text), used to tell whether a cut is still pending.
    static var itemIDs: Set<String> {
        guard let data = pasteboard.data(forType: type),
              let transfer = try? JSONDecoder().decode(ItemTransfer.self, from: data) else { return [] }
        return Set(transfer.items.map(\.id))
    }

    static var hasContent: Bool {
        pasteboard.availableType(from: [type, .string]) != nil
    }

    /// Our own items if present, otherwise items parsed from plain text.
    static func read() -> [Item] {
        if let data = pasteboard.data(forType: type), let transfer = try? JSONDecoder().decode(ItemTransfer.self, from: data) {
            return transfer.items
        }
        if let text = pasteboard.string(forType: .string) { return ItemTransfer.parse(text) }
        return []
    }
}
