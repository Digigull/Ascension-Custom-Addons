--[[ Verdict.lua -- the pure roll-verdict shape.

Turns the scanner's compare result (is it an upgrade? by how much? is it high
value?) into the frozen verdict table the PasslootBiS roll advisor consumes
(integration.md §5.2a, docs/integration-api.md §3.6):

    { upgrade = bool, delta = number, highValue = bool, reason = string }

The SAME table shape is read by PasslootBiS.API on the host side, so this is the
cross-addon contract -- keep it identical to Core/RollAdvisor.lua's
NormalizeVerdict over in the PasslootBiS repo. No WoW API here, so it loads and
self-tests under bare lua5.1.
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local Verdict = {}

-- Format a delta fraction as a signed percent, or "new slot" for an empty slot
-- (math.huge sentinel from Score.deltaFraction). Mirrors Alert.fmtDelta so the
-- advisor reason and the scanner's own alert read the same.
function Verdict.fmtDelta(delta)
	if delta == math.huge then return "new slot" end
	return string.format("+%d%%", math.floor((tonumber(delta) or 0) * 100 + 0.5))
end

-- Build the verdict table, or nil to abstain when neither reason applies.
--   isUpgrade : bool from Score.verdict
--   delta     : delta fraction from Score.verdict
--   goldText  : Auctionator high-value flag text (or nil)
-- The `reason` is human-readable -- it is what the host's held-confirm popup /
-- advisory tag shows the user.
function Verdict.build(isUpgrade, delta, goldText)
	isUpgrade = isUpgrade and true or false
	local highValue = (goldText ~= nil and goldText ~= "")
	if not isUpgrade and not highValue then return nil end

	local parts = {}
	if isUpgrade then parts[#parts + 1] = "Upgrade " .. Verdict.fmtDelta(delta) end
	if highValue then parts[#parts + 1] = goldText end

	return {
		upgrade   = isUpgrade,
		delta     = isUpgrade and (tonumber(delta) or 0) or 0,
		highValue = highValue,
		reason    = table.concat(parts, " / "),
	}
end

ns.Verdict = Verdict
return Verdict
