import Foundation
import Testing
@testable import NexusCore

struct PHPProjectTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "Nexus PHP Projects \(UUID().uuidString)", directoryHint: .isDirectory)

    private func folder(_ name: String, files: [String: String]) throws -> URL {
        let folder = root.appending(path: name, directoryHint: .isDirectory)

        for (path, text) in files {
            let file = folder.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func eachProjectGetsItsType() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bedrock = try folder("bedrock", files: ["composer.json": #"{"require": {"roots/bedrock-autoloader": "^1.0"}}"#, "web/wp/wp-load.php": "<?php"])
        let oldBedrock = try folder("old-bedrock", files: ["web/wp-config.php": "<?php", "config/application.php": "<?php"])
        let laravel = try folder("laravel", files: ["artisan": "", "bootstrap/app.php": "<?php", "composer.json": "{}"])
        let classic = try folder("classic", files: ["wp-config.php": "<?php", "wp-load.php": "<?php", "index.php": "<?php"])
        let download = try folder("download", files: ["wordpress/wp-load.php": "<?php", "wordpress/index.php": "<?php"])
        let configOnly = try folder("config-only", files: ["wp-config.php": "<?php"])
        let deeper = try folder("deeper", files: ["site/wordpress/wp-load.php": "<?php"])
        let plain = try folder("plain", files: ["index.php": "<?php"])

        #expect(PHPProject.type(of: bedrock) == .bedrock)
        #expect(PHPProject.type(of: oldBedrock) == .bedrock)
        #expect(PHPProject.type(of: laravel) == .laravel)
        #expect(PHPProject.type(of: classic) == .wordpress)
        #expect(PHPProject.type(of: download) == .wordpress)
        #expect(PHPProject.type(of: configOnly) == .other)
        #expect(PHPProject.type(of: deeper) == .other)
        #expect(PHPProject.type(of: plain) == .other)
        #expect(PHPProjectType.bedrock.isWordPress && PHPProjectType.wordpress.isWordPress && !PHPProjectType.laravel.isWordPress)
    }

    @Test func twoFoldersWithWordPressGiveNoWordPressFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let two = try folder("two", files: ["one/wp-load.php": "<?php", "other/wp-load.php": "<?php"])

        #expect(PHPProject.wordPressFolder(in: two) == nil)
    }

    @Test func aLinkToACopyOfWordPressIsTheWordPressFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try folder("core", files: ["wp-load.php": "<?php", "index.php": "<?php"])
        let site = try folder("site", files: ["wp-config.php": "<?php"])
        let link = site.appending(path: "wordpress")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: core)

        #expect(PHPProject.wordPressFolder(in: site)?.lastPathComponent == "wordpress")
        #expect(PHPProject.type(of: site) == .wordpress)
    }

    @Test func bedrockServesWebRadicleServesPublicAndAClassicSiteServesTheFolderWithIndex() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bedrock = try folder("bedrock", files: ["composer.json": "roots/bedrock-autoloader", "web/index.php": "<?php"])
        let radicle = try folder("radicle", files: ["composer.json": "roots/bedrock-autoloader", "public/index.php": "<?php", "public/wp/wp-load.php": "<?php"])
        let beforeInstall = try folder("before-install", files: ["composer.json": "roots/bedrock-autoloader"])
        let download = try folder("download", files: ["wordpress/wp-load.php": "<?php", "wordpress/index.php": "<?php"])
        let ownDirectory = try folder("own", files: ["index.php": "<?php require __DIR__ . '/wordpress/wp-blog-header.php';", "wordpress/wp-load.php": "<?php", "wordpress/index.php": "<?php"])

        #expect(Site(host: "a.test", folder: bedrock, php: "8.4").documentRoot.lastPathComponent == "web")
        #expect(Site(host: "r.test", folder: radicle, php: "8.4").documentRoot.lastPathComponent == "public")
        #expect(Site(host: "i.test", folder: beforeInstall, php: "8.4").documentRoot.lastPathComponent == "before-install")
        #expect(Site(host: "b.test", folder: download, php: "8.4").documentRoot.lastPathComponent == "wordpress")
        #expect(Site(host: "c.test", folder: ownDirectory, php: "8.4").documentRoot.lastPathComponent == "own")
        #expect(PHPProject.wordPressFolder(in: radicle)?.path(percentEncoded: false).hasSuffix("/public/wp/") == true)
    }

    @Test func aBedrockSiteOnWebBelongsToItsProject() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bedrock = try folder("bedrock", files: ["composer.json": "roots/bedrock-autoloader", "web/index.php": "<?php"])
        let other = try folder("other", files: ["web/index.php": "<?php"])
        let site = Site(host: "a.test", folder: bedrock.appending(path: "web", directoryHint: .isDirectory), php: "8.4")
        let otherSite = Site(host: "b.test", folder: other.appending(path: "web", directoryHint: .isDirectory), php: "8.4")

        #expect(ProjectFolder.projectFolder(of: site) == RealPath.of(bedrock))
        #expect(ProjectFolder.workspaceKey(of: site) == RealPath.of(bedrock))
        #expect(PHPProject.type(of: site) == .bedrock)
        #expect(ProjectFolder.projectFolder(of: otherSite) == RealPath.of(other.appending(path: "web")))
    }

    @Test func wordPressWithAPackageFileIsAPHPSite() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let theme = try folder("theme", files: ["wp-load.php": "<?php", "package.json": #"{"scripts": {"dev": "vite"}}"#])
        let headless = try folder("headless", files: ["package.json": #"{"scripts": {"dev": "next dev"}}"#, "cms/wp-load.php": "<?php"])

        #expect(SiteKind.detected(in: theme) == .php)
        #expect(SiteKind.detected(in: headless) == .node)
    }
}
