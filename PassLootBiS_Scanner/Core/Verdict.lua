--[[ Verdict.lua -- the pure roll-verdict shape.

Turns the scanner's compare result (is it an upgrade? by how much? is it high
value?) into the frozen verdict table the PasslootBiS roll advisor consumes
(integration.md §5.2a, docs/integration-api.md §3.6):

    { upgrade = bool, delta = number, highValue = bool,
      downgrade = bool, downDelta = number, reason = string }

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

-- Format a NEGATIVE delta fraction as a signed percent. Separate from fmtDelta
-- because that one hardcodes a "+" (it only ever describes upgrades) and has a
-- "new slot" sentinel that cannot occur on this side: you can only be worse than
-- something you already have.
function Verdict.fmtDownDelta(delta)
	-- Round the MAGNITUDE and re-apply the sign, rather than flooring the negative
	-- directly: math.floor rounds toward -infinity, so a clean -0.12 came out as
	-- "-13%" and every downgrade read one point worse than it was.
	local pct = math.floor(math.abs(tonumber(delta) or 0) * 100 + 0.5)
	return string.format("-%d%%", pct)
end

-- Build the verdict table, or nil to abstain when no reason applies.
--   isUpgrade : bool from Score.verdict
--   delta     : delta fraction from Score.verdict
--   goldText  : Auctionator high-value flag text (or nil)
--   down      : BiS-downgrade info, or nil. { delta = negative fraction,
--               wonName = string|nil } -- see the third reason below.
-- The `reason` is human-readable -- it is what the host's held-confirm popup /
-- advisory tag shows the user.
--
-- THREE independent reasons to speak up, not two (the third was added for the
-- owner's "BiS Check", 2026-08):
--   * upgrade   -- beats what you would replace. Roll for it.
--   * highValue -- worth gold on the AH. Roll for it.
--   * downgrade -- it is ON YOUR BiS LIST but scores BELOW what you would replace,
--                  so the BiS rule is about to Need something worse than you have.
--                  This one is a WARNING, not an invitation: the host vetoes the
--                  auto-roll and shows the window instead of rolling.
-- Only the host decides what to DO with each; this file just states them.
function Verdict.build(isUpgrade, delta, goldText, down)
	isUpgrade = isUpgrade and true or false
	local highValue = (goldText ~= nil and goldText ~= "")
	local downgrade = (type(down) == "table")
	-- An item cannot be both better and worse than the thing it replaces. If the
	-- caller somehow says both, the upgrade wins and the warning is dropped: a
	-- false "don't roll" costs you the item, a false "roll" costs you a roll.
	if isUpgrade then downgrade = false end
	if not isUpgrade and not highValue and not downgrade then return nil end

	local parts = {}
	if isUpgrade then parts[#parts + 1] = "Upgrade " .. Verdict.fmtDelta(delta) end
	if downgrade then
		local line = "On your BiS list, but " .. Verdict.fmtDownDelta(down.delta) .. " vs equipped"
		if down.wonName and down.wonName ~= "" then
			-- The run-ledger case: what actually beat it is the thing you won ten
			-- minutes ago and have not equipped yet, so name it or the number looks
			-- wrong against the character sheet.
			line = "On your BiS list, but " .. Verdict.fmtDownDelta(down.delta) ..
				" vs the " .. down.wonName .. " you won"
		end
		parts[#parts + 1] = line
	end
	if highValue then parts[#parts + 1] = goldText end

	return {
		upgrade   = isUpgrade,
		delta     = isUpgrade and (tonumber(delta) or 0) or 0,
		highValue = highValue,
		downgrade = downgrade,
		downDelta = downgrade and (tonumber(down.delta) or 0) or 0,
		reason    = table.concat(parts, " / "),
	}
end

ns.Verdict = Verdict
return Verdict
