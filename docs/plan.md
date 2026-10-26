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

Risk: Firefox uses its own certificate store. The UI shows a short instruction for Firefox.

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

## Step 5 - Databases and Redis

Work:
1. Instances of MySQL, MariaDB and PostgreSQL. Each has its own version, port and data folder
   (D34). The user root with the password root on 127.0.0.1 (D35).
2. Redis instances with "databases" set high enough for all workspaces (D47).
3. The action "copy a database from another server": a dump from the other server and a
   restore into a Nexus instance (D37). The other server is only read.
4. The button that opens a database in TablePlus or Sequel Ace (D36).

Done when:
- MySQL 8.0, MySQL 8.4 and PostgreSQL 17 run at the same time on their own ports.
- The development database of a real project comes over from MAMP. That project then works on
  Nexus with only DB_PORT changed in its .env.

## Step 6 - The app window and the menu bar

Each step adds its own screens. This step completes them:
1. Overview: services, sites, workspaces and their state.
2. Sites: the settings of each site, the workspace settings and the background processes.
3. Services: versions, instances, ports, logs and the module and extension toggles.
4. The first-run flow: install the first versions, trust the CA, set the resolver, start at
   login, and the PATH setting (off by default).
5. The menu bar item: state, start, stop, open a site.

Done when: a new user can go from the first launch to a working site without the terminal.

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
