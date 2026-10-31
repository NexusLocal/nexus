import NexusCore

// The list of background processes that a Laravel site starts with (D52). A queue with one of these
// drivers runs its jobs in the application, so it needs no worker.
public enum BackgroundPreset {
    private static let driversWithoutWorker: Set<String> = ["sync", "null", "deferred", "background"]

    public static let hotFile = "public/hot"

    // runsVite says that the site has a vite.config file and that git ignores what Vite writes.
    public static func commands(for configuration: LaravelConfiguration, runsVite: Bool) -> [String] {
        var commands = needsWorker(configuration) ? ["php artisan queue:work"] : []

        commands.append("php artisan schedule:work")

        if usesReverb(configuration) {
            commands.append("php artisan reverb:start --port={port:reverb}")
        }

        if runsVite {
            commands.append("npm run dev -- --port {port:vite} --strictPort")
        }

        return commands
    }

    public static func usesReverb(_ configuration: LaravelConfiguration) -> Bool {
        let settings = configuration.settings
        let connection = settings["broadcasting.default"]?.value.description ?? ""

        return settings["broadcasting.connections.\(connection).driver"]?.value.description == "reverb"
    }

    // The port of the Reverb server of the main checkout. The .env of the main checkout does not
    // change, so the server must stay on the port that the application connects to.
    public static func reverbServerPort(_ configuration: LaravelConfiguration) -> Int? {
        let settings = configuration.settings
        let server = settings["reverb.default"]?.value.description ?? "reverb"

        return settings["reverb.servers.\(server).port"].flatMap { Int($0.value.description) }
    }

    // The name for {database} in the main checkout. An application without a database name has none.
    public static func databaseName(_ configuration: LaravelConfiguration) -> String? {
        let settings = configuration.settings
        let connection = settings["database.default"]?.value.description ?? ""

        guard let name = settings["database.connections.\(connection).database"]?.value, name != .null, name != .text("") else {
            return nil
        }

        return name.description
    }

    // The folder that a build of Vite writes to, with a slash at its end. git check-ignore needs that
    // slash for a folder that does not exist and that .gitignore names with a slash.
    public static func viteOutput(inConfiguration source: String) -> String {
        if let directory = source.firstMatch(of: #/buildDirectory\s*:\s*['"]([^'"]+)['"]/#) {
            return "public/\(directory.output.1)/"
        }

        if let directory = source.firstMatch(of: #/outDir\s*:\s*['"]([^'"]+)['"]/#) {
            return "\(directory.output.1)/"
        }

        return "public/build/"
    }

    private static func needsWorker(_ configuration: LaravelConfiguration) -> Bool {
        let settings = configuration.settings

        guard let connection = settings["queue.default"]?.value.description else {
            return false
        }

        let driver = settings["queue.connections.\(connection).driver"]?.value.description ?? connection

        return !driversWithoutWorker.contains(driver)
    }
}
