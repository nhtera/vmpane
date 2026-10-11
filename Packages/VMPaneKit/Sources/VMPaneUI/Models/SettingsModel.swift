import Foundation
import Observation
import VMPaneControl
import VMPaneCore

/// The settings sheet: an editable copy of the VM's config, the changes as one `vm.settings.apply` merge
/// patch, and what happened to each changed setting (in effect now, at the next start, or refused).
@MainActor
@Observable
public final class SettingsModel {
    public var draft: VMConfigV1
    public private(set) var original: VMConfigV1
    public private(set) var outcomes: [String: SettingOutcome] = [:]
    public private(set) var reasons: [String: String] = [:]
    public private(set) var applying = false
    public var lastError: String?
    /// Each saved port forward's state (`vm.ports.list`), by rule id.
    public private(set) var portStatuses: [String: PortStatus] = [:]

    public struct PortStatus: Equatable, Sendable {
        /// listening, blocked, failed or inactive.
        public let state: String
        public let reason: String?
    }

    @ObservationIgnored private let channel: HelperChannel

    public init(config: VMConfigV1, channel: HelperChannel) {
        draft = config
        original = config
        self.channel = channel
    }

    /// The current config from the helper.
    public static func load(_ channel: HelperChannel) async throws -> SettingsModel {
        let json = try await channel.call(ControlMethod.vmSettingsGet.rawValue, params: nil, timeout: .seconds(10))
        let config = try CanonicalJSON.decoder().decode(VMConfigV1.self, from: CanonicalJSON.encoder().encode(json))
        return SettingsModel(config: config, channel: channel)
    }

    private static func json(_ config: VMConfigV1) -> JSONValue {
        (try? CanonicalJSON.decoder().decode(JSONValue.self, from: CanonicalJSON.encode(config))) ?? [:]
    }

    /// Setting paths the draft changes.
    public var changedPaths: [String] { SettingsPatch.changedPaths(Self.json(original), Self.json(draft)) }
    public var hasChanges: Bool { !changedPaths.isEmpty }

    /// How a setting under `path` can change (for the "live" / "next boot" badge next to it).
    public static func kind(of path: String) -> SettingKind { SettingsPatch.kind(of: path) }

    /// Some saved change waits for the next start.
    public var needsRestart: Bool { outcomes.values.contains(.nextBoot) }

    /// Reads the forwards' states from the helper.
    public func refreshPorts() async {
        guard let result = try? await channel.call(ControlMethod.vmPortsList.rawValue, params: nil, timeout: .seconds(10)),
            case .array(let rules)? = result["rules"]
        else { return }
        var statuses: [String: PortStatus] = [:]
        for rule in rules {
            guard let id = rule["id"]?.stringValue, let state = rule["status"]?.stringValue else { continue }
            statuses[id] = PortStatus(state: state, reason: rule["reason"]?.stringValue)
        }
        portStatuses = statuses
    }

    public func revert() {
        draft = original
    }

    /// Sends the changes as one patch; afterwards `outcomes` says what each did, and the draft is the new baseline.
    public func apply() async {
        guard let patch = SettingsPatch.makePatch(from: Self.json(original), to: Self.json(draft)) else { return }
        applying = true
        defer { applying = false }
        do {
            let result = try await channel.call(ControlMethod.vmSettingsApply.rawValue, params: ["patch": patch], timeout: .seconds(60))
            var outcomes: [String: SettingOutcome] = [:]
            for (path, value) in result["fields"]?.objectValue ?? [:] {
                if let outcome = value.stringValue.flatMap(SettingOutcome.init(rawValue:)) { outcomes[path] = outcome }
            }
            self.outcomes = outcomes
            reasons = (result["reasons"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
            // What was refused stays as it was; everything else is the new baseline.
            var baseline = Self.json(draft)
            for path in outcomes.filter({ $0.value == .rejected }).map(\.key) {
                baseline = SettingsPatch.copy(path, from: Self.json(original), into: baseline)
            }
            let accepted = try CanonicalJSON.decoder().decode(VMConfigV1.self, from: CanonicalJSON.encoder().encode(baseline))
            original = accepted
            draft = accepted
            if outcomes.keys.contains(where: { $0.hasPrefix("portForwards") }) { await refreshPorts() }
        } catch let error as RPCError {
            lastError = error.message
        } catch {
            lastError = String(describing: error)
        }
    }
}
