# Roadmap

Nexus gets updates about every week until version 1.0. The items below come after 0.2. They are
not in a fixed order. Each item needs research and a plan before the work starts.

## Planned

- **A viewer for dumps.** Nexus catches `dump()`, `dd()` and similar calls of each site and
  workspace, without a change in your code. The app shows them for each request.
- **An MCP server.** A coding agent can read the state of Nexus: the sites, the workspaces, the
  logs and the mail.
- **Share a site through a tunnel.** A local site gets a public link, for example for a client or
  for a webhook.
- **MongoDB.** A database service with versions, as MySQL, MariaDB and PostgreSQL have. Each PHP
  version gets the `mongodb` extension.
- **Valkey.** The fork of Redis with the BSD license, as a service next to Redis.
- **More PHP extensions.** `mailparse`, `gmp` and `memcached`, in each PHP version where they build
  and load.
- **A dump file for each new workspace.** A site can name a dump file, for example a scrubbed copy
  of production. Each new workspace loads it into its own database.
- **Xdebug only for debug requests.** A request with the Xdebug cookie goes to a PHP process with
  Xdebug. All other requests stay fast.
- **Stop idle workspaces, if you want.** A workspace without requests can stop its database server
  and its workers. The next request starts them again. You choose the time, or never.
- **Import a .wpress file with a password or with compression.** Nexus asks for the password.

## Not planned

- Windows and Linux. Nexus stays a macOS app.
- FrankenPHP.
- A paid version.

## Ideas

[Open an issue](https://github.com/NexusLocal/nexus/issues/new?template=feature_request.yml) on
GitHub with your idea or wish.
