-- Bundled by luabundle {"version":"1.7.0"}
local __bundle_require, __bundle_loaded, __bundle_register, __bundle_modules = (function(superRequire)
	local loadingPlaceholder = {[{}] = true}

	local register
	local modules = {}

	local require
	local loaded = {}

	register = function(name, body)
		if not modules[name] then
			modules[name] = body
		end
	end

	require = function(name)
		local loadedModule = loaded[name]

		if loadedModule then
			if loadedModule == loadingPlaceholder then
				return nil
			end
		else
			if not modules[name] then
				if not superRequire then
					local identifier = type(name) == 'string' and '\"' .. name .. '\"' or tostring(name)
					error('Tried to require ' .. identifier .. ', but no such module has been registered')
				else
					return superRequire(name)
				end
			end

			loaded[name] = loadingPlaceholder
			loadedModule = modules[name](require, loaded, register, modules)
			loaded[name] = loadedModule
		end

		return loadedModule
	end

	return require, loaded, register, modules
end)(require)
__bundle_register("__root", function(require, _LOADED, __bundle_register, __bundle_modules)
-- requires MIST to be loaded first
-- DO SCRIPT FILE: mist.lua
--[[ This is handy for development, so that you don't need to delete and re-add the individual scripts in the ME when you make a change.  These will not be packaged with the .miz, so you shouldn't use this script loader for packaging .miz files for other machines/users.  You'll want to add each script individually with a DO SCRIPT FILE ]]--
-- DO SCRIPT: assert(loadfile("C:\\Users\\username\\...\\bundled.lua"))()

require("table") --Load modified standard libraries

local ControlZones = require("control-zones") --Load the ControlZones class from control-zoness.lua
local CoalitionCommander = require("coalition-commander") --Load the CoalitionCommander class from coalition-commander.lua

local UnitLostHandler = require("handlers").UnitLostHandler --Load event handlers

local constants = require("constants") --Load constants

cz = ControlZones.new(nil, constants.groundTemplates)

cz:setup()
cz:constructDelaunayIndex()
cz:precalculateConnections()

cz:assignCompassMaxima()
local width = cz.maxima.eastmost.y - cz.maxima.westmost.y
local height = cz.maxima.northmost.x - cz.maxima.southmost.x
local centerpoint = { y = 200, x = cz.maxima.southmost.x+height/2, z = cz.maxima.westmost.y+width/2 }

local unitLostHandler = UnitLostHandler.new(cz)
world.addEventHandler(unitLostHandler)

cz:addCommander("blue", CoalitionCommander.new(cz, {color = "blue"}, constants.groundTemplates.blue))
cz:addCommander("red", CoalitionCommander.new(cz, {color = "red"}, constants.groundTemplates.red))
cz:kickoff()
end)
__bundle_register("constants", function(require, _LOADED, __bundle_register, __bundle_modules)
local acceptableLevelsOfRisk = {
    LOW = "Low", -- Accept favorable engagements only; withdraw to preserve forces
    MEDIUM = "Medium", -- Accept neutral/favorable engagements; withdraw to avoid heavy losses
    HIGH = "High", -- Accept major losses to achieve objectives
}

local dispositionTypes = {
    ADVANCE = "Advance",
    ASSAULT = "Assault",
    DEFEND = "Defend",
    EVADE = "Evade",
    HOLD = "Hold Position",
    RETREAT = "Retreat",
}

local formationTypes = {
    OFF_ROAD = "Off Road", -- moving off-road in Column formation 
    ON_ROAD = "On Road", -- moving on road in Column formation 
    RANK = "Rank", -- moving off road in Row formation 
    CONE = "Cone", -- moving in Wedge formation 
    VEE = "Vee", -- moving in Vee formation 
    DIAMOND = "Diamond", -- moving in Diamond formation 
    ECHELONL = "EchelonL", -- moving in Echelon Left formation 
    ECHELONR = "EchelonR", -- moving in Echelon Right formation  
}

local groundTemplates = { --frontline, rear, farp
    red = {
        {"KAMAZ Truck", "KAMAZ Truck", "KAMAZ Truck", "KAMAZ Truck"},
        {"MTLB", "Ural-375", "Ural-375", "GAZ-66"},
        {"BTR-80", "KAMAZ Truck", "KAMAZ Truck", "GAZ-66"},
        {"BMP-2", "BTR-80", "MTLB", "GAZ-66"},
    },
    blue = {
        {"Hummer", "M 818", "M 818", "M 818"},
        {"M-113", "Hummer", "M 818", "M 818"},
        {"M-113", "M-113", "Hummer", "Hummer"},
        {"M-2 Bradley", "M1043 HMMWV Armament", "M1043 HMMWV Armament", "Hummer"},
    }
}

local taskTypes = {
    DEFEND = 1,
    REINFORCE = 2,
    RECON = 3,
    ASSAULT = 4,
    RESERVE = 5,
    INDIRECT = 6,
    AA = 7,
}

local statusTypes = {
    HOLD = 1,
    EN_ROUTE = 2,
}

local oodaStates = {
    OBSERVE = "Observe",
    ORIENT = "Orient",
    DECIDE = "Decide",
    ACT = "Act",
}

local rgb = {
    blue = {0,0.1,0.8,0.5},
    red = {0.5,0,0.1,0.5},
    neutral = {0.1,0.1,0.1,0.5},
}

local rulesOfEngagement = {
    WEAPON_FREE = 0, -- Engage targets at will
    RETURN_FIRE = 3, -- Engage only if fired upon
    WEAPON_HOLD = 4, -- Hold fire, do not engage
}

-- Unit classification and threat ratings
-- Each unit type has threat values against infantry, armor, and air
local unitClassification = {
    -- Infantry units
    ["Soldier M4"] = {category = "infantry", threats = {infantry = 2, armor = 0.5, air = 0}, strength = 1},
    ["Soldier M249"] = {category = "infantry", threats = {infantry = 3, armor = 0.5, air = 0}, strength = 1.2},
    ["Infantry AK"] = {category = "infantry", threats = {infantry = 2, armor = 0.5, air = 0}, strength = 1},
    ["Paratrooper RPG-16"] = {category = "infantry", threats = {infantry = 1.5, armor = 4, air = 0}, strength = 1.5},
    
    -- Light vehicles / Trucks
    ["Hummer"] = {category = "infantry", threats = {infantry = 1, armor = 0.5, air = 0}, strength = 1.5},
    ["GAZ-66"] = {category = "infantry", threats = {infantry = 1, armor = 0.5, air = 0}, strength = 1.5},
    ["UAZ-469"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 0.8},
    ["M 818"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["KAMAZ Truck"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["Kamaz 43101"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["Ural-375"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["Ural-4320-31"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["Ural-4320T"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    
    -- Scout vehicles
    ["M1043 HMMWV Armament"] = {category = "infantry", threats = {infantry = 3, armor = 2, air = 0}, strength = 2},
    ["BRDM-2"] = {category = "infantry", threats = {infantry = 3, armor = 1.5, air = 0}, strength = 2},
    
    -- Light armor / IFVs
    ["M-113"] = {category = "armor", threats = {infantry = 3, armor = 1, air = 0}, strength = 2.5},
    ["M-2 Bradley"] = {category = "armor", threats = {infantry = 5, armor = 3, air = 0}, strength = 4},
    ["BMP-2"] = {category = "armor", threats = {infantry = 5, armor = 3, air = 0}, strength = 4},
    ["BTR-80"] = {category = "armor", threats = {infantry = 4, armor = 2, air = 0}, strength = 3},
    
    -- Medium armor
    ["M-1 Abrams"] = {category = "armor", threats = {infantry = 3, armor = 8, air = 0}, strength = 8},
    ["T-72B"] = {category = "armor", threats = {infantry = 3, armor = 7, air = 0}, strength = 7},
    ["T-80U"] = {category = "armor", threats = {infantry = 3, armor = 7.5, air = 0}, strength = 7.5},
    
    -- Air defense
    ["Avenger"] = {category = "armor", threats = {infantry = 1, armor = 0, air = 6}, strength = 3},
    ["Vulcan"] = {category = "armor", threats = {infantry = 2, armor = 1, air = 5}, strength = 3},
    ["Strela-10M3"] = {category = "armor", threats = {infantry = 0, armor = 0, air = 5}, strength = 3},
    ["Strela-1 9P31"] = {category = "armor", threats = {infantry = 0, armor = 0, air = 5}, strength = 3},
    
    -- Artillery
    ["M-109"] = {category = "armor", threats = {infantry = 6, armor = 4, air = 0}, strength = 5},
    ["2S9 Nona"] = {category = "armor", threats = {infantry = 5, armor = 3, air = 0}, strength = 4},
}

-- Vulnerability modifiers based on unit category
local vulnerabilityMatrix = {
    infantry = {
        infantry = 1.0,  -- Infantry vs infantry weapons
        armor = 0.3,     -- Infantry vs armor weapons (takes cover, dispersed)
        air = 0.2,        -- Infantry vs air weapons (small target)
        antiair = 0.4     -- Infantry vs anti-air weapons
    },
    armor = {
        infantry = 0.5,  -- Armor vs infantry weapons (some resistance)
        armor = 1.2,     -- Armor vs armor weapons (vulnerable to AT)
        air = 0.8,        -- Armor vs air weapons
        antiair = 0.6     -- Armor vs anti-air weapons
    },
    air = {
        infantry = 0.4,  -- Air vs infantry weapons (less effective)
        armor = 0.7,     -- Air vs armor weapons
        air = 1.0,        -- Air vs air weapons
        antiair = 1.5     -- Air vs anti-air weapons (highly vulnerable)
    },
    antiair = {
        infantry = 0.6,  -- AA vs infantry weapons
        armor = 0.9,     -- AA vs armor weapons
        air = 1.3,        -- AA vs air weapons (highly effective)
        antiair = 1.0     -- AA vs anti-air weapons
    }
}

return {
    acceptableLevelsOfRisk = acceptableLevelsOfRisk,
    dispositionTypes = dispositionTypes,
    formationTypes = formationTypes,
    groundTemplates = groundTemplates,
    rulesOfEngagement = rulesOfEngagement,
    oodaStates = oodaStates,
    rgb = rgb,
    taskTypes = taskTypes,
    statusTypes = statusTypes,
    unitClassification = unitClassification,
    vulnerabilityMatrix = vulnerabilityMatrix
}

end)
__bundle_register("handlers", function(require, _LOADED, __bundle_register, __bundle_modules)
local UnitLostHandler = {}
UnitLostHandler.__index = UnitLostHandler

function UnitLostHandler.new(cz)
    local self = setmetatable({}, UnitLostHandler)
    self.cz = cz
    return self
end

function UnitLostHandler:onEvent(e)
    -- ground unit sequence seems to always be: world.event.S_EVENT_KILL then S_EVENT_DEAD (but no S_EVENT_LOST)
    -- however it needs a workaround for the dead unit not having a group,
    -- likely due to https://forum.dcs.world/topic/295922-scripting-api-eventdead-not-called-if-an-object-isnt-immediately-dead/
    if not e then return end
    if world.event.S_EVENT_KILL == e.id then
        local unitName = e.target:getName()
        --event initiator
        if unitName and not e.target:getPlayerName() then
            --register reduced strength or loss with coalition command
            self.cz:processDeadUnit(unitName)
        end
    end
end

return {
    UnitLostHandler = UnitLostHandler
}

end)
__bundle_register("coalition-commander", function(require, _LOADED, __bundle_register, __bundle_modules)
local taskTypes = require("constants").taskTypes
local statusTypes = require("constants").statusTypes

local CoalitionCommander = {}
CoalitionCommander.__index = CoalitionCommander

function CoalitionCommander.new(parent, config, groundTemplates)
    local self = setmetatable({}, CoalitionCommander)
    self.map = parent
    self.coalition = config.color
    self.color = config.color
    self.opponent = config.color == "blue" and "red" or "blue"
    self.templates = groundTemplates
    self.groupId = 1
    self.groups = {} -- e.g. name location task
    self.groupsByZone = {}
    for _, name in pairs(self.map.allZones) do
        self.groupsByZone[name] = {}
    end
    self.groupsByTask = {}
    for i, j in pairs(taskTypes) do
        self.groupsByTask[j] = {}
    end
    self.operations = {
        active = {},
        history = {},
        group = nil,
        status = nil,
    }
    -- attitude/aggressiveness = offensive, defensive, cautious, etc
    return self
end

function CoalitionCommander:getNewGroupId()
    self.groupId = self.groupId + 1
    return self.groupId
end

function CoalitionCommander:addGroup(groupName, templateID, task, target, zoneName)
    self.groups[groupName] = {
        name = groupName,
        template = templateID,
        strength = #self.templates[templateID],
        task = task or taskTypes.DEFEND,
        location = zoneName,
        status = statusTypes.HOLD, -- preparing, en route, complete/at destination
        target = target or nil,
        origin = zoneName, --or point, or other value
    }
    table.insert(self.groupsByTask[task], groupName)
    if zoneName then
        table.insert(self.groupsByZone[zoneName], groupName)
    end
end
function CoalitionCommander:updateGroup(groupName, params)
    local grp = self.groups[groupName]
    for k, v in pairs(params) do
        if k == "task" then
            local oldTask = grp.task
            local newTask = v
            for i, g in pairs(self.groupsByTask[oldTask]) do
                if g == groupName then table.remove(self.groupsByTask[oldTask], i) end
            end
            table.insert(self.groupsByTask[newTask], groupName)
            --if groups was not already EN_ROUTE...
            if newTask == taskTypes.ASSAULT or newTask == taskTypes.REINFORCE or newTask == taskTypes.RECON then
                grp.status = statusTypes.EN_ROUTE
                for i, g in pairs(self.groupsByZone[grp.location]) do
                    if g == groupName then table.remove(self.groupsByZone[grp.location], i) end
                end
            end
        end
        self.groups[groupName][k] = v
    end
end
function CoalitionCommander:removeGroup(groupName)
    local task = self.groups[groupName].task
    local zone = self.groups[groupName].location
    local status = self.groups[groupName].status
    for i, g in pairs(self.groupsByTask[task]) do
        if g == groupName then table.remove(self.groupsByTask[task], i) end
    end
    if zone and status == statusTypes.HOLD then
        for i, g in pairs(self.groupsByZone[zone]) do
            if g == groupName then table.remove(self.groupsByZone[zone], i) end
        end
    end
    self.groups[groupName] = nil
end

function CoalitionCommander:registerUnitLost(unitName, groupName)
    env.info(self.coalition.." command: receiving report on "..unitName.." of "..groupName)
    local grp = self.groups[groupName]
    env.info("    "..self.coalition.." command lost "..unitName.." in assault on "..grp.target)
    grp.strength = grp.strength - 1
    env.info("    group strength is now "..grp.strength)
end
function CoalitionCommander:registerGroupLost(groupName)
    env.info(self.coalition.." command: receiving report on "..groupName)
    local grp = self.groups[groupName]
    if grp then
        env.info("    lost "..grp.name.." - assault on "..grp.target.." failed")
        for i, op in pairs(self.operations.active) do
            if op.group == groupName then
                table.insert(self.operations.history, op)
                self.operations.active[i] = nil
                env.info("+++ updated operations list")
                env.info(mist.utils.tableShow(self.operations.active))
                env.info("--- past operations list")
                env.info(mist.utils.tableShow(self.operations.history))
            end
        end
        self:removeGroup(groupName)
    else
        env.info("    ("..groupName.." was already reported lost)")
    end
end

function CoalitionCommander:chooseZoneReinforcements(zones)
    local reinforcements = {}
    for _, zoneName in pairs(zones) do
        local r = math.random(#self.templates)
        local group = self.templates[r]
        local groupName = zoneName.."-"..self:getNewGroupId()
        reinforcements[zoneName] = {
            groupName = groupName,
            template = group
        }
        self:addGroup(groupName, r, taskTypes.DEFEND, zoneName, zoneName)
    end
    return reinforcements
end

function CoalitionCommander:designateAssault()
    local frontlineReserves = {}
    local frontZones = self.map:getPerimeterZones(self.color)

    for _, zoneName in pairs(frontZones) do
        local groupsInZone = self.groupsByZone[zoneName]
        if #groupsInZone > 1 then
            local defensive = 0
            local zoneReserves = {}
            for _, groupName in pairs(groupsInZone) do
                if self.groups[groupName] and self.groups[groupName].task == taskTypes.DEFEND then
                    defensive = defensive + 1
                    table.insert(zoneReserves, groupName)
                end
            end
            if #zoneReserves > 1 then
                table.insert(frontlineReserves, {zone = zoneName, groups = zoneReserves})
            end
        end
    end

    if #frontlineReserves < 1 then
        env.info("    no frontline zones have groups available for offensive tasking")
        return nil
    end
    local randomReserves = frontlineReserves[math.random(#frontlineReserves)]

    local enemyNeighbors = self.map:getNeighbors(randomReserves.zone, self.opponent, true)
    local target = enemyNeighbors[math.random(#enemyNeighbors)]

    --for now, choose single group
    if #randomReserves.groups > 1 then --can task multiple groups if available
        env.info("    "..#randomReserves.groups.." groups available at "..randomReserves.zone)
    end
    local taskedGroup = randomReserves.groups[1]

    self:updateGroup(taskedGroup, {task = taskTypes.ASSAULT, target = target})
    table.insert(self.operations.active, {type = "assault", origin = randomReserves.zone, destination = target, group = taskedGroup})
    env.info("    tasking "..taskedGroup.." to assault "..target)

    return {
        group = taskedGroup,
        origin = self.map:getZone(randomReserves.zone),
        destination = self.map:getZone(target),
    }

end

function CoalitionCommander:issueOrders()
    env.info(self.color.." generating orders")
    if #self.operations.active > 4 then --limit number of active operations
        env.info("    pass (at capacity)")
        return nil
    end
    if math.random() < 0.5 then
        env.info("    pass (random)")
        return nil
    end

    local params = self:designateAssault()

    return params
end

return CoalitionCommander

end)
__bundle_register("control-zones", function(require, _LOADED, __bundle_register, __bundle_modules)
local rgb = require("constants").rgb
local Map = require("map")
local isCounterClockwise = require("helpers").isCounterClockwise --Load helper functions

local ControlZones = {}
ControlZones.__index = ControlZones

function ControlZones.new(namedZones, groundTemplates)
    local self = setmetatable({}, ControlZones)
    if not namedZones then
        self.allZones = {}      --array of names of zones
        self.zonesByName = {}   --full zone details indexed by zone name
        self.owner = {}
        self.neighbors = {}
        self.edges = {}
        self.perimeter = {}
        self.front = {
            blue = {},
            red = {}
        }
    else
        -- self.zonesByName = namedZones
        --put keys into allZones
    end
    self.maxima = nil
    self.groupCounter = 1
    self.commanders = {}
    -- self.maxima = {
    --     westmost = nil,
    --     eastmost = nil,
    --     northmost = nil,
    --     southmost = nil
    -- }
    self.groundTemplates = groundTemplates or {
        blue = {},
        red = {}
    }
    self.groupOfUnit = {}
    self.groundGroups = {}
    self.groupsByZone = {}
    self.centroid = {}
    return self
end

function ControlZones:addCommander(side, c)
    self.commanders[side] = c
end

function ControlZones:getOpponent(color)
    return color == "blue" and "red" or "blue"
end

function ControlZones:setup(options)
    options = options or {}

    for zonename, zoneobj in pairs(mist.DBs.zonesByName) do
        if string.sub(zonename,1,7) == 'control' then
            -- add an 'owner' property to zones
            -- zoneobj.owner = 0
            self.zonesByName[zonename] = zoneobj --indexed by name of the trigger zone
            table.insert(self.allZones, zoneobj.name) --list of all zone names / names of all zones
        end
    end

    -- Voronoi distribution from two initial random points
    local redSeed = self.allZones[math.random(#self.allZones)]
    local blueSeed = self.allZones[math.random(#self.allZones)]
    while blueSeed == redSeed do
        blueSeed = self.allZones[math.random(#self.allZones)]
    end

    local initialRedZone = self.zonesByName[redSeed]
    env.info("Red starting zone: "..redSeed)
    local initialBlueZone = self.zonesByName[blueSeed]
    env.info("Blue starting zone: "..blueSeed)

    for name, zone in pairs(self.zonesByName) do
        local redDistance = self:distance(zone, initialRedZone)
        local blueDistance = self:distance(zone, initialBlueZone)
        self.owner[name] = (redDistance < blueDistance) and "red" or "blue"
    end

    self.map = Map.new()

    self.perimeter = self:findPerimeter(self.allZones)

end

function ControlZones:centroidOfZones(zones)
    local sumX = 0
    local sumY = 0
    for _, id in pairs(zones) do
        sumX = sumX + self.zonesByName[id].x
        sumY = sumY + self.zonesByName[id].y
    end
    return { x = sumX / #zones, y = sumY / #zones }
end

function ControlZones:getCluster(color)
    local cluster = {}
    for name, ownerColor in pairs(self.owner) do
        if ownerColor == color then
            table.insert(cluster, name)
        end
    end
    return cluster
end

function ControlZones:distance(p1, p2)
    local dx = p2.x - p1.x
    local dy = p2.y - p1.y
    return math.sqrt(dx * dx + dy * dy)
end

function ControlZones:getZone(name)
    return self.zonesByName[name]
end

function ControlZones:getGroupsInZone(zoneName)
    return self.groupsByZone[zoneName]
end

function ControlZones:changeZoneOwner(name, newOwner)
    local formerOwner = self.owner[name]
    if newOwner == formerOwner then
        env.info("Notice: zone not changed, "..newOwner.." already controls "..name)
        return false
    end
    self.owner[name] = newOwner
    env.info("Control change: "..name.." switched from "..formerOwner.." to "..newOwner)

    self.map:redrawZone(name, newOwner, self:getZone(name).point)
    if formerOwner ~= "neutral" then
        local fronts = self:getOrderedFrontlines(formerOwner)
        local firstPass = true
        for _, front in pairs(fronts) do
            self.map:drawFrontlineFromPoints(front.points, formerOwner, firstPass)
            firstPass = false
        end
    end
    if newOwner ~= "neutral" then
        local fronts = self:getOrderedFrontlines(newOwner)
        local firstPass = true
        for _, front in pairs(fronts) do
            self.map:drawFrontlineFromPoints(front.points, newOwner, firstPass)
            firstPass = false
        end
    end
end

function ControlZones:checkOwnership(time)
    -- if owner units not in a color zone, lose control 
    -- if units in a neutral zone, gain control 
    -- if both colors in zone, no change
    env.info("checking zone control......")
    for zoneName, _ in pairs(self.zonesByName) do
        self:updateZoneOwner(zoneName)
    end
    return time + 30
end

function ControlZones:updateZoneOwner(zoneName)
    env.info("checking ownership of "..zoneName)
    local ownerColor = self.owner[zoneName]
    local blueGround = mist.makeUnitTable({'[blue][vehicle]'})
    local redGround = mist.makeUnitTable({'[red][vehicle]'})
        local groundInZone = {
            blue = mist.getUnitsInZones(blueGround, zoneName),
            red = mist.getUnitsInZones(redGround, zoneName)
        }
        if ownerColor == "neutral" then
        -- if blue and no red, blue now owns
        -- if red and no blue, red now owns
            -- if neither or both, stays neutral
            if #groundInZone["blue"] > 0 and #groundInZone["red"] <= 0 then
                self:changeZoneOwner(zoneName, "blue")
            elseif #groundInZone["red"] > 0 and #groundInZone["blue"] <= 0 then
                self:changeZoneOwner(zoneName, "red")
            end
        elseif ownerColor and #groundInZone[ownerColor] <= 0 then
            env.info("####### "..ownerColor.." no longer has any units in "..zoneName)
            local opponentColor = self:getOpponent(ownerColor)
            if #groundInZone[opponentColor] > 0 then
                self:changeZoneOwner(zoneName, opponentColor)
            else
                self:changeZoneOwner(zoneName, "neutral")
            end
        end
end

function ControlZones:addNeighbor(key1, key2) --bidirectional
    if not self:hasNeighbor(key1, key2) then
        table.insert(self.neighbors[key1], key2)
    end
    if not self:hasNeighbor(key2, key1) then
        table.insert(self.neighbors[key2], key1)
    end
end

function ControlZones:hasNeighbor(key, neighborKey)
    for _, n in ipairs(self.neighbors[key]) do
        if n == neighborKey then return true end
    end
    return false
end

function ControlZones:getNeighbors(key, color, includeNeutral)
    local color = color or nil
    if not color then
        return self.neighbors[key] or {}
    end
    local different = {}
    for _, n in ipairs(self.neighbors[key]) do
        if self.owner[n] == color or (includeNeutral and self.owner[n] == "neutral") then
            table.insert(different, n)
        end
    end
    return different
end

function ControlZones:constructDelaunayIndex()
    local points = {}
    local keyToIndex = {}
    local indexToKey = {}
    local index = 1

    -- Convert to indexed array for algorithm
    -- e.g. {1: {zone info}, ...}
    for key, point in pairs(self.zonesByName) do
        points[index] = {x = point.x, y = point.y}
        keyToIndex[key] = index
        indexToKey[index] = key
        index = index + 1
        self.neighbors[key] = {}
    end

    local triangles = self:delaunayTriangulate(points)

    -- Convert back to key-based triangles
    -- e.g. {3,15,7} to {"control-5","control-8","control-7"}
    self.triangles = {}
    for _, tri in ipairs(triangles) do
        table.insert(self.triangles, {
            indexToKey[tri[1]],
            indexToKey[tri[2]],
            indexToKey[tri[3]]
        })
    end
    for _, tri in ipairs(self.triangles) do
        self:addNeighbor(tri[1], tri[2])
        self:addNeighbor(tri[2], tri[3])
        self:addNeighbor(tri[3], tri[1])
    end

    self.keyToIndex = keyToIndex
    self.indexToKey = indexToKey

end

-- Bowyer-Watson Delaunay Triangulation
function ControlZones:delaunayTriangulate(points)
    if #points < 3 then return {} end

    -- Find bounding super-triangle to bootstrap the algorithm
    -- (Starting at infinity)
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge

    for _, p in ipairs(points) do
        minX = math.min(minX, p.x)
        minY = math.min(minY, p.y)
        maxX = math.max(maxX, p.x)
        maxY = math.max(maxY, p.y)
    end

    local dx = maxX - minX
    local dy = maxY - minY
    local deltaMax = math.max(dx, dy) * 2

    local superTriangle = {
        {x = minX - deltaMax, y = minY - 1},
        {x = minX + deltaMax * 2, y = minY - 1},
        {x = minX + deltaMax, y = maxY + deltaMax * 2}
    }

    -- Add super triangle points
    for _, p in ipairs(superTriangle) do
        table.insert(points, p)
    end

    local triangles = {{#points - 2, #points - 1, #points}}

    -- Add each point one at a time
    for i = 1, #points - 3 do
        local point = points[i]
        local badTriangles = {}

        -- Find triangles whose circumcircle contains the point
        for j, tri in ipairs(triangles) do
            if self:inCircumcircle(point, points[tri[1]], points[tri[2]], points[tri[3]]) then
                table.insert(badTriangles, j)
            end
        end

        -- Find the boundary of the polygonal hole
        local polygon = {}
        for _, triIdx in ipairs(badTriangles) do
            local tri = triangles[triIdx]
            local edges = {
                {tri[1], tri[2]},
                {tri[2], tri[3]},
                {tri[3], tri[1]}
            }

            for _, edge in ipairs(edges) do
                local shared = false
                for _, otherTriIdx in ipairs(badTriangles) do
                    if otherTriIdx ~= triIdx then
                        local otherTri = triangles[otherTriIdx]
                        if self:triangleHasEdge(otherTri, edge[1], edge[2]) then
                            shared = true
                            break
                        end
                    end
                end

                if not shared then
                    table.insert(polygon, edge)
                end
            end
        end

        -- Remove bad triangles (in reverse to maintain indices)
        for j = #badTriangles, 1, -1 do
            table.remove(triangles, badTriangles[j])
        end

        -- Create new triangles from point to polygon edges
        for _, edge in ipairs(polygon) do
            table.insert(triangles, {edge[1], edge[2], i})
        end
    end

    -- Remove triangles that share vertices with super triangle
    local finalTriangles = {}
    local superIndices = {#points - 2, #points - 1, #points}

    for _, tri in ipairs(triangles) do
        local hasSuper = false
        for _, v in ipairs(tri) do
            for _, s in ipairs(superIndices) do
                if v == s then
                    hasSuper = true
                    break
                end
            end
            if hasSuper then break end
        end

        if not hasSuper then
            table.insert(finalTriangles, tri)
        end
    end

    return finalTriangles
end

-- Check if point is inside circumcircle of triangle
function ControlZones:inCircumcircle(p, a, b, c)
    local ax, ay = a.x - p.x, a.y - p.y
    local bx, by = b.x - p.x, b.y - p.y
    local cx, cy = c.x - p.x, c.y - p.y

    local det = (ax * ax + ay * ay) * (bx * cy - cx * by) -
                (bx * bx + by * by) * (ax * cy - cx * ay) +
                (cx * cx + cy * cy) * (ax * by - bx * ay)

    return det > 0
end

-- Check if triangle contains edge
function ControlZones:triangleHasEdge(tri, v1, v2)
    return (tri[1] == v1 and tri[2] == v2) or (tri[2] == v1 and tri[1] == v2) or
           (tri[2] == v1 and tri[3] == v2) or (tri[3] == v1 and tri[2] == v2) or
           (tri[3] == v1 and tri[1] == v2) or (tri[1] == v1 and tri[3] == v2)
end

-- Get perimeter edges of the provided color that are facing another color
function ControlZones:getPerimeterZones(color)
    if not self.triangles then
        self:constructDelaunayIndex()
    end
    
    local frontZones = {}
    local frontSet = {}
    
    for _, tri in ipairs(self.triangles) do
        local colors = {
            self.owner[tri[1]],
            self.owner[tri[2]],
            self.owner[tri[3]]
        }
        
        -- Check each edge of the triangle
        local edgePairs = {
            {1, 2, 3},
            {2, 3, 1},
            {3, 1, 2}
        }
        
        for _, pair in ipairs(edgePairs) do
            local v1, v2, v3 = pair[1], pair[2], pair[3]
            
            -- Edge v1-v2 is part of perimeter if:
            -- - both v1 and v2 are 'color'
            -- - v3 is 'facingColor' or "neutral"
            if colors[v1] == color and colors[v2] == color and colors[v3] ~= color then
                local key1, key2 = tri[v1], tri[v2]
                if not frontSet[key1] then
                    frontSet[key1] = true
                    table.insert(frontZones, key1)
                end
                if not frontSet[key2] then
                    frontSet[key2] = true
                    table.insert(frontZones, key2)
                end
            end
        end
    end
    
    return frontZones
end

function ControlZones:getPerimeterEdges(color, returnPoints) --returns a table of pairs of zone names (default) or positions of those zones
    if not self.triangles then
        self:constructDelaunayIndex()
    end
    
    local edges = {}
    local edgeSet = {}  -- to avoid duplicates
    
    for _, tri in ipairs(self.triangles) do
        local colors = {
            self.owner[tri[1]],
            self.owner[tri[2]],
            self.owner[tri[3]]
        }
        
        -- Check each edge of the triangle
        local edgePairs = {
            {1, 2, 3},
            {2, 3, 1},
            {3, 1, 2}
        }
        
        for _, pair in ipairs(edgePairs) do
            local v1, v2, v3 = pair[1], pair[2], pair[3]
            
            -- Edge v1-v2 is part of perimeter if:
            -- - both v1 and v2 are 'color'
            -- - v3 is 'facingColor' or "neutral"
            if colors[v1] == color and colors[v2] == color and colors[v3] ~= color then
                local key1, key2 = tri[v1], tri[v2]
                local edgeKey = key1 < key2 and (key1 .. "-" .. key2) or (key2 .. "-" .. key1)
                
                if not edgeSet[edgeKey] then
                    edgeSet[edgeKey] = true
                    if returnPoints then
                        table.insert(edges, {p1 = self:getZone(key1).point, p2 = self:getZone(key2).point, o1 = self:getZone(tri[v3]).point})
                    else
                        table.insert(edges, {p1 = key1, p2 = key2, o1 = tri[v3]})
                    end
                end
            end
        end
    end
    
    return edges
end

function ControlZones:getEdge(z1, z2)
    local edgeKey = z1 < z2 and (z1 .. "-" .. z2) or (z2 .. "-" .. z1)
    return self.edges[edgeKey]
end

function ControlZones:getAllEdges()
    if not self.triangles then
        self:constructDelaunayIndex()
    end
    if not self.edges then
        self:precalculateConnections()
    end

    return self.edges
end

function ControlZones:precalculateConnections()
    if not self.triangles then
        self:constructDelaunayIndex()
    end
    local edgeSet = {}  -- to avoid duplicates

    -- Examine each triangle
    for l, tri in ipairs(self.triangles) do
        -- Check each edge of the triangle
        local triPairs = {
            {1, 2},
            {2, 3},
            {3, 1}
        }
        for m, pair in ipairs(triPairs) do
            local v1, v2 = pair[1], pair[2]
            local key1, key2
            if tri[v1] < tri[v2] then
                key1, key2 = tri[v1], tri[v2]
            else
                key1, key2 = tri[v2], tri[v1]
            end
            local edgeKey = key1 .. "-" .. key2

            if not edgeSet[edgeKey] then
                edgeSet[edgeKey] = true
                local z1, z2 = self:getZone(key1), self:getZone(key2)
                local heading = mist.utils.getHeadingPoints(z1.point, z2.point)
                local distance = mist.utils.get2DDist(z1.point, z2.point)
                local roadPath = land.findPathOnRoads("roads", z1.x, z1.y, z2.x, z2.y)
                local roadDistance = mist.getPathLength(roadPath)
                local allowable_detour = 1.4
                local cross_country = roadDistance / distance > allowable_detour

                -- Depending on number of zones and their separation, it could be speed things up
                -- to not bother with full calculation if road path is obviously inefficient
                -- local cutoff = distance * 2
                -- local roadDistance, _ = mist.getPathLength(roadPath, cutoff)

                self.edges[edgeKey] = {
                    p1 = z1.point,
                    p2 = z2.point,
                    heading = heading,
                    distance = {
                        straight = distance,
                        road = roadDistance,
                    },
                    crosscountry = cross_country,
                    terrainDifficulty = 0,
                    triangles = {l} --index of member triangle in self.triangles
                }
            elseif not table.contains(self.edges[edgeKey].triangles, l) then
                table.insert(self.edges[edgeKey].triangles, l)
            end
        end
    end

    return self.edges
end

-- Normalize angle to [0, 2π)
local function normalizeAngle(angle)
    local TWO_PI = 2 * math.pi
    angle = angle % TWO_PI
    if angle < 0 then
        angle = angle + TWO_PI
    end
    return angle
end
local function angularDistance(from, to)
    local TWO_PI = 2 * math.pi
    local diff = (to - from) % TWO_PI
    if diff < 0 then
        diff = diff + TWO_PI
    end
    return diff
end

function ControlZones:getHeading(z1, z2)
    local heading = self:getEdge(z1, z2).heading
    if z1 < z2 then
        return heading
    else
        return normalizeAngle(heading + math.pi)
    end
end

function ControlZones:calculateLength(front)
    local length = 0
    if #front.zones < 2 then
        return length
    end

    for i=2, #front.zones do
        local edge = self:getEdge(front.zones[i], front.zones[i-1])
        length = length + edge.distance.straight
    end
    if front.isLoop then
        local edge = self:getEdge(front.zones[#front.zones], front.zones[1])
        length = length + edge.distance.straight
    end

    return length
end

-- Calculates edges in contiguous sequence, returning multiple if frontline is disconnected
function ControlZones:getOrderedFrontlines(color)
    local edges = self:getPerimeterEdges(color)

    if #edges == 0 then return {} end
    local globalVisited = {}
    local fronts = {}

    -- Generate a lookup table for all own border zones
    local frontZones = {}
    for _, edge in ipairs(edges) do
        frontZones[edge.p1] = true
        frontZones[edge.p2] = true
    end

    -- Find flank zones (both on the frontline and on the global perimeter)
    local anchors = {}
    for zone, _ in pairs(frontZones) do
        if table.contains(self.perimeter, zone) then
            table.insert(anchors, zone)
        end
    end

    -- Find frontline path by clockwise sweep from previous allied zone, projecting points toward each enemy zone
    -- then jumping to first allied zone encountered until back at start zone or reached the other flank (zone is on the perimeter)
    local function constructSegment(startKey, prev)
        local segment = {
            zones = {},
            points = {},
            length = nil,
            isLoop = false,
        }
        local current = startKey
        local lastEnemy = nil
        local isPenultimate = false

        repeat -- keep hopping to allied neighbor (the one on closest cw heading after enemy neighbor)
            globalVisited[current] = true
            table.insert(segment.zones, current)
            local z = self:getZone(current)

            local foundNext = false

            -- Sort all neighbors by distance from prev heading
            local initialHeading = normalizeAngle(
                mist.utils.getHeadingPoints(
                    self:getZone(current).point,
                    self:getZone(prev).point
                )
            )
            local sortedNeighbors = self:getNeighbors(current)
            table.sort(sortedNeighbors, function(a, b)
                local headingA = normalizeAngle(mist.utils.getHeadingPoints(z.point, self:getZone(a).point))
                local headingB = normalizeAngle(mist.utils.getHeadingPoints(z.point, self:getZone(b).point))
                local arcA = angularDistance(initialHeading, headingA)
                local arcB = angularDistance(initialHeading, headingB)
                return arcA < arcB
            end)
            table.insert(sortedNeighbors, table.remove(sortedNeighbors, 1))

            local nextFriendlyZone = nil
            for _, neighbor in pairs(sortedNeighbors) do
                if self.owner[neighbor] == color then
                    nextFriendlyZone = neighbor
                    break
                else
                    lastEnemy = neighbor
                    local enemyHeading = self:getHeading(current, neighbor)
                    table.insert(segment.points, {center = z.point, heading = enemyHeading})
                    -- if current is a flank anchor (on the perimeter), stop at first enemy also on perimeter
                    -- (handles lone perimeter zone that has no allied neighbors)
                    if isPenultimate and table.contains(self.perimeter, neighbor) then
                        break
                    end
                end
            end

            if isPenultimate then
                foundNext = false
            elseif nextFriendlyZone then
                if frontZones[nextFriendlyZone] then -- neighbor is also on frontline
                    if table.contains(self.perimeter, nextFriendlyZone) then
                        isPenultimate = true
                    end
                    foundNext = true
                    prev = current
                    current = nextFriendlyZone
                end
            end
        until (current == startKey and not table.contains(anchors, current)) or not foundNext

        if current == startKey and not table.contains(self.perimeter, current) then
            -- make a final, extra line back to original zone, offset toward shared enemy neighbor
            if lastEnemy then
                local lastPoint = self:getZone(current).point
                local enemyHeading = mist.utils.getHeadingPoints(lastPoint, self:getZone(lastEnemy).point)
                table.insert(segment.points, {center = lastPoint, heading = enemyHeading})
            end
            segment.isLoop = true
        end
        segment.length = self:calculateLength(segment)

        return segment
    end --end local function constructSegment

    -- Construct all anchored front lines by starting at each left flank zone
    for _, zone in pairs(anchors) do
        local i = table.findIndex(self.perimeter, zone)
        if i then
            local ccw = i+1 > #self.perimeter and 1 or i+1
            local cw = i-1 < 1 and #self.perimeter or i-1
            local ccwz = self.perimeter[ccw]
            local cwz = self.perimeter[cw]
            if self.owner[ccwz] == color and self.owner[cwz] ~= color then
                local segment = constructSegment(zone, ccwz)
                table.insert(fronts, segment)
            elseif self.owner[ccwz] ~= color and self.owner[cwz] ~= color then
                local segment = constructSegment(zone, ccwz)
                table.insert(fronts, segment)
            end
        end
    end

    -- Examine all zones on border to identify closed loop (internal) fronts
    for startKey, _ in pairs(frontZones) do
        if not globalVisited[startKey] then
            env.info(">>>>>>> "..startKey.." hasn't been visited yet")
            local tris = {}
            -- Find triangles that include the zone in question
            for _, edge in pairs(edges) do
                if edge.p1 == startKey then
                    table.insert(tris, {edge.p1, edge.p2, edge.o1})
                elseif edge.p2 == startKey then
                    table.insert(tris, {edge.p2, edge.p1, edge.o1})
                end
            end
            -- Identify previous allied zone by startKey->enemy->allied being a ccw sequence
            for _, tri in pairs(tris) do
                local z1 = self:getZone(tri[1])
                local z2 = self:getZone(tri[3]) --enemy neighbor
                local z3 = self:getZone(tri[2]) --allied neighbor

                if isCounterClockwise({x = z1.x, y = z1.y}, {x = z2.x, y = z2.y}, {x = z3.x, y = z3.y}) then
                    env.info("   using "..tri[2].." as prev for "..startKey)
                    local segment = constructSegment(startKey, tri[2])
                    table.insert(fronts, segment)
                end
            end
        end
    end

    return fronts
end

function ControlZones:assignCompassMaxima()
    local firstZone = self:getZone(self.allZones[1])
    self.maxima = {
        westmost = { name = firstZone.name, x = firstZone.x, y = firstZone.y},
        eastmost = { name = firstZone.name, x = firstZone.x, y = firstZone.y},
        southmost = { name = firstZone.name, x = firstZone.x, y = firstZone.y},
        northmost = { name = firstZone.name, x = firstZone.x, y = firstZone.y},
    }
    for i = 2, #self.allZones do
        local zone = self:getZone(self.allZones[i])
        if zone.y < self.maxima.westmost.y then
            self.maxima.westmost = { name = zone.name, x = zone.x, y = zone.y}
        elseif zone.y > self.maxima.eastmost.y then
            self.maxima.eastmost = { name = zone.name, x = zone.x, y = zone.y}
        end
        if zone.x < self.maxima.southmost.x then
            self.maxima.southmost = { name = zone.name, x = zone.x, y = zone.y}
        elseif zone.x > self.maxima.northmost.x then
            self.maxima.northmost = { name = zone.name, x = zone.x, y = zone.y}
        end
    end
end

function ControlZones:findPerimeter(zoneList) --zoneList is array of indices = names from zonesByName table
    if #zoneList < 3 then return zoneList end

    local zones = {}
    for _, zonename in pairs(zoneList) do
        zone = self:getZone(zonename)
        table.insert(zones, { name = zonename, x = zone.x, y = zone.y })
    end

    local leftmost = 1
    for i = 2, #zones do
        if zones[i].y < zones[leftmost].y then
            leftmost = i
        end
    end

    local hull = {}
    local current = leftmost

    repeat
        table.insert(hull, zones[current].name) --first point will be westmost
        local next = 1

        for i = 2, #zones do
            if next == current or isCounterClockwise(zones[current], zones[i], zones[next]) then
                next = i
            end
        end

        current = next
    until current == leftmost --we're back at first point

    return hull --return array of zone names
end

function ControlZones:selectTrianglesForFARPs(color, front)
    if #front.zones < 2 then
        return {}
    end

    FARP_MIN_INTERVAL = 20000
    local farpEdges = {}
    local farpTris = {}
    local length = 0

    for i=2, #front.zones do
        local edge = self:getEdge(front.zones[i], front.zones[i-1])
        length = length + edge.distance.straight
        if length > FARP_MIN_INTERVAL then
            table.insert(farpEdges, {front.zones[i], front.zones[i-1]})
            length = 0
            -- or examine associated triangles right away and do not reset length if no fully-controlled found
        end
    end

    for _, edge in pairs(farpEdges) do
        for _, tri in pairs(self.triangles) do
            if self:triangleHasEdge(tri, edge[1], edge[2]) then
                if self.owner[tri[1]] == color and self.owner[tri[2]] == color and self.owner[tri[3]] == color then
                    table.insert(farpTris, tri)
                    break
                end
            end
        end
    end

    return farpTris
end

function ControlZones:placeFARP(color, pt)
    local searchRadius = 1000
    local clearRadius = 120
    local spot = Disposition.getSimpleZones(mist.utils.makeVec3(pt), searchRadius, clearRadius, 1)
    if not spot or not spot[1] then
        env.info("!! no suitable spot found for spawning FARP")
        return false
    end

    local coal = color == "blue" and country.id.USA or country.id.RUSSIA --country.id.USSR
    local farp = {
        ["category"] = "Heliports",
        ["shape_name"] = "FARPS", -- "invisiblefarp"  | "FARP"           | "FARP_SINGLE_01"
        ["type"] = "FARP",        -- "Invisible FARP" | "SINGLE_HELIPAD" | "FARP_SINGLE_01"
        ["unitId"] = mist.getNextUnitId(),
        ["x"] = spot[1].x,
        ["y"] = spot[1].y,
        ["name"] = color.." FARP "..math.random(1000,9999),
        ["heading"] = 0,
        ["dead"] = false,
        ["dynamicSpawn"] = true,
        ["allowHotStart"] = true
        -- ["dynamicCargo"]
    }
    coalition.addStaticObject(coal, farp)

    local farp_stock = {
        blue = {
            "UH-1H",
            "AH-64D_BLK_II",
        },
        red = {
            "Mi-8MT",
            "Mi-24P",
            "Ka-50_3",
        }
    }
    timer.scheduleFunction(
        function (info)
            local farpObj = Airbase.getByName(info.name)
            local wh = farpObj:getWarehouse()
            for _, item in pairs(farp_stock[info.color]) do
                wh:setItem(item, 4)
            end
            wh:setLiquidAmount(0, 1000)
        end,
        {name = farp.name, color = color},
        timer.getTime()+5
    )

    return true -- or farp name or id
end

function ControlZones:orientToClosestEnemy(zoneName)
    local opponent = self:getOpponent(self.owner[zoneName])
    local enemyNeighbors = self:getNeighbors(zoneName, opponent)
    local nearestEnemy
    local dist = math.huge
    for _, enemyZone in pairs(enemyNeighbors) do
        local newDist = self:getEdge(zoneName, enemyZone).distance.straight
        if newDist < dist then
            nearestEnemy = enemyZone
            dist = newDist
        end
    end
    local heading
    if nearestEnemy then
        heading = mist.utils.getHeadingPoints(self:getZone(zoneName).point, self:getZone(nearestEnemy).point)
        env.info("-> Orienting units in"..zoneName..": "..mist.utils.toDegree(heading))
    else
        heading =  mist.utils.getHeadingPoints(self.centroid[self.owner[zoneName]], self.centroid[opponent])
        env.info("!? could not find nearestEnemy (might not be frontline zone)")
    end
    return heading
end

function ControlZones:spawnGroupInZone(groupName, zoneName, color, template, heading)
    local zn = self:getZone(zoneName)
    local unitSet = {}

    local searchRadius = zn.radius
    local clearRadius = 50
    local spots = Disposition.getSimpleZones(zn.point, searchRadius, clearRadius, #template)

    if #spots < #template then
        env.info("!! not enough spots for spawning all units in "..zoneName..". spots found: "..#spots.." of "..#template)
        for i=1, #template do
            if not spots[i] then spots[i] = mist.getRandomPointInZone(zoneName) end
        end
    end

    for j, unitName in pairs(template) do
        local variance = math.random(-4, 4)/10
        local hdg = heading + variance
        table.insert(unitSet, j, { type = unitName, x = spots[j].x, y = spots[j].y, heading = hdg})
    end
    local newGroup = mist.dynAdd({ -- mist.dynAddStatic()
        groupName = groupName,
        units = unitSet,
        country = color == "blue" and "USA" or "USSR",
        category = "vehicle",
    })
    for _, unit in pairs(Group.getByName(groupName):getUnits()) do
        local unitName = unit:getName()
        if unitName then self.groupOfUnit[unitName] = newGroup.name end
    end
    self.groundGroups[newGroup.name] = {
        origin = zoneName,
        color = color,
    }
    if not self.groupsByZone[zoneName] then
        self.groupsByZone[zoneName] = { groupName }
    else
        table.insert(self.groupsByZone[zoneName], groupName)
    end
    return groupName
end

function ControlZones:processDeadUnit(unitName)
    env.info("control zone: unit "..unitName.." is dead")
    local grpName = self.groupOfUnit[unitName]
    local grpColor = self.groundGroups[grpName].color
    env.info("    from group "..grpName.." of "..grpColor)
    if mist.groupIsDead(grpName) then --error if player
        env.info("    >>> GROUP LOST all units of "..grpName.." are dead")
        self.commanders[grpColor]:registerGroupLost(grpName)
        local originZone = self.groundGroups[grpName].origin
        self:updateZoneOwner(originZone)
    else
        self.commanders[grpColor]:registerUnitLost(unitName, grpName)
    end
end

function ControlZones:constructTask(params)
    local task = {}
    local pt = params.destination.point

    local route = {
        ["points"] = {
            [1] = {
                type= AI.Task.WaypointType.TURNING_POINT,
                x = pt.x,
                y = pt.z,
                speed = 100,
                action = AI.Task.VehicleFormation.RANK
            },
            [2] = {
                type= AI.Task.WaypointType.TURNING_POINT,
                x = pt.x,
                y = pt.z,
                speed = 100,
                action = AI.Task.VehicleFormation.RANK
            },
        }
    }

    --also mist.ground.buildWP or mist.groupToPoint(groupName, zoneName, ...)
    local taskMove = {
        id = 'Mission',
        params = {
            route = route,
        }
    }

    task = taskMove
    return task
end

function ControlZones:setGroupTask(groupName, task)
    local group = Group.getByName(groupName)
    if not group then
        env.info("Not assigning task: no group "..groupName)
        return false
    end

    group:getController():setTask(task)
    --remove group from self.groupsByZone[]
    return true
end

function ControlZones:populateZones()
    -- on first pass spawn basic template to hold zone,
    -- later reinforce zones prioritized by each commander
    for _, cmd in pairs(self.commanders) do
        --a single group for each zone to start
        local zones = self:getCluster(cmd.color)
        local avgHeading =  mist.utils.getHeadingPoints(self.centroid[cmd.color], self.centroid[self:getOpponent(cmd.color)])
        local reinforcements = cmd:chooseZoneReinforcements(zones)
        for zoneName, data in pairs(reinforcements) do
            self:spawnGroupInZone(data.groupName, zoneName, cmd.color, data.template, avgHeading)
        end

        --front zones get an additional group
        local frontlineZones = self:getPerimeterZones(cmd.color)
        reinforcements = cmd:chooseZoneReinforcements(frontlineZones)
        for zoneName, data in pairs(reinforcements) do
            local heading = self:orientToClosestEnemy(zoneName)
            self:spawnGroupInZone(data.groupName, zoneName, cmd.color, data.template, heading)
        end
    end
end

function ControlZones:requestOrders()
    for _, cmd in pairs(self.commanders) do
        local params = cmd:issueOrders()
        if params then
            env.info("    constructing task for "..params.group)
            local task = self:constructTask(params)
            self:setGroupTask(params.group, task)
            self.map:drawDirective(self:getZone(params.origin.name).point, self:getZone(params.destination.name).point, cmd.color)
        end
    end
end

function ControlZones:kickoff()
    local zoneInfo = {}
    for name, color in pairs(self.owner) do
        zoneInfo[name] = {color = color, point = self:getZone(name).point}
    end
    self.map:drawZones(zoneInfo)
    self.map:drawEdges(self:getAllEdges())

    for color, _ in pairs(self.commanders) do
        self.centroid[color] = self:centroidOfZones(self:getCluster(color))
        local fronts = self:getOrderedFrontlines(color)

        -- for each front, draw frontline and place FARPs
        for i, front in pairs(fronts) do
            env.info(color.." "..i)
            local pts = front.points
            self.map:drawFrontlineFromPoints(pts, color)

            for _, tri in pairs(self:selectTrianglesForFARPs(color, front)) do
                local center = self:centroidOfZones({tri[1], tri[2], tri[3]})
                self:placeFARP(color, center)
            end
        end
    end

    self:populateZones()
    timer.scheduleFunction(
        function(params)
            params.context:requestOrders()
            return timer.getTime() + 30
        end,
        {context = self},
        timer.getTime() + 8
    )
end

return ControlZones

end)
__bundle_register("helpers", function(require, _LOADED, __bundle_register, __bundle_modules)
local function isCounterClockwise(p1, p2, p3)
    -- swapped to account for DCS coordinate weirdness
    return (p2.y - p1.y) * (p3.x - p1.x) - (p2.x - p1.x) * (p3.y - p1.y) > 0
    -- standard (x,y) as (N/S,E/W) version:
    -- return (p2.x - p1.x) * (p3.y - p1.y) - (p2.y - p1.y) * (p3.x - p1.x) > 0
end

return {
    isCounterClockwise = isCounterClockwise
}

end)
__bundle_register("map", function(require, _LOADED, __bundle_register, __bundle_modules)
local rgb = require("constants").rgb
local settings = require("settings")
local Map = {}
Map.__index = Map

function Map.new()
    local self = setmetatable({}, Map)
    self.markerCounter = 5000
    self.markers = {
        front = {
            red = {},
            blue = {}
        },
        zones = {},
        zoneLabels = {},
        edges = {},
    }
    return self
end

function Map:getNewMarker()
    self.markerCounter = self.markerCounter + 1
    return self.markerCounter
end

function Map:getVisibility(color, feature)
    -- Return value will include '0' or '-1' to ensure that map marks are always
    -- drawn for neutrals (game commander and spectators), regardless of settings
    if settings.displayToAll[feature] then
        return {-1}
    else
        return {0, color == "red" and 1 or 2}
    end
end

function Map:drawZone(name, color, pt)
    if not settings.draw.zones then return end
    if not self.markers.zones[name] then self.markers.zones[name] = {} end
    local sides = self:getVisibility(color, "zones")
    for _, side in pairs(sides) do
        local zoneId = self:getNewMarker()
        table.insert(self.markers.zones[name], zoneId)
        trigger.action.circleToAll(side, zoneId, pt, 510, {0,0,0,0.2}, rgb[color], 1)
        local labelId = self:getNewMarker()
        trigger.action.textToAll(side, labelId, pt, {1,1,0,0.5}, {0,0,0,0}, 13, true, name)
    end
end

function Map:redrawZone(name, color, point)
    if not settings.draw.zones then return end
    if settings.displayToAll.zones then -- Change fill color of existing marker
        for _, id in pairs(self.markers.zones[name]) do
            trigger.action.setMarkupColorFill(id, rgb[color])
        end
    else -- Erase markers so new ones can be drawn with appropriate visibility
        for _, id in pairs(self.markers.zones[name]) do
            trigger.action.removeMark(id)
        end
        self.markers.zones[name] = {}
        self:drawZone(name, color, point)
    end
end

function Map:drawZones(zones)
    if not settings.draw.zones then return end
    for name, info in pairs(zones) do
        self:drawZone(name, info.color, info.point)
    end
end

function Map:drawEdges(edges)
    if not settings.draw.edges then return end
    for _, edge in pairs(edges) do
        local lineId = self:getNewMarker()
        table.insert(self.markers.edges, lineId)
        trigger.action.lineToAll(-1, lineId, edge.p1, edge.p2, {1,1,0.2,0.1}, 5)
    end
end

function Map:drawFrontline(edges, color)
    --first erase any existing lines
    if self.markers.front[color] then
        for _, id in pairs(self.markers.front[color]) do
            trigger.action.removeMark(id)
        end
        self.markers.front[color] = {}
    end
    --then draw a line for each edge of the current color's front
    local sides = self:getVisibility(color, "frontlines")
    for _, side in pairs(sides) do
        for _, zonePoints in pairs(edges) do
            local lineId = self:getNewMarker()
            table.insert(self.markers.front[color], lineId)
            local lineColor = rgb[color]
            trigger.action.lineToAll(side, lineId, zonePoints.p1, zonePoints.p2, lineColor, 1)
            -- trigger.action.lineToAll(side, lineId2, p1B, p2B, lineColor, 1) --double the line for better visibility
        end
    end
end

function Map:drawFrontlineFromPoints(points, color, erasePrevious)
    local OFFSET = 1500
    -- first erase any existing lines
    if erasePrevious and self.markers.front[color] then
        for _, id in pairs(self.markers.front[color]) do
            trigger.action.removeMark(id)
        end
        self.markers.front[color] = {}
    end

    --then draw a line for each edge of the current color's front
    local sides = self:getVisibility(color, "frontlines")
    local prevPts = {}
    for _, side in pairs(sides) do
        local firstPass = true
        for _, data in pairs(points) do
            local lineId1 = self:getNewMarker()
            local lineId2 = self:getNewMarker()
            table.insert(self.markers.front[color], lineId1)
            table.insert(self.markers.front[color], lineId2)
            local lineColor = rgb[color]
            local point1 = mist.projectPoint(data.center, OFFSET, data.heading)
            local point2 = mist.projectPoint(data.center, OFFSET+200, data.heading)
            if not firstPass then
                trigger.action.lineToAll(side, lineId1, prevPts[1], point1, lineColor, 1)
                trigger.action.lineToAll(side, lineId2, prevPts[2], point2, lineColor, 1)
            end
            prevPts[1] = point1
            prevPts[2] = point2
            firstPass = false
        end
    end
end

function Map:drawDirective(originPoint, targetPoint, color)
    if not settings.draw.directives then return end
    local sides = self:getVisibility(color, "directives")
    for _, side in pairs(sides) do
        local nextId = self:getNewMarker()
        local lineColor = {1,1,0.2,1}
        local fillColor = lineColor
        local heading = mist.utils.getHeadingPoints(originPoint, targetPoint)
        local reciprocal = mist.utils.getHeadingPoints(targetPoint, originPoint)
        local distance = 1000
        local lineStart = mist.projectPoint(originPoint, distance+200, heading)
        local arrowEnd = mist.projectPoint(targetPoint, distance, reciprocal)
        trigger.action.arrowToAll(side, nextId, arrowEnd, lineStart, lineColor, fillColor, 1)
    end
    return true
end

return Map
end)
__bundle_register("settings", function(require, _LOADED, __bundle_register, __bundle_modules)
local settings = {
    draw = {
        edges = true,
        zones = true,
        frontlines = true,
        directives = true,
    },
    displayToAll = { 
        zones = true,
        frontlines = true,
        directives = false,
    }
}

return settings
end)
__bundle_register("table", function(require, _LOADED, __bundle_register, __bundle_modules)
function table.contains(table, el)
    for _, v in pairs(table) do
        if v == el then
            return true
        end
    end
    return false
end

function table.findIndex(table, needle)
    for i, v in pairs(table) do
        if v == needle then
            return i
        end
    end
    return nil
end

end)
return __bundle_require("__root")