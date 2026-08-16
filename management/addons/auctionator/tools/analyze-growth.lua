-- analyze-growth.lua -- does vendor price growth per item level cluster by
-- item class / subclass / quality / slot, and would predicting from those
-- clusters beat the estimator we ship?  Maintenance tooling: never shipped,
-- never loaded by the client.
--
-- Usage (from the repo root):
--   lua5.1 management/addons/auctionator/tools/analyze-growth.lua <dump.lua> [more dumps...] [options]
--
--   -k <keys>     grouping keys to test, comma separated
--                 (default: qual,cls,sub,slot,cls+sub,cls+sub+qual)
--   -m <n>        ignore groups with fewer than n rows  (default: 5)
--   -v            list every group, not just the summary
--
-- The measurement.  Atr_VendorLearn_OnEvent logs each sale with both the
-- cached UNSCALED sighting (bil, brq, bp) and what actually sold (il, rq, p),
-- so a single log row already spans two item levels of the same item.  That
-- makes every row a growth sample -- and unlike the obs table, log rows carry
-- qual/cls/sub/slot, which is what a clustering question needs.
--
--   growth = (p / bp) ^ (1 / (il - bil)) - 1        per item level
--
-- Rows are deduped by (id, il, rq): repeat sales of the same tuple are the same
-- fact recorded twice, and letting them vote twice would overweight whatever a
-- player happened to vendor repeatedly.
--
-- The question is not "do the group medians differ" -- with enough groups some
-- always will.  It is whether knowing the group tells you anything you did not
-- already know from the global median, so the summary reports spread reduction
-- (how much of the scatter the grouping explains) and then simulates the
-- estimator head to head, leave-one-out, against the predictor's own logged
-- guesses on the same rows.  Only that last table answers "would this help".

local DEFAULT_KEYS = "qual,cls,sub,slot,cls+sub,cls+sub+qual"

local function die (fmt, ...)
	io.stderr:write ("analyze-growth: " .. string.format (fmt, ...) .. "\n")
	os.exit (1)
end

local opt   = { keys = DEFAULT_KEYS, minGroup = 5 }
local paths = {}

local i = 1
while (i <= #arg) do
	local a = arg[i]
	if     (a == "-k") then i = i + 1; opt.keys     = arg[i] or die ("-k needs a value")
	elseif (a == "-m") then i = i + 1; opt.minGroup = tonumber (arg[i]) or die ("-m needs a number")
	elseif (a == "-v") then opt.verbose = true
	elseif (a == "-h" or a == "--help") then
		io.write ("usage: lua5.1 analyze-growth.lua <dump.lua> [dumps...] [-k keys] [-m n] [-v]\n")
		os.exit (0)
	elseif (a:sub (1, 1) == "-") then die ("unknown option %s", a)
	else   paths[#paths + 1] = a
	end
	i = i + 1
end

if (#paths == 0) then die ("no SavedVariables dump given (try --help)") end

local function loadIsolated (path)
	local chunk, err = loadfile (path)
	if (chunk == nil) then die ("cannot read %s: %s", path, tostring (err)) end
	local env = {}
	setfenv (chunk, env)
	local okRun, runErr = pcall (chunk)
	if (not okRun) then die ("cannot parse %s: %s", path, tostring (runErr)) end
	return env
end

-- ---------------------------------------------------------------- gather --

local rows, seen = {}, {}
local stat = { total = 0, dup = 0, noSpan = 0, unusable = 0 }

for _, path in ipairs (paths) do
	local learned = loadIsolated (path).AUCTIONATOR_VENDOR_LEARNED
	if (type (learned) ~= "table") then die ("%s has no AUCTIONATOR_VENDOR_LEARNED table", path) end
	for _, e in ipairs (learned.log or {}) do
		stat.total = stat.total + 1
		local key = string.format ("%s:%s:%s", tostring (e.id), tostring (e.il), tostring (e.rq))
		if (seen[key]) then
			stat.dup = stat.dup + 1
		elseif (type (e.bp) ~= "number" or e.bp <= 0 or type (e.p) ~= "number" or e.p <= 0
		        or type (e.il) ~= "number" or type (e.bil) ~= "number" or e.bil <= 0) then
			stat.unusable = stat.unusable + 1
		elseif (e.il <= e.bil) then
			-- No span: the sale was at (or below) the cached base level, so it
			-- carries no growth information.  Common, and not an error.
			stat.noSpan = stat.noSpan + 1
			seen[key] = true
		else
			seen[key] = true
			rows[#rows + 1] = {
				id = e.id, span = e.il - e.bil, ratio = e.p / e.bp,
				growth = (e.p / e.bp) ^ (1 / (e.il - e.bil)) - 1,
				bp = e.bp, p = e.p, il = e.il, bil = e.bil,
				qual = e.qual, cls = e.cls, sub = e.sub, slot = e.slot,
				pp = e.pp, pt = e.pt,
			}
		end
	end
end

if (#rows == 0) then die ("no usable growth rows (need log entries whose sale ilvl exceeds the cached base ilvl)") end

-- ----------------------------------------------------------- statistics --

local function median (t)
	if (#t == 0) then return nil end
	local c = {}
	for n = 1, #t do c[n] = t[n] end
	table.sort (c)
	if (#c % 2 == 1) then return c[(#c + 1) / 2] end
	return (c[#c / 2] + c[#c / 2 + 1]) / 2
end

-- Median absolute deviation, not standard deviation: vendor growth has genuine
-- outliers (the plateau items sit at exactly 0) and one of them would dominate
-- a squared-error measure.
local function mad (t, centre)
	if (#t == 0) then return nil end
	local c = centre or median (t)
	local d = {}
	for n = 1, #t do d[n] = math.abs (t[n] - c) end
	return median (d)
end

local function pct (t, q)
	if (#t == 0) then return nil end
	local c = {}
	for n = 1, #t do c[n] = t[n] end
	table.sort (c)
	local idx = math.max (1, math.min (#c, math.floor (q * #c + 0.5)))
	return c[idx]
end

local function keyOf (r, spec)
	local parts = {}
	for field in spec:gmatch ("[^+]+") do
		local v = r[field]
		parts[#parts + 1] = (v == nil or v == "") and "?" or tostring (v)
	end
	return table.concat (parts, "|")
end

local allGrowth = {}
for _, r in ipairs (rows) do allGrowth[#allGrowth + 1] = r.growth end
local gMed = median (allGrowth)
local gMad = mad (allGrowth, gMed)

io.write (string.format ("rows       %d usable growth sample(s) from %d log row(s)\n", #rows, stat.total))
io.write (string.format ("           %d duplicate tuple(s), %d with no ilvl span, %d unusable\n",
                        stat.dup, stat.noSpan, stat.unusable))
io.write (string.format ("growth     median %.2f%%/ilvl   p10 %.2f%%   p90 %.2f%%   MAD %.2f%%\n",
                        gMed * 100, (pct (allGrowth, 0.10) or 0) * 100,
                        (pct (allGrowth, 0.90) or 0) * 100, gMad * 100))
io.write ("\n")

-- ----------------------------------------------------- clustering summary --

io.write ("-- does the grouping explain the scatter?\n")
io.write (string.format ("   %-18s %6s %7s %10s %10s\n", "key", "groups", "rows", "within-MAD", "explained"))

local specs = {}
for s in opt.keys:gmatch ("[^,]+") do specs[#specs + 1] = s end

for _, spec in ipairs (specs) do
	local groups = {}
	for _, r in ipairs (rows) do
		local k = keyOf (r, spec)
		groups[k] = groups[k] or {}
		table.insert (groups[k], r.growth)
	end

	-- Weighted mean of within-group MAD.  If the grouping is informative the
	-- scatter inside a group is smaller than the scatter overall; if it is
	-- noise, this lands back at the global MAD.
	local sumW, sumMad, nGroup, nUsed = 0, 0, 0, 0
	local listing = {}
	for k, t in pairs (groups) do
		nGroup = nGroup + 1
		if (#t >= opt.minGroup) then
			local m = median (t)
			sumW    = sumW + #t
			sumMad  = sumMad + mad (t, m) * #t
			nUsed   = nUsed + #t
			listing[#listing + 1] = { k = k, n = #t, med = m, mad = mad (t, m) }
		end
	end

	if (sumW == 0) then
		io.write (string.format ("   %-18s %6d %7s %10s %10s\n", spec, nGroup, "-", "-", "(no group reaches -m)"))
	else
		local within    = sumMad / sumW
		local explained = (gMad > 0) and (1 - within / gMad) or 0
		io.write (string.format ("   %-18s %6d %7d %9.2f%% %9.1f%%\n", spec, nGroup, nUsed, within * 100, explained * 100))
		if (opt.verbose) then
			table.sort (listing, function (a, b) return a.med < b.med end)
			for _, g in ipairs (listing) do
				io.write (string.format ("       %-34s n=%-4d median %7.2f%%/ilvl  MAD %6.2f%%\n",
				                        g.k, g.n, g.med * 100, g.mad * 100))
			end
		end
	end
end
io.write ("\n")

-- ------------------------------------------------------ estimator bakeoff --

-- Spread reduction is suggestive, not decisive: a grouping can explain scatter
-- and still not beat a flat guess once the prices are reconstructed.  So
-- rebuild each row's price from its base and score it.  Group medians are
-- computed leave-one-out -- a group median fitted on the row it then predicts
-- would score its own training data and flatter every candidate.
local function scoreOf (predict)
	local errs = {}
	for _, r in ipairs (rows) do
		local p = predict (r)
		if (p and p > 0) then errs[#errs + 1] = math.abs (p - r.p) / r.p end
	end
	return median (errs) or 0, pct (errs, 0.90) or 0, #errs
end

local function looMedian (spec)
	local groups = {}
	for _, r in ipairs (rows) do
		local k = keyOf (r, spec)
		groups[k] = groups[k] or {}
		table.insert (groups[k], r)
	end
	return function (r)
		local t = groups[keyOf (r, spec)]
		if (t == nil or #t < 2) then return nil end
		local vals = {}
		for _, o in ipairs (t) do
			if (o ~= r) then vals[#vals + 1] = o.growth end
		end
		return median (vals)
	end
end

local function looGlobal (r)
	local vals = {}
	for _, o in ipairs (rows) do
		if (o ~= r) then vals[#vals + 1] = o.growth end
	end
	return median (vals)
end

io.write ("-- rebuild the price from the base and score it (leave-one-out)\n")
io.write (string.format ("   %-30s %10s %10s %7s\n", "strategy", "median err", "p90 err", "rows"))

local med, p90, n = scoreOf (function (r) return r.bp end)
io.write (string.format ("   %-30s %9.1f%% %9.1f%% %7d\n", "flat: price = base price", med * 100, p90 * 100, n))

-- looGlobal is O(n^2) over the whole set; fine at log sizes (<= 500 per dump).
med, p90, n = scoreOf (function (r) return r.bp * (1 + looGlobal (r)) ^ r.span end)
io.write (string.format ("   %-30s %9.1f%% %9.1f%% %7d\n", "global median growth", med * 100, p90 * 100, n))

for _, spec in ipairs (specs) do
	local f = looMedian (spec)
	med, p90, n = scoreOf (function (r)
		local g = f (r)
		if (g == nil) then return nil end
		return r.bp * (1 + g) ^ r.span
	end)
	io.write (string.format ("   %-30s %9.1f%% %9.1f%% %7d\n", "group median: " .. spec, med * 100, p90 * 100, n))
end

-- What the addon actually said at the time, on the same rows.  pt=="learned" is
-- excluded: those are repeat sales of a price already stored locally, so the
-- predictor was reciting, not predicting, and counting them would make the
-- shipped estimator look far better than it is.
local errs, tiers = {}, {}
for _, r in ipairs (rows) do
	if (r.pp and r.pp > 0 and r.pt ~= "learned") then
		errs[#errs + 1] = math.abs (r.pp - r.p) / r.p
		tiers[r.pt or "?"] = (tiers[r.pt or "?"] or 0) + 1
	end
end
if (#errs > 0) then
	local parts = {}
	for k, v in pairs (tiers) do parts[#parts + 1] = string.format ("%s %d", k, v) end
	table.sort (parts)
	io.write (string.format ("   %-30s %9.1f%% %9.1f%% %7d\n", "SHIPPED predictor (non-learned)",
	                        (median (errs) or 0) * 100, (pct (errs, 0.90) or 0) * 100, #errs))
	io.write (string.format ("   %-30s %s\n", "   tiers in that row set", table.concat (parts, ", ")))
end
