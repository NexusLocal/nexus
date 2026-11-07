import Foundation
import NexusCore
import NexusIPC

// Bedrock can set DB_HOST in .env.local. A .env reads as a file of Laravel. So a text names the
// Bedrock project with it.
extension WordPressSiteInfo {
    var configName: String {
        configFile.map { ($0 as NSString).lastPathComponent } ?? (type == .bedrock ? ".env" : "wp-config.php")
    }

    var configText: String {
        type == .bedrock ? "the \(configName) of this Bedrock project" : configName
    }

    var configTextAtStart: String {
        type == .bedrock ? "The \(configName) of this Bedrock project" : configName
    }
}

// The database connections of a Laravel site. The sample data gives the state of the design "Site".
extension AppModel {
    func siteDatabases(of site: SiteItem) async -> Result<[SiteDatabase], SiteDatabasesProblem> {
        guard isLive else {
            return .success([
                SiteDatabase(connection: "mysql", database: "shop", host: "127.0.0.1", port: 13306, instance: "mysql-8.0"),
                SiteDatabase(connection: "cms", database: "shop_cms", host: "127.0.0.1", port: 13306, instance: "mysql-8.0"),
            ])
        }

        switch await outcome(of: .siteDatabases(host: site.host)) {
        case .answer(.siteDatabases(let databases)):
            return .success(databases)
        case .failure(let message):
            return .failure(SiteDatabasesProblem(message: message))
        default:
            return .failure(SiteDatabasesProblem(message: "nexusd did not answer."))
        }
    }
}

struct SiteDatabasesProblem: Error {
    let message: String
}

// The configuration and the database of a WordPress site (Phase 4, 3b). The sample data gives the
// state of the design "Site · WordPress".
extension AppModel {
    func wordPressSite(of site: SiteItem) async -> WordPressSiteInfo? {
        guard isLive else {
            return WordPressSiteInfo(
                type: .wordpress,
                version: "7.1.4",
                configFile: "\(site.folder)/wp-config.php",
                database: "blog",
                dbHost: "127.0.0.1:13307",
                instance: "mysql-8.4",
                databaseExists: true,
                home: site.url,
                siteURL: site.url
            )
        }

        guard case .answer(.wordPressSite(let info))? = await outcome(of: .wordPressSite(host: site.host)) else {
            return nil
        }

        return info
    }

    func setUpWordPress(_ site: SiteItem, database: String, instance: String) async -> Bool {
        await sendWordPressChange(.setUpWordPress(host: site.host, database: database, instance: instance), failure: "Nexus did not set up WordPress for \(site.host)")
    }

    func createWordPressDatabase(_ site: SiteItem) async -> Bool {
        await sendWordPressChange(.createWordPressDatabase(host: site.host), failure: "Nexus did not make the database of \(site.host)")
    }

    func setWordPressDBHost(_ site: SiteItem, value: String) async -> Bool {
        await sendWordPressChange(.setWordPressDBHost(host: site.host, value: value), failure: "DB_HOST of \(site.host) did not change")
    }

    func changeWordPressURLs(_ site: SiteItem, plan: WordPressURLPlan) async -> Bool {
        await sendWordPressChange(.changeWordPressURLs(host: site.host, plan: plan), failure: "Nexus did not change the URLs of \(site.host)")
    }

    func undoWordPressURLChange(_ site: SiteItem, plan: WordPressURLPlan) async -> Bool {
        await sendWordPressChange(.undoWordPressURLChange(host: site.host, plan: plan), failure: "Nexus did not undo the URL change of \(site.host)")
    }

    // "Copy to Nexus…" opens the import sheet with the server and the account of wp-config.php.
    func copyWordPressDatabase(_ site: SiteItem, instance: String) async {
        guard isLive else {
            sheet = .importDatabase(instance: instance, source: WordPressCopySource(server: DatabaseServer(port: 8889), database: "blog", instance: instance))
            return
        }

        if case .wordPressCopySource(let source)? = await perform(.wordPressCopySource(host: site.host), failure: "Nexus cannot copy the database of \(site.host)", place: .window) {
            sheet = .importDatabase(instance: source.instance, source: source)
        }
    }

    func turnOffMailPlugins(_ site: SiteItem, folders: [String]) async -> Bool {
        await sendWordPressChange(.turnOffMailPlugins(host: site.host, folders: folders), failure: "Nexus did not turn off the mail plugins of \(site.host)")
    }

    private func sendWordPressChange(_ request: NexusRequest, failure: String) async -> Bool {
        guard isLive else {
            return true
        }

        let changed = await perform(request, failure: failure, place: .window) != nil

        if changed {
            wordPressChanges += 1
        }

        return changed
    }
}
