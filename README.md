# MessagingSessionKit — Demo App

An iOS app that lets you break a realtime messaging connection on purpose and watch the client
survive it.

The [MessagingSessionKit](https://github.com/rajatslakhina/messaging-session-kit) library answers a
question that is hard to demonstrate in a README: *what actually happens to your messages when the
socket dies?* This app makes that visible. Drop the socket mid-send. Start losing acks. Watch the
outbox refuse to lose anything, the backoff arm itself, the reconnect resume, and the duplicate
suppression quietly do its job.

---

## Why this matters

The failure modes this app reproduces are the ones you cannot reproduce on demand in real life:

| Button | What it triggers | What you should watch for |
|---|---|---|
| **Send 6** | six messages across two conversations | at most **one in-flight per conversation** — ordering is enforced, not hoped for |
| **Drop socket** | the server kills the connection mid-flight | backoff arms and the reconnect resumes. *Turn on **Acks: lossy** first* — against a perfect in-memory server the round trip is instantaneous, so there is rarely anything in flight to watch move back to pending |
| **Acks: lossy** | every 2nd ack is silently discarded | **`redelivered` climbs while `received` stays flat** — the message goes out twice and lands in the thread once |
| **Peer msg** | an inbound message from another user | inbound sequence tracking on traffic the client did not originate |
| **Stream: lossy** | every 3rd server broadcast is skipped | `gaps` climbs — the client detects the hole in the sequence rather than silently rendering a thread with a piece missing |
| **Replay** | the server re-sends its buffered history | `dupes killed` climbs while `received` stays flat — the second dedup layer catching a server-side replay |
| **Dials: refused** | every reconnect attempt is refused | backoff runs out its budget and the session reaches `parked`, which is terminal until **Revive** |
| **Restart** | `stop()` then `start()` | nothing undelivered is lost across a full lifecycle bounce |
| **Revive** | leaves the `parked` state | parking is terminal by design; only the app can overrule it. Tapping it *outside* `parked` is an illegal transition — correctly ignored and counted, and pointedly it does **not** disturb a retry that is already armed |

The **Acks: lossy** row is the one worth sitting with. Turn it on, send a burst, and watch
`redelivered` climb while `received` stays flat. That gap is the entire point of the library:
at-least-once delivery on the wire, composing with server-side idempotency into exactly one message
in the user's thread. (`dupes killed` stays at zero here, and that is correct — the simulated
server suppresses the duplicate on receipt, so the client never sees a second copy to reject. That
counter moves when the *server* replays history, which is what the second dedup layer is for.)

The `illegal events` counter is the other one. Every frame that arrives in a state where it makes no
sense is counted rather than crashed on — and in production, that counter climbing is one of the
highest-signal alerts a realtime client can have.

---

## How to run it

```bash
git clone https://github.com/rajatslakhina/messaging-session-kit-demo-app.git
cd messaging-session-kit-demo-app
open Demo.xcodeproj
```

Then select the **Demo** scheme, pick any iOS Simulator, and **⌘R**.

Xcode resolves the library automatically — this project depends on
[messaging-session-kit](https://github.com/rajatslakhina/messaging-session-kit) as a **remote Swift
Package** (`XCRemoteSwiftPackageReference`, branch `main`), exactly as any external consumer would.
There is no local path reference and no copy of the library in this repository. Requires iOS 17+.

No server is needed: the library ships a fault-injectable `InMemoryTransport` with a small simulated
server that models idempotent receipt by client-generated ID and a per-conversation sequence counter
with replayable history. That is what makes every failure in the table above reproducible on demand.

---

## How the two repositories fit together

```
messaging-session-kit           (library — no app target of any kind, 71 tests)
        ▲
        │ XCRemoteSwiftPackageReference → https://github.com/rajatslakhina/messaging-session-kit.git
        │                                  requirement: branch "main"
        │
messaging-session-kit-demo-app  (this repo — Demo.xcodeproj + one SwiftUI file)
```

The split is deliberate. A library that carries its own demo app target cannot honestly claim to be
consumable, because it has never once been consumed the way a real client would consume it. Keeping
the runnable app in a separate repository that resolves the library by its published git URL means
the integration *will be* proven by construction every time this project builds — including the
first time, which, per the verification note below, has not happened yet.

---

## Honest statement of what was verified

Being precise about this, because "it builds" and "it runs" are different claims:

**Verified.**

- The library it depends on: `swift build` clean with **zero warnings** under the Swift 6 language
  mode (strict concurrency), and **71/71 tests passing** from a clean build directory, re-run
  three times consecutively to check for flakiness.
- `Demo.xcodeproj/project.pbxproj`: brace- and paren-balanced, **20 declared objects with zero
  dangling UUID references**, and the package reference confirmed to be a remote git URL on branch
  `main` rather than a local path.
- `Demo.xcscheme`: parsed and validated as XML.
- `Demo/DemoApp.swift`: parses cleanly under `swiftc -parse`, and a static audit found **zero
  force-unwraps**, with the message-burst count clamped and every collection access bounds-safe.

**Not verified — and not claimed.**

- **The Demo target has never been compiled.** `swiftc -parse` checks syntax only — not types, not
  linking. Xcode has never resolved the `XCRemoteSwiftPackageReference`, so the app-to-library
  integration is unproven at the compiler level. The library itself builds and tests clean, and the
  project file is structurally verified, but that is a weaker claim than "it builds" and it would be
  dishonest to let the two blur together.
- **This app has not been launched on a Simulator.** The pipeline that built it tries to, but its
  first step is to screenshot the machine and check whether anything unrelated is open. On this run
  Xcode was holding an active, unrelated project mid-edit, so the pipeline aborted rather than
  clicking through someone else's session. That is the rule working as intended, not a shortcut.
- Consequently there are **no screenshots** in `Demo/Screenshots/` — see the note in that folder.
  Nothing has been mocked up or substituted. The first ⌘R will genuinely be this app's first launch.

---

## License

MIT
