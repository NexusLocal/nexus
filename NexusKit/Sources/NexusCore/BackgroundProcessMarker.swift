// nexusd puts this key in the environment of each background process, each workspace server and
// each Node.js app. So the nexus command knows that a link of bin/ runs inside such a program
// (owner, 2026-11-15).
public enum BackgroundProcessMarker {
    public static let name = "NEXUS_BACKGROUND_PROCESS"
}
