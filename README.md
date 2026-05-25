# bookorbit.koplugin

> KOReader plugin for syncing reading statistics and progress with [BookOrbit](https://bookorbit.app).

This plugin connects KOReader to your BookOrbit account, pushing reading session data and live progress updates so your BookOrbit dashboard stays in sync across all your devices: e-readers, tablets, phones, and desktops.

---

## Features

- **Live progress sync:** pushes your current page and percentage to BookOrbit as you read, keeping your "Currently Reading" cards up to date in near real-time
- **Full reading statistics sync:** sends session-level data (page interactions, timestamps, durations) from KOReader's local `statistics.sqlite3` to BookOrbit for server-side analytics
- **Delta syncing:** only sends new data since the last successful sync, not the full database every time
- **Automatic sync triggers:** syncs on book close, device suspend, network reconnect (if >30 min since last sync), and configurable page/minute reading thresholds
- **Multi-device support:** each device syncs independently under your BookOrbit account; all stats are aggregated server-side

---

## Prerequisites

- KOReader installed on your device (e-reader, phone, or tablet)
- A BookOrbit account with a KOReader account configured
- Network access from your KOReader device

---

## Installation

### Installation from zip (recommended)

1. Download the latest zip from the [Releases](../../releases) page.
2. Unzip it and copy the `bookorbit.koplugin` folder into your KOReader plugins directory.

### Installation from source

1. Clone this repository.
2. Copy the `bookorbit.koplugin` folder into your KOReader plugins directory.

The plugins directory is typically located at:

| Device type | Path |
|---|---|
| Kobo | `koreader/plugins/` |
| Kindle | `koreader/plugins/` |
| Android | `koreader/plugins/` on internal storage |

3. Restart KOReader. The BookOrbit plugin will appear under **Tools > BookOrbit**.

### Directory structure requirement

The plugin folder **must** be named `bookorbit.koplugin` exactly. This is a KOReader requirement for plugin discovery.

---

## Configuration

1. Open KOReader and go to **Tools > BookOrbit > Settings**.
2. Enter your BookOrbit server URL (e.g. `https://bookorbit.app`).
3. Enter your KOReader account username and password.
   - These are the credentials from the KOReader account configured in your BookOrbit web app, not your main BookOrbit login.
   - Your password is stored and transmitted using the MD5 hash format expected by the KOSync protocol.
4. Save settings. The plugin will attempt a connection test.

### Per-user setup

Each BookOrbit user should configure the plugin with their own KOReader account credentials. Stats are pushed and stored per user, so multiple people in the same household should each have their own BookOrbit account and KOReader account pair.

---

## How it works

### Data source

The plugin reads from KOReader's local SQLite statistics database (`statistics.sqlite3`), specifically the `book` and `page_stat_data` tables. These tables contain:

- Book metadata (title, authors, total pages, MD5 hash)
- Per-page reading events (page number, start timestamp, duration in seconds)

The MD5 hash of the book file is used as the canonical identifier for matching books between KOReader and BookOrbit.

### Sync flow

**Bootstrap (first sync)**

On the first sync, the plugin sends a full snapshot of all books and their reading history. This establishes the baseline on the BookOrbit side.

**Incremental sync (ongoing)**

After the bootstrap, the plugin stores a cursor (timestamp of last successful sync). On each subsequent sync, only sessions newer than that cursor are sent. This keeps payloads small even for heavy readers.

**State sync (checkpoints)**

On book close or device suspend, the plugin also sends a lightweight state update with the book's current page, progress percentage, and cumulative reading time.

### Sync triggers

The plugin syncs automatically when:

- A book is closed
- The device suspends/sleeps
- The network becomes available and more than 30 minutes have passed since the last sync
- A configurable reading threshold is reached (pages read or minutes elapsed)

You can also trigger a manual sync from **Tools > BookOrbit > Settings > Sync Now**.

---

## API contract

The plugin communicates with BookOrbit using two endpoints. Both require KOSync-protocol authentication headers.

### `PUT /api/progress`

Lightweight, frequent progress updates. Keeps the "Currently Reading" state in BookOrbit accurate without waiting for a full stats sync.

```json
{
  "document": "ab143951...",
  "progress": "120",
  "percentage": 0.42,
  "device": "KOReader"
}
```

| Field | Description |
|---|---|
| `document` | MD5 hash of the book file (fallback: file path) |
| `progress` | Current page number as a string |
| `percentage` | Reading progress as a float (0.0-1.0) |
| `device` | Source device/app identifier |

### `POST /api/stats`

Main statistics ingestion endpoint. Sent on delta sync and bootstrap.

```json
{
  "since": 1779297000,
  "timestamp": 1779299000,
  "books": [
    {
      "id_book": 8,
      "md5": "ab143951...",
      "document": "ab143951...",
      "title": "Eigenvalues and Eigenvectors",
      "authors": "N/A",
      "pages": 14,
      "last_open": 1779297822,
      "notes": 0,
      "highlights": 0,
      "total_read_secs": 49,
      "total_read_mins": 0,
      "total_read_pages": 2,
      "page_sessions": [
        {
          "page": 2,
          "start_time": 1779297772,
          "duration": 5,
          "total_pages": 14
        },
        {
          "page": 2,
          "start_time": 1779297778,
          "duration": 44,
          "total_pages": 14
        }
      ]
    }
  ]
}
```

**Top-level fields**

| Field | Description |
|---|---|
| `since` | Unix timestamp of last successful sync (0 for bootstrap) |
| `timestamp` | Unix timestamp of this sync |
| `books` | Array of books with activity since `since` |

**Book object fields**

| Field | Description |
|---|---|
| `id_book` | KOReader internal database ID |
| `md5` | Canonical book identifier (MD5 hash of file) |
| `document` | MD5 hash or fallback file path |
| `title` | Book title |
| `authors` | Author(s) string, or `null`/`"N/A"` |
| `pages` | Total page count |
| `last_open` | Unix timestamp of last session |
| `notes` | Note count |
| `highlights` | Highlight count |
| `total_read_secs` | Cumulative seconds spent reading this book |
| `total_read_mins` | Cumulative minutes (rounded) |
| `total_read_pages` | Total pages read across all sessions |
| `page_sessions` | Raw reading activity events (see below) |

**`page_sessions` object fields**

| Field | Description |
|---|---|
| `page` | Page number interacted with |
| `start_time` | Unix timestamp of the reading event |
| `duration` | Seconds spent on this page in this event |
| `total_pages` | Snapshot of total pages at time of event |

### Authentication

All requests include KOSync-protocol auth headers. The password is sent as an MD5 hash, matching the format BookOrbit stores in the `koreader_users` table. No separate credential setup is needed beyond configuring your KOReader account in the BookOrbit web app.

---

## Analytics and data processing

The plugin only collects and forwards raw data. All analytics are computed server-side by BookOrbit. This includes:

- Reading heatmaps
- Streak tracking
- Reading pace charts
- Session timelines
- Completion estimates
- Genre reading time
- Yearly reading summaries
- Habit analytics

This keeps the plugin lightweight and the KOReader device unburdened.

---

## Troubleshooting

**Plugin does not appear in KOReader**
Verify the plugin folder is named exactly `bookorbit.koplugin` and is placed in the correct plugins directory. Restart KOReader after installing.

**Authentication fails**
Confirm you are using your KOReader account credentials (set up in BookOrbit's web app), not your main BookOrbit login. Ensure the server URL does not have a trailing slash.

**Stats not appearing on the BookOrbit dashboard**
Check that the BookOrbit server has implemented the `POST /api/stats` endpoint. Progress updates (`PUT /api/progress`) and stats sync are separate; the dashboard charts require the stats endpoint.

**Sync not triggering automatically**
Manual sync is available via **Tools > BookOrbit > Settings > Sync Now**. Automatic triggers require network connectivity and depend on reading thresholds being met.

---

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request.

If you are adding a feature or fixing a bug, open an issue first to discuss the approach.

---

## License

This project is licensed under the [GNU Affero General Public License v3.0 (AGPL-3.0)](LICENSE).