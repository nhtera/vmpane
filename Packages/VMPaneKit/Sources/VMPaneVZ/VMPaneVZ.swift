import VMPaneCore

/// Virtualization.framework backend (macOS and Linux guests). VMs are owned by an actor whose
/// executor is the VM's own serial queue (see docs/adr/0003-swift6-vz-isolation.md).
public enum VZBackendInfo {
    public static let name = "vz"
}
