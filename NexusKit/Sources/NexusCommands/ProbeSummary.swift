import NexusCore

// The lines of nexus site probe. A row has the path of a setting, its value and the env key that
// feeds it.
enum ProbeSummary {
    static func lines(_ configuration: LaravelConfiguration) -> [String] {
        let rows = paths(configuration).compactMap { path in
            configuration.settings[path].map { (path: path, value: withoutPassword($0.value.description), source: source($0)) }
        }
        let pathWidth = rows.map(\.path.count).max() ?? 0
        let valueWidth = rows.map(\.value.count).max() ?? 0

        return ["Laravel \(configuration.version)", ""] + rows.map { row in
            [row.path.padding(to: pathWidth), row.value.padding(to: valueWidth), row.source].joined(separator: "  ")
        }
    }

    private static func paths(_ configuration: LaravelConfiguration) -> [String] {
        let databases = configuration.databaseConnections.flatMap { name in
            ["driver", "database", "host", "port", "url"].map { "database.connections.\(name).\($0)" }
        }
        let redis = configuration.redisConnections.flatMap { name in
            ["database", "host", "port", "url"].map { "database.redis.\(name).\($0)" }
        }

        return ["app.url", "database.default"] + databases + ["database.redis.client", "database.redis.options.prefix"] + redis + [
            "session.driver", "session.connection", "session.domain", "session.cookie",
            "cache.default", "cache.prefix", "queue.default", "broadcasting.default",
        ]
    }

    // A connection URL can hold a password. Users paste this output in tickets and chats.
    private static func withoutPassword(_ value: String) -> String {
        value.replacing(#/:\/\/([^:@\/]*):.*@/#) { match in "://\(match.output.1):***@" }
    }

    private static func source(_ setting: ConfigSetting) -> String {
        guard !setting.isFixed else {
            return "fixed in a config file"
        }

        return setting.keys.joined(separator: ", ") + (setting.exact ? "" : " (changed by the application)")
    }
}
