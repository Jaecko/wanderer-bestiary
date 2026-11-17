local ADDON, ns = ...
local L = ns.L

-- The bestiary: the creatures of the zone you are in ("Here"), or all of them, each with its portrait, its rank,
-- its levels and how many you killed; those you never met in shadow ("???"), where they live under the mouse. A
-- search and a kind narrow the list. A click opens the creature's card beside. "Records": your hunting log
-- counted (discovered, killed, your series, your nemesis...), a click on a creature's line opens its card.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Clean = U and U.Clean

local WIDTH, ROWS = 520, 11
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
-- (a first kill's notice: the hunter's mark, a skull for a boss; never the question mark of a creature not met)
local PREY_ICON, BOSS_ICON = "Interface\\Icons\\Ability_Hunter_SniperShot", "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"

local window, list, tabs, search, kindBox
local page = "here"
local query, kindChosen = "", 0
local sortBy, descending = "level", false
local entries = {}

local function Settings() return W and W.Settings and W.Settings("bestiary") or nil end
local function On()
	local settings = Settings()
	return settings and settings.enabled
end
-- (said as every addon of the family says it)
local function SayOff() W.Print(L.EXT_TURNED_OFF:format(L.ADDON)) end

-- The zone you are in: its map, its name (plain), to find the creatures living there.
local function Here()
	local map = C_Map and U.Clean(U.Safe(C_Map.GetBestMapForUnit, "player"))
	local zone = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
	local info = map and U.Safe(C_Map.GetMapInfo, map)
	-- (a part of a zone: the zone around it)
	while type(info) == "table" and (U.Clean(info.mapType) or zone) > zone and U.Clean(info.parentMapID) do
		local parent = U.Safe(C_Map.GetMapInfo, U.Clean(info.parentMapID))
		if type(parent) ~= "table" then break end
		map, info = U.Clean(info.parentMapID), parent
	end
	return map, type(info) == "table" and U.PlainName(U.Clean(info.name)) or nil
end

-- "Keep the surprise": a boss, a rare or an elite you never met tells neither its level nor where it lives.
function ns.Hidden(creature, met)
	local settings = Settings()
	return not met and creature.rank > 0 and settings ~= nil and settings.surprise and true or false
end

local function LivesHere(creature, map, name)
	for _, area in ipairs(creature.zones) do
		if (name and ns.PlainArea(area) == name) or (map and U.MapOfArea and U.MapOfArea(area) == map) then return true end
	end
	return false
end

-- The list --------------------------------------------------------------------------------------------------------

-- (one pass over every creature at each drawing: a scroll, a letter typed, a kill while it is open)
local zoneCount = { met = 0, killed = 0, of = 0 }
local function Gather()
	wipe(entries)
	local db = ns.Journal()
	local map, name = Here()
	zoneCount.met, zoneCount.killed, zoneCount.of, zoneCount.name = 0, 0, 0, name
	local folded = U.Fold and U.Fold(query) or query:lower()
	for _, creature in ipairs(ns.All()) do
		local met = db.seen[creature.id] ~= nil or db.kills[creature.id] ~= nil
		local here = page == "here" and LivesHere(creature, map, name)
		if here then
			zoneCount.of = zoneCount.of + 1
			if met then zoneCount.met = zoneCount.met + 1 end
			if db.kills[creature.id] then zoneCount.killed = zoneCount.killed + 1 end
		end
		local wanted = (page == "all" or here)
			and (kindChosen == 0 or creature.kind == kindChosen)
			and (folded == "" or (met and (U.Fold and U.Fold(creature.name) or creature.name:lower()):find(folded, 1, true)))
		if wanted then entries[#entries + 1] = { creature = creature, met = met, kills = db.kills[creature.id] or 0 } end
	end
	table.sort(entries, function(a, b)
		local x, y = a, b
		if descending then x, y = b, a end
		if sortBy == "kills" and x.kills ~= y.kills then return x.kills < y.kills end
		if sortBy == "name" and x.met ~= y.met then return x.met end
		if sortBy == "name" and x.creature.name ~= y.creature.name then return x.creature.name < y.creature.name end
		if x.creature.low ~= y.creature.low then return x.creature.low < y.creature.low end
		return x.creature.id < y.creature.id
	end)
end

-- Your records, as rows: { name, value, id (a creature's card) } under their headings.
local function RecordRows()
	local records = ns.Records()
	local out = {}
	local function Creature(id) local creature = ns.Creature(id) return creature and creature.name or "?" end
	local function Add(name, value, id) out[#out + 1] = { name = name, value = value, id = id } end
	out[#out + 1] = { header = L.REC_HUNT }
	Add(L.REC_DISCOVERED, L.REC_OF:format(records.discovered, ns.Total()))
	Add(L.REC_KILLED_KINDS, L.REC_OF:format(records.killed, ns.Total()))
	Add(L.REC_TOTAL, tostring(records.total))
	Add(L.REC_DIED, tostring(records.died))
	Add(L.REC_STREAK, tostring(records.streak))
	Add(L.REC_BEST, tostring(records.best))
	out[#out + 1] = { header = L.REC_FEATS }
	if records.most then Add(L.REC_MOST, L.REC_TIMES:format(Creature(records.most.id), records.most.count), records.most.id) end
	if records.nemesis then Add(L.REC_NEMESIS, L.REC_TIMES:format(Creature(records.nemesis.id), records.nemesis.count), records.nemesis.id) end
	if records.highest then Add(L.REC_HIGHEST, L.REC_LEVEL:format(Creature(records.highest.id), records.highest.level), records.highest.id) end
	if records.firstKill then Add(L.REC_FIRST, Creature(records.firstKill.id), records.firstKill.id) end
	Add(L.REC_RARES, tostring(records.rares))
	Add(L.REC_ELITES, tostring(records.elites))
	Add(L.REC_BOSSES, tostring(records.bosses))
	if records.kindMost then Add(L.REC_KIND_MOST, records.kindMost) end
	-- (each kind: how many met and killed of how many)
	local kinds = {}
	local db = ns.Journal()
	for _, creature in ipairs(ns.All()) do
		local kind = creature.kind
		if rawget(ns.LOCALES.enUS, "KIND_" .. kind) then
			kinds[kind] = kinds[kind] or { of = 0, killed = 0 }
			kinds[kind].of = kinds[kind].of + 1
			if db.kills[creature.id] then kinds[kind].killed = kinds[kind].killed + 1 end
		end
	end
	out[#out + 1] = { header = L.REC_KINDS }
	for kind = 1, 10 do
		local count = kinds[kind]
		if count then Add(L["KIND_" .. kind], L.REC_KIND_VALUE:format(count.killed, count.of, math.floor(count.killed / count.of * 100 + 0.5))) end
	end
	-- (with the counts above: never under the import's heading)
	if records.zone then
		Add(L.REC_ZONE, L.REC_ZONE_VALUE:format(U.AreaName(records.zone.area) or "?", math.floor(records.zone.done / records.zone.of * 100 + 0.5)))
	end
	-- Bringing your counts from another addon (KillTrack, while it is loaded too), or taking the last import back.
	local preview = ns.ImportPreview()
	local undo = ns.Journal().importUndo
	if preview or undo then out[#out + 1] = { header = L.IMPORT_HEADER } end
	if preview then
		out[#out + 1] = { name = L.IMPORT_FROM:format(preview.source), value = L.IMPORT_COUNT:format(#preview.changes),
			run = function() ns.AskImport() end, tip = L.IMPORT_TIP }
	end
	if type(undo) == "table" then
		out[#out + 1] = { name = L.IMPORT_UNDO:format(undo.source or "?"), value = "", run = function()
			Skin.Ask(L.IMPORT_UNDO_ASK, function() ns.ImportUndo() end)
		end }
	end
	return out
end

-- At the top: how much of the world you discovered (a golden line filling up), your kills and best series.
local function Summary()
	local records = ns.Records()
	local total = ns.Total()
	local share = total > 0 and records.discovered / total or 0
	window.summary:SetText(L.DISCOVERED:format(Skin.Colorize(BreakUpLargeNumbers and BreakUpLargeNumbers(records.discovered) or records.discovered, "gold"),
		BreakUpLargeNumbers and BreakUpLargeNumbers(total) or total, math.floor(share * 100 + 0.5)))
	window.progress:Set(share)
	window.stats:SetText(L.STATS_LINE:format(Skin.Colorize(BreakUpLargeNumbers and BreakUpLargeNumbers(records.total) or records.total, "gold"),
		Skin.Colorize(records.best, "gold")))
end

-- A creature's portrait in a row: round, in a ring the colour of its rank (gold elite, blue rare, red boss); a
-- question mark, faint, before you met it.
local RING = { [1] = { "gold", 0.85 }, [2] = { "blue", 0.9 }, [3] = { "bad", 0.9 }, [4] = { "blue", 0.9 } } -- (a role, its alpha)
local function Portrait(row, creature, met)
	if not row.icon then return end
	if not row.round then
		local size = row.icon:GetWidth() - 2
		row.round = Skin.RoundPortrait(row.icon, size)
		row.round:SetPoint("CENTER", row.icon, "CENTER")
	end
	row.icon.ground:SetAlpha(0)
	row.icon.texture:SetAlpha(0)
	row.icon.edges.Color(1, 1, 1, 0)
	row.round:Show()
	local drawn = met and ns.Portrait(row.round, creature)
	if not drawn then row.round:SetTexture(UNKNOWN_ICON) end
	row.round:SetAlpha(met and 1 or 0.45)
	local ring = met and RING[creature.rank]
	if row.round.ringShown ~= false then
		row.round.ring:Show()
		if ring then
			local c = Skin.COLORS[ring[1]]
			row.round.ring:SetVertexColor(c[1], c[2], c[3], ring[2])
		else
			row.round.ring:SetVertexColor(1, 1, 1, met and 0.3 or 0.15)
		end
	end
end

local function Draw()
	if not (window and window:IsShown()) then return end
	Summary()
	local records = page == "records"
	search:SetShown(not records)
	kindBox:SetShown(not records)
	local rowsShown = records and RecordRows() or nil
	if not records then Gather() end
	local total = records and #rowsShown or #entries
	list:Clamp(total)
	local chosen = ns.CardShown()
	for index, row in ipairs(list.rows) do
		local at = list.offset + index
		if records then
			local entry = rowsShown[at]
			if entry and entry.header then
				row:Fill({ header = entry.header })
			elseif entry then
				row:Fill({ name = entry.name, icon = nil, id = entry.id, run = entry.run, color = entry.run and Skin.COLORS.gold or Skin.COLORS.soft,
					tip = entry.tip or (entry.id and L.OPEN_CARD or nil) }, entry.id ~= nil and entry.id == chosen,
					{ level = "", kills = Skin.Colorize(entry.value, "text") })
				if row.icon then row.icon:Hide() end
				if row.round then row.round:Hide() row.round.ring:Hide() end
			else
				row:Fill(nil)
			end
		else
			local entry = entries[at]
			if entry then
				local creature = entry.creature
				local rank = ns.RANKS[creature.rank]
				local tip
				local hidden = ns.Hidden(creature, entry.met)
				if not entry.met then
					local where = {}
					for _, area in ipairs(creature.zones) do where[#where + 1] = U.AreaName(area) or "?" end
					tip = { L.NOT_MET, hidden and L.SURPRISE_KEPT or L.LIVES_IN:format(table.concat(where, ", ")) }
				end
				row:Fill({ name = entry.met and creature.name or L.UNKNOWN_NAME, id = creature.id, icon = UNKNOWN_ICON,
					color = not entry.met and Skin.COLORS.muted or nil, tip = tip },
					creature.id == chosen, { level = hidden and "?" or ns.Levels(creature), kills = entry.kills > 0 and Skin.Colorize(L.TIMES_SHORT:format(entry.kills), "gold") or "" },
					entry.met and rank and L[rank] or nil, rank and (creature.rank == 3 and "red" or creature.rank == 1 and "gold" or "blue") or nil)
				-- (its portrait once met; a question mark before)
				if row.icon then
					row.icon:Show()
					Portrait(row, creature, entry.met)
				end
			else
				row:Fill(nil)
			end
		end
	end
	-- (on "Here": this zone's creatures met and killed, a golden line)
	local zone = page == "here" and zoneCount.of > 0
	window.zone:SetShown(zone)
	window.zoneLine:SetShown(zone)
	if zone then
		window.zone:SetText(L.ZONE_LINE:format(Clean(U.Safe(GetZoneText)) or "",zoneCount.met, zoneCount.of, zoneCount.killed))
		window.zoneLine:Set(zoneCount.killed / zoneCount.of)
	end
	-- (the game look: its column titles written as they are, as the kit's own)
	local Caps = (Skin.GameWindows and Skin.GameWindows()) and tostring or U.Upper
	list.titles[1]:SetText(Caps(records and "" or L.COL_LEVEL))
	list.titles[2]:SetText(Caps(records and "" or L.COL_KILLS))
	-- (a search that finds nothing: said, and that it knows only the creatures you met)
	list.empty:SetText(not records and query ~= "" and L.SEARCH_EMPTY or L.EMPTY)
	list.empty:SetShown(total == 0)
end

local function Create()
	window = Skin.CreateWindow("WandererBestiaryWindow", "MEDIUM")
	Skin.Sounds(window, Skin.SOUNDS.open, Skin.SOUNDS.close)
	Skin.Dress(window, { "CENTER", UIParent, "CENTER", -180, 40 }, "bestiaryPos")
	local _, title, margin = Skin.Header(window, "Wanderer", L.TITLE, { settings = "ext:bestiary" })
	-- How much of the world you discovered: its words, a golden line; your kills on the right.
	window.summary = Skin.Text(window, "GameTooltipTextSmall", "soft")
	window.summary:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	window.stats = Skin.Text(window, "GameTooltipTextSmall", "soft")
	window.stats:SetPoint("BOTTOMRIGHT", window.summary, "BOTTOMRIGHT", 0, 0)
	window.stats:SetPoint("RIGHT", window, "RIGHT", -margin, 0)
	window.stats:SetJustifyH("RIGHT")
	window.progress = Skin.ProgressLine(window, 2)
	window.progress:SetPoint("TOPLEFT", window.summary, "BOTTOMLEFT", 0, -5)
	window.progress:SetPoint("RIGHT", window, "RIGHT", -margin, 0)
	-- The pages.
	local rule = Skin.Rule(window)
	-- (the game look: the game's own divider under its tabs)
	if Skin.GameWindows and Skin.GameWindows() then Skin.GameAtlas(rule, "Options_HorizontalDivider") end
	rule:SetPoint("TOPLEFT", window.progress, "BOTTOMLEFT", 0, -30)
	rule:SetPoint("RIGHT", window, "RIGHT", -margin, 0)
	tabs = Skin.Tabs(window, { { "here", L.TAB_HERE }, { "all", L.TAB_ALL }, { "records", L.TAB_RECORDS } }, function(key)
		page = key
		list.offset = 0
		Draw()
	end)
	tabs:SetPoint("BOTTOMLEFT", rule, "TOPLEFT", 0, 0)
	tabs:Select(page)
	-- A search, a kind.
	search = Skin.CreateInput(window, nil, 40, { hint = L.SEARCH_HINT, onChange = function(_, typed)
		query = typed or ""
		list.offset = 0
		Draw()
	end })
	search:SetPoint("TOPLEFT", rule, "BOTTOMLEFT", 0, -10)
	search:SetWidth(240)
	kindBox = Skin.Dropdown(window, function()
		local choices = { { id = 0, label = L.KIND_ANY } }
		for kind = 1, 10 do
			if rawget(ns.LOCALES.enUS, "KIND_" .. kind) then choices[#choices + 1] = { id = kind, label = L["KIND_" .. kind] } end
		end
		return choices
	end, function() return kindChosen end, function(id)
		kindChosen = id
		list.offset = 0
		Draw()
	end, L.KIND_ANY, 140, 200)
	kindBox:SetPoint("LEFT", search, "RIGHT", 10, 0)
	list = Skin.Table(window, {
		width = WIDTH - margin * 2, rows = ROWS, nameTitle = L.COL_CREATURE, nameSort = "name",
		columns = { { key = "level", title = L.COL_LEVEL, width = 56, sort = "level" }, { key = "kills", title = L.COL_KILLS, width = 150, sort = "kills" } },
		onSort = function(sort)
			if page == "records" then return end
			if sortBy == sort then descending = not descending else sortBy, descending = sort, sort == "kills" end
			list:SetSort(sortBy, not descending)
			Draw()
		end,
		onClick = function(entry)
			if entry.run then return entry.run() end
			if not entry.id then return end
			if ns.CardShown() == entry.id and ns.CardOwner() == window then ns.HideCard() else ns.ShowCard(entry.id, window) end
			Draw()
		end,
		onDraw = Draw,
	})
	list:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -30)
	-- This zone's completion, between the search and the list.
	window.zone = Skin.Text(window, "GameTooltipTextSmall", "soft")
	window.zone:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -8)
	window.zoneLine = Skin.ProgressLine(window, 2)
	window.zoneLine:SetPoint("TOPLEFT", window.zone, "BOTTOMLEFT", 0, -3)
	window.zoneLine:SetPoint("RIGHT", window, "RIGHT", -margin, 0)
	list:SetSort(sortBy, true)
	local help = Skin.Help(window, L.HELP_TIP, "HEADING")
	-- (a controller: its own keys, not the mouse's)
	if help then
		help:HookScript("OnEnter", function(self)
			if U.UsingPad and U.UsingPad() then Skin.ShowTip(self, L.HELP_TIP_PAD, "ANCHOR_BOTTOM") end
		end)
	end
	window:SetSize(WIDTH, margin * 2 + 30 + 26 + 50 + 10 + 24 + 10 + list:GetHeight() + 8)
	window:HookScript("OnShow", function(self)
		self:SetScale(Skin.FitScale(self))
		Draw()
	end)
	window:HookScript("OnHide", function()
		if ns.CardOwner() == window then ns.HideCard() end
	end)
	Skin.Get(window):Layout()
end

function ns.Toggle()
	if not On() then return SayOff() end
	if not window then Create() end
	if not window:IsShown() then ns.ImportGame() end
	window:SetShown(not window:IsShown())
end

function ns.Open(id)
	if not On() then return SayOff() end
	ns.ImportGame()
	if not window then Create() end
	window:Show()
	if id then ns.ShowCard(id, window) end
	Draw()
end
ns.Window = function() return window end -- (tests)

-- A first kill of an elite, a rare or a boss: a notice (a click opens its card).
function ns.NewEntry(id)
	local settings = Settings()
	local creature = ns.Creature(id)
	if not (settings and settings.notify and creature and ns.RANKS[creature.rank]) then return end
	W.Toast(L.NEW_TITLE, L.NEW_TEXT:format(creature.name, L[ns.RANKS[creature.rank]]), { kicker = L.ADDON, corner = true, duration = 6,
		icon = creature.rank == 3 and BOSS_ICON or PREY_ICON, tone = "gold", kind = "bestiaryNew", kindName = L.NEW_KIND, hint = L.OPEN_CARD,
		onClick = function() ns.Open(id) end })
end

-- The import asked first: what it brings (how many creatures raised, the biggest changes), nothing written before
-- yes; taken back from Records after.
function ns.AskImport()
	local preview = ns.ImportPreview()
	if not preview then return end
	if not preview.changes[1] then return W.Print(L.IMPORT_NOTHING:format(preview.source)) end
	local lines = { L.IMPORT_ASK:format(preview.source, #preview.changes, preview.creatures, preview.unknown) }
	for at = 1, math.min(5, #preview.changes) do
		local change = preview.changes[at]
		lines[#lines + 1] = L.IMPORT_LINE:format(ns.Creature(change.id).name, change.from, change.to)
	end
	if #preview.changes > 5 then lines[#lines + 1] = L.IMPORT_MORE:format(#preview.changes - 5) end
	Skin.Ask(table.concat(lines, "\n"), function()
		local done = ns.ImportApply(preview)
		W.Print(L.IMPORT_DONE:format(done, preview.source))
	end)
end

-- A milestone: a creature killed 25, 100, 500 or 1000 times, or your kills in all (id nil). Quiet, and asked for.
function ns.Milestone(id, count)
	local settings = Settings()
	if not (settings and settings.milestones) then return end
	local creature = id and ns.Creature(id)
	local text = creature and L.MILESTONE_ONE:format(creature.name, count) or L.MILESTONE_ALL:format(count)
	W.Toast(L.MILESTONE_TITLE, text, { kicker = L.ADDON, corner = true, duration = 5, tone = "gold", kind = "bestiaryMilestone",
		kindName = L.MILESTONE_KIND, hint = id and L.OPEN_CARD or nil, onClick = function() ns.Open(id) end })
end

-- A line under a creature's name (Wanderer's label, the game's tooltip): killed ×12, or never met. Never in a
-- dungeon or a raid (the game hides who they are there), and asked for.
function ns.NoteFor(guid)
	local settings = Settings()
	if not (settings and settings.enabled and settings.tooltip) then return nil end
	if Clean(U.Safe(IsInInstance)) then return nil end
	local id = U.NpcID(guid)
	if not (id and ns.Known(id)) then return nil end
	local db = ns.Journal()
	local kills = db.kills[id]
	if kills then return Skin.Colorize(L.NOTE_KILLED:format(kills), "kicker") end
	if not db.seen[id] then return Skin.Colorize(L.NOTE_NEW, "gold") end
	return Skin.Colorize(L.NOTE_MET, "muted")
end

local function GameTooltipNote()
	if not (TooltipDataProcessor and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit) then return end
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
		if tooltip ~= GameTooltip then return end
		local line = ns.NoteFor(type(data) == "table" and Clean(data.guid) or nil)
		if line then tooltip:AddLine(line) end
	end)
end

-- Init ---------------------------------------------------------------------------------------------------------

BINDING_HEADER_WANDERERBESTIARY = "Wanderer Bestiary"
BINDING_NAME_WANDERERBESTIARY_TOGGLE = L.TITLE
-- (the key does nothing before Init has passed Wanderer's API check)
function WandererBestiary_Toggle() if ns.ready then ns.Toggle() end end

function ns.Init()
	if not (W and W.RegisterExtension) then return end
	-- (built on Wanderer's API 21 (UnitNote, Skin.Beside's opts, the pad marks): an older Wanderer is only asked to update, nothing of it is called)
	if (W.API or 1) < 21 then return W.Print(L.NEEDS_WANDERER) end
	W.RegisterExtension({
		key = "bestiary",
		addon = ADDON,
		slash = "/wbestiary",
		title = L.ADDON,
		news = L.NEWS_LINES,
		defaults = { enabled = true, track = true, notify = true, milestones = true, surprise = true, tooltip = true },
		launcher = { label = L.TITLE, open = function() ns.Toggle() end },
		refresh = function()
			ns.ListenAsSet()
			if not On() then
				if window then window:Hide() end
				ns.HideCard()
			end
			Draw()
		end,
		options = function(o)
			local enabled = o.Checkbox("bestiary", "enabled", L.ENABLE, L.ENABLE_DESC, function() ns.ListenAsSet() end)
			local on = o.IsOn("bestiary", "enabled")
			o.Under(o.Button(L.TITLE, L.OPEN, L.OPEN_DESC, function()
				o.CloseSettings()
				ns.Open()
			end), enabled, on)
			o.Under(o.Checkbox("bestiary", "track", L.TRACK, L.TRACK_DESC, function() ns.ListenAsSet() end), enabled, on)
			o.Under(o.Checkbox("bestiary", "notify", L.NOTIFY, L.NOTIFY_DESC), enabled, on)
			o.Under(o.Checkbox("bestiary", "milestones", L.MILESTONES, L.MILESTONES_DESC), enabled, on)
			o.Under(o.Checkbox("bestiary", "tooltip", L.TOOLTIP, L.TOOLTIP_DESC), enabled, on)
			o.Under(o.Checkbox("bestiary", "surprise", L.SURPRISE, L.SURPRISE_DESC, function() Draw() end), enabled, on)
		end,
	})
	SLASH_WANDERERBESTIARY1 = "/wbestiary"
	SlashCmdList.WANDERERBESTIARY = function() ns.Toggle() end
	ns.ListenAsSet()
	ns.OnChanged(Draw)
	-- (its line under a creature's name: Wanderer's label, the game's tooltip)
	if W.UnitNote then W.UnitNote(ns.NoteFor) end
	GameTooltipNote()
	-- For the other addons (Wanderer Quests' sheet, Wanderer Maps' atlas): a creature's card beside their window.
	-- (Bestiary off: nothing known, no habitat, no name, no portrait; Show says it is off)
	WandererBestiary = {
		IsOn = function() return On() and true or false end,
		Known = function(id) return On() and ns.Known(id) or false end,
		-- (where it lives, point by point, for Wanderer Maps' atlas: { { map, points = { { x, y } } } }; the surprise kept)
		Habitat = function(id)
			if not On() then return {} end
			local creature = ns.Creature(id)
			if not creature then return {} end
			local db = ns.Journal()
			if ns.Hidden(creature, (db.seen[id] or db.kills[id]) and true or false) then return {} end
			return ns.Habitat(id)
		end,
		-- (its name once met, "???" before; its portrait on a texture: false when it cannot be drawn)
		Name = function(id)
			if not On() then return nil end
			local creature = ns.Creature(id)
			if not creature then return nil end
			local db = ns.Journal()
			return (db.seen[id] or db.kills[id]) and creature.name or L.UNKNOWN_NAME
		end,
		Portrait = function(texture, id)
			if not On() then return false end
			local db = ns.Journal()
			return (db.seen[id] or db.kills[id]) and ns.Portrait(texture, ns.Creature(id)) or false
		end,
		Show = function(id, beside)
			if not On() then
				SayOff()
				return false
			end
			return ns.ShowCard(id, beside) or false
		end,
		Hide = function(beside) if ns.CardOwner() == beside then ns.HideCard() end end,
		Shown = function(beside) return ns.CardOwner() == beside and ns.CardShown() or nil end,
		Toggle = function() ns.Toggle() end,
	}
	ns.ready = true
end

if W and W.WhenLoaded then W.WhenLoaded(ADDON, ns.Init) elseif W and W.Print then W.Print(L.NEEDS_WANDERER) end
