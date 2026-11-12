local _, ns = ...

-- Your hunting log, per character (WandererBestiaryDB): the creatures you met (seen: targeted, under the mouse, a
-- nameplate), those you killed (how many, first and last time), those that killed you, what you looted from them,
-- your series without dying, the highest level you brought down. Without the combat log (Forever keeps it closed):
-- a kill is a creature you fought (your target in a fight, or one fighting you) seen dead without being another's,
-- or a corpse you loot; the creature that killed you is the one fighting you when you fell (your guess, said so).

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U.Safe, U.Clean

local COUNTED_MOST = 400 -- corpses remembered (a kill counted once), forgotten past that
local LOOT_MOST = 12 -- items kept for each creature (the most looted)
local PAIR_DEAD, PAIR_LOOT = 4, 120 -- seconds a kill read by its name and one seen by its corpse are the same
local MILESTONES = { [25] = true, [100] = true, [500] = true, [1000] = true }
local TOTAL_MILESTONES = { [100] = true, [500] = true, [1000] = true, [2500] = true, [5000] = true, [10000] = true }
local FIGHT_AFTER = 8 -- seconds after a fight a death still counts as yours
local PLATES = 40

local listeners = {}
function ns.OnChanged(fn) listeners[#listeners + 1] = fn end
local changeSoon
local function Changed()
	if not changeSoon then
		changeSoon = U.Debounce(0.3, function() for _, fn in ipairs(listeners) do pcall(fn) end end)
	end
	changeSoon()
end

function ns.Journal()
	local db = _G.WandererBestiaryDB
	if type(db) ~= "table" then
		db = {}
		_G.WandererBestiaryDB = db
	end
	for _, key in ipairs({ "seen", "kills", "first", "last", "deaths", "loot" }) do
		if type(db[key]) ~= "table" then db[key] = {} end
	end
	db.total, db.died, db.streak, db.best = db.total or 0, db.died or 0, db.streak or 0, db.best or 0
	return db
end

local function Settings() return W and W.Settings and W.Settings("bestiary") or nil end
local function Tracking()
	local settings = Settings()
	return settings and settings.enabled and settings.track
end

-- Seen ------------------------------------------------------------------------------------------------------------

local function Look(unit)
	local id = ns.UnitCreature(unit)
	if not id then return end
	local db = ns.Journal()
	if db.seen[id] then return end
	db.seen[id] = time()
	Changed()
end

-- Kills -----------------------------------------------------------------------------------------------------------

local counted, countedSize = {}, 0
local engaged = {} -- guid -> true: a creature you fought
local lastFight = 0

local function Count(guid)
	if counted[guid] then return false end
	if countedSize >= COUNTED_MOST then counted, countedSize = {}, 0 end
	counted[guid] = true
	countedSize = countedSize + 1
	return true
end

-- A kill of yours: counted, dated, your series, your highest level.
local function Kill(id, level)
	local db = ns.Journal()
	local now = time()
	local first = not db.kills[id]
	db.kills[id] = (db.kills[id] or 0) + 1
	db.first[id] = db.first[id] or now
	db.last[id] = now
	db.seen[id] = db.seen[id] or now
	db.total = db.total + 1
	db.streak = db.streak + 1
	if db.streak > db.best then db.best = db.streak end
	level = level or (ns.Creature(id) or {}).high
	if level and (not db.highest or level > db.highest.level) then db.highest = { id = id, level = level, at = now } end
	db.firstKill = db.firstKill or { id = id, at = now }
	Changed()
	if first and ns.NewEntry then ns.NewEntry(id) end
	if not first and MILESTONES[db.kills[id]] and ns.Milestone then ns.Milestone(id, db.kills[id]) end
	if TOTAL_MILESTONES[db.total] and ns.Milestone then ns.Milestone(nil, db.total) end
end

-- The same kill seen two ways (its corpse, by its id; the game's words, by its name: "X dies, you gain 120
-- experience", a boss's encounter ended): counted once. Each way keeps the kills the other has not matched yet.
local byCorpse, byName = {}, {} -- name -> { times }
local function Take(list, name, within)
	local times = list[name]
	if not times then return false end
	local now = GetTime()
	for index = #times, 1, -1 do
		if now - times[index] <= within then
			table.remove(times, index)
			return true
		end
	end
	list[name] = nil
	return false
end
local function Leave(list, name)
	list[name] = list[name] or {}
	table.insert(list[name], GetTime())
	if #list[name] > 20 then table.remove(list[name], 1) end
end

-- A kill seen by its corpse (id): counted unless its name was already counted a moment ago.
local function KillCorpse(id, level, within)
	local creature = ns.Creature(id)
	local name = creature and creature.name
	if name and Take(byName, name, within) then return end
	if name then Leave(byCorpse, name) end
	Kill(id, level)
end

-- The creatures of a name, the one of the zone you are in first (several share a name).
local named
local function Named(name)
	if not named then
		named = {}
		for _, creature in ipairs(ns.All()) do
			named[creature.name] = named[creature.name] or {}
			table.insert(named[creature.name], creature)
		end
	end
	local list = named[name]
	if not list then return nil end
	if #list == 1 then return list[1].id end
	local here = U.PlainName(Clean(Safe(GetRealZoneText)))
	for _, creature in ipairs(list) do
		for _, area in ipairs(creature.zones) do
			if here and U.PlainName(U.AreaName(area)) == here then return creature.id end
		end
	end
	return list[1].id
end

-- A kill seen by its name (the game's words): counted unless its corpse was already counted a moment ago.
local function KillNamed(name)
	if type(name) ~= "string" or name == "" then return end
	local id = Named(name)
	if not id then return end
	if Take(byCorpse, ns.Creature(id).name, PAIR_DEAD) then return end
	Leave(byName, ns.Creature(id).name)
	Kill(id, nil)
end

-- The game's words for experience from a kill, in your language: "%s dies, you gain %d experience." and its
-- kin (rested, in a group, in a raid). Their patterns, made once.
local XP_FORMATS = { "COMBATLOG_XPGAIN_FIRSTPERSON", "COMBATLOG_XPGAIN_FIRSTPERSON_GROUP", "COMBATLOG_XPGAIN_FIRSTPERSON_RAID",
	"COMBATLOG_XPGAIN_EXHAUSTION1", "COMBATLOG_XPGAIN_EXHAUSTION1_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION1_RAID",
	"COMBATLOG_XPGAIN_EXHAUSTION2", "COMBATLOG_XPGAIN_EXHAUSTION2_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION2_RAID",
	"COMBATLOG_XPGAIN_EXHAUSTION4", "COMBATLOG_XPGAIN_EXHAUSTION4_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION4_RAID",
	"COMBATLOG_XPGAIN_EXHAUSTION5", "COMBATLOG_XPGAIN_EXHAUSTION5_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION5_RAID" }
local xpPatterns
local function XpKill(text)
	text = Clean(text)
	if type(text) ~= "string" then return end
	if not xpPatterns then
		xpPatterns = {}
		for _, name in ipairs(XP_FORMATS) do
			local pattern = U.FormatPattern(_G[name], true)
			if pattern then xpPatterns[#xpPatterns + 1] = pattern end
		end
	end
	for _, pattern in ipairs(xpPatterns) do
		local name = text:match(pattern)
		if name then return KillNamed(name) end
	end
end

-- A creature fighting you, or the one you target in a fight: fought.
local function Engage(unit)
	local guid = Clean(Safe(UnitGUID, unit))
	if not guid or engaged[guid] then return end
	local fighting = Clean(Safe(UnitAffectingCombat, "player"))
	local onYou = Clean(Safe(UnitThreatSituation, "player", unit)) ~= nil
	-- (your pet's fights are yours)
	local onPet = Clean(Safe(UnitExists, "pet")) and (Clean(Safe(UnitThreatSituation, "pet", unit)) ~= nil
		or Clean(Safe(UnitIsUnit, unit .. "target", "pet")))
	if onYou or onPet or (fighting and Clean(Safe(UnitIsUnit, unit, "target"))) then engaged[guid] = true end
end

-- A creature seen dead: yours when you fought it, it was not another's, and you fought a moment ago.
local function Dead(unit)
	local id, guid = ns.UnitCreature(unit)
	if not (id and guid) then return end
	if not Clean(Safe(UnitIsDead, unit)) then
		Engage(unit)
		return
	end
	if not engaged[guid] or counted[guid] then return end
	if Clean(Safe(UnitIsTapDenied, unit)) then return end
	local fighting = Clean(Safe(UnitAffectingCombat, "player")) or GetTime() - lastFight <= FIGHT_AFTER
	if not fighting then return end
	engaged[guid] = nil
	if Count(guid) then KillCorpse(id, Clean(Safe(UnitLevel, unit)), PAIR_DEAD) end
end
ns.Dead = Dead -- (tests)

-- Loot: what each corpse gave; a corpse looted counts as a kill when it was not counted yet.
local lootRead = {} -- what this loot window already gave (its corpse, its slot, its item)
local function Keep(db, id, item, amount)
	local list = db.loot[id] or {}
	db.loot[id] = list
	if not list[item] then
		-- (full: the item looted the least makes room)
		local size, least = 0, nil
		for other, count in pairs(list) do
			size = size + 1
			if not least or count < list[least] then least = other end
		end
		if size >= LOOT_MOST and least then list[least] = nil end
	end
	list[item] = (list[item] or 0) + amount
end

local function Looted()
	local db = ns.Journal()
	for slot = 1, Clean(Safe(GetNumLootItems)) or 0 do
		local link = Clean(Safe(GetLootSlotLink, slot))
		local item = link and U.ItemID(link)
		local sources = { Safe(GetLootSourceInfo, slot) }
		for at = 1, #sources, 2 do
			local guid, amount = Clean(sources[at]), Clean(sources[at + 1])
			local id = U.NpcID(guid)
			local key = tostring(guid) .. ":" .. slot .. ":" .. tostring(item)
			if id and ns.Known(id) and not lootRead[key] then
				lootRead[key] = true
				if Count(guid) then KillCorpse(id, nil, PAIR_LOOT) end
				if item then Keep(db, id, item, tonumber(amount) or 1) end
			end
		end
	end
	Changed()
end

-- Deaths ----------------------------------------------------------------------------------------------------------

-- The creature that killed you, as well as Wanderer can tell: one fighting you (targeting you first), else your
-- target when it was fighting.
local function Killer()
	local best, bestScore, player = nil, nil, 0
	local function Weigh(unit)
		if not Clean(Safe(UnitExists, unit)) or Clean(Safe(UnitIsDead, unit)) then return end
		if not Clean(Safe(UnitCanAttack, "player", unit)) then return end
		local onYou = Clean(Safe(UnitIsUnit, unit .. "target", "player"))
		if Clean(Safe(UnitIsPlayer, unit)) then
			if onYou then player = math.max(player, 2) end
			return
		end
		local id = ns.UnitCreature(unit)
		if not id then return end
		local score = 0
		if onYou then score = score + 2 end
		if Clean(Safe(UnitThreatSituation, "player", unit)) ~= nil then score = score + 1 end
		if unit == "target" then score = score + 0.5 end
		if score > 0 and (not bestScore or score > bestScore) then best, bestScore = id, score end
	end
	Weigh("target")
	for index = 1, PLATES do Weigh("nameplate" .. index) end
	if player > 0 and player >= (bestScore or 0) then return nil end
	return best
end

local function Died()
	local db = ns.Journal()
	db.died = db.died + 1
	db.streak = 0
	local id = Killer()
	if id then
		db.deaths[id] = (db.deaths[id] or 0) + 1
		db.seen[id] = db.seen[id] or time()
	end
	db.lastDeath = { id = id, at = time() }
	Changed()
end

-- The game's own counts ---------------------------------------------------------------------------------------

-- What the game already counted (Forever keeps the statistics of the classic achievements): your kills and deaths
-- in all, the creature kind you killed the most, each dungeon and raid boss's kills, the deaths from a few
-- creatures. Taken into your log (never lowering it): those bosses met and killed as many times as the game says.
local STAT_CREATURES, STAT_DEATHS_ALL, STAT_KIND_MOST = 107, 60, 1336
local function Stat(id)
	if not GetStatistic then return nil end
	local value = Clean(Safe(GetStatistic, id))
	if value == nil then return nil end
	local digits = tostring(value):gsub("[^%d]", "")
	return tonumber(digits)
end

function ns.ImportGame()
	if not GetStatistic then return false end
	local db = ns.Journal()
	db.game = db.game or {}
	db.game.kills = Stat(STAT_CREATURES) or db.game.kills
	db.game.deaths = Stat(STAT_DEATHS_ALL) or db.game.deaths
	local kind = Clean(Safe(GetStatistic, STAT_KIND_MOST))
	if type(kind) == "string" and kind ~= "" and kind ~= "--" and kind ~= "0" then db.game.kindMost = kind end
	local now = time()
	local function Raise(list, into)
		for stat, id in pairs(list or {}) do
			local count = Stat(stat)
			if count and count > 0 and ns.Known(id) then
				if (into[id] or 0) < count then into[id] = count end
				db.seen[id] = db.seen[id] or now
			end
		end
	end
	Raise(ns.STAT_KILLS, db.kills)
	Raise(ns.STAT_DEATHS, db.deaths)
	Changed()
	return true
end

-- Another addon's counts ----------------------------------------------------------------------------------------

-- KillTrack (its counts for this character: KILLTRACK_CHAR.MOBS[npc id] = { Name, Kills }), read while it is
-- loaded too (the game gives an addon's saved data only to a loaded addon). Nothing written before you said yes,
-- and the last import can be taken back.
local function KillTrackMobs()
	local data = _G.KILLTRACK_CHAR
	local mobs = type(data) == "table" and type(data.MOBS) == "table" and data.MOBS or nil
	return mobs
end

-- What an import would change: { source, creatures (theirs), kills (theirs), changes = { { id, from, to } }, unknown }
-- (the counts only ever raised), or nil when no such addon is there.
function ns.ImportPreview()
	local mobs = KillTrackMobs()
	if not mobs then return nil end
	local db = ns.Journal()
	local out = { source = "KillTrack", creatures = 0, kills = 0, changes = {}, unknown = 0 }
	for key, mob in pairs(mobs) do
		local id = tonumber(key)
		local kills = type(mob) == "table" and tonumber(mob.Kills) or nil
		if id and kills and kills > 0 then
			out.creatures = out.creatures + 1
			out.kills = out.kills + kills
			if not ns.Known(id) then
				out.unknown = out.unknown + 1
			elseif (db.kills[id] or 0) < kills then
				out.changes[#out.changes + 1] = { id = id, from = db.kills[id] or 0, to = kills }
			end
		end
	end
	table.sort(out.changes, function(a, b) return a.to - a.from > b.to - b.from end)
	return out
end

-- Written: each count raised, what it was kept to take it back.
function ns.ImportApply(preview)
	if not (preview and preview.changes[1]) then return 0 end
	local db = ns.Journal()
	local undo = { at = time(), source = preview.source, kills = {}, seen = {} }
	local now = time()
	for _, change in ipairs(preview.changes) do
		undo.kills[change.id] = db.kills[change.id] or false
		undo.seen[change.id] = db.seen[change.id] or false
		db.kills[change.id] = change.to
		db.seen[change.id] = db.seen[change.id] or now
	end
	db.importUndo = undo
	Changed()
	return #preview.changes
end

-- The last import taken back, as it was before.
function ns.ImportUndo()
	local db = ns.Journal()
	local undo = db.importUndo
	if type(undo) ~= "table" then return false end
	for id, was in pairs(undo.kills or {}) do db.kills[id] = was or nil end
	for id, was in pairs(undo.seen or {}) do db.seen[id] = was or nil end
	db.importUndo = nil
	Changed()
	return true
end

-- Records ---------------------------------------------------------------------------------------------------------

-- What your log says, counted: { discovered, killed (kinds), total, died, best, streak, highest, most (id, n),
-- nemesis (id, n), rares, elites, bosses, zone (area, done, of) }.
function ns.Records()
	local db = ns.Journal()
	local game = db.game or {}
	local out = { discovered = 0, killed = 0, total = math.max(db.total, game.kills or 0), died = math.max(db.died, game.deaths or 0),
		best = db.best, streak = db.streak, kindMost = game.kindMost,
		highest = db.highest, firstKill = db.firstKill, rares = 0, elites = 0, bosses = 0 }
	for id in pairs(db.seen) do if ns.Known(id) then out.discovered = out.discovered + 1 end end
	for id, count in pairs(db.kills) do
		local creature = ns.Creature(id)
		if creature then
			out.killed = out.killed + 1
			if not out.most or count > out.most.count then out.most = { id = id, count = count } end
			if creature.rank == 2 or creature.rank == 4 then out.rares = out.rares + 1 end
			if creature.rank == 1 then out.elites = out.elites + 1 end
			if creature.rank == 3 then out.bosses = out.bosses + 1 end
		end
	end
	for id, count in pairs(db.deaths) do
		if ns.Known(id) and (not out.nemesis or count > out.nemesis.count) then out.nemesis = { id = id, count = count } end
	end
	-- (the zone the most complete: its creatures you killed, five at least to count)
	local inZone, doneIn = {}, {}
	for _, creature in ipairs(ns.All()) do
		local zone = creature.zones[1]
		if zone then
			inZone[zone] = (inZone[zone] or 0) + 1
			if db.kills[creature.id] then doneIn[zone] = (doneIn[zone] or 0) + 1 end
		end
	end
	for zone, done in pairs(doneIn) do
		local of = inZone[zone]
		if of >= 5 and (not out.zone or done / of > out.zone.done / out.zone.of) then out.zone = { area = zone, done = done, of = of } end
	end
	return out
end

-- Listening -------------------------------------------------------------------------------------------------------

local listener
local imported = false
function ns.Listen(on)
	if not listener then
		listener = CreateFrame("Frame")
		listener:SetScript("OnEvent", function(_, event, unit, ...)
			if event == "PLAYER_TARGET_CHANGED" then
				Look("target")
				Dead("target")
			elseif event == "UPDATE_MOUSEOVER_UNIT" then
				Look("mouseover")
			elseif event == "NAME_PLATE_UNIT_ADDED" then
				Look(unit)
			elseif event == "UNIT_HEALTH" or event == "UNIT_FLAGS" or event == "UNIT_THREAT_LIST_UPDATE" then
				if unit == "target" or unit == "focus" or (type(unit) == "string" and unit:find("^nameplate")) then Dead(unit) end
			elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
				Looted()
			elseif event == "LOOT_CLOSED" then
				wipe(lootRead)
			elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
				XpKill(unit)
			elseif event == "ENCOUNTER_END" then
				-- (encounterID, its name, difficulty, size, success: the id came as the first value)
				local name, _, _, success = ...
				if Clean(success) == 1 then KillNamed(Clean(name)) end
			elseif event == "PLAYER_ENTERING_WORLD" then
				-- (once a session, a moment after: what the game counted)
				if not imported then
					imported = true
					C_Timer.After(3, ns.ImportGame)
				end
			elseif event == "PLAYER_DEAD" then
				Died()
			elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
				lastFight = GetTime()
			end
		end)
	end
	for _, event in ipairs({ "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED", "UNIT_HEALTH", "UNIT_FLAGS",
		"UNIT_THREAT_LIST_UPDATE", "LOOT_READY", "LOOT_OPENED", "LOOT_CLOSED", "CHAT_MSG_COMBAT_XP_GAIN", "ENCOUNTER_END",
		"PLAYER_DEAD", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
		if on then pcall(listener.RegisterEvent, listener, event) else pcall(listener.UnregisterEvent, listener, event) end
	end
end

-- On when the bestiary and its log are (its settings changed: again).
function ns.ListenAsSet() ns.Listen(Tracking() and true or false) end
