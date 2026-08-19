--[[ Alert.lua -- the upgrade / high-value alert surface.

HARD CONSTRAINT (DESIGN §6.4, inherited from the importer): StaticPopups and
overlays do NOT render reliably on this client. So the alert is a gameplay-time
CreateFrame floating frame plus a colored chat line -- never a StaticPopup.

Built for TWO independent reasons-to-need from day one (§7): an "upgrade" verdict
and a "high value" flag can appear alone or together in one alert.

WoW-API; guarded so the file loads (as a no-op) under bare lua5.1.
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local Alert = {}
ns.Alert = Alert

local PREFIX = "|cff33ff99PLBiS|r "   -- matches BiSRollLog's chat color

-- The two cues, one per reason-to-need (§7). Distinct on purpose: with both
-- toggles on you can tell an upgrade from a gold flag without looking away.
--
-- A cue is either a SoundEntries.dbc kit name (`kit`, played with PlaySound) or a
-- file shipped in this addon (`file`, played with PlaySoundFile). Note that BOTH
-- fail SILENTLY on this client -- a misspelt kit name and a missing file are
-- equally soundless, with no error -- which is what the options window's Test
-- button exists to catch.
local UPGRADE_SOUND = { kit = "LEVELUP" }

-- Shipped coin jingle (Sounds/coin.ogg), supplied by the addon owner. Converted
-- for this client: trimmed of 74ms leading silence, lifted ~13.5dB (the source
-- peaked at -19.7dBFS, some 20dB under WoW's own effects, so it vanished under
-- combat), and resampled 48kHz stereo -> 44.1kHz mono, which is what the 3.3.5
-- sound engine is built around. Sounds/coin.mp3 is the same audio in the other
-- format the client accepts: if the .ogg turns out silent on an Ascension build,
-- swap the extension on the line below -- that is the whole fallback.
local VALUE_SOUND   = { file = "Interface\\AddOns\\PassLootBiS_Scanner\\Sounds\\coin.ogg" }

-- Format a delta fraction as a signed percent, or "new" for an empty slot.
local function fmtDelta(delta)
	if delta == math.huge then return "new slot" end
	return string.format("+%d%%", math.floor(delta * 100 + 0.5))
end

-- Build the one-line human summary from the two independent reasons.
-- info = { itemLink, itemName, slotName, delta, isBiS, goldText }
function Alert.summary(info)
	local parts = {}
	if info.isBiS then
		parts[#parts + 1] = "|cffff8000BiS!|r"
	end
	if info.delta ~= nil then
		parts[#parts + 1] = "Possible upgrade " .. fmtDelta(info.delta)
			.. (info.slotName and (" for " .. info.slotName) or "")
	end
	if info.goldText then
		parts[#parts + 1] = "|cffffd700" .. info.goldText .. "|r"
	end
	return table.concat(parts, "  ·  ")
end

ns.Alert.summary = Alert.summary   -- exposed for tests (pure)

-- Which sound cues this alert should fire, given the channel toggles. Pure, so
-- the options window's Test button can play exactly what a real alert would.
--
-- There is deliberately NO separate sound threshold. db.useSound fires on ANY
-- upgrade -- the upgrade-threshold slider already decides what counts as one, and
-- db.useSoundGold likewise rides the gold threshold. (Superseded: this used to
-- fire only above a second, hidden `strongDelta` cutoff of +10%, which meant the
-- visible threshold you set was silently not the one the sound obeyed.)
function Alert.cues(info, db)
	db = db or {}
	local out = {}
	if db.useSound and info.delta ~= nil then
		out[#out + 1] = UPGRADE_SOUND
	end
	if db.useSoundGold and info.goldText then
		out[#out + 1] = VALUE_SOUND
	end
	return out
end

ns.Alert.cues = Alert.cues   -- exposed for tests (pure)

-- The rest is UI; skip when no WoW API.
if not rawget(_G, "CreateFrame") then
	return Alert
end

local frame
local function ensureFrame()
	if frame then return frame end
	frame = CreateFrame("Frame", "PLBiSScannerAlert", UIParent)
	frame:SetWidth(320)
	frame:SetHeight(52)
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
	ns.UI.applyDarkBackdrop(frame)   -- shared house chrome (Core/UI.lua)
	-- Strata deliberately left alone: applyWindowChrome() puts windows on LOW, under
	-- the Blizzard panels, which is right for a window you go and look at but wrong
	-- for a notification. This toast exists to be NOTICED, and the moment it fires
	-- is usually the moment your bags are open -- on LOW it would be hidden behind
	-- them exactly when it matters. Spike-free either way: no SetToplevel here.
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

	local icon = frame:CreateTexture(nil, "ARTWORK")
	icon:SetWidth(32); icon:SetHeight(32)
	icon:SetPoint("LEFT", frame, "LEFT", 10, 0)
	frame.icon = icon

	local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	text:SetPoint("LEFT", icon, "RIGHT", 8, 0)
	text:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
	text:SetJustifyH("LEFT")
	frame.text = text

	frame:Hide()
	return frame
end

-- Show an alert. `db` carries the channel toggles
-- (useFrame/useChat/useSound/useSoundGold).
function Alert.Show(info, db)
	db = db or {}
	local line = Alert.summary(info)
	local named = (info.itemLink or info.itemName or "?") .. "  " .. line

	if db.useChat ~= false then
		DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. named)
	end

	if db.useFrame then
		local f = ensureFrame()
		if info.texture then f.icon:SetTexture(info.texture) else f.icon:SetTexture(nil) end
		f.text:SetText((info.itemLink or info.itemName or "?") .. "\n" .. line)
		f:Show()
	end

	Alert.PlayCues(info, db)
end

-- Play the cues Alert.cues() picks; returns how many fired (the Test button in
-- the options window reports "nothing is on" when that is 0).
function Alert.PlayCues(info, db)
	local cues = Alert.cues(info, db)
	for _, cue in ipairs(cues) do
		if cue.file then
			PlaySoundFile(cue.file)
		else
			PlaySound(cue.kit)
		end
	end
	return #cues
end

-- Hide the floating frame (call when the roll ends).
function Alert.Hide()
	if frame then frame:Hide() end
end

return Alert
