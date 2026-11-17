-- MarketScribe: ScanButton.lua
--
-- A small draggable button that appears while the Auction House is open.
-- Clicking it forces an immediate re-scan of every reagent/output tied to
-- your known recipes (bypassing the normal per-item cooldown), so you
-- don't have to search each one by hand. Same thing /ms scan does.
--
-- It's a standalone floating frame rather than something docked onto
-- AuctionHouseFrame's own layout, so it can't ever overlap or clip
-- Blizzard's UI -- drag it wherever's convenient once and it stays there.

local addonName, ns = ...

local button = CreateFrame("Button", "MarketScribeScanButton", UIParent, "UIPanelButtonTemplate")
button:SetSize(140, 24)
button:SetText("Scan Prices")
button:SetMovable(true)
button:EnableMouse(true)
button:RegisterForDrag("LeftButton")
button:SetFrameStrata("HIGH")
button:Hide()

button:SetScript("OnDragStart", function(self)
	self:StartMoving()
end)

button:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, relativePoint, x, y = self:GetPoint()
	ns.Settings().buttonPos = { point = point, relativePoint = relativePoint, x = x, y = y }
end)

local function RestorePosition()
	button:ClearAllPoints()
	local pos = ns.Settings().buttonPos
	if pos then
		button:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
	else
		button:SetPoint("TOP", UIParent, "TOP", 0, -220)
	end
end

button:SetScript("OnClick", function()
	-- while a scan is running, a click stops it instead of restarting it
	if ns.IsScanning and ns.IsScanning() then
		local dropped = ns.StopScan()
		print(("|cff40c0ffMarketScribe|r: scan stopped (%d items not searched). Click again to start a new scan."):format(dropped))
		return
	end
	if not ns.ForceScanAll then
		return
	end
	local added = ns.ForceScanAll()
	if added == 0 then
		print("|cff40c0ffMarketScribe|r: nothing to scan -- everything left is priced by vendor or commodity data already.")
	else
		print(("|cff40c0ffMarketScribe|r: scanning %d items (skipping vendor/commodity prices, which don't need it)."):format(added))
	end
end)

-- Called by Scanner.lua whenever the queue length changes.
function ns.ReportScanProgress(remaining)
	if remaining and remaining > 0 then
		button:SetText(("Stop scan (%d left)"):format(remaining))
	else
		button:SetText("Scan Prices")
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:SetScript("OnEvent", function(_, event)
	if event == "AUCTION_HOUSE_SHOW" then
		RestorePosition()
		button:Show()
	elseif event == "AUCTION_HOUSE_CLOSED" then
		button:Hide()
	end
end)

--------------------------------------------------------------------------
-- Undercut watch
--
-- While the Auctions tab is open, a panel beside the Auction House lists
-- your auctions that someone has listed cheaper than you. Each of your
-- items is searched once when you open the tab (and again with "Check
-- again"); the search results are read here with your own listings left
-- out, so "lowest" is always the cheapest *other* seller.
--------------------------------------------------------------------------

local RECHECK = 300 -- seconds before an item is searched again on tab open
local competitor = {} -- itemID -> { price = unit copper or false, time = }
local mine = {}       -- itemID -> { price = my lowest unit price, link = }
local announced = {}  -- itemID -> competitor price we already printed

local panel = CreateFrame("Frame", "MarketScribeUndercutPanel", UIParent, "BackdropTemplate")
panel:SetSize(300, 60)
panel:SetFrameStrata("HIGH")
panel:SetBackdrop({
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 14,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
panel:SetBackdropColor(0.05, 0.05, 0.08, 0.92)
panel:Hide()

panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panel.title:SetPoint("TOPLEFT", 10, -9)
panel.title:SetText("MarketScribe: undercuts")

panel.status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
panel.status:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -4)
panel.status:SetJustifyH("LEFT")
panel.status:SetWidth(280)

local check = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
check:SetSize(90, 18)
check:SetPoint("TOPRIGHT", -8, -7)
check:SetText("Check again")
check:GetFontString():SetFontObject("GameFontNormalSmall")

panel.rows = {}
local function Row(i)
	local r = panel.rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, panel)
	r:SetSize(284, 28)
	r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.name:SetPoint("TOPLEFT", 0, 0)
	r.name:SetWidth(284)
	r.name:SetJustifyH("LEFT")
	r.name:SetWordWrap(false)
	r.detail = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	r.detail:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 8, -2)
	r.detail:SetJustifyH("LEFT")
	r:SetScript("OnEnter", function(self)
		if self.link then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink(self.link)
			GameTooltip:Show()
		end
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	panel.rows[i] = r
	return r
end

local function Money(c)
	if GetMoneyString then
		return GetMoneyString(c, true)
	end
	return ns.FormatMoney(c)
end

local function Ago(t)
	local s = time() - (t or 0)
	if s < 90 then return "just now" end
	if s < 5400 then return math.floor(s / 60 + 0.5) .. " min ago" end
	return math.floor(s / 3600 + 0.5) .. " h ago"
end

-- Reads your listings into `mine`.
local function ReadOwned()
	wipe(mine)
	if not (C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions) then return end
	local sold = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold or 1
	for i = 1, C_AuctionHouse.GetNumOwnedAuctions() or 0 do
		local a = C_AuctionHouse.GetOwnedAuctionInfo(i)
		local id = a and a.itemKey and a.itemKey.itemID
		if id and a.status ~= sold and a.buyoutAmount and a.buyoutAmount > 0 then
			local unit = a.buyoutAmount
			-- commodities report a unit price; a multi-item auction reports
			-- the total, so divide that back down
			-- (only divide when the AH confirms it's not a commodity)
			local info = C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(a.itemKey)
			if info and info.isCommodity == false and (a.quantity or 1) > 1 then
				unit = math.floor(unit / a.quantity)
			end
			local m = mine[id]
			if not m or unit < m.price then
				mine[id] = { price = unit, link = a.itemLink or (m and m.link) }
			end
		end
	end
end

local function Refresh()
	if not panel:IsShown() then return end
	local under, total, pending, lastCheck = {}, 0, 0, nil
	for id, m in pairs(mine) do
		total = total + 1
		local c = competitor[id]
		if not c then
			pending = pending + 1
		else
			if not lastCheck or c.time < lastCheck then lastCheck = c.time end
			if c.price and c.price < m.price then
				under[#under + 1] = { id = id, m = m, c = c }
			end
		end
	end
	table.sort(under, function(a, b) return (a.m.price - a.c.price) > (b.m.price - b.c.price) end)

	local shown = math.min(#under, 12)
	for i = 1, shown do
		local u, r = under[i], Row(i)
		local link = u.m.link or select(2, C_Item.GetItemInfo(u.id)) or ("item:" .. u.id)
		r.link = link
		r.name:SetText(link)
		r.detail:SetText(("yours %s, lowest |cffff6060%s|r  (%s)"):format(Money(u.m.price), Money(u.c.price), Ago(u.c.time)))
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", panel.status, "BOTTOMLEFT", 0, -6 - (i - 1) * 30)
		r:Show()
	end
	for i = shown + 1, #panel.rows do panel.rows[i]:Hide() end

	local text
	if total == 0 then
		text = "You have no active auctions."
	elseif #under == 0 then
		text = ("|cff40ff40None of your %d item%s undercut.|r"):format(total, total == 1 and " is" or "s are")
	else
		text = ("|cffff6060%d of your %d item%s undercut.|r"):format(#under, total, total == 1 and " is" or "s are")
		if #under > shown then text = text .. (" (showing %d)"):format(shown) end
	end
	if pending > 0 then
		text = text .. ("\nChecking %d item%s..."):format(pending, pending == 1 and "" or "s")
	elseif lastCheck then
		text = text .. "\nChecked " .. Ago(lastCheck) .. "."
	end
	panel.status:SetText(text)
	panel:SetHeight(46 + panel.status:GetStringHeight() + shown * 30)
end

-- Searches your auctioned items (all of them, or just ones not checked recently).
local function CheckMine(force)
	if not ns.QueueItemsForced then return end
	local ids, now = {}, time()
	for id in pairs(mine) do
		local c = competitor[id]
		if force or not c or now - c.time > RECHECK then
			ids[#ids + 1] = id
			if force then competitor[id] = nil end
		end
	end
	if #ids > 0 then ns.QueueItemsForced(ids) end
	Refresh()
end

check:SetScript("OnClick", function() CheckMine(true) end)

local function Announce()
	for id, m in pairs(mine) do
		local c = competitor[id]
		if c and c.price and c.price < m.price and announced[id] ~= c.price then
			announced[id] = c.price
			local link = m.link or select(2, C_Item.GetItemInfo(id)) or ("item:" .. id)
			print(("|cff40c0ffMarketScribe|r: %s undercut -- yours %s, lowest %s."):format(link, Money(m.price), Money(c.price)))
		end
	end
end

-- Lowest price from someone other than you, from the search results.
local function OnCommodityResults(id)
	if not id or not mine[id] then return end
	local lowest = false
	for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(id) or 0 do
		local r = C_AuctionHouse.GetCommoditySearchResultInfo(id, i)
		if r and r.unitPrice and (r.quantity or 0) > (r.numOwnerItems or 0) then
			lowest = r.unitPrice
			break
		end
	end
	competitor[id] = { price = lowest, time = time() }
	Announce()
	Refresh()
end

local function OnItemResults(itemKey)
	local id = itemKey and itemKey.itemID
	if not id or not mine[id] then return end
	local lowest = false
	for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0 do
		local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
		if r and r.buyoutAmount and r.buyoutAmount > 0 and not r.containsOwnerItem then
			local unit = r.buyoutAmount
			if (r.quantity or 1) > 1 then unit = math.floor(unit / r.quantity) end
			if not lowest or unit < lowest then lowest = unit end
		end
	end
	-- the same item can come back under several keys (item levels); keep the cheapest
	local old = competitor[id]
	if old and time() - old.time < 5 and old.price and (not lowest or old.price < lowest) then
		lowest = old.price
	end
	competitor[id] = { price = lowest, time = time() }
	Announce()
	Refresh()
end

local function AuctionsTab()
	return AuctionHouseFrame and AuctionHouseFrame.AuctionsFrame
end

local function ShowPanel()
	if ns.Settings().undercutPanel == false then return end
	panel:ClearAllPoints()
	panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, -30)
	panel:Show()
	if C_AuctionHouse.QueryOwnedAuctions then
		pcall(C_AuctionHouse.QueryOwnedAuctions, {})
	end
	ReadOwned()
	CheckMine(false)
end

local hooked
local function HookTab()
	local tab = AuctionsTab()
	if hooked or not tab then return end
	hooked = true
	tab:HookScript("OnShow", ShowPanel)
	tab:HookScript("OnHide", function() panel:Hide() end)
	if tab:IsShown() then ShowPanel() end
end

local watch = CreateFrame("Frame")
watch:RegisterEvent("AUCTION_HOUSE_SHOW")
watch:RegisterEvent("AUCTION_HOUSE_CLOSED")
watch:RegisterEvent("OWNED_AUCTIONS_UPDATED")
watch:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED")
watch:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
watch:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
watch:SetScript("OnEvent", function(_, event, a)
	if event == "AUCTION_HOUSE_SHOW" then
		HookTab()
		-- read your listings in the background so undercuts get announced
		-- in chat even if you never open the Auctions tab
		if C_AuctionHouse.QueryOwnedAuctions then
			C_Timer.After(1, function() pcall(C_AuctionHouse.QueryOwnedAuctions, {}) end)
		end
	elseif event == "AUCTION_HOUSE_CLOSED" then
		panel:Hide()
	elseif event == "OWNED_AUCTIONS_UPDATED" or event == "AUCTION_HOUSE_AUCTION_CREATED" then
		ReadOwned()
		-- a freshly posted price is mine now, so re-search it
		if event == "AUCTION_HOUSE_AUCTION_CREATED" then
			C_Timer.After(1, function() pcall(C_AuctionHouse.QueryOwnedAuctions, {}) end)
		end
		CheckMine(false)
	elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		pcall(OnCommodityResults, a)
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
		pcall(OnItemResults, a)
	end
end)

-- /ms undercut toggles the panel (the chat lines stay on either way)
function ns.ToggleUndercutPanel()
	local s = ns.Settings()
	s.undercutPanel = s.undercutPanel == false
	if s.undercutPanel then
		local tab = AuctionsTab()
		if tab and tab:IsShown() then ShowPanel() end
	else
		panel:Hide()
	end
	return s.undercutPanel
end
