--[[ selftest.lua — run !ClientPerfProbe's OWN self-tests under bare lua5.1.

     This is a RUNNER, not a harness. Six of the probe's pure modules already
     carry an `if _SELFTEST then ... end` block; there was simply no way to
     invoke them from the repo, so they were dead. This sets the flag and loads
     each module as a chunk. No stubs, no mocks, no WoW emulation — the modules
     that need the client (Core, Probe, Attrib, UI, Minimap, ExportWindow) are
     deliberately NOT listed here and stay syntax-check-only.

     Usage, from the repo root:  lua5.1 management/addons/clientperfprobe/tools/selftest.lua
]]

_SELFTEST = true

local MODULES = {
    "RingBuffer",
    "Report",
    "Events",
    "LoadProfile",
    "MemWalk",
    "Storm",
}

local ns = {}
local failed = 0

for _, name in ipairs(MODULES) do
    local path = "!ClientPerfProbe/" .. name .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then
        print(("%s: LOAD FAILED — %s"):format(name, tostring(err)))
        failed = failed + 1
    else
        -- same varargs the client passes an addon file: (addonName, sharedTable)
        local ok, cerr = pcall(chunk, "!ClientPerfProbe", ns)
        if not ok then
            print(("%s: FAILED — %s"):format(name, tostring(cerr)))
            failed = failed + 1
        end
    end
end

if failed > 0 then
    print(("\n%d module(s) failed."):format(failed))
    os.exit(1)
end
print("\nall self-tests passed.")
