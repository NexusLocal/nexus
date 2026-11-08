// The ids follow the bundle id of the app. The PRODUCT_BUNDLE_IDENTIFIER of each target in the
// Xcode project must give the same ids for each configuration.
public enum NexusIdentifiers {
    public static let app = NexusVariant.current.bundleIdentifier
    public static let daemon = "\(app).daemon"
    public static let helper = "\(app).helper"
    public static let cli = "\(app).cli"
}
