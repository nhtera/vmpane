import Darwin

/// The SPICE client libraries are weak-linked: they ship only with the QEMU bundle, and a helper without
/// them must still run VZ VMs. Nothing may touch a CocoaSpice class (whose code calls into the libraries)
/// unless this says they were loaded.
public enum SpiceLibraries {
    public static let available: Bool = dlopen("@rpath/libspice-client-glib-2.0.8.dylib", RTLD_NOLOAD | RTLD_LAZY) != nil
}
