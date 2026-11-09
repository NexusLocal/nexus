# Roadmap

Nexus gets updates about every week until version 1.0. The order below can change. Each item
needs research and a plan before the work starts.

## Next

Small items for the next release.

- **PCOV on by default.** Fast code coverage for your tests, in each PHP version.
- **A workspace in one step.** `nexus workspace create <branch>` and a "New workspace" button make
  the git worktree and the workspace.
- **`nexus open` and `nexus edit`.** They open the site of the current folder in the browser or in
  your editor.
- **Extra files for each workspace.** A site can name files that git ignores, for example
  `.env.testing` or `auth.json`. Each workspace gets a clone of them.
- **Database commands.** `nexus db connection` shows the database connection of a site. Another
  command makes an empty database, for example a test database for an agent.
- **A document root setting** for a project that does not use `public/`.
- **Commands before the removal of a workspace,** for example `php artisan queue:clear`.
- **A dump file for each new workspace.** A site can name a dump file, for example a scrubbed copy
  of production. Each new workspace loads it into its own database.
- **Better error pages:** a list of your sites for a name that Nexus does not know, and a wait page
  while PHP restarts.
- **Plain error texts.** Nexus shows each error as a plain sentence, not as a raw system text.
- **`mailparse`** in each PHP version.

## Planned

In this order:

1. **An MCP server.** A coding agent can read the state of Nexus: the sites, the workspaces, the
   logs and the mail. It can also wait for a mail and open its links. So an agent can test a
   sign-up or a password reset from start to end.
2. **A viewer for dumps.** Nexus catches `dump()`, `dd()` and similar calls of each site and
   workspace, without a change in your code. The app shows them for each request.
3. **Xdebug only for debug requests.** A request with the Xdebug cookie goes to a PHP process with
   Xdebug. All other requests stay fast. One command can also run with Xdebug.
4. **More for workspaces:**
   - a dev server that starts when you open the site and stops when nobody uses it;
   - stop idle workspaces, if you want: their database server and workers stop until the next
     request;
   - a list of old workspaces, with a button to remove them.
5. **Help for a project that you add.** Nexus offers to point its database, its Redis and its
   `APP_URL` to Nexus, with a backup of the old values.
6. **Your own nginx and Apache lines** for each site, as `nexus ini` gives for PHP.
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
