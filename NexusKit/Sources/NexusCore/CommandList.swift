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
            CommandItem(command: "nexus site edit shop.test --server apache", help: "Changes the PHP version, the webserver or the aliases."),
            CommandItem(command: "nexus site remove shop.test", help: "Removes a site. The folder stays."),
            CommandItem(command: "nexus site defaults --php 8.4", help: "Changes the PHP version or the webserver of a new site."),
            CommandItem(command: "nexus park ~/Sites", help: "Makes each folder in ~/Sites a site."),
            CommandItem(command: "nexus unpark ~/Sites", help: "Stops a folder of projects. Its folders stay."),
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
            CommandItem(command: "nexus db account mysql-8.4 root", help: "Changes the user of an instance. --password gives it a password."),
        ]),
        CommandSection(title: "PHP and webservers", commands: [
            CommandItem(command: "nexus ext 8.4 xdebug on", help: "Turns a PHP extension on or off."),
            CommandItem(command: "nexus ini 8.4 \"memory_limit = 512M\"", help: "Replaces the custom php.ini lines of a PHP version."),
            CommandItem(command: "nexus module apache rewrite off", help: "Turns a webserver module on or off."),
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
