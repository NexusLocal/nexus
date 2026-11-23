# Roadmap

Nexus gets updates about every week until version 1.0. The order below can change. Each item
needs research and a plan before the work starts.

## Planned

In this order:

1. **PHP 8.6**, when Xdebug, Redis, APCu, pcov, igbinary, YAML, Imagick and memcached have releases
   that support it.

## Later

- Global keyboard shortcuts.

## Done recently

- **0.9.0:** a log viewer for the logs of your apps, on a screen, on a web page, with `nexus logs`
  and for coding agents, and the PHP errors of each site with their time.
- **0.8.0:** MongoDB 7.0, 8.0 and 9.0 as a service with transactions, the import of a MongoDB
  database from Docker, Atlas or a dump file, and a MongoDB server of its own for each workspace.
- **0.7.3:** PostGIS and pgRouting for PostgreSQL 15 to 19, the `mongodb` extension for PHP 8.2 to
  8.5, and a message for each workspace that shares MongoDB with the main site.
- **0.7.2:** pgvector for PostgreSQL 15 to 19, `gmp` and `memcached` for PHP 8.2 to 8.5, and
  "Replace only the tables" that changes nothing when something else uses a table of the dump.
- **0.7.1:** PostgreSQL 19, Server Actions of Next.js, no PHP source on Apache for a file such as
  `info.PHP`, and no crash report of Nexus for a crash of a service.
- **0.7.0:** share a site through a public link, with a password, hidden errors, the requests of
  each webhook in the dump viewer and a fixed address on your own domain.
- **0.6.5:** a line in the activity log for each start and stop with its cause, coding agents
  that keep working after an update, and a safer stop in the "Port in use" window.
- **0.6.4:** a faster switch to a new version after an update, a clear message when a newer
  `nexus` command meets an older background service, and two fixes for a workspace removal that
  stopped halfway.
- **0.6.3:** a notice when Local, Herd, Valet or another app also needs ports 80 and 443, .local
  as a choice for the domain of your sites, and a fix for the message of a failed port change.
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
