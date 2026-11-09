// The code editors that Nexus knows, in the order that Nexus suggests them (D61). The app and
// nexus edit share them. The app keeps the path of the chosen editor under preferenceKey. An empty
// path is the choice "None".
public enum CodeEditors {
    public static let preferenceKey = "editorApp"

    public static let bundleIdentifiers = [
        "com.jetbrains.PhpStorm", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed",
        "com.sublimetext.4", "com.panic.Nova", "com.jetbrains.WebStorm", "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
        "com.barebones.bbedit", "com.macromates.TextMate",
    ]
}
