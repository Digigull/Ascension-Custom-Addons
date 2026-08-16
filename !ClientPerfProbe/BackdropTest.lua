--[[ BackdropTest.lua — live backdrop INSPECTOR (`/cpp backdrop <Frame>`).

     What is left of the drag-freeze investigation's tooling. The A/B/C/D backdrop
     frames and the E/F/G/H construction frames that used to live here were spawned
     to isolate the freeze one variable at a time; the cause is confirmed and written
     up (SetToplevel(true) raising into a populated strata — management/docs/DRAG-FREEZE.md),
     so the spawners are gone. The backdrop A/B was itself EXONERATED along the way:
     an empty HIGH+toplevel frame with no backdrop at all still froze 1273 ms.

     describe() stays because it answers a question the write-up does not: what is
     THIS window on THIS client actually built with. It reads a live frame's backdrop
     via GetBackdrop() — nothing is created, shown, or moved — so a suspicious window
     can be compared against a known-smooth one (Details / WeakAuras) without guessing
     from third-party source that may not match the installed 3.3.5 build.

     WoW-facing (reads _G, calls GetBackdrop); syntax-checked only. No CreateFrame
     anywhere in this file, at file scope or otherwise.
]]

local ADDON, ns = ...

local BackdropTest = {}

-- describe(name): read a LIVE frame's backdrop straight from the owner's client, so a
-- spiking window can be compared to a non-spiking one (Details / WeakAuras) without
-- guessing from third-party source (their installed 3.3.5 builds may differ from any
-- public/retail source). Uses the standard GetBackdrop() — feature-detected (ground
-- rule 2). Returns { found=bool, heavy=bool, lines={...} } for the caller to print.
-- A frame with a plain custom texture / no SetBackdrop returns GetBackdrop()==nil (the
-- light style); a standard dialog window returns the UI-DialogBox table. "heavy" flags
-- the latter as a STYLE observation only — the backdrop is not a freeze cause.
function BackdropTest.describe(name)
    local f = (type(name) == "string") and (rawget(_G, name) or _G[name]) or nil
    if type(f) ~= "table" or type(f.GetBackdrop) ~= "function" then
        return { found = false, lines = {
            tostring(name) .. ": not found / not backdrop-capable (open the window first — many are lazy)" } }
    end
    local ok, bd = pcall(f.GetBackdrop, f)
    if not ok then
        return { found = false, lines = { tostring(name) .. ": GetBackdrop() failed on this client" } }
    end
    if type(bd) ~= "table" then
        return { found = true, heavy = false, lines = {
            tostring(name) .. ": |cff44ff44NO SetBackdrop|r (custom textures / none) — the light style" } }
    end
    local bg = tostring(bd.bgFile or "-")
    local edge = tostring(bd.edgeFile or "-")
    local heavy = (bg:find("UI%-DialogBox") or edge:find("UI%-DialogBox")) and true or false
    return {
        found = true, heavy = heavy,
        lines = {
            tostring(name) .. ": SetBackdrop present" ..
                (heavy and " |cffff8800(standard UI-DialogBox — the heavy style)|r" or " |cffffff00(non-standard backdrop)|r"),
            ("  bg=|cffdddddd%s|r"):format(bg),
            ("  edge=|cffdddddd%s|r tile=%s tileSize=%s edgeSize=%s"):format(
                edge, tostring(bd.tile), tostring(bd.tileSize), tostring(bd.edgeSize)),
        },
    }
end

ns.BackdropTest = BackdropTest

return ns.BackdropTest
