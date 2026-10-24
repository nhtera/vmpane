import Foundation

/// What happened to one changed setting in `vm.settings.apply`.
public enum SettingOutcome: String, Codable, Sendable {
    /// In effect now (host-side settings, live changes, or any change while the VM is stopped).
    case applied
    /// Saved; the running VM picks it up at its next start.
    case nextBoot
    /// Not saved (cannot change, or unknown).
    case rejected
}

/// How a setting can change.
public enum SettingKind: Sendable, Equatable {
    /// Read by the host only (name, port rules, policy, UI): saving it applies it.
    case host
    /// The backend may apply it to a running VM (`VMBackend.applyLive`); otherwise next boot.
    case live
    /// Fixed while the VM runs (S11 matrix: `docs/live-capabilities.md`).
    case nextBoot
    /// Never changed through settings (identity, disks, install source).
    case immutable
    case unknown
}

/// `vm.settings.apply` patches: a JSON merge patch (RFC 7386) over the config, split into setting paths
/// such as `cpu.count` or `network.0.mode`. Arrays whose items have no live meaning on their own
/// (`shares`, `portForwards`, …) are one setting.
public enum SettingsPatch {
    /// RFC 7386: objects merge recursively, `null` removes a key, anything else replaces.
    public static func merge(_ base: JSONValue, _ patch: JSONValue) -> JSONValue {
        guard case .object(let changes) = patch else { return patch }
        var result = base.objectValue ?? [:]
        for (key, value) in changes {
            if case .null = value {
                result.removeValue(forKey: key)
            } else {
                result[key] = merge(result[key] ?? .null, value)
            }
        }
        return .object(result)
    }

    /// The RFC 7386 merge patch that turns `old` into `new` (nil when they are equal): changed keys with their
    /// new value, removed keys as `null`, nested objects as nested patches; arrays and scalars whole.
    public static func makePatch(from old: JSONValue, to new: JSONValue) -> JSONValue? {
        guard old != new else { return nil }
        guard case .object(let before) = old, case .object(let after) = new else { return new }
        var patch: [String: JSONValue] = [:]
        for key in Set(before.keys).union(after.keys) {
            switch (before[key], after[key]) {
            case (_?, nil): patch[key] = .null
            case (nil, let value?): patch[key] = value
            case (let was?, let now?): if let nested = makePatch(from: was, to: now) { patch[key] = nested }
            case (nil, nil): break
            }
        }
        return .object(patch)
    }

    /// The setting paths that differ between `old` and `new`, sorted.
    public static func changedPaths(_ old: JSONValue, _ new: JSONValue) -> [String] {
        var paths: [String] = []
        diff(old, new, path: [], into: &paths)
        return paths.sorted()
    }

    private static let wholeArrays: Set<String> = ["shares", "portForwards", "removable", "disks"]

    private static func diff(_ old: JSONValue?, _ new: JSONValue?, path: [String], into paths: inout [String]) {
        guard old != new else { return }
        if path.count == 1, wholeArrays.contains(path[0]) {
            paths.append(path[0])
            return
        }
        switch (old, new) {
        case (.object(let a)?, .object(let b)?):
            for key in Set(a.keys).union(b.keys) { diff(a[key], b[key], path: path + [key], into: &paths) }
        case (.array(let a)?, .array(let b)?) where a.count == b.count:
            for index in a.indices { diff(a[index], b[index], path: path + [String(index)], into: &paths) }
        default:
            paths.append(path.joined(separator: "."))
        }
    }

    public static func kind(of path: String) -> SettingKind {
        let parts = path.split(separator: ".").map(String.init)
        guard let top = parts.first else { return .unknown }
        let leaf = parts.count > 1 ? parts[parts.count - 1] : nil
        switch top {
        case "schemaVersion", "id", "os", "backend", "platform", "disks", "install": return .immutable
        case "name", "portForwards", "mcp", "ui": return .host
        case "shares": return .live
        case "display": return ["widthPx", "heightPx", "autoResize"].contains(leaf ?? "") ? .live : .nextBoot
        case "network": return parts.count == 3 && leaf == "mode" ? .live : .nextBoot
        case "clipboard": return leaf == "allowWithAgents" ? .host : .nextBoot
        case "agent": return leaf == "autoUpdate" ? .host : .nextBoot
        case "cpu", "memory", "removable", "audio", "vz", "qemu", "windows": return .nextBoot
        default: return .unknown
        }
    }

    /// `target` with the value at `path` taken from `source` (removed if `source` has none).
    public static func copy(_ path: String, from source: JSONValue, into target: JSONValue) -> JSONValue {
        set(path.split(separator: ".").map(String.init)[...], value(at: path, in: source), in: target)
    }

    public static func value(at path: String, in json: JSONValue) -> JSONValue? {
        var current: JSONValue? = json
        for part in path.split(separator: ".").map(String.init) {
            switch current {
            case .object(let object)?: current = object[part]
            case .array(let array)?: current = Int(part).flatMap { array.indices.contains($0) ? array[$0] : nil }
            default: return nil
            }
        }
        return current
    }

    private static func set(_ path: ArraySlice<String>, _ value: JSONValue?, in json: JSONValue) -> JSONValue {
        guard let key = path.first else { return value ?? .null }
        let rest = path.dropFirst()
        if case .array(var array) = json, let index = Int(key), array.indices.contains(index) {
            array[index] = set(rest, value, in: array[index])
            return .array(array)
        }
        var object = json.objectValue ?? [:]
        if rest.isEmpty, value == nil {
            object.removeValue(forKey: key)
        } else {
            object[key] = set(rest, value, in: object[key] ?? .null)
        }
        return .object(object)
    }
}
