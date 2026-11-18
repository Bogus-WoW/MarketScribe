-- MarketScribe: DEScan.lua
--
-- "Disenchant Scan": browses the Auction House for green and blue weapons and
-- armour, works out what each one would give when disenchanted (using the
-- dust/essence/shard prices MarketScribe has saved, via Disenchant.lua), and
-- lists the ones that cost less than that, best profit first, in a window
-- beside the Auction House.
--
-- Buying: click a row. The cheapest buyout of that item is looked up (so
-- the price is current), then a confirmation shows the cost and the profit.
-- Accepting it buys that auction. That's two clicks because the game only
-- lets an addon spend gold on a click, never on its own.
--
-- Pressing Scan first refreshes the dust/essence/shard prices (step 1), then browses the gear (step 2).
--
-- Commands: /ms de            show or hide the window
--           /ms de scan       start (or restart) a scan
--           /ms de min <s>    only list items with at least <s> silver profit
--
-- How the profit is worked out:
--   profit = disenchant value x 0.95 (the AH cut when you sell the dust)
--            - the lowest buyout for that item
-- Disenchant value is an average: Disenchant.lua's chances and amounts times
-- your saved material prices. A "*" means a material had no price saved, so
-- the value is a lower bound. The window does not check your Enchanting skill.

local addonName, ns = ...

local AH_CUT = 0.95
local MAX_RESULTS = 30000   -- stop paging the AH after this many item groups
local ROWS = 12
local ROW_H = 32

local entries = {}   -- key -> entry
local pendingInfo = {} -- itemID -> true while its item data loads
local list = {}      -- sorted, filtered view of entries
local scanning = false
local scanStarted
local lastScanned
local dirty = false
local offset = 0
local phase -- nil | "materials" (refreshing dust/essence/shard prices first)
local phaseDone
local StartBrowse
local buy -- { stage = "search" | "confirm" | "refresh", entry = , itemKey = }

local function Money(c)
	c = math.floor((c or 0) + (((c or 0) < 0) and -0.5 or 0.5))
	local neg = c < 0
	local text = GetMoneyString and GetMoneyString(math.abs(c), true) or ns.FormatMoney(math.abs(c))
	return (neg and "-" or "") .. text
end

local function MinProfit()
	local v = ns.Settings().deMinProfit
	if v == nil then return 100 end -- default: ignore under 1 silver
	return v
end

--------------------------------------------------------------------------
-- Valuing an item
--------------------------------------------------------------------------

local function Key(itemKey)
	return table.concat({ itemKey.itemID or 0, itemKey.itemLevel or 0, itemKey.itemSuffix or 0 }, ":")
end

-- Returns: "loading" while item data is missing, nil if it can't be
-- disenchanted, else the disenchant value (copper) and whether it's complete.
local function DisenchantValue(itemID)
	local name = C_Item.GetItemInfo(itemID)
	if not name then
		if not pendingInfo[itemID] and C_Item.RequestLoadItemDataByID then
			pendingInfo[itemID] = true
			C_Item.RequestLoadItemDataByID(itemID)
		end
		return "loading"
	end
	if not ns.GetDisenchantEV then return nil end
	local ev, complete = ns.GetDisenchantEV(itemID)
	if not ev or ev <= 0 then return nil end
	return ev * AH_CUT, complete
end

local function Evaluate(e)
	local value, complete = DisenchantValue(e.itemID)
	if value == "loading" then
		e.loading = true
		return
	end
	e.loading = false
	if not value then
		e.value = nil
		return
	end
	e.value, e.complete = value, complete
	e.profit = value - e.price
end

local function Rebuild()
	wipe(list)
	local minP = MinProfit()
	for _, e in pairs(entries) do
		if e.value and e.profit and e.profit >= minP and e.profit >= 1 then
			list[#list + 1] = e
		end
	end
	table.sort(list, function(a, b)
		if a.profit ~= b.profit then return a.profit > b.profit end
		return a.price < b.price
	end)
end

--------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------

local panel = CreateFrame("Frame", "MarketScribeDEPanel", UIParent, "BackdropTemplate")
panel:SetSize(380, 90 + ROWS * ROW_H)
panel:SetFrameStrata("HIGH")
panel:SetMovable(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:SetClampedToScreen(true)
panel:SetBackdrop({
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 14,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
panel:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
panel:Hide()

panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
panel:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, relPoint, x, y = self:GetPoint()
	ns.Settings().dePos = { point = point, relativePoint = relPoint, x = x, y = y }
end)

local function Place()
	panel:ClearAllPoints()
	local pos = ns.Settings().dePos
	if pos then
		panel:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
	elseif AuctionHouseFrame then
		-- left of the Auction House, so it never covers the Auctions-tab panel
		panel:SetPoint("TOPRIGHT", AuctionHouseFrame, "TOPLEFT", -4, -30)
	else
		panel:SetPoint("CENTER")
	end
end

panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panel.title:SetPoint("TOPLEFT", 10, -9)
panel.title:SetText("MarketScribe: Disenchant Scan")

panel.status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
panel.status:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -4)
panel.status:SetWidth(360)
panel.status:SetJustifyH("LEFT")

local scanBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
scanBtn:SetSize(90, 20)
scanBtn:SetPoint("TOPRIGHT", -8, -6)
scanBtn:SetText("Scan")

local closeBtn = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", 2, 2)
closeBtn:SetScale(0.7)
scanBtn:ClearAllPoints()
scanBtn:SetPoint("TOPRIGHT", -30, -6)

panel.rows = {}
local function Row(i)
	local r = panel.rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, panel)
	r:SetSize(344, ROW_H - 2)
	r:SetPoint("TOPLEFT", 10, -54 - (i - 1) * ROW_H)
	r.bg = r:CreateTexture(nil, "BACKGROUND")
	r.bg:SetAllPoints()
	r.bg:SetColorTexture(1, 1, 1, 0.04)
	r.hl = r:CreateTexture(nil, "HIGHLIGHT")
	r.hl:SetAllPoints()
	r.hl:SetColorTexture(1, 1, 1, 0.12)
	r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.name:SetPoint("TOPLEFT", 4, -2)
	r.name:SetWidth(240)
	r.name:SetJustifyH("LEFT")
	r.name:SetWordWrap(false)
	r.profit = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.profit:SetPoint("TOPRIGHT", -4, -2)
	r.profit:SetJustifyH("RIGHT")
	r.detail = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	r.detail:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -2)
	r.detail:SetWidth(336)
	r.detail:SetJustifyH("LEFT")
	r.detail:SetWordWrap(false)
	r:SetScript("OnEnter", function(self)
		if self.entry then
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			if self.entry.link then
				GameTooltip:SetHyperlink(self.entry.link)
			end
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Click to buy the cheapest one", 0.4, 1, 0.4)
			GameTooltip:Show()
		end
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r:SetScript("OnClick", function(self)
		if self.entry then ns.DEBuy(self.entry) end
	end)
	panel.rows[i] = r
	return r
end

local scroll = CreateFrame("Slider", nil, panel)
scroll:SetOrientation("VERTICAL")
scroll:SetPoint("TOPRIGHT", -4, -54)
scroll:SetSize(10, ROWS * ROW_H - 2)
scroll:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
scroll:GetThumbTexture():SetSize(8, 24)
scroll:GetThumbTexture():SetVertexColor(0.6, 0.6, 0.7, 0.8)
scroll.bg = scroll:CreateTexture(nil, "BACKGROUND")
scroll.bg:SetAllPoints()
scroll.bg:SetColorTexture(0, 0, 0, 0.4)
scroll:SetMinMaxValues(0, 0)
scroll:SetValueStep(1)
if scroll.SetObeyStepOnDrag then scroll:SetObeyStepOnDrag(true) end
scroll:SetValue(0)

panel.foot = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
panel.foot:SetPoint("BOTTOMLEFT", 10, 8)
panel.foot:SetWidth(360)
panel.foot:SetJustifyH("LEFT")

local settingScroll = false
local function Refresh()
	if not panel:IsShown() then return end
	if dirty then
		Rebuild()
		dirty = false
	end
	local maxOff = math.max(0, #list - ROWS)
	if offset > maxOff then offset = maxOff end
	settingScroll = true
	scroll:SetMinMaxValues(0, maxOff)
	scroll:SetValue(offset)
	settingScroll = false
	for i = 1, ROWS do
		local r = Row(i)
		local e = list[offset + i]
		if e then
			r.entry = e
			r.name:SetText((e.link or e.name or ("item:" .. e.itemID)) ..
				((e.qty or 1) > 1 and ("  |cff999999x" .. e.qty .. " listed|r") or ""))
			r.profit:SetText(("|cff40ff40+%s|r"):format(Money(e.profit)))
			r.detail:SetText(("costs %s  ->  disenchants for ~%s%s"):format(
				Money(e.price), Money(e.value), e.complete == false and "*" or ""))
			r:Show()
		else
			r.entry = nil
			r:Hide()
		end
	end
	local loading = 0
	for _, e in pairs(entries) do if e.loading then loading = loading + 1 end end
	local text
	if not ns.GetDisenchantEV then
		text = "Disenchant data is missing."
	elseif phase == "materials" then
		text = "|cffffd100Step 1/2: refreshing dust, essence and shard prices...|r"
	elseif scanning then
		text = ("|cffffd100Step 2/2: scanning gear...|r %d item groups so far, %d worth buying."):format(
			(function() local n = 0 for _ in pairs(entries) do n = n + 1 end return n end)(), #list)
	elseif lastScanned then
		text = ("%d worth buying. Scanned at %s."):format(#list, date("%H:%M", lastScanned))
	else
		text = "Press Scan to search the Auction House for gear that is worth disenchanting."
	end
	if loading > 0 then text = text .. (" (%d still loading item info)"):format(loading) end
	if buy and buy.stage == "search" then text = text .. "\n|cffffd100Looking up the cheapest listing...|r" end
	panel.status:SetText(text)
	panel.foot:SetText("Profit = disenchant value x 0.95 minus the buyout. * = a material has no saved price. Needs the Enchanting skill; not checked here.")
	scanBtn:SetText((scanning or phase) and "Stop" or "Scan")
end

scroll:SetScript("OnValueChanged", function(_, v)
	if settingScroll then return end
	offset = math.floor(v + 0.5)
	Refresh()
end)
panel:EnableMouseWheel(true)
panel:SetScript("OnMouseWheel", function(_, delta)
	offset = math.max(0, offset - delta * 3)
	Refresh()
end)

-- redraw a few times a second while results are arriving
local acc = 0
panel:SetScript("OnUpdate", function(_, dt)
	acc = acc + dt
	if acc >= 0.4 then
		acc = 0
		if phase == "materials" and not (ns.IsScanning and ns.IsScanning()) then
			-- queue empty: give the last search a moment to come back
			phaseDone = phaseDone or GetTime()
			if GetTime() - phaseDone >= 2 then
				if AuctionHouseFrame and AuctionHouseFrame:IsShown() then StartBrowse() else phase = nil end
			end
		end
		if scanning then pcall(Pump) end
		-- items whose info wasn't cached yet: ask again and re-value them
		local changed = false
		local budget = 400
		for _, e in pairs(entries) do
			if e.loading and budget > 0 then
				budget = budget - 1
				local _, link = C_Item.GetItemInfo(e.itemID)
				if link then
					e.link, e.name = link, C_Item.GetItemInfo(e.itemID)
					pendingInfo[e.itemID] = nil
					Evaluate(e)
					changed = true
				elseif C_Item.RequestLoadItemDataByID then
					C_Item.RequestLoadItemDataByID(e.itemID)
				end
			end
		end
		if changed then dirty = true end
		if dirty then Refresh() end
	end
end)

--------------------------------------------------------------------------
-- Scanning
--------------------------------------------------------------------------

local function QuerySpec()
	local Enum = Enum or {}
	local F = Enum.AuctionHouseFilter or {}
	local C = Enum.ItemClass or {}
	local sort = Enum.AuctionHouseSortOrder or {}
	local filters = {}
	if F.UncommonQuality then filters[#filters + 1] = F.UncommonQuality end
	if F.RareQuality then filters[#filters + 1] = F.RareQuality end
	return {
		searchString = "",
		minLevel = 0,
		maxLevel = 0,
		sorts = { { sortOrder = sort.Price or 0, reverseSort = false } },
		filters = filters,
		itemClassFilters = {
			{ classID = C.Armor or 4 },
			{ classID = C.Weapon or 2 },
		},
	}
end

local function Ingest()
	local results = C_AuctionHouse.GetBrowseResults() or {}
	for _, r in ipairs(results) do
		local ik = r.itemKey
		if ik and ik.itemID and r.minPrice and r.minPrice > 0 then
			local k = Key(ik)
			local e = entries[k]
			if not e then
				e = { key = k, itemKey = ik, itemID = ik.itemID }
				entries[k] = e
			end
			e.price = r.minPrice
			e.qty = r.totalQuantity
			if not e.link then
				local _, link = C_Item.GetItemInfo(e.itemID)
				e.link = link
				e.name = C_Item.GetItemInfo(e.itemID)
			end
			Evaluate(e)
		end
	end
	dirty = true
	return #results
end

local lastCount, lastGrowth, stable = 0, 0, 0
local function Finish(why)
	scanning = false
	lastScanned = time()
	dirty = true
	Rebuild()
	dirty = false
	Refresh()
	local n = 0
	for _ in pairs(entries) do n = n + 1 end
	local noDE, unprofitable, loading = 0, 0, 0
	for _, e in pairs(entries) do
		if e.loading then loading = loading + 1
		elseif not e.value then noDE = noDE + 1
		elseif not (e.profit and e.profit >= MinProfit()) then unprofitable = unprofitable + 1 end
	end
	print(("|cff40c0ffMarketScribe|r: disenchant scan done%s -- %d item groups checked, %d worth buying (%d not disenchantable or no material prices, %d not profitable enough, %d still loading)."):format(why or "", n, #list, noDE, unprofitable, loading))
end

local function Pump()
	if not scanning then return end
	if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
	local n = Ingest()
	if n > lastCount then lastCount, lastGrowth, stable = n, GetTime(), 0 end
	local full = C_AuctionHouse.HasFullBrowseResults and C_AuctionHouse.HasFullBrowseResults()
	if n >= MAX_RESULTS then return Finish(" (hit the " .. MAX_RESULTS .. " limit)") end
	if full then
		-- results can still be trickling in right after "full": wait until the count holds still
		stable = stable + 1
		if stable >= 3 then return Finish() end
	else
		stable = 0
		-- stalled: no new results for a while even though we kept asking
		if GetTime() - lastGrowth > 25 then return Finish(" (the Auction House stopped sending results)") end
		if C_AuctionHouse.IsThrottledMessageSystemReady() then
			C_AuctionHouse.RequestMoreBrowseResults()
		end
	end
	Refresh()
end

StartBrowse = function()
	phase = nil
	lastCount, lastGrowth, stable = 0, GetTime(), 0
	wipe(entries)
	wipe(pendingInfo)
	wipe(list)
	offset = 0
	scanning = true
	scanStarted = time()
	dirty = true
	local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, QuerySpec())
	if not ok then
		scanning = false
		print("|cff40c0ffMarketScribe|r: the Auction House refused the search: " .. tostring(err))
	end
	Refresh()
end

function ns.DEScan()
	if ns.neutralAH then
		print("|cff40c0ffMarketScribe|r: this is a Neutral Auction House -- scanning is disabled here.")
		return
	end
	if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
		print("|cff40c0ffMarketScribe|r: open the Auction House first.")
		return
	end
	if ns.IsScanning and ns.IsScanning() then
		print("|cff40c0ffMarketScribe|r: the price scan is still running. Stop it (Scan Prices button) or wait, then try again.")
		return
	end
	wipe(entries)
	wipe(list)
	offset = 0
	panel:Show()
	Place()
	-- first refresh every dust/essence/shard price so the values are current
	local added = 0
	if ns.QueueItemsForced and ns.DEMaterialIDs then
		added = ns.QueueItemsForced(ns.DEMaterialIDs()) or 0
	end
	if added > 0 then
		phase, phaseDone = "materials", nil
		scanning = false
		dirty = true
	else
		StartBrowse()
	end
	Refresh()
end

function ns.DEStop()
	if phase == "materials" then
		phase = nil
		if ns.StopScan then ns.StopScan() end
		Refresh()
		return
	end
	if scanning then
		scanning = false
		lastScanned = time()
		dirty = true
		Refresh()
	end
end

scanBtn:SetScript("OnClick", function()
	if scanning or phase then ns.DEStop() else ns.DEScan() end
end)

--------------------------------------------------------------------------
-- Buying
--------------------------------------------------------------------------

StaticPopupDialogs["MARKETSCRIBE_DE_BUY"] = {
	text = "%s",
	button1 = "Buy",
	button2 = CANCEL or "Cancel",
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnAccept = function()
		local b = buy
		if not (b and b.stage == "confirm" and b.auctionID) then return end
		b.stage = "refresh"
		C_AuctionHouse.PlaceBid(b.auctionID, b.buyout)
		print(("|cff40c0ffMarketScribe|r: buying %s for %s."):format(b.entry.link or b.entry.name or "item", Money(b.buyout)))
		-- look the item up again shortly, to drop it or show the next price
		C_Timer.After(1.5, function()
			if buy == b and AuctionHouseFrame and AuctionHouseFrame:IsShown() then
				pcall(C_AuctionHouse.SendSearchQuery, b.itemKey, { { sortOrder = (Enum.AuctionHouseSortOrder or {}).Price or 0, reverseSort = false } }, false)
			end
		end)
	end,
	OnCancel = function() buy = nil; Refresh() end,
}

function ns.DEBuy(e)
	if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
	if ns.IsScanning and ns.IsScanning() then
		print("|cff40c0ffMarketScribe|r: the price scan is running; stop it first.")
		return
	end
	buy = { stage = "search", entry = e, itemKey = e.itemKey }
	local ok = pcall(C_AuctionHouse.SendSearchQuery, e.itemKey, { { sortOrder = (Enum.AuctionHouseSortOrder or {}).Price or 0, reverseSort = false } }, false)
	if not ok then
		buy = nil
		print("|cff40c0ffMarketScribe|r: couldn't look that item up.")
	end
	Refresh()
end

-- Cheapest listing (with a buyout) that isn't yours.
local function CheapestListing(itemKey)
	local best
	for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0 do
		local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
		if r and r.buyoutAmount and r.buyoutAmount > 0 and r.auctionID and not r.containsOwnerItem then
			if not best or r.buyoutAmount < best.buyoutAmount then best = r end
		end
	end
	return best
end

local function OnItemResults(itemKey)
	if not (buy and itemKey and itemKey.itemID == buy.entry.itemID) then return end
	local best = CheapestListing(buy.itemKey)
	local e = buy.entry
	if buy.stage == "search" then
		if not best then
			print("|cff40c0ffMarketScribe|r: nobody is selling that with a buyout any more.")
			entries[e.key] = nil
			dirty = true
			buy = nil
			Refresh()
			return
		end
		buy.stage, buy.auctionID, buy.buyout = "confirm", best.auctionID, best.buyoutAmount
		local profit = e.value - best.buyoutAmount
		local text = ("Buy %s for %s?\nDisenchant value ~%s -> %s%s"):format(
			e.link or e.name or "this item", Money(best.buyoutAmount), Money(e.value),
			profit >= 0 and ("profit " .. Money(profit)) or ("|cffff4040loss " .. Money(-profit) .. "|r"),
			e.complete == false and " (*)" or "")
		StaticPopup_Show("MARKETSCRIBE_DE_BUY", text)
		Refresh()
	elseif buy.stage == "refresh" then
		-- after buying: update the row from the fresh listing
		if best then
			e.price = best.buyoutAmount
			Evaluate(e)
		else
			entries[e.key] = nil
		end
		dirty = true
		buy = nil
		Refresh()
	end
end

--------------------------------------------------------------------------
-- Events, button, command
--------------------------------------------------------------------------

local button = CreateFrame("Button", "MarketScribeDEButton", UIParent, "UIPanelButtonTemplate")
button:SetSize(140, 24)
button:SetText("Disenchant Scan")
button:SetFrameStrata("HIGH")
button:Hide()
button:SetScript("OnClick", function()
	if panel:IsShown() then
		panel:Hide()
	else
		Place()
		panel:Show()
		Refresh()
	end
end)

local function PlaceButton()
	button:ClearAllPoints()
	if MarketScribeScanButton then
		button:SetPoint("TOP", MarketScribeScanButton, "BOTTOM", 0, -2)
	else
		button:SetPoint("TOP", UIParent, "TOP", 0, -250)
	end
end

function ns.ToggleDEPanel()
	button:Click()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
ev:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
ev:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")
ev:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
ev:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ev:SetScript("OnEvent", function(_, event, a)
	if event == "AUCTION_HOUSE_SHOW" then
		PlaceButton()
		button:SetShown(not ns.neutralAH)
	elseif event == "AUCTION_HOUSE_CLOSED" then
		scanning = false
		phase = nil
		buy = nil
		button:Hide()
		panel:Hide()
		StaticPopup_Hide("MARKETSCRIBE_DE_BUY")
	elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED"
		or event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
		pcall(Pump)
	elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
		if scanning then
			scanning = false
			print("|cff40c0ffMarketScribe|r: the Auction House search failed. Try the scan again.")
			Refresh()
		end
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
		pcall(OnItemResults, a)
	elseif event == "GET_ITEM_INFO_RECEIVED" then
		if a and pendingInfo[a] then
			pendingInfo[a] = nil
			for _, e in pairs(entries) do
				if e.itemID == a then
					local _, link = C_Item.GetItemInfo(a)
					e.link, e.name = link, C_Item.GetItemInfo(a)
					Evaluate(e)
				end
			end
			dirty = true
		end
	end
end)

function ns.DECommand(arg)
	arg = arg or ""
	local sub, rest = arg:match("^(%S*)%s*(.-)$")
	if sub == "scan" then
		ns.DEScan()
	elseif sub == "min" then
		local s = tonumber(rest)
		if not s or s < 0 then
			print(("|cff40c0ffMarketScribe|r: only listing items with at least %s profit. /ms de min <silver> to change it."):format(Money(MinProfit())))
		else
			ns.Settings().deMinProfit = math.floor(s * 100)
			dirty = true
			Refresh()
			print(("|cff40c0ffMarketScribe|r: disenchant scan now lists items with at least %s profit."):format(Money(MinProfit())))
		end
	else
		if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
			if panel:IsShown() then
				panel:Hide()
			else
				Place()
				panel:Show()
				Refresh()
			end
		else
			print("|cff40c0ffMarketScribe|r: open the Auction House first. /ms de scan starts a scan, /ms de min <silver> sets the minimum profit.")
		end
	end
end
