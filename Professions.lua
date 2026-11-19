-- MarketScribe: Professions.lua
--
-- Adds an expected-profit label to each recipe row in the profession
-- window, using MarketScribe's own price cache (Core.lua) for both the
-- reagent costs and the crafted item's sale value.

local addonName, ns = ...

-- Bind on Pickup (or otherwise never on the AH): worth what a vendor pays,
-- 0 if nothing. nil when it CAN be auctioned, or isn't loaded yet.
local function BoPValue(itemID)
	local _, _, quality, _, _, _, _, _, _, _, sell, _, _, bindType = C_Item.GetItemInfo(itemID)
	if quality == nil then
		C_Item.RequestLoadItemDataByID(itemID)
		return nil
	end
	if bindType == 1 then
		return sell or 0
	end
	return nil
end
ns.BoPValue = BoPValue

-- What a vendor pays for one of the item, nil if unknown/none.
local function VendorSellValue(itemID)
	local sell = select(11, C_Item.GetItemInfo(itemID))
	if sell and sell > 0 then return sell end
end

-- What one crafted item is worth to you, and whether that is the vendor
-- price: the better of the AH price (after the 5% cut) and the vendor price. Bind-on-Pickup
-- items can only be vendored. Third result: true when the AH price is
-- missing, so the number is a floor (the AH might pay more).
local function OutputValue(itemID)
	local bop = BoPValue(itemID)
	if bop ~= nil then
		return bop, bop > 0, false
	end
	local ah = ns.GetSellPrice(itemID) -- AH after the 5% cut
	local vendor = VendorSellValue(itemID)
	if vendor and (not ah or vendor >= ah) then
		return vendor, true, not ah
	end
	return ah, false, false
end

local function FormatProfit(profit, complete, vendored)
	if profit == nil then
		return "|cff888888?|r"
	end
	local color = (profit >= 0) and "|cff40ff40" or "|cffff4040"
	local sign = (profit >= 0) and "+" or "-"
	local text = color .. sign .. ns.FormatMoney(profit) .. "|r"
	if vendored then
		text = text .. " |cff80c0ff(v)|r" -- vendoring beats (or replaces) the AH
	end
	if not complete then
		text = text .. " |cff888888~|r" -- one or more prices are missing/stale
	end
	return text
end

-- Total reagent cost for a recipe's *required* slots -- both "Basic"
-- reagents and any other (Finishing/Modifying) slot the recipe marks as
-- required, e.g. a mandatory quality-boosting reagent like a pearl clasp.
-- Optional/finishing slots the player can freely skip are still excluded.
-- A slot can offer a choice of several interchangeable reagents; we cost it
-- at the cheapest option we know a price for, and queue every option we
-- don't have a price for yet.
local function GetRecipeCost(recipeID)
	local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
	if not schematic or not schematic.reagentSlotSchematics then
		return nil, nil, schematic
	end

	local total, complete = 0, true
	for _, slot in ipairs(schematic.reagentSlotSchematics) do
		local isBasic = slot.reagentType == Enum.CraftingReagentType.Basic
		local isRequiredOther = (not isBasic) and slot.required
		if (isBasic or isRequiredOther) and slot.reagents then
			local qty = slot.quantityRequired or 0
			if qty > 0 then
				local cheapest
				for _, option in ipairs(slot.reagents) do
					if option.itemID then
						if ns.QueueItem then
							ns.QueueItem(option.itemID)
						end
						-- a Bind-on-Pickup reagent has no market: count it at what
						-- a vendor would pay you for it instead
						local price = ns.GetPrice(option.itemID) or BoPValue(option.itemID)
						if price and (not cheapest or price < cheapest) then
							cheapest = price
						end
					end
				end
				if cheapest then
					total = total + (cheapest * qty)
				else
					complete = false
				end
			end
		end
	end
	return total, complete, schematic
end
ns.GetRecipeCost = GetRecipeCost

-- Reagent cost divided down to "per one crafted item", matching how
-- GetRecipeProfit already accounts for recipes that yield more than one
-- item per craft (quantityMin/quantityMax) -- so it's directly comparable,
-- unit for unit, to a single item's AH price or disenchant value. Returns
-- nil if the recipe's cost isn't known at all.
local function GetRecipeCostPerItem(recipeID)
	local cost, complete, schematic = GetRecipeCost(recipeID)
	if not schematic or cost == nil then
		return nil
	end
	local quantity = ((schematic.quantityMin or 1) + (schematic.quantityMax or schematic.quantityMin or 1)) / 2
	if quantity <= 0 then
		quantity = 1
	end
	return cost / quantity, complete
end
ns.GetRecipeCostPerItem = GetRecipeCostPerItem

-- Expected profit = crafted item's cached price x average yield, minus
-- reagent cost. Returns nil when we don't know the output's price at all.
local function GetRecipeProfit(recipeID)
	local cost, complete, schematic = GetRecipeCost(recipeID)
	if not schematic then
		return nil
	end
	local outputItemID = ns.GetRecipeOutputItemID(recipeID, schematic)
	if not outputItemID then
		return nil
	end
	if ns.QueueItem then
		ns.QueueItem(outputItemID)
	end
	-- Worth the better of AH and vendor price; Bind on Pickup items can only
	-- be vendored (0 if no vendor price), so the profit shows what crafting
	-- them costs you
	local outputPrice, vendored, ahMissing = OutputValue(outputItemID)
	if not outputPrice or cost == nil then
		return nil
	end
	if ahMissing then complete = false end
	local quantity = ((schematic.quantityMin or 1) + (schematic.quantityMax or schematic.quantityMin or 1)) / 2
	if quantity <= 0 then
		quantity = 1
	end
	return (outputPrice * quantity) - cost, complete, vendored
end
ns.GetRecipeProfit = GetRecipeProfit

-- Called once per row whenever the profession recipe list (re)builds a
-- row's contents -- mirrors the ScrollUtil hook pattern used by other
-- Forever profession addons (e.g. skillup-forever) against this exact UI.
local function DecorateRow(self, row, node)
	local data = node and node:GetData()
	local info = data and data.recipeInfo

	local text = row.MarketScribeText
	if not text then
		text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight_NoShadow")
		text:SetJustifyH("RIGHT")
		row.MarketScribeText = text
	end

	if not info or not info.recipeID then
		text:Hide()
		return
	end

	local profit, complete, vendored = GetRecipeProfit(info.recipeID)
	text:ClearAllPoints()
	if row.LockedIcon and row.LockedIcon:IsShown() then
		text:SetPoint("RIGHT", row.LockedIcon, "LEFT", -4, 0)
	else
		text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
	end
	text:SetText(FormatProfit(profit, complete, vendored))
	text:Show()
end

local attached = false
local function Attach()
	if attached then
		return
	end
	local recipeList = ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.RecipeList
	if not (recipeList and recipeList.ScrollBox and ScrollUtil) then
		return
	end
	ScrollUtil.AddInitializedFrameCallback(recipeList.ScrollBox, DecorateRow, ns)
	attached = true
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:SetScript("OnEvent", Attach)
