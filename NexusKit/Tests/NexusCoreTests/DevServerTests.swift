import Foundation
import Testing
@testable import NexusCore

struct DevServerTests {
    @Test func onlyACommandWithThePortOfViteIsADevServer() {
        #expect(DevServer.isDevServer("npm run dev -- --port {port:vite} --strictPort"))
        #expect(DevServer.isDevServer("pnpm dev --port {port:vite}"))
        #expect(!DevServer.isDevServer("php artisan queue:work"))
        #expect(!DevServer.isDevServer("php artisan reverb:start --port={port:reverb}"))
    }

    @Test func theNameIsTheCommandBeforeItsFirstOption() {
        #expect(DevServer.displayName(of: "npm run dev -- --port {port:vite} --strictPort") == "npm run dev")
        #expect(DevServer.displayName(of: "pnpm dev --port {port:vite}") == "pnpm dev")
    }

    @Test func theBuildUsesTheSamePackageManager() {
        #expect(DevServer.buildCommand(for: "npm run dev -- --port {port:vite}") == "npm run build")
        #expect(DevServer.buildCommand(for: "pnpm dev --port {port:vite}") == "pnpm run build")
        #expect(DevServer.buildCommand(for: "npx vite --port {port:vite}") == "npm run build")
    }

    @Test func theHotFileGivesThePortOfItsAddress() {
        #expect(DevServer.port(inHotFile: "http://[::1]:5173") == 5173)
        #expect(DevServer.port(inHotFile: "http://localhost:20005\n") == 20005)
        #expect(DevServer.port(inHotFile: "https://shop.test:5173") == 5173)
        #expect(DevServer.port(inHotFile: "not a url") == nil)
    }

    @Test func theChoicesHaveTheirTitlesAndNeverHasNoDuration() throws {
        #expect(DevServerStop.allCases.map(\.title) == ["1 minute", "5 minutes", "15 minutes", "30 minutes", "Never"])
        #expect(DevServerStop.never.duration == nil)
        #expect(DevServerStop.fiveMinutes.duration == 300)
        #expect(DevServerStop.standard == .fiveMinutes)

        for stop in DevServerStop.allCases {
            let data = try JSONEncoder().encode(stop)
            #expect(try JSONDecoder().decode(DevServerStop.self, from: data) == stop)
        }
    }
}
