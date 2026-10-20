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
- **Measurable progress**: any item can count toward a target (see below), so "read ten papers" is one item at *4/10 papers*, not ten items.
- **Projects** group items and come in three types (see below).
- **Progress log**: every status change and note is timestamped per item; changes made by the assistant are marked as such.
- **Review** dashboard (⌘4): completed/added counts, experiments by phase, active coding, blocked/overdue/stale work, per-project progress, and an activity timeline over 7/14/30 days.

## Progress toward a target

Some work is measured in units: papers to read, pages to write, runs to finish. Turn on **Track progress toward a target** in an item's detail panel and set the target and a unit (e.g. 10 papers). The item then shows *4/10 papers* with a small bar.

- **Update it in place**: click − or + on the list row or board card, use **Progress +1 / −1** in the context menu, or type the exact number in the detail panel.
- **Status follows the count**: the first step moves the item to In Progress, reaching the target marks it Done, and going back below the target reopens it. Changing the status yourself always wins.
- **History stays readable**: steps within five minutes are saved as one log entry, e.g. *Progress 3 → 7/10 papers*.
- **The assistant uses it too**: "I read two more papers" adds to the existing item instead of creating new ones.

## Projects

Each project has a type that sets which kind new items get and how its progress is shown:

| Type | For | Progress |
|---|---|---|
| **Research** | A paper, research thread, or system | Coding / experiment / writing progress bars and a deadline |
| **Personal** | An area or effort in your life: health, finances, a trip, a move | Open, done this week, overdue, and next due |
| **Misc** | Everything else: errands, admin, reviewing duties | Open, done this week, overdue, and next due |

Personal and misc projects are often ongoing, so the deadline is optional and shown as a *target date*. Pick the type when creating a project, or change it later in the editor or from the project's context menu. When you change a project to Personal or Misc, the editor can convert its items to the matching kind too.

Filing an item into a project of a different type changes its kind to match. This applies to the sidebar drop, the Project picker, and the context menu. A coding item moved into *Health* becomes Personal. Research items keep their kind inside research projects.

### Sidebar

- **Today, Inbox, Upcoming, Review**: lists that collect items from everywhere.
- **Research**: Coding, Experiments, Writing, Reading, Tasks.
- **Life**: Personal, Misc.
- **Projects**: every project of every type in one list, told apart by icon and color (hover to see the type). The **+** menu creates a Research, Personal, or Misc project. Archived projects are folded in at the bottom.
- **All Items, Logbook**.

The Review dashboard and the Project pickers group projects by type.

## Moving, copying, and rearranging

- **Rearrange** by dragging items within a list or board column. Order is kept per item and shared by all lists; use the toolbar's Sort menu to switch between Manual, Priority, Due Date, and Title (dragging sets the order only in Manual). Upcoming and Logbook are always ordered by date.
- **Drag between sections** to change status: dropping into *Running*, *In Review*, *Blocked*, etc. (or onto a board column) updates the status, and experiment run times are stamped as usual.
- **Drag onto the sidebar** to file items: a project assigns it, a kind (Coding, Experiments, …) changes its kind, Today flags it, Inbox untriages it, Logbook completes it.
- **Hold ⌥ while dropping** to copy instead of move.
- **Select several** items with ⌘-click or ⇧-click; drags, the context menu, and the clipboard act on all of them.
- **⌘C / ⌘X / ⌘V**: copy and paste duplicate items into the current list (after the selection). Cut doesn't remove anything: the items fade, and the next paste moves them, keeping their history. Esc cancels a cut. Copied items paste into other apps as a Markdown checklist, and pasting or dropping plain text into a list creates one item per line (bullets, numbers, and `[x]` are understood).
- **⌘D** duplicates the selection in place. Copies get a fresh progress log.

## Assistant

Open with ⌘J. The assistant works through tools that read and modify the same database the UI uses: list/get/create/update items, edit checklists, log progress, manage projects, and produce a review summary. It knows the project types and files personal and misc items into matching projects, not research ones. It sees which list and items you're looking at, so "log that this run finished with ppl 18.9" applies to the selected experiment. It can mark items *dropped* but cannot delete them.

### Model providers

Configure providers in **Settings → Providers** (⌘,). Two API styles are supported:

- **Anthropic Messages API** — Claude models (default: Claude Opus 5.5, medium effort), or an Anthropic-compatible gateway.
- **OpenAI-compatible Chat Completions** — OpenAI, OpenRouter, DeepSeek, Ollama, LM Studio, vLLM, llama.cpp, or any server exposing `/v1/chat/completions` with function calling.

Add one from a preset with **+**, set its base URL, key, and model (the ↻ button loads the server's model list), then **Test Connection** — it checks auth, the model name, and that the model can call tools, which the assistant needs. API keys are stored per provider in your login Keychain; local servers can run without one. `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` from the environment are used as fallbacks.

**Switching:** use the menu in the assistant panel's header (providers with several *Quick Switch Models* show them as a submenu), the **Assistant** menu, or **⌃⌘1–9**. Switching keeps the conversation: the transcript is stored in a provider-neutral form and translated for whichever API answers next.

## Local API

Local AI clients such as Codex chats can do everything the built-in assistant can, through a JSON API the app serves on `127.0.0.1`. Turn it on in **Settings → API**. Requests need a bearer token, which is kept with the base URL in `api.json` next to the database (readable only by you).

The assistant and the API run the same operations from one shared registry, with the same arguments, validation, and results. `GET /v1/tools` lists them and their schemas, and `POST /v1/tools/{name}` calls one. Items come with their checklists and quantitative progress as structured data.

Changes go through the same store as the UI, so they appear at once. They are saved together with their log entries, marked *Assistant* or *API*. Items and projects have revision numbers for conflict checks, and every change accepts an idempotency key so retries never repeat it. The original task and project endpoints still work as adapters over the same operations. Endpoints, schemas, statuses, and error codes are in [docs/API.md](docs/API.md).

## Shortcuts

| | |
|---|---|
| ⌘N | New item (focuses quick-add) |
| ⇧⌘N | New project (type follows the current list or project; **File → New Project** picks one) |
| ⌘1 – ⌘4 | Today, Inbox, Upcoming, Review |
| ⌘5 – ⌘7 | Coding, Experiments, Writing |
| ⌘J | Toggle assistant |
| ⇧⌘J | New assistant conversation |
| ⌃⌘1 – ⌃⌘9 | Switch model provider |
| ⌘C / ⌘X / ⌘V | Copy / cut / paste items |
| ⌘D | Duplicate |
| ⌫ | Mark selected items dropped |
| Esc | Cancel a pending cut |

## Data

SQLite at `~/Library/Application Support/DoResearch/doresearch.sqlite` (WAL mode). Override with `DORESEARCH_DB=/path/to/file.sqlite` — useful for testing against scratch data. The API connection file (`api.json`) lives in the same folder.
