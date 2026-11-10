import Foundation
import NexusCore

// The agent reads these texts to choose a tool. So they must be exact. The level of a tool is the
// lowest access level that offers it.
public struct NexusToolSpec: Sendable {
    public let name: String
    public let title: String
    public let level: AgentLevel
    public let description: String
    public let properties: [String: JSONValue]
    public let required: [String]

    public var tool: MCPTool {
        var schema: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]

        if !required.isEmpty {
            schema["required"] = .array(required.map(JSONValue.string))
        }

        return MCPTool(name: name, title: title, description: description, inputSchema: .object(schema), readOnly: level == .read, destructive: level == .remove)
    }
}

public enum NexusTools {
    static let site: JSONValue = [
        "type": "string",
        "description": "A host such as shop.test, or a folder of a site or of a git worktree. The default is the project folder of this session.",
    ]

    static let mailSite: JSONValue = [
        "type": "string",
        "description": "A host or a folder of a site, or all for the whole inbox. A site includes the mail of its workspaces. The default is the project folder of this session.",
    ]

    public static let all: [NexusToolSpec] = [
        NexusToolSpec(
            name: "site_info",
            title: "Site info",
            level: .read,
            description: "The URL, folder, type and PHP version of a site, its database connections with the password, its test database, where its mail goes and its workspaces. Call this before you guess a URL, a port or a password.",
            properties: ["site": site],
            required: []
        ),
        NexusToolSpec(
            name: "list_sites",
            title: "List sites",
            level: .read,
            description: "All sites and workspaces of Nexus with their URL, folder, type and PHP version.",
            properties: [:],
            required: []
        ),
        NexusToolSpec(
            name: "status",
            title: "Nexus status",
            level: .read,
            description: "If Nexus runs, its services with their version, state and port, the tasks that run now and any problems.",
            properties: [:],
            required: []
        ),
        NexusToolSpec(
            name: "list_packages",
            title: "List packages",
            level: .read,
            description: "The installed and the available versions of PHP, Node.js and the services.",
            properties: [:],
            required: []
        ),
        NexusToolSpec(
            name: "php_extensions",
            title: "PHP extensions",
            level: .read,
            description: "The PHP extensions that the site requires (ext-* in composer.json and composer.lock) and if its PHP version has each one on.",
            properties: ["site": site],
            required: []
        ),
        NexusToolSpec(
            name: "last_errors",
            title: "Last errors",
            level: .read,
            description: "The newest errors of a site, newest first: the Laravel log (error and worse, with the stack trace), the PHP errors of the site and the requests that failed with status 500 or higher. Call this first when a page or a command fails.",
            properties: [
                "site": site,
                "limit": ["type": "integer", "minimum": 1, "maximum": 20, "description": "The number of errors. The default is 5."],
            ],
            required: []
        ),
        NexusToolSpec(
            name: "read_log",
            title: "Read a log",
            level: .read,
            description: "The last lines of one log of Nexus: the access log of a site, PHP-FPM, nginx, Apache, a service, a Node.js app or Nexus itself. Without `log`, it lists the logs.",
            properties: [
                "log": ["type": "string", "description": "The name of a log from the list, for example php-8.5, nginx, access:shop.test or nexus."],
                "lines": ["type": "integer", "minimum": 1, "maximum": 500, "description": "The number of lines. The default is 50."],
                "contains": ["type": "string", "description": "Only the lines with this text."],
            ],
            required: []
        ),
        NexusToolSpec(
            name: "list_mail",
            title: "List mail",
            level: .read,
            description: "The newest mails of the site in the Nexus inbox: id, time, from, to and subject. Mail never leaves this Mac.",
            properties: [
                "site": mailSite,
                "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "The number of mails. The default is 20."],
            ],
            required: []
        ),
        NexusToolSpec(
            name: "read_mail",
            title: "Read a mail",
            level: .read,
            description: "One mail: the headers, the text, each link with its link text, the codes (for example a login code) and the attachments. Use the id `latest` for the newest mail.",
            properties: [
                "id": ["type": "string", "description": "The id from list_mail, or latest. The default is latest."],
                "site": mailSite,
            ],
            required: []
        ),
        NexusToolSpec(
            name: "wait_for_mail",
            title: "Wait for a mail",
            level: .read,
            description: "Waits for a mail that matches `to` or `subject` and gives it as read_mail does. A mail counts from 60 seconds before the call. So call this after the action that sends the mail. It waits 30 seconds by default and 50 seconds at most. When no mail comes, call it again.",
            properties: [
                "to": ["type": "string", "description": "The address that gets the mail. With an address, the whole inbox counts."],
                "subject": ["type": "string", "description": "A word or a part of the subject."],
                "since": ["type": "string", "description": "An ISO 8601 time. Only a mail after this time counts. The default is 60 seconds before the call."],
                "seconds": ["type": "integer", "minimum": 1, "maximum": 50, "description": "How long to wait. The default is 30."],
                "site": mailSite,
            ],
            required: []
        ),
        NexusToolSpec(
            name: "start_service",
            title: "Start a service",
            level: .change,
            description: "Starts a service, for example MySQL 8.4. With `restart: true` it restarts a service that runs.",
            properties: [
                "service": ["type": "string", "description": "The service as status gives it, for example mysql-8.4, redis-8.2, php-8.5, nginx or mail."],
                "restart": ["type": "boolean", "description": "Restart the service when it runs."],
            ],
            required: ["service"]
        ),
        NexusToolSpec(
            name: "install_package",
            title: "Install a package",
            level: .change,
            description: "Installs a version of PHP, Node.js or a service, for example PHP 8.4 or Redis 7.4. This can take a minute.",
            properties: [
                "package": ["type": "string", "description": "The package as list_packages gives it, for example php, node, mysql, mariadb, postgresql, redis or mailpit."],
                "version": ["type": "string", "description": "The version line, for example 8.4."],
            ],
            required: ["package", "version"]
        ),
        NexusToolSpec(
            name: "set_php_extension",
            title: "Turn a PHP extension on or off",
            level: .change,
            description: "Turns a PHP extension on or off for one PHP version. PHP of that version restarts.",
            properties: [
                "extension": ["type": "string", "description": "The extension, for example xdebug, redis or imagick."],
                "on": ["type": "boolean", "description": "true turns it on, false turns it off."],
                "php": ["type": "string", "description": "The PHP version line, for example 8.4. The default is the PHP version of the site."],
                "site": site,
            ],
            required: ["extension", "on"]
        ),
        NexusToolSpec(
            name: "create_database",
            title: "Make a database",
            level: .change,
            description: "Makes an empty database on the database server of the site, for example a database for the tests.",
            properties: [
                "name": ["type": "string", "description": "The name of the new database, for example shop_testing."],
                "site": site,
            ],
            required: ["name"]
        ),
        NexusToolSpec(
            name: "create_workspace",
            title: "Make a workspace",
            level: .change,
            description: "Makes a git worktree for a branch and a workspace for it with its own URL and database. A worktree from `git worktree add` gets a workspace by itself, so use this only when you need a new branch. Waits up to 50 seconds until the workspace is ready.",
            properties: [
                "branch": ["type": "string", "description": "The branch. A new branch starts from the current branch of the main checkout."],
                "databases": ["type": "string", "enum": ["copy", "empty", "dump"], "description": "copy, empty or dump. The default is the choice of the site."],
                "site": site,
            ],
            required: ["branch"]
        ),
        NexusToolSpec(
            name: "add_site",
            title: "Add a site",
            level: .change,
            description: "Serves a project folder as a Nexus site at https://<name>.\(NexusVariant.current.tld).",
            properties: [
                "folder": ["type": "string", "description": "The project folder. The default is the project folder of this session."],
                "host": ["type": "string", "description": "The host, for example shop.test. The default is the folder name with the dev domain."],
                "php": ["type": "string", "description": "The PHP version line, for example 8.4. The default comes from the settings of Nexus."],
            ],
            required: []
        ),
        NexusToolSpec(
            name: "remove_workspace",
            title: "Remove a workspace",
            level: .remove,
            description: "Removes a workspace and its git worktree. Git refuses when the worktree has changes that are not committed. Nexus keeps a dump of its database in the trash for 7 days.",
            properties: [
                "workspace": ["type": "string", "description": "The name or the folder of the workspace. The default is the workspace of the project folder of this session."],
                "site": ["type": "string", "description": "The host of the site, when more sites have a workspace with this name."],
            ],
            required: []
        ),
        NexusToolSpec(
            name: "remove_site",
            title: "Remove a site",
            level: .remove,
            description: "Nexus stops serving the site. Its folder and its databases stay.",
            properties: [
                "site": ["type": "string", "description": "The host of the site, for example shop.test."],
            ],
            required: ["site"]
        ),
        NexusToolSpec(
            name: "stop_service",
            title: "Stop a service",
            level: .remove,
            description: "Stops a service. Each site that uses it gets errors until it starts again.",
            properties: [
                "service": ["type": "string", "description": "The service as status gives it, for example mysql-8.4."],
            ],
            required: ["service"]
        ),
        NexusToolSpec(
            name: "clear_mail",
            title: "Remove mail",
            level: .remove,
            description: "Removes the mails of the site from the Nexus inbox, or one mail with `id`.",
            properties: [
                "id": ["type": "string", "description": "The id of one mail, or latest."],
                "site": mailSite,
            ],
            required: []
        ),
    ]

    public static func spec(_ name: String) -> NexusToolSpec? {
        all.first { $0.name == name }
    }

    public static var readToolNames: [String] {
        all.filter { $0.level == .read }.map(\.name)
    }
}
