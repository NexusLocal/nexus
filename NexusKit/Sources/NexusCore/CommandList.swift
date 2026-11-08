// The nexus commands that the Command line page of the app lists, each with an example (D64).
// A test parses every example with the nexus command, and checks that the list has every
// command of nexus.
public struct CommandItem: Sendable, Identifiable {
    public let command: String
    public let help: String

    public var id: String { command }

    public init(command: String, help: String) {
        self.command = command
        self.help = help
    }
}

public struct CommandSection: Sendable, Identifiable {
    public let title: String
    public let commands: [CommandItem]

    public var id: String { title }

    public init(title: String, commands: [CommandItem]) {
        self.title = title
        self.commands = commands
    }
}

extension CommandSection {
    public static let all: [CommandSection] = [
        CommandSection(title: "Sites", commands: [
            CommandItem(command: "nexus site list", help: "Lists the sites."),
            CommandItem(command: "nexus site add . --php 8.4", help: "Adds the current folder as a site."),
            CommandItem(command: "nexus new laravel foo --kit react", help: "Makes a new site from a template: laravel, wordpress, next, nuxt, vite or astro."),
            CommandItem(command: "nexus import ~/Downloads/foo.wpress", help: "Makes a WordPress site from a backup of Local, Jetpack, Studio or All-in-One WP Migration, or from a folder with a dump."),
            CommandItem(command: "nexus site edit shop.test --server apache", help: "Changes the kind, the PHP version, the Node version, the webserver, the aliases or the workspace settings. --workspace-databases empty gives new workspaces an empty database."),
            CommandItem(command: "nexus site remove shop.test", help: "Removes a site. The folder stays."),
            CommandItem(command: "nexus site defaults --php 8.4", help: "Changes the PHP version, the Node version or the webserver of a new site."),
            CommandItem(command: "nexus site probe .", help: "Shows which env key feeds each setting of a Laravel application."),
            CommandItem(command: "nexus site wordpress blog.test", help: "Shows the WordPress version and the database of a WordPress site. --set-up, --create-database and --set-db-host do what the buttons on the Site screen do."),
            CommandItem(command: "nexus park ~/Sites", help: "Makes each folder in ~/Sites a site."),
            CommandItem(command: "nexus unpark ~/Sites", help: "Stops a folder of projects. Its folders stay."),
        ]),
        CommandSection(title: "Workspaces", commands: [
            CommandItem(command: "nexus workspace create", help: "Makes a workspace for the current worktree. --databases empty gives it an empty database."),
            CommandItem(command: "nexus workspace wait", help: "Waits until the workspace is ready."),
            CommandItem(command: "nexus workspace info --json", help: "Gives the URL, the databases and the ports."),
            CommandItem(command: "nexus workspace list", help: "Lists the workspaces of the current site."),
            CommandItem(command: "nexus workspace remove", help: "Removes the workspace and keeps a dump."),
            CommandItem(command: "nexus workspace env shop.test", help: "Shows which keys Nexus changes in the .env of a workspace."),
            CommandItem(command: "nexus workspace retry shop.test ticket-123", help: "Sets up a workspace again, for example after you fix why it is not isolated."),
        ]),
        CommandSection(title: "Services", commands: [
            CommandItem(command: "nexus status", help: "Lists the services and their state."),
            CommandItem(command: "nexus start mysql-8.4", help: "Starts a service."),
            CommandItem(command: "nexus stop mysql-8.4", help: "Stops a service."),
            CommandItem(command: "nexus restart mysql-8.4", help: "Stops a service and starts it again."),
            CommandItem(command: "nexus stop --all", help: "Stops every service."),
            CommandItem(command: "nexus start --stopped", help: "Starts the services again after nexus stop --all."),
            CommandItem(command: "nexus port mysql-8.4 13307", help: "Gives a service another port."),
        ]),
        CommandSection(title: "Packages", commands: [
            CommandItem(command: "nexus available", help: "Lists the packages that Nexus can install."),
            CommandItem(command: "nexus installed", help: "Lists the installed packages."),
            CommandItem(command: "nexus install redis 8.2", help: "Installs a package."),
            CommandItem(command: "nexus remove redis 8.2", help: "Removes a package."),
        ]),
        CommandSection(title: "Databases", commands: [
            CommandItem(command: "nexus db list", help: "Lists the database instances."),
            CommandItem(command: "nexus db copy shop --to mysql-8.4", help: "Imports a database from another server."),
            CommandItem(command: "nexus db open mysql-8.4 shop", help: "Opens a database in your database app."),
            CommandItem(command: "nexus db dumps", help: "Lists the dumps of removed workspaces in the Nexus trash."),
            CommandItem(command: "nexus db restore <dump> --to mysql-8.4 --as shop_ticket_1", help: "Restores a dump into a new database."),
            CommandItem(command: "nexus db account mysql-8.4 root", help: "Changes the user of an instance. --password gives it a password."),
        ]),
        CommandSection(title: "PHP and tools", commands: [
            CommandItem(command: "nexus php -v", help: "Runs the PHP of the site in the current folder."),
            CommandItem(command: "nexus composer install", help: "Runs Composer with that PHP."),
            CommandItem(command: "nexus node -v", help: "Runs the Node of the site in the current folder."),
            CommandItem(command: "nexus npm ci", help: "Runs npm with the Node of the site."),
            CommandItem(command: "nexus wp option get siteurl", help: "Runs WP-CLI with the PHP of the site."),
            CommandItem(command: "nexus ext 8.4 xdebug on", help: "Turns a PHP extension on or off."),
            CommandItem(command: "nexus ini 8.4 \"memory_limit = 512M\"", help: "Replaces the custom php.ini lines of a PHP version."),
            CommandItem(command: "nexus module apache rewrite off", help: "Turns a webserver module on or off."),
        ]),
        CommandSection(title: "Mail", commands: [
            CommandItem(command: "nexus mail", help: "Opens the inbox of the mail service in the browser."),
            CommandItem(command: "nexus mail list --site shop.test", help: "Lists the newest mails, of one site or workspace with --site. --json prints JSON."),
            CommandItem(command: "nexus mail show latest", help: "Shows a mail with its text. --json gives the HTML, the headers and the files too."),
            CommandItem(command: "nexus mail remove latest", help: "Removes one mail from the inbox, or more with more ids."),
            CommandItem(command: "nexus mail clear", help: "Removes all mails from the inbox."),
            CommandItem(command: "nexus mail outbox", help: "Shows the mails that wait for the mail service. --clear removes them."),
            CommandItem(command: "nexus mail settings --outbox-mails 500", help: "Changes the limits of the outbox and the inbox. Without options it shows them."),
            CommandItem(command: "nexus site mail shop.test", help: "Shows where a site sends its mail. --send-to-nexus sends the mail of a Laravel site to the inbox. --restore puts the old mail settings back. --turn-off-plugins turns off the mail plugins of a WordPress site."),
            CommandItem(command: "nexus sendmail -S 127.0.0.1:1025 -t", help: "Gives the mail on the input to the mail service. PHP runs it for mail()."),
        ]),
        CommandSection(title: "Domains and certificates", commands: [
            CommandItem(command: "nexus tld internal", help: "Gives every site a name in another dev domain."),
            CommandItem(command: "nexus trust", help: "Trusts the Nexus root certificate."),
            CommandItem(command: "nexus cert shop.test", help: "Makes a certificate for one or more names."),
            CommandItem(command: "nexus hosts", help: "Lists the names that Nexus adds to /etc/hosts."),
            CommandItem(command: "nexus hosts add blog.local", help: "Sends a name to this Mac through /etc/hosts."),
            CommandItem(command: "nexus hosts remove blog.local", help: "Removes the /etc/hosts line of a name."),
            CommandItem(command: "nexus lan on", help: "Lets other devices on the network open the sites."),
            CommandItem(command: "nexus uninstall", help: "Removes everything that Nexus changed in macOS."),
        ]),
    ]
}
