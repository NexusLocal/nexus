import Foundation
import Testing
@testable import NexusCore

struct NodeProjectTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "Nexus Node Projects \(UUID().uuidString)", directoryHint: .isDirectory)

    private func makeFolder(_ path: String, files: [String: String] = [:]) throws -> URL {
        let folder = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for (name, text) in files {
            try Data(text.utf8).write(to: folder.appending(path: name))
        }

        return folder
    }

    private func package(scripts: [String: String] = [:], dependencies: [String: String] = [:], devDependencies: [String: String] = [:], packageManager: String? = nil) throws -> String {
        var object: [String: Any] = ["name": "app", "scripts": scripts, "dependencies": dependencies, "devDependencies": devDependencies]
        object["packageManager"] = packageManager
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test func theDevScriptComesBeforeTheStartScript() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let both = try makeFolder("both", files: ["package.json": try package(scripts: ["start": "next start", "dev": "next dev"])])
        let start = try makeFolder("start", files: ["package.json": try package(scripts: ["start": "node server.js", "dev": ""])])
        let none = try makeFolder("none", files: ["package.json": try package(scripts: ["build": "vite build"])])

        #expect(NodeProject.read(in: both)?.command == "npm run dev")
        #expect(NodeProject.read(in: start)?.command == "npm run start")
        #expect(NodeProject.read(in: none)?.command == nil)
        #expect(NodeProject.read(in: root) == nil)
    }

    @Test func theFrameworkComesFromTheDependencies() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let svelte = try makeFolder("svelte", files: ["package.json": try package(devDependencies: ["vite": "^8", "@sveltejs/kit": "^3"])])
        let next = try makeFolder("next", files: ["package.json": try package(dependencies: ["next": "16.4.0", "react": "19"])])
        let plain = try makeFolder("plain", files: ["package.json": try package(dependencies: ["left-pad": "1"])])

        #expect(NodeProject.read(in: svelte)?.framework == .sveltekit)
        #expect(NodeProject.read(in: next)?.framework == .next)
        #expect(NodeProject.read(in: plain)?.framework == nil)
    }

    @Test func theLockFilePicksThePackageManager() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let pnpm = try makeFolder("pnpm", files: ["package.json": try package(scripts: ["dev": "vite"]), "pnpm-lock.yaml": "", "package-lock.json": "{}"])
        let bun = try makeFolder("bun", files: ["package.json": try package(scripts: ["dev": "vite"]), "bun.lock": ""])
        let declared = try makeFolder("declared", files: ["package.json": try package(scripts: ["dev": "vite"], packageManager: "yarn@4.6.0+sha512.abc")])

        #expect(NodeProject.read(in: pnpm)?.command == "pnpm run dev")
        #expect(NodeProject.read(in: bun)?.packageManager == .bun)
        #expect(NodeProject.read(in: declared)?.packageManager == .yarn)
        #expect(PackageManager.yarn.usesCorepack)
        #expect(!PackageManager.bun.usesCorepack)
    }

    @Test func aLockFileInAParentCountsOnlyInsideTheGitCheckout() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeFolder("monorepo", files: ["pnpm-lock.yaml": ""])
        _ = try makeFolder("monorepo/.git")
        let app = try makeFolder("monorepo/apps/web", files: ["package.json": try package(scripts: ["dev": "nuxt dev"])])
        _ = try makeFolder("loose", files: ["yarn.lock": ""])
        let outside = try makeFolder("loose/app", files: ["package.json": try package(scripts: ["dev": "nuxt dev"])])

        #expect(NodeProject.read(in: app)?.packageManager == .pnpm)
        #expect(NodeProject.read(in: outside)?.packageManager == .npm)
    }

    @Test func composerJSONMakesAPHPSiteAndADevScriptMakesANodeApp() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let laravel = try makeFolder("laravel", files: ["composer.json": "{}", "package.json": try package(scripts: ["dev": "vite"])])
        let laravelPublic = try makeFolder("laravel/public")
        let next = try makeFolder("next", files: ["package.json": try package(scripts: ["dev": "next dev"])])
        let library = try makeFolder("library", files: ["package.json": try package(scripts: ["test": "vitest"])])
        let empty = try makeFolder("empty")

        #expect(SiteKind.detected(in: laravel) == .php)
        #expect(SiteKind.detected(in: laravelPublic) == .php)
        #expect(SiteKind.detected(in: next) == .node)
        #expect(SiteKind.detected(in: library) == .php)
        #expect(SiteKind.detected(in: empty) == .php)
    }

    @Test func theViteServerGetsItsPortAfterTheScript() {
        let npm = NodeProject(script: "dev", framework: .vite, packageManager: .npm, scriptText: "vite")
        let pnpm = NodeProject(script: "dev", framework: .astro, packageManager: .pnpm, scriptText: "astro dev")

        #expect(NodeAppLaunch.make(command: nil, project: npm, port: 20001, hosts: ["shop.test"], tld: "test")?.command == "npm run dev -- --port 20001 --strictPort")
        #expect(NodeAppLaunch.make(command: nil, project: pnpm, port: 20001, hosts: ["shop.test"], tld: "test")?.command == "pnpm run dev --port 20001 --strictPort")
    }

    @Test func nextAndNuxtReadPORTAndNuxtAlsoGetsHOST() {
        let next = NodeAppLaunch.make(command: nil, project: NodeProject(script: "dev", framework: .next, packageManager: .npm, scriptText: "next dev"), port: 20002, hosts: ["shop.internal", "shop.local"], tld: "internal")
        let nuxt = NodeAppLaunch.make(command: nil, project: NodeProject(script: "dev", framework: .nuxt, packageManager: .yarn, scriptText: "nuxt dev"), port: 20003, hosts: ["shop.test"], tld: "test")

        #expect(next?.command == "npm run dev")
        #expect(next?.environment == ["PORT": "20002", "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS": ".internal"])
        #expect(next?.warnings == [])
        #expect(nuxt?.command == "yarn run dev")
        #expect(nuxt?.environment["HOST"] == "127.0.0.1")
    }

    @Test func anAliasOutsideTheDevTLDGetsAWarningForTheViteServer() {
        let launch = NodeAppLaunch.make(command: nil, project: NodeProject(script: "dev", framework: .sveltekit, packageManager: .npm, scriptText: "vite dev"), port: 20007, hosts: ["shop.test", "shop.local"], tld: "test")

        #expect(launch?.warnings == ["SvelteKit allows only the hosts in .test without a change. Add shop.local to server.allowedHosts in the configuration of Vite."])
    }

    @Test func aCommandOfTheUserGetsTheEnvironmentAndNoFlags() {
        let launch = NodeAppLaunch.make(command: "vite --port 20004", project: NodeProject(script: "dev", framework: .vite, packageManager: .npm), port: 20004, hosts: ["shop.test"], tld: "test")

        #expect(launch?.command == "vite --port 20004")
        #expect(launch?.environment["PORT"] == "20004")
        #expect(NodeAppLaunch.make(command: nil, project: NodeProject(script: nil, framework: .vite, packageManager: .npm), port: 1, hosts: [], tld: "test") == nil)
        #expect(NodeAppLaunch.make(command: nil, project: nil, port: 1, hosts: [], tld: "test") == nil)
    }

    @Test func aScriptWithItsOwnPortGetsAWarningAndNoSecondPort() {
        let vite = NodeAppLaunch.make(command: nil, project: NodeProject(script: "dev", framework: .vite, packageManager: .npm, scriptText: "vite --port 3000"), port: 20005, hosts: ["shop.test"], tld: "test")
        let next = NodeAppLaunch.make(command: nil, project: NodeProject(script: "dev", framework: .next, packageManager: .npm, scriptText: "next dev -p 3001"), port: 20006, hosts: ["shop.test"], tld: "test")

        #expect(vite?.command == "npm run dev")
        #expect(vite?.warnings == ["The dev script of package.json sets its own port, so Nexus cannot give the app port 20005. Remove the port from the script, or set a command that uses {port:app}."])
        #expect(next?.warnings.count == 1)
    }

    @Test func onlyAPortFlagWithANumberSetsThePort() {
        let texts = ["vite --port 3000": true, "vite --port=3000": true, "next dev -p 3001": true, "next dev --turbopack": false, "tsc -p tsconfig.json && vite": false, "npm-run-all -p dev:*": false, "vite --portless": false]

        for (text, setsPort) in texts {
            #expect(NodeProject(script: "dev", framework: .vite, packageManager: .npm, scriptText: text).scriptSetsPort == setsPort, "\(text)")
        }
    }

    @Test func aParkedProjectGetsTheKindOfItsFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let parked = try makeFolder("parked")
        _ = try makeFolder("parked/shop", files: ["composer.json": "{}"])
        _ = try makeFolder("parked/web", files: ["package.json": try package(scripts: ["dev": "astro dev"])])

        let sites = ParkedFolder(folder: parked, php: "8.5").sites(tld: "test")

        #expect(sites.map(\.host) == ["shop.test", "web.test"])
        #expect(sites.map(\.kind) == [.php, .node])
    }
}
