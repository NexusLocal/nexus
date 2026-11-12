import Foundation
import NexusCore
import Testing

struct CodeEditorsTests {
    private static let file = "/Users/x/Tim Klaversma/shop/app/Http/Controllers/CheckoutController.php"

    private func link(_ bundleIdentifier: String) -> String? {
        guard case .link(let url)? = CodeEditors.fileAtLine(Self.file, line: 42, editor: bundleIdentifier) else {
            return nil
        }

        return url.absoluteString
    }

    @Test func aJetBrainsIDEGetsTheLineAsAnArgument() {
        for identifier in ["com.jetbrains.PhpStorm", "com.jetbrains.WebStorm", "com.jetbrains.intellij", "com.jetbrains.intellij.ce"] {
            #expect(CodeEditors.fileAtLine(Self.file, line: 42, editor: identifier) == .launchArguments(["--line", "42", Self.file]))
        }
    }

    @Test func theEditorsOfVSCodeGetTheLineInThePath() {
        #expect(link("com.microsoft.VSCode") == "vscode://file/Users/x/Tim%20Klaversma/shop/app/Http/Controllers/CheckoutController.php:42")
        #expect(link("com.todesktop.230313mzl4w4u92") == "cursor://file/Users/x/Tim%20Klaversma/shop/app/Http/Controllers/CheckoutController.php:42")
        #expect(link("com.exafunction.windsurf") == "windsurf://file/Users/x/Tim%20Klaversma/shop/app/Http/Controllers/CheckoutController.php:42")
        #expect(link("dev.zed.Zed") == "zed://file/Users/x/Tim%20Klaversma/shop/app/Http/Controllers/CheckoutController.php:42")
    }

    @Test func aFileLinkInTheQueryIsEncodedOnceMore() {
        #expect(link("com.macromates.TextMate") == "txmt://open?url=file:///Users/x/Tim%2520Klaversma/shop/app/Http/Controllers/CheckoutController.php&line=42")
        #expect(link("com.barebones.bbedit") == "x-bbedit://open?url=file:///Users/x/Tim%2520Klaversma/shop/app/Http/Controllers/CheckoutController.php&line=42")
        #expect(link("com.sublimetext.4") == "subl://open?url=file:///Users/x/Tim%2520Klaversma/shop/app/Http/Controllers/CheckoutController.php&line=42")
        #expect(link("com.panic.Nova") == "nova://core/open/file?filename=/Users/x/Tim%20Klaversma/shop/app/Http/Controllers/CheckoutController.php&line=42")
    }

    @Test func anAmpersandInThePathDoesNotEndTheValue() {
        guard case .link(let url)? = CodeEditors.fileAtLine("/Users/x/a&b=c/index.php", line: 7, editor: "com.macromates.TextMate") else {
            Issue.record("TextMate has no link")
            return
        }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.map(\.name) == ["url", "line"])
        #expect(items.first?.value.flatMap(URL.init(string:))?.path(percentEncoded: false) == "/Users/x/a&b=c/index.php")
    }

    @Test func eachKnownEditorHasAWay() {
        for identifier in CodeEditors.bundleIdentifiers {
            #expect(CodeEditors.fileAtLine(Self.file, line: 1, editor: identifier) != nil)
        }
    }

    @Test func theOrderOfTheSuggestionsStays() {
        #expect(CodeEditors.bundleIdentifiers == [
            "com.jetbrains.PhpStorm", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed",
            "com.sublimetext.4", "com.panic.Nova", "com.jetbrains.WebStorm", "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
            "com.barebones.bbedit", "com.macromates.TextMate",
        ])
    }

    @Test func anUnknownEditorHasNoWay() {
        #expect(CodeEditors.fileAtLine(Self.file, line: 42, editor: "com.apple.TextEdit") == nil)
    }
}
