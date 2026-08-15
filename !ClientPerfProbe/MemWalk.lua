--[[ MemWalk.lua — bounded, on-contract per-global Lua memory estimator (PURE,
     self-tested offline).

     WHY THIS EXISTS. On Ascension `GetAddOnMemoryUsage`→0 (per-addon memory is
     locked), and the devconsole `memtables` command IS Lua-readable per-addon
     memory (it named pfDB ≈ 158 MB, ~35% of the heap) but (a) prints to the
     devconsole, OFF the §6a copy/paste contract, and (b) bare `memtables` on `_G`
     dies with "block too big" — it walks 262k+ tables and OOMs on the unbounded
     scan/output. This is the on-contract answer: an in-addon `_G` size-walker that
     is BOUNDED (a hard node cap so it can't OOM), ranks the top memory globals, and
     feeds the copy/paste window (Report `WM`/`W` rows) — one-shot, repeatable, no
     screenshots.

     HONEST LIMITS (say them, don't hide them):
     - The byte figures are ROUGH ESTIMATES from a fixed per-node cost model. Exact
       table memory is not readable from Lua (that's why `memtables` does it
       engine-side, and even it calls its sizes "rough shallow estimates"). The
       constants below are tunable; calibrate them against a known `memtables`
       number (pfDB) when a live capture lands — do NOT hardcode a story.
     - `_G`-reachable NAMED state only. Closure upvalues / locals are invisible
       (same blind spot as `memtables`). A big table held only in a local won't show.
     - Shared subtrees are attributed to the FIRST root that reaches them (roots
       visited in sorted-key order for determinism) — so a table two addons share
       lands under one of them, not split. Rough, like `memtables`.
     - The walk is HEAVY (visits every reachable table). On-demand only (`/cpp mem`),
       never on the hot path. The node cap bounds worst-case time + memory.

     PURE: no WoW APIs. `estimate()` is a pure function of the table you pass it, so
     it self-tests under bare lua5.1. The WoW side just passes `_G` + a skip-set.
]]

local ADDON, ns = ...
ns = ns or {}

local MemWalk = {}

-- Rough per-node byte-cost model (Lua 5.1, 32-bit client — matches the 3.3.5
-- client). ESTIMATES, tunable; calibrate against a real `memtables` pfDB reading.
MemWalk.BYTES_TABLE  = 56       -- Table struct header overhead
MemWalk.BYTES_ARRAY  = 16       -- one array-part TValue slot
MemWalk.BYTES_HASH   = 40       -- one hash-part Node (key TValue + value TValue + next)
MemWalk.BYTES_STRING = 24       -- interned-string header; + #s bytes added per distinct string
-- Caps that keep the walk from OOMing a 32-bit client. `_G` here is 262k+ tables
-- and a single wide table (pfDB) can push tens of thousands of children in one
-- step — the array/hash doubling that follows is exactly the "block too big"
-- allocation failure the live capture hit. So we bound THREE things: total tables
-- (global memory ceiling), tables PER ROOT (one giant root can't starve/OOM the
-- rest — every addon-global still gets a floored estimate), and the pending stack
-- size (a wide node can't balloon the frontier). All far below the old 250k.
MemWalk.MAX_NODES    = 50000    -- global ceiling on tables visited (memory safety)
MemWalk.MAX_PER_ROOT = 6000     -- per-root ceiling (fair coverage; also bounds the stack)
MemWalk.DEFAULT_LIMIT = 12      -- top-N globals ranked into the report

-- Standard-library / runtime globals to skip as roots, so the estimate attributes
-- ADDON state rather than the Lua runtime itself. (Reachable library tables still
-- get visited if an addon references them; this only stops them being their own
-- top-level line item.) The caller can extend this.
MemWalk.DEFAULT_SKIP = {
    _G = true, _VERSION = true,
    string = true, table = true, math = true, os = true, io = true,
    coroutine = true, debug = true, package = true, bit = true, utf8 = true,
}

-- estimate(root, opts) -> {
--   ranked    = { { name=<globalKey>, bytes=<est>, nodes=<tableCount> }, ... } desc,
--   totalBytes= sum over ALL attributed roots (before the top-N limit),
--   totalNodes= tables visited,
--   capHit    = true if the GLOBAL node cap stopped the whole walk (total is a floor),
--   partial   = true if capHit OR any single root hit its per-root cap (some sizes are floors),
--   roots     = number of top-level roots attributed,
--   ranked[i].capped = true if THAT root was floored by the per-root/stack budget.
-- }
-- opts: { maxNodes=, maxPerRoot=, limit=, skip={key=true} }
function MemWalk.estimate(root, opts)
    opts = opts or {}
    if type(root) ~= "table" then
        return { ranked = {}, totalBytes = 0, totalNodes = 0, capHit = false, roots = 0 }
    end
    local maxNodes   = opts.maxNodes or MemWalk.MAX_NODES
    local maxPerRoot = opts.maxPerRoot or MemWalk.MAX_PER_ROOT
    local skip       = opts.skip or MemWalk.DEFAULT_SKIP
    local BT, BA, BH, BS = MemWalk.BYTES_TABLE, MemWalk.BYTES_ARRAY, MemWalk.BYTES_HASH, MemWalk.BYTES_STRING

    local visited = {}     -- [table]  = true   (each table counted at most once, globally)
    local seenStr = {}     -- [string] = true   (interned strings counted once)
    local totalNodes, capHit = 0, false

    -- one table's own structural cost (not its children)
    local function tableSelfBytes(t)
        local n, arr = 0, #t
        for _ in pairs(t) do n = n + 1 end
        local hash = n - arr
        if hash < 0 then hash = 0 end
        return BT + arr * BA + hash * BH
    end

    -- a string's bytes, once (interned => shared in the real heap)
    local function strBytes(s)
        if type(s) ~= "string" or seenStr[s] then return 0 end
        seenStr[s] = true
        return BS + #s
    end

    -- deterministic root order so ranking + shared-table attribution are stable
    local keys = {}
    for k in pairs(root) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local results = {}
    local anyRootCapped = false
    for _, key in ipairs(keys) do
        local v = root[key]
        if type(v) == "table" and not visited[v] and not skip[key] then
            local bytes, nodes = 0, 0
            local rootCapped = false
            local stack = { v }
            visited[v] = true
            while #stack > 0 do
                local t = stack[#stack]; stack[#stack] = nil
                bytes = bytes + tableSelfBytes(t)
                nodes = nodes + 1
                totalNodes = totalNodes + 1
                if totalNodes >= maxNodes then capHit = true; break end
                if nodes >= maxPerRoot then rootCapped = true; break end   -- this root is a floor
                for kk, vv in pairs(t) do
                    bytes = bytes + strBytes(kk) + strBytes(vv)
                    if type(kk) == "table" and not visited[kk] then
                        visited[kk] = true; stack[#stack + 1] = kk
                    end
                    if type(vv) == "table" and not visited[vv] then
                        visited[vv] = true; stack[#stack + 1] = vv
                    end
                    -- a single wide table must not balloon the frontier into an OOM;
                    -- stop pushing once the pending stack reaches the per-root budget.
                    if #stack >= maxPerRoot then rootCapped = true; break end
                end
                if rootCapped then break end
            end
            if rootCapped then anyRootCapped = true end
            results[#results + 1] = { name = tostring(key), bytes = bytes, nodes = nodes, capped = rootCapped }
            if capHit then break end
        end
    end

    table.sort(results, function(a, b)
        if a.bytes ~= b.bytes then return a.bytes > b.bytes end
        return a.name < b.name
    end)

    local totalBytes = 0
    for _, r in ipairs(results) do totalBytes = totalBytes + r.bytes end
    local roots = #results

    local limit = opts.limit or MemWalk.DEFAULT_LIMIT
    if limit and #results > limit then
        for i = #results, limit + 1, -1 do results[i] = nil end
    end

    return { ranked = results, totalBytes = totalBytes, totalNodes = totalNodes,
             capHit = capHit, partial = (capHit or anyRootCapped), roots = roots }
end

ns.MemWalk = MemWalk

--============================================================================--
if _SELFTEST then
    local function eq(a, b, msg)
        assert(a == b, (msg or "eq") .. ": expected " .. tostring(b) .. " got " .. tostring(a))
    end

    -- a fake _G: one big global (nested tables) + one small + a skipped runtime one
    local big = {}
    for i = 1, 50 do big["k" .. i] = { a = i, b = "val" .. i } end   -- 1 + 50 child tables
    local fakeG = {
        pfDB  = big,
        small = { x = 1 },
        math  = { pi = 3 },   -- would be huge-ish but is on the skip list
        n     = 42,           -- non-table global ignored
    }

    local r = MemWalk.estimate(fakeG, { skip = { math = true } })
    eq(r.ranked[1].name, "pfDB", "ranks the biggest global first")
    assert(r.ranked[1].bytes > r.ranked[2].bytes, "pfDB estimated larger than small")
    eq(r.ranked[1].nodes, 51, "counts the root + its 50 child tables")
    eq(r.roots, 2, "two attributed roots (math skipped, n is not a table)")
    -- 'math' must not appear (skipped as a root)
    for _, e in ipairs(r.ranked) do assert(e.name ~= "math", "skip-set excludes runtime globals") end

    -- determinism: same input -> same ranking + byte figures
    local r2 = MemWalk.estimate(fakeG, { skip = { math = true } })
    eq(r2.ranked[1].bytes, r.ranked[1].bytes, "estimate is deterministic")

    -- node cap: stops the walk and flags capHit (estimate becomes a floor)
    local capped = MemWalk.estimate(fakeG, { skip = { math = true }, maxNodes = 3 })
    eq(capped.capHit, true, "node cap trips capHit")
    eq(capped.partial, true, "global cap => partial")
    assert(capped.totalNodes <= 3, "node cap bounds tables visited")

    -- per-root cap: a giant root is floored but SMALLER roots are still covered
    -- (the fix for the live 'block too big' OOM — one huge root can't starve the walk)
    local bigA = {}
    for i = 1, 40 do bigA["k" .. i] = { a = i } end          -- 1 + 40 = 41 child tables
    local g3 = { aaa = bigA, bbb = { x = 1 }, ccc = { y = 2 } }
    local rp = MemWalk.estimate(g3, { skip = {}, maxPerRoot = 5 })
    local aaaR, bbbR
    for _, e in ipairs(rp.ranked) do
        if e.name == "aaa" then aaaR = e elseif e.name == "bbb" then bbbR = e end
    end
    assert(aaaR and aaaR.nodes <= 5, "per-root cap bounds the giant root's node count")
    eq(aaaR.capped, true, "the floored root is flagged capped")
    assert(bbbR ~= nil, "smaller roots are still covered despite a capped big root")
    eq(rp.partial, true, "a capped root marks the estimate partial")

    -- a wide table (many table children at once) can't balloon the stack past the cap
    local wide = {}
    for i = 1, 100 do wide["c" .. i] = { i } end
    local rw = MemWalk.estimate({ w = wide }, { skip = {}, maxPerRoot = 10 })
    assert(rw.ranked[1].nodes <= 10, "wide-node frontier is bounded by the per-root cap")
    eq(rw.partial, true, "wide-node cap marks partial")

    -- shared subtree attributed to the FIRST root (sorted order), counted once
    local shared = { s = 1 }
    local g2 = { aaa = { ref = shared }, zzz = { ref = shared } }
    local rs = MemWalk.estimate(g2, { skip = {} })
    local aaaNodes, zzzNodes
    for _, e in ipairs(rs.ranked) do
        if e.name == "aaa" then aaaNodes = e.nodes elseif e.name == "zzz" then zzzNodes = e.nodes end
    end
    eq(aaaNodes, 2, "first root owns the shared table (root + shared)")
    eq(zzzNodes, 1, "second root does not double-count the shared table")

    -- cycles don't loop forever (visited guards identity)
    local cyc = {}; cyc.self = cyc
    local rc = MemWalk.estimate({ c = cyc }, { skip = {} })
    eq(rc.ranked[1].nodes, 1, "self-cycle visited once")

    -- non-table root is handled
    local rn = MemWalk.estimate("not a table")
    eq(rn.totalNodes, 0, "non-table root -> empty estimate")

    print("MemWalk: OK")
end

return ns.MemWalk
