-- MarketScribe: Disenchant.lua
--
-- Estimates the expected gold value of disenchanting a green/blue item,
-- using your own price cache for the resulting dust/essence/shard, so it
-- can be compared against the item's own known value in its tooltip.
--
-- IMPORTANT HONESTY NOTE: Blizzard has never published exact disenchant
-- odds, even for original vanilla content. The percentages and material
-- tiers below are reconstructed from community testing (Wowpedia's
-- disenchanting tables, wow-professions.com, and cross-referenced farming
-- guides) for classic-era content, cross-checked against each other where
-- they agreed. They are NOT confirmed against WoW: Forever specifically --
-- this server could easily tune disenchanting differently. Treat every
-- number here as "a reasonable estimate", not "guaranteed correct", and
-- expect the real average to drift from this over enough samples.

local addonName, ns = ...

--------------------------------------------------------------------------
-- Item-level brackets. Each bracket names the dust/essence/shard that
-- results from disenchanting an item in that range -- these material NAMES
-- are stable, well-documented Blizzard strings, so we resolve them to this
-- server's actual item IDs at runtime (see ResolveMaterialID) rather than
-- hardcoding IDs we can't verify match Forever's data.
--------------------------------------------------------------------------

-- Each bracket names exactly ONE essence tier, not a Lesser/Greater choice
-- -- confirmed against Wowpedia's actual disenchanting table (cross-checked
-- across multiple fetches): a given item-level range only ever produces one
-- specific essence name, never a chance at either the Lesser or Greater
-- version of it. Dust never has Lesser/Greater variants at all, only named
-- tiers (Strange/Soul/Vision/Dream/Illusion) that step up alongside the
-- essence tier.
--
-- The *Qty fields are the average amount you get WHEN that outcome occurs
-- (e.g. a "2-3" range in the source data becomes 2.5 here) rather than a
-- separate multiple-item-chance calculation -- expected value is linear, so
-- chance * averageQty * price already equals what you'd get from fully
-- modeling "70% chance of 1, 30% chance of 2" etc. There's no missing
-- factor here, just a collapsed-to-its-mean version of the same math.
local BRACKETS = {
	{ maxLevel = 15, dust = "Strange Dust", dustQty = 1.5, essence = "Lesser Magic Essence", essenceQty = 1.5, shard = "Small Glimmering Shard" },
	{ maxLevel = 20, dust = "Strange Dust", dustQty = 2.5, essence = "Greater Magic Essence", essenceQty = 1.5, shard = "Small Glimmering Shard" },
	{ maxLevel = 25, dust = "Strange Dust", dustQty = 5, essence = "Lesser Astral Essence", essenceQty = 1.5, shard = "Small Glimmering Shard" },
	{ maxLevel = 30, dust = "Soul Dust", dustQty = 1.5, essence = "Greater Astral Essence", essenceQty = 1.5, shard = "Large Glimmering Shard" },
	{ maxLevel = 35, dust = "Soul Dust", dustQty = 3.5, essence = "Lesser Mystic Essence", essenceQty = 1.5, shard = "Small Glowing Shard" },
	{ maxLevel = 40, dust = "Vision Dust", dustQty = 1.5, essence = "Greater Mystic Essence", essenceQty = 1.5, shard = "Large Glowing Shard" },
	{ maxLevel = 45, dust = "Vision Dust", dustQty = 3.5, essence = "Lesser Nether Essence", essenceQty = 1.5, shard = "Small Radiant Shard" },
	{ maxLevel = 50, dust = "Dream Dust", dustQty = 1.5, essence = "Greater Nether Essence", essenceQty = 1.5, shard = "Large Radiant Shard" },
	{ maxLevel = 55, dust = "Dream Dust", dustQty = 3.5, essence = "Lesser Eternal Essence", essenceQty = 1.5, shard = "Small Brilliant Shard" },
	{ maxLevel = 9999, dust = "Illusion Dust", dustQty = 1.5, essence = "Greater Eternal Essence", essenceQty = 1.5, shard = "Large Brilliant Shard" },
}

local function GetBracket(itemLevel)
	for _, bracket in ipairs(BRACKETS) do
		if itemLevel <= bracket.maxLevel then
			return bracket
		end
	end
	return BRACKETS[#BRACKETS]
end

-- Rough odds, reconstructed the same way as the brackets above -- confirmed
-- against Wowpedia's actual per-bracket table for ARMOR specifically. Green
-- ARMOR rolls dust most of the time with essence as the minority result;
-- green WEAPONS are documented as flipping that (essence becomes the common
-- result) but without their own confirmed quantity ranges, so weapons reuse
-- the same dustQty/essenceQty numbers as armor with the odds swapped --
-- that reuse is an assumption on top of an already-reconstructed table, so
-- treat weapon estimates as the least confident part of this whole feature.
-- Either way there's a small chance at a shard too. Rare (blue) items are
-- treated as a guaranteed shard, which is the well-agreed-on part of the
-- classic disenchant model.
local DUST_PRIMARY_CHANCE, DUST_SECONDARY_CHANCE = 0.78, 0.23
local ESSENCE_PRIMARY_CHANCE, ESSENCE_SECONDARY_CHANCE = 0.75, 0.20
local GREEN_SHARD_CHANCE = 0.02

--------------------------------------------------------------------------
-- Name -> itemID resolution.
--
-- These 23 material names are standard, unchanging vanilla-WoW item IDs --
-- the same numeric ID is used across every version of WoW (Classic Era,
-- retail's classic content, and WoW: Forever included), verified against
-- Wowhead's classic item pages and cross-checked against an independent
-- item database. Hardcoding them fixes a real bug the previous name->ID
-- lookup had: C_Item.GetItemInfoInstant(name) only resolves a name once the
-- client has that specific item's data cached locally (i.e. you've actually
-- seen a Strange Dust or a Lesser Magic Essence before), which is often
-- simply untrue for materials you've never disenchanted anything into yet.
-- Worse, a failed lookup was cached as a *permanent* failure and never
-- retried -- so every material stayed unresolved forever, and every
-- disenchant estimate silently stuck at 0c, regardless of how much AH/vendor
-- scanning you did afterwards. Hardcoding sidesteps name resolution
-- entirely for every material this feature actually uses.
--------------------------------------------------------------------------

local MATERIAL_IDS = {
	["Strange Dust"] = 10940,
	["Soul Dust"] = 11083,
	["Vision Dust"] = 11137,
	["Dream Dust"] = 11176,
	["Illusion Dust"] = 16204,

	["Lesser Magic Essence"] = 10938,
	["Greater Magic Essence"] = 10939,
	["Lesser Astral Essence"] = 10998,
	["Greater Astral Essence"] = 11082,
	["Lesser Mystic Essence"] = 11134,
	["Greater Mystic Essence"] = 11135,
	["Lesser Nether Essence"] = 11174,
	["Greater Nether Essence"] = 11175,
	["Lesser Eternal Essence"] = 16202,
	["Greater Eternal Essence"] = 16203,

	["Small Glimmering Shard"] = 10978,
	["Large Glimmering Shard"] = 11084,
	["Small Glowing Shard"] = 11138,
	["Large Glowing Shard"] = 11139,
	["Small Radiant Shard"] = 11177,
	["Large Radiant Shard"] = 11178,
	["Small Brilliant Shard"] = 14343,
	["Large Brilliant Shard"] = 14344,
}

-- every dust/essence/shard ID, for the Disenchant Scan's price refresh
function ns.DEMaterialIDs()
	local ids = {}
	for _, id in pairs(MATERIAL_IDS) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

local resolvedIDs = {}

local function ResolveMaterialID(name)
	if resolvedIDs[name] then
		return resolvedIDs[name]
	end
	local id = MATERIAL_IDS[name]
	if not id then
		-- Fallback only, for a material name that's somehow not in the
		-- hardcoded table above (e.g. this file gets extended later).
		-- Deliberately NOT cached on failure -- unlike the old code, so a
		-- name that isn't resolvable yet can still succeed on a later call
		-- once the client happens to cache that item's data, rather than
		-- getting stuck at "unresolved" forever.
		if C_Item and C_Item.GetItemInfoInstant then
			id = C_Item.GetItemInfoInstant(name)
		elseif GetItemInfoInstant then
			id = GetItemInfoInstant(name)
		end
	end
	if id then
		resolvedIDs[name] = id
	end
	return id
end

--------------------------------------------------------------------------
-- Items that look disenchantable (green/blue weapon or armor) but can't
-- actually be disenchanted. The Enchanting-made wands are the known case.
-- ns.IsNotDisenchantable is also used by companion addons (SkillScribe).
--------------------------------------------------------------------------

local NOT_DISENCHANTABLE = {
	[11287] = true, -- Lesser Magic Wand
	[11288] = true, -- Greater Magic Wand
	[11289] = true, -- Lesser Mystic Wand
	[11290] = true, -- Greater Mystic Wand
}

function ns.IsNotDisenchantable(itemID)
	return itemID and NOT_DISENCHANTABLE[itemID] or false
end

--------------------------------------------------------------------------
-- Expected value calculation
--------------------------------------------------------------------------

-- Returns (expectedValue, complete) in copper, or nil if this item isn't a
-- weapon/armor piece of Uncommon or Rare quality (i.e. not something this
-- estimate applies to at all). `complete` is false when one or more of the
-- possible outcome materials couldn't be priced (unresolved item ID, or no
-- price on file yet) -- the returned value is then a lower bound, not the
-- true expected value.
function ns.GetDisenchantEV(itemID)
	if ns.IsNotDisenchantable(itemID) then
		return nil
	end
	if not (C_Item and C_Item.GetItemInfo) then
		return nil
	end
	local _, _, quality, itemLevel, _, _, _, _, _, _, _, classID = C_Item.GetItemInfo(itemID)
	if not (quality and itemLevel and classID) then
		return nil -- item data not cached yet
	end

	local ItemClass = Enum.ItemClass or {}
	local isWeapon = classID == (ItemClass.Weapon or 2)
	local isArmor = classID == (ItemClass.Armor or 4)
	if not (isWeapon or isArmor) then
		return nil
	end

	local Quality = Enum.ItemQuality or {}
	local UNCOMMON, RARE = Quality.Uncommon or 2, Quality.Rare or 3
	if quality ~= UNCOMMON and quality ~= RARE then
		return nil -- only Uncommon/Rare are handled with any real confidence
	end
	if itemLevel < 5 then
		return nil -- too low-level to yield anything meaningful when disenchanted
	end

	local bracket = GetBracket(itemLevel)
	local total, complete = 0, true

	local function Add(materialName, chance, qty)
		if not materialName or chance <= 0 then
			return
		end
		local id = ResolveMaterialID(materialName)
		if not id then
			complete = false
			return
		end
		if ns.QueueItem then
			ns.QueueItem(id)
		end
		local price = ns.GetSellPrice(id) -- you sell the materials: AH after the 5% cut
		if price then
			total = total + chance * qty * price
		else
			complete = false
		end
	end

	if quality == RARE then
		Add(bracket.shard, 1.0, 1)
	else
		if isWeapon then
			Add(bracket.essence, ESSENCE_PRIMARY_CHANCE, bracket.essenceQty)
			Add(bracket.dust, DUST_SECONDARY_CHANCE, bracket.dustQty)
		else
			Add(bracket.dust, DUST_PRIMARY_CHANCE, bracket.dustQty)
			Add(bracket.essence, ESSENCE_SECONDARY_CHANCE, bracket.essenceQty)
		end
		Add(bracket.shard, GREEN_SHARD_CHANCE, 1)
	end

	return total, complete
end
