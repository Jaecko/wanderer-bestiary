local _, ns = ...
local L = ns.L

-- A creature's card, beside the window that asked (the bestiary, Wanderer Quests' sheet, the atlas), or in the
-- middle of the screen. At its top its name, its rank, its levels and its kind, then its model, turned by
-- dragging, brought closer by the wheel. Below, scrolled: where it lives (a click: the way there), its strength
-- and its spells, what it carries, and your hunting log with it. A creature you never met: its silhouette only,
-- where it lives; met but never killed: its strength and spells kept for your first kill.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin

local WIDTH = 380
local MODEL_HEIGHT = 210
local GAP = 4
local ALONE_HEIGHT = 600
local ITEMS_MOST = 12
local ITEM_SIZE = 28
local ZOOM_LEAST, ZOOM_MOST = 0.6, 2.2
local TURN_STEP = 0.35 -- a step of the cross, turning the model

local card, scroll, content, bar, owner
local shown -- the creature shown
local texts, rows, rules, used = {}, {}, {}, { texts = 0, rows = 0, rules = 0 }
local items = {}

local RANK_TONES = { [1] = "gold", [2] = "blue", [3] = "red", [4] = "blue" }

-- The pieces, made once and used again at each drawing --------------------------------------------------------

local function Text(template, role)
	used.texts = used.texts + 1
	local text = texts[used.texts]
	if not text then
		text = Skin.Text(content, template, role)
		text:SetJustifyH("LEFT")
		texts[used.texts] = text
	end
	local c = Skin.COLORS[role or "text"] or Skin.COLORS.text
	text:SetFontObject(Skin.FontFor and Skin.FontFor(template) or template)
	text:SetTextColor(c[1], c[2], c[3])
	text:ClearAllPoints()
	text:SetWidth(WIDTH - Skin.Margin() * 2 - 24)
	text:Show()
	return text
end

-- A line to click (a place, a spell): its icon, its words, its tooltip; onClick (nil: none).
local function Row()
	used.rows = used.rows + 1
	local row = rows[used.rows]
	if not row then
		row = CreateFrame("Button", nil, content)
		row:SetHeight(Skin.ROW.compact)
		row.hover = row:CreateTexture(nil, "BACKGROUND")
		row.hover:SetAllPoints()
		row.hover:SetColorTexture(1, 1, 1, Skin.HOVER)
		row.hover:Hide()
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(18, 18)
		row.icon:SetPoint("LEFT", 2, 0)
		row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		row.text = Skin.Text(row, "GameTooltipText", "text")
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)
		row.more = Skin.Glyph(row, "chevron", 10)
		row.more:SetPoint("RIGHT", -4, 0)
		row:SetScript("OnEnter", function(self)
			if self.onClick then self.hover:Show() end
			if self.spell then
				GameTooltip:SetOwner(self, "ANCHOR_LEFT")
				pcall(GameTooltip.SetSpellByID, GameTooltip, self.spell)
				GameTooltip:Show()
			elseif self.tip then
				Skin.ShowTip(self, self.tip)
			end
		end)
		row:SetScript("OnLeave", function(self)
			self.hover:Hide()
			GameTooltip:Hide()
		end)
		row:SetScript("OnClick", function(self)
			if not self.onClick then return end
			Skin.Play("click")
			self.onClick()
		end)
		rows[used.rows] = row
	end
	row:ClearAllPoints()
	row:SetPoint("LEFT", content, "LEFT", 0, 0)
	row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
	row.onClick, row.spell, row.tip = nil, nil, nil
	row:Show()
	return row
end

local function Item(at)
	local square = items[at]
	if not square then
		square = Skin.Icon(content, ITEM_SIZE)
		square:EnableMouse(true)
		square.padTip = true -- (a controller stops on it to read it)
		square.count = Skin.Text(square, "NumberFontNormalSmall", "text")
		square.count:SetPoint("BOTTOMRIGHT", -2, 2)
		Skin.ItemTooltip(square, function(self) return self.item end)
		items[at] = square
	end
	square:Show()
	return square
end

-- The drawing ----------------------------------------------------------------------------------------------------

local y
local function Place(region, height, x)
	region:SetPoint("TOPLEFT", content, "TOPLEFT", x or 0, -y)
	y = y + height
end

local function Kicker(words)
	y = y + 14
	local text = Text("GameTooltipTextSmall", "kicker")
	text:SetText(U.Upper(words))
	Place(text, 16)
	used.rules = used.rules + 1
	local rule = rules[used.rules]
	if not rule then
		rule = Skin.Rule(content, false, 0.35)
		rules[used.rules] = rule
	end
	rule:ClearAllPoints()
	rule:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -3)
	rule:SetPoint("RIGHT", content, "RIGHT", 0, 0)
	rule:Show()
	y = y + 6
end

-- A line: its words on the left, its value on the right.
local function Line(label, value)
	local left = Text("GameTooltipText", "soft")
	left:SetText(label)
	Place(left, 0)
	local right = Text("GameTooltipText", "text")
	right:SetJustifyH("RIGHT")
	right:SetText(value)
	right:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
	y = y + math.max(18, U.Measure(right, "GetStringHeight", 14) + 4)
end

local function Words(words, role)
	local text = Text("GameTooltipText", role or "muted")
	text:SetText(words)
	Place(text, U.Measure(text, "GetStringHeight", 14) + 6)
end

local function Number(value)
	if not value then return "" end
	return _G.BreakUpLargeNumbers and BreakUpLargeNumbers(value) or tostring(value)
end

local function Seconds(value)
	return (("%.1f"):format(value)):gsub("%.0$", "")
end

local function Draw()
	if not (card and shown) then return end
	for _, text in ipairs(texts) do text:Hide() end
	for _, row in ipairs(rows) do row:Hide() end
	for _, square in ipairs(items) do square:Hide() end
	for _, rule in ipairs(rules) do rule:Hide() end
	used.texts, used.rows, used.rules, y = 0, 0, 0, 0
	local creature = ns.Creature(shown)
	if not creature then return end
	local db = ns.Journal()
	local met, killed = db.seen[shown] ~= nil or db.kills[shown] ~= nil, db.kills[shown] ~= nil
	-- The heading: its name (or "???"), its rank, its levels and kind.
	card.title:SetText(met and creature.name or L.UNKNOWN_NAME)
	local rank = ns.RANKS[creature.rank]
	card.rank:Set(rank and L[rank] or nil, RANK_TONES[creature.rank])
	local kind = ns.KindName(creature)
	local hidden = ns.Hidden and ns.Hidden(creature, met)
	card.levels:SetText(L.LEVEL:format(hidden and "?" or ns.Levels(creature)) .. (kind and ("  \194\183  " .. kind) or ""))
	-- The model: drawn once met, else its place empty with a question mark.
	card.unknown:SetShown(not met)
	card.model:SetShown(met)
	if met and card.model.SetDisplayInfo and card.model.shownId ~= shown then
		card.model.shownId = shown
		pcall(card.model.SetDisplayInfo, card.model, creature.models[1])
		card.model.turn, card.model.zoom = 0.6, 1
		pcall(card.model.SetRotation, card.model, card.model.turn)
		if card.model.SetCamDistanceScale then pcall(card.model.SetCamDistanceScale, card.model, card.model.zoom) end
	end
	local strip = {}
	if db.kills[shown] then strip[#strip + 1] = L.STRIP_KILLS:format(Skin.Colorize(db.kills[shown], "gold")) end
	if db.deaths[shown] then strip[#strip + 1] = L.STRIP_DEATHS:format(Skin.Colorize(db.deaths[shown], "bad")) end
	card.strip:SetText(met and (strip[1] and table.concat(strip, "  \194\183  ") or L.STRIP_NONE) or "")
	-- Where it lives.
	Kicker(L.SEC_WHERE)
	if hidden then Words(L.SURPRISE_KEPT) end
	for index, area in ipairs(hidden and {} or creature.zones) do
		local row = Row()
		Place(row, 24)
		row.icon:SetTexture("Interface\\Minimap\\Tracking\\None")
		row.icon:SetShown(false)
		row.text:ClearAllPoints()
		row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
		row.text:SetPoint("RIGHT", row.more, "LEFT", -6, 0)
		row.text:SetText(U.AreaName(area) or ("#" .. area))
		local map, x, py = ns.PlaceOnMap(creature, index > 1 and area or nil)
		row.more:SetShown(map ~= nil and x ~= nil)
		if map and x then
			row.tip = L.GO_THERE
			row.onClick = function() U.Go(map, x, py, creature.name, { kind = "creature", label = creature.name }) end
		end
	end
	if not met then
		y = y + 8
		Words(L.NOT_MET)
	else
		-- Its strength and its spells: once you killed it.
		Kicker(L.SEC_FIGHT)
		if not killed then
			Words(L.LOCKED)
		else
			Line(L.HEALTH, Number(creature.health))
			if creature.mana and creature.mana > 0 then Line(L.MANA, Number(creature.mana)) end
			if creature.hitHigh and creature.hitHigh > 0 then
				Line(L.BLOWS, L.BLOWS_VALUE:format(Number(creature.hitLow), Number(creature.hitHigh), Seconds(creature.swing)))
			end
			if creature.armor and creature.armor > 0 then Line(L.ARMOR, Number(creature.armor)) end
			local spells = ns.Spells(creature)
			if spells[1] then
				Kicker(L.SEC_SPELLS)
				for _, spell in ipairs(spells) do
					local row = Row()
					Place(row, 24)
					row.icon:SetShown(true)
					row.icon:SetTexture(spell.icon)
					row.text:ClearAllPoints()
					row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
					row.text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
					row.text:SetText(spell.name)
					row.more:Hide()
					row.spell = spell.id
				end
			end
			-- What it carries.
			local any = creature.goldHigh > 0 or creature.skinned or creature.pickpocket
			if any then
				Kicker(L.SEC_ON_IT)
				if creature.goldHigh > 0 then
					Line(L.GOLD, creature.goldLow == creature.goldHigh and U.Coins(creature.goldHigh)
						or (U.Coins(creature.goldLow) .. " \194\183 " .. U.Coins(creature.goldHigh)))
				end
				if creature.skinned then Words(L.SKINNABLE, "soft") end
				if creature.pickpocket then Words(L.PICKPOCKET, "soft") end
			end
		end
		-- Your hunting log.
		Kicker(L.SEC_YOURS)
		local now = time()
		if killed then
			Line(L.KILLED, U.Plural(db.kills[shown], L.TIMES_ONE, L.TIMES))
			if db.first[shown] then Line(L.FIRST_TIME, U.AgoWords(now - db.first[shown])) end
			if db.last[shown] and db.kills[shown] > 1 then Line(L.LAST_TIME, U.AgoWords(now - db.last[shown])) end
		else
			Words(L.NOT_KILLED)
		end
		if db.deaths[shown] then Line(L.KILLED_YOU, U.Plural(db.deaths[shown], L.TIMES_ONE, L.TIMES)) end
		local loot = db.loot[shown]
		if loot and next(loot) then
			y = y + 6
			local label = Text("GameTooltipTextSmall", "label")
			label:SetText(L.LOOTED)
			Place(label, 18)
			local list = {}
			for item, count in pairs(loot) do list[#list + 1] = { item = item, count = count } end
			table.sort(list, function(a, b) return a.count > b.count end)
			local perRow = math.floor((WIDTH - Skin.Margin() * 2 - 24) / (ITEM_SIZE + 4))
			for at, entry in ipairs(list) do
				if at > ITEMS_MOST then break end
				local square = Item(at)
				square.item = entry.item
				square:Set(U.ItemIcon(entry.item), U.ItemQuality(entry.item))
				square.count:SetText(entry.count > 1 and entry.count or "")
				square:ClearAllPoints()
				square:SetPoint("TOPLEFT", content, "TOPLEFT", ((at - 1) % perRow) * (ITEM_SIZE + 4), -(y + math.floor((at - 1) / perRow) * (ITEM_SIZE + 4)))
			end
			y = y + math.ceil(math.min(#list, ITEMS_MOST) / perRow) * (ITEM_SIZE + 4)
		end
	end
	content:SetHeight(math.max(1, y + 8))
	scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(), math.max(0, content:GetHeight() - scroll:GetHeight())))
	bar:Set(content:GetHeight(), scroll:GetHeight(), scroll:GetVerticalScroll())
	-- The way there, at its foot.
	local map, x = ns.PlaceOnMap(creature)
	card.go:SetShown(map ~= nil and x ~= nil)
	-- (Wanderer Maps there and its atlas on: a Maps that says so is asked, an older one taken at its word)
	local maps = _G.WandererMaps
	local atlas = type(maps) == "table" and maps.ShowHabitat ~= nil and (not maps.AtlasOn or maps.AtlasOn())
	local canShow = met and not hidden and atlas and ns.Habitat(shown)[1] ~= nil
	card.atlas:ClearAllPoints()
	if card.go:IsShown() then card.atlas:SetPoint("LEFT", card.go, "RIGHT", 8, 0) else card.atlas:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", Skin.Margin() + 8, Skin.Margin() + 12) end
	card.atlas:SetShown(canShow and true or false)
end

-- The window ---------------------------------------------------------------------------------------------------

local function MakeModel(parent)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetHeight(MODEL_HEIGHT)
	holder.ground = holder:CreateTexture(nil, "BACKGROUND")
	holder.ground:SetAllPoints()
	holder.ground:SetColorTexture(0.05, 0.06, 0.09, 0.85)
	Skin.Edges(holder, Skin.RGB("gold", 0.35))
	local ok, model = pcall(CreateFrame, "PlayerModel", nil, holder)
	if not ok then model = CreateFrame("Frame", nil, holder) end
	model:SetPoint("TOPLEFT", 1, -1)
	model:SetPoint("BOTTOMRIGHT", -1, 1)
	model:EnableMouse(true)
	model:EnableMouseWheel(true)
	model.turn, model.zoom = 0.6, 1
	-- Dragged: turned; the wheel: closer or further.
	model:SetScript("OnMouseDown", function(self) self.from = GetCursorPosition() end)
	model:SetScript("OnMouseUp", function(self) self.from = nil end)
	model:SetScript("OnUpdate", function(self)
		if not self.from then return end
		local at = GetCursorPosition()
		self.turn = self.turn + (at - self.from) / 80
		self.from = at
		if self.SetRotation then pcall(self.SetRotation, self, self.turn) end
	end)
	model:SetScript("OnMouseWheel", function(self, delta)
		self.zoom = math.max(ZOOM_LEAST, math.min(ZOOM_MOST, self.zoom - delta * 0.15))
		if self.SetCamDistanceScale then pcall(self.SetCamDistanceScale, self, self.zoom) end
	end)
	-- A controller: the cross's left and right turn it (held: again and again), the right stick brings it closer.
	model.padAdjust = function(self, delta)
		self.turn = self.turn + delta * TURN_STEP
		if self.SetRotation then pcall(self.SetRotation, self, self.turn) end
	end
	model.padWheel = true
	model.padTip = true -- (not a button: reached all the same)
	Skin.Tooltip(model, function()
		if not (U.UsingPad and U.UsingPad()) then return L.MODEL_TIP end
		return Skin.PadKeys and Skin.PadKeys({ { "PADDLEFT PADDRIGHT", "TURN" }, { "PADRSTICKAXIS", "ZOOM" } }) or L.MODEL_TIP_PAD
	end)
	holder.model = model
	-- Never met: a question mark in its place.
	holder.unknown = Skin.Text(holder, "GameFontNormalHuge", "muted")
	holder.unknown:SetPoint("CENTER")
	holder.unknown:SetText("?")
	return holder
end

local function Create()
	card = Skin.CreateWindow("WandererBestiaryCard", "MEDIUM")
	if Skin.PadWindow then Skin.PadWindow(card, { side = true }) end
	card:SetWidth(WIDTH)
	card:EnableMouse(true)
	card:SetClampedToScreen(true)
	local margin = Skin.Margin() + 8
	Skin.CloseButton(card, function() ns.HideCard() end)
	local _, title = Skin.Header(card, L.TITLE, "")
	card.title = title
	title:SetPoint("RIGHT", card, "RIGHT", -margin - 18, 0)
	title:SetWordWrap(true)
	card.rank = Skin.Chip(card)
	card.rank:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	card.levels = Skin.Text(card, "GameTooltipText", "soft")
	card.levels:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -26)
	local model = MakeModel(card)
	model:SetPoint("TOPLEFT", card.levels, "BOTTOMLEFT", 0, -10)
	model:SetPoint("RIGHT", card, "RIGHT", -margin, 0)
	card.model, card.unknown = model.model, model.unknown
	card.modelHolder = model
	-- The way there, at the foot.
	card.go = Skin.Button(card, L.GO_THERE, function()
		local creature = shown and ns.Creature(shown)
		local map, x, py = ns.PlaceOnMap(creature)
		if map and x then U.Go(map, x, py, creature.name, { kind = "creature", label = creature.name }) end
	end, "main")
	card.go:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", margin, margin)
	-- Its habitat drawn on Wanderer Maps' atlas, point by point.
	card.atlas = Skin.SmallButton(card, L.ON_ATLAS, function()
		local maps = _G.WandererMaps
		local creature = shown and ns.Creature(shown)
		if not (creature and type(maps) == "table" and maps.ShowHabitat) then return end
		maps.ShowHabitat(shown, creature.name, ns.Habitat(shown))
	end, L.ON_ATLAS_DESC)
	card.atlas:SetPoint("LEFT", card.go, "RIGHT", 8, 0)
	-- What it says, scrolled by the wheel.
	scroll = CreateFrame("ScrollFrame", nil, card)
	-- (under the model, your log with it in one line: kills, deaths)
	card.strip = Skin.Text(card, "GameTooltipTextSmall", "soft")
	card.strip:SetPoint("TOP", model, "BOTTOM", 0, -6)
	scroll:SetPoint("TOPLEFT", model, "BOTTOMLEFT", 0, -24)
	scroll:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -margin, margin + 34)
	content = CreateFrame("Frame", nil, scroll)
	content:SetSize(WIDTH - margin * 2, 1)
	scroll:SetScrollChild(content)
	bar = Skin.ScrollBar(card, function(offset)
		scroll:SetVerticalScroll(offset)
		bar:Set(content:GetHeight(), scroll:GetHeight(), offset)
	end)
	bar:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", Skin.SCROLL_WIDTH, 0)
	bar:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", Skin.SCROLL_WIDTH, 0)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local most = math.max(0, content:GetHeight() - self:GetHeight())
		self:SetVerticalScroll(math.max(0, math.min(most, self:GetVerticalScroll() - delta * 40)))
		bar:Set(content:GetHeight(), self:GetHeight(), self:GetVerticalScroll())
	end)
	card:Hide()
	Skin.Get(card):Layout()
end

-- Where it stands: on the right of the window that asked when the screen has room, else on the left of it (and
-- of the window it is itself beside: a sheet beside its window), never over them nor moving them; room on neither
-- side: in the middle of the screen (Wanderer's own way, the same for every sheet of the family). As tall as that
-- window when it is tall, else its own height from its top.
local function Put()
	card:ClearAllPoints()
	if not (owner and owner:IsShown()) then
		if card:GetParent() ~= UIParent then card:SetParent(UIParent) end
		card:SetFrameStrata("MEDIUM")
		card:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
		card:SetHeight(ALONE_HEIGHT)
		return
	end
	if card:GetParent() ~= owner then
		card:SetParent(owner)
		card:SetFrameLevel(owner:GetFrameLevel() + 10)
	end
	-- (the window it stands beside, when that one is further left: the card goes left of both)
	local holder = owner:GetParent()
	if not (holder and holder ~= UIParent and holder.GetLeft and (holder:GetLeft() or math.huge) < (owner:GetLeft() or 0)) then holder = nil end
	local tall = (owner:GetHeight() or 0) >= ALONE_HEIGHT - 40
	local side = Skin.Beside(card, owner, WIDTH, GAP, not tall and ALONE_HEIGHT or nil, { still = true, holder = holder })
	if side == "center" then
		card:ClearAllPoints()
		card:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
		card:SetHeight(ALONE_HEIGHT)
	end
end

-- A creature's card (its id), beside a window (nil: alone). False when the bestiary does not know it.
function ns.ShowCard(id, beside)
	id = tonumber(id)
	if not (id and ns.Known(id)) then return false end
	if not card then Create() end
	owner = beside
	-- (alone, it takes the controller as a window of its own; beside another, it is that one's side sheet)
	if Skin.PadWindow then Skin.PadWindow(card, { takes = beside == nil }) end
	local changed = shown ~= id
	shown = id
	Put()
	card:Show()
	if changed then scroll:SetVerticalScroll(0) end
	Draw()
	Skin.Get(card):Layout()
	return true
end

function ns.HideCard()
	shown = nil
	if card then card:Hide() end
end

function ns.CardShown() return card ~= nil and card:IsShown() and shown or nil end
function ns.CardOwner() return card and card:IsShown() and owner or nil end
function ns.Card() return card end -- (tests)

ns.OnChanged(function() if ns.CardShown() then Draw() end end)
