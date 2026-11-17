-- MarketScribe: Export.lua
--
-- Lets you get MarketScribe's collected price data out of the game as a
-- plain JSON blob, so it can be pasted/uploaded somewhere else (e.g. to
-- figure out which materials are actually worth farming). MarketScribe
-- itself only knows prices -- it has no idea where anything drops or is
-- gathered, so that part happens outside the game with whatever you paste
-- this into.

local addonName, ns = ...

--------------------------------------------------------------------------
-- Minimal JSON encoder -- just enough for our own flat data shapes
-- (strings, numbers, booleans, arrays, and objects built from an explicit
-- ordered list of key/value pairs so output is stable and human-readable
-- rather than relying on Lua's unordered pairs()).
--------------------------------------------------------------------------

local function EncodeString(s)
	s = s:gsub('[%c\\"]', function(c)
		if c == "\\" then
			return "\\\\"
		elseif c == '"' then
			return '\\"'
		elseif c == "\n" then
			return "\\n"
		elseif c == "\r" then
			return "\\r"
		elseif c == "\t" then
			return "\\t"
		else
			return string.format("\\u%04x", c:byte())
		end
	end)
	return '"' .. s .. '"'
end

local EncodeValue -- forward decl

local function EncodeArray(t)
	local parts = {}
	for i, v in ipairs(t) do
		parts[i] = EncodeValue(v)
	end
	return "[" .. table.concat(parts, ",") .. "]"
end

local function EncodeObject(orderedPairs)
	local parts = {}
	for i, kv in ipairs(orderedPairs) do
		parts[i] = EncodeString(kv[1]) .. ":" .. EncodeValue(kv[2])
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

EncodeValue = function(v)
	local t = type(v)
	if t == "string" then
		return EncodeString(v)
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return "null"
		end
		return tostring(v)
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		if v.__isObject then
			return EncodeObject(v)
		end
		return EncodeArray(v)
	end
	return "null"
end

--------------------------------------------------------------------------
-- Building the export payload
--------------------------------------------------------------------------

local function ItemName(itemID)
	local name
	if C_Item and C_Item.GetItemInfo then
		name = C_Item.GetItemInfo(itemID)
	end
	if not name and GetItemInfo then
		name = GetItemInfo(itemID)
	end
	return name
end

local function FindField(entry, key)
	for _, kv in ipairs(entry) do
		if kv[1] == key then
			return kv[2]
		end
	end
	return nil
end

local function BuildExportTable()
	local store = ns.Store()
	local seen = {}
	local items = {}

	local function AddItem(itemID)
		if seen[itemID] then
			return
		end
		seen[itemID] = true
		local price, capturedAt, source = ns.GetPrice(itemID)
		if not price then
			return
		end
		local entry = {
			__isObject = true,
			{ "id", itemID },
			{ "name", ItemName(itemID) or ("Item #" .. itemID) },
			{ "price", price },
			{ "source", source },
		}
		if capturedAt then
			table.insert(entry, { "ageSeconds", time() - capturedAt })
		end
		table.insert(items, entry)
	end

	for itemID in pairs(store.prices) do
		AddItem(itemID)
	end
	for itemID in pairs(store.vendor) do
		AddItem(itemID)
	end

	-- Most-valuable-first, since that's what matters when scanning for
	-- worthwhile farming targets.
	table.sort(items, function(a, b)
		return (FindField(a, "price") or 0) > (FindField(b, "price") or 0)
	end)

	return {
		__isObject = true,
		{ "realm", ns.RealmKey() },
		{ "exportedAt", time() },
		{ "itemCount", #items },
		{ "items", items },
	}
end

function ns.BuildExportJSON()
	return EncodeValue(BuildExportTable())
end

--------------------------------------------------------------------------
-- Export window: a plain, selectable text box, shown on /ms export.
--------------------------------------------------------------------------

local exportFrame

local function EnsureFrame()
	if exportFrame then
		return exportFrame
	end

	local f = CreateFrame("Frame", "MarketScribeExportFrame", UIParent, "BackdropTemplate")
	f:SetSize(520, 420)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetBackdrop({
		bgFile = "Interface/DialogFrame/UI-DialogBox-Background",
		edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
		tile = true,
		tileSize = 32,
		edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	f:Hide()

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("MarketScribe Export")

	local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("TOP", title, "BOTTOM", 0, -6)
	hint:SetText("Ctrl+A then Ctrl+C to copy, then paste it wherever you're sending it.")

	local scroll = CreateFrame("ScrollFrame", "MarketScribeExportScroll", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 16, -56)
	scroll:SetPoint("BOTTOMRIGHT", -32, 44)

	local edit = CreateFrame("EditBox", nil, scroll)
	edit:SetMultiLine(true)
	edit:SetFontObject(ChatFontNormal)
	edit:SetWidth(460)
	edit:SetAutoFocus(false)
	edit:SetScript("OnEscapePressed", function()
		f:Hide()
	end)
	-- Wrapped: the focus handler receives extra arguments, which HighlightText
	-- would otherwise read as (start, stop) and reject as out of range.
	edit:SetScript("OnEditFocusGained", function(self)
		self:HighlightText()
	end)
	scroll:SetScrollChild(edit)
	f.editBox = edit

	local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	close:SetSize(96, 22)
	close:SetPoint("BOTTOM", 0, 14)
	close:SetText("Close")
	close:SetScript("OnClick", function()
		f:Hide()
	end)

	exportFrame = f
	return f
end

function ns.ShowExport()
	local json = ns.BuildExportJSON()
	local f = EnsureFrame()
	f.editBox:SetText(json)
	f:Show()
	f.editBox:SetFocus()
	f.editBox:HighlightText()
end
