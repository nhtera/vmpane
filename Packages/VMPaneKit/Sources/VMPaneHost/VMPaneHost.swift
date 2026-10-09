import VMPaneControl
import VMPaneCore
import VMPaneQEMU
import VMPaneVZ

/// Logic of the per-VM helper process (one process per running VM).
public enum HelperInfo {
    /// Backends this helper can run.
    public static let backends = [VZBackendInfo.name, QEMUBackendInfo.name]
}
