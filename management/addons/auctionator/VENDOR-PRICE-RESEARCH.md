# Ascension vendor pricing — what we know

Why the addon ships a table of observed prices instead of computing them. Findings, not
argument; the tools that produced them are in `tools/` and every number here is re-derivable
by running them against a SavedVariables dump.

Sample behind this: 487 logged sales across two accounts, plus 1349 confirmed price tuples.
**Re-run against a fresh dump 2026-08-19 (see the last section) — no fact below moved, and the
first premise survived a 1349-tuple re-test with zero conflicts.**

## The model

```
vendor price = base price x multiplier
```

`base price` is the item's unscaled sell price, visible from the client cache. The
`multiplier` is a property of the individual item, and it is the part nothing predicts.

Price is a function of `(itemID, itemLevel, requiredLevel)` and nothing else. That tuple is
the addon's key everywhere.

## Established

**The tuple determines the price.** The same `(itemID, ilvl, req)` sells for the same amount
on any character and any account. Zero conflicts across 453 base facts; a seeded price
re-sold on an unrelated account matched to the copper.

**Character level does not affect price.** An item generated at level 39 was sold at level 39
and, after mailing, at level 60 — identical both times, despite the level 60 tooltip showing
an equip effect the level 39 one did not. Nothing else about the seller is recorded to matter.

**Nothing rescales in transit.** Mailing, selling and buying back leave item level and required
level untouched. An item's stats are fixed when it is generated.

**The multiplier is discrete and concentrates hard.** Exactly `1.00x` in 30% of sales and
exactly `2.00x` in another 13% — 45% of all observations sit on one of two values. The
remainder scatter from `1.05x` to `20x` with no visible structure.

**The multiplier cannot be derived.** Not from item class, subclass, quality, slot, or item
level. At item level 65, 55 sales sit at `1.00x` and 32 at `2.00x` — same level, different
items, different multiplier.

**Price never falls below base when the item is at or above its base item level.** 409 of 409
sales, minimum ratio exactly `1.000`. Below its base item level an item can sell for less;
28% do, as low as `0.28x`.

**Growth is a step, not a curve.** Price can hold flat across 35 item levels and then double.
Per-item-level growth rates range from 0% to 13%+ and describe nothing real.

## Ruled out

**Bucketing growth by category.** Class, subclass and slot explain at most ~16% of the scatter
in growth rate. Reconstructing prices from group-median growth scores 33–35% median error —
worse than the estimator already shipping at 30.4%. Quality alone reached 27.2%, a few points,
and that is the flat/doubled structure showing through rather than a quality effect.

**Any smooth curve fit to item level.** Every variant tried stalls between 27% and 35% median
error, because a smooth function cannot fit a step function.

**Quoting a range in the tooltip.** The distribution is right-skewed with a long tail: p95 is
`6.16x` and the maximum `20.29x`. A band covering 72% of cases spans `1x` to `2x`, and quoting
its midpoint scores 42.8% median error — worse than the point estimate it would replace. A
lower bound adds nothing either: the estimator already never predicts below the base floor
(0 violations in 394).

## Consequence

The multiplier has to be observed per item, which is what `obs`, `base` and `trk` collect and
what the shipped seed distributes. The seed is the architecture, not scaffolding around a
formula that has not been found yet. Estimation is the fallback for items never sold, it is
accurate to roughly 30%, and no amount of modelling the available features improves it.

Effort is better spent widening coverage than sharpening the estimator.

## The 2026-08-19 re-run

First dump of the real saved-variables file (`Auctionator-Finder-Ascension.lua`, 1.14 MB).
Both tools were run against it unchanged.

**`diff-vendor-seed`: the premise held.** 1349 obs agree with the shipped seed, **0 disagree**,
**0 contested**, 0 malformed; 453 base facts agree, **0 disagree**. The dump added **88 new real
observations and 65 new base facts** the seed did not have. `seedver` reads `2026-08-16` and
matches the shipped seed, so nothing is a ghost from an older one.

**The learned table is 93% echo.** 1338 of 1437 `obs` entries and 449 of 518 `base` entries are
seed copies written back to disk — about 152 KB of a 1.14 MB file duplicating a table that ships
inside the addon. That is a storage question rather than a research one; it is backlog item 13.

**`analyze-growth`, and this one is a flag, not a finding.** On the 76 usable growth rows in this
dump, rebuilding the price as **flat `price = base price` scored 2.4% median error against the
shipped predictor's 20.3%**. That is *not* a refutation of the 30.4% figure above, which came
from 409 sales across two accounts: 76 rows from one account, heavily weighted to items sold at
or near their base item level, is exactly the sample where flat wins by construction. What it
does say is that the shipped estimator **over-predicts on fresh data**, and that is worth
re-checking the moment the log grows — it is cheap, it is one command, and if it holds on a
wider pool then the estimator should be flooring to base far more often than it does.

## Open

- Is the multiplier fixed per item, or rolled per generated instance? Two instances of one
  itemID at different item levels are the only case that would tell them apart.
- What sets it. `1.00x` and `2.00x` being so dominant suggests a small set of server-side
  brackets, but nothing in the client identifies which bracket an item is in.
- Whether the `1.00x`/`2.00x` spikes hold on a wider item pool. 409 samples, mostly one account.
- Seller level. **`lv` now reaches the dumps** — 96 of the 109 log rows in the 2026-08-19 file
  carry it — but the question is still open for want of the right *shape* of data, not the
  field: **no tuple in that log was sold at two different seller levels**, so there is nothing to
  compare. It stays open until one is, and the single controlled test remains the only evidence.
- Whether flat-at-base beats the shipped estimator on a wider sample — see the re-run above.

## Re-running

```sh
lua5.1 tools/analyze-growth.lua <dump.lua> [more dumps...] [-v]   # multipliers, clustering
lua5.1 tools/diff-vendor-seed.lua <dump.lua>                      # provenance, conflicts
```

A conflict reported by either tool contradicts the first fact above and is worth chasing before
anything else. Run them from the **repo root** — `diff-vendor-seed` resolves the shipped seed by
a path relative to the working directory.

Take the dump from `WTF/Account/<ACCT>/SavedVariables/`**`Auctionator-Finder-Ascension.lua`** and
no other file; a folder that has seen a few installs can also hold stock Auctionator's
`Auctionator_Price_Database.lua`, which is a different addon's data (BACKLOG item 10).
