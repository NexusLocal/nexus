# Nexus - decision record

Result of the design interview on 2026-10-26. Nexus is a free macOS app that serves local
websites, PHP, databases and Redis, like MAMP PRO and Herd Pro. Its main feature is workspaces:
an isolated copy of a site for each git worktree. So many tickets can run at the same time, each
with its own domain, database and processes.

Nexus must work for every Laravel application. The evidence below comes from the 22 sites in the
owner's MAMP PRO setup (19 Laravel applications, Laravel 8.83 to 13.38). The record describes
these applications by their patterns, not by their names.

Out of scope: Memcached, Mailhog, Dynamic DNS and Valkey.

## Decisions

### Product

1. Nexus is for other users too. The owner tests it locally first.
2. Nexus is free. There is no license key, no paid tier and no payment code.
3. Version 1 contains everything in this record. There is no split into version 1 and 2.
4. Native Swift and SwiftUI app for Apple silicon. The minimum is macOS 27, for the app and
   for all binaries. Risk: users on macOS 26 or older cannot install Nexus. CI builds on the
   `xcode-27` runner (macOS 27, Apple silicon), generally available since 2026-10-15.
5. UI: a main window for sites and services, and a menu bar item for status, start and stop.
   "Start at login" is a setting that is on by default. The menu bar item opens a small panel
   with the services, their switches and the running tasks. It lists no sites, because a user
   can have many. A setting shows the app icon in the Dock, in the menu bar or in both. (user,
   step 6 design)
6. App updates use Sparkle.
6b. The Apple team Rood Fruit B.V. signs the releases of Nexus. (user) The team has no active
    paid membership now, so it cannot sign yet. Release signing (Developer ID and
    notarization) needs the paid Apple Developer Program. Reopen in step 10.
    The repository contains no team. Each developer sets their own team in
    Config/Signing.local.xcconfig, which git ignores. The owner uses the free Personal Team.
6c. Bundle IDs: nl.roodfruit.nexus for the app, with .daemon, .helper and .cli for the other
    programs. Chosen by Claude from roodfruit.nl, the domain of the team. It cannot change after
    the first release.

### Binaries

7. Nexus uses only binaries that it installed itself, in ~/Library/Application Support/Nexus.
   It never uses a binary from MAMP PRO, Homebrew, the system or the PATH. A PHP 8.5 in MAMP
   PRO does not count as a PHP 8.5 for Nexus.
8. Nexus downloads prebuilt binaries. GitHub Actions builds them and GitHub Releases hosts them.
   Homebrew is not the source: its bottles work only in /opt/homebrew, which the user's own
   installs share, and other users may not have Homebrew.
9. Both repositories are in the GitHub organization NexusLocal (created 2026-10-26):
   NexusLocal/nexus for the app and NexusLocal/binaries for the build scripts.
   The build scripts go in a separate public repository. Standard GitHub-hosted runners are free
   for public repositories. A public repository with links to the source also covers the GPL
   rule for the MySQL and MariaDB binaries.
   Source: docs.github.com/en/billing/reference/actions-runner-pricing.
10. Node is not compiled. Nexus downloads the official macOS arm64 builds from nodejs.org and
    checks them against SHASUMS256.txt.
11. Nexus ships Composer (composer.phar) and runs it only with its own PHP.
12. Each version line gets the newest patch release. A binary update comes from a manifest in
    the build repository. Nexus keeps a version that gets no security fixes any more and marks
    it as such in the window.

### Versions in version 1

Dates are the end of security fixes, from endoflife.date on 2026-10-26.

13. PHP: 8.2 (2026-12-31), 8.3, 8.4, 8.5.
14. MySQL: 8.0 (ended 2026-04-30), 8.4 LTS, 9.7 LTS.
15. MariaDB: 10.11, 11.4, 11.8, 12.3. All are LTS.
16. PostgreSQL: 14 (2026-11-12), 15, 16, 17, 18.
17. Redis: 7.2, 8.2 and the newest 8 (now 8.10). 7.2 has the BSD license. Redis 8 has AGPLv3
    as one of its licenses. 7.4 is left out: its licenses are RSALv2 or SSPLv1, and RSALv2
    forbids distribution "in a manner that makes the functionality of the Software available to
    third parties" (redis.io/legal/rsalv2-agreement).
18. nginx: the newest stable line (now 1.30). One version only, because nginx is the front
    server for all sites.
19. Apache: 2.4 (now 2.4.69).
20. Node: 22, 24, 26.
21. A site gets its Node version from .nvmrc, .node-version, .tool-versions or "engines" in
    package.json, else the newest LTS. A setting can override it. A project that asks for a
    version that Nexus does not have gets the oldest newer line: .nvmrc 16 and 20 give Node 22.
    The app shows it as "22 (.nvmrc asks for 20)". (owner, step 7)
    Evidence: on the owner's Mac, one project has .nvmrc 16, one has .nvmrc 20.10.0 and one has
    only .tool-versions.

### Web servers, PHP, DNS and SSL

22. Each site chooses Apache or nginx. nginx is the default for a new site.
23. nginx always listens on 80 and 443 and does TLS for all sites. It serves nginx sites itself
    and proxies Apache sites to Apache on an internal port. Apache sets HTTPS=on from
    X-Forwarded-Proto and takes the client IP from mod_remoteip. So PHP sees HTTPS without a
    TrustProxies change in the application.
24. nginx and Apache bind *:80 and *:443 as the normal user. Access rules allow only loopback by
    default. A LAN setting can open it.
    Evidence: a test on macOS 27. 0.0.0.0:81 binds as a normal user. 127.0.0.1:81 gives
    "Permission denied".
25. Module toggles: Apache uses LoadModule lines. nginx is built with --with-compat, and the
    toggles cover the modules that nginx can load as dynamic modules. The modules that the front
    needs (ssl, http2, proxy) cannot be turned off.
26. PHP runs as php-fpm, one master for each PHP version. Every PHP process gets
    OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES.
    Evidence: php-cgi children of MAMP PRO crash on macOS 27 because the parent loads the
    Objective-C runtime before it forks.
    Every PHP process also gets OS_ACTIVITY_MODE=disable. Evidence: a php-fpm worker of PHP 8.5
    crashed in the SQLite of macOS when it wrote its first log line after the fork. In a test,
    9 of 80 forks crashed without the setting and 0 of 80 with it.
27. Extensions follow the MAMP model. Core extensions are built into the binary. Optional
    extensions (xdebug, pcov, opcache, redis, imagick, igbinary, apcu, yaml and more) are shared
    .so files. Nexus turns them on or off in the php.ini of that PHP version, not for one site.
    Evidence: MAMP PHP 8.4.17 has 43 built-in modules and 18 shared .so files.
28. DNS: a wildcard resolver for the dev TLD (.test by default) through /etc/resolver/test and a
    small DNS server in Nexus. /etc/hosts gets lines only for hosts outside the dev TLD, such as
    .local hosts. Reason: workspaces add hosts often, and MAMP PRO writes 78 lines to /etc/hosts.
    The dev TLD can only be .test, .internal or .localhost. Reason: a resolver file for a real
    TLD, such as .dev, sends every lookup of that TLD on the Mac to Nexus. (user)
29. SSL: Nexus makes its own root CA. The user trusts it one time. Nexus signs a certificate for
    each host and each workspace. The CA private key stays in the login keychain.
    Nexus signs certificates and writes /etc/hosts lines only for names that end in .test,
    .localhost, .internal, .local, .example, .invalid or .home.arpa. The root CA has name
    constraints for the same names. Reason: every program of the user can run the nexus CLI. A
    certificate for a public name such as github.com would let that program read the HTTPS
    traffic of the browser. (security review of step 3)
30. One small privileged helper (SMAppService) writes /etc/resolver/<tld> and the /etc/hosts
    lines. It refuses every other path. The trust of the root CA needs no helper: it is a trust
    setting in the login keychain, and macOS asks for the password. The DNS server needs no
    root either: it listens on a high port, and /etc/resolver sets that port (resolver(5)).
31. Ports: defaults 80, 443, 3306, 5432 and 6379. When a port is in use, Nexus shows the process
    that holds it and offers two actions: stop that app, or pick another port. Every port of
    every service can change, in the app and with `nexus port <service> <port>`. (user)
32. One launchd user agent, nexusd, starts and watches all services as child processes. So
    services keep running when the window closes, and the user sees one background item. The
    app and the CLI talk to nexusd over XPC.

### Sites and databases

33. A site comes from an added folder or from a parked folder, where each subfolder is a site.
    The document root is public/ when it exists, else the folder.
34. More than one version of a service can run at the same time. Each instance has its own
    version, port and data folder. Nexus has one instance for each installed version line, for
    example mysql-8.0 and mysql-8.4. (step 5)
35. A new database instance gets the user root without a password, on 127.0.0.1 only. The user
    can change the account of each instance, and the default for new instances in Settings.
    The MAMP PRO import sets root/root on the instances that it fills, because MAMP PRO sites
    have DB_PASSWORD=root in their .env. (user, step 6 design. Was root/root for every
    instance.)
36. A button opens a database through its mysql:// or postgresql:// link, in the app that the
    user chose in Settings > Databases. Nexus finds the installed database apps, and the user
    can add one. Nexus has no built-in admin tool. (user, step 6 design)
37. Import from MAMP PRO: the hosts (name, aliases, document root, PHP version, SSL). Database
    data comes over with the action "copy a database from another server" (a dump and a
    restore through the port). The tools of the instance that receives the copy make the dump,
    so no tool of MAMP PRO runs (D7). The clients use the plugin folder of their package.
    Evidence: without it, the MySQL 9.7 client cannot log in to MAMP PRO, where root has
    mysql_native_password. (step 5)

### CLI

38. A `nexus` CLI ships with the app. `nexus php`, `nexus composer`, `nexus node` and
    `nexus npm` pick the version of the site that contains the current folder.
    `nexus workspace info --json` gives the URL, the databases and the ports of a workspace.
39. By default Nexus changes no shell file. A setting "Add Nexus to PATH" is off by default.
    When it is on, Nexus adds one line at the end of ~/.zshrc that puts
    ~/Library/Application Support/Nexus/bin first on the PATH. Turning it off removes the line.
    It must be the end of ~/.zshrc: zsh reads ~/.zshrc last, and a ~/.zshrc can add other PHP
    folders to the front of the PATH. An alias still wins over the PATH.
    While the setting is on, the app shows each of php, composer, node and npm that the terminal
    does not run from Nexus, with the reason, for example an alias. The user must know when
    another program runs instead of Nexus. (owner, step 7)

### Workspaces

40. Nexus creates a workspace for each new worktree of a site, and removes it when the worktree
    goes away. A site setting turns this off. It is on by default. `nexus workspace create`
    works when the setting is off. `nexus workspace wait` waits until a workspace is ready.
    A worktree that exists when Nexus gets the site, or that comes while the setting is off,
    gets no workspace by itself. The setting does not stop a removal.
    Evidence: 9 sites have worktrees, up to 14 for one site.
41. The workspace name is the worktree folder name in lowercase. Every character outside a-z,
    0-9 and - becomes -. TICKET-123 becomes ticket-123. A name has at most 40 characters and
    no - at its start or end, because it goes into a host. A name with no other characters
    becomes workspace.
42. Domain: every host keeps its subdomains. The label before the TLD gets "-<workspace>".
    my.shop.test becomes my.shop-ticket-123.test. A host outside the dev TLD gets the dev
    TLD: blog.local becomes blog-ticket-123.test.
    Reason: for the browser each workspace is a separate site, so no cookie goes between the
    main site and a workspace. A prefix such as "workspace." is not used: some applications bind
    their routes to a fixed subdomain (one application binds all routes to "my.").
43. Nexus reads the configuration of the application, not only its .env. It boots the
    application with its own PHP and runs only the bootstrappers LoadEnvironmentVariables and
    LoadConfiguration, so no service provider runs. It sets a unique marker value for each env
    key that config/*.php uses. So Nexus learns which env key feeds which database, Redis,
    session, cache, queue and broadcast setting. A key that the probe does not find gives a
    fixed setting. So a missed key gives a workspace that is not isolated (D48), and not a
    workspace that writes into the main database. A last pass changes only the keys of the
    database names and the Redis indexes, as a workspace does. A setting that does not follow
    its key in this pass also counts as fixed.
    Evidence: one application hardcodes 'default' => 'main' in config/database.php and has four MySQL
    connections and four Redis connections. Four sites use their own connection names (app,
    cms, crm, main). Some keys have no line in .env and use the default in the config file.
44. The workspace .env: when the worktree has no .env, Nexus copies the .env of the main
    checkout. Nexus then changes only these values, and keeps all other lines:
    - Hosts: every value that contains a host of the site, or its parent domain with a leading
      dot, gets the workspace host. This covers APP_URL, SESSION_DOMAIN and custom keys.
      Evidence: sites use SESSION_DOMAIN=.${APP_HOST}, ${APP_DOMAIN}, .shop.test and
      site.local.
    - Databases: see 46.
    - Redis: see 47.
    When an env key that Nexus must change has no line in .env, Nexus adds the line.
45. A site can add more keys with placeholders: {workspace}, {host}, {database} and
    {port:<name>}. Each {port:<name>} gets its own free port for each workspace. Use this for
    services that Nexus does not manage, such as Pusher or a search server.
46. Databases: Nexus copies every database of the site that is on a Nexus MySQL, MariaDB or
    PostgreSQL instance. The copy is called <database>_<workspace>. A - of the workspace name
    becomes _ in the copy, because a - needs quotes in each query. Nexus changes each env key
    that feeds the name of such a database. A SQLite file gets an APFS clone. A file in
    write-ahead mode or with a rollback journal gets a backup with sqlite3, because a clone can
    then hold a part of a write.
47. Redis: one instance for each Redis version. Each env key of a Redis index gets its own
    index in each workspace, from 16 up, because the main sites use the indexes below 16.
    Connections that share one env key share one index in a workspace. Nexus can set only that
    key. Nexus starts Redis with 256 databases, so 240 indexes are for workspaces. An index with
    keys, an index of the main site and an index in the .env or config/database.php of another
    site are not free. A workspace without a free index is "not isolated".
48. Safety: when a database name or a Redis index comes from a hardcoded value and not from an
    env key, Nexus cannot isolate it. The same applies to a default connection or a used Redis
    connection that is not on a Nexus instance, to a name in a URL, to a cached configuration
    and to a .env that git does not ignore. Then the workspace is "not isolated". Nexus shows which
    connection is the cause and starts no background process for that workspace. Reason: a
    workspace that writes into the main database is worse than no workspace.
49. Files: Nexus makes APFS clones (copy on write) of vendor, node_modules, the build output,
    storage/app and the Passport keys in storage from the main checkout. The build output is each
    path that git ignores in public, dist and build. A clone takes seconds and uses no extra disk until a file changes. Nexus runs `composer install` only when composer.lock is different from the
    main checkout, and the same for package-lock.json. No symlinks: a `composer require` in a
    worktree would then change the main checkout.
50. Nexus never writes a file that git sees. Before it writes .env or makes a clone, it checks
    the path with `git check-ignore`. When the path is not ignored, Nexus skips it and shows a
    warning.
51. Each site has a list of commands that Nexus runs after the database copy. For example: reset
    a custom domain that the application keeps in its database.
52. Background processes: each site has a list of commands that every workspace runs as its own
    copy. A site setting turns this on or off. It is on by default. For a Laravel site the list
    starts with a preset that follows the configuration:
    - `php artisan queue:work` when the queue connection is not sync.
    - `php artisan schedule:work`.
    - `php artisan reverb:start --port={port:reverb}` when the broadcast connection is reverb.
      Nexus also changes the Reverb port keys.
    - `npm run dev -- --port {port:vite} --strictPort` when the site has a vite.config file.
    An asset process is in the preset only when its output folder is ignored by git.
    Evidence: one application uses Laravel Mix and has 115 built files in public/ in git. A build in
    a workspace would change those files.
    The same list can run for the main checkout. That switch is off by default.
53. Removal: Nexus removes a workspace only when git no longer lists the worktree. Before it drops
    a workspace database, it writes a compressed dump to the Nexus trash folder. The trash keeps
    a dump for 7 days (a setting). Nexus empties the Redis indexes of the workspace.
54. A site that is not a Laravel application gets a workspace with only the domain, the
    certificate and the file clones.
55. Site settings live in the storage of Nexus, not in the repository.

### Installation and design

56. The app contains no service. Nexus downloads every package from the manifest itself. At
    the first launch the user picks what to install, and the window can install or remove any
    version later. Reason: the app download stays small, and packages outside the app bundle do
    not need a Developer ID signature or notarization. (user: "the user is in charge")
    The first launch preselects nginx, the newest PHP and Composer. Everything else starts
    unselected. (user)
    nginx, at least one PHP version and Composer are required at the first launch. Every site
    needs nginx, and workspaces need Composer. (user, step 6 design)
57. The UI is designed in pen.dev first (through its MCP), so the owner can say what must
    change before it is built. The app uses the standard macOS 27 controls and styling as much
    as possible, not custom components. (user)
    The design is docs/design/nexus.pen. The owner approved it on 2026-10-27. Its frame "UX
    Rules" holds the rules for every screen. Two of them differ from Apple's guidelines (user):
    - All text uses sentence case. Only names and abbreviations keep their capitals.
    - "webserver" is one word.
58. Sites can go in named groups. The user sets the order of the groups and the sites by hand,
    and "Sort by name" sorts the groups, the sites outside a group and the sites in each group.
    The sidebar can collapse its sections, each group and the workspaces of each site. (user)
    The order by hand needs drag and drop, which comes in phase 2 of docs/plan.md. Until then,
    "Move to group" puts a site in a group. (user, 2026-10-27)
59. Settings > Sites holds the defaults for a new site: webserver, PHP, Node, background
    processes, commands after the database copy and environment keys. A change does not change
    existing sites. (user)
60. Each PHP version has custom php.ini lines. Nexus adds them after its own settings, checks
    them before the restart, and keeps the old lines when a line has an error. The app shows
    the line and the error. (user)
61. Settings > General holds the terminal app and the code editor. Nexus finds the installed
    apps, and the user can add one. A site then has "Open in <app>" actions. Notifications for a
    stopped service, a ready workspace and a finished import are settings too. (user)
62. nexusd watches each parked folder. A new folder in it becomes a site with the defaults,
    without the app. (user)
63. "Stop all services" remembers which services ran. "Start stopped services" starts only
    those. There is no "Start all", because it would also start services that the user turned
    off. (user)
64. The app has a "Command line" page that lists the nexus commands with a copy button. (user)
65. A name of a site outside the dev TLD, for example an alias blog.local, gets its /etc/hosts
    line without a setting. So Settings has no list of host names. `nexus hosts` stays for a
    name that belongs to no site. (user)

## Open and deferred

- Remove docs/ from the public repository and from its history. The owner wants this
  eventually. Reopen before the first release to other users.

- Public or private for the app repository. Reopen when CI for the app itself is set up.
- PHP 7.4, 8.0 and 8.1. PHP 7.x needs patches to build against OpenSSL 3. Reopen when a user
  asks for one of them.
- Import from Herd. Reopen when a user asks for it.
- A settings file in the repository that a team can share. Reopen when a team asks for it.
- A Claude Code plugin that tells Claude the workspace URL and the `nexus php` command. Reopen
  after version 1 works.
- An MCP server, so AI tools can use Nexus through MCP tools next to the nexus CLI. Reopen after
  version 1 works. (user, 2026-10-27)

## Plan changes from the interview

- Removed: Homebrew as the binary source. Added: a separate public build repository with CI.
  All other work depends on it.
- Removed: Valkey.
- Added: Node, Composer, the `nexus` CLI, the privileged helper, Sparkle, background processes
  for each workspace, the database dump before a workspace is removed, and the MAMP PRO import.
- Added: nginx as the fixed front server, also for Apache sites.
- Added: Nexus reads the real configuration of each application, so workspaces work for every
  Laravel application and not only for applications with a standard .env.
- Rejected: a version 2 for part of the features.
