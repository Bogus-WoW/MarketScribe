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

-- How many of the hovered item are in the stack? Read from the item button the
-- tooltip is attached to (bags, bank, vendor, loot and so on all keep it there),
-- or from the bag slot as a fallback. Returns nil if it can't be told.
local function StackCount(tooltip)
	local owner = tooltip.GetOwner and tooltip:GetOwner()
	if type(owner) ~= "table" then return nil end
	local function Num(v)
		if issecretvalue and issecretvalue(v) then return nil end
		v = tonumber(v)
		return v and v >= 1 and math.floor(v) or nil
	end
	local n = Num(owner.count)
	if n then return n end
	local fs = owner.Count
	if not fs and owner.GetName and owner:GetName() then fs = _G[owner:GetName() .. "Count"] end
	if fs and fs.GetText then
		n = Num(fs:GetText())
		if n then return n end
	end
	-- an item button with no count text holds a single item (or it's a bag slot we can ask about)
	if C_Container and C_Container.GetContainerItemInfo and owner.GetParent and owner.GetID then
		local parent = owner:GetParent()
		local ok, info = pcall(C_Container.GetContainerItemInfo, parent and parent:GetID(), owner:GetID())
		if ok and type(info) == "table" then
			n = Num(info.stackCount)
			if n then return n end
		end
	end
	if fs or owner.icon or owner.Icon then return 1 end
	return nil
end

local function AddStackLine(tooltip, label, each)
	if not IsShiftKeyDown() then return end
	local n = StackCount(tooltip)
	if not n then
		tooltip:AddLine("|cff888888MarketScribe: can't tell the stack size here|r")
		return
	end
	if n > 1 then
		tooltip:AddLine(("|cff40c0ffMarketScribe|r %s x%d: %s"):format(label, n, ns.FormatMoney(each * n)))
	end
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
		if source ~= "vendor" and ns.Trend then
			local tr, was, days = ns.Trend(id, 3)
			if tr then
				local v = math.floor(math.abs(tr) * 100 + 0.5)
				local txt, col
				if v == 0 then txt, col = "unchanged", "aaaaaa"
				elseif tr > 0 then txt, col = ("+%d%%"):format(v), "40e080"
				else txt, col = ("-%d%%"):format(v), "ff6060" end
				local span = (math.floor(days + 0.5) == 3) and "3-day" or ("%.1f-day"):format(days)
				tooltip:AddLine(("|cff40c0ffMarketScribe|r %s trend: |cff%s%s|r |cff888888(was %s)|r"):format(
					span, col, txt, ns.FormatMoney(was)))
			end
		end
		AddStackLine(tooltip, label, price)

		-- When a (cheaper) vendor price wins, still show the AH price if we
		-- have one -- that's what the item actually sells for.
		if source == "vendor" and ns.GetMarketPrice then
			local mPrice, mTime, mSource = ns.GetMarketPrice(id)
			if mPrice then
				tooltip:AddLine(("|cff40c0ffMarketScribe|r %s: %s |cff888888(%s%s)|r"):format(
					mSource == "commodity" and "AH (commodity)" or "AH", ns.FormatMoney(mPrice), ns.FormatAge(mTime), listedText))
				AddStackLine(tooltip, mSource == "commodity" and "AH (commodity)" or "AH", mPrice)
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
			local text = ("|cff40c0ffMarketScribe|r Disenchant (avg, after AH cut): %s"):format(ns.FormatMoney(deValue))
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

-- Pressing or releasing Shift while an item tooltip is up redraws it, so the
-- stack price appears (or goes away) without moving the mouse.
local shiftWatcher = CreateFrame("Frame")
shiftWatcher:RegisterEvent("MODIFIER_STATE_CHANGED")
shiftWatcher:SetScript("OnEvent", function(_, _, key)
	if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
	if not (GameTooltip and GameTooltip:IsShown()) then return end
	-- only item tooltips: redrawing a unit tooltip makes the game's own code error
	-- when the unit is a protected ("secret") value
	local okItem, _, itemLink = pcall(GameTooltip.GetItem, GameTooltip)
	if not (okItem and itemLink) then return end
	if GameTooltip.RefreshData then
		pcall(GameTooltip.RefreshData, GameTooltip)
	else
		local owner = GameTooltip:GetOwner()
		local onEnter = owner and owner.GetScript and owner:GetScript("OnEnter")
		if onEnter then pcall(onEnter, owner) end
	end
end)

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
-- unique (two characters can share a first name), so characters are kept
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

-- Gold history (for the 24 hour line) and per-character session baselines.
-- goldHist[guid] = { {time, money}, ... }: a sample whenever the gold changed,
-- at most every SAMPLE_GAP seconds, plus one on every login/logout.
-- goldSession[guid] = { start = money, t = time }: set at each fresh login
-- (not on /reload), so a session lasts until you log out and back in.
local DAY = 86400
local SAMPLE_GAP = 600

local function Hist()
	MarketScribeDB.goldHist = MarketScribeDB.goldHist or {}
	return MarketScribeDB.goldHist
end

local function Sessions()
	MarketScribeDB.goldSession = MarketScribeDB.goldSession or {}
	return MarketScribeDB.goldSession
end

-- newest saved record for each character across all realm keys, by GUID
local function NewestChars()
	local out = {}
	for _, t in pairs(GoldDB()) do
		if type(t) == "table" then
			for key, c in pairs(t) do
				local k = c.guid or key
				if not out[k] or (c.time or 0) > (out[k].time or 0) then out[k] = c end
			end
		end
	end
	return out
end

local function RecordSample(k, money, now, force)
	local list = Hist()[k]
	if not list then list = {}; Hist()[k] = list end
	local last = list[#list]
	if last then
		if last[2] == money then return end
		if not force and now - last[1] < SAMPLE_GAP then return end
	end
	list[#list + 1] = { now, money }
	-- keep what is newer than 48 hours, plus the newest sample before that
	local cut, drop = now - 2 * DAY, 0
	for i = 1, #list - 1 do
		if list[i + 1][1] <= cut then drop = i else break end
	end
	for _ = 1, drop do table.remove(list, 1) end
end

-- characters saved before history existed start from their last saved gold
local function EnsureHistory()
	for k, c in pairs(NewestChars()) do
		if not Hist()[k] and c.money then
			RecordSample(k, c.money, c.time or time(), true)
		end
	end
end

local function StartSession(forceNew)
	local guid = UnitGUID and UnitGUID("player")
	if not guid then return end
	local s = Sessions()
	if forceNew or not s[guid] then s[guid] = { start = GetMoney() or 0, t = time() } end
end

-- gold change over the last 24 hours across all characters. If a character
-- has less than 24 hours of history, its earliest sample is used and the
-- shortest such span is returned as the second value.
local function DayDelta()
	local now = time()
	local cutoff = now - DAY
	local total, shortest = 0, nil
	for k, c in pairs(NewestChars()) do
		local list = Hist()[k]
		local base, partial
		if list and #list > 0 then
			for i = #list, 1, -1 do
				if list[i][1] <= cutoff then base = list[i][2]; break end
			end
			if not base then base = list[1][2]; partial = now - list[1][1] end
		end
		if base then
			total = total + ((c.money or 0) - base)
			if partial and (not shortest or partial < shortest) then shortest = partial end
		end
	end
	return total, shortest
end

local function Duration(sec)
	sec = math.max(0, math.floor(sec or 0))
	local h, m = math.floor(sec / 3600), math.floor((sec % 3600) / 60)
	if h > 0 then return ("%dh %02dm"):format(h, m) end
	return ("%dm"):format(m)
end

local function Signed(copper)
	if copper > 0 then return "|cff40ff40+" .. ns.FormatMoney(copper) .. "|r" end
	if copper < 0 then return "|cffff4040-" .. ns.FormatMoney(-copper) .. "|r" end
	return "|cff888888" .. ns.FormatMoney(0) .. "|r"
end

-- `confirmed` is true when the game just told us the gold changed. Otherwise
-- a 0 is ignored if we already know a higher amount: while logging in or out
-- the game briefly reports 0 gold.
local function SaveMyGold(confirmed, force)
	local realm, name, guid = GetRealmName(), UnitName("player"), UnitGUID and UnitGUID("player")
	if not (realm and name) then return end
	local key = guid or name
	local money = GetMoney() or 0
	local _, class = UnitClass("player")
	local db = GoldDB()
	EnsureHistory()
	db[realm] = db[realm] or {}
	local old = db[realm][key]
	if money == 0 and not confirmed and old and (old.money or 0) > 0 then return end
	-- the old name-only entry is ambiguous (two characters with the same first name overwrote each other): drop it
	local legacy = db[realm][name]
	if guid and legacy and not legacy.guid then db[realm][name] = nil end
	-- the realm name is only technical (and GetRealmName can come back empty),
	-- so the same character must never be stored under two realm keys
	for r, t in pairs(db) do
		if r ~= realm and type(t) == "table" then t[key] = nil end
	end
	db[realm][key] = { money = money, class = class, faction = UnitFactionGroup("player"), time = time(),
		name = name, last = LastName() or (old and old.last), level = UnitLevel("player"), guid = guid }
	RecordSample(key, money, time(), force)
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
	-- one entry per character across all realm keys: keep the newest (older
	-- copies are left from when the realm name was different or empty)
	local newest = {}
	for _, realm in ipairs(realms) do
		for key, c in pairs(GoldDB()[realm]) do
			local k = c.guid or key
			if not newest[k] or (c.time or 0) > (newest[k].c.time or 0) then
				newest[k] = { realm = realm, key = key, c = c }
			end
		end
	end
	local byRealm = {}
	for _, e in pairs(newest) do
		byRealm[e.realm] = byRealm[e.realm] or {}
		byRealm[e.realm][e.key] = e.c
	end
	local shown = {}
	for _, realm in ipairs(realms) do
		if byRealm[realm] then shown[#shown + 1] = realm end
	end
	realms = shown
	for _, realm in ipairs(realms) do
		local chars, seen = {}, {}
		for key, c in pairs(byRealm[realm]) do
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
		for _, e in ipairs(chars) do
			local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.c.class]
			local label = (myGuid and (e.key == myGuid or e.c.guid == myGuid)) and (e.label .. " (you)") or e.label
			GameTooltip:AddDoubleLine(label, ns.FormatMoney(e.c.money),
				color and color.r or 1, color and color.g or 1, color and color.b or 1, 1, 1, 1)
			total = total + e.c.money
		end
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddDoubleLine("Total", ns.FormatMoney(total), 1, 0.82, 0, 1, 0.82, 0)
	-- this character's session, and all characters over the last 24 hours
	local sess = myGuid and Sessions()[myGuid]
	if sess then
		GameTooltip:AddDoubleLine(("Session (%s)"):format(Duration(time() - (sess.t or time()))),
			Signed((GetMoney() or 0) - (sess.start or 0)), 0.8, 0.8, 0.8, 1, 1, 1)
	end
	local day, partial = DayDelta()
	local dayLabel = "Last 24h, all characters"
	if partial then dayLabel = dayLabel .. (" (only %s tracked)"):format(Duration(partial)) end
	GameTooltip:AddDoubleLine(dayLabel, Signed(day), 0.8, 0.8, 0.8, 1, 1, 1)
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
goldFrame:RegisterEvent("PLAYER_LOGOUT")
goldFrame:SetScript("OnEvent", function(_, event, isInitialLogin)
	if event == "PLAYER_MONEY" then
		SaveMyGold(true)
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- a fresh login starts a new session; /reload and zoning keep it
		if isInitialLogin then
			local guid = UnitGUID and UnitGUID("player")
			if guid then Sessions()[guid] = nil end
		end
		-- gold is known a moment after loading in
		C_Timer.After(3, function() SaveMyGold(false); StartSession(false) end)
	elseif event == "PLAYER_LOGOUT" then
		SaveMyGold(false, true)
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

-- /ms session reset: start this character's session line from the current gold
do
	local orig = SlashCmdList.MARKETSCRIBE
	SlashCmdList.MARKETSCRIBE = function(msg)
		local m = (msg or ""):lower():match("^%s*(.-)%s*$")
		if m == "session reset" then
			StartSession(true)
			print("|cff40c0ffMarketScribe|r: session gold restarted from now.")
		elseif orig then
			orig(msg)
		end
	end
end
