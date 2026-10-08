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

## Moving, copying, and rearranging

- **Rearrange** by dragging items within a list or board column. Order is kept per item and shared by all lists; use the toolbar's Sort menu to switch between Manual, Priority, Due Date, and Title (dragging sets the order only in Manual). Upcoming and Logbook are always ordered by date.
- **Drag between sections** to change status: dropping into *Running*, *In Review*, *Blocked*, etc. (or onto a board column) updates the status, and experiment run times are stamped as usual.
- **Drag onto the sidebar** to file items: a project assigns it, a kind (Coding, Experiments, …) changes its kind, Today flags it, Inbox untriages it, Logbook completes it.
- **Hold ⌥ while dropping** to copy instead of move.
- **Select several** items with ⌘-click or ⇧-click; drags, the context menu, and the clipboard act on all of them.
- **⌘C / ⌘X / ⌘V**: copy and paste duplicate items into the current list (after the selection). Cut doesn't remove anything: the items fade, and the next paste moves them, keeping their history. Esc cancels a cut. Copied items paste into other apps as a Markdown checklist, and pasting or dropping plain text into a list creates one item per line (bullets, numbers, and `[x]` are understood).
- **⌘D** duplicates the selection in place. Copies get a fresh progress log.

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
| ⌘C / ⌘X / ⌘V | Copy / cut / paste items |
| ⌘D | Duplicate |
| ⌫ | Mark selected items dropped |
| Esc | Cancel a pending cut |

## Data

SQLite at `~/Library/Application Support/DoResearch/doresearch.sqlite` (WAL mode). Override with `DORESEARCH_DB=/path/to/file.sqlite` — useful for testing against scratch data.
