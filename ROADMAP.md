# Roadmap

Nexus gets updates about every week until version 1.0. The order below can change. Each item
needs research and a plan before the work starts.

## Planned

In this order:

1. **A viewer for dumps.** Nexus catches `dump()`, `dd()` and similar calls of each site and
   workspace, without a change in your code. The app shows them for each request. A later part
   adds the database queries, the log lines and the queue jobs of each request.
2. **Notifications that open the right place.** A click on a notification opens the screen that
   the notification is about. A new mail opens the Mail screen with the site of that mail and the
   mail itself. A workspace that is ready opens its site. A service that stopped or failed opens
   that service. An import opens its database.
3. **Xdebug only for debug requests.** A request with the Xdebug cookie goes to a PHP process with
   Xdebug. All other requests stay fast. One command can also run with Xdebug.
4. **More for workspaces:**
   - a dev server that starts when you open the site and stops when nobody uses it;
   - stop idle workspaces, if you want: their database server and workers stop until the next
     request;
   - a list of old workspaces, with a button to remove them;
   - a button on the Site screen that removes one workspace, next to "Open".
5. **Help for a project that you add.** Nexus offers to point its database, its Redis and its
   `APP_URL` to Nexus, with a backup of the old values.
6. **Your own nginx and Apache lines** for each site, as `nexus ini` gives for PHP. Also a
   `redis.conf` that you can edit, as `my.cnf` is for MySQL.
7. **Share a site through a tunnel.** A local site gets a public link, for example for a client or
   for a webhook.

## Packages

- **PHP 8.6**, after its release.
- **More PHP extensions:** `gmp` and `memcached`, in each PHP version where they build and load.
- **PostgreSQL extensions:** pgvector, PostGIS and pgRouting.
- **MongoDB.** A database service with versions, as MySQL, MariaDB and PostgreSQL have. Each PHP
  version gets the `mongodb` extension.
- **Valkey.** The fork of Redis with the BSD license, as a service next to Redis.

## Later

- Import a .wpress file with a password or with compression.
- A log viewer for the logs of your apps.
- Global keyboard shortcuts.

## Done recently

- **0.3.0:** an MCP server for coding agents such as Claude Code, Codex and Cursor, with Settings >
  Agents, and help for a separate database for the tests of a Laravel site.
- **0.2.6:** automatic updates that ask for a restart, so an update does not wait until you quit
  Nexus.
- **0.2.5:** PCOV also for `pest --tia` and `pest --mutate`, and a check for app updates every
  hour.
- **0.2.4:** import a dump file, a dump file for each new workspace (WordPress links change during
  the load), a workspace in one step, extra files and removal commands for workspaces, `nexus open`,
  `nexus edit` and database commands, a document root setting, better error pages, plain error
  texts, PCOV for `--coverage` and `mailparse`.
- **0.2.3:** package updates install by themselves, for example a security fix of PHP or Node.js.
- **0.2.2:** `php`, `composer` and `wp` follow the project in their arguments. Workspaces wait for
  your own worktree scripts.

## Not planned

- Windows and Linux. Nexus stays a macOS app.
- FrankenPHP.
- A paid version.
- A settings file for a team in the repository, for now. Nexus is for one developer.

## Ideas

[Open an issue](https://github.com/NexusLocal/nexus/issues/new?template=feature_request.yml) on
GitHub with your idea or wish.
