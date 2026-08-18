# SQL Monitor Web Dashboard

A lightweight, Redgate-style web dashboard for the `basemonitor` SQL Server monitoring
data collected into the central `CHN_DBA` repository.

## Prerequisites

- Node.js 18+ installed
- The `basemonitor` collector service already running and writing to `CHN_DBA`
- A dedicated read-only SQL login for this web app (see below)

## 1. Create the read-only SQL login

The collectors connect via Windows Integrated Security. This web app runs as a separate
Node.js process and uses SQL Authentication instead (simpler and more portable than the
native Windows-auth driver for Node).

Run [`../SQL/Create-WebReaderLogin.sql`](../SQL/Create-WebReaderLogin.sql) against the
central repository server (`OVHWEDEV-SQL027\OVHCHN_DEV01`), after changing the password
in the script. This requires Mixed Mode authentication to be enabled on that instance.

## 2. Configure

Edit `config.json` in this folder:

```json
{
  "db": {
    "server": "OVHWEDEV-SQL027\\OVHCHN_DEV01",
    "database": "CHN_DBA",
    "user": "WebMonitorReader",
    "password": "<the password you set in step 1>"
  }
}
```

## 3. Install and run

```powershell
cd WebApp
npm install
npm start
```

Then open http://localhost:3000 in a browser.

## What it shows

- **Overview** — a tile per monitored instance with CPU, memory, blocked sessions,
  oldest full backup age, and failed job count, color-coded Healthy/Warning/Critical.
- **Instance detail** (click a tile) — tabs for CPU/Memory trend charts, Wait Stats,
  Databases, Disk IO, TempDB, Log/VLF, Backups, Agent Jobs, Top Queries, Index Health
  (missing/unused/fragmentation), and live Connections/Blocking.

All pages auto-refresh every 30 seconds. Thresholds used for status coloring are in
`config.json` under `thresholds` and can be tuned without code changes.
