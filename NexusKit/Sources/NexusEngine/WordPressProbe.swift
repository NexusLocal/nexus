import Foundation
import NexusCore
import NexusRuntime
import NexusSupervisor

// Reads wp-config.php and wp-includes/version.php with the tokenizer of PHP (Phase 4, 3b). The
// files do not run. A define() or an assignment counts only when its value is one literal. A name
// with two different values gives nil, for example a define in each branch of an if.
struct WordPressProbe: Sendable {
    static let timeout: Duration = .seconds(10)

    static let source = #"""
    error_reporting(0);

    function nexus_tokens(string $file): array {
        $code = @file_get_contents($file);

        if ($code === false) {
            return [];
        }

        $skipped = [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT, T_OPEN_TAG];

        return array_values(array_filter(token_get_all($code), fn ($token) => ! is_array($token) || ! in_array($token[0], $skipped, true)));
    }

    function nexus_literal($token, &$value): bool {
        if (! is_array($token)) {
            return false;
        }

        if ($token[0] === T_LNUMBER) {
            $value = (int) $token[1];
            return true;
        }

        if ($token[0] === T_CONSTANT_ENCAPSED_STRING) {
            $text = substr($token[1], 1, -1);
            $value = $token[1][0] === "'" ? strtr($text, ['\\\\' => '\\', "\\'" => "'"]) : stripcslashes($text);
            return true;
        }

        if ($token[0] === T_STRING && in_array(strtolower($token[1]), ['true', 'false'], true)) {
            $value = strtolower($token[1]) === 'true';
            return true;
        }

        return false;
    }

    function nexus_keep(array &$found, string $name, $value, bool $literal): void {
        if (! $literal || (array_key_exists($name, $found) && $found[$name] !== $value)) {
            $found[$name] = null;
            return;
        }

        $found[$name] = $value;
    }

    function nexus_read(string $file, array $constants, array $variables): array {
        $tokens = nexus_tokens($file);
        $found = [];

        foreach ($tokens as $index => $token) {
            $next = fn (int $offset) => $tokens[$index + $offset] ?? null;

            if (is_array($token) && in_array($token[0], [T_STRING, T_NAME_FULLY_QUALIFIED], true) && strtolower(ltrim($token[1], '\\')) === 'define'
                && $next(1) === '(' && nexus_literal($next(2), $name) && is_string($name) && $next(3) === ',' && in_array($name, $constants, true)) {
                $literal = nexus_literal($next(4), $value) && $next(5) === ')';
                nexus_keep($found, $name, $literal ? $value : null, $literal);
            }

            if (is_array($token) && $token[0] === T_VARIABLE && in_array(substr($token[1], 1), $variables, true) && $next(1) === '=') {
                $literal = nexus_literal($next(2), $value) && $next(3) === ';';
                nexus_keep($found, substr($token[1], 1), $literal ? $value : null, $literal);
            }
        }

        return $found;
    }

    $constants = ['DB_NAME', 'DB_USER', 'DB_PASSWORD', 'DB_HOST', 'WP_HOME', 'WP_SITEURL', 'MULTISITE', 'SUBDOMAIN_INSTALL', 'DOMAIN_CURRENT_SITE'];
    $config = $argv[1] === '' ? [] : nexus_read($argv[1], $constants, ['table_prefix']);
    $version = nexus_read($argv[2], [], ['wp_version']);

    echo json_encode(['config' => (object) $config, 'version' => $version['wp_version'] ?? null], JSON_INVALID_UTF8_SUBSTITUTE);
    """#

    struct Result: Equatable, Sendable {
        let config: WordPressConfig?
        let version: String?
    }

    private let php: URL
    private let environment: [String: String]

    init(php: URL, environment: [String: String]) {
        self.php = php
        self.environment = environment
    }

    // A config file of nil reads only the version, for example for Bedrock.
    func run(config: URL?, version: URL) async throws -> Result {
        let command = Command(
            executable: php,
            arguments: ["-d", "xdebug.mode=off", "-r", Self.source, "--", config?.path(percentEncoded: false) ?? "", version.path(percentEncoded: false)],
            environment: environment,
            stopSignal: SIGKILL
        )
        let output = try await withThrowingTaskGroup(of: CommandOutput?.self) { group in
            group.addTask { try await CommandRunner.run(command) }
            group.addTask {
                try await Task.sleep(for: Self.timeout)
                return nil
            }

            defer { group.cancelAll() }

            guard let finished = try await group.next(), let output = finished else {
                throw RuntimeError.unsupported("PHP did not read wp-config.php in \(Int(Self.timeout.components.seconds)) seconds.")
            }

            return output
        }

        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(output.standardOutput.utf8)) else {
            throw RuntimeError.unsupported("Nexus cannot read the answer of PHP about wp-config.php: \(output.standardError.suffix(300))")
        }

        return Result(config: config == nil ? nil : answer.config.wordPressConfig, version: answer.version)
    }

    private struct Answer: Decodable {
        let config: [String: ConfigValue]
        let version: String?
    }
}

private extension [String: ConfigValue] {
    var wordPressConfig: WordPressConfig {
        WordPressConfig(
            database: text("DB_NAME"),
            user: text("DB_USER"),
            password: text("DB_PASSWORD"),
            host: text("DB_HOST"),
            tablePrefix: text("table_prefix"),
            home: text("WP_HOME"),
            siteURL: text("WP_SITEURL"),
            multisite: flag("MULTISITE"),
            subdomainInstall: flag("SUBDOMAIN_INSTALL"),
            domainCurrentSite: text("DOMAIN_CURRENT_SITE")
        )
    }

    func text(_ name: String) -> String? {
        switch self[name] {
        case .text(let text): text
        case .number(let number): String(Int(number))
        default: nil
        }
    }

    func flag(_ name: String) -> Bool? {
        switch self[name] {
        case .flag(let flag): flag
        case .number(let number): number != 0
        case .text(let text): !text.isEmpty && text != "0"
        default: nil
        }
    }
}
