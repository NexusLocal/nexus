# Roadmap

Nexus gets updates about every week until version 1.0. The order below can change. Each item
needs research and a plan before the work starts.

## Planned

In this order:

1. **Share a site through a tunnel.** A local site gets a public link, for example for a client or
   for a webhook.
2. **Packages:**
   - **PHP 8.6**, after its release.
   - **More PHP extensions:** `gmp` and `memcached`, in each PHP version where they build and
     load.
   - **PostgreSQL extensions:** pgvector, PostGIS and pgRouting.
3. **MongoDB.** A database service with versions, as MySQL, MariaDB and PostgreSQL have. Each PHP
   version gets the `mongodb` extension.
4. **Valkey.** The fork of Redis with the BSD license, as a service next to Redis.
5. **A log viewer** for the logs of your apps.

## Later

- Global keyboard shortcuts.

## Done recently

- **0.6.2:** a switch to remove a workspace without a dump of its databases, and a fix for a
  crash of the background service.
- **0.6.1:** an update no longer loses a change while the background service ends its work, and
  the dump viewer is off until you turn it on.
- **0.6.0:** workspaces that stop when nobody uses them and start again with the next page,
  command or database connection, dev servers that start with the first page, a list of old
  workspaces with one step to remove them, and "Remove Workspace…" for one workspace.
- **0.5.0:** the queries, the log lines and the queue jobs of each request in the dump viewer,
  notifications that open the right place, Xdebug only for debug requests and `nexus debug`, "Use
  Nexus…" for the `.env` of a project that you add, your own nginx and Apache lines for each site,
  and the import of a .wpress file with a password or with compression.
- **0.4.1:** an Agents screen with the MCP tools, the result of "Check for updates", the tag of
  each mail of a Laravel site, "Open in Mailpit" for a site, dark mails and your own redis.conf.
- **0.4.0:** a viewer for `dump()` and `dd()` of each site, workspace and command, in the app, in
  the browser and with `nexus dumps`.
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
