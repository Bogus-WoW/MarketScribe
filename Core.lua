-- MarketScribe: Core.lua
-- SavedVariables storage, price lookup/record helpers, the "watch list" of
-- item IDs worth pricing (every reagent and crafted output the player knows
-- a recipe for), and the /ms slash command.

local addonName, ns = ...

-- Public handle so companion addons (e.g. CrateScribe) can read prices
-- and queue scans through the same functions MarketScribe uses itself.
MarketScribeAPI = ns

MarketScribeDB = MarketScribeDB or {}

-- Global (not per-realm) addon settings, e.g. UI positions.
function ns.Settings()
	MarketScribeDB.settings = MarketScribeDB.settings or {}
	return MarketScribeDB.settings
end

--------------------------------------------------------------------------
-- Storage: one price table per faction. In WoW: Forever the realm name is
-- only a technical label, and every realm shares one connected auction house.
--------------------------------------------------------------------------

-- Prices are kept apart per faction AND per ruleset. PvP (the default, and
-- the key every older version used) has no suffix; PvE gets "-PvE". Set it
-- with /ms realmtype pve|pvp. Friends only exchange prices when the keys
-- match, so a PvE player and a PvP player never mix data.
local function IsPvERealm()
	return (ns.Settings().realmType == "pve")
end
ns.IsPvERealm = IsPvERealm

local function RealmKey()
	local faction = UnitFactionGroup("player") or "Neutral"
	return "WoWForever-" .. faction .. (IsPvERealm() and "-PvE" or "")
end
ns.RealmKey = RealmKey

-- Up to 1.1.x, prices were stored per realm. Fold those tables for this faction
-- into the shared one, keeping the newest value for each item.
local function MergeOldStores(key, store)
	if key:find("%-PvE$") then
		return -- old per-realm data was never PvE-specific; it belongs to the default store
	end
	local faction = key:match("%-(%a+)$")
	local oldKeys = {}
	for k, old in pairs(MarketScribeDB) do
		if k ~= key and type(k) == "string" and type(old) == "table" and old.prices
			and k:match("%-(%a+)$") == faction then
			oldKeys[#oldKeys + 1] = k
		end
	end
	for _, k in ipairs(oldKeys) do
		local old = MarketScribeDB[k]
		for id, p in pairs(old.prices or {}) do
			local mine = store.prices[id]
			if not mine or (mine.time or 0) < (p.time or 0) then store.prices[id] = p end
		end
		for id, v in pairs(old.vendor or {}) do
			if store.vendor[id] == nil then store.vendor[id] = v end
		end
		for id, l in pairs(old.listings or {}) do
			store.listings = store.listings or {}
			local mine = store.listings[id]
			if not mine or (mine.t or 0) < (l.t or 0) then store.listings[id] = l end
		end
		MarketScribeDB[k] = nil
	end
end

local function Store()
	local key = RealmKey()
	local store = MarketScribeDB[key]
	if not store then
		store = { prices = {}, vendor = {} }
		MarketScribeDB[key] = store
	end
	store.prices = store.prices or {}
	store.vendor = store.vendor or {}
	if not ns.oldStoresMerged then
		ns.oldStoresMerged = true
		MergeOldStores(key, store)
	end
	return store
end
ns.Store = Store

-- Auction House price, copper per single unit of the item.
function ns.RecordPrice(itemID, price, source)
	if ns.neutralAH then
		return -- Neutral AH prices are a different market; never stored
	end
	if not itemID or not price or price <= 0 then
		return
	end
	local store = Store()
	store.prices[itemID] = { price = price, time = time(), source = source }
	if ns.RecordHistory then ns.RecordHistory(itemID, price, store.prices[itemID].time, 0) end
	if MarketScribeDB.wanted then
		MarketScribeDB.wanted[itemID] = nil
	end
end

--------------------------------------------------------------------------
-- Listing counts: how many units were on the AH the last time we searched
-- for an item (0 = searched, nothing listed). Kept in their own table so
-- the price table and price sharing don't change. scans counts how many
-- searches have been recorded, empty how many of them found nothing.
--------------------------------------------------------------------------

function ns.RecordListings(itemID, quantity)
	if ns.neutralAH then
		return -- Neutral AH listings are a different market; never stored
	end
	if not itemID or not quantity or quantity < 0 then
		return
	end
	local store = Store()
	store.listings = store.listings or {}
	local l = store.listings[itemID] or { scans = 0, empty = 0 }
	-- the AH fires several updates per search; count one scan per minute at most
	local newScan = not l.t or (time() - l.t) >= 60
	l.n, l.t = quantity, time()
	if newScan then
		l.scans = (l.scans or 0) + 1
		if quantity == 0 then l.empty = (l.empty or 0) + 1 end
	end
	store.listings[itemID] = l
	if ns.HistoryListing then ns.HistoryListing(itemID, quantity) end
end

-- Returns units listed at the last search, when that was, and how many
-- searches (and empty ones) we've recorded. nil if never searched.
function ns.GetListings(itemID)
	local store = Store()
	local l = itemID and store.listings and store.listings[itemID]
	if l then
		return l.n, l.t, l.scans, l.empty
	end
end

-- Removes AH prices and listing counts that were recorded in the last
-- `hours` hours by this client (prices received from friends are kept).
-- Returns how many prices and listing records were removed.
function ns.PurgeRecent(hours)
	local store = Store()
	local cutoff = time() - hours * 3600
	local p, l = 0, 0
	for id, e in pairs(store.prices) do
		if (e.time or 0) >= cutoff and not e.from then
			store.prices[id] = nil
			p = p + 1
		end
	end
	for id, e in pairs(store.listings or {}) do
		if (e.t or 0) >= cutoff then
			store.listings[id] = nil
			l = l + 1
		end
	end
	return p, l
end

--------------------------------------------------------------------------
-- "Wanted" list: items you've hovered whose AH price is missing or older
-- than an hour. It's saved account-wide, so an item you look at on one
-- character gets searched the next time ANY of your characters opens the
-- Auction House (see Scanner.lua). Entries are dropped once a search for
-- them has been sent, or after a week.
--------------------------------------------------------------------------

ns.WANT_STALE = 3600       -- re-search prices older than this
ns.WANT_EXPIRE = 7 * 86400 -- forget hovers older than this

local function Wanted()
	MarketScribeDB.wanted = MarketScribeDB.wanted or {}
	return MarketScribeDB.wanted
end
ns.Wanted = Wanted

-- True if this item's AH price is missing or older than WANT_STALE.
function ns.IsPriceStale(itemID)
	local market = Store().prices[itemID]
	return not market or (time() - (market.time or 0)) >= ns.WANT_STALE
end

-- False for things that can never be on the Auction House: grey junk,
-- Bind-on-Pickup and quest items. Unknown items (not cached yet) count as
-- auctionable, so nothing is skipped by mistake.
function ns.Auctionable(itemID)
	local _, _, quality, _, _, _, _, _, _, _, _, _, _, bindType = C_Item.GetItemInfo(itemID)
	if quality == 0 or bindType == 1 or bindType == 4 then
		return false
	end
	return true
end

function ns.NoteWanted(itemID)
	if not itemID then
		return
	end
	local quality = select(3, C_Item.GetItemInfo(itemID))
	if quality == nil or not ns.Auctionable(itemID) then
		return
	end
	if ns.IsPriceStale(itemID) then
		Wanted()[itemID] = time()
	end
end

-- Vendor (merchant) price, copper per single unit. Vendor prices don't go
-- stale the way AH prices do, so they're kept separately and always win
-- when they're cheaper than whatever's cached from the AH.
function ns.RecordVendorPrice(itemID, price)
	if not itemID or not price or price <= 0 then
		return
	end
	Store().vendor[itemID] = price
end

-- Returns price (copper), the time() it was captured (nil for vendor
-- prices), and its source ("vendor", "commodity" or "auction"), or nil if
-- we've never seen this item anywhere.
function ns.GetPrice(itemID)
	if not itemID then
		return nil
	end
	local store = Store()
	local market = store.prices[itemID]
	local vendor = store.vendor[itemID]
	if vendor and (not market or vendor <= market.price) then
		return vendor, nil, "vendor"
	elseif market then
		return market.price, market.time, market.source
	end
	return nil
end

-- The AH price on file, ignoring any vendor price (for "what would this sell
-- for" rather than "what does this cost me").
function ns.GetMarketPrice(itemID)
	local market = itemID and Store().prices[itemID]
	if market then
		return market.price, market.time, market.source
	end
end

-- The Auction House keeps 5% of every sale. Every sale value MarketScribe
-- (and SkillScribe, through GetDisenchantEV and GetRecipeProfit) works out
-- is net of it; costs of buying are not.
ns.AH_CUT = 0.95

-- What one unit of the item sells for on the AH after the cut, true when
-- that is what it returned. Falls back to whatever price is on file (not cut,
-- since that is not an AH sale) when the AH price is unknown.
function ns.GetSellPrice(itemID)
	local m = ns.GetMarketPrice(itemID)
	if m then
		return m * ns.AH_CUT, true
	end
	return (ns.GetPrice(itemID)), false
end

-- Removes stored vendor prices without touching AH prices. `query` is an
-- item link, an itemID, or text matched against item names (e.g. "raw "
-- for all the raw fish). Returns removed names and how many entries were
-- skipped because their names aren't cached yet.
function ns.ForgetVendorPrices(query)
	local vendor = Store().vendor
	local removed, uncached = {}, 0
	local exactID = tonumber(query:match("item:(%d+)") or query:match("^(%d+)$"))
	local needle = query:match("%[(.-)%]") or query
	for itemID in pairs(vendor) do
		local name
		if C_Item and C_Item.GetItemInfo then
			name = C_Item.GetItemInfo(itemID)
		elseif GetItemInfo then
			name = GetItemInfo(itemID)
		end
		local hit
		if exactID then
			hit = itemID == exactID
		elseif name then
			hit = name:lower():find(needle, 1, true) ~= nil
		else
			uncached = uncached + 1
			if C_Item and C_Item.RequestLoadItemDataByID then
				C_Item.RequestLoadItemDataByID(itemID)
			end
		end
		if hit then
			vendor[itemID] = nil
			table.insert(removed, name or ("Item #" .. itemID))
		end
	end
	table.sort(removed)
	return removed, uncached
end

--------------------------------------------------------------------------
-- Price check: /ms price <item link, itemID or part of a name>. Works
-- anywhere (no Auction House needed) and prints what is on file.
--------------------------------------------------------------------------

local function ItemNameLink(itemID)
	local name, link
	if C_Item and C_Item.GetItemInfo then
		name, link = C_Item.GetItemInfo(itemID)
	elseif GetItemInfo then
		name, link = GetItemInfo(itemID)
	end
	return name, link
end

-- One line of text for an item: AH price (age, listings, who sent it) and
-- vendor price, whichever are on file.
local function PriceLine(itemID, name, link)
	local store = Store()
	local market, vendor = store.prices[itemID], store.vendor[itemID]
	local parts = {}
	if market then
		local detail = { ns.FormatAge(market.time) }
		local listed = ns.GetListings and ns.GetListings(itemID)
		if listed then
			detail[#detail + 1] = ("%d listed"):format(listed)
		end
		if market.from then
			detail[#detail + 1] = "from " .. market.from
		end
		if time() - (market.time or 0) >= 86400 then
			detail[#detail + 1] = "|cffff9933old|r"
		end
		parts[#parts + 1] = ("AH %s%s (%s)"):format(ns.FormatMoney(market.price),
			market.source == "commodity" and " each" or "", table.concat(detail, ", "))
	end
	if vendor then
		parts[#parts + 1] = "vendor " .. ns.FormatMoney(vendor)
	end
	if #parts == 0 then
		parts[1] = "|cff888888no price on file|r"
	end
	return ("  %s: %s"):format(link or name or ("Item #" .. itemID), table.concat(parts, "  |  "))
end

function ns.PriceCheck(query)
	local tag = "|cff40c0ffMarketScribe|r: "
	query = (query or ""):match("^%s*(.-)%s*$")
	query = query:match('^"(.*)"$') or query
	if query == "" then
		print(tag .. "usage: /ms price <item link, itemID or part of a name>  (shift-click an item to insert its link)")
		return
	end

	local exactID = tonumber(query:match("item:(%d+)") or query:match("^(%d+)$"))
	if exactID then
		local name, link = ItemNameLink(exactID)
		print(tag .. "price check")
		print(PriceLine(exactID, name, link))
		return
	end

	local needle = (query:match("%[(.-)%]") or query):lower()
	local store = Store()
	local seen, matches, uncached = {}, {}, 0
	local function consider(itemID)
		if seen[itemID] then
			return
		end
		seen[itemID] = true
		local name, link = ItemNameLink(itemID)
		if name then
			if name:lower():find(needle, 1, true) then
				matches[#matches + 1] = { id = itemID, name = name, link = link }
			end
		else
			uncached = uncached + 1
			if C_Item and C_Item.RequestLoadItemDataByID then
				C_Item.RequestLoadItemDataByID(itemID)
			end
		end
	end
	for itemID in pairs(store.prices) do consider(itemID) end
	for itemID in pairs(store.vendor) do consider(itemID) end

	table.sort(matches, function(a, b) return a.name < b.name end)
	if #matches == 0 then
		print(tag .. ('nothing on file matching "%s".'):format(query))
	else
		local shown = math.min(#matches, 8)
		print(tag .. ("price check: %d match%s for \"%s\""):format(#matches, #matches == 1 and "" or "es", query))
		for i = 1, shown do
			print(PriceLine(matches[i].id, matches[i].name, matches[i].link))
		end
		if #matches > shown then
			print(("  ...and %d more -- type more of the name to narrow it down."):format(#matches - shown))
		end
	end
	if uncached > 0 then
		print(("  %d items on file had no name cached yet -- run the same command again in a few seconds to include them."):format(uncached))
	end
end

--------------------------------------------------------------------------
-- Formatting helpers
--------------------------------------------------------------------------

-- Compact decimal money format: 45c stays "45c", 165c becomes "1.65s",
-- 16500c (165s) becomes "1.65g". Whichever unit is used, values divide
-- evenly into it (each unit is exactly 100x the one below), so 2 decimal
-- places never lose more than sub-copper precision -- except when
-- displaying in gold, where any leftover copper below the nearest silver
-- is rounded off.
function ns.FormatMoney(copper)
	copper = math.floor(math.abs(copper or 0) + 0.5)

	local value, unit
	if copper >= 10000 then
		value, unit = copper / 10000, "g"
	elseif copper >= 100 then
		value, unit = copper / 100, "s"
	else
		return copper .. "c"
	end

	local text = string.format("%.2f", value)
	text = text:gsub("0+$", "")
	text = text:gsub("%.$", "")
	return text .. unit
end

function ns.FormatAge(t)
	if not t then
		return "never"
	end
	local seconds = time() - t
	if seconds < 60 then
		return "just now"
	elseif seconds < 3600 then
		return math.floor(seconds / 60) .. "m ago"
	elseif seconds < 86400 then
		return math.floor(seconds / 3600) .. "h ago"
	else
		return math.floor(seconds / 86400) .. "d ago"
	end
end

--------------------------------------------------------------------------
-- Resolving what a recipe actually produces.
--------------------------------------------------------------------------

-- schematic.outputItemID is only set for recipes with one fixed result.
-- Modern crafting's quality-variable recipes (most of them, in practice)
-- leave it nil/0, so falling back to GetRecipeOutputItemData -- the same
-- call Blizzard's own crafting UI uses to show the output icon -- is what
-- actually resolves the item for those.
function ns.GetRecipeOutputItemID(recipeID, schematic)
	if schematic and schematic.outputItemID and schematic.outputItemID > 0 then
		return schematic.outputItemID
	end
	if not (C_TradeSkillUI and C_TradeSkillUI.GetRecipeOutputItemData) then
		return nil
	end
	local ok, info = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
	if ok and info and info.itemID and info.itemID > 0 then
		return info.itemID
	end
	return nil
end

--------------------------------------------------------------------------
-- Watch list: every reagent + crafted-output item ID for recipes the
-- player currently knows. Rebuilt lazily, invalidated when profession
-- data changes.
--------------------------------------------------------------------------

local watchList
-- outputItemID -> { recipeID, ... }: every known recipe that produces a
-- given item, so "what would it cost to make this myself" can be answered
-- for any item that happens to be a crafted output, not just while looking
-- at the profession window. Built alongside watchList, invalidated with it.
local outputRecipes

function ns.GetWatchList()
	if watchList then
		return watchList
	end
	watchList = {}
	outputRecipes = {}
	local seen = {}
	if not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs) then
		return watchList
	end

	local ok, recipeIDs = pcall(C_TradeSkillUI.GetAllRecipeIDs)
	if not ok or not recipeIDs then
		return watchList
	end

	for _, recipeID in ipairs(recipeIDs) do
		local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
		if schematic then
			local outputItemID = ns.GetRecipeOutputItemID(recipeID, schematic)
			if outputItemID then
				if not seen[outputItemID] then
					seen[outputItemID] = true
					table.insert(watchList, outputItemID)
				end
				outputRecipes[outputItemID] = outputRecipes[outputItemID] or {}
				table.insert(outputRecipes[outputItemID], recipeID)
			end
			if schematic.reagentSlotSchematics then
				for _, slot in ipairs(schematic.reagentSlotSchematics) do
					local isBasic = slot.reagentType == Enum.CraftingReagentType.Basic
					local isRequiredOther = (not isBasic) and slot.required
					if (isBasic or isRequiredOther) and slot.reagents then
						for _, option in ipairs(slot.reagents) do
							if option.itemID and not seen[option.itemID] then
								seen[option.itemID] = true
								table.insert(watchList, option.itemID)
							end
						end
					end
				end
			end
		end
	end
	return watchList
end

-- Every known recipeID that produces the given item, or nil if it isn't a
-- crafted output of anything you currently know. Forces the watch list to
-- build if it hasn't yet, since that's what actually walks your recipes.
function ns.GetRecipesForOutput(itemID)
	if not itemID then
		return nil
	end
	ns.GetWatchList()
	return outputRecipes and outputRecipes[itemID]
end

function ns.InvalidateWatchList()
	watchList = nil
	outputRecipes = nil
end

--------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------

SLASH_MARKETSCRIBE1 = "/ms"
SlashCmdList.MARKETSCRIBE = function(msg)
	msg = (msg or ""):lower()
	msg = msg:match("^%s*(.-)%s*$") -- trim

	if msg == "scan stop" or msg == "stop" then
		if ns.IsScanning and ns.IsScanning() then
			print(("|cff40c0ffMarketScribe|r: scan stopped (%d items not searched)."):format(ns.StopScan()))
		else
			print("|cff40c0ffMarketScribe|r: no scan is running.")
		end
	elseif msg == "scan" then
		if ns.IsScanning and ns.IsScanning() then
			print("|cff40c0ffMarketScribe|r: a scan is already running. /ms scan stop (or click the button) stops it.")
			return
		end
		ns.InvalidateWatchList()
		if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
			print("|cff40c0ffMarketScribe|r: open the Auction House first, then use /ms scan or the Scan Prices button.")
			return
		end
		local added = ns.ForceScanAll and ns.ForceScanAll() or 0
		if ns.neutralAH then
			-- ForceScanAll already explained why nothing was queued
		elseif added == 0 then
			print("|cff40c0ffMarketScribe|r: nothing to scan -- everything left is priced by vendor or commodity data already.")
		else
			print(("|cff40c0ffMarketScribe|r: scanning %d items (skipping vendor/commodity prices, which don't need it)."):format(added))
		end
	elseif msg == "export" then
		if ns.ShowExport then
			ns.ShowExport()
		end
	elseif msg == "debug vendor" then
		if not (GetMerchantNumItems and GetMerchantItemID and C_MerchantFrame and C_MerchantFrame.GetItemInfo) then
			print("|cff40c0ffMarketScribe|r: no merchant API available right now.")
		elseif not (MerchantFrame and MerchantFrame:IsShown()) then
			print("|cff40c0ffMarketScribe|r: open a vendor window first, then use /ms debug vendor.")
		else
			local numItems = GetMerchantNumItems() or 0
			print(("|cff40c0ffMarketScribe|r debug: %d merchant items"):format(numItems))
			for index = 1, numItems do
				local itemID = GetMerchantItemID(index)
				local info = C_MerchantFrame.GetItemInfo(index)
				if itemID and info then
					print(("  #%d itemID=%s price=%s stackCount=%s numAvailable=%s extendedCost=%s"):format(
						index, tostring(itemID), tostring(info.price), tostring(info.stackCount),
						tostring(info.numAvailable), tostring(info.hasExtendedCost)))
				end
			end
		end
	elseif msg:sub(1, 5) == "debug" then
		local search = msg:sub(6):match("^%s*(.-)%s*$")
		if search == "" then
			print("|cff40c0ffMarketScribe|r: usage: /ms debug <recipe name or part of it>, or /ms debug vendor")
		elseif not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetRecipeInfo) then
			print("|cff40c0ffMarketScribe|r: no profession data available right now.")
		else
			local ok, recipeIDs = pcall(C_TradeSkillUI.GetAllRecipeIDs)
			local found = 0
			if ok and recipeIDs then
				local needle = search:lower()
				for _, recipeID in ipairs(recipeIDs) do
					local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
					local name = info and info.name
					if name and name:lower():find(needle, 1, true) then
						found = found + 1
						local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
						print(("|cff40c0ffMarketScribe|r debug: %s (recipeID %d)"):format(name, recipeID))
						local outputItemID = ns.GetRecipeOutputItemID(recipeID, schematic)
						print(("  output: resolved itemID=%s (schematic.outputItemID=%s)"):format(
							tostring(outputItemID), tostring(schematic and schematic.outputItemID)))
						if schematic and schematic.reagentSlotSchematics then
							for i, slot in ipairs(schematic.reagentSlotSchematics) do
								local ids = {}
								for _, option in ipairs(slot.reagents or {}) do
									table.insert(ids, tostring(option.itemID))
								end
								print(("  slot %d: reagentType=%s required=%s qty=%s items={%s}"):format(
									i, tostring(slot.reagentType), tostring(slot.required),
									tostring(slot.quantityRequired), table.concat(ids, ",")))
							end
						end
					end
				end
			end
			if found == 0 then
				print(("|cff40c0ffMarketScribe|r: no known recipe matching \"%s\"."):format(search))
			end
		end
	elseif msg:match("^realmtype%f[%s%z]") then
		local want = msg:match("^realmtype%s+(%a+)")
		local tag = "|cff40c0ffMarketScribe|r: "
		if want == "pve" or want == "pvp" then
			ns.Settings().realmType = want
			print(tag .. ("ruleset set to %s. Prices are now stored and shared as \"%s\" (separate from the other ruleset's prices)."):format(want:upper(), ns.RealmKey()))
		else
			print(tag .. ("ruleset is %s (storing as \"%s\"). Change with /ms realmtype pve|pvp -- prices are kept separate per ruleset and per faction, and only shared with friends on the same one."):format(IsPvERealm() and "PvE" or "PvP", ns.RealmKey()))
		end
	elseif msg:match("^show%f[%s%z]") then
		ns.ToggleGraph(msg:match("^show%s*(.*)$"))
	elseif msg:match("^price%f[%s%z]") or msg:match("^pricecheck%f[%s%z]") or msg:match("^pc%f[%s%z]") then
		ns.PriceCheck(msg:gsub("^%S+", "", 1))
	elseif msg:sub(1, 13) == "forget vendor" then
		local query = msg:sub(14):match("^%s*(.-)%s*$")
		-- Quotes keep surrounding spaces: /ms forget vendor "raw " matches
		-- "Raw Rockscale Cod" but not "Rawhide Boots".
		query = query:match('^"(.*)"$') or query
		if query == "" then
			print("|cff40c0ffMarketScribe|r: usage: /ms forget vendor <item link, itemID or part of a name>  (e.g. /ms forget vendor \"raw \" for all raw fish)")
		else
			local removed, uncached = ns.ForgetVendorPrices(query)
			print(("|cff40c0ffMarketScribe|r: removed %d vendor price(s); AH prices kept."):format(#removed))
			for _, name in ipairs(removed) do
				print("  " .. name)
			end
			if uncached > 0 and not query:match("item:%d+") and not query:match("^%d+$") then
				print(("  %d vendor entries had no item name cached yet -- run the same command again in a few seconds to check those too."):format(uncached))
			end
		end
	elseif msg:sub(1, 5) == "share" then
		if ns.ShareCommand then
			ns.ShareCommand(msg:sub(6):match("^%s*(.-)%s*$"))
		end
	elseif msg == "de" or msg:sub(1, 3) == "de " then
		if ns.DECommand then
			ns.DECommand(msg:sub(3):match("^%s*(.-)%s*$"))
		end
	elseif msg == "undercut" then
		if ns.ToggleUndercutPanel then
			local on = ns.ToggleUndercutPanel()
			print("|cff40c0ffMarketScribe|r: undercut panel on the Auctions tab " .. (on and "on." or "off (chat alerts still on)."))
		end
	elseif msg:sub(1, 7) == "neutral" then
		if ns.NeutralCommand then
			ns.NeutralCommand(msg:sub(8):match("^%s*(.-)%s*$"))
		end
	elseif msg:sub(1, 5) == "purge" then
		local hours = tonumber(msg:sub(6):match("^%s*(.-)%s*$"))
		if not hours or hours <= 0 then
			print("|cff40c0ffMarketScribe|r: usage: /ms purge <hours> -- removes the AH prices and listing counts you recorded in the last <hours> hours (prices from friends are kept).")
		else
			local p, l = ns.PurgeRecent(hours)
			if ns.PurgeHistory then ns.PurgeHistory(hours) end
			print(("|cff40c0ffMarketScribe|r: purged %d price(s) and %d listing record(s) recorded in the last %s hour(s)."):format(p, l, tostring(hours)))
		end
	elseif msg == "status" then
		local store = Store()
		local ahCount, vendorCount = 0, 0
		for _ in pairs(store.prices) do
			ahCount = ahCount + 1
		end
		for _ in pairs(store.vendor) do
			vendorCount = vendorCount + 1
		end
		print(("|cff40c0ffMarketScribe|r: %d AH prices and %d vendor prices cached for %s."):format(ahCount, vendorCount, RealmKey()))
	else
		print("|cff40c0ffMarketScribe|r commands: /ms realmtype pve|pvp (keep PvE and PvP prices apart), /ms price <item link, itemID or part of a name> (price check, no AH needed; also /ms pc), /ms scan (queue known reagents/outputs while the AH is open; /ms scan stop or clicking the button while it runs stops it), /ms status, /ms undercut (toggle the undercut panel on the Auctions tab), /ms de (Disenchant Scan window: gear that is cheaper than its disenchant value; /ms de scan, /ms de min <silver>), /ms show [item link, itemID or part of a name] (price history window), /ms export (get all cached prices as JSON), /ms debug <recipe name> (dump raw reagent slot data), /ms debug vendor (dump the open merchant's raw item data), /ms forget vendor <item/name text> (drop stored vendor prices, keep AH prices), /ms share list|now|off|on|debug (swap prices with friends on your Friends list), /ms neutral [auto|always|off] (Neutral AH protection), /ms purge <hours> (delete prices/listings recorded in the last N hours), /ms share purge [friend] (delete prices received from friends)")
	end
end

--------------------------------------------------------------------------
-- Invalidate the watch list whenever profession data changes.
--------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
loader:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED")
loader:RegisterEvent("NEW_RECIPE_LEARNED")
loader:SetScript("OnEvent", function()
	ns.InvalidateWatchList()
end)
