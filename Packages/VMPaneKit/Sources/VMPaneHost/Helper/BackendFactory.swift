import Foundation
import VMPaneCore
import VMPaneVZ

/// Chooses and prepares the backend for a helper's VM.
public enum BackendFactory {
    public struct Made: Sendable {
        public let backend: VMBackend?
        /// The config after first-start preparation (e.g. a new machine identifier), already saved.
        public let config: VMConfigV1
        /// Config changes to save after a successful start (e.g. a macOS install finished).
        public let afterStart: (@Sendable (VMConfigV1) -> VMConfigV1?)?

        public init(backend: VMBackend?, config: VMConfigV1, afterStart: (@Sendable (VMConfigV1) -> VMConfigV1?)? = nil) {
            self.backend = backend
            self.config = config
            self.afterStart = afterStart
        }
    }

    /// The backend for `prepared`'s VM, or nil when this build has none for it (the helper then answers
    /// `backendUnavailable`). First-start changes are saved under the bundle lock.
    public static func make(_ prepared: PreparedBundle) throws -> Made {
        var config = prepared.config
        switch config.backend {
        case .vz:
            guard config.os != .windows else { return Made(backend: nil, config: config) }
            if let updated = VZBackend.prepare(config) {
                try ConfigStore.save(updated, holding: prepared.lock)
                config = updated
            }
            let bundle = prepared.lock.bundle
            let plan = try VZPlanBuilder.plan(config, bundle: bundle)
            let backend = VZBackend(plan: plan, title: config.name, replan: { try VZPlanBuilder.plan($0, bundle: bundle) })
            return Made(backend: backend, config: config) { VZBackend.installed($0, bundle: bundle) }
        case .qemu:
            return Made(backend: nil, config: config)  // Phase 05
        }
    }

    /// `validate()` of the VM's configuration (signed helper only: needs the entitlement).
    public static func validate(_ bundle: VMBundle) throws {
        var config = try ConfigStore.load(bundle)
        if let prepared = VZBackend.prepare(config) { config = prepared }  // validation must not write
        try VZBackend.validate(try VZPlanBuilder.plan(config, bundle: bundle))
    }
}
