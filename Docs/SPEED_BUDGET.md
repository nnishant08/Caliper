# Speed budget

Logging speed is one of the three things carrying the product. §5 of the brief
sets it as a hard acceptance criterion rather than an aspiration, which means it
needs a definition precise enough to argue about *before* M3 builds against it.

This document fixes the counting rules. The instrumentation lands with M3.

---

## The budgets

Measured from **cold start** — app not in memory, no prior state.

| Flow | Budget |
|---|---|
| Barcode scan → logged | ≤ 4 actions |
| Search → logged | ≤ 8 actions |
| Repeat a recent or frequent food | ≤ 3 actions |
| Quick-add raw calories | ≤ 3 actions |
| Copy yesterday's meal | ≤ 3 actions |

---

## What counts as one action

A definition that is not agreed in advance will be quietly relaxed the first time
a flow misses its budget.

**One action is one of:**

- A tap or long-press on any control.
- A scroll gesture that is *required* to reach the target — if the target is
  off-screen on a 6.1" device at default text size, reaching it costs one action.
  A scroll that merely browses does not count, because it was not required.
- A **keystroke group**: an uninterrupted run of typing into one field. Typing
  "chicken breast" is one action, not fourteen.
- A swipe that performs a function (delete, complete), not one that scrolls.
- Dismissing a sheet or alert the app raised on its own.

**Zero actions:**

- Anything the app does without the user: automatic barcode recognition once the
  camera is pointed, prefilled fields, an inferred meal slot.
- System-level permission prompts on first run only. They are counted separately
  and reported, but they are not part of the steady-state budget.
- Waiting.

**The cold-start entry tap counts.** Launching from the widget, the Home Screen
quick action, or the app icon is action one in every flow. This is deliberate:
it is what makes the widget and App Intent surfaces worth building, and a budget
that excluded it would flatter us.

---

## Consequences that fall out of the counting rules

Writing the rules down first makes two design decisions unavoidable rather than
debatable:

- **Barcode → logged in ≤ 4 with the launch tap included** leaves no room for a
  meal picker. The meal slot must be inferred from the time of day, with an
  inline chip to change it — changing it costs an action, but only for the user
  who needs to.
- **Scan must auto-recognise.** A "capture" button would cost an action the
  budget cannot afford.
- **The miss path cannot be a dead end** (§5). A barcode we do not have offers
  manual search, then "create food". That path will exceed the budget, and
  should: it is a different flow, and it is reported separately rather than
  averaged into the scan number.

---

## Instrumentation

Built at M3, in `App/Debug/`, behind a debug-build flag.

- An `ActionCounter` that logging surfaces call, recording a typed action kind
  with a timestamp and the flow it belongs to.
- A session begins at cold start or at a deep link, and ends when a food is
  logged or the flow is abandoned.
- A debug overlay showing the live count, so a flow can be walked and watched.
- A summary dumped per session: flow, action count, elapsed time, and whether the
  budget was met.

Reported as measured counts at M3 review, per flow, not as an assurance that the
budgets were met.

Abandoned sessions are recorded too. A flow that meets its budget when completed
but is abandoned half the time is not fast, and only the abandonment number would
show it.
