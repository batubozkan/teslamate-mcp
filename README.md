<div align="center">

# TeslaMate MCP Server

<img src="assets/teslamcp.gif" alt="TeslaMate MCP Server demo" width="720" />

Connect your AI assistant to your [TeslaMate](https://github.com/teslamate-org/teslamate) data.
This is a [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) server. It reads your TeslaMate PostgreSQL database. It gives MCP clients (Claude Desktop, Cursor, and others) 35 tools, 6 prompts, and interactive charts.

[![CI](https://github.com/batubozkan/teslamate-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/batubozkan/teslamate-mcp/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/batubozkan/teslamate-mcp?logo=github&sort=semver)](https://github.com/batubozkan/teslamate-mcp/releases)
[![GHCR](https://img.shields.io/badge/ghcr.io-batubozkan%2Fteslamate--mcp-2496ED?logo=docker)](https://github.com/batubozkan/teslamate-mcp/pkgs/container/teslamate-mcp)
[![Python](https://img.shields.io/badge/python-3.11%20%7C%203.12%20%7C%203.13-blue?logo=python&logoColor=white)](https://www.python.org/downloads/)
[![License](https://img.shields.io/github/license/batubozkan/teslamate-mcp)](LICENSE)
[![Ruff](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/astral-sh/ruff/main/assets/badge/v2.json)](https://github.com/astral-sh/ruff)

This is a fork of [cobanov/teslamate-mcp](https://github.com/cobanov/teslamate-mcp). It adds the 0.4.0+ feature line.

</div>

## What you can ask

- "Is my battery really degrading?" — the server estimates usable capacity in kWh from your charging sessions.
- "How much range do I lose while parked?" — the server finds vampire drain between drives.
- "Show the route of my longest drive." — the server returns the GPS track, with an interactive map on chart-capable clients.
- "Compare my driving this month with last month." — one call returns both windows, per metric.

## Highlights

- **30 SQL report tools.** Battery capacity and degradation, vampire drain, charging efficiency (AC vs DC), charging costs, geofences, driving patterns, routes, and search tools for drives and charging sessions.
- **3 interactive charts (MCP Apps).** `show_charging_curve`, `show_battery_degradation`, and `show_drive_route` draw charts inside the conversation. On clients without chart support, the same tools return plain rows.
- **Typed inputs and outputs.** Each report tool declares its parameters and result columns in a `.toml` file. The server validates the declarations at startup. Parameters bind as SQL placeholders, never as string concatenation.
- **Safe custom SQL.** `run_sql` runs your `SELECT` inside a PostgreSQL `READ ONLY` transaction, with timeouts and a row cap. The transaction always rolls back.
- **Optional cost writes, with confirmation.** One opt-in tool writes charging costs. A column-scoped database grant limits what it can touch. Clients with MCP elicitation show a confirmation dialog first.
- **Local-time reports.** Set `REPORT_TIMEZONE` and daily, weekly, and monthly buckets follow your local midnight.
- **Two transports.** Run `teslamate-mcp stdio` for local clients. Run `teslamate-mcp http` for remote clients, with bearer-token auth and a `/health` probe.

## Requirements

- TeslaMate with its PostgreSQL database.
- Python 3.11+ for a local install, or Docker for a server install.

## Quick start — local (stdio)

1. Install:

   ```bash
   git clone https://github.com/batubozkan/teslamate-mcp.git
   cd teslamate-mcp
   cp env.example .env      # set DATABASE_URL
   uv sync
   ```

2. Add the server to your MCP client. Example for Claude Desktop or Cursor:

   ```json
   {
     "mcpServers": {
       "teslamate": {
         "command": "uv",
         "args": ["--directory", "/path/to/teslamate-mcp", "run", "teslamate-mcp", "stdio"]
       }
     }
   }
   ```

## Quick start — Docker

```bash
cp env.example .env          # set DATABASE_URL, and set AUTH_TOKEN for remote use
docker compose up -d
```

The MCP endpoint is `http://localhost:8888/mcp`. The liveness probe is `http://localhost:8888/health`.

A multi-arch image (`linux/amd64`, `linux/arm64`) is published to GHCR on each release:

```bash
docker run --rm -e DATABASE_URL=... -p 8888:8888 ghcr.io/batubozkan/teslamate-mcp:latest
```

## Deploy on Unraid, behind Cloudflare

You can reach this server from claude.ai, Claude Desktop, and mobile — with OAuth login and with no open ports on your home network.

The **[Unraid + Cloudflare deployment guide](deploy/unraid/UNRAID_CLOUDFLARE_DEPLOYMENT.md)** shows the full path:

1. Run the container on Unraid with the included [Community Apps template](deploy/unraid/teslamate-mcp.xml).
2. Publish it through a Cloudflare Tunnel. No inbound firewall rules are necessary.
3. Put a Cloudflare Zero Trust **MCP Server Portal** in front. The portal handles OAuth for Claude clients and sends the bearer token upstream.

The guide includes the exact dashboard fields, verification commands for each phase, and a troubleshooting table.

## Tools

Each report tool accepts optional filters: `car_name` everywhere, plus `days`, `limit`, and thresholds where they apply. A call with no arguments returns the full report.

### Reports (18)

| Group | Tools |
|---|---|
| Vehicle | `get_basic_car_information`, `get_current_car_status`, `get_software_update_history` |
| Battery | `get_battery_health_summary`, `get_battery_degradation_over_time`, `get_daily_battery_usage_patterns`, `get_tire_pressure_weekly_trends` |
| Driving | `get_monthly_driving_summary`, `get_daily_driving_patterns`, `get_longest_drives_by_distance`, `get_total_distance_and_efficiency`, `get_drive_summary_per_day` |
| Efficiency | `get_efficiency_by_month_and_temperature`, `get_average_efficiency_by_temperature`, `get_unusual_power_consumption` |
| Charging | `get_charging_by_location`, `get_all_charging_sessions_summary`, `get_most_visited_locations` |

### Insights (6)

| Tool | What it returns |
|---|---|
| `get_battery_capacity_trend` | Usable capacity in kWh, estimated from charging sessions (energy added ÷ SOC gained), per month and car |
| `get_vampire_drain` | Range lost while parked between drives; gaps that contain a charge do not count |
| `get_charging_efficiency` | kWh added vs kWh drawn per car, split into AC and DC |
| `get_charging_by_geofence` | Charging totals per TeslaMate geofence, plus an "Ungeofenced" group |
| `get_soc_hygiene` | Share of samples above 80% and below 20% state of charge |
| `get_period_comparison` | The last N days vs the N days before, one row per metric |

### Search and detail (6)

| Tool | What it returns |
|---|---|
| `search_drives` | Drives filtered by date range, location text, distance, and car; sortable |
| `search_charging_sessions` | Charging sessions filtered by date range, location, energy, and car |
| `get_drive_details` | Full statistics for one drive |
| `get_drive_route` | GPS track points for one drive, downsampled |
| `get_charging_curve` | Power and SOC curve for one charging session, downsampled |
| `get_charging_costs` | Costs grouped by month, location, or car |

### Charts (3)

`show_charging_curve`, `show_battery_degradation`, and `show_drive_route` are the chart versions of their `get_*` tools. On chart-capable clients they draw an interactive chart in the conversation. On other clients they return the same rows as the `get_*` tool.

### Custom (2)

- `get_database_schema` — lists all tables, shows the columns of one table, and re-reads the schema when you pass `refresh=true`.
- `run_sql` — runs one custom `SELECT` or `WITH … SELECT`.

### Cost writes (opt-in, off by default)

Set `ENABLE_CHARGING_WRITES=true` to register `set_charging_cost(charging_process_id, cost)`. It sets the cost of one charging session. This is the same field that the TeslaMate UI edits. A `backfill_costs_from_receipts` prompt guides the receipt-matching workflow.

Give the database role write access to that single column only:

```sql
GRANT UPDATE (cost) ON charging_processes TO teslamate_ro;
```

This grant is the security boundary. The tool cannot write anything else. On clients with MCP elicitation, the user confirms each write in a dialog. `run_sql` stays read-only in all cases.

## Configuration

The server reads all settings from environment variables. It also reads a `.env` file. Only `DATABASE_URL` is required.

| Variable                | Default     | Purpose                                                     |
|-------------------------|-------------|-------------------------------------------------------------|
| `DATABASE_URL`          | _required_  | `postgresql://user:pass@host:5432/teslamate`                |
| `AUTH_TOKEN`            | _empty_     | Turns on bearer auth for the HTTP endpoint                  |
| `HOST`                  | `0.0.0.0`   | HTTP bind host                                              |
| `PORT`                  | `8888`      | HTTP bind port                                              |
| `POOL_MIN_SIZE`         | `1`         | Minimum pool connections                                    |
| `POOL_MAX_SIZE`         | `10`        | Maximum pool connections                                    |
| `QUERY_TIMEOUT_MS`      | `5000`      | `statement_timeout` for `run_sql`                           |
| `CUSTOM_SQL_ROW_LIMIT`  | `1000`      | Row cap added when `run_sql` has no `LIMIT`                 |
| `REPORT_TIMEZONE`       | `UTC`       | IANA timezone for report buckets                            |
| `ENABLE_CHARGING_WRITES`| `false`     | Registers `set_charging_cost`                               |
| `LOG_LEVEL`             | `INFO`      | Python log level                                            |
| `DEBUG`                 | `false`     | Starlette debug mode; keep off in production                |

Generate a bearer token:

```bash
uv run teslamate-mcp gen-token
```

## Add your own query

No code change is necessary. The server finds new queries at startup.

1. Put a `SELECT` in `src/teslamate_mcp/queries/your_query.sql`.
2. Add `your_query.toml` next to it:

   ```toml
   name = "get_your_data"
   description = "What this returns, units, grouping, and available filters."

   [[params]]                 # optional: typed tool arguments
   name = "car_name"
   type = "string"            # string | integer | number | boolean
   description = "Case-insensitive substring match on the car's name."

   [[params]]
   name = "limit"
   type = "integer"
   description = "Maximum number of rows returned."
   default = 10
   minimum = 1
   maximum = 100

   [[output]]                 # optional: one entry per result column
   name = "car_name"
   type = "string"
   ```

3. Write parameters as `%(car_name)s` placeholders in the SQL. Do not build SQL from strings. Cast the first use of each placeholder, for example `%(limit)s::int`. Write a literal `%` as `%%`. The reserved `%(tz)s` placeholder binds `REPORT_TIMEZONE`.
4. Restart the server. The registry validates the pair and registers the tool. Run `teslamate-mcp list-tools` to confirm.

The startup validation rejects a query when a declared parameter is missing from the SQL, or when the SQL uses an undeclared parameter.

## Security

- `run_sql` runs in a `READ ONLY` transaction that always rolls back. Timeouts and a row cap apply.
- Use a `SELECT`-only PostgreSQL role for defense in depth.
- The HTTP transport compares bearer tokens with a timing-safe function.
- Report vulnerabilities through [private security advisories](https://github.com/batubozkan/teslamate-mcp/security/advisories/new). See [SECURITY.md](SECURITY.md).

## Development

```bash
uv sync                          # install with dev dependencies
uv run ruff check src tests      # lint
uv run ruff format src tests     # format
uv run pytest                    # 119 tests; Docker-backed tests skip without Docker
```

## License

MIT — see [LICENSE](LICENSE). Based on [cobanov/teslamate-mcp](https://github.com/cobanov/teslamate-mcp) by Mert Cobanov.
