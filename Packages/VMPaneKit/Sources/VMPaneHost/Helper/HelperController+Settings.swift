import Foundation
import VMPaneControl
import VMPaneCore

/// `vm.settings.apply`: a merge patch over the config, saved first, then applied to the running VM where
/// the backend can (S11 matrix); the rest waits for the next start. Policy (`uiOnly` for sensitive
/// patches) is checked before this runs.
extension HelperController {
    private struct ApplyParams: Decodable { var patch: JSONValue }

    /// `byApp`: the change comes from VMPane's app; port forwards anyone else adds are marked as an agent's.
    func applySettings(_ params: JSONValue?, byApp: Bool = true) async -> Result<JSONValue, RPCError> {
        let patch: JSONValue
        switch RPCParams.decode(ApplyParams.self, from: params) {
        case .success(let decoded): patch = decoded.patch
        case .failure(let error): return .failure(error)
        }
        guard case .object = patch else { return .failure(RPCError(.invalidParams, "patch must be an object")) }
        let running = [.running, .paused].contains(state)
        guard running || [.stopped, .error].contains(state) else {
            return .failure(RPCError(.invalidState, "cannot change settings while \(state.rawValue)"))
        }
        do {
            let old = try Self.json(config)
            let (saved, rejected) = Self.screen(old, SettingsPatch.merge(old, patch))
            let accepted = SettingsPatch.changedPaths(old, saved)
            let updated = try newConfig(from: saved, accepted: accepted, byApp: byApp)
            let lock = prepared.lock
            try await Blocking.run { try ConfigStore.save(updated, holding: lock) }
            config = updated

            // Port forwards are host settings, but a QEMU guest's live in QEMU's NAT: the backend applies them too.
            let livePaths = accepted.filter { SettingsPatch.kind(of: $0) == .live || $0.hasPrefix("portForwards") }
            // While agents are stopped, their forwards stay down.
            var allowed = updated
            allowed.portForwards = forwardsAllowedNow()
            var live = running ? await backend?.applyLive(allowed, paths: livePaths) ?? [] : []
            // A running Windows VM's shares are the helper's WebDAV server.
            if accepted.contains("shares"), updateWebDAVShares(updated.shares) { live.insert("shares") }
            // A running VZ VM's forwards are the helper's own listeners.
            let forwardsLive =
                running && backend?.kind == .vz && accepted.contains { $0.hasPrefix("portForwards") }
                ? await applyForwards((try? PortRule.rules(allowed.portForwards)) ?? []) : false
            var outcomes = rejected.mapValues { _ in JSONValue.string(SettingOutcome.rejected.rawValue) }
            var inEffect: [String] = []
            for path in accepted {
                let now = inEffectNow(path, running: running, live: live, forwardsLive: forwardsLive)
                outcomes[path] = .string(now ? SettingOutcome.applied.rawValue : SettingOutcome.nextBoot.rawValue)
                if now { inEffect.append(path) }
            }
            if running { try noteAppliedWhileRunning(inEffect, from: saved) }
            var result: [String: JSONValue] = ["fields": .object(outcomes)]
            if !rejected.isEmpty { result["reasons"] = .object(rejected.mapValues { .string($0) }) }
            return .success(.object(result))
        } catch let error as DecodingError {
            return .failure(RPCError(.invalidParams, "the patched config is not valid: \(error)"))
        } catch {
            return .failure(RPCError(.invalidParams, "cannot apply: \(error)"))
        }
    }

    /// The config to save: agents' new forwards marked as theirs, a changed agent policy tagged.
    private func newConfig(from saved: JSONValue, accepted: [String], byApp: Bool) throws -> VMConfigV1 {
        var merged = try Self.config(from: saved)
        if !byApp {
            // The kill switch takes down what agents opened: rules a non-app client adds are theirs.
            let before = config.portForwards
            merged.portForwards = merged.portForwards.map { rule in
                var rule = rule
                if !before.contains(rule) { rule.origin = .agent }
                return rule
            }
        }
        // A new agent policy is tagged here (only VMPane's UI may change it: policy uiOnly), so it counts.
        let policyChanged = accepted.contains { $0.hasPrefix("mcp") || $0 == "clipboard.allowWithAgents" }
        let key = policyChanged ? PolicyKeyFile(paths: prepared.runFiles.paths).key(create: true) : nil
        return key.map { PolicyIntegrity.signed(merged, key: $0) } ?? merged
    }

    /// Whether a changed setting is in effect now (else at the next start).
    private func inEffectNow(_ path: String, running: Bool, live: Set<String>, forwardsLive: Bool) -> Bool {
        switch SettingsPatch.kind(of: path) {
        // A running QEMU VM's forwards are in QEMU: in effect only if it took them.
        case .host where path.hasPrefix("portForwards") && running && backend?.kind == .qemu: live.contains(path)
        case .host where path.hasPrefix("portForwards") && running && backend?.kind == .vz: forwardsLive
        case .host: true
        case .live: !running || live.contains(path)
        default: !running
        }
    }

    /// `old` with the changeable settings of `merged`, and the refused ones with their reasons.
    private static func screen(_ old: JSONValue, _ merged: JSONValue) -> (saved: JSONValue, rejected: [String: String]) {
        var saved = old
        var rejected: [String: String] = [:]
        for path in SettingsPatch.changedPaths(old, merged) {
            switch SettingsPatch.kind(of: path) {
            // Removing `install` ejects the installer by hand (e.g. a distro whose boot entry is not detected).
            case .immutable where path == "install" && SettingsPatch.value(at: path, in: merged) == nil:
                saved = SettingsPatch.copy(path, from: merged, into: saved)
            case .immutable: rejected[path] = "cannot be changed"
            case .host where path == "mcp.tag": rejected[path] = "written by VMPane"
            case .host where path == "portForwards":
                // One bad rule refuses the list: forwards are built only from rules that check out.
                do {
                    let rules = try CanonicalJSON.decoder().decode(
                        [Extensible<PortForwardConfig>].self,
                        from: CanonicalJSON.encoder().encode(SettingsPatch.value(at: path, in: merged) ?? .array([])))
                    let wanted = try PortRule.rules(rules)
                    let current =
                        (try? CanonicalJSON.decoder().decode(
                            [Extensible<PortForwardConfig>].self,
                            from: CanonicalJSON.encoder().encode(SettingsPatch.value(at: path, in: old) ?? .array([]))))
                        .flatMap { try? PortRule.rules($0) } ?? []
                    if let busy = busyHostPort(wanted, current: current) {
                        rejected[path] = busy
                    } else {
                        saved = SettingsPatch.copy(path, from: merged, into: saved)
                    }
                } catch let error as PortRule.Invalid {
                    rejected[path] = error.description
                } catch {
                    rejected[path] = "not a list of port forwards"
                }
            case .unknown: rejected[path] = "unknown setting"
            case .host, .live, .nextBoot: saved = SettingsPatch.copy(path, from: merged, into: saved)
            }
        }
        return (saved, rejected)
    }

    /// The running VM's hardware now includes `paths`: saved state and live snapshots are tagged with it.
    private func noteAppliedWhileRunning(_ paths: [String], from saved: JSONValue) throws {
        guard let current = runningConfig else { return }
        var json = try Self.json(current)
        for path in paths { json = SettingsPatch.copy(path, from: saved, into: json) }
        runningConfig = try Self.config(from: json)
    }

    private static func json(_ config: VMConfigV1) throws -> JSONValue {
        try CanonicalJSON.decoder().decode(JSONValue.self, from: CanonicalJSON.encode(config))
    }

    private static func config(from json: JSONValue) throws -> VMConfigV1 {
        let config = try CanonicalJSON.decoder().decode(VMConfigV1.self, from: CanonicalJSON.encoder().encode(json))
        try ConfigStore.validate(config)
        return config
    }
}
