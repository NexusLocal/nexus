import NexusCore
import Testing
@testable import NexusLaravel

struct BackgroundPresetTests {
    private func configuration(_ settings: [String: ConfigSetting]) -> LaravelConfiguration {
        LaravelConfiguration(version: "12.0.0", settings: settings, databaseConnections: [], redisConnections: [])
    }

    private func setting(_ value: String) -> ConfigSetting {
        ConfigSetting(value: .text(value))
    }

    private let queue = "php artisan queue:work"
    private let schedule = "php artisan schedule:work"
    private let reverb = "php artisan reverb:start --port={port:reverb}"
    private let vite = "npm run dev -- --port {port:vite} --strictPort"

    @Test func aRedisQueueGetsAWorkerAndTheScheduler() {
        let settings = ["queue.default": setting("redis"), "queue.connections.redis.driver": setting("redis")]

        #expect(BackgroundPreset.commands(for: configuration(settings), runsVite: false) == [queue, schedule])
    }

    @Test(arguments: ["sync", "null", "deferred", "background"])
    func aQueueThatRunsInTheApplicationGetsNoWorker(_ driver: String) {
        let settings = ["queue.default": setting("own"), "queue.connections.own.driver": setting(driver)]

        #expect(BackgroundPreset.commands(for: configuration(settings), runsVite: false) == [schedule])
    }

    @Test func aQueueWithoutAConnectionBlockUsesItsName() {
        #expect(BackgroundPreset.commands(for: configuration(["queue.default": setting("sync")]), runsVite: false) == [schedule])
    }

    @Test func theBroadcastDriverDecidesReverbAlsoUnderAnotherConnectionName() {
        let settings = ["broadcasting.default": setting("live"), "broadcasting.connections.live.driver": setting("reverb")]

        #expect(BackgroundPreset.commands(for: configuration(settings), runsVite: true) == [schedule, reverb, vite])
    }

    @Test func aPusherConnectionGetsNoReverb() {
        let settings = ["broadcasting.default": setting("pusher"), "broadcasting.connections.pusher.driver": setting("pusher")]

        #expect(BackgroundPreset.commands(for: configuration(settings), runsVite: false) == [schedule])
    }

    @Test func theOutputOfViteComesFromItsConfiguration() {
        #expect(BackgroundPreset.viteOutput(inConfiguration: "laravel({ input: 'a.js' })") == "public/build/")
        #expect(BackgroundPreset.viteOutput(inConfiguration: "laravel({ buildDirectory: 'assets' })") == "public/assets/")
        #expect(BackgroundPreset.viteOutput(inConfiguration: #"build: { outDir: "dist" }"#) == "dist/")
    }

    @Test func theMainCheckoutUsesThePortOfItsReverbServer() {
        let settings = ["reverb.default": setting("own"), "reverb.servers.own.port": ConfigSetting(value: .number(8081))]

        #expect(BackgroundPreset.reverbServerPort(configuration(settings)) == 8081)
        #expect(BackgroundPreset.reverbServerPort(configuration([:])) == nil)
    }

    @Test func theDatabaseNameOfTheMainCheckoutIsTheNameOfTheDefaultConnection() {
        let named = ["database.default": setting("main"), "database.connections.main.database": setting("shop")]
        let withoutName = ["database.default": setting("main"), "database.connections.main.database": ConfigSetting(value: .null)]
        let emptyName = ["database.default": setting("main"), "database.connections.main.database": setting("")]

        #expect(BackgroundPreset.databaseName(configuration(named)) == "shop")
        #expect(BackgroundPreset.databaseName(configuration(withoutName)) == nil)
        #expect(BackgroundPreset.databaseName(configuration(emptyName)) == nil)
    }
}
