import Foundation
import Testing
@testable import NexusCore

struct BackupLayoutTests {
    private func entries(_ paths: [String]) -> [BackupEntry] {
        paths.map { BackupEntry(path: $0, size: $0.hasSuffix(".sql") || $0.hasSuffix(".gz") ? 100 : 0) }
    }

    @Test func anExportOfLocalHasItsSiteInAppPublic() throws {
        let layout = try #require(BackupLayout.detect(entries(["local-site.json", "app/public/wp-load.php", "app/public/wp-config.php", "app/public/wp-content/", "app/sql/local.sql", "conf/nginx/site.conf", "logs/"])))

        #expect(layout.format == .localExport)
        #expect(layout.siteRoot == "app/public")
        #expect(layout.dumps == ["app/sql/local.sql"])
        #expect(layout.hasCore)
        #expect(layout.hasConfig)
    }

    @Test func aLocalSiteFolderWithoutItsJSONIsACopyOfTheFolder() throws {
        let layout = try #require(BackupLayout.detect(entries(["./app/public/wp-content/themes/", "./app/sql/local.sql"])))

        #expect(layout.format == .localSiteFolder)
    }

    @Test func studioHasMetaJSONAndJetpackHasOneFileForEachTable() throws {
        let studio = try #require(BackupLayout.detect(entries(["meta.json", "wp-config.php", "wp-content/plugins/", "sql/studio-backup-db-export-2026-11-07-20-00-00.sql"])))
        let jetpack = try #require(BackupLayout.detect(entries(["wp-config.php", "wp-content/uploads/", "sql/wp_posts.sql", "sql/wp_options.sql", "sql/wp_posts-updates.sql", "sql/wp_comments.sql"])))

        #expect(studio.format == .studio)
        #expect(studio.metaFile == "meta.json")
        #expect(!studio.hasCore)
        #expect(jetpack.format == .jetpack)
        #expect(jetpack.dumps == ["sql/wp_comments.sql", "sql/wp_options.sql", "sql/wp_posts.sql", "sql/wp_posts-updates.sql"])
    }

    @Test func aFolderWithAWrapperFolderAndADumpNextToTheSite() throws {
        let layout = try #require(BackupLayout.detect(entries(["shop/wp-load.php", "shop/wp-content/", "shop/backup.sql.gz", "shop/old.sql"])))

        #expect(layout.format == .folder)
        #expect(layout.siteRoot == "shop")
        #expect(layout.hasCore)
        #expect(layout.dumps.count == 1)
    }

    @Test func aBackupWithoutWordPressOrWithoutADumpIsNoBackup() {
        #expect(BackupLayout.detect(entries(["photos/a.png", "backup.sql"])) == nil)
        #expect(BackupLayout.detect(entries(["wp-content/", "wp-load.php"])) == nil)
    }

    @Test func aNameOutsideTheFolderIsNotSafe() {
        #expect(BackupLayout.isSafe("uploads/2026/a.png"))
        #expect(!BackupLayout.isSafe("../etc/passwd"))
        #expect(!BackupLayout.isSafe("/etc/passwd"))
        #expect(!BackupLayout.isSafe("plugins/../../x"))
    }

    @Test func aWpressHeaderGivesNameSizeAndFolder() throws {
        var bytes = [UInt8](repeating: 0, count: WpressHeader.length)

        func put(_ text: String, at offset: Int) {
            for (index, byte) in text.utf8.enumerated() {
                bytes[offset + index] = byte
            }
        }

        put("akismet.php", at: 0)
        put("2048", at: 255)
        put("1794070000", at: 269)
        put("plugins/akismet", at: 281)

        let header = try #require(WpressHeader.parse(Data(bytes)))

        #expect(header.path == "plugins/akismet/akismet.php")
        #expect(header.size == 2048)
        #expect(WpressHeader.parse(Data(count: WpressHeader.length)) == nil)
    }
}

struct DumpScannerTests {
    @Test func theScannerFindsThePrefixAndTheURLsAlsoOverAPartBoundary() {
        var scanner = DumpScanner()
        let dump = """
            CREATE TABLE `shop_comments` (comment_ID bigint);
            INSERT INTO `shop_postmeta` VALUES (1,2,'home','https://wrong.example');
            CREATE TABLE `shop_options` (option_id bigint);
            INSERT INTO `shop_options` VALUES (1,'siteurl','https://shop.example/wp','yes'),(2,'home','https://shop.example','yes'),(3,'blogname','It\\'s a shop','yes');
            """
        let middle = dump.index(dump.startIndex, offsetBy: 230)

        scanner.scan(String(dump[..<middle]))
        scanner.scan(String(dump[middle...]))

        #expect(scanner.prefix == "shop_")
        #expect(scanner.home == "https://shop.example")
        #expect(scanner.siteURL == "https://shop.example/wp")
        #expect(scanner.url == "https://shop.example")
        #expect(scanner.isComplete)
    }

    @Test func theOptionsOfTheMainSiteOfANetworkCount() {
        var scanner = DumpScanner()
        scanner.scan("""
            CREATE TABLE `wp_2_options` (option_id bigint);
            INSERT INTO `wp_2_options` VALUES (1,'siteurl','https://two.example','yes'),(2,'home','https://two.example','yes');
            CREATE TABLE `wp_options` (option_id bigint);
            INSERT INTO `wp_options` VALUES (1,'siteurl','https://main.example','yes'),(2,'home','https://main.example','yes');
            """)

        #expect(scanner.prefix == "wp_")
        #expect(scanner.home == "https://main.example")
        #expect(scanner.isComplete)
    }

    @Test func aPrefixLikeASiteOfANetworkCountsWhenItIsTheOnlyOne() {
        var scanner = DumpScanner()
        scanner.scan("CREATE TABLE `site_1_options` (option_id bigint);\n")

        #expect(scanner.prefix == "site_1_")
        #expect(!scanner.isComplete)
    }

    @Test func theOptionsFileOfTheMainSiteIsScanned() {
        let layout = BackupLayout(format: .jetpack, siteRoot: "", dumps: ["sql/wp_2_options.sql", "sql/wp_options.sql", "sql/wp_posts.sql", "sql/wp_wc_options.sql"], hasCore: false, hasConfig: true, metaFile: nil)
        let single = BackupLayout(format: .studio, siteRoot: "", dumps: ["sql/export.sql"], hasCore: false, hasConfig: true, metaFile: nil)

        #expect(layout.optionsDump == "sql/wp_options.sql")
        #expect(single.optionsDump == "sql/export.sql")
    }

    @Test func aDumpOfAllInOneWPMigrationHasItsPlaceholderPrefix() {
        var scanner = DumpScanner()
        scanner.scan("CREATE TABLE `SERVMASK_PREFIX_options` (\nINSERT INTO `SERVMASK_PREFIX_options` VALUES (1,'home','http://a.example','yes');")

        #expect(scanner.prefix == "SERVMASK_PREFIX_")
        #expect(scanner.home == "http://a.example")
    }

    @Test func aBackupNameGivesTheNameOfTheSite() {
        #expect(BackupName.suggested(for: "/tmp/foo-2026-11-07.zip") == "foo")
        #expect(BackupName.suggested(for: "/tmp/My Shop backup 2.wpress") == "my-shop")
        #expect(BackupName.suggested(for: "/tmp/2026-11-07.tar.gz") == "site")
        #expect(BackupName.suggested(for: "/tmp/foo-local.zip") == "foo")
    }
}
