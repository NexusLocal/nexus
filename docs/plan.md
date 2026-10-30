# Nexus - build plan

This plan turns docs/decisions.md into work. Read the decisions first. A number such as (D44)
points to decision 44 in that file.

## Rules for all work

- Do not touch MAMP PRO, its data or its config. Read access only, for the import and for tests.
- Do not use the existing worktrees of any project for tests. Make a new worktree for each test,
  and remove it after the test.
- Do not run a destructive database command on a server that Nexus did not create. A dump from
  MAMP is permitted. A drop, a truncate or a migrate:fresh is not.
- Until MAMP PRO is gone, Nexus runs on development ports: 8080, 8443, 13306, 15432 and 16379.
  So MAMP PRO keeps working during the build. A setting changes the ports later (D31).
- Every step ends with checks that a person can run. A step is done when all its checks pass.

## Architecture

Four programs:

| Program | Runs as | Job |
| --- | --- | --- |
| Nexus.app | the user | The window and the menu bar item. A client of nexusd. |
| nexusd | a launchd agent of the user | Starts and watches all services. Keeps the state. Serves an XPC Mach service. |
| nexus | the user | The CLI. A client of nexusd. Ships inside the app bundle. |
| NexusHelper | root, through SMAppService | Writes /etc/resolver/<tld> and the /etc/hosts lines. Nothing else. |

nexusd is the only launchd agent. It starts each service as a child process and restarts it
when it stops. So services keep running when the window closes (D32), and the user sees one
background item, not one for each service.

Code: one Xcode project with the four targets, and one local Swift package `NexusKit` with
the logic. The targets stay thin. `swift test` runs the package tests without the app. Swift 6
language mode with strict concurrency. Minimum macOS 27 for the app and for all binaries.

| Module in NexusKit | Job |
| --- | --- |
| NexusCore | Models (site, service, instance, workspace), settings, paths |
| NexusConfig | Generates nginx, Apache, php-fpm, php.ini, my.cnf, postgresql.conf and redis.conf files |
| NexusRuntime | Reads the manifest, downloads, checks the SHA-256, unpacks, removes |
| NexusSupervisor | Processes, ports, logs, health checks |
| NexusDNS | The DNS server for the dev TLD |
| NexusTLS | The root CA and the certificates for each host |
| NexusLaravel | The configuration probe and the .env rewrite |
| NexusWorkspaces | Worktree detection and the workspace lifecycle |
| NexusIPC | The XPC protocol between nexusd, the app and the CLI |

Folders in ~/Library/Application Support/Nexus:

| Folder | Content |
| --- | --- |
| runtimes/<name>/<version> | The installed binaries |
| config | The generated config files |
| data/<service>-<version> | The data folder of each database and Redis instance |
| run | Sockets and pid files |
| logs | One log for each service and each site |
| certs | The certificates for each host. The CA key stays in the login keychain (D29). |
| trash | Dumps of removed workspace databases, kept 7 days (D53) |
| bin | The shims for the PATH setting (D39) |

## Step 0 - Setup

Work:
1. Remove the "Untitled Project" template (the deletions are staged already).
2. Make the Xcode project `Nexus` with the four targets and the local package `NexusKit`.
3. Use automatic signing. Copy Config/Signing.local.xcconfig.example to
   Config/Signing.local.xcconfig and set your own team. A free Personal Team is enough for
   local builds. SMAppService needs a signed app, also for local tests. Do not choose a team in
   the Xcode Team menu, because Xcode then writes the team into the project file.
4. Make the public repository `NexusLocal/binaries` (D9).
5. Add a CI job for the app repository that runs `swift test` on the `xcode-27` runner.

Done when:
- The empty app starts, shows a window and a menu bar item.
- `swift test` passes in CI and on the owner's Mac.

## Step 1 - Build pipeline (repository NexusLocal/binaries)

This is the longest step. Steps 2 and 3 can start at the same time with binaries that the
owner builds locally with the same scripts.

### 1a. Base

Work:
1. One build script for each product, the same for local runs and CI. The runner is `xcode-27`
   (Apple silicon, macOS 27, free for a public repository).
2. Shared dependencies are built from source into a staging prefix: OpenSSL 3, ICU, libxml2,
   libxslt, zlib, bzip2, libzip, oniguruma, libsodium, PCRE2, libpng, libjpeg-turbo, libwebp,
   FreeType, libavif, libyaml, zstd, lz4, readline or libedit, nghttp2, APR and APR-util, and
   ImageMagick for imagick.
3. A relocation tool changes every install name to @rpath and adds @loader_path rpaths. It then
   signs every Mach-O file again with an ad-hoc signature, because install_name_tool breaks the
   old signature.
4. A check tool runs `otool -L` on every Mach-O file. It fails the build when a path points
   outside the package, /usr/lib or /System.
5. Each package is a .tar.xz with a licenses folder and a SOURCE file (the URL and the SHA-256
   of each source archive). Not .tar.zst: the tar of macOS 27 cannot read zstd, and Nexus
   unpacks with /usr/bin/tar.
6. The build starts in an empty environment with the PATH /usr/bin:/bin:/usr/sbin:/sbin. The
   build tools (cmake, ninja, pkgconf) come with the scripts. Reason: on the owner's Mac the PATH
   puts MAMP's pkg-config, autoconf, libtool and curl first.

Done when:
- The check tool passes on every package.
- A package unpacked into a folder with spaces in its path works. The Nexus folder is in
  "Application Support", so this is the normal case.

### 1b. nginx

Work: build the newest stable line with --with-compat, http_ssl, http_v2, http_v3, stream and
the dynamic modules that nginx supports (D25). Third-party dynamic modules: brotli,
headers-more and geoip2.

Done when: `nginx -V` shows the modules. Each .so module loads with `load_module` and
`nginx -t` passes.

### 1c. PHP 8.2, 8.3, 8.4 and 8.5

Work:
1. Build CLI and FPM. No CGI (D26).
2. Built-in extensions: the 43 that MAMP has built in (D27).
3. Shared extensions, built from PECL: xdebug, pcov, redis, igbinary, imagick, apcu, yaml,
   pgsql, pdo_pgsql and imap (imap is in PECL from PHP 8.4).
4. opcache is a shared extension in 8.2 to 8.4. In 8.5 it is always built in, so Nexus toggles
   it with opcache.enable.
5. Start with 8.5. The other versions use the same script.

Done when:
- `php -n -m` shows the built-in list for each version.
- Each shared extension loads with `-d extension=<name>.so`.
- `php-fpm -t` passes.
- A fresh laravel/laravel application passes its own tests on each version.

### 1d. Apache 2.4

Work: build with the event MPM, all modules as shared modules, mod_proxy_fcgi, mod_remoteip,
mod_rewrite and mod_http2.

Done when: `httpd -M` lists the modules after a LoadModule line for each one. `httpd -t` passes.

### 1e. Redis 7.2, 8.2 and the newest 8

Work: build without TLS. Redis has few dependencies.

Done when: `redis-server --version` matches. A test writes and reads a key on a high port.

### 1f. MySQL 8.0, 8.4 and 9.7

Work: build from source with the same OpenSSL. If the build time on CI is too long, use the
official macOS arm64 archives from Oracle and run the same relocation check. Ship the server,
the client, mysqldump and the mysql_tzinfo tools.

Done when: `mysqld --initialize-insecure` makes a data folder in a temp folder. The server starts
on a high port. A dump from MAMP MySQL 8.0 restores into each version.

### 1g. MariaDB 10.11, 11.4, 11.8 and 12.3

Done when: the same checks as MySQL, with mariadb-install-db.

### 1h. PostgreSQL 14 to 18

Done when: `initdb` makes a data folder in a temp folder. The server starts on a high port.
`pg_dump` and `pg_restore` work.

### 1i. Node and Composer

Work: no build. The manifest gets entries for the official Node 22, 24 and 26 archives with
their SHA-256 from SHASUMS256.txt (D10). The manifest also gets composer.phar with its SHA-256.

### 1j. Releases and manifest

Work:
1. A release for each package on GitHub Releases.
2. One manifest.json with name, version, URL, SHA-256, size, minimum macOS, license and source
   URL for each package.
3. A scheduled CI job that looks for new patch releases and opens a pull request (D12).

Done when: a script downloads every package from the manifest and the check tool passes on all.

## Step 2 - nexusd core

Work:
1. NexusRuntime: read the manifest, install and remove a version, check the SHA-256.
2. NexusSupervisor: start, stop and restart processes. Keep a log for each one. Restart a
   process that stops, with a delay that grows.
3. Ports: a port registry. Before a start, check the port. When it is in use, find the process
   that holds it and report it (D31).
4. nexusd as a launchd agent through SMAppService, with an XPC Mach service.
5. The CLI skeleton: `nexus status`, `nexus start`, `nexus stop`.

Done when:
- `nexus status` lists the services.
- A killed process comes back.
- A port that MAMP holds gives a clear message that names MAMP PRO.

## Step 3 - DNS, certificates and the helper

Work:
1. NexusDNS: a small DNS server on 127.0.0.1 on a high port. It answers 127.0.0.1 and ::1 for
   every name in the dev TLD. /etc/resolver/test sets that port, so the DNS server needs no
   root (`port` is a documented key in resolver(5)).
2. NexusHelper: writes /etc/resolver/<tld> and the /etc/hosts lines for hosts outside the dev
   TLD. It refuses every other path.
3. NexusTLS: makes the root CA and stores its key in the login keychain. It adds the trust
   setting for the CA (macOS asks for the password). It signs a certificate for each host.

Done when:
- `dscacheutil -q host -a name anything.test` gives 127.0.0.1.
- `curl https://<host>:8443` gives no certificate error in Safari and Chrome.
- Removing Nexus removes /etc/resolver/test and its /etc/hosts lines.

Built: the DNS server runs in nexusd on 127.0.0.1:10053 (`nexus port dns <port>` changes it).
`nexus trust` trusts the root CA, `nexus cert <host>...` signs a certificate, `nexus hosts add`
adds an /etc/hosts line and `nexus uninstall` removes every change to macOS. The app registers
the helper, and the user approves it in System Settings > General > Login Items & Extensions.

Risk: Firefox uses its own certificate store. The UI shows a short instruction for Firefox.

Risk: a program with its own list of CAs does not trust the Nexus root CA. Examples are the curl
of MAMP PRO, Node and PHP with its own CA file. /usr/bin/curl and URLSession trust it. Step 4
must check that PHP in Nexus trusts it, for an application that calls another local site.

## Step 4 - Web serving

Work:
1. php-fpm: one master for each PHP version, with a socket in run/. Every PHP process gets
   OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES (D26).
2. nginx front on 80 and 443 (8080 and 8443 during the build). A server block for each host.
   nginx sites go to php-fpm. Apache sites go to Apache on an internal port (D23).
3. Apache with mod_proxy_fcgi to the same php-fpm sockets. HTTPS=on from X-Forwarded-Proto.
   The client IP from mod_remoteip.
4. Sites: add a folder, park a folder, the document root rule, aliases, PHP version for each site
   and the choice of web server (D22, D33).
5. Extension toggles for each PHP version (D27) and module toggles for Apache and nginx (D25).
6. The LAN setting (D24).

Done when:
- Two copies of the same Laravel application run at the same time. One copy is on nginx with
  PHP 8.5 and the other copy is on Apache with PHP 8.4.
- Laravel sees HTTPS on both. `request()->isSecure()` is true and the URLs are https.
- Xdebug on for one PHP version does not change the other versions.
- A request from another device on the LAN gets a 403 until the LAN setting is on.

Built: `nexus site add|edit|remove|list`, `nexus park`, `nexus unpark`, `nexus ext <php>`,
`nexus module apache|nginx` and `nexus lan`. The ports have the names http, https and apache:
`nexus port https 8443`. php.ini of each PHP version belongs to the user. Nexus writes it one time
and keeps the extension toggles in conf.d/00-nexus.ini. Xdebug and PCOV are off by default.
The checks ran with a new Laravel application in two copies, on 8080 and 8443.

Risk: macOS asks before nexusd and its children read ~/Documents, ~/Desktop or ~/Downloads. A
site in one of these folders needs that permission. The app must explain this in step 6.

## Step 5 - Databases and Redis

Work:
1. Instances of MySQL, MariaDB and PostgreSQL. Each has its own version, port and data folder
   (D34). The user root with the password root on 127.0.0.1 (D35). MariaDB: run
   scripts/mariadb-install-db with the package folder as the working folder and --basedir=. ,
   because the script breaks on the space in "Application Support". The data folder can have a
   space.
2. Redis instances with "databases" set high enough for all workspaces (D47).
3. The action "copy a database from another server": a dump from the other server and a
   restore into a Nexus instance (D37). The other server is only read.
4. The button that opens a database in TablePlus or Sequel Ace (D36).

Done when:
- MySQL 8.0, MySQL 8.4 and PostgreSQL 17 run at the same time on their own ports.
- The development database of a real project comes over from MAMP. That project then works on
  Nexus with only DB_PORT changed in its .env.

Built: each installed version line of MySQL, MariaDB and PostgreSQL is one instance, for example
mysql-8.4. Its name is also its port key: `nexus port mysql-8.4 13307`. The data folder is
data/<instance>. Before the first start, Nexus makes the data folder in a hidden folder next to
it and moves it into place only when the initialization succeeds. MySQL uses
`--initialize-insecure` with an init file, MariaDB uses mariadb-install-db with an extra SQL
file, and PostgreSQL uses initdb. Every instance gets root with the password root on 127.0.0.1
and ::1. PostgreSQL also accepts root without a password on its socket in run/, which only the
user can open. config/<mysql|mariadb>/<line>/my.cnf belongs to the user. Nexus sets the port, the
address, the folders and the socket on the command line. PostgreSQL stops with SIGINT, because
it waits for every client after SIGTERM. Redis keeps 256 databases for each instance (D47).

`nexus db` lists the instances. `nexus db copy <database> --to <instance>` copies a database
from another server. The default source is root/root on 127.0.0.1 on the standard port of the
instance (3306 or 5432). `--as` gives the copy another name, and `--replace` drops a database
with the same name in the instance first. `nexus db open <instance> [database]` opens TablePlus
or Sequel Ace. The checks ran with MySQL 8.0, 8.4 and 9.7 on 13306, 13307 and 13309, MariaDB
11.4 on 13308 and PostgreSQL 17 on 15432. A Laravel 13 application from MAMP PRO (217 tables)
ran on Nexus with only DB_PORT changed. The copy had the same row count in every table.

Not built: a setting for another user or password (D35). The copy and the open action use
root/root.

Risk: the dump uses the tools of the receiving instance (D7). A dump from MySQL does not always
restore into MariaDB, or the other way. In a test, MariaDB refused a generated column of MySQL.
A collation that only one of the two knows, such as utf8mb4_0900_ai_ci of MySQL 8 in a MariaDB
older than 11.4.5, stops the copy too. The copy then stops with the error of the server, and
Nexus drops the half copy. Copy into the same kind of server for a full copy.

Risk: the copy shows no progress. A database of some GB takes minutes, and the CLI waits. The
app needs a progress display in step 6.

## Step 6 - The app window and the menu bar

The design is docs/design/nexus.pen. The owner approved it on 2026-10-27 (D57). Its frames "UX
Rules" and "Notes" apply to every part below. The screens use the standard macOS 27 controls and
styling, not custom components. Compare each screen with its light and dark frame.

The design also shows parts that work only from a later step: workspaces, background processes,
commands after the copy, environment keys, the database connections of a site and the Workspaces
tab of Settings (step 8), the Node version and the PATH setting (step 7), the import from MAMP PRO
(step 9) and app updates with Sparkle (step 10). Step 6 does not build these parts. The step that
makes them work also adds them to the screens.

Step 6 has 8 parts. Part 6a builds all screens with sample data and no function (owner,
2026-10-27). Parts 6b to 6h then connect the screens to nexusd, one area at a time, and add the
nexusd work of that area. Each part ends with `swift test`, the app build, a code review and a
commit with a push.

### 6a. All screens with sample data

Work:
1. The app icon and the menu bar icon from the design. The colors of the design as named colors
   for light and dark mode.
2. One app model holds everything that the screens show. In 6a, sample data fills it. Parts 6b
   to 6h fill it from nexusd, so the screens do not change for that.
3. The main window: the sidebar with the sections Sites and Services, one row for each kind of
   service, the search field, and the + and sort buttons at the bottom. Minimum size 900 × 600 pt.
4. Every screen, sheet, alert, menu and settings tab of the design, the first run and the menu
   bar panel. A button that has no function yet does nothing.

Done when: the owner compares each screen with its frame in the design, in light and dark mode,
and approves it.

### 6b. Live state, Overview and menu bar

Work:
1. nexusd pushes each change to the app over XPC, so the app does not ask for the status again
   and again.
2. Restart a service in one request. "Stop all services" remembers which services ran, and
   "Start stopped services" starts only those (D63).
3. The sidebar, the Overview and the menu bar panel show the real services. The switches start
   and stop them.
4. The problem banner of the Overview and the menu bar panel shows when the helper needs the
   approval of the user in Login Items. The menu bar showed this before step 6.

Done when: a switch in the window and in the menu bar panel starts and stops a service. A
`nexus start` or `nexus stop` in the terminal shows in the window within one second.

Built: the app keeps one XPC connection to nexusd open and calls `watch()` on it. nexusd then
sends the service list after each change, also after an exit that nobody asked for. When nexusd
stops, the app shows a banner and connects again every 2 seconds. New CLI commands:
`nexus restart <service>`, `nexus stop --all` and `nexus start --stopped`. A debug build with the
launch argument `--sample` shows only sample data, for a check of the screens against the design.

### 6c. Database and Redis services

Work:
1. Connect the screens of MySQL, MariaDB, PostgreSQL and Redis. Each version shows its state,
   port, account, data folder and log.
2. nexusd lists the databases in an instance with their size.
3. Change the account of an instance. A new instance gets root without a password (D35). The
   instances that exist now keep root/root.
4. "Open" is a split button. It uses the mysql:// or postgresql:// link and lists only the
   installed apps that can open the link, and "Copy URL" (D36).
5. A log shows the newest 100 lines. "Open log file" opens the full log.
6. Change the port of each instance (D31).
7. The alert for a port in use: nexusd names the program that holds the port (app, process,
   process number and path). The alert can quit that app or pick another port (D31).

Done when: MySQL 8.0 shows `3rdrisk_platform` with its size. "Open" opens it in TablePlus. A port
that MAMP PRO holds shows the alert with the name MAMP PRO.

Built: the events of nexusd carry the account, the data folder, the log file and a port conflict
of each service. The app reads the newest 100 log lines itself and follows the file. New CLI
command: `nexus db account <instance> <user> --password <password>`, for a running instance.
PostgreSQL cannot have an empty password, so an instance without a password trusts the
connections over TCP on 127.0.0.1. The tests in `RealDatabaseTests.swift` run real MySQL, MariaDB
and PostgreSQL servers in /tmp, only when `NEXUS_REAL_RUNTIMES` names the runtimes folder.

### 6d. PHP, webservers and DNS

Work:
1. Connect the PHP screen: the extensions with a switch and a tooltip each.
2. Custom php.ini lines for each PHP version. nexusd adds them after its own settings and checks
   them before the restart. On an error it keeps the old lines, and the app shows the line and
   the error (D60).
3. Connect the webservers screen for nginx and for Apache: the modules, the ports and the LAN
   setting. Apache shows its internal port.
4. Connect the DNS screen: the state and the port.

Done when: a wrong php.ini line shows its error, and PHP keeps running with the old lines. A
module switch changes the server config and restarts the server.

Built: the events of nexusd carry the extensions and modules with a help text each, the custom
lines and the sites of each PHP version, a note for Apache and DNS, and the LAN setting. nexusd
writes the custom lines to `conf.d/99-custom.ini`. Before that, the command line PHP of the same
version reads them in a copy of conf.d. A message that is not there without the new lines is an
error. A message without a line number gets the first line that makes it show. New CLI command:
`nexus ini <php> [lines] [--clear]`. Some modules need another module first, for example dav_fs
needs dav and ngx_stream_js_module needs ngx_stream_module. A switch turns both on or off. The
configuration loads them in the right order. A module whose needed module is not installed does
not turn on. A switch shows what loads. A change keeps a name on that loads for another name. nginx
shows ssl, http2 and proxy as always on. The toggles of Apache leave out mpm_prefork and
mpm_worker. A new port of Apache needs only a graceful restart. The supervisor then keeps the new
port. So the app shows it. nexusd waits until Apache accepts connections on the new port. When it
does not, the old port comes back. A port, a module or the LAN switch only reloads the running
web services. It starts and stops nothing. So the services that "Stop all services" stopped stay
stopped (D63). nexusd reads the .so files of a runtime again only when the modification date of
their folder changes. New names send the service list to the app. Each key of the messages that
came after part 6c is optional. So an app can read the events of an older nexusd. An event that
the app cannot read shows its own problem in the app, with a button that starts nexusd again.
The LAN switch is in Settings > Network, as in the design.

### 6e. Sites

Work:
1. Connect the Site screen: hosts, aliases, folder, document root, PHP version and webserver. The
   actions "Open in browser", "Open in <terminal app>", "Open in <code editor>" and "Show in
   Finder". The app finds the installed terminal apps and code editors itself.
2. Connect the "Add a site" sheet, the + menu, the sort menu and the right-click menu of a site.
3. Site groups, "Move to group" and "Sort by name" (D58). The sidebar can collapse its sections
   and each group. Drag and drop in the sidebar comes in phase 2.
4. Defaults for new sites in nexusd: webserver and PHP (D59).
5. nexusd watches each parked folder. A new folder becomes a site with the defaults, without the
   app (D62).
6. The drop area on the Overview adds a folder as a site.
7. A site in ~/Documents, ~/Desktop or ~/Downloads: the app tells why macOS asks for access.

Done when: a folder that you drop on the Overview opens over HTTPS. A new folder in a parked
folder shows in the sidebar without a click.

Built: nexusd sends the sites in their own event, with the order of the sidebar, the folders of
projects, the defaults and the dev domain. nexusd keeps the groups and the order of the sites
(D58). The app sends the whole order after each change. A site of a parked folder shows in that
folder, unless it is in a group. New CLI commands: `nexus site defaults [--php <version|newest>]
[--server <nginx|apache>]` and `nexus site add --group <name>`. nexusd watches each parked folder
with FSEvents. A new, removed or renamed project and a new public folder in a project change the
configuration. A change deeper in a project does not. A new site from the watch and a new start
of nexusd start no web service while "Stop all services" is in effect, unless the user started it
after "Stop all services". That service then waits for "Start stopped services" (D63). A site
that the user adds starts nginx and PHP (owner). A new
project in a parked folder gets the webserver and the PHP version of that folder. So nexusd does
not remove a PHP version or Apache that a parked folder uses. The drop area opens the "Add a site"
sheet with the folder. The sheet chooses "Many projects" when the folder has no project file and a
folder in it has one. The "Used by" column of a database comes from the .env of each site
(DB_CONNECTION, DB_HOST, DB_PORT and DB_DATABASE), until step 8a reads the configuration of the
application. The app finds 9 terminal apps and 12 code editors by their bundle identifier. The
supervisor ends the process group of a service when its main process ends. Before this change, the
workers of a php-fpm whose master got SIGKILL kept the socket, and each new start failed. The id
of a site row in the sidebar names its group or folder too. Without that, the list of macOS 27
kept an old row on the screen when a site moved into a group or out of one. A project with
settings of its own in a folder of projects has "Remove site". It then gets the settings of the
folder again. Settings > Sites already changes the defaults in nexusd. The other rows of that tab
stay for part 6g and step 8.

### 6f. Packages and tasks

Work:
1. The manifest gets the end date of security fixes and an LTS flag for each package. This
   changes the build scripts in nexus-binaries too.
2. Connect the Packages screen: install, remove and update each version. It marks a version without
   security fixes (D12). The update check runs at launch, once a day and on a click.
3. Progress and stop for a package download and a database import. The import still runs
   outside the change queue.
4. "Activity" on the Overview and the running tasks in the menu bar panel.
5. Connect the "Import a database" sheet. nexusd lists the databases on the source server.

Done when: a download of MySQL 9.7 shows its progress and stops on a click without a half
install. A copy of a large database shows its progress in the window and in the menu bar panel.

Built: `support.lock` in nexus-binaries gives the LTS flag and the last day of security fixes of
each version line, from endoflife.date. `scripts/support.sh` adds them to the manifest as `lts`
and `security_end`. The workflow Manifest adds them to the published manifest without a new
build. The weekly update check reports a date that endoflife.date changed. The Packages screen
shows a note when the security fixes end within 6 months, and after they ended. nexusd sends the
running tasks in their own event, four times each second while a task runs. A stopped task
answers `.stopped` with a message that says what changed. A download can stop until its new
folder goes into place. The change of the folder and the restart of an update do not stop. An
update stops a running service only for the change of the folder. nexusd refuses a second
install of the same package. It refuses a second copy into the same database. It refuses an
update of an instance during a copy into it, and a copy into an instance during its update. The
progress of a copy counts the bytes of the dump against the size of the tables on the other
server. So the total is an estimate. A dump of MySQL or MariaDB names each table. PostgreSQL
dumps without compression, so its bytes compare with the size of its tables. A copy that fails
or stops drops its half database. Checked on 2026-10-28 on the owner's Mac: a download of MySQL
9.7 stopped on a click and left nothing behind. A copy of fc_local_smartforms (2.8 GB) from MAMP
PRO showed its progress in the sheet and in the menu bar panel, and stopped at 46 percent
without a half database.

### 6g. Settings

Work: connect 7 of the 8 tabs of the design. The Workspaces tab comes in step 8.
1. General: start at login, the app icon in the Dock, the menu bar or both, the terminal app, the
   code editor and the notifications (D5, D61).
2. Sites: the defaults for new sites (D59). The rows for background processes, commands and keys
   come in step 8.
3. Databases: the database apps and the account for new instances (D35, D36).
4. Network: the ports, the LAN setting and the dev domain. nexusd can change the dev domain after
   the first run (D28).
5. Certificates: nexusd tells if the root CA is trusted. The trust action and the instruction for
   Firefox.
6. Updates: the package update check. App updates with Sparkle come in step 10.
7. Advanced: the folders, the background items and the uninstall.

A user can remove the menu bar icon with a Cmd-drag. When the Dock icon is off at that moment,
Nexus turns the Dock icon on again, so the app stays reachable.

Done when: a change of the dev domain from .test to .internal makes every site open on its new
name.

Built: Settings > Network and `nexus tld` change the dev TLD. Every name in the old TLD gets the
new one: the added sites, their aliases and the order of the sidebar. The sites of the parked
folders get it from the state. nexusd refuses a change that gives two sites one name. The helper
writes the resolver file of the new TLD first, so a refused file changes nothing. The file of the
old TLD goes at the next write of the system files. An uninstall removes the resolver file of each
dev TLD. nexusd keeps the account for new instances and tells whether macOS trusts the root CA. The
app keeps the settings that only it uses in UserDefaults: the Dock and menu bar icons, the chosen
and added apps, the notifications and the package updates. A database app that the user adds can
open every kind, because Nexus cannot ask it which links it opens. Without the automatic update
check, the Packages screen reads the manifest at its first visit. "Start at login" is the login
item of the app. The first run turns it on (D5). macOS shows a notification only while Nexus is
not the active app. The Node default and the PATH setting come in step 7, the workspace
notification in step 8. Checked on 2026-10-28 on the owner's Mac: in Settings > Network, a change
from .test to .internal made three sites, one with an alias, open on their new names with a
trusted certificate. The old names stopped. The change back to .test worked too.

### 6h. First run and Command line

Work:
1. Connect the first run in 3 steps: Packages, Domains and Settings. nginx, one PHP version and Composer
   are required. nginx, the newest PHP and Composer are preselected (D56).
2. The Domains step sets the resolver, approves the helper and trusts the root CA.
3. The Settings step turns on "Start at login" (D5) and asks macOS for the permission to show
   notifications. Both notification settings are on by default, so the question comes when the
   user expects it. Without it, macOS asks at the first notification, and a user who misses that
   banner gets no notifications. (owner)
4. Connect the Command line page: the nexus commands with a copy button (D64).
5. A launch argument shows the first run again. It deletes nothing.

Done when: a new user can go from the first launch to a working site without the terminal. Test
this on the owner's Mac with the launch argument. The Mac already has MAMP PRO and Nexus
packages, as most users have other tools. Do not make a new macOS user account. (owner)

Built: the first run shows at each launch until the user clicks "Done". A Mac that has nginx, PHP,
Composer, the helper and a trusted root CA skips it. That is an install from before the first run.
The launch argument `--first-run` shows it again in every build. The Packages step reads the
manifest and the installed packages. An installed version stays picked and shows "Installed". A
required package can only go when another version of it stays picked. The newest nginx, PHP and
Composer are preselected only when no version of them is installed. "Continue" starts the
downloads. The Settings step shows their progress. The Domains step waits until the helper is
allowed and nexusd wrote /etc/resolver/<tld>. A resolver file of another app such as Herd does
not count. The domain picker waits for the helper, because nexusd writes the new resolver file
first. "Continue" waits for the trusted root CA too. The Settings step asks macOS for the
notification permission while it shows. Settings > General and the first run show a note when
macOS blocks the notifications. "Start at login" starts at its current value when the first run
was done before. A failure in the first run shows in its own alert. After the first run closed it
shows in the main window. The Command line page lists every nexus command with an example. A test
parses each example with the nexus command and fails when a command is missing from the list.
`nexus runtimes` is `nexus installed` now, as in the design. The old name still works. Until the
PATH setting of step 7, the page has a button that copies the path of the nexus command in the
app. A removed package without data leaves no data folder. Checked on 2026-10-29 on the owner's
Mac with `--first-run`: the first run showed the installed packages, downloaded Redis 8.10 and
MariaDB 12.3 with their progress, and kept "Start at login" off. A folder added in the main window
then opened as https://firstrun-shop.test:8443 with a trusted certificate. The test packages and
the test site are removed.

## Step 7 - CLI and the PATH setting

Work:
1. `nexus php`, `nexus composer`, `nexus node` and `nexus npm`. Each one finds the site that
   contains the current folder and uses its versions (D38).
2. The shims in bin/ for the PATH setting, and the line at the end of ~/.zshrc (D39). Turning the
   setting off removes the line.

Done when:
- `nexus php -v` in a site folder shows the PHP version of that site.
- `nexus composer install` and `nexus npm ci` work in a worktree.
- With the PATH setting on, `./vendor/bin/pest` uses Nexus PHP.

Built: nexus php, composer, node and npm ask nexusd what to run. The nexus command then becomes
that program. So the program gets the terminal and the exit code. A folder in a git worktree
uses its site, also when the worktree is outside the folder of the site. Outside a site the
defaults for a new site apply. PHP gets the settings of its version through PHPRC and
PHP_INI_SCAN_DIR. These replace the values of MAMP PRO in the shell of the owner. The folder of
the runtime and bin/ come first on the PATH of the program. So php and node in a Composer or npm
script get the same versions. The Node version comes from .nvmrc, .node-version, .tool-versions
or "engines" in package.json, from the current folder up to the folder of the site (D21). The
Site screen and Settings > Sites have a Node picker. nexus site edit and nexus site defaults
have --node. nexusd makes the links nexus, php, composer, node and npm in bin/ at each start.
When nexusd does not answer, a link runs the next program with its name on the PATH and says
so. The PATH setting is the line in ~/.zshrc itself. So a change by hand shows in the app. A
line of Nexus that is not at the end shows a note. The Command line page shows the banner of
the design while the setting is off, with a button that copies the path of the nexus command.
An alias wins over the PATH (D39). On the owner's Mac, ~/.profile of MAMP PRO has aliases for
php and composer. So while the setting is on, the app starts a new login shell of zsh and asks
what php, composer, node and npm are. Each one that is not the link of Nexus shows in an orange
box in Settings > General, with the line of zsh, the reason and "Check again". The Command line
page shows the same box (design "Settings General · PATH warning" and "Command Line · PATH
warning", owner 2026-10-30). The Overview uses the same box. The check runs again only after a
change of the setting or of a shell file. A shell that hangs stops after 10 seconds. A stop now
ends the whole process group of a command. Neither nexusd nor the app makes a link to a
temporary copy of the app (AppTranslocation). Checked on 2026-10-30: both screens showed the php
and composer aliases of the owner. Checked on 2026-10-29 on the owner's Mac: in a test site with
PHP 8.4, nexus php -v gave 8.4 and 8.5 outside it. nexus composer install and nexus npm ci worked in a worktree
outside the site. Their scripts got PHP 8.4 and Node 24. With the setting on in Settings >
General, ./vendor/bin/pest ran on Nexus PHP 8.4 in a new zsh. Without it, Pest ran on the PHP of
MAMP PRO. Turning the setting off left ~/.zshrc as it was before. The test site is removed.

## Step 8 - Workspaces

This is the main feature. It has the most risk, so it has the most checks.

### 8a. Configuration probe

Work:
1. Find every env key in config/*.php.
2. Start PHP with a unique marker value for each key in the environment. Real environment values
   win over .env in Laravel. Run only the bootstrappers LoadEnvironmentVariables and
   LoadConfiguration, so no service provider runs (D43).
3. Read the configuration and find the markers. The result: which env key feeds which database
   name, host, port, Redis index, session, queue and broadcast value.
4. Numeric settings can lose a text marker through a cast. So run a second pass with numeric
   markers.
5. If bootstrap/cache/config.php exists, the probe stops and reports it. A cached configuration
   ignores the environment.

Done when: the probe gives a correct result for the 19 Laravel applications in the owner's MAMP
setup. These cover Laravel 8.83 to 13.38, a hardcoded default connection, four MySQL
connections, custom connection names, SQLite, Reverb, Mix and Vite. The probe only reads.

Built: the module NexusLaravel and `nexus site probe [folder] [--php <line>] [--json]`. The
request goes through nexusd, because nexusd knows the PHP of the site. The probe runs four
passes of `php -r`. The first has the real environment and gives the values. The second has text
markers and the third has numeric markers. These two give the keys. The last pass does what a
workspace does: it changes only the keys of the database names and the Redis indexes. A setting
that does not follow its key in this pass is a fixed setting. So a key behind a flag that is off
never counts. The keys come from config/ and from the config files of the
framework, because Laravel 11 and newer merge those files. A text marker starts with the number
of the key. So arithmetic on the value does not stop PHP, and a cast to int keeps the number.
The step between two numbers is the prime number 1009. So a round number that the application
adds to a value names no key. A value without a marker is a fixed setting. Xdebug is off in a
pass, and a pass stops after 30 seconds. The result holds only the sections that Nexus uses:
app.url, database, session, cache, queue, broadcasting and reverb.

A site on the public folder of a project now holds the whole project, also for nexus php,
composer, node and npm. A host of MAMP PRO points at the public folder.

Checked on 2026-10-30 with the Laravel applications of MAMP PRO. MAMP PRO now has 20, not 19. 2
stopped on bootstrap/cache/config.php, as work item 5 says. After `php artisan config:clear` in
those 2 (owner), all 20 gave a result. A separate script read
config/database.php of each application and of the framework. It compared 551 settings with the
result. These are the default connection and the database, host and port of each connection and
Redis connection. The 2 differences came from that script: one application has read and write
hosts, and the result shows them correctly. `git status` of each application did not change, and
the probe changed no file.

### 8b. Worktree detection

Work: watch .git/worktrees of each site. Only `git worktree list --porcelain` says which worktrees
exist. A worktree counts as removed only when git no longer lists it (D53).

Done when: `git worktree add` and `claude --worktree` both give a workspace. `git worktree
remove` starts the removal.

Built: the module NexusWorkspaces, `nexus workspace list`, `nexus site edit --workspaces on|off`,
and the Workspaces section of the Site screen with the switch and a row for each workspace. A
workspace is only a record now. Parts 8c to 8k add its domain, files and databases. The rows get
the domain, the state and Open in those parts.

nexusd watches the .git folder of each site. A change counts only when something that git lists
changes in .git/worktrees: an admin folder, its index, its gitdir or its HEAD. Then `git worktree
list --porcelain` decides. nexusd also checks at its start and after each change of the sites.
So a worktree from a time when nexusd did not run gets a workspace too. When git cannot list the
worktrees, the workspaces stay.

A site that is new to Nexus keeps its worktrees without a workspace, because one application has
14 worktrees. Only a worktree that comes later gets a workspace (D40). The same applies to a
worktree that came while the setting was off. A worktree that is itself a site gets no workspace.
`git worktree move` keeps the workspace when the folder name stays the same. A second worktree
with the same name gets a number. A worktree of a branch without the folder of the site waits
until that folder comes. A site without a repository gets a record too, so a worktree after a
later `git init` counts as new. nexusd reads the list with /usr/bin/git only when `xcode-select
-p` works, because /usr/bin/git can be a stub that opens the install dialog of macOS. Without git,
the Site screen says so and the workspaces stay.

A lock is no sign that git still adds a worktree, because `claude --worktree` keeps its worktree
locked. So a worktree counts as added when it has no lock or when it has an index. The index comes
at the end of the checkout.

A removed site loses its workspace records. Part 8k must also remove their databases. A record
stays while the folder of the site does not exist, for example on a disk that is not connected.
So part 8k must also decide what happens after a user deletes that folder.

Checked on 2026-10-30 on the owner's Mac with a test site through the real nexusd: `git worktree
add` and `claude --worktree` each gave a workspace in 2 seconds. `git worktree remove` removed it.
`git worktree move` kept it. With the setting off, a new worktree got no workspace. The test site
is removed.

### 8c. Domain and certificate

Work: the host rule (D42), a certificate for each workspace host, the nginx server blocks.

Done when: my.shop.test gives my.shop-test-1.test, and blog.local gives
blog-test-1.test. Both open with a valid certificate.

Built: `HostName.workspaceHost` makes the host. A workspace runs as a site in the web
configuration, with the PHP and the webserver of its project, the document root in its worktree
and its own certificate. Each host of the site gets a workspace host, so aliases work too. Two
sites of one project share one block for a workspace. A workspace whose host is taken does not
run and gives a warning. A new or removed workspace gives a new web configuration by itself. The
Site screen shows the host and Open for each workspace. `nexus workspace list` shows the URL and
the folder. For a workspace that does not run, both show the warning and no URL. A checkout, a
pull or a merge that adds the public folder of a worktree changes its document root. A web
service that the user stopped with `nexus stop` stays stopped after a new workspace or a new
project in a parked folder. It starts again after `nexus start`, a change of a site or a new
start of nexusd.

Checked on 2026-10-30 on the owner's Mac through the real DNS server: my.shop.test gave
my.shop-test-1.test and blog.local gave blog-test-1.test. Each opened over HTTPS with the files
of its worktree. macOS accepted both certificates with `security verify-cert`. After `git
worktree remove`, the host gave no site. The test sites are removed.

### 8d. The .env

Work: copy the .env when the worktree has none. Rewrite the hosts. Set the database and Redis
keys from the probe. Add a line when the key has none. Add the extra keys of the site with
placeholders (D44, D45). Check with `git check-ignore` before the write (D50).

Done when: a diff between the main .env and the workspace .env shows only the expected keys.

Built: a new workspace now starts in the state Preparing. nexusd sets up one workspace at a time.
It probes the main checkout with the PHP of the site, checks `.env` with `git check-ignore`, and
writes the `.env` of the worktree. The state then becomes Ready or Not isolated, with the reason
(D48). A site that is no Laravel application is Ready at once (D54). Redis indexes come from 16 up
and the {port:<name>} ports from 20000 up. Both stay in the record of the workspace. The database
copy of 8e is not there yet, so a workspace cannot use its database keys before that part.

`nexus workspace env <host>` shows the keys. `nexus site edit --workspace-key KEY=VALUE` sets your
own keys. The Site screen has the section Environment keys of the design, and each workspace row
shows its state. `nexus workspace retry <host> <name>` and the Retry button (not in the design)
set up a workspace again after the user fixes the cause of Not isolated. A setup also runs again
after a change of the own keys, the aliases or the dev TLD, and after `git worktree move`. It
keeps the Redis indexes and the ports. Part 8e must not copy a database again in such a setup.

Checked on 2026-10-30 with throwaway clones of finconnect and 3rdRisk-platform on the owner's
Mac, with the database and Redis ports of the Nexus instances in their .env. The diff between the
main .env and the workspace .env showed only the hosts, the database names and the Redis keys.
`git status` of each worktree stayed empty. The clones are removed.

### 8e. Databases

Work: copy every database of the site that is on a Nexus instance (D46). MySQL and MariaDB
use mysqldump with --single-transaction and a restore. MySQL also needs --set-gtid-purged=OFF:
MySQL 9 turns GTIDs on, and a dump with GTID_PURGED fails when it goes back into the same
server. PostgreSQL uses pg_dump and
pg_restore. CREATE DATABASE with TEMPLATE needs a template that has no other connections,
so it is not the default. SQLite gets an APFS clone.

Done when: the application with four MySQL connections gets four database copies. The main databases do not change. A checksum
before and after the copy proves it.

Built: the setup copies each database after it writes the .env, with the copy code of step 5 and
the same instance as source and target. A SQLite file gets an APFS clone when git ignores it and
its write-ahead file. A file in write-ahead mode gets a backup with /usr/bin/sqlite3 instead. Two
clones are not one moment while the main site writes. The backup reads one moment, and it does not
change the database of the main site. A file with a rollback journal also gets a backup, with a
normal connection. It waits for a write that runs, and it rolls back a write that a crash ended,
as the next connection of the application does. The record of the workspace names each copy before it starts and after it
ends. Part 8k drops only those copies. A second setup keeps a finished copy that still exists. It
makes a copy again that went away, and it replaces a copy that started and did not end. A setup
makes no copy for a key that the site replaces. It starts a stopped instance, but that does not
enable the instance. A database with the name of the copy that this workspace did not make stays,
and the workspace is Not isolated with that reason. A missing database of the default connection
gives the same state, and a missing database of another connection is skipped, because the main
site does not have it either. The row shows Copying databases with the percentage.

Checked on 2026-10-30 on the owner's Mac with a clone of finconnect and its three databases of 6.6
GB, copied from MAMP PRO to mysql-8.0. finconnect has four connections and three databases, because
the connection sessions uses the main database. The workspace got three copies in 9.5 minutes.
CHECKSUM TABLE gave the same result for the 93 tables of the main databases before and after the
copy, and for the 93 tables of the copies.

### 8f. Redis

Work: give each Redis connection of each workspace its own index (D47). Empty the indexes at
removal.

Facts from the probe (8a):
- 8 applications feed all their Redis connections from the one key REDIS_DB, with another default
  for each connection. In a workspace all these connections use one index (D47). The workspace
  stays separate from the main site. A cache clear in that workspace also empties its sessions.
- 3 applications have fixed indexes in config/database.php. D48 makes their workspaces "not
  isolated".

Done when: a cache write in a workspace is not visible in the main site.

Built: nexusd starts Redis with 256 databases since step 2, so 240 indexes are for workspaces. The
setup starts a stopped instance and does not enable it, as part 8e does for a database. It then
reads the keyspace and takes the lowest free index from 16 up. An index is not free when a
workspace has it, when it has keys, when the main site of the project uses it, or when the .env
of another site names it. A setup probes only its own project, because a probe of each site takes
too long. So a fixed index from 16 up in config/database.php of another project stays unknown
while that index has no keys. D47 says that main sites use the indexes below 16. A workspace
without a free index is Not isolated. The record names the indexes and their instances before the
.env names them, because a database copy can take minutes and nexusd can stop in that time. A
record from before this part has indexes without instances, so it gets a new setup.

Only a Redis that is installed counts as a Nexus instance. The state keeps the port of a removed
Redis, and on the owner's Mac MAMP PRO uses that port (6379). Before this part, a workspace of an
application on that port was Ready with an index that Redis of MAMP PRO does not have.

Nexus empties the indexes of a workspace that went away, and an index that a setup no longer uses.
A stopped instance runs only for this step and stops again, and no choice of the user changes.
Each Redis command uses the port from the supervisor. A running instance keeps its port until a
restart, while `nexus port` changes the state at once. Another Redis can listen on the new port.
A removal probes the main site first, because only a probe shows a fixed index in its
config/database.php. Without a result of the probe, the indexes stay as they are, and the reason
goes to the log of the instance.
`redis-cli -n` is not safe for this step. When the index does not exist, it runs FLUSHDB on index
0 and it reports success. So SELECT and FLUSHDB run in one Lua script, and only the answer OK
counts. An index that Nexus cannot empty keeps its data, and the reason goes to the log of the
instance. Its keys keep that index out of the choice of a later workspace, so no workspace reads
that data.

Checked on 2026-10-30 on the owner's Mac with the clone of finconnect on redis-8.2 and phpredis.
The vendor folder of the worktree was a temporary link, because part 8g adds that folder.
cache()->put in the workspace wrote to index 16, and cache()->get in the main site gave null. A
write in the main site went to index 1, and the workspace gave null. The real-runtime tests check
the removal, because a new worktree of this clone needs a database copy of 6.6 GB.

### 8g. Files

Work: APFS clones of vendor, node_modules, the build output and storage/app (D49). Do not clone
bootstrap/cache. Run `composer install` or `npm ci` only when the lock file is different.

Done when: a new workspace of an application with 1.5 GB of vendor and node_modules uses
almost no extra disk. `git status` in the
worktree shows no change after the setup. Measure the time of the node_modules clone, because
it has many small files.

### 8h. Commands after the copy

Work: run the list of the site after the database copy (D51). Show the output in the log.

### 8i. Background processes

Work: the preset from the probe (D52). Free ports for each {port:<name>}. Start the processes
when the workspace is ready. Stop them at removal.

Done when: a queued job from a workspace runs in the worker of that workspace. Vite of two
workspaces runs at the same time on two ports.

### 8j. Isolation check

Work: a workspace with a connection that the probe cannot isolate is "not isolated" (D48).
Nexus shows the cause and starts no background process.

Done when: a test application with a hardcoded database name gets the state "not isolated".

### 8k. Removal

Work: write a compressed dump of each workspace database to trash/ first. Then drop the
database. Part 8f already empties the Redis indexes. Remove the server blocks and the certificate.
Delete dumps older than 7 days (D53).

Done when: a removed workspace leaves only its dump in trash/. A restore of that dump works.

### 8l. CLI

Work: `nexus workspace create`, `wait`, `info --json`, `list` and `remove` (D38, D40).

### Final check for step 8

Ten new worktrees, split over two of the owner's largest applications, run at the same time. Each one
has its own domain, databases, Redis indexes and workers. You can log in to all ten in one
browser at the same time, and no login ends another one. A commit and a push from each worktree
change nothing in the main checkout.

## Step 9 - MAMP PRO import

Work: read the hosts from the MAMP PRO settings: names, aliases, document roots, PHP versions and
SSL. Show them in a list where the user selects what to import (D37). Database data comes over
with the copy action from step 5.

Done when: the 22 MAMP PRO hosts of the owner import without manual changes. MAMP PRO keeps
working after the import.

## Step 10 - Release

Work:
1. Sparkle with an EdDSA key and an appcast (D6).
2. Decide the open item: the visibility of the app repository.
3. Sign with a Developer ID and notarize.
4. A short user guide.

Done when: a notarized build installs on a second Mac with macOS 27 without a warning, and an
update through Sparkle works.

## Phase 2

Work that comes after step 10 (owner, 2026-10-27).

### Drag and drop in the sidebar

Work: drag sites and groups to set their order by hand, and drag a site into or out of a group
(D58). Use the macOS outline list (NSOutlineView), the control of the sidebars of Finder and Mail.
It draws the insertion line and handles the selection itself.

Reason: a SwiftUI List on macOS 27 failed in step 6a. A drop target on the ForEach made the app
crash when a group was open. A drag modifier on a row made the list wait for a mouse-up event
that the drag had taken, so the app took no clicks after the first drag.

Done when: a site moves before another site, into a group and out of a group. A group moves
between the other rows. Clicks and drags still work after many drags.

## Order and parallel work

1. Step 0, then steps 1, 2 and 3 at the same time.
2. Steps 4 and 5 need packages from step 1 (local builds are enough).
3. Step 6 grows with each step.
4. Step 8a (the probe) has no dependencies. It can start early, because it has the most risk.
5. Steps 7, 8 and 9 come after 4 and 5. Step 10 is last.

## Main risks

| Risk | Effect | Action |
| --- | --- | --- |
| A dependency keeps an absolute path | The binary fails on another Mac | The otool check in 1a fails the build |
| ImageMagick has many dependencies | The imagick build is large and slow | Build it last. Skip imagick for a version if it blocks the release. |
| The probe misses a key in an unusual application | A workspace writes into the main database | The isolation check (D48) and the 19 test applications |
| The clone of node_modules is slow | A workspace takes long to start | Measure in 8g. Clone in the background and wait in `nexus workspace wait`. |
| A large database | The copy takes minutes | Show the progress. `nexus workspace wait` waits for it. |
| CI time for MySQL and MariaDB | Long builds | Cache the dependencies. Use the Oracle archives for MySQL if necessary. |
