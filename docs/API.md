# DoResearch local API

A JSON-over-HTTP API that lets local tools (for example Codex chats) find tasks, update them, and log progress. It is served by the DoResearch app while the app is open, and every change goes through the same store the UI uses. Changes appear in the app immediately and are saved to the normal database (`doresearch.sqlite`).

"Task" here means any DoResearch item; experiments are the main use.

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
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/tasks?chat_id=$CODEX_CHAT_ID"
```

## Interfaces

| Interface | Endpoint |
|---|---|
| `list_projects` | `GET /v1/projects` |
| `list_tasks` | `GET /v1/tasks` |
| `get_task` | `GET /v1/tasks/{id}` |
| `update_task` | `PATCH /v1/tasks/{id}` |
| `append_progress_log` | `POST /v1/tasks/{id}/progress` |
| (statuses) | `GET /v1/statuses` |
| (health) | `GET /v1/health`: no auth; `{"ok": true, "api_version": 1}` |

## Status values

`status` is the **experiment status**. These seven names are used for every task, whatever its kind; in the app, non-experiment kinds show their own names for the same states (e.g. *Planned* is *To Do* for a coding item).

| Status | Open | Meaning |
|---|---|---|
| `Inbox` | yes | Not yet triaged |
| `Planned` | yes | Ready, not started |
| `Running` | yes | Running; the run start time is stamped automatically |
| `Analyzing` | yes | Run finished, results being analyzed; the run end time is stamped |
| `Blocked` | yes | Cannot proceed |
| `Concluded` | no | Finished |
| `Dropped` | no | Abandoned (the API never deletes tasks) |

Names are matched case-insensitively on input and always returned as above. **Chat execution status is separate.** Whether a Codex chat is running, finished, or failed is not an experiment status, and DoResearch does not store it as one. Values such as `completed`, `failed`, or `in_progress` are rejected with `invalid_field`. To record what a chat did, append a progress log entry.

`outcome` values: `pending`, `supported`, `refuted`, `inconclusive`, `failed`.

`GET /v1/statuses` returns these lists:

```json
{
  "statuses": [{"name": "Inbox", "open": true}, …, {"name": "Dropped", "open": false}],
  "outcomes": ["pending", "supported", "refuted", "inconclusive", "failed"],
  "updatable_fields": ["title", "status", …]
}
```

## Revisions

Every task has an integer `revision`, starting at 1, that increases on every saved change: edits from the app, the assistant, or the API, checklist changes, and new log entries. Reordering lists does not change it.

To avoid overwriting newer edits, send the revision you last read as `expected_revision` in `update_task`. If the task has changed since, the request fails with `409 revision_conflict` and changes nothing. Re-read the task, reapply your change, and retry. `expected_revision` is optional; without it the update applies unconditionally, but still only to the fields you send.

## Objects

### Task summary (in `list_tasks`)

```json
{
  "id": "k3mz8qpa",
  "title": "Ablation: sparsity 0.9",
  "kind": "experiment",
  "status": "Running",
  "project_id": "b7x2n4kc",
  "chat_ids": ["codex-1"],
  "revision": 4,
  "updated_at": "2026-10-12T09:41:07.512Z"
}
```

`kind` is one of `coding`, `experiment`, `writing`, `reading`, `task`, `personal`, `misc`. `project_id` may be `null`.

### Task (in `get_task` and `update_task`)

The summary fields, plus:

```json
{
  "project": {"id": "b7x2n4kc", "name": "Sparse Attention", "type": "research"},
  "hypothesis": "ppl within 2% of dense",
  "setup": "bs=64, seed 0, configs/sparse09.yaml",
  "compute": "4×A100, cluster-a",
  "notes": "",
  "results": "",
  "conclusion": "",
  "outcome": "pending",
  "metrics": [{"name": "ppl", "value": "18.9"}],
  "created_at": "2026-10-10T14:00:00.000Z",
  "run_started_at": "2026-10-12T08:02:11.000Z",
  "run_ended_at": null,
  "progress_log": [ /* log entries, newest first */ ]
}
```

`project` is `null` when there is no project. Metric values are always strings. Timestamps are ISO 8601 UTC.

### Log entry

```json
{
  "id": "q8w2e4r6t7y9",
  "created_at": "2026-10-12T09:41:07.512Z",
  "kind": "note",
  "text": "Epoch 3: ppl 19.2",
  "author": "api",
  "source_chat_id": "codex-1",
  "idempotency_key": "codex-1/turn-17"
}
```

`kind`: `created`, `status` (status changes, e.g. "Planned → Running"), `note`, `update` (field changes, e.g. "Updated setup, compute"), `progress` (counts). `author`: `user` (the app), `agent` (the built-in assistant), `api`. `source_chat_id` and `idempotency_key` are `null` for entries not appended through the API.

## Endpoints

### `GET /v1/projects`

Query: `include_archived=true` (optional; default excludes archived projects).

```json
{"projects": [{"id": "b7x2n4kc", "name": "Sparse Attention", "type": "research", "status": "active"}]}
```

`type`: `research`, `personal`, `misc`. `status`: `active`, `paused`, `done`, `archived`. Project ids are stable.

### `GET /v1/tasks`

Query parameters (all optional, combined with AND):

| Param | Matches |
|---|---|
| `project_id` | Tasks in this project; `none` for tasks without one. An unknown id gives `404 project_not_found`. |
| `title` | Case-insensitive substring of the title |
| `chat_id` | Tasks whose `chat_ids` contain this exact id |
| `status` | One status name |
| `kind` | One kind |
| `limit` | Max results, default 100, max 500 |

Unknown parameters are rejected (`invalid_field`), so typos don't silently widen a search. Results are sorted by `updated_at`, newest first; `total` counts all matches before `limit`.

```json
{"total": 1, "tasks": [ /* task summaries */ ]}
```

### `GET /v1/tasks/{id}`

Query: `log_limit` (default 50, max 500).

The task is read from the database, not from a cache, so this also verifies earlier writes.

```json
{"task": { /* task */ }}
```

### `PATCH /v1/tasks/{id}`

```json
{
  "expected_revision": 4,
  "fields": {
    "status": "Analyzing",
    "compute": "4×A100, cluster-a",
    "metrics": [{"name": "ppl", "value": 18.9}]
  }
}
```

Only the fields you send change; everything else is preserved. Updatable fields:

| Field | Type | Notes |
|---|---|---|
| `title` | string | Must not be empty |
| `status` | string | A status name |
| `project_id` | string or `null` | Must be an existing project id |
| `notes`, `hypothesis`, `setup`, `compute`, `results`, `conclusion` | string | Replaces the field's text |
| `outcome` | string | An outcome value |
| `metrics` | array of `{name, value}` | Replaces all metrics; numeric values are stored as strings |
| `chat_ids` | array of strings | Replaces the linked chats (duplicates removed). Read, add your id, and write back with `expected_revision`. |

Response `200`. `task` is the saved state read back from the database, and `changed` lists the requested fields whose value actually changed. A request whose values all match the current ones changes nothing and keeps the revision.

```json
{"task": { /* task, revision 5 */ }, "changed": ["compute", "metrics", "status"]}
```

Changes are logged in the task's progress log with author `api`, the same way the app logs its own edits.

### `POST /v1/tasks/{id}/progress`

```json
{
  "text": "Epoch 3 done: ppl 19.2, loss 2.95",
  "source_chat_id": "codex-1",
  "idempotency_key": "codex-1/turn-17"
}
```

All three are required non-empty strings. The server timestamps the entry. Use a key that is unique per entry, for example the chat id plus a turn or step number. Idempotency keys are global, not per task.

| Case | Response |
|---|---|
| New key | `201`, `"duplicate": false` |
| Same key, same task, text, and chat | `200`, `"duplicate": true`, the original entry. Nothing new is stored. Safe to retry. |
| Same key, different content or task | `409 idempotency_conflict` |

```json
{"entry": { /* log entry */ }, "duplicate": false, "task_id": "k3mz8qpa", "revision": 5}
```

`revision` is the task's revision after the append. A new entry increases it, a replay does not.

## Errors

Every error has this shape. `code` is stable; `message` is for people.

```json
{"error": {"code": "revision_conflict", "message": "…", "expected_revision": 4, "current_revision": 6, "task": { /* current task, without log */ }}}
```

| HTTP | `code` | When | Extra fields |
|---|---|---|---|
| 400 | `bad_request` | Missing or malformed JSON body, bad request line, chunked body | |
| 401 | `unauthorized` | Missing or wrong bearer token | |
| 404 | `task_not_found` | No task with that id | `task_id` |
| 404 | `project_not_found` | Unknown `project_id` filter in `list_tasks` | `project_id` |
| 404 | `not_found` | No such endpoint | |
| 405 | `method_not_allowed` | Wrong HTTP method | `allowed_methods` |
| 409 | `revision_conflict` | `expected_revision` is stale | `expected_revision`, `current_revision`, `task` |
| 409 | `idempotency_conflict` | Key reused for a different entry | `existing_entry` |
| 413 | `payload_too_large` | Body over 1 MiB | |
| 422 | `invalid_field` | Unknown or read-only field, wrong type, unknown status/outcome/kind, empty title, unknown query parameter | `field`, and `allowed` when there is a fixed set |
| 500 | `storage_error` | The database write failed; nothing was changed | |

When the app is closed or the API is disabled, connections are refused.

## Typical flow for a chat

1. `GET /v1/tasks?chat_id=<chat>`. If nothing matches, find the task with `?title=…` or `?project_id=…`, then link it: `PATCH` with `chat_ids` = current list + your chat id, and `expected_revision`.
2. When the experiment changes phase or setup, `PATCH` the fields with `expected_revision`. On `409`, re-read and retry.
3. Log progress with `POST …/progress` and a deterministic idempotency key, so retries never duplicate entries.
4. To verify, `GET /v1/tasks/{id}` and compare the fields and `revision`.
