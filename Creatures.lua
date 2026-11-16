local _, ns = ...

-- The creatures of the old world you may fight (Data.lua, built by build_bestiary.js from CMaNGOS and pfQuest):
-- read as text at login (nearly nothing), made into a table the first time the bestiary needs it. Their names:
-- English, yours over it (Names_*.lua, the toc loads only those two).

local W = Wanderer
local U = W and W.Util

local language = GetLocale and GetLocale() or "enUS"
local EMPTY = {}

local function Read(source)
	local compile = loadstring or load
	local made = type(source) == "string" and compile and compile(source)
	if not made then return nil end
	local ok, value = pcall(made)
	return ok and type(value) == "table" and value or nil
end

local rows, names, list
local function Load()
	if rows then return end
	rows = Read(ns.CREATURE_SOURCE) or {}
	ns.CREATURE_SOURCE = nil
	local sources = ns.NAME_SOURCES or {}
	names = Read(sources.enUS) or {}
	local yours = language ~= "enUS" and Read(sources[language]) or nil
	for id, name in pairs(yours or EMPTY) do names[id] = name end
	ns.NAME_SOURCES = nil
end

-- What the rank of a creature is called (its chip), and the ranks worth a chip.
ns.RANKS = { [1] = "RANK_ELITE", [2] = "RANK_RARE_ELITE", [3] = "RANK_BOSS", [4] = "RANK_RARE" }

-- A creature: { id, name, low, high (levels), rank, kind, family, health, mana, hitLow, hitHigh, swing (seconds),
-- armor, models, zones, place, side, spells, goldLow, goldHigh, skinned, pickpocket, loot }; nil when unknown.
local made = {}
function ns.Creature(id)
	id = tonumber(id)
	if not id then return nil end
	if made[id] ~= nil then return made[id] or nil end
	Load()
	local row = rows[id]
	if not row then
		made[id] = false
		return nil
	end
	local marks = row[19] or 0
	local creature = {
		id = id, name = names[id] or ("#" .. id), low = row[1], high = row[2], rank = row[3], kind = row[4], family = row[5],
		health = row[6], mana = row[7], hitLow = row[8], hitHigh = row[9], swing = (row[10] or 0) / 1000, armor = row[11],
		models = row[12] or EMPTY, zones = row[13] or EMPTY, place = row[14] or EMPTY, side = row[15] or "", spells = row[16] or EMPTY,
		goldLow = row[17] or 0, goldHigh = row[18] or 0,
		skinned = marks % 2 == 1, pickpocket = math.floor(marks / 2) % 2 == 1, loot = math.floor(marks / 4) % 2 == 1,
	}
	made[id] = creature
	return creature
end

function ns.Known(id) return ns.Creature(id) ~= nil end

-- Every creature you may fight (those friendly to your side left out), made once.
function ns.All()
	if list then return list end
	Load()
	list = {}
	local faction = U.Clean(U.Safe(UnitFactionGroup, "player"))
	local mine = faction == "Alliance" and "A" or faction == "Horde" and "H" or nil
	for id in pairs(rows) do
		local creature = ns.Creature(id)
		if creature and not (mine and creature.side == mine) then list[#list + 1] = creature end
	end
	table.sort(list, function(a, b)
		if a.low ~= b.low then return a.low < b.low end
		return a.name < b.name
	end)
	return list
end

-- An area's name made comparable (lower case, without the game's parentheses), asked of the game once per area: the
-- list reads thousands of them at each drawing.
local plainAreas = {}
function ns.PlainArea(area)
	if not area then return nil end
	local plain = plainAreas[area]
	if plain == nil then
		plain = U.PlainName(U.AreaName(area)) or false
		plainAreas[area] = plain
	end
	return plain or nil
end

-- The levels, as one number or a span.
function ns.Levels(creature)
	if not creature then return "" end
	if creature.low == creature.high then return tostring(creature.low) end
	return creature.low .. "-" .. creature.high
end

-- What kind of creature it is, in your language: the game's word for its family (a wolf, a spider) when it has
-- one, else ours for its kind (a beast, an undead).
function ns.KindName(creature)
	if not creature then return nil end
	local info = C_CreatureInfo
	if creature.family and creature.family > 0 and info and info.GetCreatureFamilyInfo then
		local family = U.Safe(info.GetCreatureFamilyInfo, creature.family)
		local name = type(family) == "table" and U.Clean(family.name)
		if name and name ~= "" then return name end
	end
	local key = "KIND_" .. (creature.kind or 0)
	local word = rawget(ns.LOCALES.enUS, key) and ns.L[key]
	return word or nil
end

-- A creature's portrait (its first model) on a texture; false when the game cannot draw it.
function ns.Portrait(texture, creature)
	local model = creature and creature.models[1]
	if not (model and SetPortraitTextureFromCreatureDisplayID) then return false end
	return pcall(SetPortraitTextureFromCreatureDisplayID, texture, model) and true or false
end

-- The game's map of the place a creature stands at, and where on it (0 to 1): nil when none is found. On the maps
-- Forever redrew, its place in the world turned into the new map.
function ns.PlaceOnMap(creature, zone)
	local place = creature and creature.place
	if not (place and place[3]) then return nil end
	if zone and zone ~= place[3] then return U.MapOfArea and U.MapOfArea(zone), nil, nil end
	local map = U.MapOfArea and U.MapOfArea(place[3])
	if not map then return nil end
	if place[4] and U.WorldToMap then
		local _, x, y = U.WorldToMap(place[6], place[4], place[5], map)
		if x then return map, x, y end
	end
	return map, place[1] / 100, place[2] / 100
end

-- Where it lives, point by point, on the game's maps: { { map, points = { { x, y }, ... } (0 to 1) }, ... } (its
-- zones the most first); empty when nothing is known (a dungeon's creature). Read once, the first time it is asked.
local habitats
function ns.Habitat(id)
	if not habitats then
		habitats = Read(ns.HABITAT_SOURCE) or {}
		ns.HABITAT_SOURCE = nil
	end
	local out = {}
	for _, part in ipairs(habitats[id] or EMPTY) do
		local zone = part[1]
		if zone and zone < 0 then
			-- (a map Forever redrew: the points in the world, turned into its map by the game)
			local map = U.MapOfArea and U.MapOfArea(-zone)
			if map and U.WorldToMap then
				local points = {}
				for at = 3, #part - 1, 2 do
					local _, x, y = U.WorldToMap(part[2], part[at], part[at + 1], map)
					if x then points[#points + 1] = { x, y } end
				end
				if points[1] then out[#out + 1] = { map = map, area = -zone, points = points } end
			end
		elseif zone then
			local map = U.MapOfArea and U.MapOfArea(zone)
			if map then
				local points = {}
				for at = 2, #part - 1, 2 do points[#points + 1] = { part[at] / 100, part[at + 1] / 100 } end
				out[#out + 1] = { map = map, area = zone, points = points }
			end
		end
	end
	return out
end

-- The spells it casts the game knows: { id, name, icon }.
function ns.Spells(creature)
	local out = {}
	for _, id in ipairs(creature and creature.spells or EMPTY) do
		local name, icon
		if C_Spell and C_Spell.GetSpellInfo then
			local info = U.Safe(C_Spell.GetSpellInfo, id)
			if type(info) == "table" then name, icon = U.Clean(info.name), U.Clean(info.iconID) end
		elseif GetSpellInfo then
			name, _, icon = U.Safe(GetSpellInfo, id)
			name, icon = U.Clean(name), U.Clean(icon)
		end
		if name and name ~= "" then out[#out + 1] = { id = id, name = name, icon = icon } end
	end
	return out
end

-- The creature a unit is (target, nameplate...): its id when the bestiary knows it.
function ns.UnitCreature(unit)
	if not unit then return nil end
	local guid = U.Safe(UnitGUID, unit)
	local id = U.NpcID(guid)
	return id and ns.Known(id) and id or nil, U.Clean(guid)
end

function ns.Total() return #ns.All() end
