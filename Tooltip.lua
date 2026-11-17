-- MarketScribe: Tooltip.lua
--
-- Forever uses the modern tooltip system (TooltipDataProcessor +
-- TooltipUtil), not the old OnTooltipSetItem script hook.

local addonName, ns = ...

-- Appends a colored "+/-X vs <label>" line, or nothing if the compare value
-- isn't known. `incomplete` adds the same grey "~" marker used elsewhere for
-- a value that's a floor, not a confirmed number.
local function AddCompareLine(tooltip, deValue, compareValue, label, incomplete)
	if not compareValue then
		return
	end
	local diff = deValue - compareValue
	local text
	if diff > 0 then
		text = ("  |cff40ff40+%s vs %s|r"):format(ns.FormatMoney(diff), label)
	elseif diff < 0 then
		text = ("  |cffff4040-%s vs %s|r"):format(ns.FormatMoney(-diff), label)
	else
		text = ("  |cff888888+0 vs %s|r"):format(label)
	end
	if incomplete then
		text = text .. " |cff888888~|r"
	end
	tooltip:AddLine(text)
end

local function OnItemTooltip(tooltip)
	if not (TooltipUtil and TooltipUtil.GetDisplayedItem) then
		return
	end
	local _, _, id = TooltipUtil.GetDisplayedItem(tooltip)
	if not id then
		return
	end

	local price, seenAt, source = ns.GetPrice(id)
	-- Remember items whose AH price is missing or over an hour old, so the
	-- next character to open the Auction House searches for them.
	if ns.NoteWanted then
		ns.NoteWanted(id)
	end
	if price and ns.IsPriceStale and ns.IsPriceStale(id) and ns.QueueItem and not (source == "vendor" and not ns.GetMarketPrice(id)) then
		ns.QueueItem(id)
	end
	if price then
		local label
		if source == "vendor" then
			label = "Vendor"
		elseif source == "commodity" then
			label = "AH (commodity)"
		else
			label = "AH"
		end

		local suffix = ""
		local listed = ns.GetListings and ns.GetListings(id)
		local listedText = listed and (", %d listed"):format(listed) or ""
		if source ~= "vendor" then
			suffix = (" |cff888888(%s%s)|r"):format(ns.FormatAge(seenAt), listedText)
		end

		tooltip:AddLine(("|cff40c0ffMarketScribe|r %s: %s%s"):format(label, ns.FormatMoney(price), suffix))

		-- When a (cheaper) vendor price wins, still show the AH price if we
		-- have one -- that's what the item actually sells for.
		if source == "vendor" and ns.GetMarketPrice then
			local mPrice, mTime, mSource = ns.GetMarketPrice(id)
			if mPrice then
				tooltip:AddLine(("|cff40c0ffMarketScribe|r %s: %s |cff888888(%s%s)|r"):format(
					mSource == "commodity" and "AH (commodity)" or "AH", ns.FormatMoney(mPrice), ns.FormatAge(mTime), listedText))
			end
		end
	else
		-- We don't have a price for this item yet. Queue it (respecting the
		-- normal per-item cooldown) so it gets picked up next time the
		-- Auction House is open -- previously, hovering an item was a pure
		-- read with no side effect, so anything not already on the watch
		-- list (e.g. a reagent slot glanced at inside the crafting window,
		-- rather than the recipe row itself) never got queued at all.
		-- (greys, Bind-on-Pickup and quest items are never on the AH: no note)
		if not (ns.Auctionable and not ns.Auctionable(id)) then
			if ns.QueueItem then
				ns.QueueItem(id)
			end
			tooltip:AddLine("|cff888888MarketScribe: no price yet -- queued, check back after opening the Auction House|r")
		end
	end

	-- Disenchant estimate, for weapon/armor greens and blues. Shown
	-- alongside (not instead of) the price line above -- see Disenchant.lua
	-- for the reconstructed-from-community-data caveat.
	if ns.GetDisenchantEV then
		local deValue, complete = ns.GetDisenchantEV(id)
		if deValue then
			local text = ("|cff40c0ffMarketScribe|r Disenchant (avg): %s"):format(ns.FormatMoney(deValue))
			if not complete then
				text = text .. " |cff888888~|r"
			end
			tooltip:AddLine(text)

			-- vs buying this item outright (AH or vendor, whichever price we
			-- have on file for it).
			if price and price > 0 then
				AddCompareLine(tooltip, deValue, price, "buying")
			end

			-- vs crafting it yourself, if it's the output of a recipe you
			-- know -- costed the same way the profession window's profit
			-- column is, so it's directly comparable per single item made.
			if ns.GetRecipesForOutput and ns.GetRecipeCostPerItem then
				local recipeIDs = ns.GetRecipesForOutput(id)
				if recipeIDs then
					local cheapestCost, costIncomplete
					for _, recipeID in ipairs(recipeIDs) do
						local cost, costComplete = ns.GetRecipeCostPerItem(recipeID)
						if cost and (not cheapestCost or cost < cheapestCost) then
							cheapestCost = cost
							costIncomplete = not costComplete
						end
					end
					AddCompareLine(tooltip, deValue, cheapestCost, "crafting", costIncomplete)
				end
			end
		end
	end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
end

--------------------------------------------------------------------------
-- Gold on all your characters
--
-- Every character's gold is remembered (account-wide). Hovering the gold in
-- your bags lists each character and the total.
--------------------------------------------------------------------------

local function GoldDB()
	MarketScribeDB.gold = MarketScribeDB.gold or {}
	return MarketScribeDB.gold
end

-- Forever characters have a first and a last name, and first names aren't
-- unique (two characters can share one), so characters are kept
-- by their GUID, which is unique, with the name stored for display.
local function NoSpaces(s) return (s or ""):gsub("[%s%-']", ""):lower() end

-- Your last name, if the client gives it to addons anywhere we can find.
local function LastName()
	local name, second = UnitName("player")
	local realm = NoSpaces(GetRealmName())
	local function ok(x)
		x = x and tostring(x)
		return x and x ~= "" and NoSpaces(x) ~= realm and x ~= name and x or nil
	end
	if ok(second) then return second end
	if GetUnitName then
		local full = GetUnitName("player", true)
		local last = full and (full:match("^[^%s%-]+[%s%-](.+)$"))
		if ok(last) then return last end
	end
	if UnitFullName then
		local _, r = UnitFullName("player")
		if ok(r) then return r end
	end
end

-- `confirmed` is true when the game just told us the gold changed. Otherwise
-- a 0 is ignored if we already know a higher amount: while logging in or out
-- the game briefly reports 0 gold.
local function SaveMyGold(confirmed)
	local realm, name, guid = GetRealmName(), UnitName("player"), UnitGUID and UnitGUID("player")
	if not (realm and name) then return end
	local key = guid or name
	local money = GetMoney() or 0
	local _, class = UnitClass("player")
	local db = GoldDB()
	db[realm] = db[realm] or {}
	local old = db[realm][key]
	if money == 0 and not confirmed and old and (old.money or 0) > 0 then return end
	-- the old name-only entry is ambiguous (two characters with one first name overwrote each other): drop it
	local legacy = db[realm][name]
	if guid and legacy and not legacy.guid then db[realm][name] = nil end
	db[realm][key] = { money = money, class = class, faction = UnitFactionGroup("player"), time = time(),
		name = name, last = LastName() or (old and old.last), level = UnitLevel("player"), guid = guid }
end

local function GoldTooltip(owner)
	SaveMyGold()
	GameTooltip:SetOwner(owner, "ANCHOR_TOPLEFT")
	GameTooltip:AddLine("|cff40c0ffMarketScribe|r: gold on your characters")
	local total = 0
	local realms = {}
	for realm in pairs(GoldDB()) do realms[#realms + 1] = realm end
	table.sort(realms)
	local myGuid = UnitGUID and UnitGUID("player")
	for _, realm in ipairs(realms) do
		local chars, seen = {}, {}
		for key, c in pairs(GoldDB()[realm]) do
			local label = c.name or key
			if c.last then label = label .. " " .. c.last end
			chars[#chars + 1] = { key = key, c = c, label = label }
			seen[label] = (seen[label] or 0) + 1
		end
		-- same name and no last name known: tell them apart by class and level
		for _, e in ipairs(chars) do
			if seen[e.label] > 1 then
				local cls = e.c.class and ((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[e.c.class]) or e.c.class) or "?"
				e.label = ("%s (%s%s)"):format(e.label, cls, e.c.level and (" " .. e.c.level) or "")
			end
		end
		table.sort(chars, function(a, b) return a.c.money > b.c.money end)
		if #realms > 1 then GameTooltip:AddLine(realm, 0.6, 0.6, 0.6) end
		for _, e in ipairs(chars) do
			local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.c.class]
			local label = (myGuid and e.key == myGuid) and (e.label .. " (you)") or e.label
			GameTooltip:AddDoubleLine(label, ns.FormatMoney(e.c.money),
				color and color.r or 1, color and color.g or 1, color and color.b or 1, 1, 1, 1)
			total = total + e.c.money
		end
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddDoubleLine("Total", ns.FormatMoney(total), 1, 0.82, 0, 1, 0.82, 0)
	GameTooltip:Show()
end

local hooked = {}
local function HookMoneyFrame(frame)
	if not frame or hooked[frame] then return end
	hooked[frame] = true
	local parts = { frame }
	for _, key in ipairs({ "GoldButton", "SilverButton", "CopperButton" }) do
		local b = frame[key] or (frame:GetName() and _G[frame:GetName() .. key])
		if b then parts[#parts + 1] = b end
	end
	for _, f in ipairs(parts) do
		if f.EnableMouse then f:EnableMouse(true) end
		f:HookScript("OnEnter", function(self) GoldTooltip(self) end)
		f:HookScript("OnLeave", function() GameTooltip:Hide() end)
	end
end

local function HookBagMoney()
	HookMoneyFrame(_G.ContainerFrame1MoneyFrame)
	if ContainerFrameCombinedBags then
		HookMoneyFrame(ContainerFrameCombinedBags.MoneyFrame)
	end
	if ContainerFrame1 and ContainerFrame1.MoneyFrame then
		HookMoneyFrame(ContainerFrame1.MoneyFrame)
	end
end

local goldFrame = CreateFrame("Frame")
goldFrame:RegisterEvent("PLAYER_LOGIN")
goldFrame:RegisterEvent("PLAYER_MONEY")
goldFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
goldFrame:RegisterEvent("BAG_OPEN")
goldFrame:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_MONEY" then
		SaveMyGold(true)
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- gold is known a moment after loading in
		C_Timer.After(3, function() SaveMyGold(false) end)
	else
		SaveMyGold(false)
	end
	if event == "PLAYER_LOGIN" or event == "BAG_OPEN" then
		pcall(HookBagMoney)
	end
end)
if OpenAllBags then hooksecurefunc("OpenAllBags", function() pcall(HookBagMoney) end) end
if ToggleBackpack then hooksecurefunc("ToggleBackpack", function() pcall(HookBagMoney) end) end
if ToggleAllBags then hooksecurefunc("ToggleAllBags", function() pcall(HookBagMoney) end) end
if ToggleBag then hooksecurefunc("ToggleBag", function() pcall(HookBagMoney) end) end
