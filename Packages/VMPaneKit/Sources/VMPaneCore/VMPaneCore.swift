import Foundation

/// Product-wide constants shared by the app, the per-VM helper and the CLI.
public enum VMPane {
    /// Marketing version; the build number comes from the bundle at run time.
    public static let version = "1.0.0-beta.1"

    /// Code-signing identifiers. Peer-identity checks on the control socket match against these.
    public enum SigningIdentifier {
        public static let app = "app.vmpane.mac"
        public static let helper = "app.vmpane.mac.vm"
        public static let cli = "app.vmpane.mac.cli"
    }

    /// File-name extension of a VM bundle (exported UTI `app.vmpane.vm`).
    public static let bundleExtension = "vmpane"
}
