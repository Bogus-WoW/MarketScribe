-- MarketScribe: Scanner.lua
--
-- WoW: Forever runs the modern retail-style Auction House API
-- (C_AuctionHouse), which has no "dump the whole AH" call for individual
-- items/equipment -- Blizzard removed that after Legion. The only thing
-- that DOES support a cheap full price scan is commodities (stackable
-- reagents: ore, herbs, cloth, motes, etc.) via SendSearchQuery + the
-- commodity result getters.
--
-- So this file:
--   1. Queries reagent/output item IDs (see Core.lua's watch list) while the
--      Auction House window is open, respecting Blizzard's query throttle.
--      This only happens on demand -- via the Scan Prices button or
--      /ms scan (ForceScanAll below) -- plus a light opportunistic queue of
--      whatever single item you're actually hovering/looking at (from
--      Tooltip.lua / Professions.lua) if it has no price yet. There's no
--      automatic full-watchlist scan anymore; that was surprising the
--      player with hundreds of queries just from opening the AH.
--   2. Passively records the result of ANY item search -- including ones
--      the player types in manually -- since the same events fire either
--      way. That's the "manual search for the rest" half.

local addonName, ns = ...

local queue = {}
local queuedSet = {}
local lastQueried = {}
-- Seconds before the same item is eligible for another automatic (passive)
-- re-query. This has to comfortably outlast how long a full pass over the
-- whole watch list actually takes: at ~1 query/second, a few hundred items
-- takes several minutes on its own, so a short cooldown here gets eaten
-- just by the scan's own runtime -- items queried early in one scan are
-- already past the cooldown again by the time the scan finishes, let alone
-- by the time you're back from crafting something and reopen the AH.
local REQUERY_COOLDOWN = 1800

local function CanRequery(itemID)
	local t = lastQueried[itemID]
	return not t or (time() - t) >= REQUERY_COOLDOWN
end

-- Tracks whether we're mid-scan, purely so we can print one "scan
-- complete" line instead of one per item.
local wasScanning = false

local function ReportProgress()
	local remaining = #queue
	if remaining > 0 then
		wasScanning = true
	elseif wasScanning then
		wasScanning = false
		print("|cff40c0ffMarketScribe|r: scan complete.")
	end
	if ns.ReportScanProgress then
		ns.ReportScanProgress(remaining)
	end
end

local function QueueItem(itemID, bypassCooldown)
	if ns.neutralAH then
		return false -- nothing is searched at a Neutral AH
	end
	if not itemID or queuedSet[itemID] then
		return false
	end
	-- greys, Bind-on-Pickup and quest items are never on the AH
	if ns.Auctionable and not ns.Auctionable(itemID) then
		return false
	end
	if not bypassCooldown and not CanRequery(itemID) then
		return false
	end
	queuedSet[itemID] = true
	table.insert(queue, itemID)
	return true
end

-- Passive/opportunistic queueing -- used whenever you hover an item with no
-- cached price (Tooltip.lua), or the profession window looks up a recipe's
-- reagents/output (Professions.lua) -- queues just that one item, respecting
-- the per-item cooldown so it doesn't hammer the same item every few
-- seconds. This is the only "automatic" queueing left; it only ever adds
-- the specific item you're actually looking at, never the whole list.
ns.QueueItem = function(itemID)
	if QueueItem(itemID, false) then
		ReportProgress()
	end
end

-- Queue a specific list of item IDs, ignoring the per-item cooldown. Used
-- by companion addons (CrateScribe's "Scan AH" button). Returns how many
-- were actually added.
ns.QueueItemsForced = function(itemIDs)
	local added = 0
	for _, itemID in ipairs(itemIDs or {}) do
		if QueueItem(itemID, true) then
			added = added + 1
		end
	end
	if added > 0 then
		ReportProgress()
	end
	return added
end

-- Explicit "scan everything now": ignores the per-item cooldown, but skips
-- anything that doesn't need it:
--   - vendor prices never change from an AH scan, so there's nothing to
--     refresh there.
--   - commodities already get refreshed for free by the ordinary
--     background scan every time the AH is open (that's the "instant
--     lookup" -- Blizzard hands back the full price list in one query),
--     so re-forcing them here would just waste throttled queries.
-- Everything else -- items with no price on file yet, AND items whose only
-- price came from a past individual auction search -- gets (re)queried, so
-- those stay current instead of only ever being priced once.
-- This is what the Scan Prices button and /ms scan both call.
function ns.ForceScanAll()
	if ns.neutralAH then
		print("|cff40c0ffMarketScribe|r: this is a Neutral Auction House -- scanning is disabled here.")
		return 0
	end
	local added = 0
	for _, itemID in ipairs(ns.GetWatchList()) do
		local price, _, source = ns.GetPrice(itemID)
		local alreadyCovered = price and (source == "commodity" or source == "vendor")
		if not alreadyCovered then
			if QueueItem(itemID, true) then
				added = added + 1
			end
		end
	end
	-- companion addons can add items (SkillScribe: recipes you could learn
	-- and their reagents)
	if ns.ExtraWatch then
		local ok, extra = pcall(ns.ExtraWatch)
		for _, itemID in ipairs(ok and extra or {}) do
			local price, _, source = ns.GetPrice(itemID)
			local alreadyCovered = price and (source == "commodity" or source == "vendor")
			if not alreadyCovered and not ns.IsPriceStale(itemID) then
				alreadyCovered = true -- searched recently enough
			end
			if not alreadyCovered and QueueItem(itemID, true) then
				added = added + 1
			end
		end
	end
	if added > 0 then
		ReportProgress()
	end
	return added
end

-- Stops a scan: drops everything still waiting to be searched. A search that
-- is already out finishes and is saved as usual. Returns how many were dropped.
function ns.StopScan()
	local dropped = #queue
	wipe(queue)
	wipe(queuedSet)
	wasScanning = false
	if ns.ReportScanProgress then
		ns.ReportScanProgress(0)
	end
	return dropped
end

function ns.IsScanning()
	return #queue > 0
end

-- The AH buckets/searches equipment by its FULL item key (itemID + itemLevel
-- + itemSuffix), not just itemID -- a bare {itemID = id} key defaults
-- itemLevel to 0, which matches nothing for a piece of gear that doesn't
-- actually exist at ilvl 0 (that's the "output item never gets a price"
-- bug: reagents/materials have no ilvl variance so the bare key happened to
-- work for them, but a crafted item does). Building the real key needs the
-- item's data cached; if it isn't yet, request it and fall back to the bare
-- key for this attempt (correct for materials, may just miss this one pass
-- for an uncached piece of gear -- better than never trying).
local function BuildItemKey(itemID)
	local level = C_Item and C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(itemID)
	if not level or level == 0 then
		if C_Item and C_Item.RequestLoadItemDataByID then
			C_Item.RequestLoadItemDataByID(itemID)
		end
		return { itemID = itemID }
	end
	if C_AuctionHouse.MakeItemKey then
		return C_AuctionHouse.MakeItemKey(itemID, level, 0, 0)
	end
	return { itemID = itemID, itemLevel = level, itemSuffix = 0, battlePetSpeciesID = 0 }
end

local function Pump()
	if #queue == 0 then
		return
	end
	if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
		return
	end
	if not C_AuctionHouse.IsThrottledMessageSystemReady() then
		return
	end
	local itemID = table.remove(queue, 1)
	queuedSet[itemID] = nil
	lastQueried[itemID] = time()
	-- a search for it is going out now, so it's no longer "wanted"
	if MarketScribeDB.wanted then
		MarketScribeDB.wanted[itemID] = nil
	end
	local ok = pcall(C_AuctionHouse.SendSearchQuery, BuildItemKey(itemID), {}, false)
	if not ok then
		-- Item couldn't be queried this way (e.g. not a valid AH item key); drop it.
	end
	ReportProgress()
end

local function HandleCommodityResults(itemID)
	if not itemID then
		return
	end
	-- Commodity search results are returned cheapest-first; index 1 is the
	-- lowest currently-listed unit price.
	local result = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
	if result and result.unitPrice and result.unitPrice > 0 then
		ns.RecordPrice(itemID, result.unitPrice, "commodity")
	end
	-- total units listed
	if ns.RecordListings then
		local total = C_AuctionHouse.GetCommoditySearchResultsQuantity and C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID)
		if not total then
			total = 0
			local n = C_AuctionHouse.GetNumCommoditySearchResults and C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
			for i = 1, n do
				local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
				total = total + (r and r.quantity or 0)
			end
		end
		ns.RecordListings(itemID, total)
	end
end

local function HandleItemResults(itemKey)
	if not itemKey or not itemKey.itemID then
		return
	end
	local count = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
	local lowest, units = nil, 0
	for i = 1, count do
		local result = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
		if result then
			units = units + (result.quantity or 1)
			if result.buyoutAmount and result.buyoutAmount > 0 then
				if not lowest or result.buyoutAmount < lowest then
					lowest = result.buyoutAmount
				end
			end
		end
	end
	if lowest then
		ns.RecordPrice(itemKey.itemID, lowest, "auction")
	end
	-- results can arrive in pages; only record the count once the list is complete
	local complete = not C_AuctionHouse.HasFullItemSearchResults or C_AuctionHouse.HasFullItemSearchResults(itemKey)
	if ns.RecordListings and complete then
		ns.RecordListings(itemKey.itemID, units)
	end
end

--------------------------------------------------------------------------
-- Neutral Auction House protection. Neutral AHs (Booty Bay, Everlook,
-- Gadgetzan) are a separate market from your faction's AH, so while one is
-- open nothing is read, searched or stored, and the Scan button does nothing.
-- Detection: the auctioneer's faction ("npc" unit) is "Neutral" or not your
-- own; if the client gives no faction for the auctioneer, a Neutral AH town
-- name is used instead. /ms neutral always|off|auto overrides it.
--------------------------------------------------------------------------

local NEUTRAL_TOWNS = { ["Booty Bay"] = true, ["Everlook"] = true, ["Gadgetzan"] = true }

local function DetectNeutral()
	local mode = ns.Settings().neutralMode
	if mode == "off" then
		return false, "protection off"
	elseif mode == "always" then
		return true, "forced on"
	end
	local mine = UnitFactionGroup("player")
	local npcExists = UnitExists and UnitExists("npc")
	local npcFaction = npcExists and UnitFactionGroup("npc") or nil
	if npcFaction == "Neutral" or (npcFaction and npcFaction ~= mine) then
		return true, "auctioneer faction " .. npcFaction
	end
	local zone, sub = GetZoneText and GetZoneText(), GetSubZoneText and GetSubZoneText()
	if not npcFaction and ((zone and NEUTRAL_TOWNS[zone]) or (sub and NEUTRAL_TOWNS[sub])) then
		return true, "auctioneer has no faction, in " .. ((zone and NEUTRAL_TOWNS[zone]) and zone or sub)
	end
	return false, ("auctioneer faction %s, zone %s / %s"):format(tostring(npcFaction), tostring(zone), tostring(sub))
end

function ns.NeutralCommand(arg)
	if arg == "auto" or arg == "always" or arg == "off" then
		ns.Settings().neutralMode = (arg ~= "auto") and arg or nil
		print("|cff40c0ffMarketScribe|r: Neutral AH protection set to " .. arg .. ". Re-open the Auction House for it to apply.")
	else
		local mode = ns.Settings().neutralMode or "auto"
		print(("|cff40c0ffMarketScribe|r: Neutral AH protection: %s. Last check: %s -> %s."):format(
			mode, ns.neutralReason or "AH not opened yet", ns.neutralAH and "BLOCKING (nothing recorded)" or "recording normally"))
		print("  /ms neutral auto|always|off -- always = treat every AH as Neutral, off = no protection.")
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
frame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
frame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")

local ticker

frame:SetScript("OnEvent", function(_, event, a, b)
	if event == "AUCTION_HOUSE_SHOW" then
		ns.neutralAH, ns.neutralReason = DetectNeutral()
		if ns.neutralAH then
			wipe(queue)
			wipe(queuedSet)
			print("|cff40c0ffMarketScribe|r: Neutral Auction House (" .. ns.neutralReason .. ") -- prices are NOT being read or saved here, and tooltips keep showing your faction's prices.")
			if ns.ReportScanProgress then
				ns.ReportScanProgress(0)
			end
			return
		end
		-- No automatic full-watchlist scan anymore -- that's Scan Prices /
		-- /ms scan's job now, entirely on demand. The ticker still needs to
		-- start so that button/command (and the odd item queued just from
		-- hovering it) actually gets pumped once something's in the queue.
		if not ticker then
			ticker = C_Timer.NewTicker(1, Pump)
		end
		-- Items hovered on any character (or earlier on this one) whose
		-- price is missing or over an hour old.
		if ns.Wanted then
			local wanted, added, now = ns.Wanted(), 0, time()
			for itemID, hoveredAt in pairs(wanted) do
				if now - hoveredAt > ns.WANT_EXPIRE then
					wanted[itemID] = nil
				elseif not ns.IsPriceStale(itemID) then
					wanted[itemID] = nil
				elseif QueueItem(itemID, true) then
					added = added + 1
				end
			end
			if added > 0 then
				print(("|cff40c0ffMarketScribe|r: searching %d item(s) you hovered earlier with missing or old prices."):format(added))
				ReportProgress()
			end
		end
	elseif event == "AUCTION_HOUSE_CLOSED" then
		ns.neutralAH = false
		if ticker then
			ticker:Cancel()
			ticker = nil
		end
		wipe(queue)
		wipe(queuedSet)
		wasScanning = false
		if ns.ReportScanProgress then
			ns.ReportScanProgress(0)
		end
	elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
		Pump()
	elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		HandleCommodityResults(a)
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
		HandleItemResults(a)
	end
end)
