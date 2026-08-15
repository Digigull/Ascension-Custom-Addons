-- diff-vendor-seed.lua -- compare a SavedVariables dump against the shipped
-- Auctionator-Finder-Ascension/AuctionatorVendorSeed.lua.  Maintenance tooling:
-- never shipped, never loaded by the client.
--
-- Usage (from the repo root):
--   lua5.1 management/addons/auctionator/tools/diff-vendor-seed.lua <dump.lua> [options]
--
--   <dump.lua>    WTF/Account/<ACCT>/SavedVariables/Auctionator-Finder-Ascension.lua
--   -s <path>     seed to compare against (default: the shipped seed)
--   -n <count>    sample rows to print per bucket  (default: 8, 0 = none)
--   --all         print every row of every bucket, not a sample
--
-- Why this exists.  gen-vendor-seed.lua reports "+N new", which cannot answer
-- the only question that matters before shipping: is a new entry a fact this
-- player actually confirmed, or the shipped table echoed back at us?
-- Atr_VendorSeed_Merge writes every shipped obs price into the player's
-- SavedVariables as { p, n = 0, seed = 1 }, so a dump always contains the seed
-- it was merged from.  In union mode those echoes are indistinguishable from
-- real observations at the point gen-vendor-seed counts them.
--
-- The provenance flags (AuctionatorHints.lua, Atr_VendorLearn_OnEvent and
-- Atr_VendorSeed_Merge) carry the answer:
--
--   obs   seed == 1, n == 0    pure echo of some shipped seed, never sold here
--         seed == nil, n > 0   real sale; a confirmed sale clears the flag
--
--   base  seed == 1, n == 1    pure echo of some shipped seed
--         seed == 1, n > 1     echo that real unscaled sales then re-confirmed
--         seed == nil          real observation; x counts price conflicts ever
--                              seen for that item (majority vote self-healing)
--
-- The bucket that justifies this script is ECHO-ONLY-NOT-IN-SEED: an entry
-- flagged as seeded whose key the current seed does not contain.  It can only
-- have come from an OLDER shipped seed, so union mode would silently promote a
-- price we already chose to drop back into the shipped table, laundered as new.
-- That is what "an old file mixed with a new one" looks like from here.

local DEFAULT_SEED = "Auctionator-Finder-Ascension/AuctionatorVendorSeed.lua"

local function die (fmt, ...)
	io.stderr:write ("diff-vendor-seed: " .. string.format (fmt, ...) .. "\n")
	os.exit (1)
end

-- ------------------------------------------------------------------ args --

local opt = { seed = DEFAULT_SEED, sample = 8 }
local dumpPath = nil

local i = 1
while (i <= #arg) do
	local a = arg[i]
	if     (a == "-s") then i = i + 1; opt.seed   = arg[i] or die ("-s needs a path")
	elseif (a == "-n") then i = i + 1; opt.sample = tonumber (arg[i]) or die ("-n needs a number")
	elseif (a == "--all") then opt.all = true
	elseif (a == "-h" or a == "--help") then
		io.write ("usage: lua5.1 diff-vendor-seed.lua <dump.lua> [-s seed] [-n count] [--all]\n")
		os.exit (0)
	elseif (a:sub (1, 1) == "-") then die ("unknown option %s", a)
	elseif (dumpPath == nil)      then dumpPath = a
	else   die ("unexpected argument %s", a)
	end
	i = i + 1
end

if (dumpPath == nil) then die ("no SavedVariables dump given (try --help)") end

-- Same isolation as gen-vendor-seed: each chunk gets its own empty environment,
-- so no globals leak between them and a dump containing a call finds nothing
-- to call.
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

local seedEnv  = loadIsolated (opt.seed, "seed")
local seed     = seedEnv.ATR_VENDOR_SEED
if (type (seed) ~= "table") then die ("%s has no ATR_VENDOR_SEED table", opt.seed) end
local seedObs  = seed.obs  or {}
local seedBase = seed.base or {}
local seedVer  = (seed.meta and seed.meta.built) or "?"

-- --------------------------------------------------------------- buckets --

local function parseKey (k)
	if (type (k) ~= "string") then return nil end
	local id, il, rq = k:match ("^(%d+):(%d+):(%d+)$")
	if (id == nil) then return nil end
	return tonumber (id), tonumber (il), tonumber (rq)
end

local function isCopper (p)
	return type (p) == "number" and p > 0 and p == math.floor (p)
end

local B = {}				-- ordered bucket list, so the report reads top-down
local function bucket (name, note)
	local b = { name = name, note = note, rows = {} }
	B[#B + 1] = b
	B[name]   = b
	return b
end

local function put (name, row) local b = B[name]; b.rows[#b.rows + 1] = row end

bucket ("obs.agree",       "in both, same price -- the dump confirms the shipped value")
bucket ("obs.disagree",    "in both, DIFFERENT price -- one of the two is wrong")
bucket ("obs.new.real",    "not in seed, confirmed by a real sale here -- the payload")
bucket ("obs.new.echo",    "not in seed, flagged seeded -- ghost from an OLDER seed")
bucket ("obs.seedonly",    "in seed, absent from the dump -- carried forward unverified")
bucket ("obs.malformed",   "unparseable key or non-integer price -- dropped")
bucket ("base.agree",      "in both, same price")
bucket ("base.disagree",   "in both, DIFFERENT price")
bucket ("base.new.real",   "not in seed, real unscaled sale")
bucket ("base.new.tested", "not in seed, seeded but re-confirmed by real sales")
bucket ("base.new.echo",   "not in seed, pure echo -- ghost from an OLDER seed")
bucket ("base.seedonly",   "in seed, absent from the dump")
bucket ("base.contested",  "conflicting prices seen for this item (x > 0) -- low trust")
bucket ("base.malformed",  "unusable record -- dropped")

-- .obs ---------------------------------------------------------------------

local nEcho, nReal = 0, 0

for k, rec in pairs (learned.obs or {}) do
	local id = parseKey (k)
	if (id == nil or type (rec) ~= "table" or not isCopper (rec.p)) then
		put ("obs.malformed", { k = tostring (k) })
	else
		local n    = rec.n or 0
		local echo = (rec.seed == 1 and n == 0)		-- merge writes exactly this
		if (echo) then nEcho = nEcho + 1 else nReal = nReal + 1 end

		local sp = seedObs[k]
		if (sp == nil) then
			put (echo and "obs.new.echo" or "obs.new.real", { k = k, p = rec.p, n = n })
		elseif (sp == rec.p) then
			put ("obs.agree", { k = k, p = rec.p, n = n, echo = echo })
		else
			put ("obs.disagree", { k = k, p = rec.p, sp = sp, n = n, echo = echo })
		end
	end
end

for k, sp in pairs (seedObs) do
	if ((learned.obs or {})[k] == nil) then put ("obs.seedonly", { k = k, sp = sp }) end
end

-- .base --------------------------------------------------------------------

for id, r in pairs (learned.base or {}) do
	local nid = tonumber (id)
	if (nid == nil or type (r) ~= "table" or not isCopper (r.p)) then
		put ("base.malformed", { k = tostring (id) })
	else
		local n = r.n or 0
		local x = r.x or 0
		if (x > 0) then put ("base.contested", { id = nid, p = r.p, n = n, x = x }) end

		local sr   = seedBase[nid]
		local kind = (r.seed ~= 1) and "real" or ((n > 1) and "tested" or "echo")
		if (n <= 0) then
			put ("base.malformed", { k = tostring (id) .. " (n=" .. n .. ", vote collapsed)" })
		elseif (sr == nil) then
			put ("base.new." .. kind, { id = nid, p = r.p, n = n, x = x })
		elseif (sr.p == r.p) then
			put ("base.agree", { id = nid, p = r.p, n = n, kind = kind })
		else
			put ("base.disagree", { id = nid, p = r.p, sp = sr.p, n = n, kind = kind })
		end
	end
end

for id in pairs (seedBase) do
	if ((learned.base or {})[id] == nil) then put ("base.seedonly", { id = id, sp = seedBase[id].p }) end
end

-- ---------------------------------------------------------------- report --

local function money (c)
	local g, s = math.floor (c / 10000), math.floor ((c % 10000) / 100)
	if (g > 0) then return string.format ("%dg%02ds%02dc", g, s, c % 100) end
	if (s > 0) then return string.format ("%ds%02dc", s, c % 100) end
	return string.format ("%dc", c)
end

local function describe (r)
	if (r.k and r.p == nil and r.sp == nil) then return r.k end
	local who = r.k or ("item " .. tostring (r.id))
	local out
	if (r.sp and r.p) then
		out = string.format ("%-18s %12s -> %-12s  (%+.1f%%)", who, money (r.sp), money (r.p),
		                     ((r.p / r.sp) - 1) * 100)
	elseif (r.p) then
		out = string.format ("%-18s %12s", who, money (r.p))
	else
		out = string.format ("%-18s %12s", who, money (r.sp))
	end
	if (r.n)    then out = out .. string.format ("  n=%d", r.n) end
	if (r.x and r.x > 0) then out = out .. string.format ("  x=%d", r.x) end
	if (r.kind) then out = out .. "  " .. r.kind end
	if (r.echo) then out = out .. "  echo" end
	return out
end

local function sortRows (rows)
	table.sort (rows, function (a, b)
		local ak = a.k or string.format ("%09d", a.id or 0)
		local bk = b.k or string.format ("%09d", b.id or 0)
		local aid, ail, arq = parseKey (ak)
		local bid, bil, brq = parseKey (bk)
		if (aid and bid) then
			if (aid ~= bid) then return aid < bid end
			if (ail ~= bil) then return ail < bil end
			return arq < brq
		end
		return ak < bk
	end)
end

io.write (string.format ("dump      %s\n", dumpPath))
io.write (string.format ("seed      %s  (built %s)\n", opt.seed, seedVer))
io.write (string.format ("seedver   %s%s\n", tostring (learned.seedver),
                        tostring (learned.seedver) == seedVer and "  (matches shipped seed)"
                                                              or "  <- DIFFERENT from the shipped seed"))
io.write (string.format ("dump obs  %d  (%d real, %d seed echo)   dump base %d   log %d\n",
                        nReal + nEcho, nReal, nEcho,
                        (function () local c = 0; for _ in pairs (learned.base or {}) do c = c + 1 end; return c end) (),
                        #(learned.log or {})))
io.write (string.format ("seed obs  %d   seed base %d\n",
                        #(function () local t = {}; for k in pairs (seedObs)  do t[#t + 1] = k end; return t end) (),
                        #(function () local t = {}; for k in pairs (seedBase) do t[#t + 1] = k end; return t end) ()))
io.write ("\n")

for _, b in ipairs (B) do
	io.write (string.format ("%-18s %6d   %s\n", b.name, #b.rows, b.note))
end
io.write ("\n")

local populated = 0
for _, b in ipairs (B) do
	if (#b.rows > 0) then populated = populated + 1 end
	local limit = opt.all and #b.rows or math.min (#b.rows, opt.sample)
	if (limit > 0) then
		sortRows (b.rows)
		io.write (string.format ("-- %s  (%d)\n", b.name, #b.rows))
		for n = 1, limit do io.write ("   " .. describe (b.rows[n]) .. "\n") end
		if (limit < #b.rows) then io.write (string.format ("   ... %d more\n", #b.rows - limit)) end
		io.write ("\n")
	end
end
-- Distinguish "every bucket is empty" from "-n 0 asked for no samples".
if (populated == 0) then io.write ("(no rows in any bucket)\n\n") end

-- ----------------------------------------------------------------- audit --

-- Two cheap structural checks on the dump itself.  Neither compares against the
-- seed; they ask whether the dump is internally coherent enough to ship from.
--
-- Not checked, deliberately: obs against base at the base record's own
-- (id, il, rq).  Those tables are disjoint by construction -- an unscaled sale
-- takes the base branch of Atr_VendorLearn_OnEvent and never writes obs -- so
-- the check finds nothing to compare and "0 mismatches" would read as a pass
-- where no test ran.

local repeats = { inseed = {}, new = {} }
for k, rec in pairs (learned.obs or {}) do
	if (parseKey (k) and isCopper (rec.p)) then
		local w = seedObs[k] and "inseed" or "new"
		local n = rec.n or 0
		repeats[w][n] = (repeats[w][n] or 0) + 1
	end
end

local function distLine (w)
	local t, ks = repeats[w], {}
	for n in pairs (t) do ks[#ks + 1] = n end
	table.sort (ks)
	local out = {}
	for _, n in ipairs (ks) do out[#out + 1] = string.format ("n=%d:%d", n, t[n]) end
	return table.concat (out, "  ")
end

-- Vendor price rises with item level for a given item, so a higher-ilvl tuple
-- priced below a lower-ilvl one is a corrupt record, not a bargain.
local per = {}
for k, rec in pairs (learned.obs or {}) do
	local id, il = parseKey (k)
	if (id and isCopper (rec.p)) then
		per[id] = per[id] or {}
		table.insert (per[id], { il = il, p = rec.p })
	end
end

local inversions, multiItem = {}, 0
for id, rows in pairs (per) do
	if (#rows > 1) then
		multiItem = multiItem + 1
		table.sort (rows, function (a, b) return a.il < b.il end)
		for n = 2, #rows do
			if (rows[n].il > rows[n - 1].il and rows[n].p < rows[n - 1].p) then
				inversions[#inversions + 1] = string.format ("item %d  il %d = %s  ->  il %d = %s",
					id, rows[n - 1].il, money (rows[n - 1].p), rows[n].il, money (rows[n].p))
			end
		end
	end
end

io.write ("-- audit\n")
io.write (string.format ("   repeat sales, already in seed   %s\n", distLine ("inseed")))
io.write (string.format ("   repeat sales, new to the seed   %s\n", distLine ("new")))
io.write (string.format ("   ilvl monotonicity               %d item(s) with >1 tuple, %d inversion(s)\n",
                        multiItem, #inversions))
for n = 1, math.min (#inversions, opt.all and #inversions or opt.sample) do
	io.write ("     " .. inversions[n] .. "\n")
end
io.write ("\n")

-- The verdict is about provenance, not counts: disagreements and ghosts are the
-- two ways a regeneration can ship something worse than what it replaced.
local bad = #B["obs.disagree"].rows + #B["base.disagree"].rows
local ghost = #B["obs.new.echo"].rows + #B["base.new.echo"].rows
if (bad > 0)   then io.write (string.format ("WARN  %d price disagreement(s) -- reconcile before regenerating.\n", bad)) end
if (ghost > 0) then io.write (string.format ("WARN  %d ghost entr(ies) from an older seed -- union mode would promote them.\n", ghost)) end
if (#inversions > 0) then io.write (string.format ("WARN  %d ilvl price inversion(s) -- suspect record(s).\n", #inversions)) end
if (bad == 0 and ghost == 0 and #inversions == 0) then
	io.write ("OK    no disagreements, no ghosts, no inversions: the dump is a clean superset of the seed.\n")
end
