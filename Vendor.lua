-- MarketScribe: Vendor.lua
--
-- Records vendor sell prices whenever you visit a merchant, so plain
-- vendor-bought reagents (Coarse Thread, Empty Vial, and the like) get
-- costed into crafting profit even though they never show up on the
-- Auction House.
--
-- Deliberately NOT recorded: limited-stock items (info.numAvailable is a
-- real, non-negative count rather than -1/unlimited). A vendor selling a
-- handful of something with a slow restock -- fish, for instance -- isn't
-- a reliable, repeatable price the way an infinite-stock reagent vendor is,
-- so treating it as MarketScribe's authoritative "vendor floor" would mask
-- the AH-based price you actually want when comparing raw vs. cooked (or
-- any other buy-low-here-sell-there) math. This is a stock-based rule, not
-- a fish-specific one -- there's no clean, reliable way to ask the item API
-- "is this a fish" at all (fish share a single lumped "Cooking" item
-- category with meat/eggs/spices, nothing more specific), but limited
-- stock is exactly the actual problem described, and it correctly excludes
-- any other limited-stock vendor item, not just this one case.

local addonName, ns = ...

local function RecordMerchantPrices()
	if not (GetMerchantNumItems and GetMerchantItemID and C_MerchantFrame and C_MerchantFrame.GetItemInfo) then
		return
	end

	local numItems = GetMerchantNumItems() or 0
	for index = 1, numItems do
		local itemID = GetMerchantItemID(index)
		local info = C_MerchantFrame.GetItemInfo(index)
		local limitedStock = info and info.numAvailable and info.numAvailable >= 0
		-- Skip reputation/token/currency-cost items (hasExtendedCost) --
		-- those don't have a plain copper price to compare against the AH.
		if itemID and info and info.price and info.price > 0 and not info.hasExtendedCost and not limitedStock then
			local each = info.price / math.max(info.stackCount or 1, 1)
			ns.RecordVendorPrice(itemID, each)
		end
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("MERCHANT_UPDATE")
frame:SetScript("OnEvent", RecordMerchantPrices)
