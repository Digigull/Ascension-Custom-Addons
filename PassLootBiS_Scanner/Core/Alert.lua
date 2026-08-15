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

-- Show an alert. `db` carries the channel toggles (useFrame/useChat/useSound).
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

	if db.useSound and info.strong then
		PlaySound("LEVELUP")   -- a distinct cue on a strong upgrade
	end
end

-- Hide the floating frame (call when the roll ends).
function Alert.Hide()
	if frame then frame:Hide() end
end

return Alert
