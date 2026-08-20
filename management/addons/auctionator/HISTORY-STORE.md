# A market price history, in a file of its own

**Asked (owner, 2026-08-21):** bring back the original addon's history SavedVariables *companion
file*, make it a **toggleable feature** that populates from scan history, let the rest of the addon
use the longer history where it helps, keep it **off by default**, and keep **the setting itself in
the main saved-variables file** so turning it off never depends on the thing being turned off.

This is the research pass. It is not a build. It exists because the ask reopens a decision already
on the record — `BACKLOG.md` item 8 group C ruled out keeping history for everything, and
`FRAMEWORK.md` §5 repeats that conclusion — and the ask **changes one of the four premises that
decision rested on**. That deserves to be re-scored honestly rather than either waved through or
refused by citing the old note.

**Short version.** The owner's instinct is right about the part that matters most: a separate file
is not cosmetic, it is the only thing that fixes the *worst* failure mode on the list, and it makes
the feature's cost measurable in isolation with a tool this repo already ships. It does not fix the
other three, and one of them — memory shape — has to be decided before the first line of the writer
is written. There is a version of this that fits. It is not the naive one.

---

## 1. What history the addon has today

Four stores look like history. **None of them is a market price series**, and the reasons differ per
store, which is why "just use the existing one" fails four separate ways.

| Store | What it really is | Dated? | Why it cannot answer "what was this worth last week" |
|---|---|---|---|
| `AUCTIONATOR_PRICE_DATABASE` | `[realm_Faction][name] = lowest per-unit buyout` | no | one number, overwritten every scan |
| `AUCTIONATOR_MEAN_PRICE_DATABASE` | `[name] = up to 15 samples` | **no** | `Atr_MeanAppend` sorts by price and evicts at `math.random`; the ordering was never written |
| `AUCTIONATOR_PRICING_HISTORY` | `[name][timetag] = "price:stacksize"` | **yes** | it records **your own postings** — three writers, all `gJustPosted_*` |
| `AUCTIONATOR_AH_VARIANT` | `.obs[itemID:ilvl:req] = { p, t, s }` | **yes** | one entry per variant, replaced each session — a snapshot, not a series |

Two things follow that shape the whole plan.

**The machinery for a dated series is already written and already shipped.**
`Atr_AddHistoricalPrice`, `ToTightTime` / `FromTightTime`, and `Atr_Condense_History` (a working
daily → monthly → yearly compactor) all exist in `Auctionator.lua`. They are pointed at the wrong
input, not missing. Feeding them market prices is *a writer and a retention rule*, not a new
subsystem — the conclusion item 8 group C already reached.

**`AUCTIONATOR_AH_VARIANT` is the closest working model in the codebase and should be copied
rather than re-invented.** It is an account-wide observation store with a per-entry timestamp
(`t`), a live entry count (`.c`) so the cap check costs nothing per write, a hard cap
(`ATR_AHV_CAP = 3000`), a max age (`ATR_AHV_MAXAGE = 30 days`), a prune that drops by age and then
by cap, an enable flag defaulting ON (`Atr_AHVariant_Enabled`), and a documented rule that **age is
shown, never hidden**. Every one of those is something the history store needs. `Atr_AHVariant_Note`
/ `Atr_AHVariant_Prune` in `AuctionatorHints.lua` are the template.

### The cascade already falls back to history — the wrong one

`Atr_GetAuctionPrice` (`AuctionatorHints.lua`) is: **scan DB → `Atr_GetMostRecentSale` → variant
estimate**. That middle step reads `AUCTIONATOR_PRICING_HISTORY`, so when the scan database has
nothing, the addon's answer to "what is this worth" is **what you last listed it at**. That is
self-referential: it prices an item at your own last guess. A real market series is a strictly
better second rung, and slotting it in is a one-line change to a function every price in the addon
already flows through (29 call sites across 6 files). That is the single highest-value read of this
feature and it is nearly free once the store exists.

---

## 2. Re-scoring the four limits, now that the file can be separate

Item 8 group C listed four limits, in the order they would hurt. The companion file changes the
scoring on exactly one — the one that was named "the real reason to scope".

### 2.1 All-or-nothing corruption — **the companion file fixes this, and this was the point**

> "A SavedVariables file truncated by a client crash fails to parse and the client discards **the
> whole file** — the ledger, the vendor learning, the harvested recipes, the watchlist, not just
> the history."

Today all 19 account-wide variables live in one `Auctionator-Finder-Ascension.lua`. A history
large enough to be useful is a history large enough to make that file slower to write and longer
exposed, and the thing it puts at risk is **everything the player cannot re-derive**: the ledger of
real trades, the vendor learning grown over months, the harvested recipe book.

Move the history to its own addon folder and it gets its own file. A truncated write then loses
**the history and nothing else** — and the history is the one store in the addon that is
*re-derivable by simply scanning again*. The blast radius goes from "irreplaceable" to
"regrows on its own".

This is upstream Auctionator's own reason for splitting `Auctionator_Price_Database` and
`Auctionator_Pricing_History` into companion folders, and it is why the owner remembers those files
existing. It is a good instinct and it is the strongest argument in the whole ask.

### 2.2 Parse on load — **not fixed, but made switchable and, for the first time, measurable**

SavedVariables are executed as a Lua chunk at login and at every `/reload`, on the critical path.
Splitting the file does not reduce the total bytes parsed when the feature is on.

What it does do is make the cost **separable and attributable**, and this repo happens to own the
instrument:

> `!ClientPerfProbe/LoadProfile.lua`: "ADDON_LOADED fires ONCE PER ADDON, SERIALLY, and both
> `debugprofilestop()` and `collectgarbage("count")` work. So the DELTA between two consecutive
> ADDON_LOADED marks is the load cost of the addon that just finished loading — in ms (CPU) and KB
> (Lua heap). That is a real per-addon CPU *and* memory channel the engine does not block."

A companion addon gets its own `ADDON_LOADED`, so **`/cpp load` reports the history file's parse
cost as its own line**, in milliseconds and kilobytes, separate from the rest of Auctionator. The
owner's "if client performance ever becomes an issue they can turn it off" stops being a feeling
and becomes a number, before and after, from a tool already installed.

Worth knowing while planning this: **Ascension locks `scriptProfile` and `GetAddOnMemoryUsage` to
zero**, which is why the load profile is the only per-addon channel left — and why
`Atr_GetAuctionatorMemString` (used by `/atr clear`) reports `0 KB` on this server and is not a
usable check.

### 2.3 Memory shape — **unchanged, and it is the decision that must be made first**

> "158,000 samples stored as `{ t = , p = }` is 158,000 Lua tables. It must be flat parallel arrays
> or a packed string per sample, decided before the first line is written — the same call item 13
> made."

A separate file changes nothing here: the heap cost is the same wherever the bytes came from. §5
picks a shape and shows the arithmetic. Getting this wrong is the failure that cannot be fixed
later without a migration, which is exactly the shape of backlog item 13 (which clawed back 384 KB
of "table wrapped around a single number" after the fact).

### 2.4 It is ~99% waste — **unchanged, and it is a scope question, not a container question**

5267 names are in the price database; a player trades perhaps thirty. Storing a series for all 5267
is not a bigger version of the feature, it is a different one. §6 proposes tiers instead of a
single all-or-nothing switch, so "on" does not have to mean "everything".

**Net:** one of four fixed outright, one turned into a measurable and reversible cost, two still
real and both addressed by design choices rather than by the file. The ask is viable. The naive
implementation is still not.

---

## 3. How a companion addon actually works here

Certain, from the 3.3.5 addon model and from this repo's own `.toc` files:

- **One folder = one addon = one `.toc` = one SavedVariables file**, at
  `WTF/Account/<ACCT>/SavedVariables/<FolderName>.lua`. There is no way to split one addon's saved
  variables across two files. **A second folder is not a style choice; it is the only mechanism.**
- **A global may only be declared by one addon.** If the history variable is declared in the
  companion's `.toc`, it must *not* also be in `Auctionator-Finder-Ascension.toc`.
- **The companion needs no Lua at all** — a `.toc` with `## SavedVariables:` and no file list is a
  complete, working store. Upstream's companions were exactly that.
- **Load order** is alphabetical by folder name, adjusted by `## Dependencies` / `## OptionalDeps`.
  `## OptionalDeps: <companion>` on the main addon expresses "load it first if it is there" without
  making it required.
- **Disabling or deleting the companion** leaves the global `nil`. That is the natural hard off
  switch, and the main addon must survive it — which is a guard, not a feature.

**Needs confirming in game before the writer is trusted** (state it as unverified until then): that
Ascension's client honours `## OptionalDeps` for ordering. The design below **does not depend on
it** — every read goes through one accessor that resolves the global lazily on first use, long
after login, the same shape `Atr_An_DB()` already uses. Order then cannot matter, and the
`OptionalDeps` line is belt-and-braces.

### The three states, because there are three and not two

| Setting (main file) | Companion installed | Behaviour |
|---|---|---|
| off (default) | either | nothing is recorded, nothing is read, no cost beyond one flag check |
| on | yes | records and reads |
| **on** | **no** | **records nothing** — and must SAY so, once, where the player will see it |

The third row is the one that will actually happen: someone updates the addon folder and not the
companion. It has to be visible, not silent — the Scanning options row should read *history addon
not installed* and `Fdr_PriceDB_WhyText`'s existing pattern of naming the rule that swallowed a
scan is the model.

---

## 4. Everywhere this touches

### 4.1 Writers — four sites, and they are already the same four

Every place the addon turns a scan into a stored price calls `Atr_MeanAppend`. The history writer
belongs beside it, in the same guards, and there is nowhere else it needs to go:

| Site | Path | Notes |
|---|---|---|
| `Fdr_PriceDB_Update` (`AuctionatorFinderPriceDB.lua`) | Finder category scans | **the main feed on this server** — upstream's getAll full scan is dead here |
| `AtrSearch:Finish` (`AuctionatorScan.lua`) | one searched item | the Buy/Sell path |
| full-scan processing (`AuctionatorScan.lua`) | legacy getAll | dead on Ascension; wire it anyway for correctness |
| Bazaar (`AuctionatorBazaar.lua`) | token prices | |

This is the single most useful finding in the research: **the history feed inherits the price
feed's four correctness rules for free** by sitting inside them —

> 1. NEVER DELETE (a missing name means "not scanned", not "not for sale")
> 2. SKIP SCALED EQUIPMENT (the DB is name-keyed; one price would stand for every scaled variant)
> 3. SKIP A CAPPED SCAN (a truncated slice is biased HIGH)
> 4. BID-ONLY ROWS CONTRIBUTE NOTHING

Rules 3 and 4 matter *more* for a series than for a current price, because a bad sample in a series
is permanent and gets averaged into every later reading, where a bad current price is overwritten
by the next scan. A history writer placed anywhere other than inside these guards would be a
regression dressed as a feature.

The sample to record is **the quantity-weighted median** (`Atr_WeightedMedianPrice`), the same one
the mean database already takes — not the lowest listing. The lowest is one seller's decision; the
weighted median is the book.

### 4.2 Readers — what a series is worth, ranked by value per line of code

| Consumer | What it gains | Cost |
|---|---|---|
| **`Atr_GetAuctionPrice` cascade** (`AuctionatorHints.lua`, 29 call sites / 6 files) | a real second rung in place of "what you last posted at" | one branch |
| **Analysis → Market view** (item 8 group C) | the week-over-week `+240%` column that item was scoped around | one column, one `val` |
| **Item 30, the Advisor** | "ore is up, go mine" — the sentence the whole item was named for, and the one figure it cannot compute today | reads the same call |
| **Item 28, the Call Board** | weekly demand rotation is *the* mechanism; a weekly delta is its signature | reads the same call |
| **Sell tab recommendation** | "you are undercutting a price that has doubled since Tuesday" | one line |
| **Tooltips** (`AuctionatorHints.lua`) | an age-aware price line, the way `AUCTIONATOR_AH_VARIANT` already does | one line |
| **Crafting / Reagents views** | "this reagent is dear *today*" — the difference between a bad recipe and a bad week | reads the cascade |
| **`AUCTIONATOR_MEAN_PRICE_DATABASE`** | a dated, honestly-evicting series makes the random-eviction store redundant — *eventually* | a deletion, later |

That last row is a real prize and a real trap. **Do not touch the mean database in this project.**
It is 5267 rows of live data behind two shipped items (12 part 3b, 13); replacing it is its own
item, after the history has proven itself on a real account.

### 4.3 Infrastructure

- **`.toc`** — the history global moves out; `## OptionalDeps` goes in.
- **A new folder at the repo root.** `management/docs/CLAUDE.md` opens with "Five independent
  addons in one repo" and its per-addon table lists five. The companion is a **sixth folder and it
  is not independent** — it is a satellite that is useless alone. Both the sentence and the table
  need updating, and the install instructions need to say the two folders travel together.
- **`/atr clear`** already has `fullscandb` and `posthistory`; it wants `markethistory`. Note that
  the memory figure it prints around the clear is `0 KB` on this server (§2.2) and should be
  dropped or replaced with the entry count.
- **The dump tooling.** This is the documentation hazard with teeth. `management/addons/auctionator/tools/`
  and `BACKLOG.md` currently instruct, in bold: *"Take the file named after the addon folder, and no
  other"* — a rule written because **backlog item 10 was an entire item lost to dumping stock
  Auctionator's companion files by mistake.** Shipping a companion makes that rule wrong: there
  would then be two legitimate files, one of which has almost the same name as the stock file that
  caused item 10. Whatever else this project does, **it must rewrite that instruction in the same
  commit that creates the folder**, naming the exact two files and the exact stock ones to avoid.
- **Localisation** — any new option label and status text goes through `ZT`/`FT` like the rest.

---

## 5. Storage shape, and the arithmetic that picks it

Blizzard's serialiser writes **one array element per line** with an index comment, so a stored
element costs ~20–30 bytes on disk however small the value is. That per-element overhead, not the
data, is what made the naive design unusable — and it is entirely avoidable.

Assume a **daily** sample (§6 argues why daily is not merely enough but generous).

| Shape | 5267 names × 30 days | Heap objects | Verdict |
|---|---|---|---|
| A. `obs[name][i] = { t = , p = }` | ~5–8 MB | 158,000 **tables** | the shape item 8 C ruled out; do not |
| B. `obs[name][i] = "day:price"` | ~3.2–4.7 MB | 5,267 tables + 158,000 strings | still one line per sample |
| **C. `obs[name] = "d1:p1;d2:p2;…"`** | **~1.8 MB** (measured) | **5,267 strings** | one line per *name*; decode lazily |

**The C row stopped being an estimate on 2026-08-21.** A first real day on the owner's account wrote
647 items in 31 KB, which decomposes as: **23 bytes of item name, 15 bytes of fixed line overhead,
and 9.8 bytes of packed sample**. Only the last of those grows with time, which is the property the
shape was chosen for. Projected from the measured figures:

| | 7 days | 30 days | 90 days |
|---|---|---|---|
| 647 items (one session's scanning) | 71 KB | 228 KB | 636 KB |
| 5267 items (the whole price database) | 578 KB | **1.81 MB** | 5.06 MB |

So the estimate held, and the 30-day whole-market case is confirmed affordable: **1.81 MB in a file
that regrows by scanning**, against a main file of 1.14 MB that cannot. 90 days is the one that is
not, which is what the condenser (stage 5) is for.

Shape **C** — one packed string per item name, the whole series in it — is the recommendation, and
the reasoning is the same one item 13 made about the mean database's single-sample wrapper: the
container costs more than the contents. It kills the per-line overhead **and** collapses 158,000
heap objects into 5,267, and it is the shape `AUCTIONATOR_PRICING_HISTORY` is already halfway to
(`"price:stacksize"` packed per entry).

Decode only what is asked for: a week-over-week column needs two numbers out of one string, and
nothing needs the whole table expanded at once. Cache the decode per name per session.

Two details that pay for themselves:

- **Store a day index, not a timestamp.** `ToTightTime` packs *minutes* since 2008-08-01 — ~9.5
  million today, 7 digits per sample. Days since the same epoch is ~6,580, four digits, and a daily
  series has no use for the other three. Better still, store a base day once per string and
  deltas after it (1–2 digits each).
- **Reuse `Atr_Condense_History`'s idea, not necessarily its code.** It already ages entries
  daily → monthly → yearly. A history that condenses beyond ~30 days keeps a year of shape for
  roughly the size of a month of detail.

---

## 6. Retention, and why "on" should not mean "everything"

The owner asked for one toggle. The research says the honest version is **one toggle with a scope**,
because the difference between the tiers is two orders of magnitude and the top tier is the one
that would make someone turn the feature off.

| Tier | Scope | 30 days, shape C | Answers |
|---|---|---|---|
| 1 | watchlist only (~20–50 names) | ~15–25 KB | item 8 C, item 28, item 30's ore card |
| 2 | + everything you have traded (the ledger's names) | ~40–80 KB | the above, plus your own inventory |
| **3** | **every name a scan has priced (~5267)** | **~1.5–1.8 MB** | the above, plus any item you look up cold |
| 4 | tier 3 at 90 days | ~4.5–5.4 MB | nothing tier 3 does not, for 3× the file |

Tier 3 is the owner's ask read literally, and at shape C it is **defensible** — it roughly doubles
today's 1.14 MB total, in a file that can be deleted without losing anything irreplaceable, behind
a switch that is off unless asked for. Tier 4 is not, and the condenser is what makes it
unnecessary: 90 days of *shape* costs almost nothing once the first 30 are the only ones kept daily.

**One sample a day, at most.** The demand driver the owner described — Call Board quests rotating
weekly — has a seven-day period. Item 8 group C settled this already: what that needs is "vs seven
days ago", **a delta and not a trend line**, and no chart. Daily sampling is generous against a
weekly signal, and it is also the natural de-duplication rule: scan an item nine times in an
evening and it writes once.

Suggested default if the feature is switched on: **tier 1**, with tier 3 available. The player who
turns it on wants their watchlist to grow a memory; the player who wants the whole market can say
so, and now has a number telling them what it costs.

---

## 7. Risks, in the order they would actually bite

1. **The two-dump documentation hazard (§4.3).** Item 10 already burned one whole backlog item on
   file confusion, and this project manufactures the same confusion deliberately. Mitigation is
   documentation written *in the same commit*, not after.
2. **A stale series presented as current.** An auction price rots; a vendor price does not. The
   `AUCTIONATOR_AH_VARIANT` rule — *age is shown, never hidden*, printed past a day, dropped past a
   month — is the standard to hold every reader to. A week-over-week figure computed against a
   sample from three weeks ago must say so or not print.
3. **Sampling bias from the feed.** Scans are user-driven and irregular. A "daily close" that is
   really "whenever they happened to look" is a floor on the truth, not the truth, and the same
   honesty the Analysis tab already applies to Sold/day applies here. Store the sample count per
   day alongside, so a reader can tell one observation from ten.
4. **Writing on the scan path.** The feed already runs inside a loop over every row of a scan. The
   history writer must be O(1) per name per scan (one string append, one cap check by count — the
   `.c` trick from `AUCTIONATOR_AH_VARIANT`), never a re-serialise of the whole series per row.
5. **The repo convention change (§4.3).** Worth an explicit yes from the owner before a folder
   appears at the root, because it changes what "download one folder and drop it in" means for
   this addon.
6. **Migration has no rollback.** Once the history variable is declared by the companion, an
   install without the companion loses whatever was in it. Since the store is re-derivable by
   scanning, this is survivable — but it is the reason the store must hold *only* re-derivable
   data. **Nothing else may ever move into that file.**

---

## 8. A staged plan, each stage worth shipping alone

**Stage 0 — one measurement, before any of it (recommended first).**
`/cpp load` on the current install, saved with `/cpp save`. It gives the before-figure for the
addon's own load cost in ms and KB. Every later argument about whether the feature is affordable is
guesswork without it, and it costs one command.

**Stage 1 — the store, the toggle, and the writer. No readers. — BUILT 2026-08-21, see §11.**
The companion folder and its `.toc`; the lazy accessor that tolerates the companion being absent;
shape C encode/decode with the cap and the age prune modelled on `Atr_AHVariant_Prune`; the writer
beside `Atr_MeanAppend` at all four sites, inside the existing guards; the setting in
`AUCTIONATOR_FINDER_SETTINGS` (off by default) with a row on the Scanning options panel beside
`feedPriceDB` and an `/atrhistory on|off` fallback, exactly the pattern `feedPriceDB` already
follows. Ships dark: it records and nothing reads it. **That is deliberate** — a week of ordinary
play then produces real data, and stage 2's readers can be built against something instead of
against an empty table.

**Stage 2 — the cheapest, highest-value read: the cascade. — BUILT 2026-08-21, see §12.**
`Atr_GetAuctionPrice` gains a history rung above `Atr_GetMostRecentSale`. One branch, and every
price in the addon improves at once.

**Stage 3 — the week-over-week column** (this *is* item 8 group C, and it closes it).
**— BUILT 2026-08-21, see §12.**
One column on the Analysis tab's Market view: `+240%`, no chart, nil when the comparison sample is
too old to be honest.

**Stage 4 — the readers that were waiting for it. — BUILT 2026-08-21 (the two that could be), see
§13.** Item 30's ore card and item 28's demand signal want items that do not exist yet; the Sell
tab's warning and the age-aware tooltip line did not, and shipped.

**Stage 5 — retention polish.** The condenser, and only then the question of whether the mean
database still earns its 5267 rows.

---

## 11. Stage 1 as built, 2026-08-21 — and confirmed in game the same day

**It works.** First real run on the owner's account: 647 items recorded from one session's
scanning, all on day 6593 (2008-08-01 + 6593 days = 2026-08-20 — the epoch arithmetic is right),
24 of them closed more than once and carrying the `:2` / `:3` scan counts, `n = 647` in step with
the entry count, and the whole thing in
`WTF/Account/<ACCT>/SavedVariables/Auctionator-Finder-Ascension-History.lua` — its own file, which
was the entire premise. `/atrhistory show` round-tripped a series back out of the packed string
through the real client, not a stub.

**One defect, found and fixed by that run.** The copy box printed `58  00` where it meant 58 gold:
`zc.priceToMoneyString` renders coins as TEXTURES, and a texture copies out of an EditBox as
nothing. Every money formatter in this addon has that property, and it is invisible until someone
pastes. The diagnostic now formats plain `58g 00s 00c` text with the raw copper beside it — a copy
box whose text does not survive being copied has not delivered anything.

**The baseline load figure, from `/cpp load` on the same session:**
`Auctionator-Finder-Ascension` costs **96.2 ms and 1052 KB** at login, rank 7 of 27 addons, against
a 3683 ms total login and a top entry (Details) of 1724.5 ms. That reading was taken while the
history file was still empty — SavedVariables are written at logout, so a login profile always
reflects the *previous* session's file — which makes it exactly the before-figure. The comparison
worth taking next is the same command after a login with a full file in place; the companion should
appear as a line of its own, which is the per-addon attribution the separate file was supposed to
buy.

The capture also independently confirms a research finding: `GetAddOnMemoryUsage` reports
`st=zero` on this server, so `/atr clear`'s memory line is indeed useless here and the load profile
is the only per-addon channel.

Files:

- **`Auctionator-Finder-Ascension-History/`** — the companion. A `.toc` declaring
  `AUCTIONATOR_MARKET_HISTORY` and one line of Lua setting
  `AUCTIONATOR_MARKET_HISTORY_LOADED = true`. The Lua line is there for two reasons: a `.toc` with
  no files at all would *probably* load, and "probably" is not worth betting the feature on; and the
  marker is how the parent tells *"companion installed"* from *"installed, nothing recorded yet"*.
  **SavedVariables load before an addon's own files run**, so if the marker is set the saved table
  is already in place — which is what lets the parent resolve everything lazily and ignore load
  order. `## OptionalDeps` asks for it first as well; nothing depends on that being honoured.
- **`Auctionator-Finder-Ascension/AuctionatorHistory.lua`** — everything that reads or writes it.
  The companion holds no logic at all.

**The shape, as shipped.** `realms[realm_Faction].p[name] = "day:price[:scans];…"` — one packed
string per item name, keyed per realm and faction exactly like the price database, because a series
that mixed realms would be noise. `day` is days since 2008-08-01 (four digits; `ToTightTime` packs
*minutes* since the same epoch, and a daily series has no use for the other three). `price` is the
**quantity-weighted median** of the scan — the same sample the mean database takes, not the lowest
listing. `scans` is omitted at 1 and present above it, so a reader can tell one observation from
ten; without it "daily close" quietly means "whenever they happened to look".

**Appending is O(1) per name per scan**, which is the constraint that shaped the code: the writer
runs inside a loop over every row of a scan. Today's record is either the last one in the string or
absent, so the common path is one `match` on the tail and one concatenation. A full decode happens
only when a string outgrows `ATR_HIST_TRIM_AT`, which is **at most once per name per month** — and
that is why retention is a window rather than an exact edge: a name carries between 30 days and
roughly 55 before being cut back. The overshoot is a few hundred bytes and it buys a decode per
month instead of a decode per scan.

**Nothing walks the table at login**, which matters because a login-time sweep is exactly the cost
this feature is trying not to add. Trimming on write bounds a name that is still being scanned; a
name that stops being scanned freezes under the per-name cap. Total is bounded by names × cap
without ever traversing it.

**The four writers are the four `Atr_MeanAppend` sites** — `Fdr_PriceDB_Update`, `AtrSearch:Finish`,
the (dead on this server) getAll full scan, and the Bazaar bridge — each *inside* the existing
guards, so the history inherits the four rules that make a partial scan safe to store. The Bazaar
one is arguable and the comment at the site says so: a token price is administered rather than a
market, but the series has to be the history *of the price this addon reports*, and stage 5 cannot
compare the series against the mean database if the two are fed from different populations.

**Off by default**, `AUCTIONATOR_FINDER_SETTINGS.marketHistory == true` — note the idiom is the
**opposite** of `feedPriceDB`'s `~= false` two lines away, and copying that one here would turn the
feature on for everybody. The setting lives in the main file, per the owner's requirement: being
able to turn this off must never depend on the thing being turned off. A row sits on the Scanning
options panel under the other three; **when the companion is missing the row disables itself and
says `(history addon not installed)`** rather than offering a checkbox that does nothing — the third
state from §3, which is the one that will actually happen.

**`/atrhistory`** — `on` / `off` / `clear`, a bare call for the status line, and `show <item>`,
which prints the decoded series into the **copy box**, not chat. That diagnostic is the exception
CLAUDE.md's rule allows for, and the justification is specific: stage 1 ships with no reader, so
without it there is no way to know the store is recording until stage 2 is built on top of it.

**Tested:** `management/addons/auctionator/tools/history-store-smoke.lua`, 50 assertions, all
passing. It exists against the house rule for two stated reasons — the append path is string surgery
with index arithmetic, and a bad append is *silent and permanent* where a bad current price is
overwritten by the next scan. It pins the off-by-default path, the missing-companion path, the
same-day close, the next-day append, the refusal of a backwards clock, retention, the per-realm
split, and that an unreadable record is dropped rather than guessed at.

**What is deliberately not here:** no reader. `Atr_Hist_Series` exists and nothing in the addon
calls it. That is stage 2's seam, and leaving it dark is what lets a week of ordinary play produce
real data for the readers to be built against.

---

## 12. Stages 2 and 3 as built, 2026-08-21

Built back to back on the owner's call to keep moving rather than verify each step
(*"assume it's going to work... continue as if nothing will go wrong for efficiency"*), which is
the repo's own standing rule applied deliberately. Offline checks pass; **not seen in game**.

### Stage 2 — the cascade rung

`Atr_GetAuctionPrice` becomes: scan database → **`Atr_Hist_Recent`** → `Atr_GetMostRecentSale` →
`Atr_GetAHVariantEstimate`.

The rung it was inserted above is the point. `Atr_GetMostRecentSale` reads
`AUCTIONATOR_PRICING_HISTORY`, which is **what you listed things at** — so when the scan database
had nothing, this function's answer was *your own last guess, priced back to you as evidence*. That
is not a small thing to fix: 29 call sites across 6 files go through this function, so every price
the addon shows for an unscanned item improves at once.

`Atr_Hist_Recent` reads only the tail of the packed string — a table lookup and one match — and it
runs only on the path where the scan database already missed. **No age filter**, deliberately: the
store's own month of retention *is* the filter, and the rung below it has no age bound at all, so a
three-week-old market reading is strictly better than an unbounded guess. The age comes back as a
second return for callers that want to say how old it is.

### Stage 3 — the Week column, which closes item 8's group C

One column on the Analysis tab's Market view reading `+240%`. **No chart** — group C settled that:
the demand driver rotates weekly, so what is wanted is "vs seven days ago", not a curve.

- **`Atr_Hist_Delta`** picks the **newest sample at or before seven days back** — "what it was a
  week ago", not "the oldest thing I have". Until a week has been recorded that sample does not
  exist, so it falls back to the oldest reading it does have **and returns the real span with it**,
  and the hover says *"4 days ago"* rather than quietly calling four days a week. Under three days
  it returns nothing: two readings a day apart is noise.
- **Up is green**, which is this view's reading — the column two along is Gold/day and the question
  the table answers is what is worth going and getting. The hover states both prices and both dates
  so the buyer's half of the story is one glance away.
- **A stale newer end is dimmed, not hidden.** It is still the last thing the market did, and
  hiding it would say "no movement" about an item nobody has scanned lately — a claim about the
  player, not the market.
- **Widths paid for it the same way the Reagents view paid for Outlay**: Item 184→176, Group 74→60,
  Sellers 48→44, Listings 54→48, Sold/day 80→74, Low 84→78, Gold/day 96→88. Eight columns is 684 of
  the 702px row, clearing it by 18.
- The delta is computed **once per row per rebuild** and cached on the record beside `st`, because
  the sort calls a column's `val` for every row and the draw calls it again for every visible one —
  and this one decodes a string.

**A superseded decision, worth naming.** Group C's plan was to store the series as a capped daily
`{ t, low }` **on each watched item's `obs` record**. Item 31 replaced that: the series is general,
so the column reads the same store every other consumer does and the watchlist is no longer the
unit of retention. One store, one shape — which is the whole of §10's argument arriving early.

**Tested:** the smoke test grew to 66 assertions, covering which sample "a week ago" resolves to,
the short-history fallback and its reported span, the three-day floor, the staleness age, and the
cascade read. That off-by-one is the kind nothing in game would ever show you — the number would
simply be wrong.

---

## 13. Stage 4 as built, 2026-08-21 — the readers, minus two that had nothing to read from

**Two of the four listed readers were not buildable and are not built.** Item 30's ore card and
item 28's demand signal are features of items that do not exist yet — there is no Advisor tab and no
Call Board capture to put a line on. Nothing about them is blocked on the history any more, which is
the point: when either gets built, its figure is one call away. The other two shipped.

**Four surfaces now print this figure, so there is one function that phrases it.**
`Atr_Hist_PctText` rounds and clamps; `Atr_Hist_MoveText` adds the span. Four sites rounding a
percentage their own way is four chances to describe one number two ways, which is the duplication
FRAMEWORK.md §6 warns about for prices and is no different here. The Analysis column was rewritten
to go through it rather than keep its own copy.

### The item tooltip — everywhere an item is drawn

A fifth money line under Vendor / Auction / Auction median / Disenchant, reading
`Auction 7d ago    12s  +240%`. It carries the old **price** as well as the move, because the other
four lines are all money and a bare percentage in that stack reads as a different kind of thing.

It **does not compete for the best-price highlight**. That highlight answers "what is this worth to
me", and a week-old figure is not an offer.

The label states the real span — `7d ago`, `4d ago` — never the word "week", for the same reason the
Analysis column does: until a week has been recorded it is not one.

This also covers the Sell tab's item hover for free, since that hover is `SetHyperlink` on the same
tooltip.

### The Sell tab's sentence

One line on the drop-box hover, and the direction that matters is the one the flow makes dangerous.
Auctionator's sell flow is *undercut the current lowest*, and the lowest listing is one seller's
decision — so the case worth a warning is not a dear market, it is a **fallen** one: undercutting a
crash prices you into it. The rise is reported too, shorter, because it is reassurance rather than a
decision.

Three gates, each for its own reason: **SELL tab only** (the same hover serves BUY, where
"undercutting it" is not what you are doing), **±15% or nothing** (a few percent is the noise a
daily close carries, and a tooltip that comments on noise teaches you to ignore it), and **nothing
when the newer end is stale** — "the market has fallen" would then be a claim about a market nobody
has looked at.

`Atr_ShowRecTooltip` is re-run **every frame** while that tooltip is up. That is why
`Atr_Hist_Delta` now memoises per name per day: a decode allocates a table per sample, so uncached
this would be thousands of short-lived tables a second for a number that changes once a day. The
cache entry is dropped whenever that name is written, and the stored day makes a day roll drop it by
itself.

### The Crafting and Reagents side tooltips

One line each, and they answer the same question from opposite ends. On a **craft row**: a recipe
that pays today because its product spiked is a different proposition from one that pays every week,
and Profit/craft cannot tell them apart. On a **reagent row**: is this dear *today* — the difference
between a bad recipe and a bad week. Neither could be a column; the Reagents view has no width left
for a ninth and it was never a table's job to say it.

### One bug, caught by re-reading rather than by running

The sell sentence used `txt:gsub("^%-", "")` inline as a `string.format` argument. **`gsub` returns
two values** — the string and a replacement count — and an unparenthesised call passes both, so the
count landed in the `%d` and every sentence would have read *"on 1 days ago"*. Parenthesised, and
pinned by an assertion that checks the span survives, because the test that was there passed happily
without it.

**Tested:** the smoke test is now **84 assertions**. The new ones cover the cache dropping on a
same-day re-close and on a new day's write, the shared formatter's rounding and clamping in both
directions, that the move text always carries the real span, and each gate on the sell sentence —
the fall, the rise, the noise floor and the staleness floor.

---

## 9. Answered by the owner, 2026-08-21

1. **A sixth folder and a companion addon: yes**, both approved.
2. **"If this works out we may make it core instead of toggleable — it may be more efficient and
   less cumbersome than the existing structure."** Recorded as the *direction*, not as this
   project's shape. §10 is what that sentence turns into once it is taken seriously.
3. **On measurement: "we can use the CPP addon for diagnosis, but the real test will be
   implementation of some sort."** Agreed, and it matches the repo's own standing rule — ship the
   change, verify it later, tooling is a fallback and not a frontline. Stage 0 demotes from a phase
   to a **ten-second habit**: take one `/cpp load` reading *before* the companion folder exists,
   because that is the only moment the before-figure can be captured. Everything after that is
   measured by having built it.

**Still open, and both smaller than they were:**

- **The companion folder's name.** It must not collide with stock Auctionator's
  `Auctionator_Pricing_History`, which is exactly the file item 10 was lost to. Suggested:
  `Auctionator-Finder-Ascension-History` — ugly, unmistakable, and sorts next to its parent.
- **The default scope** (§6) — and §10 argues the "core" direction answers it by implication.

---

## 10. If it goes core — what that sentence is actually worth

The owner's instinct is that this could be *less cumbersome than the existing structure*. Taken
seriously, that is a stronger claim than it first sounds, and it is worth writing down before the
writer's shape is chosen, because it changes what a good v1 looks like.

**A dated series subsumes both of the current price stores.** Today two variables answer "what is
this worth": `AUCTIONATOR_PRICE_DATABASE` (one current number per name) and
`AUCTIONATOR_MEAN_PRICE_DATABASE` (up to 15 samples, price-sorted, evicted at random, undated). The
second is a *broken attempt at exactly the question a history answers* — it wants to say "what is
this normally worth" and cannot, because it discarded the dates and thins itself at random. Against
a real series:

- **current price** = the newest sample
- **typical price** = the median of the last N days, which is what the mean database was reaching
  for and cannot deliver
- **"is this dear today"** = the thing neither store can express at all

So the end state is not "three stores instead of two". It is **one store, one shape, honest
eviction, and a deletion** — and the deletion is 5267 rows out of the current file. A history at 30
days daily, condensed beyond, is plausibly **net-neutral or smaller on disk than what it replaces**.
That is the real form of the owner's "more efficient", and it is a better argument for building this
than "it unblocks three backlog items".

**Two consequences for how to build it, and they point the same way:**

- **Core and watchlist-only are incoherent together.** A feature that is always on but only
  remembers the thirty items you happened to tick is a half-thing no reader can rely on — every
  consumer would need an "unless it is not watched" branch. If the destination is core, the default
  scope is **every name a scan has priced** (tier 3, ~1.5–1.8 MB at shape C) and retention does the
  bounding rather than a watchlist filter. That settles §6 by implication.
- **The cascade read (stage 2) stops being optional.** A price store the price function does not
  read is a side-car, not a replacement — and reading it is one branch.

**Where the sequencing should NOT change, and this is the one push-back in the document.** Build it
toggleable and off by default anyway, exactly as staged. Not as hedging — as the thing that makes
stage 1 shippable at all:

- A core store means **migrating live data on a real account** (5267 rows, the mean database, and a
  cascade every price in the addon flows through) on a client that cannot be run or tested here. A
  toggle means stage 1 changes *nothing* for anyone who does not switch it on.
- **Removing a flag later is deleting a branch. Adding one later is shipping a fix under pressure.**
  The asymmetry is entirely one-sided, and the flag costs one boolean check per scan row.
- The core step is then small and evidence-led: a migration, a deletion and a default flip, taken
  **after** a month of real data has shown what the file actually weighs and whether a
  median-over-N-days reads better than the mean database it would replace. Same shape as item 12
  part 3b and item 13 — measure on the owner's own dump, then decide.

**Verdict.** Right destination, and it is the strongest argument yet for building this at all.
Wrong starting point. Ship it dark and switchable, let it fill, then take the core step with the
file sitting in front of you.
