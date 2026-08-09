# Licensing

How Caliper uses third-party food data, and the invariants that keep that use
clean. A legal review is planned before launch; this document records the shape
we are building to and the reasoning behind it, so the review has something
concrete to check rather than a codebase to reverse-engineer.

Nothing here is legal advice.

---

## Sources

| Source | Coverage | Licence | Attribution required |
|---|---|---|---|
| Open Food Facts | Barcoded and branded products | ODbL 1.0 | **Yes** |
| USDA FoodData Central | Generic and whole foods | CC0 / US public domain | No, but given |
| User-created foods and recipes | The user's own | The user's | n/a |

---

## The invariant

**Open Food Facts data is never merged with anything else.**

ODbL §4.4 attaches share-alike obligations to a *Derivative Database*. If our
proprietary data and our users' data are never merged into the OFF database,
they are not a derivative of it, and the share-alike obligation has nothing to
attach to.

The architecture makes this structural rather than procedural — see
`Docs/DECISIONS.md`, ADR-0004. OFF rows live in `off_products` inside a SQLite
snapshot that the app opens **read-only**. User data lives in a separate
SwiftData store. They are different files with different lifecycles, joined only
in Swift at query time. The app holds no write handle to the OFF table at all,
so a merge is not merely forbidden — it is unavailable.

Two consequences worth being explicit about:

- **ODbL is a data licence, not a code licence.** It is not GPL. Caliper's Swift
  source is never at risk from it, whatever we do with the data.
- **Corrections are deltas, never edits.** `off_corrections` is authored by the
  offline pipeline, ships as its own table, and is applied at query time. If we
  ever publish a derivative database, publishing means exporting that one table
  and nothing else leaks. See ADR-0005.

A user editing an OFF food creates a **fork** into their own `UserFood` record.
The OFF row is untouched, and the fork keeps its attribution.

---

## What ODbL does require: the Produced Work

Any screen that displays OFF-derived nutrition facts is a *Produced Work*, and
ODbL §4.3 requires that it carry notice of the source and licence. Concretely,
in Caliper:

1. **A per-food source badge.** Every food shows where it came from — "Open Food
   Facts", "USDA", or "Yours". Not a settings-screen disclosure; on the food
   itself, at the point of display.
2. **An Attribution & Licences screen**, reachable from Settings, which names
   Open Food Facts, links to <https://openfoodfacts.org>, states that the data is
   made available under the Open Database License (ODbL) 1.0, and links to the
   licence text.
3. **Attribution survives everything.** Export, share, a forked food, a recipe
   built from OFF ingredients — the badge and the notice travel with it.

**OFF data is never presented with the attribution stripped.** This is the one
rule in this document that has a UI consequence on every screen, and it is the
one most likely to be eroded by a redesign that wants a cleaner food row.

USDA data is CC0 and legally needs no attribution. We credit it anyway, in the
same screen, because a per-food source badge that is blank for half the database
tells the user nothing. We do not imply USDA endorsement.

---

## Why this shape also helps elsewhere

Caliper has no accounts and no backend (§2 of the brief). Personal data never
reaches a server we control: logs live on the device and, if the user chooses,
in *their own* CloudKit private database.

- **Guideline 5.1.1(v)** — in-app account deletion — does not apply, because
  there is no account to delete.
- **GDPR surface** is drastically reduced for the same reason.
- **HealthKit data never reaches iCloud at all** (Guideline 5.1.3), enforced by
  the two-store split in ADR-0002.

These are properties to preserve, not conveniences. Adding a backend in v1 would
forfeit all three at once.

---

## Open questions for legal review

1. Whether the per-food badge plus the Attribution screen together satisfy ODbL
   §4.3 notice for a Produced Work, or whether the notice must appear on the same
   screen as the data in every case.
2. Whether shipping `off_corrections` inside the same SQLite file as
   `off_products` — separate tables, joined at query time, never written back —
   is distinguishable from producing a Derivative Database. Our position is that
   it is, because the OFF table is bit-identical to what we ingested and the
   correction table is independently separable. Worth confirming.
3. Whether a user-created recipe whose ingredients reference OFF rows constitutes
   a Produced Work, a Derivative Database, or neither. Our position: a Produced
   Work, since it displays facts rather than redistributing the database.
