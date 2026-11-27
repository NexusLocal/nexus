import Foundation
import Testing
@testable import NexusCore

// The files of Local 10.2.0 in the VM local-golden (docs/group11-local.md), made smaller.
struct LocalReaderTests {
    private struct Fixture {
        let root: URL
        let local: URL
        let services: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "nexus-local-\(UUID().uuidString)", directoryHint: .isDirectory)
            local = root.appending(path: "Library/Application Support/Local", directoryHint: .isDirectory)
            services = root.appending(path: "Local.app/lightning-services", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        }

        func write(_ text: String, to path: String, in folder: URL) throws {
            let file = folder.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    static let sitesJSON = #"""
    {
      "7CQOwD38y": {
        "id": "7CQOwD38y", "name": "shop", "path": "~/Local Sites/shop", "domain": "shop.local",
        "localVersion": "10.2.0+7022", "mysql": {"database": "local", "user": "root", "password": "root"},
        "environment": "custom",
        "services": {
          "mailpit": {"name": "mailpit", "version": "1.24.1", "type": "lightning", "ports": {"WEB": [10000], "SMTP": [10001]}},
          "php": {"name": "php", "version": "8.2.29", "type": "lightning", "role": "php", "ports": {"cgi": [10002]}},
          "mysql": {"name": "mysql", "version": "8.4.0", "type": "lightning", "role": "db", "ports": {"MYSQL": [10003]}},
          "nginx": {"name": "nginx", "version": "1.26.1", "type": "lightning", "role": "http", "ports": {"HTTP": [10004]}}
        },
        "multiSite": "", "xdebugEnabled": false
      },
      "S_bEHv3bc": {
        "id": "S_bEHv3bc", "name": "blog", "path": "~/Local Sites/blog", "domain": "blog.local",
        "mysql": {"database": "local", "user": "root", "password": "root"},
        "services": {
          "php": {"name": "php", "version": "7.4.30", "type": "lightning", "role": "php", "ports": {"cgi": [10007]}},
          "mysql": {"name": "mysql", "version": "8.0.35", "type": "lightning", "role": "db", "ports": {"MYSQL": [10008]}},
          "apache": {"name": "apache", "version": "2.4.43", "type": "lightning", "role": "http", "ports": {"HTTP": [10009]}}
        },
        "multiSite": ""
      },
      "XTJpXZnEh": {
        "id": "XTJpXZnEh", "name": "subnet", "path": "~/Local Sites/subnet", "domain": "subnet.local",
        "mysql": {"database": "local", "user": "root", "password": "root"},
        "services": {
          "php": {"name": "php", "version": "8.3.30", "type": "lightning", "role": "php", "ports": {"cgi": [10022]}},
          "mysql": {"name": "mysql", "version": "8.0.35", "type": "lightning", "role": "db", "ports": {"MYSQL": [10023]}},
          "nginx": {"name": "nginx", "version": "1.26.1", "type": "lightning", "role": "http", "ports": {"HTTP": [10024]}}
        },
        "multiSite": "ms-subdomain",
        "multiSiteDomains": ["http://subnet.local", "http://one.subnet.local/"]
      },
      "broken": {"name": "no id"}
    }
    """#

    static let nginxTemplate = """
    server {
    \tlisten 127.0.0.1:{{port}};
        root   "{{root}}";

        index index.php index.html index.htm;

    \tinclude includes/restrictions.conf;
    }
    """

    @Test func localGivesItsSitesWithTheirServicesAndFolders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.sitesJSON, to: "sites.json", in: fixture.local)
        try fixture.write(#"{"7CQOwD38y":"running","S_bEHv3bc":"halted"}"#, to: "site-statuses.json", in: fixture.local)

        let setup = try #require(LocalReader.read(local: fixture.local, home: fixture.root, bundledServices: fixture.services))
        let shop = try #require(setup.sites.first { $0.domain == "shop.local" })
        let blog = try #require(setup.sites.first { $0.domain == "blog.local" })
        let subnet = try #require(setup.sites.first { $0.domain == "subnet.local" })

        #expect(setup.sites.map(\.domain) == ["blog.local", "shop.local", "subnet.local"])
        #expect(setup.tld == "local")
        #expect(shop.folder == fixture.root.appending(path: "Local Sites/shop", directoryHint: .isDirectory).standardizedFileURL)
        #expect(shop.webRoot.path(percentEncoded: false).hasSuffix("Local Sites/shop/app/public/"))
        #expect(shop.php == "8.2.29")
        #expect(shop.server == .nginx)
        #expect(shop.databaseKind == "mysql")
        #expect(shop.databaseVersion == "8.4.0")
        #expect(shop.databasePort == 10003)
        #expect(shop.database == "local")
        #expect(shop.user == "root" && shop.password == "root")
        #expect(shop.status == "running")
        #expect(shop.socket == fixture.local.appending(path: "run/7CQOwD38y/mysql/mysqld.sock"))
        #expect(shop.dataFolder == fixture.local.appending(path: "run/7CQOwD38y/mysql/data", directoryHint: .isDirectory))
        #expect(shop.dump.path(percentEncoded: false).hasSuffix("Local Sites/shop/app/sql/local.sql"))
        #expect(blog.server == .apache)
        #expect(blog.php == "7.4.30")
        #expect(subnet.network == .subdomains)
        #expect(subnet.networkDomains == ["one.subnet.local"])
        #expect(setup.certificate(of: "shop.local") == fixture.local.appending(path: "run/router/nginx/certs/shop.local.crt"))
    }

    @Test func aSiteBeforeLocal51KeepsItsDataInMysqlRawData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.sitesJSON, to: "sites.json", in: fixture.local)
        try FileManager.default.createDirectory(at: fixture.local.appending(path: "run/7CQOwD38y/mysql-raw-data"), withIntermediateDirectories: true)

        let setup = try #require(LocalReader.read(local: fixture.local, home: fixture.root, bundledServices: nil))
        let shop = try #require(setup.sites.first { $0.domain == "shop.local" })

        #expect(shop.dataFolder.lastPathComponent == "mysql-raw-data")
    }

    @Test func theOwnLinesAreTheLinesThatTheUserAddedToTheTemplate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.sitesJSON, to: "sites.json", in: fixture.local)
        try fixture.write(Self.nginxTemplate, to: "nginx-1.26.1+3/conf/site.conf.hbs", in: fixture.services)
        let site = Self.nginxTemplate.replacingOccurrences(of: "index index.php index.html index.htm;", with: "index index.php index.html index.htm;\n    add_header X-Shop-Test \"moved\" always;\n    location /api {\n        return 204;\n    }")
        try fixture.write(site, to: "Local Sites/shop/conf/nginx/site.conf.hbs", in: fixture.root)

        let setup = try #require(LocalReader.read(local: fixture.local, home: fixture.root, bundledServices: fixture.services))
        let shop = try #require(setup.sites.first { $0.domain == "shop.local" })

        #expect(shop.ownLines == [#"add_header X-Shop-Test "moved" always;"#, "location /api {", "return 204;", "}"])
    }

    @Test func thePHPLinesAreTheValuesThatDifferFromTheTemplateOfTheVersion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.sitesJSON, to: "sites.json", in: fixture.local)
        let template = "[PHP]\nmax_execution_time = 1200\nmax_input_vars = 4000\nmemory_limit = 256M\nerror_log = \"{{logs.errorLog}}\"\n{{#if os.windows}}\nextension=php_curl.dll\n{{/if}}\n"
        try fixture.write(template, to: "php-8.2.29+0/conf/php.ini.hbs", in: fixture.local.appending(path: "lightning-services"))
        let site = template.replacingOccurrences(of: "memory_limit = 256M", with: "memory_limit = 512M").replacingOccurrences(of: "max_input_vars = 4000", with: "max_input_vars = 5000")
        try fixture.write(site, to: "Local Sites/shop/conf/php/php.ini.hbs", in: fixture.root)

        let setup = try #require(LocalReader.read(local: fixture.local, home: fixture.root, bundledServices: nil))
        let shop = try #require(setup.sites.first { $0.domain == "shop.local" })

        #expect(shop.phpIniLines == ["max_input_vars = 5000", "memory_limit = 512M"])
    }

    @Test func withoutTheTemplateOfItsVersionASiteHasNoOwnLines() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.sitesJSON, to: "sites.json", in: fixture.local)
        try fixture.write("server {\n  add_header X-Test 1;\n}\n", to: "Local Sites/shop/conf/nginx/site.conf.hbs", in: fixture.root)

        let setup = try #require(LocalReader.read(local: fixture.local, home: fixture.root, bundledServices: fixture.services))

        #expect(setup.sites.first { $0.domain == "shop.local" }?.ownLines == [])
    }

    @Test func withoutSitesJSONThereIsNoLocal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(LocalReader.read(local: fixture.local, home: fixture.root, bundledServices: nil) == nil)
    }

    @Test func theDatabaseNameComesFromTheFirstLabelOfTheHost() {
        #expect(DatabaseName.suggestion(from: "shop.local") == "shop")
        #expect(DatabaseName.suggestion(from: "my-shop.local") == "my_shop")
        #expect(DatabaseName.suggestion(from: "") == "site")
    }
}
