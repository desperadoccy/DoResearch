# DoResearch

A native macOS app (SwiftUI) for tracking day-to-day research work — coding, experiments, writing, reading — alongside personal and miscellaneous tasks, with a built-in Claude assistant that can create, organize, update, and review items for you.

## Build & run

Requires macOS 14+ and the Xcode Command Line Tools (full Xcode not needed).

```bash
./scripts/build-app.sh          # → build/DoResearch.app (release)
open build/DoResearch.app
```

`./scripts/build-app.sh debug` builds without optimizations. Copy the app to `/Applications` to keep it.

Headless checks for the data layer and agent tools:

```bash
./scripts/test.sh
```

## Concepts

- **Items** have a *kind*: Coding, Experiment, Writing, Reading, Task, Personal, Misc. Statuses are shared but named per kind — an experiment is *Planned → Running → Analyzing → Concluded*; coding is *To Do → In Development → In Review → Merged*.
- **Experiments** track hypothesis, setup, compute, run start/end (timed automatically when the status changes), metrics, results, outcome (supported / refuted / inconclusive / failed), and conclusion.
- **Coding items** track repo, branch, PR/issue link, and a checklist of implementation steps with progress.
- **Projects** group items (e.g. one paper) and show per-kind progress and a deadline.
- **Progress log**: every status change and note is timestamped per item; changes made by the assistant are marked as such.
- **Review** dashboard (⌘4): completed/added counts, experiments by phase, active coding, blocked/overdue/stale work, per-project progress, and an activity timeline over 7/14/30 days.

## Assistant

Open with ⌘J. Add an Anthropic API key in Settings (⌘,) — it's stored in your login Keychain (or set `ANTHROPIC_API_KEY` in the environment). Model and effort are configurable; the default is Claude Opus 5.5 at medium effort.

The assistant works through tools that read and modify the same database the UI uses: list/get/create/update items, edit checklists, log progress, manage projects, and produce a review summary. It sees which list and item you're looking at, so "log that this run finished with ppl 18.9" applies to the selected experiment. It can mark items *dropped* but cannot delete them.

## Shortcuts

| | |
|---|---|
| ⌘N | New item (focuses quick-add) |
| ⇧⌘N | New project |
| ⌘1 – ⌘4 | Today, Inbox, Upcoming, Review |
| ⌘5 – ⌘7 | Coding, Experiments, Writing |
| ⌘J | Toggle assistant |
| ⌫ | Drop selected item |

## Data

SQLite at `~/Library/Application Support/DoResearch/doresearch.sqlite` (WAL mode). Override with `DORESEARCH_DB=/path/to/file.sqlite` — useful for testing against scratch data.
