-- gen-vendor-seed.lua -- regenerate Auctionator-Finder-Ascension/AuctionatorVendorSeed.lua
-- from a SavedVariables dump.  Maintenance tooling: never shipped, never loaded
-- by the client.
--
-- Usage (from the repo root):
--   lua5.1 management/addons/auctionator/tools/gen-vendor-seed.lua <dump.lua> [options]
--
--   <dump.lua>    WTF/Account/<ACCT>/SavedVariables/Auctionator-Finder-Ascension.lua
--   -o <path>     output file  (default: Auctionator-Finder-Ascension/AuctionatorVendorSeed.lua)
--   --date <d>    meta.built stamp  (default: today, UTC)
--   --src <s>     meta.src provenance label  (default: dump-<sha-ish of the file>)
--   --replace     emit ONLY the dump's real observations; do not carry the current
--                 seed forward.  Default is union: current seed + dump, dump wins
--                 on conflict, so a regeneration can never lose a known fact.
--   --force-date  allow reusing the current seed's meta.built (see below)
--   --dry-run     report what would change; write nothing
--
-- What ships, and why (Old Docs/VENDOR-SEED-PLAN.md in the upstream
-- Auctionator-Ascension-Finder repo):
--   * .obs["itemID:ilvl:req"] = copper   -- confirmed per-instance sale prices
--   * .base[itemID] = { p, il, rq }      -- trusted unscaled base facts
--   * NEVER .cb / .trk / .log -- cache- and client-local state, meaningless or
--     wrong on another player's install.
--
-- The meta.built stamp is load-bearing, not decoration.  Atr_VendorSeed_Merge
-- refreshes a seed-only entry only when the shipped version differs from the
-- player's stored db.seedver (`prev ~= ver`).  Ship new prices under the old
-- date and every existing install silently keeps the stale ones, so this script
-- refuses to reuse the current date unless --force-date is passed.
--
-- Entries are sorted by (itemID, ilvl, req) / itemID so successive dumps
-- produce reviewable diffs rather than reshuffled noise.

local DEFAULT_OUT = "Auctionator-Finder-Ascension/AuctionatorVendorSeed.lua"

-- ------------------------------------------------------------------ args --

local function die (fmt, ...)
	io.stderr:write ("gen-vendor-seed: " .. string.format (fmt, ...) .. "\n")
	os.exit (1)
end

local opt = { out = DEFAULT_OUT, union = true }
local dumpPath = nil

local i = 1
while (i <= #arg) do
	local a = arg[i]
	if     (a == "-o")           then i = i + 1; opt.out       = arg[i] or die ("-o needs a path")
	elseif (a == "--date")       then i = i + 1; opt.date      = arg[i] or die ("--date needs a value")
	elseif (a == "--src")        then i = i + 1; opt.src       = arg[i] or die ("--src needs a value")
	elseif (a == "--replace")    then opt.union     = false
	elseif (a == "--force-date") then opt.forceDate = true
	elseif (a == "--dry-run")    then opt.dryRun    = true
	elseif (a == "-h" or a == "--help") then
		io.write ("usage: lua5.1 gen-vendor-seed.lua <dump.lua> [-o out] [--date d] [--src s]\n"
		       .. "                                  [--replace] [--force-date] [--dry-run]\n")
		os.exit (0)
	elseif (a:sub (1, 1) == "-") then die ("unknown option %s", a)
	elseif (dumpPath == nil)     then dumpPath = a
	else   die ("unexpected argument %s", a)
	end
	i = i + 1
end

if (dumpPath == nil) then die ("no SavedVariables dump given (try --help)") end

-- ------------------------------------------------------- load Lua chunks --

-- SavedVariables and the seed file are both plain Lua assignments.  Load each
-- into its own empty environment: no globals leak between them, and a dump that
-- somehow contains a call finds nothing to call.
local function loadIsolated (path, what)
	local chunk, err = loadfile (path)
	if (chunk == nil) then die ("cannot read %s %s: %s", what, path, tostring (err)) end
	local env = {}
	setfenv (chunk, env)
	local okRun, runErr = pcall (chunk)
	if (not okRun) then die ("cannot parse %s %s: %s", what, path, tostring (runErr)) end
	return env
end

local dumpEnv = loadIsolated (dumpPath, "dump")
local learned = dumpEnv.AUCTIONATOR_VENDOR_LEARNED

if (type (learned) ~= "table") then
	die ("%s has no AUCTIONATOR_VENDOR_LEARNED table -- is this the Auctionator SavedVariables file?", dumpPath)
end

-- current seed, for the union floor and for the date-collision check
local curObs, curBase, curBuilt = {}, {}, nil
do
	local f = io.open (opt.out, "r")
	if (f) then
		f:close ()
		local seedEnv = loadIsolated (opt.out, "current seed")
		local cur     = seedEnv.ATR_VENDOR_SEED
		if (type (cur) == "table") then
			curObs   = cur.obs or {}
			curBase  = cur.base or {}
			curBuilt = cur.meta and cur.meta.built
		end
	end
end

-- --------------------------------------------------------------- harvest --

local function isCopper (p)
	return type (p) == "number" and p > 0 and p == math.floor (p)
end

-- obs keys are "itemID:ilvl:req"; anything else is corruption, not a fact.
local function parseKey (k)
	if (type (k) ~= "string") then return nil end
	local id, il, rq = k:match ("^(%d+):(%d+):(%d+)$")
	if (id == nil) then return nil end
	return tonumber (id), tonumber (il), tonumber (rq)
end

local obs, base   = {}, {}
local skipped     = { obs = 0, base = 0 }
local nNew, nChanged, nCarried = 0, 0, 0

if (opt.union) then
	for k, p in pairs (curObs) do
		if (parseKey (k) and isCopper (p)) then obs[k] = p; nCarried = nCarried + 1 end
	end
	for id, r in pairs (curBase) do
		if (type (id) == "number" and type (r) == "table" and isCopper (r.p)) then
			base[id] = { p = r.p, il = r.il or 0, rq = r.rq or 0 }
		end
	end
end

-- .obs -- a record is a real confirmed sale once n > 0; n == 0 with seed == 1 is
-- just the shipped table echoed back into the player's SavedVariables.
for k, rec in pairs (learned.obs or {}) do
	if (parseKey (k) == nil or type (rec) ~= "table" or not isCopper (rec.p)) then
		skipped.obs = skipped.obs + 1
	else
		local real = (rec.n or 0) > 0
		if (real or opt.union) then
			local prev = obs[k]
			if     (prev == nil)   then nNew = nNew + 1
			elseif (prev ~= rec.p) then nChanged = nChanged + 1 end
			obs[k] = rec.p
		end
	end
end

-- .base -- trusted only from majority-voted unscaled sales (n > 0).  seed == 1
-- marks a record this install got from the shipped table, not from a real sale.
for id, r in pairs (learned.base or {}) do
	local nid = tonumber (id)
	if (nid == nil or type (r) ~= "table" or not isCopper (r.p) or (r.n or 0) <= 0) then
		skipped.base = skipped.base + 1
	else
		local real = (r.seed == nil)
		if (real or opt.union) then
			base[nid] = { p = r.p, il = tonumber (r.il) or 0, rq = tonumber (r.rq) or 0 }
		end
	end
end

-- ------------------------------------------------------------------ meta --

local built = opt.date or os.date ("!%Y-%m-%d")

if (built == curBuilt and not opt.forceDate) then
	die ("meta.built would stay %s -- existing installs would keep their stale seed-only\n"
	  .. "prices (the refresh path is gated on prev ~= ver).  Pass --date <newer> or\n"
	  .. "--force-date if you really mean to reship under the same version.", built)
end

-- provenance: cheap content-derived label, enough to tell two dumps apart.
local src = opt.src
if (src == nil) then
	local f = io.open (dumpPath, "rb")
	local h = 5381
	if (f) then
		local blob = f:read ("*a") or ""
		f:close ()
		for pos = 1, #blob do
			h = (h * 33 + blob:byte (pos)) % 4294967296
		end
		src = string.format ("dump-%08x", h)
	else
		src = "dump-unknown"
	end
end

-- ------------------------------------------------------------------ emit --

local obsKeys = {}
for k in pairs (obs) do obsKeys[#obsKeys + 1] = k end
table.sort (obsKeys, function (a, b)
	local aid, ail, arq = parseKey (a)
	local bid, bil, brq = parseKey (b)
	if (aid ~= bid) then return aid < bid end
	if (ail ~= bil) then return ail < bil end
	return arq < brq
end)

local baseIDs = {}
for id in pairs (base) do baseIDs[#baseIDs + 1] = id end
table.sort (baseIDs)

local out = {}
local function w (s) out[#out + 1] = s end

w ("-- AuctionatorVendorSeed.lua  -- AUTO-GENERATED, do not hand-edit.\n")
w ("-- Bundled table of server-deterministic vendor facts, harvested from\n")
w ("-- confirmed buyback sales. Merged into AUCTIONATOR_VENDOR_LEARNED at login\n")
w ("-- to seed fresh installs (see VENDOR-SEED-PLAN.md). Prices are copper.\n")
w ("--   obs[\"itemID:ilvl:req\"] = unitPrice   (confirmed per-instance sale)\n")
w ("--   base[itemID] = { p, il, rq }          (trusted unscaled base fact)\n")
w (string.format ("-- Built from %s; %d obs tuples, %d base facts.\n", src, #obsKeys, #baseIDs))
w ("-- Regenerate with management/addons/auctionator/tools/gen-vendor-seed.lua.\n")
w ("\n")
w ("ATR_VENDOR_SEED = {\n")
w (string.format ("\tmeta = { built = %q, nobs = %d, nbase = %d, src = %q },\n",
                  built, #obsKeys, #baseIDs, src))
w ("\tobs = {\n")
for _, k in ipairs (obsKeys) do
	w (string.format ("\t\t[%q] = %d,\n", k, obs[k]))
end
w ("\t},\n")
w ("\tbase = {\n")
for _, id in ipairs (baseIDs) do
	local r = base[id]
	w (string.format ("\t\t[%d] = { p = %d, il = %d, rq = %d },\n", id, r.p, r.il, r.rq))
end
w ("\t},\n")
w ("}\n")

local body = table.concat (out)

-- ---------------------------------------------------------------- report --

io.write (string.format ("dump     %s\n", dumpPath))
io.write (string.format ("mode     %s\n", opt.union and "union (current seed carried forward)" or "replace (dump only)"))
io.write (string.format ("obs      %d  (+%d new, %d price changes, %d carried)\n",
                        #obsKeys, nNew, nChanged, nCarried))
io.write (string.format ("base     %d\n", #baseIDs))
if (skipped.obs > 0 or skipped.base > 0) then
	io.write (string.format ("skipped  %d obs, %d base  (malformed key, non-integer price, or unvoted)\n",
	                        skipped.obs, skipped.base))
end
io.write (string.format ("built    %s%s\n", built, curBuilt and ("  (was " .. curBuilt .. ")") or ""))

if (opt.dryRun) then
	io.write ("dry run  -- nothing written\n")
	os.exit (0)
end

local fh, ferr = io.open (opt.out, "wb")
if (fh == nil) then die ("cannot write %s: %s", opt.out, tostring (ferr)) end
fh:write (body)
fh:close ()

io.write (string.format ("wrote    %s\n", opt.out))
io.write ("verify   luac5.1 -p " .. opt.out .. "\n")
