import Foundation

// A WordPress site names one instance in DB_HOST (Phase 4, 3e). Its object cache can use one Redis
// index. Its values come from wp-config.php or the .env of Bedrock. So the plan has no keys. It
// names the instance and the index for the server and the Redis index of the workspace.
extension WorkspaceEnvPlan {
    public static let wordPressRedisKey = "WP_REDIS_DATABASE"

    public init(wordPressDatabase name: String?, port: Int, redisPort: Int?, mainRedisIndex: Int) {
        self.init()

        serverPortKeys[port] = ["DB_HOST"]

        if let name {
            database = name
            databases = [WorkspaceDatabase(name: name, port: port, isDefault: true)]
        }

        if let redisPort {
            redisKeys = [Self.wordPressRedisKey]
            redisPorts = [redisPort]
            mainRedisIndexes = [mainRedisIndex]
        }
    }
}
