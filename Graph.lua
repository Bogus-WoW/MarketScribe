-- MarketScribe: Graph.lua
--
-- /ms show            open or close the price history window
-- /ms show <name|id|item link>   open it on that item
--
-- Left: every item with history, searchable, sortable (biggest movers,
-- cheap right now, A-Z, most data, latest) and a watchlist of starred items. Right: the price graph
-- (lowest AH price over time), a strip underneath with how many units were
-- listed, average and vendor lines, and a hover read-out.

local _, ns = ...

local DAY = 86400
local W, HGT = 830, 520
local CW, CH = 470, 240
local ROWS, ROWH = 19, 20
local RANGES = { { "1D", DAY }, { "3D", 3 * DAY }, { "7D", 7 * DAY }, { "14D" } }
local SORTS = { "Movers", "Cheap now", "A-Z", "Most data", "Latest" }

local frame, search, slider, canvas, strip, titleText, statText, hoverText, footText, emptyText
local sortBtn, watchBtn, starBtn, rangeBtns, rows = nil, nil, nil, {}, {}
local onlyStarred = false
local items, view = {}, {}
local sel, rangeIdx, sortIdx, offset = nil, 4, 1, 0
local function Stars()
	MarketScribeDB.stars = MarketScribeDB.stars or {}
	return MarketScribeDB.stars
end
local drawn
local requested = {}

--------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------

local function Money(c)
	c = math.floor((c or 0) + 0.5)
	if c >= 10000 then
		local g, s = math.floor(c / 10000), math.floor((c % 10000) / 100)
		if g >= 100 or s == 0 then return ("%dg"):format(g) end
		return ("%dg %ds"):format(g, s)
	elseif c >= 100 then
		local s, k = math.floor(c / 100), c % 100
		if k == 0 then return ("%ds"):format(s) end
		return ("%ds %dc"):format(s, k)
	end
	return ("%dc"):format(c)
end

local function Pct(x)
	if not x then return "" end
	local v = math.floor(math.abs(x) * 100 + 0.5)
	if v == 0 then return "|cffaaaaaa0%|r" end
	if x > 0 then return ("|cff40e080+%d%%|r"):format(v) end
	return ("|cffff6060-%d%%|r"):format(v)
end

local function ItemName(id)
	local db = MarketScribeDB
	db.names = db.names or {}
	local n = db.names[id]
	if n then return n end
	local gi = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local name = gi and gi(id)
	if name then
		db.names[id] = name
		return name
	end
	if not requested[id] then
		requested[id] = true
		if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
	end
end

local function Pool(create)
	local p = { list = {}, n = 0 }
	function p.get()
		p.n = p.n + 1
		local o = p.list[p.n]
		if not o then
			o = create()
			p.list[p.n] = o
		end
		o:Show()
		return o
	end
	function p.reset()
		for i = 1, p.n do p.list[i]:Hide() end
		p.n = 0
	end
	return p
end

--------------------------------------------------------------------------
-- item list
--------------------------------------------------------------------------

local function Stats(h, now)
	local c = #h
	local s = { cur = h[c - 1], last = h[c - 2], pts = c / 3 }
	local sum, n = 0, 0
	for i = 1, c, 3 do
		sum, n = sum + h[i + 1], n + 1
	end
	if n >= 4 then s.cheap = s.cur / (sum / n) end
	return s
end

local function BuildItems()
	items = {}
	local store = ns.Store()
	local now = time()
	for id, h in pairs(store.hist or {}) do
		if #h >= 3 then
			local s = Stats(h, now)
			s.id = id
			s.chg = ns.Trend and ns.Trend(id, 3) or nil
			items[#items + 1] = s
		end
	end
	for id in pairs(Stars()) do
		local h = store.hist and store.hist[id]
		if not h or #h < 3 then
			items[#items + 1] = { id = id, cur = (store.prices[id] and store.prices[id].price) or 0, last = 0, pts = 0 }
		end
	end
end

local function Key(s) return s.name or ("~" .. s.id) end

local function SortView()
	local mode = SORTS[sortIdx]
	local cmp
	if mode == "Movers" then
		cmp = function(a, b)
			local x, y = a.chg and math.abs(a.chg) or -1, b.chg and math.abs(b.chg) or -1
			if x ~= y then return x > y end
			return a.id < b.id
		end
	elseif mode == "Cheap now" then
		cmp = function(a, b)
			local x, y = a.cheap or 99, b.cheap or 99
			if x ~= y then return x < y end
			return a.id < b.id
		end
	elseif mode == "Most data" then
		cmp = function(a, b)
			if a.pts ~= b.pts then return a.pts > b.pts end
			return a.id < b.id
		end
	elseif mode == "Latest" then
		cmp = function(a, b)
			if a.last ~= b.last then return a.last > b.last end
			return a.id < b.id
		end
	else
		cmp = function(a, b)
			local x, y = Key(a):lower(), Key(b):lower()
			if x ~= y then return x < y end
			return a.id < b.id
		end
	end
	table.sort(view, cmp)
end

local RefreshRows, Draw

local function ApplyFilter()
	local q = (search:GetText() or ""):lower()
	q = q:gsub("^%s+", ""):gsub("%s+$", "")
	local qid = tonumber(q)
	view = {}
	local stars = Stars()
	for _, s in ipairs(items) do
		s.name = s.name or ItemName(s.id)
		local ok = q == ""
		if not ok then
			if qid and s.id == qid then
				ok = true
			elseif s.name and s.name:lower():find(q, 1, true) then
				ok = true
			end
		end
		if ok and onlyStarred and not stars[s.id] then ok = false end
		if ok then view[#view + 1] = s end
	end
	SortView()
	local maxOff = math.max(0, #view - ROWS)
	slider:SetMinMaxValues(0, maxOff)
	if offset > maxOff then offset = maxOff end
	slider:SetValue(offset)
	RefreshRows()
end

function RefreshRows()
	for i = 1, ROWS do
		local row, s = rows[i], view[offset + i]
		if s then
			row.id = s.id
			row.name:SetText((Stars()[s.id] and "|cffffd100*|r " or "") .. (s.name or ("item " .. s.id)))
			row.price:SetText(s.cur and s.cur > 0 and Money(s.cur) or "--")
			row.pct:SetText(Pct(s.chg))
			row.sel:SetShown(s.id == sel)
			row:Show()
		else
			row.id = nil
			row:Hide()
		end
	end
end

--------------------------------------------------------------------------
-- graph
--------------------------------------------------------------------------

local lines, dots, bars, labels

local function Seg(x1, y1, x2, y2, r, g, b, a, th)
	local l = lines.get()
	l:SetThickness(th or 2)
	l:SetColorTexture(r, g, b, a or 1)
	l:SetStartPoint("BOTTOMLEFT", canvas, x1, y1)
	l:SetEndPoint("BOTTOMLEFT", canvas, x2, y2)
end

local function DateText(t, withTime)
	return date(withTime and "%d %b %H:%M" or "%d %b", math.floor(t))
end

function Draw()
	lines.reset(); dots.reset(); bars.reset(); labels.reset()
	drawn = nil
	emptyText:Hide()
	local id = sel
	local h = id and ns.GetHistory(id)
	if not h or #h < 3 then
		titleText:SetText(id and (ItemName(id) or ("item " .. id)) or "MarketScribe history")
		statText:SetText("")
		if starBtn then starBtn:SetText(id and Stars()[id] and "Watching" or "Watch") end
		emptyText:SetText(id and "No history for this item yet." or (onlyStarred and "Nothing watched yet. Pick an item and click Watch." or "Pick an item on the left."))
		emptyText:Show()
		return
	end
	local name = ItemName(id) or ("item " .. id)
	local now = time()
	local span = RANGES[rangeIdx][2]
	local t0 = span and (now - span) or h[1]
	local t1 = now
	if t1 - t0 < 3600 then t0 = t1 - 3600 end

	local pts, prev = {}, nil
	for i = 1, #h, 3 do
		local t = h[i]
		if t >= t0 then
			if prev and #pts == 0 then pts[1] = { t = t0, p = prev[2], n = 0, held = true } end
			pts[#pts + 1] = { t = t, p = h[i + 1], n = h[i + 2] }
		else
			prev = { t, h[i + 1] }
		end
	end
	if #pts == 0 and prev then pts[1] = { t = t0, p = prev[2], n = 0, held = true } end

	local lo, hi, sum, cnt, maxN = nil, nil, 0, 0, 0
	for _, pt in ipairs(pts) do
		if not pt.held then
			if not lo or pt.p < lo then lo = pt.p end
			if not hi or pt.p > hi then hi = pt.p end
			sum, cnt = sum + pt.p, cnt + 1
			if pt.n > maxN then maxN = pt.n end
		end
	end
	local last = pts[#pts]
	if not lo then lo, hi = last.p, last.p end
	local avg = cnt > 0 and sum / cnt or last.p
	local pad = (hi - lo) * 0.12
	if pad <= 0 then pad = hi * 0.1 end
	local ylo, yhi = math.max(0, lo - pad), hi + pad
	local function X(t) return (t - t0) / (t1 - t0) * CW end
	local function Y(p) return (p - ylo) / (yhi - ylo) * CH end

	-- grid and y labels
	for k = 0, 4 do
		local y = k / 4 * CH
		Seg(0, y, CW, y, 1, 1, 1, 0.12, 1)
		local fs = labels.get()
		fs:SetParent(canvas)
		fs:SetJustifyH("RIGHT")
		fs:ClearAllPoints()
		fs:SetPoint("RIGHT", canvas, "BOTTOMLEFT", -4, y)
		fs:SetText(Money(ylo + (yhi - ylo) * k / 4))
	end
	-- x labels
	for k = 0, 4 do
		local t = t0 + (t1 - t0) * k / 4
		local fs = labels.get()
		fs:SetParent(canvas)
		fs:ClearAllPoints()
		fs:SetPoint("TOP", canvas, "BOTTOMLEFT", k / 4 * CW, -3)
		fs:SetJustifyH("CENTER")
		fs:SetText(DateText(t, span and span <= 2 * DAY))
	end

	-- average line and vendor line
	if cnt > 1 then
		Seg(0, Y(avg), CW, Y(avg), 0.7, 0.7, 0.7, 0.55, 1)
	end
	local vend = ns.Store().vendor and ns.Store().vendor[id]
	if vend and vend >= ylo and vend <= yhi then
		Seg(0, Y(vend), CW, Y(vend), 0.3, 0.85, 0.4, 0.6, 1)
	end

	-- price line (last point is held flat to now)
	drawn = { pts = {}, t0 = t0, t1 = t1 }
	for i, pt in ipairs(pts) do
		pt.x, pt.y = X(pt.t), Y(pt.p)
		if i > 1 then
			local a = pts[i - 1]
			Seg(a.x, a.y, pt.x, pt.y, 1, 0.82, 0, 1, 2)
		end
		if not pt.held then drawn.pts[#drawn.pts + 1] = pt end
	end
	if last.x < CW - 1 then
		Seg(last.x, last.y, CW, last.y, 1, 0.82, 0, 0.4, 2)
	end
	if #pts <= 150 then
		for _, pt in ipairs(pts) do
			if not pt.held then
				local d = dots.get()
				d:ClearAllPoints()
				d:SetPoint("CENTER", canvas, "BOTTOMLEFT", pt.x, pt.y)
				d:SetColorTexture(1, 0.9, 0.3, 1)
			end
		end
	end

	-- listing strip
	if maxN > 0 then
		for _, pt in ipairs(drawn.pts) do
			if pt.n > 0 then
				local b = bars.get()
				b:ClearAllPoints()
				b:SetPoint("BOTTOMLEFT", strip, pt.x - 1, 0)
				b:SetSize(3, math.max(2, pt.n / maxN * 38))
				b:SetColorTexture(0.35, 0.6, 1, 0.9)
			end
		end
	end
	strip.label:SetText(maxN > 0 and ("Units listed (max " .. maxN .. ")") or "Units listed: none recorded in this range")

	-- header
	titleText:SetText(name)
	if starBtn then starBtn:SetText(Stars()[id] and "Watching" or "Watch") end
	local cur = h[#h - 1]
	local vsAvg = avg > 0 and (cur - avg) / avg or 0
	local tr, _, trDays = ns.Trend(id, 3)
	statText:SetText(("Now |cffffd100%s|r (%s)   Low %s   High %s   Avg %s   %s vs avg   %s%s   %d points%s"):format(
		Money(cur), DateText(h[#h - 2], true), Money(lo), Money(hi), Money(avg), Pct(vsAvg),
		tr and (("%.0f"):format(trDays) == "3" and "3-day " or ("%.1f-day "):format(trDays)) or "", tr and Pct(tr) or "",
		cnt, vend and ("   Vendor " .. Money(vend)) or ""))
	hoverText:SetText("")
end

local function Select(id)
	sel = id
	RefreshRows()
	Draw()
end

--------------------------------------------------------------------------
-- window
--------------------------------------------------------------------------

local function SetRange(i)
	rangeIdx = i
	for k, b in ipairs(rangeBtns) do b:SetEnabled(k ~= i) end
	Draw()
end

local pendingRefresh
local function LaterRefresh()
	if pendingRefresh or not frame or not frame:IsShown() then return end
	pendingRefresh = true
	C_Timer.After(0.5, function()
		pendingRefresh = nil
		if frame and frame:IsShown() then
			ApplyFilter()
			if sel then titleText:SetText(ItemName(sel) or ("item " .. sel)) end
		end
	end)
end

local function Build()
	frame = CreateFrame("Frame", "MarketScribeGraphFrame", UIParent, "BasicFrameTemplateWithInset")
	frame:SetSize(W, HGT)
	frame:SetFrameStrata("HIGH")
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, _, rp, x, y = self:GetPoint()
		ns.Settings().graphPos = { p, rp, x, y }
	end)
	local pos = ns.Settings().graphPos
	if pos then
		frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	else
		frame:SetPoint("CENTER")
	end
	tinsert(UISpecialFrames, "MarketScribeGraphFrame")
	local title = frame.TitleText or frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	if not frame.TitleText then title:SetPoint("TOP", 0, -5) end
	title:SetText("MarketScribe -- price history")

	-- search
	search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	search:SetSize(100, 20)
	search:SetPoint("TOPLEFT", 20, -34)
	search:SetAutoFocus(false)
	search:SetMaxLetters(40)
	search:SetScript("OnEscapePressed", search.ClearFocus)
	search:SetScript("OnEnterPressed", search.ClearFocus)
	local hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("LEFT", 2, 0)
	hint:SetText("Search name or item ID")
	local timer
	search:SetScript("OnTextChanged", function(self)
		hint:SetShown((self:GetText() or "") == "")
		if timer then timer:Cancel() end
		timer = C_Timer.NewTimer(0.15, function()
			timer = nil
			offset = 0
			ApplyFilter()
			if view[1] and not (sel and ns.GetHistory(sel) and (search:GetText() or "") == "") then
				Select(view[1].id)
			end
		end)
	end)

	sortBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	sortBtn:SetSize(84, 22)
	sortBtn:SetPoint("LEFT", search, "RIGHT", 8, 0)
	sortBtn:SetText(SORTS[sortIdx])
	sortBtn:SetScript("OnClick", function(self)
		sortIdx = sortIdx % #SORTS + 1
		self:SetText(SORTS[sortIdx])
		offset = 0
		ApplyFilter()
	end)
	sortBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Sort order (click to change)")
		GameTooltip:AddLine("Movers: biggest price change over the last 3 days.", 1, 1, 1)
		GameTooltip:AddLine("Cheap now: lowest against its 2-week average.", 1, 1, 1)
		GameTooltip:AddLine("A-Z, Most data points, Latest scanned.", 1, 1, 1)
		GameTooltip:Show()
	end)
	sortBtn:SetScript("OnLeave", GameTooltip_Hide)

	watchBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	watchBtn:SetSize(60, 22)
	watchBtn:SetPoint("LEFT", sortBtn, "RIGHT", 2, 0)
	watchBtn:SetText("Watched")
	watchBtn:SetScript("OnClick", function(self)
		onlyStarred = not onlyStarred
		self:SetText(onlyStarred and "|cffffd100Watched|r" or "Watched")
		offset = 0
		BuildItems()
		ApplyFilter()
		local inView = false
		for _, s in ipairs(view) do if s.id == sel then inView = true break end end
		if not inView then
			if view[1] then Select(view[1].id) else sel = nil; RefreshRows(); Draw() end
		end
	end)
	watchBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Show only the items you are watching")
		GameTooltip:Show()
	end)
	watchBtn:SetScript("OnLeave", GameTooltip_Hide)

	-- list
	local listTop = -62
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, frame)
		row:SetSize(232, ROWH)
		row:SetPoint("TOPLEFT", 16, listTop - (i - 1) * ROWH)
		row:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2")
		row.sel = row:CreateTexture(nil, "BACKGROUND")
		row.sel:SetAllPoints()
		row.sel:SetColorTexture(1, 0.82, 0, 0.18)
		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.name:SetPoint("LEFT", 3, 0)
		row.name:SetWidth(118)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)
		row.pct = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.pct:SetPoint("RIGHT", -2, 0)
		row.pct:SetWidth(36)
		row.pct:SetJustifyH("RIGHT")
		row.price = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		row.price:SetPoint("RIGHT", row.pct, "LEFT", -2, 0)
		row.price:SetWidth(64)
		row.price:SetJustifyH("RIGHT")
		row:SetScript("OnClick", function(self) if self.id then Select(self.id) end end)
		rows[i] = row
	end
	slider = CreateFrame("Slider", nil, frame)
	slider:SetOrientation("VERTICAL")
	slider:SetSize(12, ROWS * ROWH)
	slider:SetPoint("TOPLEFT", 252, listTop)
	local bg = slider:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.4)
	slider:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
	slider:GetThumbTexture():SetSize(14, 20)
	slider:SetMinMaxValues(0, 0)
	slider:SetValueStep(1)
	slider:SetObeyStepOnDrag(true)
	slider:SetValue(0)
	slider:SetScript("OnValueChanged", function(_, v)
		offset = math.floor(v + 0.5)
		RefreshRows()
	end)
	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, delta)
		slider:SetValue(slider:GetValue() - delta * 3)
	end)
	local count = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	count:SetPoint("TOPLEFT", 18, listTop - ROWS * ROWH - 4)
	frame.count = count

	-- right side
	local x0 = 292
	titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	titleText:SetPoint("TOPLEFT", x0, -34)
	titleText:SetWidth(W - x0 - 20)
	titleText:SetJustifyH("LEFT")
	titleText:SetWordWrap(false)
	statText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	statText:SetPoint("TOPLEFT", x0, -58)
	statText:SetWidth(W - x0 - 20)
	statText:SetJustifyH("LEFT")
	statText:SetWordWrap(true)

	starBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	starBtn:SetSize(80, 20)
	starBtn:SetPoint("TOPRIGHT", -16, -84)
	starBtn:SetText("Watch")
	starBtn:SetScript("OnClick", function()
		if not sel then return end
		local st = Stars()
		st[sel] = (not st[sel]) or nil
		BuildItems()
		ApplyFilter()
		Draw()
	end)
	starBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Add to or remove from your watchlist")
		GameTooltip:AddLine("Watched items get a * in the list; use the Watched button to show only them.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	starBtn:SetScript("OnLeave", GameTooltip_Hide)

	for i, r in ipairs(RANGES) do
		local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		b:SetSize(46, 20)
		b:SetPoint("TOPLEFT", x0 + (i - 1) * 50, -84)
		b:SetText(r[1])
		b:SetScript("OnClick", function() SetRange(i) end)
		rangeBtns[i] = b
	end

	canvas = CreateFrame("Frame", nil, frame)
	canvas:SetSize(CW, CH)
	canvas:SetPoint("TOPLEFT", x0 + 50, -128)
	local cbg = canvas:CreateTexture(nil, "BACKGROUND")
	cbg:SetAllPoints()
	cbg:SetColorTexture(0, 0, 0, 0.45)
	emptyText = canvas:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	emptyText:SetPoint("CENTER")

	strip = CreateFrame("Frame", nil, frame)
	strip:SetSize(CW, 40)
	strip:SetPoint("TOPLEFT", canvas, "BOTTOMLEFT", 0, -26)
	local sbg = strip:CreateTexture(nil, "BACKGROUND")
	sbg:SetAllPoints()
	sbg:SetColorTexture(0, 0, 0, 0.3)
	strip.label = strip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	strip.label:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -3)

	hoverText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	hoverText:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -22)
	hoverText:SetWidth(CW)
	hoverText:SetJustifyH("LEFT")

	footText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	footText:SetPoint("BOTTOMLEFT", 16, 12)
	footText:SetPoint("BOTTOMRIGHT", -16, 12)
	footText:SetJustifyH("LEFT")
	footText:SetWordWrap(true)
	footText:SetText("Gold line: lowest AH price when MarketScribe saw it, held flat until the next scan (fainter). Grey line: average. Green line: vendor price. Blue bars: units listed. Two weeks of history are kept; friends' shared prices add their own scan times.")

	-- pools
	lines = Pool(function() return canvas:CreateLine(nil, "ARTWORK") end)
	dots = Pool(function()
		local t = canvas:CreateTexture(nil, "OVERLAY")
		t:SetSize(4, 4)
		return t
	end)
	bars = Pool(function() return strip:CreateTexture(nil, "ARTWORK") end)
	labels = Pool(function() return frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall") end)

	-- hover
	local hv = canvas:CreateTexture(nil, "OVERLAY")
	hv:SetSize(1, CH)
	hv:SetColorTexture(1, 1, 1, 0.5)
	hv:Hide()
	local hd = canvas:CreateTexture(nil, "OVERLAY")
	hd:SetSize(7, 7)
	hd:SetColorTexture(1, 1, 1, 1)
	hd:Hide()
	canvas:SetScript("OnUpdate", function(self)
		if not drawn or #drawn.pts == 0 or not self:IsMouseOver() then
			hv:Hide(); hd:Hide()
			return
		end
		local cx = GetCursorPosition() / self:GetEffectiveScale() - self:GetLeft()
		local best, bd
		for _, pt in ipairs(drawn.pts) do
			local d = math.abs(pt.x - cx)
			if not bd or d < bd then best, bd = pt, d end
		end
		hv:ClearAllPoints()
		hv:SetPoint("BOTTOMLEFT", self, best.x, 0)
		hv:Show()
		hd:ClearAllPoints()
		hd:SetPoint("CENTER", self, "BOTTOMLEFT", best.x, best.y)
		hd:Show()
		local txt = ("%s   |cffffd100%s|r"):format(DateText(best.t, true), Money(best.p))
		if best.n > 0 then
			txt = txt .. ("   %d listed"):format(best.n)
		elseif best.n < 0 then
			txt = txt .. "   (from a friend)"
		end
		hoverText:SetText(txt)
	end)
	canvas:SetScript("OnLeave", function() if hoverText then hoverText:SetText("") end end)

	frame:SetScript("OnShow", function()
		ns.CatchUpHistory()
		BuildItems()
		ApplyFilter()
		frame.count:SetText(("%d items with history"):format(#items))
		if not sel or not ns.GetHistory(sel) then
			sel = view[1] and view[1].id or nil
		end
		SetRange(rangeIdx)
		RefreshRows()
	end)

	local ev = CreateFrame("Frame")
	ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	ev:SetScript("OnEvent", LaterRefresh)
end

local function IdFrom(text)
	return tonumber((text or ""):match("item:(%d+)") or "")
end

function ns.ToggleGraph(arg)
	if not frame then Build() end
	arg = (arg or ""):match("^%s*(.-)%s*$")
	if arg ~= "" then
		local id = IdFrom(arg)
		frame:Show()
		search:SetText(id and tostring(id) or arg)
		C_Timer.After(0.3, function()
			if view[1] then Select(view[1].id) end
		end)
	elseif frame:IsShown() then
		frame:Hide()
	else
		frame:Show()
	end
end
