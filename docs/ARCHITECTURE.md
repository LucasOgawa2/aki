# How Aki is built

A map for anyone (person or agent) about to change Aki. It says where things live and how a mark travels; the code says the rest.

## The big picture

```mermaid
flowchart LR
    subgraph Mac["Aki.app (one process, menu bar)"]
        K["Global shortcut<br/>⇧⌘A · aki:// · menu"] --> M["Marking<br/>overlay on every screen"]
        M -->|what's under the pointer| P["Probes<br/>Chrome (AppleScript JS) · Accessibility · OCR"]
        M -->|save| S[("AnnotationStore<br/>~/.aki/annotations.json")]
        S --> B["Sidebar<br/>one ring per session"]
        B -->|types the request| T["Orca tab<br/>(orca CLI)"]
        API["Local server<br/>127.0.0.1 + token"] --- S
    end
    Agent["Claude Code · Codex …"] -->|MCP: aki mcp| API
    Agent -->|CLI: aki list / wait / done| API
    T --> Agent
```

1. **⇧⌘A** (or `aki://mark`, the menu, a ring) opens **marking**: a transparent overlay per screen over a capture of it.
2. While you point, **probes** find what's there: on Chrome-family browsers Aki asks the page itself (an AppleScript `execute javascript` on a dedicated thread); elsewhere macOS Accessibility; text is read from the capture (Vision OCR). On Linux, `aki-mark` asks the page through Chrome's DevTools protocol (`AKI_CDP_URL`, 127.0.0.1 only, the same JS) once a mark is made, not while pointing; the mark stays a point.
3. **Send** saves each mark to the **store** (JSON on disk, cross-process lock), with the session it's for, the text, an optional crop in `~/.aki/images`.
4. The **sidebar** model sees the new marks, waits for you to stop and for the agent to be free, then **types the request** into that session's Orca tab.
5. The **agent** reads the marks through the **MCP server** or the **`aki` CLI** (both talk to the local server), fixes them and marks each one done.

## Targets (`Package.swift`)

| Target | What | Depends on |
|---|---|---|
| `AkiCore` | Everything without UI: the store, the local HTTP server and API, the client the CLI and MCP use, finding agent sessions. Testable. | — |
| `Aki` | The app *and* the `aki` command (same binary: `main.swift` picks by its arguments). | `AkiCore`, Sparkle |
| `AkiChecks` | The checks, as an executable (`swift run AkiChecks`) — no Xcode needed. | `AkiCore` |
| `AkiLinux` | Linux only: `aki-mark`, the marking overlay (GTK 4 on X11): the capture, one window per monitor, each area's words read by tesseract (one read at a time on a serial queue, never on GTK's thread; the send waits up to 3 s for them), the page under a mark on Chrome read through its DevTools (its own queue and socket, 1.5 s a read), saving and delivering through `AkiCore`'s `LinuxMarking`. `aki mark` execs it, so `aki` never links GTK. Swift 5 mode: GTK's C callbacks run on GLib's loop, which Swift 6 can't see as the main actor. | `AkiCore`, `CGtk`, `CX11` |
| `CGtk`, `CX11` | Linux only: GTK 4 and Xlib as system modules (pkg-config `gtk4`, `x11`), with a `shim.h` each for what Swift can't call (the variadic JPEG save). Only `CX11` includes Xlib. | — |

On Linux the package builds `AkiCore`, the `aki` command (`main.swift` and `MCP/`, no app), `aki-mark` (`AkiLinux`) and `AkiChecks`; swift-crypto stands in for CryptoKit there. Sparkle and the app never enter its build.
The `#if os(Linux)` in `Package.swift` selects sources for the build host; cross-compilation (for example, `--swift-sdk` targeting Linux from a Mac) is not supported.

## Where things live

```
Sources/
  AkiCore/
    AkiHome.swift          ~/.aki: paths, the token
    Model/                 Annotation (a mark), JSONValue
    Store/                 AnnotationStore (marks on disk, locked), DiskUsage (cleanup)
    Server/                HTTPServer (127.0.0.1), HTTP parsing, AkiAPI (routes, token, Host/Origin checks)
    Client/                AkiClient (CLI/MCP → server), Waiter (aki wait), AnnotationText (what the agent reads)
    Sessions/              AgentSessions (claude/codex processes → sessions), ClaudeSessions, ClaudeStatus, Worktree, ProcFS (Linux)
    Marking/               Linux marking without UI: LinuxMarking (fields, crop, X11 pixels, monitors, window names), OCR (tesseract's arguments, PPM, TSV), OverlayState,
                           WebSocket (a small RFC 6455 client and HTTP GET over a ByteStream), CDP (DevTools: endpoint, calls matched by id,
                           tab and window, screen → page point), PageElement (the ported page JS and its answer), PageReader,
                           DeliveryPolicy, OrcaDelivery (orca-ide, AKI_DRY_DELIVER), GnomeShortcut
  AkiLinux/                aki-mark (Linux): Capture (X11), Overlay (GTK 4 windows), TextReader (tesseract), PageReading and Browser (DevTools),
                           LoopbackStream (the POSIX socket to 127.0.0.1), GLib (signal, idle and timeout helpers)
  CGtk/, CX11/             GTK 4 and Xlib system modules
  Aki/
    main.swift             entry: the app, or the aki command (list, wait, done, mcp, serve…)
    App/                   AppDelegate, menu bar, Updates (Sparkle), TerminalJump (Orca), TerminalApps, AkiBrand
    Marking/               MarkingController (lifecycle), MarkingSession (state, save), MarkingView (overlay UI),
                           BrowserProbe (Chrome JS), ElementProbe (Accessibility), ScreenGrab, ScreenText (OCR),
                           HotKey (Carbon), AkiCursor
    Sidebar/               SidebarController (panel, hit-testing), SidebarModel (sessions, delivery), SidebarViews,
                           SidebarLayout, EdgeShape, AgentGlyph (AI logos, session identity)
    History/               HistoryWindow (search, filters by AI / app / project / session)
    Settings/              Preferences, SettingsWindow, GetStarted (permissions), Shortcuts (recorder, Raycast)
    Localization/          L10n (engine) + one table per language
    MCP/                   MCPServer (stdio JSON-RPC for agents)
    Codenotch/             views adapted from Codenotch (MIT): the bar's shape, motion, settings controls
Tests/AkiChecks/           store, API, auth, waiting, session detection
Resources/                 Info.plist, app icon, logotype
scripts/                   install, bundle/sign, release → publish, DMG, icon, one-line installer, checks
integrations/raycast/      Raycast script commands
brand/                     logos, tokens, fonts
```

## Decisions worth knowing

- **One binary, no Xcode.** SwiftPM only; `scripts/bundle.sh` assembles and signs `Aki.app`. The `Aki` target runs in Swift 5 language mode (the Codenotch views were written for it).
- **Same certificate always** ("Aki Dev"): macOS keeps Screen Recording and Accessibility across updates.
- **Texts in English in the code**, `L10n.t("…")`, one dictionary per language — a repeated key crashes the app, so `scripts/check-translations.py` guards it.
- **The store is a JSON file**, locked across processes; each write reads the file fresh under the lock.
- **Delivery goes only to Orca tabs** (by the tab handle Orca puts in the process environment); in other terminals the agent picks marks up itself (`aki wait` / MCP).
- **Linux is `#if os(macOS)` away**: macOS keeps its own calls as they were; Linux reads processes from `/proc` (`ProcFS`, parent, start, folder, Orca handle), serves on plain sockets (`HTTPServer+POSIX`) and sees no desktop apps of Claude or Codex.
- **Security**: see [SECURITY.md](../SECURITY.md).
