# Ascension Honor Tracker

Always shows your Honor and Conquest points, working around the Currency-tab bug
that hides them after a login or relog.

**Version 1.0.0 · Interface 30300 (WotLK 3.3.5 / Ascension)**

## The problem

On Ascension the default Currency tab fails to populate its PvP entries after a
fresh login or relog. Honor and Conquest simply aren't listed — even though the
client still knows the values. They only reappear once you next earn or spend
points, because any honor/arena update forces the currency list to refresh.

## What it does

Instead of trusting the currency *list*, it reads the values straight from the
client APIs (`GetHonorCurrency` / `GetArenaCurrency`), which are correct right
after login. Those are kept fresh by events plus a light poll, and the last known
values are saved per character as a final fallback. If the direct API is ever
missing, it falls back to scanning the currency list by name (it accepts both
Ascension's "Conquest Points" and classic "Arena Points").

- **Currency tab** — a **Show PvP** button is added to the top of the tab. It
  opens a small popup with your live Honor and Conquest totals, and closes when
  you leave the tab.
- **Vendor overlay** — open a vendor that sells honor- or conquest-purchased
  items and your current relevant points appear in the bottom-left of the
  merchant window. Vendors that don't deal in PvP points show nothing.
- **Popup panel** — shift-drag to move; its position is remembered.

## Installing

Copy the `AscensionHonorTracker` folder into your client's `Interface\AddOns`
directory, keeping the folder name.

## Commands

`/aht` (or `/honortracker`)

| Command | Effect |
| --- | --- |
| `/aht` or `/aht toggle` | Toggle the PvP points popup |
| `/aht show` / `/aht hide` | Show or hide the popup |
| `/aht reset` | Reset the popup back to the centre of the screen |
| `/aht status` | Print the current Honor and Conquest totals to chat |
| `/aht debug` | Dump frame geometry — useful for repositioning on a custom UI |

## Saved variables

- `AscensionHonorTrackerDB` — account-wide settings (popup position)
- `AscensionHonorTrackerCharDB` — last known Honor/Conquest per character

## Notes

The currency-tab button and vendor overlay are anchored against Ascension's
custom character/merchant frames, with the stock Blizzard frame names kept as a
fallback for other 3.3.5 cores. If either sits in the wrong place on your UI, run
`/aht debug` with the relevant window open — the offsets are the constants at the
top of `CurrencyTab.lua` and `Vendor.lua`.
