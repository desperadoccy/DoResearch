# DoResearch local API

A JSON-over-HTTP API that gives local AI clients (for example Codex chats) the same capabilities as DoResearch's built-in assistant. It is served by the app while the app is open.

The API and the assistant share one set of operations:

- **One registry.** Both use the same operation names, argument schemas, validation, defaults, business logic, and result shapes, defined once in `Sources/DoResearch/Operations/`. An operation added there is available to both.
- **Same store and database.** Every change goes through the store the UI uses and is saved to the normal database (`doresearch.sqlite`), so it appears in the app at once and survives a restart.
- **What differs is only the transport:** authentication, and who the change is attributed to (`agent` for the assistant, `api` for this API).

## Contents

- [Connection](#connection)
- [Shared operations](#shared-operations): discovery, invocation, the response envelope
- [Canonical values](#canonical-values): statuses and aliases, kinds, and other enums
- [Data model](#data-model): items, checklists, quantitative progress, logs, projects
- [Operations](#operations): arguments and behavior of each
- [Revisions](#revisions) and [idempotent retries](#idempotent-retries)
- [Errors](#errors)
- [v1 endpoints](#v1-endpoints): the original task and project endpoints, now adapters over the operations
- [Typical flow for a chat](#typical-flow-for-a-chat)

## Connection

| | |
|---|---|
| Enable | **Settings → API → Enable local API** (off by default) |
| Base URL | `http://127.0.0.1:7428/v1` (the port can be changed in Settings) |
| Bind address | `127.0.0.1` only; not reachable from other machines |
| Auth | `Authorization: Bearer <token>` on every request except `GET /v1/health` |
| Format | JSON request and response bodies, UTF-8. Send `Content-Length` (chunked bodies are rejected). Max body 1 MiB. |
| Concurrency | Requests run one at a time, interleaved with UI edits, so a revision check and its write are atomic. |

The token and base URL are written to a connection file next to the database, readable only by your user (mode 0600):

```
~/Library/Application Support/DoResearch/api.json
```

```json
{
  "api_version": 1,
  "auth": "Authorization: Bearer <token>",
  "base_url": "http://127.0.0.1:7428/v1",
  "token": "dr_…"
}
```

Clients should read this file instead of storing the token. **Regenerate Token** in Settings invalidates the old token immediately. With `DORESEARCH_DB=/path/x.sqlite`, the file is `/path/api.json`.

```bash
DR=~/Library/Application\ Support/DoResearch/api.json
BASE=$(jq -r .base_url "$DR"); TOKEN=$(jq -r .token "$DR")
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/tools" | jq '.operations[].name'
```

`GET /v1/health` needs no token and returns `{"ok": true, "api_version": 1}`.

## Shared operations

| Endpoint | Purpose |
|---|---|
| `GET /v1/tools` | Discover the operations: name, description, `mutates`, `expected_revision` target, input schema, output schema. Also returns the request, envelope, and error schemas and the status table. |
| `POST /v1/tools/{name}` | Invoke an operation. |

The operations are `list_items`, `get_item`, `create_item`, `update_item`, `update_checklist`, `add_log`, `list_projects`, `create_project`, `update_project`, and `review_summary`. The assistant's tool definitions are generated from the same registry, so `GET /v1/tools` always shows exactly what the assistant can do.

### Request

```json
POST /v1/tools/update_item

{
  "arguments": {"id": "k3mz8qpa", "progress_add": 2},
  "expected_revision": 7,
  "idempotency_key": "chat-17/event-42",
  "source_chat_id": "chat-17"
}
```

| Key | |
|---|---|
| `arguments` | The operation's arguments, exactly as the assistant passes them. Optional for operations without required arguments. |
| `expected_revision` | Optional. Only for operations that change an existing item or project (see [Revisions](#revisions)). |
| `idempotency_key` | Optional, recommended for every mutation (see [Idempotent retries](#idempotent-retries)). Ignored by read-only operations. |
| `source_chat_id` | Optional. Recorded on every audit entry the request writes. |

There is no way to set the author: API requests are always attributed to `api`. Unknown keys, at the top level or in `arguments`, are rejected with `invalid_field`.

For the assistant, the app supplies the same envelope through trusted context: author `agent`, and optionally a revision or idempotency key. The arguments and their behavior are the same.

### Response

Every successful call returns `200` with this envelope. The assistant receives the same JSON as its tool result.

```json
{
  "operation": "update_item",
  "result": { "item": { … }, "changed": ["progress_current"] },
  "replayed": false,
  "affected": [{"type": "item", "id": "k3mz8qpa", "revision": 8}]
}
```

| Key | |
|---|---|
| `result` | The operation's result (its `output_schema`). Objects in results are read back from the database after the write. |
| `replayed` | `true` when the idempotency key matched an earlier committed request. The original response is returned, and nothing is done again. |
| `affected` | Objects the call wrote, with their revision after the write. Empty for reads. |

Errors return `{"error": {"code", "message", …}}` with the HTTP status for the code (see [Errors](#errors)).

## Canonical values

### Item statuses

One set of statuses. Inputs also accept the experiment labels the API v1 used, as aliases. Both are matched case-insensitively and map to exactly one status. Results always use the canonical value, plus `status_label`, the name the app shows for that item's kind.

| Value | Alias | Open | Experiment | Coding | Others |
|---|---|---|---|---|---|
| `inbox` | `Inbox` | yes | Inbox | Inbox | Inbox |
| `todo` | `Planned` | yes | Planned | To Do | To Do |
| `in_progress` | `Running` | yes | Running | In Development | In Progress (writing: Drafting, reading: Reading) |
| `waiting` | `Analyzing` | yes | Analyzing | In Review | Waiting (writing: Revising) |
| `blocked` | `Blocked` | yes | Blocked | Blocked | Blocked |
| `done` | `Concluded` | no | Concluded | Merged | Done (reading: Read) |
| `dropped` | `Dropped` | no | Dropped | Dropped | Dropped (replaces deletion) |

**Chat execution status is separate.** Whether a chat is running, finished, or failed is not an item status. Values such as `completed` or `failed` are rejected with `invalid_field`; record what a chat did with `add_log`.

### Other values

| | Values |
|---|---|
| Item `kind` | `coding`, `experiment`, `writing`, `reading`, `task`, `personal`, `misc` |
| `priority` | `none`, `low`, `medium`, `high` |
| `outcome` | `pending`, `supported`, `refuted`, `inconclusive`, `failed` |
| Project `type` | `research`, `personal`, `misc` |
| Project `status` | `active`, `paused`, `done`, `archived` |
| Project `color` | `blue`, `purple`, `pink`, `red`, `orange`, `yellow`, `green`, `teal`, `indigo`, `gray` |
| Project `symbol` | SF Symbol names from the app's icon set (listed in the `create_project` input schema) |

Dates: calendar days (`due_date`, `deadline`) are `YYYY-MM-DD` in the user's time zone. Timestamps are ISO 8601 with the local UTC offset, e.g. `2026-10-20T09:41:07+08:00`. Date inputs also accept full ISO 8601 and `"now"`. An empty string clears.

## Data model

Four kinds of progress data are kept apart, and none is derived from another:

| Data | Fields | What it is |
|---|---|---|
| Quantitative progress | `progress_current`, `progress_target`, `progress_unit`, `tracks_progress` | A count toward a target, e.g. 4 of 10 runs |
| Checklist | `checklist` | Discrete steps, each done or not |
| Progress log | `progress_log` | Timestamped textual records: notes, status changes, field changes, count changes |
| Metrics | `metrics` | Reported measurements, e.g. ppl = 18.9 |

Checking off steps doesn't change the count; logging a note doesn't change the count; metrics are never read as progress.

### Item

`get_item`, `create_item`, and `update_item` return the full item. All keys are always present; `null` when empty.

```json
{
  "id": "k3mz8qpa", "title": "Ablation: sparsity 0.9", "kind": "experiment",
  "status": "in_progress", "status_label": "Running", "priority": "high",
  "project_id": "b7x2n4kc", "project": {"id": "b7x2n4kc", "name": "Sparse Attention", "type": "research"},
  "due_date": "2027-01-10", "today": true, "tags": ["ablation"],
  "notes": "…",
  "repo": "", "branch": "", "link": "",
  "hypothesis": "ppl within 2%", "setup": "bs=64", "compute": "4×A100", "results": "", "conclusion": "",
  "outcome": "pending", "metrics": [{"name": "ppl", "value": "18.9"}],
  "run_started_at": "2026-10-20T08:02:11+08:00", "run_ended_at": null,
  "checklist": [{"id": "x7k2m9q4pa", "title": "Verify the data split", "done": false, "position": 0}],
  "checklist_done": 0, "checklist_total": 1,
  "tracks_progress": true, "progress_current": 4, "progress_target": 10, "progress_unit": "runs", "progress_label": "4/10 runs",
  "chat_ids": ["chat-17"], "revision": 8,
  "created_at": "…", "updated_at": "…", "completed_at": null,
  "progress_log": [ /* log entries, newest first */ ]
}
```

`progress_log` is included by `get_item` (`log_limit`, default 25) and by writes (the latest 5). Lists return a compact summary: the same keys without the kind-specific fields, the checklist entries, and the log, and with `notes_preview` (the first 160 characters) instead of `notes`.

### Checklist entry

`{"id", "title", "done", "position"}`. Checklist entries are native records with stable ids. `position` gives their order; new steps are appended after the last one.

### Log entry

```json
{
  "id": "q8w2e4r6t7y9", "created_at": "…", "kind": "note", "text": "Epoch 3: ppl 19.2",
  "author": "api", "item_id": "k3mz8qpa", "project_id": "b7x2n4kc",
  "source_chat_id": "chat-17", "idempotency_key": "chat-17/event-42"
}
```

`kind`: `created`, `status`, `note`, `update` (field and checklist changes), `progress` (count changes). `author`: `user` (the app), `agent` (the built-in assistant), `api` (this API). `idempotency_key` is recorded on the first entry a keyed request writes.

### Project

```json
{
  "id": "b7x2n4kc", "name": "Sparse Attention", "type": "research", "status": "active",
  "summary": "NeurIPS 2027", "deadline": "2027-05-15", "color": "blue", "symbol": "brain",
  "revision": 3, "created_at": "…", "updated_at": "…",
  "progress": {"coding": {"done": 1, "total": 3}, "experiment": {"done": 0, "total": 2}},
  "activity": {"open": 4, "done_last_7_days": 1, "overdue": 0, "next_due": {"id": "…", "title": "…", "due_date": "2026-11-01"}}
}
```

`progress` counts items per kind (dropped excluded). `activity.next_due` is `null` when nothing open has a due date.

## Operations

All arguments other than those marked required are optional. Partial updates change only the arguments you pass; omitted fields keep their values. `null` counts as omitted.

### `list_items`

| Argument | Meaning |
|---|---|
| `kind` | One kind |
| `status` | A status or alias, or `open` (default: not done or dropped), `closed` (done or dropped), `any` |
| `project_id` | A project id, or `none` for items without one. An unknown id returns `project_not_found`. |
| `area` | `research`, `personal`, `misc`: the item's project type, or what its kind implies |
| `query` | Case-insensitive search over title, notes, and tags |
| `title` | Case-insensitive search over titles |
| `chat_id` | Items whose `chat_ids` contain this id |
| `today` | `true`: only items in the Today list (flagged, due by today, or in progress) |
| `sort` | `priority` (default: priority, then due date, then newest), `updated` (most recent first), `manual` (the app's order) |
| `limit` | Default 50, max 500 |

Result: `{"total", "items": [summaries]}`. `total` counts all matches before `limit`.

### `get_item`

`id` (required), `log_limit` (default 25, max 500). Result: `{"item"}`.

### `create_item`

`title` and `kind` are required. Any field below can also be set, plus `checklist`, an array of initial step titles. `status` defaults to `todo`. Result: `{"item"}`.

When no `status` is given, the initial count moves the status the same way a count change does on an existing item: any progress makes it `in_progress`, and reaching the target makes it `done`. An explicit `status` wins. Creating an experiment as `in_progress` stamps its run start time.

### `update_item`

`id` is required. Result: `{"item", "changed"}`, where `changed` lists the item fields whose value changed.

| Argument | Type | Notes |
|---|---|---|
| `title` | string | Trimmed; must not be empty |
| `kind` | kind | Changing it keeps all other fields |
| `status` | status | Status changes are logged; experiment run times are stamped (Running starts the run; leaving Running ends it) |
| `priority` | priority | |
| `project_id` | string | `""` (or `none`) clears; otherwise must be an existing project |
| `notes` | string | Replaces the notes |
| `append_notes` | string | Appended after a blank line |
| `due_date` | day | `""` clears |
| `today` | boolean | Flag for the Today list |
| `tags` | string array | Replaces the tags |
| `repo`, `branch`, `link` | string | Coding fields |
| `hypothesis`, `setup`, `compute`, `results`, `conclusion` | string | Experiment fields; each replaces its text |
| `outcome` | outcome | |
| `metrics` | array of `{name, value}` | Replaces all metrics; numeric values are stored as text |
| `run_started_at`, `run_ended_at` | timestamp | `"now"`, ISO 8601, or `""` to clear |
| `progress_target`, `progress_unit`, `progress`, `progress_add` | | See [Quantitative progress](#quantitative-progress) |
| `chat_ids` | string array | Replaces the linked chats; duplicates are dropped |
| `log` | string | Also adds this note to the progress log |

The whole request is validated before anything is saved. The field changes, the `log` note, and their audit entries are saved together, or not at all.

### Quantitative progress

| Argument | Meaning |
|---|---|
| `progress_target` | Positive integer target; `0` stops tracking (the count is kept). Negative values are rejected. |
| `progress_unit` | Unit such as `papers`, `runs`, `episodes` |
| `progress` | Set the absolute count (0 or more) |
| `progress_add` | Add a signed integer to the count |

Rules, the same for the assistant, the API, and the app:

- **Counts are integers.** Booleans and fractions are rejected.
- **A target comes first.** Reporting a count needs a target, which may be set in the same request.
- **Both together:** if both `progress` and `progress_add` are given, the count is set first, then incremented.
- **Bounds:** the count never goes below 0, and it may pass the target.
- **Status follows the count:** the first progress on a `todo` or `inbox` item makes it `in_progress`, reaching the target makes it `done`, and falling back below the target from `done` makes it `in_progress` again. Changing the target applies the same rules. An explicit status change in the same request wins.
- **Logging:** count changes are logged as `progress` entries ("Progress 3 → 7/10 runs"). Changes by the same author and chat within five minutes share one entry.

### `update_checklist`

```json
{
  "item_id": "k3mz8qpa",
  "add": ["Verify action replay", "Run the baseline"],
  "check": ["x7k2m9q4pa"],
  "uncheck": [],
  "remove": []
}
```

`check`, `uncheck`, and `remove` take step ids or exact titles (case-insensitive), matched against the checklist as it was before the request.

- **All or nothing:** the request is validated as a whole and applied in one transaction. Nothing is applied if a reference matches no step (`checklist_entry_not_found`), a title matches several steps (`ambiguous_match`, with the candidates' ids), the same step appears in `check` and `uncheck` or in `remove` and either (`contradictory_operations`), or a new title is empty (`invalid_field`).
- **Order and untouched steps:** steps not named in the request keep their state and order, and new steps are appended in the order given.
- **Revision:** it moves once per request, and only if something changed.

Checking steps never changes the quantitative count. Result: `{"item_id", "revision", "changed", "checklist", "added"}`; `added` holds the new entries with their ids.

### `add_log`

`item_id` and `text` (both required). Appends a note to the progress log; fields and the count are unchanged. Result: `{"item_id", "revision", "log_entry"}`.

### `list_projects`

`type`, `include_archived` (default false). Result: `{"projects"}`.

### `create_project`

`name` (required), `type` (default `research`), `summary`, `status` (default `active`), `deadline`, `color` and `symbol` (default: the type's). Result: `{"project"}`.

Names are unique among non-archived projects, ignoring case. A taken name returns `409 project_exists` with the existing project in `error.project`.

### `update_project`

`id` (required), and any of `name`, `type`, `summary`, `status`, `deadline` (`""` clears), `color`, `symbol`. The same name rule applies. Changing the type doesn't change its items' kinds. Result: `{"project", "changed"}`.

### `review_summary`

`days` (default 7, max 90). The snapshot the assistant uses for reviews: `window`, `completed`, `created_count`, `experiments` (`running`, `analyzing`, `concluded_in_window` with hypothesis, metrics, and conclusion; `planned`), `coding_active`, `blocked`, `overdue`, `stale` (no update for `stale_after_days`), and `activity` (newest 120 log entries).

## Revisions

Items and projects have an integer `revision`, starting at 1, that increases on every saved change: edits from the app, the assistant, or the API, checklist changes, and new log entries. Reordering lists doesn't change it.

`update_item`, `update_checklist`, and `add_log` check `expected_revision` against the item (the `id` or `item_id` argument), and `update_project` checks it against the project. A stale revision returns `409 revision_conflict` with `expected_revision`, `current_revision`, and the current object (`item` or `project`), and changes nothing. Re-read, reapply, retry. Creates and reads don't take `expected_revision`.

## Idempotent retries

Every mutating operation accepts an `idempotency_key`. The request and a record of its response are committed in the same transaction.

| Case | Response |
|---|---|
| New key | The operation runs; `"replayed": false` |
| Same key, same operation, arguments, and `source_chat_id` | `200` with the original response, `"replayed": true`. Nothing runs again: no second increment, checklist step, note, or item. |
| Same key, different content | `409 idempotency_conflict` |

A committed replay is recognized before the revision check, so a retry of a request that succeeded isn't rejected for the revision it advanced. Keys are global across all operations, so never reuse one. Keys used with an API version before this one stay reserved; reusing one returns `idempotency_conflict`.

## Errors

```json
{"error": {"code": "revision_conflict", "message": "…", "expected_revision": 4, "current_revision": 6, "item": { … }}}
```

`code` is stable; `message` is for people. The assistant gets the same error JSON.

| HTTP | `code` | When | Extra fields |
|---|---|---|---|
| 400 | `bad_request` | Malformed JSON body or request | |
| 401 | `unauthorized` | Missing or wrong bearer token | |
| 404 | `item_not_found` | No item with that id (`task_not_found` on v1 endpoints) | `item_id` |
| 404 | `project_not_found` | No project with that id | `project_id` |
| 404 | `unknown_operation` | No operation with that name | `allowed` |
| 404 | `not_found` | No such endpoint | |
| 405 | `method_not_allowed` | Wrong HTTP method | `allowed_methods` |
| 409 | `revision_conflict` | Stale `expected_revision` | `expected_revision`, `current_revision`, `item` or `project` |
| 409 | `idempotency_conflict` | Key reused for different content | `idempotency_key`, `original_operation` |
| 409 | `project_exists` | Name taken by a non-archived project | `project` |
| 413 | `payload_too_large` | Body over 1 MiB | |
| 422 | `invalid_field` | Unknown argument, wrong type, unknown enum value, empty title or name, count without target, bad date | `field`, and `allowed` when there is a fixed set |
| 422 | `checklist_entry_not_found` | A checklist reference matches no step | `field`, `step` |
| 422 | `ambiguous_match` | A checklist title matches several steps | `field`, `step`, `candidates` |
| 422 | `contradictory_operations` | The same step in conflicting checklist actions | `fields`, `steps` |
| 500 | `storage_error` | The database write failed; nothing was changed | |

When the app is closed or the API is disabled, connections are refused.

## v1 endpoints

The original endpoints still work and return their original shapes. Each one translates the request into a shared operation, so validation, behavior, revisions, and idempotency keys are shared with `/v1/tools`.

| Endpoint | Operation | v1 specifics |
|---|---|---|
| `GET /v1/projects` | `list_projects` | `?include_archived=true`. Returns full project objects. |
| `POST /v1/projects` | `create_project` | Body `{fields, source_chat_id?, idempotency_key?}`. `201` new, or `200` with `"duplicate": true` on replay, returning the project as it is now. |
| `GET /v1/tasks` | `list_items` | `?project_id&title&chat_id&status&kind&limit`. Defaults: `status=any`, sorted by `updated`, `limit` 100. |
| `POST /v1/tasks` | `create_item` | Body `{fields, …}`. `kind` defaults to `experiment`, or to `personal`/`misc` in such projects. `project_id: null` means none. |
| `GET /v1/tasks/{id}` | `get_item` | `?log_limit` (default 50) |
| `PATCH /v1/tasks/{id}` | `update_item` | Body `{fields, expected_revision?, idempotency_key?, source_chat_id?}`. `fields` takes every `update_item` argument except `id`. `project_id: null` clears. |
| `POST /v1/tasks/{id}/progress` | `add_log` | Body `{text, source_chat_id, idempotency_key}`, all required. **Appends a textual progress-log entry. It does not change the quantitative count**; use `update_item` with `progress` or `progress_add` for that. |
| `GET /v1/statuses` | | v1 status names, the canonical status table (`canonical`), and field lists |

The v1 task shape names statuses by their aliases (`"status": "Running"`) and uses UTC timestamps with fractional seconds. It also includes `checklist`, `progress_current`, `progress_target`, `progress_unit`, and `tracks_progress`. Missing tasks are `404 task_not_found` with `task_id`, and a revision conflict carries the task as `task`.

Behavior changes from the first v1 release:
- **Statuses:** status inputs also accept the canonical values (`in_progress`).
- **Field lists:** `PATCH` and `POST /v1/tasks` accept every field of the shared operations.
- **Idempotency matching:** a replay must match the whole request, not just the title.

## Typical flow for a chat

1. `POST /v1/tools/list_items` with `{"arguments": {"chat_id": "<chat>", "status": "any"}}`.
   - If nothing matches, search by `title` or `project_id`. Then link the item by sending `update_item` with `chat_ids` set to its current list plus your id, and `expected_revision`.
   - If the item doesn't exist, use `create_item` with your id in `chat_ids` and an idempotency key. Use `list_projects` or `create_project` for its project.
2. Record work as it happens:
   - `update_item` for status, fields, and counts (`progress_add`).
   - `update_checklist` for steps.
   - `add_log` for narrative.
   Give each call a deterministic idempotency key (chat id + event number), so retries are safe.
3. Send `expected_revision` on updates. On `409 revision_conflict`, re-read and retry.
4. To verify, use `get_item` and compare the fields and `revision`.
