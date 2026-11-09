import Foundation

// The folder that the arguments of nexus php, composer, node, npm or wp name. An MCP server of an
// editor can start php /Sites/shop/artisan boost:mcp from another folder. nexusd then takes the
// versions of the site of that folder (D38). A relative path starts in the current folder.
public enum ToolArguments {
    // PHP options with a value in the next argument. -t gives the document root of the built-in
    // server, so that folder counts.
    static let phpOptionsWithValue: Set<String> = ["-c", "-d", "-B", "-R", "-E", "-S", "-z", "--rf", "--rc", "--re", "--ri"]
    static let phpOptionsWithoutScript: Set<String> = ["-r", "-a", "-i", "-l", "-m", "-v", "-h", "--", "--ini"]
    static let nodeOptionsWithValue: Set<String> = ["-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions", "--input-type", "--env-file", "--title", "--inspect-port"]
    static let nodeOptionsWithoutScript: Set<String> = ["-e", "--eval", "-p", "--print", "-i", "--interactive", "-v", "--version", "-h", "--help", "-"]

    public static func folder(of tool: ProjectTool, in arguments: [String], currentFolder: String) -> String? {
        let current = URL(filePath: currentFolder, directoryHint: .isDirectory)

        func folder(_ path: String) -> String {
            URL(filePath: path, directoryHint: .isDirectory, relativeTo: current).standardizedFileURL.path(percentEncoded: false)
        }

        func folderOfFile(_ path: String) -> String {
            URL(filePath: path, directoryHint: .notDirectory, relativeTo: current).standardizedFileURL.deletingLastPathComponent().path(percentEncoded: false)
        }

        switch tool {
        case .php:
            return phpScript(in: arguments).map { $0.isFolder ? folder($0.path) : folderOfFile($0.path) }
        case .node:
            return nodeScript(in: arguments).map(folderOfFile)
        case .composer:
            return optionValue(["--working-dir", "-d"], in: arguments).map(folder)
        case .npm:
            return optionValue(["--prefix", "-C"], in: arguments).map(folder)
        case .wp:
            return optionValue(["--path"], in: arguments).map(folder)
        }
    }

    // The script is the first argument that is no option, or the value of -f or -F.
    static func phpScript(in arguments: [String]) -> (path: String, isFolder: Bool)? {
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]

            if phpOptionsWithoutScript.contains(argument) {
                return nil
            }

            if ["-f", "-F", "-t"].contains(argument) {
                return arguments.indices.contains(index + 1) ? (arguments[index + 1], argument == "-t") : nil
            }

            if phpOptionsWithValue.contains(argument) {
                index += 2
                continue
            }

            if !argument.hasPrefix("-") {
                return (argument, false)
            }

            index += 1
        }

        return nil
    }

    static func nodeScript(in arguments: [String]) -> String? {
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]

            if nodeOptionsWithoutScript.contains(argument) {
                return nil
            }

            if argument == "--" {
                return arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            }

            if nodeOptionsWithValue.contains(argument) {
                index += 2
                continue
            }

            if !argument.hasPrefix("-") {
                return argument
            }

            index += 1
        }

        return nil
    }

    // --name value, --name=value, and a short name with its value attached, as in -d/Sites/shop.
    // The arguments after -- belong to a script.
    static func optionValue(_ names: [String], in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == "--" {
                return nil
            }

            for name in names {
                if argument == name {
                    return arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
                }

                if name.hasPrefix("--"), argument.hasPrefix("\(name)=") {
                    return String(argument.dropFirst(name.count + 1))
                }

                if !name.hasPrefix("--"), argument.hasPrefix(name), argument.count > name.count {
                    return String(argument.dropFirst(name.count))
                }
            }
        }

        return nil
    }
}
