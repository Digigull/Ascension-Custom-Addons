# ExadMinimap

The minimap skin and the minimap-button collector from **ExadTweaks**, pulled out
into a standalone addon. Nothing else from the package comes with it.

Install it the same way as any addon — drop the `ExadMinimap` folder into
`Interface/AddOns/` — and disable or remove `ExadTweaks` if you only want this.
The two do not need each other, and running both at once means two addons
fighting over the same minimap.

---

## Why extract it

ExadTweaks' unit-frame, aura, and keypress modules manipulate **secure** Blizzard
frames (`TargetFrameToT`, `ActionButton*`, and friends). Once those are tainted,
Blizzard's own in-combat calls on them get refused, which is the

```
AddOn 'ExadTweaks' prevented the call of the secure function 'X:Show()'
```

flood. See `COMBAT_TAINT.md` in the repo root for the full picture, including the
issues still outstanding in the full package.

The minimap module was audited clean and stays clean here: **ExadMinimap never
touches a secure frame.** Minimap widgets (`Minimap`, `MinimapCluster`,
`GameTimeFrame`, `MiniMapTracking`, …) are not protected, and the collected
buttons belong to other addons, not to Blizzard. There is no code path in this
addon that can produce a blocked-secure-function message.

---

## What you get

**Square minimap skin**

- Square mask at 175px with a thin dark border
- Blizzard's border, zoom buttons, north tag, and world-map button removed
- Mousewheel zoom in their place; right-click opens the tracking menu
- A zone/clock bar under the minimap — clock on the left, zone on the right;
  clicking the zone text toggles the minimap
- Calendar, tracking, mail, LFG eye, battlefield and instance-difficulty icons
  retextured and moved off the minimap face
- Ping snitch: the zone text briefly shows who pinged, in their class colour

**Button collector**

- Every addon minimap button is gathered into a hidden grid under the zone bar
- The small icon at the right of the zone bar shows and hides the grid; it fades
  out after 45 seconds but stays clickable, and hovering brings it back
- Buttons that never registered with LibDBIcon are found by walking the
  minimap's own children, so they are collected without being named first
- Anything even that cannot reach is added by clicking it, or by name
- BugSack is special-cased: if it goes red it hops back onto the minimap so you
  can see there is an error waiting

**Options panel**

Interface > AddOns > ExadMinimap, or `/exadmm config`. Two pages:

- **ExadMinimap** — the skin, the collector, minimap size, grid spacing and the
  fade delay. Options marked `*` need a UI reload; there is a Reload UI button
  on both pages.
- **Buttons** — every button the collector can see, with its own icon, listed
  in the order the grid lays them out. Hover a row to outline the real button on
  screen. Uncheck one to leave it where its own addon put it instead of pulling
  it into the grid; the button goes back to its original spot straight away, no
  reload needed.

---

## Ordering the grid

Click a row on the Buttons page to select it, then **Move up** / **Move down**
to shift that button a place at a time. The list is in grid order — the grid
fills left to right, so the top row of the list is the top-left button — and it
relays as you go, whether or not the grid is open. **Sort A-Z** forgets the
custom order and goes back to sorting by frame name.

The order is saved by frame name, so it survives a reload, and a button whose
addon is switched off keeps its slot for when it comes back. A button from an
addon installed *after* you last reordered sorts to the end rather than pushing
into the middle of an order you set. `/exadmm order` prints the current order,
and `/exadmm order reset` is the same as Sort A-Z.

---

## Adding a button the collector missed

Three ways, in the order worth trying:

1. **Add by clicking** (Buttons page). The screen takes the next click instead
   of the button underneath it, so nothing is triggered by accident: the button
   under your cursor is outlined and named as you move, left-click adds it,
   right-click or any key backs out. `/exadmm pick` starts the same thing
   without opening the options.
2. **By name.** Type the frame name into the box on the Buttons page and press
   Add name. `/exadmm name` prints the name of whatever is under your cursor,
   and `/exadmm add <FrameName>` does the same job from chat.
3. **`/framestack`.** Last resort for a button that is drawn by a frame you
   cannot pick — type `/framestack`, hover the button, read the frame name off
   the list, and feed it to either of the above. `/framestack` again turns it
   off.

`PLBiSScannerMinimapButton` and `PasslootBiS_MinimapButton` are tracked out of
the box.

---

## Commands

```
/exadmm config            open the options panel
/exadmm pick              click a minimap button to add it
/exadmm toggle            show/hide the collected buttons (same as the icon)
/exadmm scan              look for newly created minimap buttons
/exadmm square            square minimap skin on/off       (needs /reload)
/exadmm buttons           button collector on/off          (needs /reload)
/exadmm skin              button border skinning on/off    (needs /reload)
/exadmm wheel             mousewheel zoom on/off           (needs /reload)
/exadmm detect            automatic button detection on/off
/exadmm add <FrameName>   track a button the scan cannot reach
/exadmm remove <FrameName>
/exadmm ignore <FrameName>  leave a button on the minimap
/exadmm order             print the grid order (order reset = back to A-Z)
/exadmm list              current settings and tracked buttons
/exadmm name              print the frame name under your cursor
```

Settings are saved per character in `ExadMinimapDB`.

---

## Differences from the ExadTweaks original

The behaviour is the same; three things were repaired on the way out.

1. **The button scan no longer walks all of `_G` on every click.** ExadTweaks
   rebuilt its button list by iterating every global, wrapping each one in its
   own closure and `pcall`, on every show *and* every hide — tens of thousands
   of protected calls per click on a loaded client. ExadMinimap asks the
   LibDBIcon registry directly, matches the `_G` fallback on the global's *name*
   instead of calling a method on every value, and caches the result until an
   `ADDON_LOADED` says a new button might exist. Measured against the original
   over 40k globals: ~3.4x faster cold, and free once the cache is warm.

2. **Button order is stable.** The old grid was laid out in `pairs()` order, so
   buttons shuffled between sessions. They are now sorted by name. The old
   duplicate filter also only compared against the immediately previous button;
   it now tracks every button it has seen.

3. **Button skinning actually works — and is off by default.** The original read
   the button's regions positionally after `local ok, regions = pcall(...)`,
   which keeps only the *first* return value, so the indices it read were always
   `nil` and the skin silently did nothing. Regions are now identified by what
   they are (the ring is the texture still set to Blizzard's tracking border, the
   icon is the ARTWORK-layer texture) rather than by position. Because that code
   never actually ran for you, it defaults to **off** so the addon looks exactly
   like what you have now — `/exadmm skin` turns it on.

4. **Buttons are found, not named.** The original only knew about LibDBIcon
   buttons plus a hardcoded list of two frame names; anything else stayed on the
   minimap unless you happened to know its frame name. The collector now walks
   the children of `Minimap`, `MinimapBackdrop` and `MinimapCluster` and picks
   out what looks like a button — small, square, mouse-enabled, currently
   shown, and not one of Blizzard's own minimap widgets. A false positive costs
   one click in the options panel to switch off; turn the whole thing off with
   `/exadmm detect`.

   The "currently shown" part matters: collecting a button means calling
   `Show()` on it, and a frame its owner deliberately hid may not survive that.
   `MiniMapRecordingButton` is the example — it ships hidden, and its `OnUpdate`
   calls `MovieRecording_GetTime()`, which does not exist on this client, so
   showing it throws an error on every tooltip tick. A button that appears after
   login is not lost by the rule: the minimap is rescanned each time the grid is
   opened, which is cheap because it walks the minimap's children rather than
   the globals table.

Smaller changes: the skin also applies if `Blizzard_TimeManager` happens to load
before this addon (the original only handled the other order), there is a
non-`C_Timer` fallback for the deferred work, and SexyMap / Leatrix Plus
conflicts are reported through `/exadmm list` instead of failing silently.
