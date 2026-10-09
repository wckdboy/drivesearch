import CryptoKit
import Foundation

public enum PathSanitizer {
    /// Make `relativePath` safe as a sequence of APFS path components and unique
    /// under a case-insensitive volume. The same remote id always gets the same stub path.
    public static func assign(_ items: inout [RemoteItem]) {
        var used: [String: String] = [:]
        let order = items.indices.sorted { items[$0].remoteID < items[$1].remoteID }
        for index in order {
            let desired = sanitize(items[index].relativePath)
            let key = desired.lowercased()
            let mirror: String
            if let owner = used[key], owner != items[index].remoteID {
                mirror = disambiguate(desired, remoteID: items[index].remoteID, used: &used)
            } else {
                mirror = desired
                used[key] = items[index].remoteID
            }
            items[index].mirrorPath = mirror
        }
    }

    public static func sanitize(_ relativePath: String) -> String {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true).map { component(String($0)) }
        let cleaned = parts.filter { !$0.isEmpty }
        if cleaned.isEmpty { return "_" }
        return cleaned.joined(separator: "/")
    }

    static func component(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\u{0}", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") || text.hasSuffix(" ") {
            text.removeLast()
        }
        if text.isEmpty || text == "." || text == ".." {
            text = "_"
        }
        var bytes = Array(text.utf8)
        if bytes.count > 200 {
            let digest = SHA256.hash(data: Data(bytes))
            let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
            var kept: [UInt8] = []
            for byte in bytes {
                if kept.count == 180 { break }
                kept.append(byte)
            }
            while let last = kept.last, last & 0b1100_0000 == 0b1000_0000 {
                kept.removeLast()
            }
            text = String(decoding: kept, as: UTF8.self) + "~" + suffix
        }
        return text
    }

    private static func disambiguate(_ path: String, remoteID: String, used: inout [String: String]) -> String {
        let digest = SHA256.hash(data: Data(remoteID.utf8))
        let tag = digest.prefix(3).map { String(format: "%02x", $0) }.joined()
        let parent = CloudPath.parent(path)
        let name = CloudPath.name(path)
        let stamped: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stamped = "\(name[..<dot])~\(tag)\(name[dot...])"
        } else {
            stamped = "\(name)~\(tag)"
        }
        let full = CloudPath.join(parent, stamped)
        used[full.lowercased()] = remoteID
        return full
    }
}

public enum QueryComposer {
    /// Build the fsearch query strings for one keystroke.
    /// `universe` is every indexed root. `restrictTo` is the chip selection, or nil for all of them.
    /// A relative `in:` is appended to each chosen root. An absolute `in:` is left as one scope.
    public static func fsearchQueries(userText: String, universe: [String], restrictTo: [String]?) -> [String] {
        let words = splitWords(userText)
        // Last `in:` wins, matching the engine (each filter overwrites the scope).
        var scope: String?
        var rest: [String] = []
        for word in words {
            if word.hasPrefix("in:") {
                scope = String(word.dropFirst(3))
            } else {
                rest.append(word)
            }
        }
        let base = rest.joined(separator: " ")
        let chosen = (restrictTo?.isEmpty == false ? restrictTo! : nil)
        if let scope, scope.hasPrefix("/") {
            return [join(base, scope: scope)]
        }
        if let scope {
            let roots = chosen ?? universe
            if roots.isEmpty { return [join(base, scope: scope)] }
            return roots.map { root in
                let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
                let relative = scope.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return join(base, scope: trimmed + "/" + relative)
            }
        }
        if let chosen {
            return chosen.map { join(base, scope: $0.hasSuffix("/") ? String($0.dropLast()) : $0) }
        }
        let text = base.isEmpty ? userText : base
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [text]
    }

    static func splitWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character == " ", !quoted {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func join(_ base: String, scope: String) -> String {
        let quoted = "in:\"\(scope)\""
        if base.trimmingCharacters(in: .whitespaces).isEmpty { return quoted }
        return base + " " + quoted
    }
}
