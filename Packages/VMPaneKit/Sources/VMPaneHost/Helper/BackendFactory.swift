import Foundation
import VMPaneCore
import VMPaneVZ

/// Chooses and prepares the backend for a helper's VM.
public enum BackendFactory {
    public struct Made: Sendable {
        public let backend: VMBackend?
        /// The config after first-start preparation (e.g. a new machine identifier), already saved.
        public let config: VMConfigV1

        public init(backend: VMBackend?, config: VMConfigV1) {
            self.backend = backend
            self.config = config
        }
    }

    /// The backend for `prepared`'s VM, or nil when this build has none for it (the helper then answers
    /// `backendUnavailable`). First-start changes are saved under the bundle lock.
    public static func make(_ prepared: PreparedBundle) throws -> Made {
        var config = prepared.config
        switch config.backend {
        case .vz:
            guard config.os == .linux else { return Made(backend: nil, config: config) }  // macOS guests: next
            if let updated = VZBackend.prepare(config) {
                try ConfigStore.save(updated, holding: prepared.lock)
                config = updated
            }
            let plan = try VZPlanBuilder.plan(config, bundle: prepared.lock.bundle)
            return Made(backend: VZBackend(plan: plan), config: config)
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
