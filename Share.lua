-- MarketScribe: Share.lua
--
-- Swaps AH prices with the people on your in-game Friends list who also
-- run MarketScribe. Nothing is announced anywhere: no channels, no guild
-- messages, no chat output. It only ever whispers (hidden addon messages)
-- friends who are online, and only accepts prices from people on your
-- Friends list. Newest price wins.
--
--   /ms share list   who you've synced with, and when
--   /ms share now    sync right away
--   /ms share off    stop sharing (/ms share on to turn it back on)
--
-- When it syncs: shortly after login, when a friend comes online, and
-- once an hour. Each sync asks for prices newer than the last one received
-- from that friend, so only new prices travel after the first swap.
-- Messages go out about once a second, well under Blizzard's limits.
--
-- Both of you need each other on your Friends lists (a character friend or a
-- Battle.net friend both count), and to be on the same faction. The realm
-- doesn't matter: every WoW: Forever realm shares one auction house.

local addonName, ns = ...

local PREFIX = "MScribe1"
local SEND_INTERVAL = 1.1   -- seconds between outgoing messages
local SYNC_INTERVAL = 3600
local MIN_REQUEST_GAP = 600 -- ask the same friend at most every 10 minutes
local MAX_MSG = 250

local function ShareDB()
	MarketScribeDB.share = MarketScribeDB.share or {}
	local s = MarketScribeDB.share
	s.peers = s.peers or {} -- [Name] = { since, lastSync, lastAsked }
	if s.friends then -- older manual list; keep its sync cursors
		for name, f in pairs(s.friends) do s.peers[name] = s.peers[name] or f end
		s.friends = nil
	end
	if s.enabled == nil then s.enabled = true end
	return s
end

local function Short(name)
	return Ambiguate and Ambiguate(name, "none") or name:match("^[^%-]+")
end

--------------------------------------------------------------------------
-- Friends list
--------------------------------------------------------------------------

local function Plain(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

-- Battle.net friends are messaged through their game account, which avoids
-- any trouble with character/realm name spelling.
local bnetID, bnetName = {}, {} -- name -> gameAccountID, gameAccountID -> name

-- Battle.net friends who are online on a WoW: Forever character of this
-- faction, on any realm: { [characterName] = true }
local function BNetFriends(out)
	if not (BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendNumGameAccounts) then
		return
	end
	local myFaction, myProject = UnitFactionGroup("player"), WOW_PROJECT_ID
	local total = BNGetNumFriends() or 0
	for i = 1, total do
		for j = 1, C_BattleNet.GetFriendNumGameAccounts(i) or 0 do
			local g = C_BattleNet.GetFriendGameAccountInfo(i, j)
			local name = g and Plain(g.characterName)
			if name and name ~= "" and Plain(g.clientProgram) == (BNET_CLIENT_WOW or "WoW") and g.isOnline ~= false
				and (not myProject or not Plain(g.wowProjectID) or Plain(g.wowProjectID) == myProject)
				and (not g.factionName or Plain(g.factionName) == myFaction) then
				out[Short(name)] = true
				local id = Plain(g.gameAccountID)
				if id then
					bnetID[Short(name)] = id
					bnetName[id] = Short(name)
				end
			end
		end
	end
end

-- Returns { [shortName] = isOnline } for your in-game Friends list plus
-- Battle.net friends playing WoW: Forever on this faction.
local function Friends()
	local out = {}
	if C_FriendList and C_FriendList.GetNumFriends then
		for i = 1, C_FriendList.GetNumFriends() or 0 do
			local info = C_FriendList.GetFriendInfoByIndex(i)
			if info and info.name then
				out[Short(info.name)] = info.connected and true or false
			end
		end
	end
	pcall(BNetFriends, out)
	return out
end

local function IsFriend(sender)
	return Friends()[Short(sender)] ~= nil
end

--------------------------------------------------------------------------
-- Outgoing queue
--------------------------------------------------------------------------

local outbox = {}

local function Whisper(target, msg)
	table.insert(outbox, { target = target, msg = msg })
end

C_Timer.NewTicker(SEND_INTERVAL, function()
	local item = table.remove(outbox, 1)
	if not item then return end
	local id = bnetID[item.target]
	if id and BNSendGameData then
		pcall(BNSendGameData, id, PREFIX, item.msg)
		return
	end
	local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
	if send then
		pcall(send, PREFIX, item.msg, "WHISPER", item.target)
	end
end)

--------------------------------------------------------------------------
-- Protocol (all by hidden whisper)
--   Q|<ahKey>|<since>               "send me your prices newer than <since>"
--   P|<ahKey>|id,price,time;...     a batch of prices
--   E|<ahKey>|<count>               end of the reply
--------------------------------------------------------------------------

local function Request(name, force)
	local s = ShareDB()
	if not s.enabled then return end
	s.peers[name] = s.peers[name] or { since = 0 }
	local p = s.peers[name]
	if not force and p.lastAsked and time() - p.lastAsked < MIN_REQUEST_GAP then return end
	p.lastAsked = time()
	Whisper(name, ("Q|%s|%d"):format(ns.RealmKey(), p.since or 0))
end

-- Ask every online friend for newer prices.
function ns.SyncAll(force)
	if not ShareDB().enabled then return end
	for name, online in pairs(Friends()) do
		if online then Request(name, force) end
	end
end

local function Reply(target, since)
	local key = ns.RealmKey()
	local header = "P|" .. key .. "|"
	local parts, len, count = {}, #header, 0
	for itemID, p in pairs(ns.Store().prices) do
		-- only prices we saw ourselves; each friend sends their own
		if (p.time or 0) > since and not p.from then
			local entry = ("%d,%d,%d"):format(itemID, math.floor(p.price), p.time)
			if len + #entry + 1 > MAX_MSG then
				Whisper(target, header .. table.concat(parts, ";"))
				parts, len = {}, #header
			end
			table.insert(parts, entry)
			len = len + #entry + 1
			count = count + 1
		end
	end
	if #parts > 0 then
		Whisper(target, header .. table.concat(parts, ";"))
	end
	Whisper(target, ("E|%s|%d"):format(key, count))
end

local function OnMessage(prefix, msg, channel, sender)
	if prefix ~= PREFIX or channel ~= "WHISPER" or not sender then return end
	local s = ShareDB()
	if not s.enabled or not IsFriend(sender) then return end
	local kind, key, body = msg:match("^(%a)|([^|]*)|?(.*)$")
	if not kind or key ~= ns.RealmKey() then
		return -- different faction's AH (or an older MarketScribe): their prices don't apply here
	end
	local name = Short(sender)
	s.peers[name] = s.peers[name] or { since = 0 }
	local p = s.peers[name]

	if kind == "Q" then
		Reply(name, tonumber(body) or 0)
		Request(name) -- and ask them back, so both sides end up current
	elseif kind == "P" then
		local store = ns.Store()
		for id, price, t in body:gmatch("(%d+),(%d+),(%d+)") do
			id, price, t = tonumber(id), tonumber(price), tonumber(t)
			local mine = store.prices[id]
			if price > 0 and (not mine or (mine.time or 0) < t) then
				store.prices[id] = { price = price, time = t, source = mine and mine.source or "auction", from = name }
				if MarketScribeDB.wanted then MarketScribeDB.wanted[id] = nil end
			end
			if t > (p.since or 0) then p.since = t end
		end
	elseif kind == "E" then
		p.lastSync = time()
	end
end

--------------------------------------------------------------------------
-- Slash command (called from Core.lua's /ms handler). Output only appears
-- when you type the command yourself.
--------------------------------------------------------------------------

function ns.ShareCommand(rest)
	local cmd = (rest or ""):match("^(%S*)")
	local s = ShareDB()
	local tag = "|cff40c0ffMarketScribe|r: "
	if cmd == "now" then
		ns.SyncAll(true)
		print(tag .. "asking online friends for newer prices.")
	elseif cmd == "off" then
		s.enabled = false
		print(tag .. "price sharing is off.")
	elseif cmd == "purge" then
		-- /ms share purge [friend]: delete the prices received from one friend
		-- (or from every friend), e.g. after they scanned a Neutral AH.
		local who = (rest or ""):match("^%S+%s+(.-)%s*$")
		who = who and who ~= "" and who:lower() or nil
		local removed = 0
		for id, p in pairs(ns.Store().prices) do
			if p.from and (not who or p.from:lower() == who) then
				ns.Store().prices[id] = nil
				removed = removed + 1
			end
		end
		print(tag .. ("removed %d price(s) received from %s. Turn sharing off (/ms share off) until they have updated and cleaned their own data, or they will send them again."):format(removed, who or "friends"))
	elseif cmd == "debug" then
		print(tag .. ("you: %s, realm %s, %s, project %s, market %s"):format(UnitName("player"), GetRealmName(), UnitFactionGroup("player"), tostring(WOW_PROJECT_ID), ns.RealmKey()))
		local n = C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetNumFriends() or 0
		print(("  character friends: %d"):format(n))
		for i = 1, n do
			local info = C_FriendList.GetFriendInfoByIndex(i)
			if info then print(("    %s - %s"):format(tostring(info.name), info.connected and "online" or "offline")) end
		end
		local total = BNGetNumFriends and BNGetNumFriends() or 0
		print(("  Battle.net friends: %d"):format(total))
		for i = 1, total do
			for j = 1, (C_BattleNet and C_BattleNet.GetFriendNumGameAccounts(i) or 0) do
				local g = C_BattleNet.GetFriendGameAccountInfo(i, j)
				if g and g.isOnline ~= false then
					print(("    %s: client %s, realm %s, faction %s, project %s"):format(tostring(Plain(g.characterName)),
						tostring(Plain(g.clientProgram)), tostring(Plain(g.realmName)), tostring(Plain(g.factionName)),
						tostring(Plain(g.wowProjectID))))
				end
			end
		end
		local online = {}
		for name, on in pairs(Friends()) do if on then online[#online + 1] = name end end
		print("  MarketScribe would sync with: " .. (#online > 0 and table.concat(online, ", ") or "nobody"))
	elseif cmd == "on" then
		s.enabled = true
		ns.SyncAll(true)
		print(tag .. "price sharing is on.")
	else
		print(tag .. ("price sharing is %s (with your Friends list)."):format(s.enabled and "on" or "off"))
		local online = {}
		for name, on in pairs(Friends()) do
			if on then online[#online + 1] = name end
		end
		table.sort(online)
		print("  online friends it can ask: " .. (#online > 0 and table.concat(online, ", ") or "none"))
		local any = false
		for name, p in pairs(s.peers) do
			if p.lastSync then
				any = true
				print(("  %s: last sync %s"):format(name, ns.FormatAge(p.lastSync)))
			end
		end
		if not any then
			print("  no friend has answered yet. They need MarketScribe and you on their Friends list.")
		end
	end
end

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

local wasOnline = {}

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("FRIENDLIST_UPDATE")
frame:RegisterEvent("BN_FRIEND_INFO_CHANGED")
frame:RegisterEvent("BN_CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, event, a, b, c, d)
	if event == "PLAYER_LOGIN" then
		if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
			C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
		end
		if C_FriendList and C_FriendList.ShowFriends then
			C_FriendList.ShowFriends() -- ask the server for an up-to-date list
		end
		C_Timer.After(20, function()
			wasOnline = Friends()
			ns.SyncAll()
		end)
		C_Timer.NewTicker(SYNC_INTERVAL, function() ns.SyncAll() end)
	elseif event == "CHAT_MSG_ADDON" then
		OnMessage(a, b, c, d)
	elseif event == "BN_CHAT_MSG_ADDON" then
		-- prefix, text, channel, senderGameAccountID
		if a ~= PREFIX then return end
		local name = bnetName[d]
		if not name then Friends(); name = bnetName[d] end
		if name then OnMessage(a, b, "WHISPER", name) end
	elseif event == "FRIENDLIST_UPDATE" or event == "BN_FRIEND_INFO_CHANGED" then
		-- a friend who just came online gets asked after a short delay
		local now = Friends()
		for name, online in pairs(now) do
			if online and not wasOnline[name] then
				C_Timer.After(10, function() Request(name) end)
			end
		end
		wasOnline = now
	end
end)
