import NexusCore
import Testing
@testable import NexusCommands

struct ProbeSummaryTests {
    @Test func aRowShowsThePathTheValueAndTheSource() {
        let configuration = LaravelConfiguration(
            version: "12.0.0",
            settings: [
                "database.default": ConfigSetting(value: .text("main")),
                "database.connections.main.database": ConfigSetting(value: .text("shop"), keys: ["DB_DATABASE"], exact: true),
                "cache.prefix": ConfigSetting(value: .text("shop:"), keys: ["CACHE_PREFIX"], exact: false),
                "services.mail.key": ConfigSetting(value: .text("hidden")),
            ],
            databaseConnections: ["main"],
            redisConnections: []
        )

        #expect(ProbeSummary.lines(configuration) == [
            "Laravel 12.0.0",
            "",
            "database.default                    main   fixed in a config file",
            "database.connections.main.database  shop   DB_DATABASE",
            "cache.prefix                        shop:  CACHE_PREFIX (changed by the application)",
        ])
    }

    @Test(arguments: [
        ("redis://:secret@127.0.0.1:6379", "redis://:***@127.0.0.1:6379"),
        ("mysql://root:s/e@cret@127.0.0.1/shop", "mysql://root:***@127.0.0.1/shop"),
        ("https://shop.test", "https://shop.test"),
    ])
    func aRowHidesThePasswordInAURL(url: String, shown: String) {
        let configuration = LaravelConfiguration(
            version: "12.0.0",
            settings: ["database.redis.default.url": ConfigSetting(value: .text(url), keys: ["REDIS_URL"], exact: true)],
            databaseConnections: [],
            redisConnections: ["default"]
        )

        #expect(ProbeSummary.lines(configuration).last == "database.redis.default.url  \(shown)  REDIS_URL")
    }
}
