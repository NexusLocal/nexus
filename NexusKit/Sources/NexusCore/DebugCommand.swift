import Foundation

// What nexus debug runs (owner, 2026-11-14). php, composer and wp name their tool. Another first
// word is a PHP file, for example artisan, bin/console or vendor/bin/pest. That file runs with php.
// An option such as -d also goes to php.
public enum DebugCommand {
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    static let example = "nexus debug artisan my:command"

    public static func onlyPHP(_ tool: ProjectTool) -> String {
        "nexus debug runs PHP only. Xdebug cannot debug \(tool.rawValue)."
    }

    // A first -- only ends the options of nexus debug. php -- would read a script from the input.
    public static func target(of givenArguments: [String], currentFolder: String) throws -> (tool: ProjectTool, arguments: [String]) {
        let arguments = givenArguments.first == "--" ? Array(givenArguments.dropFirst()) : givenArguments

        guard let first = arguments.first else {
            throw Refusal(description: "Name the command to debug, for example: \(example)")
        }

        if let tool = ProjectTool(rawValue: first) {
            guard tool.runsPHP else {
                throw Refusal(description: onlyPHP(tool))
            }

            return (tool, Array(arguments.dropFirst()))
        }

        if first.hasPrefix("-") {
            return (.php, arguments)
        }

        let file = URL(filePath: first, directoryHint: .notDirectory, relativeTo: URL(filePath: currentFolder, directoryHint: .isDirectory)).standardizedFileURL
        var isFolder: ObjCBool = false

        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false), isDirectory: &isFolder), !isFolder.boolValue else {
            throw Refusal(description: "Nexus cannot find the file \(first). nexus debug runs php, composer, wp or a PHP file, for example: \(example)")
        }

        guard isPHP(file, start: start(of: file)) else {
            throw Refusal(description: "\(first) is not a PHP file. nexus debug runs php, composer, wp or a PHP file, for example: \(example)")
        }

        return (.php, arguments)
    }

    // A script such as artisan has no extension. Its first line is #!/usr/bin/env php.
    static func isPHP(_ file: URL, start: String?) -> Bool {
        if file.pathExtension == "php" {
            return true
        }

        guard let start else {
            return false
        }

        let firstLine = start.prefix { $0 != "\n" }
        let code = start.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        return code.hasPrefix("<?php") || code.hasPrefix("<?=") || firstLine.hasPrefix("#!") && firstLine.contains("php")
    }

    private static func start(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }

        defer { try? handle.close() }
        return (try? handle.read(upToCount: 128)).map { String(decoding: $0, as: UTF8.self) }
    }
}
