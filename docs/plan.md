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

### 6h. First run and Command line

Work:
1. Connect the first run in 3 steps: Packages, Domains and Settings. nginx, one PHP version and Composer
   are required. nginx, the newest PHP and Composer are preselected (D56).
2. The Domains step sets the resolver, approves the helper and trusts the root CA.
3. Connect the Command line page: the nexus commands with a copy button (D64).
4. A launch argument shows the first run again. It deletes nothing.

Done when: a new user can go from the first launch to a working site without the terminal. Test
this on the owner's Mac with the launch argument. The Mac already has MAMP PRO and Nexus
packages, as most users have other tools. Do not make a new macOS user account. (owner)

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

### 8b. Worktree detection

Work: watch .git/worktrees of each site. `git worktree list --porcelain` is the source of truth.
A worktree counts as removed only when git no longer lists it (D53).

Done when: `git worktree add` and `claude --worktree` both give a workspace. `git worktree
remove` starts the removal.

### 8c. Domain and certificate

Work: the host rule (D42), a certificate for each workspace host, the nginx server blocks.

Done when: my.shop.test gives my.shop-test-1.test, and blog.local gives
blog-test-1.test. Both open with a valid certificate.

### 8d. The .env

Work: copy the .env when the worktree has none. Rewrite the hosts. Set the database and Redis
keys from the probe. Add a line when the key has none. Add the extra keys of the site with
placeholders (D44, D45). Check with `git check-ignore` before the write (D50).

Done when: a diff between the main .env and the workspace .env shows only the expected keys.

### 8e. Databases

Work: copy every database of the site that is on a Nexus instance (D46). MySQL and MariaDB
use mysqldump with --single-transaction and a restore. MySQL also needs --set-gtid-purged=OFF:
MySQL 9 turns GTIDs on, and a dump with GTID_PURGED fails when it goes back into the same
server. PostgreSQL uses pg_dump and
pg_restore. CREATE DATABASE with TEMPLATE needs a template that has no other connections,
so it is not the default. SQLite gets an APFS clone.

Done when: the application with four MySQL connections gets four database copies. The main databases do not change. A checksum
before and after the copy proves it.

### 8f. Redis

Work: give each Redis connection of each workspace its own index (D47). Empty the indexes at
removal.

Done when: a cache write in a workspace is not visible in the main site.

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
database. Empty the Redis indexes. Remove the server blocks and the certificate. Delete dumps
older than 7 days (D53).

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
