-- MarketScribe: History.lua
--
-- Keeps the last two weeks of price history per item for the /ms show window.
--
--   store.hist[itemID] = { t1, p1, n1,  t2, p2, n2, ... }   (oldest first)
--     t  unix time the price was seen
--     p  lowest AH price per unit, in copper
--     n  units listed at that search (> 0), 0 = not known,
--        -1 = the price came from a friend (price sharing)
--
-- Points are thinned as they are written: a rescan within 10 minutes
-- replaces the last point, and an unchanged price is only stored again
-- after 6 hours. Points older than two weeks are dropped.

local _, ns = ...

local DAY = 86400
local BURST = 600
local MINSTEP = 6 * 3600
local KEEP = 14 * DAY
local MAXPTS = 450

-- Drops points older than two weeks (always keeps the newest point), and if
-- an item somehow has too many points, the oldest quarter.
local function Trim(h)
	local c = #h
	local cutoff = time() - KEEP
	local first = 1
	while first <= c - 5 and h[first] < cutoff do first = first + 3 end
	if (c - first + 1) / 3 > MAXPTS then
		first = c - 2 - (math.floor(MAXPTS * 0.75) - 1) * 3
	end
	if first == 1 then return h end
	local out = {}
	for i = first, c do out[#out + 1] = h[i] end
	return out
end

function ns.GetHistory(itemID)
	local store = ns.Store()
	return store.hist and store.hist[itemID]
end

-- Adds one observation. n: listed units (> 0), 0 unknown, -1 from a friend.
function ns.RecordHistory(itemID, price, t, n)
	if ns.neutralAH or not itemID or not price or price <= 0 then
		return
	end
	t = t or time()
	n = n or 0
	if t < time() - KEEP then return end
	local store = ns.Store()
	store.hist = store.hist or {}
	local h = store.hist[itemID]
	if not h then
		h = {}
		store.hist[itemID] = h
	end
	local c = #h

	if c >= 3 and t < h[c - 2] then
		-- older than our newest point (a friend's data): insert in order
		local pos = c + 1
		for i = 1, c, 3 do
			if h[i] >= t then pos = i break end
		end
		for i = math.max(1, pos - 3), math.min(c - 2, pos), 3 do
			if math.abs(h[i] - t) < 3600 and h[i + 1] == price then return end
		end
		table.insert(h, pos, n)
		table.insert(h, pos, price)
		table.insert(h, pos, t)
		if #h > MAXPTS * 3 then store.hist[itemID] = Trim(h) end
		return
	end

	if c >= 3 then
		local lt, lp = h[c - 2], h[c - 1]
		if t - lt < BURST then
			h[c - 2], h[c - 1] = t, price
			if n > 0 then h[c] = n end
			return
		end
		if lp == price and t - lt < MINSTEP then
			if n > 0 then h[c] = n end
			return
		end
	end
	h[c + 1], h[c + 2], h[c + 3] = t, price, n
	if #h > MAXPTS * 3 then
		store.hist[itemID] = Trim(h)
	end
end

-- Attaches the listing count from a search to the point just recorded.
function ns.HistoryListing(itemID, quantity)
	if not quantity or quantity <= 0 then return end
	local h = ns.GetHistory(itemID)
	local c = h and #h or 0
	if c >= 3 and time() - h[c - 2] < 900 then
		h[c] = quantity
	end
end

-- Adds a point for every stored price newer than that item's last point.
-- Covers prices that reached the price table some other way, and gives
-- items that predate history their first point.
function ns.CatchUpHistory()
	local store = ns.Store()
	local added = 0
	for id, p in pairs(store.prices) do
		if p.price and p.price > 0 and p.time then
			local h = store.hist and store.hist[id]
			local c = h and #h or 0
			if c < 3 or p.time > h[c - 2] + 60 then
				local l = store.listings and store.listings[id]
				local n = p.from and -1 or 0
				if l and l.n and l.n > 0 and l.t and math.abs(l.t - p.time) < 900 then n = l.n end
				ns.RecordHistory(id, p.price, p.time, n)
				added = added + 1
			end
		end
	end
	ns.TrimHistory()
	return added
end

-- Applies the two-week limit to every item.
function ns.TrimHistory()
	local store = ns.Store()
	for id, h in pairs(store.hist or {}) do
		if #h >= 3 then store.hist[id] = Trim(h) end
	end
end

-- Price change over the last `days` days: percent as a fraction, the price
-- `days` ago, and how many days the comparison really covers. The older
-- price is the one that was showing at that time; if the history is
-- shorter, its first point is used (needs at least half the period).
function ns.Trend(itemID, days)
	local h = ns.GetHistory(itemID)
	local c = h and #h or 0
	if c < 6 then return end
	local now = time()
	local want = now - days * DAY
	local ref
	for i = 1, c, 3 do
		if h[i] <= want then ref = i else break end
	end
	if not ref then
		if now - h[1] < days * DAY * 0.5 then return end
		ref = 1
	end
	local old, cur = h[ref + 1], h[c - 1]
	if old <= 0 then return end
	return (cur - old) / old, old, (now - h[ref]) / DAY
end

-- Drops points this client recorded in the last `hours` hours (used by
-- the purge command next to prices). Friend-sourced points are kept.
function ns.PurgeHistory(hours)
	local store = ns.Store()
	local cutoff = time() - hours * 3600
	local removed = 0
	for id, h in pairs(store.hist or {}) do
		local out = {}
		for i = 1, #h, 3 do
			if h[i] >= cutoff and h[i + 2] >= 0 then
				removed = removed + 1
			else
				out[#out + 1], out[#out + 2], out[#out + 3] = h[i], h[i + 1], h[i + 2]
			end
		end
		if #out == 0 then store.hist[id] = nil else store.hist[id] = out end
	end
	return removed
end

-- Drops every point that came from a friend (/ms share purge without a name).
function ns.PurgeFriendHistory()
	local store = ns.Store()
	for id, h in pairs(store.hist or {}) do
		local out = {}
		for i = 1, #h, 3 do
			if h[i + 2] >= 0 then
				out[#out + 1], out[#out + 2], out[#out + 3] = h[i], h[i + 1], h[i + 2]
			end
		end
		store.hist[id] = #out > 0 and out or nil
	end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
	C_Timer.After(8, function() pcall(ns.CatchUpHistory) end)
end)
