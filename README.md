# Ascension Custom Addons

Release home for a set of custom World of Warcraft addons built for
[Project Ascension](https://ascension.gg) (WotLK 3.3.5, Interface 30300).

Each folder is a standalone, drop-in addon. Copy the folders you want into your
client's `Interface\AddOns` directory — keeping the folder name exactly as it is
here — and enable them at the character select screen.

| Addon | Version | What it does |
| --- | --- | --- |
| [`!ClientPerfProbe`](./!ClientPerfProbe) | 0.2.0 | Frame-time spike capture with per-addon and per-event attribution, plus a login-cascade load profile. Diagnose stutter before trying to fix it. |
| [`AscensionHonorTracker`](./AscensionHonorTracker) | 1.0.0 | Keeps Honor and Conquest visible, working around the Currency-tab bug that hides them after login or relog. |
| [`Auctionator-Finder-Ascension`](./Auctionator-Finder-Ascension) | 2.9.9 | Auctionator fork with a Finder tab that replaces the disabled `getAll` full scan, handles scaled gear, and adds a Bazaar token/DP/gold converter. |
| [`PasslootBiS`](./PasslootBiS) | 1.0 | PassLoot fork with BisBeard BiS-list import, Ascension-specific rule modules, a loot window, and a roll-advisor API. |
| [`PassLootBiS_Scanner`](./PassLootBiS_Scanner) | 0.1.0-alpha | Live loot-roll upgrade scanner — scores rolled items against your equipped gear using per-spec stat weights read from the item's own tooltip. |

## How they fit together

The two PassLoot addons are designed as a pair: the **Scanner** decides whether a
rolled item is an upgrade, and **PassLoot (BiS)** owns the roll itself. The
Scanner registers as a roll advisor and, depending on the trust mode you pick, its
verdict can be advisory, can hold the auto-roll behind a countdown popup, or can
drive it outright. Either one also runs perfectly well on its own.

The Scanner reads auction values from the **Auctionator** fork when it's present,
to flag items worth rolling on for their gold value rather than their stats. All
three can opt into **Client Perf Probe**'s cooperative CPU meter. Every one of
these links is a guarded optional read — nothing here hard-depends on anything
else.

Two conflicts to know about: don't run `PasslootBiS` alongside stock PassLoot, and
don't run `Auctionator-Finder-Ascension` alongside stock Auctionator.

## Shared constraints

These addons target one specific client, and a few of its quirks shape all of
them:

- **Scaled gear lies.** Link-derived `GetItemInfo` / `GetItemStats` values are
  cached-first and wrong for scaled instances. Anything that needs true stats
  reads them off a rendered tooltip instead.
- **StaticPopups don't render reliably** — they end up behind the Interface
  Options window. Every window in these addons is a plain gameplay-time frame.
- **`scriptProfile` is locked from Lua.** The client resets it to 0 on load, so
  CPU attribution falls back to memory deltas and event rates.
- **`getAll` auction scans are disabled**, hence the Finder's paged sweep.

Wherever practical the pure logic — scoring, parsing, import validation — is
written to load and self-test under bare Lua 5.1 with no WoW API present, and
every client-facing touch is guarded.
