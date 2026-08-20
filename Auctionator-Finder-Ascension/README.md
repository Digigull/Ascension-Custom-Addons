# Auctionator — Finder (Ascension)

A fork of Auctionator for Ascension, built around a new **Finder** tab that
replaces the scanning features the server disables.

**Version 2.9.9 · Interface 30300 (WotLK 3.3.5 / Ascension)**
Original Auctionator by Zirco.

> Do not run this alongside stock Auctionator — same globals, same saved
> variables.

## Why the fork

Upstream Auctionator leans on `QueryAuctionItems(..., getAll=true)` for its Full
Scan, and Ascension disables that. It also assumes an item link tells you an
item's stats, which isn't true here: gear is scaled per instance, so two auctions
of the "same" item are different items. Most of what this fork adds follows from
those two facts.

## What it adds

### Finder tab

A Blizzard-style item search that pages through every result with ordinary
queries (so it works with `getAll` disabled), then displays them with
client-side sortable columns.

- **Grouping** — identical non-equippable items are consolidated into one row
  (total quantity, listing count, cheapest price). Weapons and armour stay as
  individual rows, because their stats genuinely differ.
- **iLvl column** for equippable items.
- **Stat column** — a dropdown lists every stat present on gear in the current
  results; pick one and you get a sortable column for it. Columns reflow when it
  appears or disappears.
- **Buy-tab redirect** — searching for gear from the stock Buy tab bounces you to
  the Finder, which handles scaled gear correctly.

### Full-scan replacement

The **Scan Categories** button runs a sequential, per-category paged sweep in
place of the dead `getAll` scan.

### Price database feed

Ordinary Finder category scans feed Auctionator's own name-keyed price and mean
databases, so the tooltip price lines keep working without a full scan.
`/atrprices` inspects the feed.

### Bazaar tab

Ascension sells goods for Bazaar Tokens, which are obtainable with real money via
DP on the webshop *or* with gold off the auction house (they're ordinary item
975001). That makes one chain with four currencies:

```
USD --bundle--> DP --shop rate--> BT --auction house--> gold
```

Every edge is a player-visible, changeable number, so all three are user-editable
and persisted. Everything is reduced to copper internally, since that's the only
exact integer axis the AH gives us.

### Ledger tab

A transaction record that fills itself in: what you bought, what you listed,
what sold, what expired and what the mail brought back. It reads the auction
house's own confirmations and your mail, so nothing has to be entered by hand.

### Analysis tab

Three views over one table, switched by the toggle at the top right.

- **Market** — a watchlist, and what scanning has learned about it. Every
  listing is fingerprinted by seller, stack and price, so a listing that has
  *vanished* between two scans can be counted: how many sellers an item has,
  how fast its listings disappear, and what that is worth per day. `timeLeft`
  separates a sale from an expiry, which is what makes it an estimate rather
  than a guess — and the tab says so, in the numbers' own tooltips.
- **My trades** — the same items out of the Ledger: paid, got, margin and
  sell-through. The only numbers on the tab that are not estimates.
- **Crafting** — every recipe your professions have harvested, ranked by what
  one craft is worth at today's prices. It is the profession window's own
  profit sort, available at the auction house where the decision actually gets
  made. Hovering a row shows the reagents and their prices beside the item's
  tooltip.

Every column sorts (click a header, click again to reverse) and the filter box
narrows all three views as you type. On any row: hover for the item's tooltip,
left click to look it up — gear on the Finder tab, everything else on Buy —
and right click to add it to a shopping list or an Analysis group.

### Profession scanning

The 3.3.5 client can't be asked "what reagents craft item X" — that data is only
reachable while a profession window is open. So recipes are harvested into an
account-wide database from two sources: profession windows (reliable, keyed by
produced item ID) and recipe item tooltips (keyed by created item name, for
recipes you haven't learned). This feeds the Sell tab's crafted-goods margin
filter.

### Vendor and merchant learning

NPC trade-good prices and Bazaar token prices are learned from vendors you open.
A bundled seed table (774 observations, 344 base facts, harvested from confirmed
buyback sales) primes a fresh install so it isn't useless on day one.

### Item quantity on tooltips

A **Qty** line on item tooltips showing how many you own, and — with a modifier
held — where: which character, bags versus bank, plus account-wide web-shop bank
totals. Because the client can only read a container while its window is open,
this is a remembered cache rather than a live count.

### Scan throttling

Opening a vendor or profession window makes the client fire `MERCHANT_UPDATE` /
`TRADE_SKILL_UPDATE` in a burst, one per row whose data is still cold. The old
harvesters re-walked the entire list on every one of those, which is what made
opening a big vendor stutter. Now there's one shared event frame that debounces
the storm into a single pass, plus a session-scoped ledger keyed on a fingerprint
of the list, so re-opening a vendor already seen this session costs a string
compare instead of a full walk. The ledger resets on `/reload` — vendor stock
doesn't drift within a session, but a fresh login re-learns everything once.

## Installing

Copy the `Auctionator-Finder-Ascension` folder into `Interface\AddOns`, keeping
the folder name.

## Commands

`/atr` (or `/auctionator`) for the stock commands, plus:

| Command | Effect |
| --- | --- |
| `/atrprices` | Inspect the Finder's price-database feed |
| `/atrahdb` | Auction-house variant database inspector |
| `/atrgear` | Jump to gear handling |
| `/atrvp` | Vendor price prediction |
| `/atrprofsort` | Profession/recipe sort |
| `/atranalysis` | Analysis tab: watch an item, make a group, switch view, diagnostics |
| `/atrledger` | Ledger summary (`/atrledger 7` for the last 7 days, `clear` to empty it) |
| `/atrart` | Artwork/texture debug |

## Saved variables

Account-wide: price and mean databases, shopping lists, scan times, stacking
preferences, crafted recipes, NPC prices, learned vendor facts, Bazaar rates,
item locations, the ledger and the analysis watchlist. Per character: the
tooltip and UI preferences. See the `.toc` for the full list.

## Notes

`AuctionatorVendorSeed.lua` is generated — don't hand-edit it. The `.toc` also
lists `Locales\svSE.lua`, which isn't shipped in this repo; the client skips a
missing file, so Swedish just falls back, but the line can be dropped if you want
the manifest clean.
