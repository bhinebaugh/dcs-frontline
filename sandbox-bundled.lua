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
Constants = require("constants")
AcceptableLevelsOfRisk = Constants.acceptableLevelsOfRisk
GroundTemplates = Constants.groundTemplates
TaskTypes = Constants.taskTypes

CoalitionCommander = require("coalition-commander")
ControlZones = require("control-zones")
GroupCommander = require("group-commander")
Order = require("order")
PatrolDoctrine = require("doctrines.tactical.patrol-doctrine")

-- Initial objective for Alpha is to defend the bridge
-- near the coordinates:
local blueDefendPosition = coord.LLtoLO(
    46 + 29/60 + 18/3600,
    38 + 08/60 + 05/3600
)

-- Known safe rally point for Blue forces
local bluePatrolPosition = coord.LLtoLO(
    46 + 28/60 + 26/3600,
    38 + 19/60 + 12/3600
)

-- Initial objective for Bravo is to reposition to the
-- Kvemo-Khoshka village at these coordinates:
local redPatrolPosition = coord.LLtoLO(
    46 + 33/60 + 23/3600,
    38 + 27/60 + 25/3600
)

-- Known safe rally point for Red forces
local redDefendPosition = coord.LLtoLO(
    46 + 32/60 + 58/3600,
    38 + 39/60 + 09/3600
)

local alpha = ControlZones:spawnGroupAtPoint(
    "Alpha",
    blueDefendPosition,
    "blue",
    GroundTemplates.blue[2],
    90
)
AlphaCommander = GroupCommander.new("Alpha", alpha)

local arnold = ControlZones:spawnGroupAtPoint(
    "Arnold",
    redPatrolPosition,
    "red",
    GroundTemplates.red[1],
    270
)
ArnoldCommander = GroupCommander.new("Arnold", arnold)

local benson = ControlZones:spawnGroupAtPoint(
    "Benson",
    redDefendPosition,
    "red",
    GroundTemplates.red[4],
    270
)
BensonCommander = GroupCommander.new("Benson", benson)

CZ = ControlZones.new(nil, GroundTemplates)
CcBlue = CoalitionCommander.new(CZ, {color = "blue", groundTemplates = GroundTemplates.blue})
CcRed = CoalitionCommander.new(CZ, {color = "red", groundTemplates = GroundTemplates.red})
CZ:addCommander("blue", CcBlue)
CZ:addCommander("red", CcRed)

local alphaDefenseOrder = Order.new({
    type = TaskTypes.ASSAULT,
    position = bluePatrolPosition,
    alr = AcceptableLevelsOfRisk.MEDIUM
})
AlphaCommander:issueOrder(alphaDefenseOrder)

local arnoldDefenseOrder = Order.new({
    type = TaskTypes.ASSAULT,
    position = bluePatrolPosition,
    alr = AcceptableLevelsOfRisk.LOW
})
ArnoldCommander:issueOrder(arnoldDefenseOrder)

ArnoldDefenseOrder = Order.new({
    type = TaskTypes.DEFEND,
    alr = AcceptableLevelsOfRisk.LOW
})

-- BensonCommander:issueOrder(bensonDefenseOrder)

-- ## General scenario setup
-- 1. Bravo encounters Alpha overlooking the bridge
--   - Should spot them when near Kvemo-Roka villag
--   - at a fork in the road
-- 2. Bravo retreats up either branch of the fork
-- 3. Alpha pursues, but loses sight due to terrain
-- 4. Alpha breaks off pursuit and returns to defend the bridge
-- 5. Bravo reports enemy position to strategic command
-- 6. Strategic command dispatches reinforcements to assist Bravo
-- 7. Bravo attempts to continue to Kvemo-Khoshka village after the threat is removed

end)
__bundle_register("doctrines.tactical.patrol-doctrine", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local dispositionTypes = constants.dispositionTypes
local Doctrine = require("doctrine")
local SpatialAgent = require("spatial-agent")
local PatrolDoctrine = {}
setmetatable(PatrolDoctrine, {__index = Doctrine})
PatrolDoctrine.__index = PatrolDoctrine

-- Factory method for creating new Doctrine instances
function PatrolDoctrine.new(commanderName)
    local self = Doctrine.new("Patrol", commanderName)
    setmetatable(self, PatrolDoctrine)

    self:registerPhase("OutboundLeg", PatrolDoctrine.outboundPhase)
    self:registerPhase("InboundLeg", PatrolDoctrine.inboundPhase)

    return self
end

function PatrolDoctrine:outboundPhase(context)
    if not self.state.StartingPoint then
        self.state.StartingPoint = context.ownPosition
    end

    if not self.state.Destination then
        self.state.Destination = context.orderPosition or self.state.StartingPoint
    end

    local distanceToDestination = self.state.Destination and SpatialAgent.distance2D(context.ownPosition, self.state.Destination)
    env.info(context.groupName .. " is " .. tostring(distanceToDestination) .. " meters from patrol destination")
    local isAtDestination = distanceToDestination and distanceToDestination < 50

    if isAtDestination then
        env.info(context.groupName .. " has reached patrol destination, switching to InboundLeg")
        self:changePhase("InboundLeg")
        return {disposition = dispositionTypes.HOLD, destination = nil}
    else
        return {disposition = dispositionTypes.ADVANCE, destination = self.state.Destination, orderAction = "start"}
    end
end

function PatrolDoctrine:inboundPhase(context)
    local isAtStart = self.state.StartingPoint and SpatialAgent.distance2D(context.ownPosition, self.state.StartingPoint) < 50

    if isAtStart then
        env.info(context.groupName .. " has returned to starting point, switching to OutboundLeg")
        self:changePhase("OutboundLeg")
        return {disposition = dispositionTypes.HOLD, destination = nil}
    else
        return {disposition = dispositionTypes.ADVANCE, destination = self.state.StartingPoint}
    end
end


return PatrolDoctrine

end)
__bundle_register("spatial-agent", function(require, _LOADED, __bundle_register, __bundle_modules)
-- SpatialAgent: DCS-aware geometry and spatial calculations
-- Provides consistent, tested spatial operations for commanders
-- (Yes, it's a pun on "Special Agent" 🕵️)

local SpatialAgent = {}

-- ============================================================================
-- DISTANCE CALCULATIONS
-- ============================================================================

--- Calculate 2D distance between two positions
-- Handles DCS position formats (with or without .p property)
-- @param pos1 Position table {x, y, z} or {p = {x, y, z}}
-- @param pos2 Position table {x, y, z} or {p = {x, y, z}}
-- @return number Distance in meters, or nil if positions invalid
function SpatialAgent.distance2D(pos1, pos2)
    if not pos1 or not pos2 then
        return nil
    end
    
    -- Extract actual position if wrapped in .p
    local p1 = pos1.p or pos1
    local p2 = pos2.p or pos2
    
    if not p1.x or not p1.z or not p2.x or not p2.z then
        return nil
    end
    
    local dx = p1.x - p2.x
    local dz = p1.z - p2.z
    return math.sqrt(dx * dx + dz * dz)
end

--- Calculate squared 2D distance (faster, avoids sqrt)
-- Useful for radius checks: distanceSquared < radius^2
-- @param pos1 Position table
-- @param pos2 Position table
-- @return number Squared distance in meters^2, or nil if positions invalid
function SpatialAgent.distanceSquared(pos1, pos2)
    if not pos1 or not pos2 then
        return nil
    end
    
    local p1 = pos1.p or pos1
    local p2 = pos2.p or pos2
    
    if not p1.x or not p1.z or not p2.x or not p2.z then
        return nil
    end
    
    local dx = p1.x - p2.x
    local dz = p1.z - p2.z
    return dx * dx + dz * dz
end

--- Check if position is within radius of center
-- Optimized: uses squared distance to avoid sqrt
-- @param position Position to check
-- @param center Center position
-- @param radius Radius in meters
-- @return boolean True if within radius, false otherwise
function SpatialAgent.isWithinRadius(position, center, radius)
    local distSq = SpatialAgent.distanceSquared(position, center)
    if not distSq then
        return false
    end
    return distSq <= (radius * radius)
end

-- ============================================================================
-- CENTER OF MASS / AVERAGE POSITION
-- ============================================================================

--- Calculate geometric center (average position) of multiple positions
-- @param positions Array of position tables
-- @return table Center position {x, y, z}, or nil if no valid positions
function SpatialAgent.calculateCenter(positions)
    if not positions or #positions == 0 then
        return nil
    end
    
    local sumX = 0
    local sumY = 0
    local sumZ = 0
    local count = 0
    
    for _, pos in ipairs(positions) do
        local p = pos.p or pos
        if p.x and p.z then
            sumX = sumX + p.x
            sumY = sumY + (p.y or 0)
            sumZ = sumZ + p.z
            count = count + 1
        end
    end
    
    if count == 0 then
        return nil
    end
    
    return {
        x = sumX / count,
        y = sumY / count,
        z = sumZ / count
    }
end

--- Calculate center from a table of objects with .position fields
-- Works with any objects that have a .position property (threats, allies, units, etc.)
-- @param objects Table of objects where each has a .position field
-- @return table Center position {x, y, z}, or nil if no valid positions
function SpatialAgent.calculateCenterOfObjects(objects)
    if not objects then
        return nil
    end
    
    local positions = {}
    for _, obj in pairs(objects) do
        if obj.position then
            table.insert(positions, obj.position)
        end
    end
    
    return SpatialAgent.calculateCenter(positions)
end

--- Calculate center of threat positions (convenience wrapper)
-- @param threats Table of threats where each has a .position field
-- @return table Center position {x, y, z}, or nil if no threats
function SpatialAgent.calculateThreatCenter(threats)
    return SpatialAgent.calculateCenterOfObjects(threats)
end

-- ============================================================================
-- VECTOR OPERATIONS
-- ============================================================================

--- Normalize a 2D direction vector
-- @param dx X component
-- @param dz Z component
-- @return number, number Normalized dx, dz, or 0,0 if zero-length
function SpatialAgent.normalizeVector(vector)
    local magnitude = math.sqrt(vector.x * vector.x + vector.z * vector.z)
    
    if magnitude < 0.001 then  -- Near-zero length
        return {x = 0, z = 0}
    end
    
    return {x = vector.x / magnitude, z = vector.z / magnitude}
end

--- Rotate a 2D vector by angle
-- @param dx X component
-- @param dz Z component  
-- @param angleRadians Rotation angle in radians (positive = counterclockwise)
-- @return vector Rotated vector {x, z}
function SpatialAgent.rotateVector(vector, angleDegrees)
    local angleRadians = math.rad(angleDegrees)
    local cosAngle = math.cos(angleRadians)
    local sinAngle = math.sin(angleRadians)
    
    local rotatedX = vector.x * cosAngle - vector.z * sinAngle
    local rotatedZ = vector.x * sinAngle + vector.z * cosAngle
    
    return {x = rotatedX, z = rotatedZ}
end

--- Calculate direction vector from one position to another
-- @param fromPos Starting position
-- @param toPos Target position
-- @return direction Normalized direction vector {x, z}, or ZERO if positions identical
function SpatialAgent.calculateDirection(fromPos, toPos)
    local dist = SpatialAgent.distance2D(fromPos, toPos)
    if not dist or dist < 0.001 then
        return {x = 0, z = 0}
    end
    
    local p1 = fromPos.p or fromPos
    local p2 = toPos.p or toPos
    
    local dx = p2.x - p1.x
    local dz = p2.z - p1.z
    
    return SpatialAgent.normalizeVector({x = dx, z = dz})
end

-- ============================================================================
-- TACTICAL POSITIONING
-- ============================================================================

--- Calculate destination point from origin in a direction
-- @param origin Starting position {x, y, z}
-- @param direction Normalized direction {x, z}
-- @param distance Distance to travel in meters
-- @return table Destination position {x, y, z}
function SpatialAgent.calculateDestination(origin, direction, distance)
    if not origin then
        return nil
    end
    
    local p = origin.p or origin
    
    return {
        x = p.x + (direction.x * distance),
        y = p.y or 0,
        z = p.z + (direction.z * distance)
    }
end

--- Calculate multiple staging positions around a center point
-- Positions are spread in an arc or circle for tactical deployment
-- @param center Center position {x, y, z}
-- @param radius Distance from center in meters
-- @param count Number of positions to generate
-- @param spreadAngleDegrees Arc width in degrees (360 = full circle, 120 = front arc)
-- @return table Array of positions
function SpatialAgent.calculateArcPositions(center, radius, count, spreadAngleDegrees)
    if not center or count < 1 then
        return {}
    end
    
    local p = center.p or center
    local positions = {}
    
    -- Default to full circle if not specified
    local spreadRadians = math.rad(spreadAngleDegrees or 360)
    
    if count == 1 then
        -- Single position: place directly at radius
        table.insert(positions, {
            x = p.x + radius,
            y = p.y or 0,
            z = p.z
        })
        return positions
    end
    
    -- Multiple positions: spread evenly across arc
    local angleStep = spreadRadians / (count - 1)
    local startAngle = -spreadRadians / 2  -- Center the arc
    
    for i = 0, count - 1 do
        local angle = startAngle + (angleStep * i)
        table.insert(positions, {
            x = p.x + math.cos(angle) * radius,
            y = p.y or 0,
            z = p.z + math.sin(angle) * radius
        })
    end
    
    return positions
end

--- Calculate circular positions evenly distributed around a center
-- Simplified version of calculateStagingPositions for full 360° deployment
-- @param center Center position
-- @param radius Distance from center
-- @param count Number of positions
-- @return table Array of positions
function SpatialAgent.calculateCircularPositions(center, radius, count)
    return SpatialAgent.calculateArcPositions(center, radius, count, 360)
end

--- Calculate staging positions on allied side of threat
-- Creates an arc of positions oriented toward the threat from the allied approach direction
-- @param threatCenter Center of threat cluster
-- @param distance Staging distance from threat center
-- @param commanderPositions Array of commander positions (current locations)
-- @param spreadAngleDegrees Arc spread in degrees (default 120)
-- @return table Array of staging positions rotated to face threat from allied side
function SpatialAgent.calculateEncirclingPositions(threatCenter, distance, commanderPositions, spreadAngleDegrees)
    local numPositions = #commanderPositions
    
    if numPositions == 0 then
        return {}
    end
    
    -- Calculate centroid of allied positions
    local alliedCenterX = 0
    local alliedCenterZ = 0
    local validCount = 0
    
    for _, pos in ipairs(commanderPositions) do
        if pos then
            alliedCenterX = alliedCenterX + pos.x
            alliedCenterZ = alliedCenterZ + pos.z
            validCount = validCount + 1
        end
    end
    
    if validCount == 0 then
        return {}
    end
    
    alliedCenterX = alliedCenterX / validCount
    alliedCenterZ = alliedCenterZ / validCount
    
    -- Calculate approach angle from allied center to threat center
    local dx = threatCenter.x - alliedCenterX
    local dz = threatCenter.z - alliedCenterZ
    local approachAngle = math.atan2(dz, dx)
    
    -- Flip 180° to get angle for allied side (opposite approach direction)
    local centerAngle = approachAngle + math.pi
    
    -- Generate arc positions centered at 0°
    local arcPositions = SpatialAgent.calculateArcPositions(
        threatCenter, 
        distance, 
        numPositions, 
        spreadAngleDegrees or 120
    )
    
    -- Rotate positions so arc faces threat from allied side
    local rotatedPositions = {}
    for _, pos in ipairs(arcPositions) do
        -- Calculate relative position from threat center
        local relX = pos.x - threatCenter.x
        local relZ = pos.z - threatCenter.z
        
        -- Rotate by centerAngle
        local rotatedX = relX * math.cos(centerAngle) - relZ * math.sin(centerAngle)
        local rotatedZ = relX * math.sin(centerAngle) + relZ * math.cos(centerAngle)
        
        table.insert(rotatedPositions, {
            x = threatCenter.x + rotatedX,
            y = threatCenter.y or 0,
            z = threatCenter.z + rotatedZ
        })
    end
    
    return rotatedPositions
end

-- ============================================================================
-- SORTING AND GROUPING
-- ============================================================================

--- Sort positions by distance from a reference point
-- @param positions Array of position tables
-- @param referencePoint Reference position to measure from
-- @return table Sorted array of {position, distance} tables
function SpatialAgent.sortByDistance(positions, referencePoint)
    if not positions or not referencePoint then
        return {}
    end
    
    local positionsWithDistance = {}
    
    for _, pos in ipairs(positions) do
        local dist = SpatialAgent.distance2D(pos, referencePoint)
        if dist then
            table.insert(positionsWithDistance, {
                position = pos,
                distance = dist
            })
        end
    end
    
    table.sort(positionsWithDistance, function(a, b)
        return a.distance < b.distance
    end)

    return positionsWithDistance
end

--- Match items to positions minimizing overall travel via greedy nearest-pair assignment
-- Repeatedly picks the closest unmatched (item, position) pair until all items are matched.
-- Not globally optimal, but avoids the "stuck with the distant leftover" problem of
-- assigning by index order, and stays cheap for the small counts (~3) commanders use.
-- @param items Array of objects with a .position field
-- @param positions Array of position tables (same length as items, or longer)
-- @return table Array of {item = ..., position = ..., index = originalPositionIndex}, in item order
function SpatialAgent.assignByProximity(items, positions)
    if not items or not positions then
        return {}
    end

    local candidates = {}
    for itemIdx, item in ipairs(items) do
        local pos = item.position
        if pos then
            for posIdx, position in ipairs(positions) do
                local dist = SpatialAgent.distance2D(pos, position)
                if dist then
                    table.insert(candidates, {
                        itemIdx = itemIdx,
                        posIdx  = posIdx,
                        distance = dist,
                    })
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        return a.distance < b.distance
    end)

    local assignments = {}
    local itemTaken = {}
    local posTaken = {}
    local remaining = #items

    for _, candidate in ipairs(candidates) do
        if remaining == 0 then
            break
        end
        if not itemTaken[candidate.itemIdx] and not posTaken[candidate.posIdx] then
            itemTaken[candidate.itemIdx] = true
            posTaken[candidate.posIdx] = true
            assignments[candidate.itemIdx] = {
                item     = items[candidate.itemIdx],
                position = positions[candidate.posIdx],
                index    = candidate.posIdx,
            }
            remaining = remaining - 1
        end
    end

    local result = {}
    for itemIdx = 1, #items do
        if assignments[itemIdx] then
            table.insert(result, assignments[itemIdx])
        end
    end

    return result
end

return SpatialAgent

end)
__bundle_register("doctrine", function(require, _LOADED, __bundle_register, __bundle_modules)
-- Doctrine: Pluggable decision strategy for OODACommanders
-- Receives context from ORIENT phase, returns decisions for ACT phase
-- Works at any command level (operational, tactical, individual)

local Doctrine = {}
Doctrine.__index = Doctrine

-- Factory method for creating new Doctrine instances
function Doctrine.new(name, commanderName)
    local self = setmetatable({}, Doctrine)
    
    self.name = name or "UnnamedPlan"
    self.commanderName = commanderName or "UnknownCommander"
    
    -- State tracking
    self.currentPhaseName = nil
    self.phaseHistory = {}
    self.phases = {}
    self.state = {}
    self.phaseBaseline = { completed = 0, aborted = 0, total = 0 }

    return self
end

-- Main planning method - subclasses must implement
-- @param context snapshot table (TacticalContext or ObjectiveContext)
-- @return decisions table (structure varies by commander type)
--   Operational doctrines return { orders = { ... }, objectiveComplete = true/nil }.
function Doctrine:plan(context)
    env.info(self.commanderName .. " " .. self.name .. " executing phase " .. tostring(self.currentPhaseName))
    return self.phases[self.currentPhaseName](self, context)
end

function Doctrine:registerPhase(phaseName, planningFunction)
    if not self.currentPhaseName then
        self.currentPhaseName = phaseName
    end
    self.phases[phaseName] = planningFunction
end

function Doctrine:changePhase(phaseName, statusCounts)
    if self.currentPhaseName then
        table.insert(self.phaseHistory, {
            name = self.currentPhaseName,
            changedAt = timer.getTime()
        })
    end
    env.info(self.commanderName .. " " .. self.name .. " changing to phase " .. phaseName)
    self.currentPhaseName = phaseName
    if statusCounts then
        self.phaseBaseline = {
            completed = statusCounts.completed or 0,
            aborted   = statusCounts.aborted   or 0,
            total     = statusCounts.total     or 0,
        }
    else
        self.phaseBaseline = { completed = 0, aborted = 0, total = 0 }
    end
end

return Doctrine

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
local garrisonTemplates = { --static objects
    red = {"Ural-375"}, --category "Unarmed" {"KAMAZ Truck", "KAMAZ Truck"}, -- {"Ural-375", "Ural-375", "GAZ-66"},
    blue = {"M 818"}, --category "Unarmed" --{"M 818", "M 818"},
}
local groundTemplates = { --frontline, rear, farp
    red = {
        -- {"KAMAZ Truck", "KAMAZ Truck", "KAMAZ Truck", "KAMAZ Truck"},
        -- {"MTLB", "Ural-375", "Ural-375", "GAZ-66"},
        -- {"BTR-80", "KAMAZ Truck", "KAMAZ Truck", "GAZ-66"},
        -- {"BMP-2", "BTR-80", "MTLB", "GAZ-66"},
        {"BRDM-2", "BRDM-2", "BRDM-2"},
        {"BTR-80", "BTR-80", "BTR-80", "BTR-80"},
        {"BMP-2", "BMP-2", "BTR-80", "BTR-80"},
        {"T-72B", "T-72B", "BTR-60"}
    },
    blue = {
        -- {"Hummer", "M 818", "M 818", "M 818"},
        -- {"M-113", "Hummer", "M 818", "M 818"},
        {"M1045 HMMWV TOW",  "M1043 HMMWV Armament",  "M1043 HMMWV Armament"},
        {"M-113", "M-113", "M1043 HMMWV Armament",  "M1043 HMMWV Armament"},
        {"M-2 Bradley", "M-2 Bradley", "M1043 HMMWV Armament", "M1043 HMMWV Armament"},
        {"M-1 Abrams", "M-1 Abrams", "M-113"}
    }
}

local taskTypes = {
    DEFEND = 1,
    REINFORCE = 2,
    RECON = 3,
    ASSAULT = 4,
    RALLY = 5,
    INDIRECT = 6,
    AA = 7,
    REPOSITION = 8,
    PATROL = 9,
}

local threatStatus = {
    OBSERVED = "Observed",      -- Currently in LOS
    SUSPECTED = "Suspected",    -- Not currently visible but believed present
    UNCONFIRMED = "Unconfirmed", -- Position checked, not found
    LOST = "Lost",              -- Unconfirmed for >5 minutes, presumed gone
    ELIMINATED = "Eliminated"   -- Confirmed destroyed (BDA)
}

local statusTypes = {
    HOLD = 1,
    EN_ROUTE = 2,
}

local orderStatus = {
    ASSIGNED = "Assigned",       -- Order received, not yet acted upon
    IN_PROGRESS = "In Progress", -- Actively executing order
    COMPLETED = "Completed",     -- Successfully completed or deadline reached
    ABORTED = "Aborted",        -- Mission no longer possible or canceled
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
    -- Infantry units (foot soldiers)
    ["Soldier M4"] = {category = "infantry", threats = {infantry = 2, ["light-armor"] = 0.5, ["heavy-armor"] = 0, support = 0.5}},
    ["Soldier M249"] = {category = "infantry", threats = {infantry = 3, ["light-armor"] = 0.5, ["heavy-armor"] = 0, support = 0.5}},
    ["Infantry AK"] = {category = "infantry", threats = {infantry = 2, ["light-armor"] = 0.5, ["heavy-armor"] = 0, support = 0.5}},
    ["Paratrooper RPG-16"] = {category = "infantry", threats = {infantry = 1.5, ["light-armor"] = 6, ["heavy-armor"] = 4, support = 3}},
    
    -- Soft-skinned vehicles (unarmored trucks, transport)
    ["Hummer"] = {category = "infantry", threats = {infantry = 1, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 0}},
    ["GAZ-66"] = {category = "infantry", threats = {infantry = 1, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 0}},
    ["UAZ-469"] = {category = "infantry", threats = {infantry = 0.5, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 0}},
    ["M 818"] = {category = "infantry", threats = {infantry = 0.5, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 0}},
    ["KAMAZ Truck"] = {category = "infantry", threats = {infantry = 0.5, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 0}},
    ["Kamaz 43101"] = {category = "infantry", threats = {infantry = 0.5, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 0}},
    ["Ural-375"] = {category = "infantry", threats = {infantry = 0.5, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 0}},
    ["Ural-4320-31"] = {category = "infantry", threats = {infantry = 0.5, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 0}},
    ["Ural-4320T"] = {category = "infantry", threats = {infantry = 0.5, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 0}},
    
    -- Scout vehicles (armed soft-skinned)
    ["M1043 HMMWV Armament"] = {category = "infantry", threats = {infantry = 4, ["light-armor"] = 2, ["heavy-armor"] = 0, support = 2}},
    ["M1045 HMMWV TOW"] = {category = "infantry", threats = {infantry = 2, ["light-armor"] = 7, ["heavy-armor"] = 6, support = 4}},
    ["BRDM-2"] = {category = "infantry", threats = {infantry = 3, ["light-armor"] = 2, ["heavy-armor"] = 0, support = 2}},
    ["Tigr_233036"] = {category = "infantry", threats = {infantry = 3, ["light-armor"] = 1, ["heavy-armor"] = 0, support = 1}},
    
    -- Light armor (APCs, IFVs)
    ["M-113"] = {category = "light-armor", threats = {infantry = 3, ["light-armor"] = 1, ["heavy-armor"] = 0, support = 1}},
    ["BMD-1"] = {category = "light-armor", threats = {infantry = 5, ["light-armor"] = 4, ["heavy-armor"] = 2, support = 3}},
    ["M-2 Bradley"] = {category = "light-armor", threats = {infantry = 6, ["light-armor"] = 5, ["heavy-armor"] = 3, support = 4}},
    ["BMP-2"] = {category = "light-armor", threats = {infantry = 6, ["light-armor"] = 5, ["heavy-armor"] = 2, support = 4}},
    ["BMP-3"] = {category = "light-armor", threats = {infantry = 6, ["light-armor"] = 5, ["heavy-armor"] = 3, support = 4}},
    ["BTR-60"] = {category = "light-armor", threats = {infantry = 4, ["light-armor"] = 2, ["heavy-armor"] = 0, support = 2}},
    ["BTR-80"] = {category = "light-armor", threats = {infantry = 4, ["light-armor"] = 2, ["heavy-armor"] = 0, support = 2}},
    
    -- Heavy armor (MBTs)
    ["M-1 Abrams"] = {category = "heavy-armor", threats = {infantry = 4, ["light-armor"] = 8, ["heavy-armor"] = 8, support = 7}},
    ["T-72B"] = {category = "heavy-armor", threats = {infantry = 4, ["light-armor"] = 8, ["heavy-armor"] = 7, support = 7}},
    ["T-80U"] = {category = "heavy-armor", threats = {infantry = 4, ["light-armor"] = 8, ["heavy-armor"] = 7.5, support = 7}},
    
    -- Support units (AA systems)
    ["Avenger"] = {category = "support", threats = {infantry = 1, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 1}},
    ["Vulcan"] = {category = "support", threats = {infantry = 3, ["light-armor"] = 1, ["heavy-armor"] = 0, support = 2}},
    ["Strela-10M3"] = {category = "support", threats = {infantry = 0, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 1}},
    ["Strela-1 9P31"] = {category = "support", threats = {infantry = 0, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 1}},
    
    -- Support units (Artillery)
    ["M-109"] = {category = "support", threats = {infantry = 8, ["light-armor"] = 6, ["heavy-armor"] = 4, support = 5}},
    ["2S9 Nona"] = {category = "support", threats = {infantry = 7, ["light-armor"] = 5, ["heavy-armor"] = 3, support = 4}},
}

return {
    acceptableLevelsOfRisk = acceptableLevelsOfRisk,
    dispositionTypes = dispositionTypes,
    formationTypes = formationTypes,
    garrisonTemplates = garrisonTemplates,
    groundTemplates = groundTemplates,
    orderStatus = orderStatus,
    rulesOfEngagement = rulesOfEngagement,
    oodaStates = oodaStates,
    rgb = rgb,
    taskTypes = taskTypes,
    threatStatus = threatStatus,
    statusTypes = statusTypes,
    unitClassification = unitClassification
}

end)
__bundle_register("order", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local orderStatus = constants.orderStatus

-- Order class for tracking individual group orders issued by Strategic Commander
-- Each order is assigned to a specific group and references its parent objective

local Order = {}
Order.__index = Order

function Order.new(config)
    local self = setmetatable({}, Order)
    
    -- Required fields
    self.assignedTo = config.assignedTo  -- groupName string
    self.objective = config.objective     -- reference to parent Objective
    self.position = config.position       -- {x, z}
    self.type = config.type               -- taskTypes constant
    
    -- Optional fields with defaults
    self.alr = config.alr or constants.acceptableLevelsOfRisk.MEDIUM
    self.radius = config.radius or 500
    self.deadline = config.deadline       -- nil or timer.getTime() + duration
    self.pushTime = config.pushTime       -- nil or timer.getTime() + calculated rally duration
    self.missionProfile = config.missionProfile or nil
    
    -- Status tracking (set by GroupCommander)
    self.status = orderStatus.ASSIGNED
    self.assignedAt = timer.getTime()
    self.startedAt = nil
    self.completedAt = nil
    self.abortReason = nil
    
    return self
end

-- Get a summary of order state for reporting
function Order:getSummary()
    return {
        assignedTo = self.assignedTo,
        status = self.status,
        type = self.type,
        position = self.position,
        assignedAt = self.assignedAt,
        startedAt = self.startedAt,
        completedAt = self.completedAt,
        abortReason = self.abortReason,
        timeSinceAssigned = timer.getTime() - self.assignedAt,
    }
end

-- Check if order is still active (not completed or aborted)
function Order:isActive()
    return self.status == orderStatus.ASSIGNED or 
           self.status == orderStatus.IN_PROGRESS
end

-- Check if order is finished (completed or aborted)
function Order:isFinished()
    return self.status == orderStatus.COMPLETED or 
           self.status == orderStatus.ABORTED
end

-- Mark order as started (transition from ASSIGNED to IN_PROGRESS)
function Order:start()
    if self.status == orderStatus.ASSIGNED then
        self.status = orderStatus.IN_PROGRESS
        self.startedAt = timer.getTime()
    end
end

-- Mark order as completed
function Order:complete()
    if self:isActive() then
        self.status = orderStatus.COMPLETED
        self.completedAt = timer.getTime()
    end
end

-- Mark order as aborted with reason
function Order:abort(reason)
    if self:isActive() then
        self.status = orderStatus.ABORTED
        self.abortReason = reason
        self.completedAt = timer.getTime()
    end
end

-- Check if order deadline has expired
function Order:isExpired()
    if self.deadline then
        return timer.getTime() >= self.deadline
    end
    return false
end

return Order

end)
__bundle_register("group-commander", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local DefensiveDoctrine = require("doctrines.tactical.defensive-doctrine")
local ForceStatusAnalyzer = require("force-status-analyzer")
local GroupProfiler = require("group-profiler")
local OODACommander = require("ooda-commander")
local AsOrderedDoctrine = require("doctrines.tactical.as-ordered-doctrine")
local AssaultDoctrine = require("doctrines.tactical.assault-doctrine")
local PatrolDoctrine = require("doctrines.tactical.patrol-doctrine")
local ReconDoctrine = require("doctrines.tactical.recon-doctrine")
local RallyDoctrine = require("doctrines.tactical.rally-doctrine")
local SpatialAgent = require("spatial-agent")
local ThreatDetector = require("threat-detector")
local ThreatTracker = require("threat-tracker")
local alr = constants.acceptableLevelsOfRisk
local dispositionTypes = constants.dispositionTypes
local formationTypes = constants.formationTypes
local orderStatus = constants.orderStatus
local roe = constants.rulesOfEngagement
local taskTypes = constants.taskTypes
local GroupCommander = {}

setmetatable(GroupCommander, {__index = OODACommander})
GroupCommander.__index = GroupCommander
GroupCommander.instances = {}

local oodaInterval = 10.0 -- seconds
local detectionRadius = 8000 -- meters

function GroupCommander.new(groupName, config)
    -- Initialize parent class (sets up OODA loop scheduling)
    local self = OODACommander.new({interval = oodaInterval})
    setmetatable(self, GroupCommander)
    
    -- GroupCommander-specific initialization
    self.alr = alr.LOW
    self.coalition = config.color
    self.color = config.color
    self.destination = nil
    self.disposition = dispositionTypes.HOLD
    self.formationType = formationTypes.OFF_ROAD
    self.groupName = groupName
    self.initialUnitNames = self:getOwnUnitNames()
    self.initialCollectiveStatus = self:getCollectiveStatus()
    
    -- Capture initial ammo count for percentage-based low ammo thresholds
    local initialStatus = self:getStatusReport()
    self.initialAmmoCount = initialStatus.ammoCount
    
    self.orders = nil
    self.lastMoveOrder = nil
    self.pendingOrderAction = nil
    self.groupProfile = nil
    self.suitability = nil
    self.ownForceStrength = nil
    self.roe = roe.WEAPON_HOLD
    self.threatTracker = ThreatTracker.new(groupName)
    self.threatAnalysis = nil
    self.lastThreatCenter = nil
    self.allyIntel = nil  -- Nearby ally strength info from OpsCom
    self.destroyed = false  -- Tracks if group no longer exists
    self.visualizer = config.visualizer
    
    -- Simulated fuel tracking (DCS doesn't model fuel for ground units)
    self.fuelRemaining = 1.0  -- Start at 100%
    self.lastPosition = nil
    self.lastObserveTime = timer.getTime()
    
    -- Active Doctrine (persists across OODA cycles until a new order is assigned)
    -- Default to groups defending their current position until tasked to an opscom
    self.doctrine = DefensiveDoctrine.new(self.groupName)
    self.doctrineOrder = nil
    
    -- Register this instance
    table.insert(GroupCommander.instances, self)
    
    return self
end

function GroupCommander.getInstances(coalition)
    if not coalition then
        return GroupCommander.instances
    end
    
    local filtered = {}
    for _, instance in ipairs(GroupCommander.instances) do
        if instance.coalition == coalition then
            table.insert(filtered, instance)
        end
    end
    return filtered
end

function GroupCommander:observe()
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        -- Mark as destroyed (oodaTick will handle cancellation)
        self.destroyed = true
        self.lastObserveTime = timer.getTime()
        env.info(self.groupName .. " destroyed - marking for cleanup")
        return
    end
    
    -- Update simulated fuel consumption
    local currentTime = timer.getTime()
    local currentPos = self:getOwnPosition()

    -- Only update position/time if we have a valid currentPos
    if currentPos then
        self:updateFuelConsumption(currentTime, currentPos)
        self.lastPosition = currentPos
        self.lastObserveTime = currentTime
    end
    
    -- Use ThreatDetector to get visible threats
    local detected = ThreatDetector.detectUnits(
        ThreatDetector.getUnitsFromGroups({group}),
        detectionRadius,
        self.coalition,  -- "red" or "blue"
        2,  -- Observer altitude offset
        2   -- Target altitude offset
    )
    
    local visibleThreatNames = {}
    for _, unit in ipairs(detected.enemy) do
        table.insert(visibleThreatNames, unit:getName())
    end
    
    -- Build observed unit data for threats we can see (no unit refs stored)
    local observedThreats = {}
    for _, unitName in ipairs(visibleThreatNames) do
        local unit = Unit.getByName(unitName)
        -- Only add if unit exists (error guard, not intel cheat)
        if unit and unit:isExist() then
            table.insert(observedThreats, {
                name = unitName,
                position = unit:getPosition().p
            })
        end
    end
    
    -- Update threat table with newly observed threats (keeping old ones)
    self.threatTracker:updateThreats(observedThreats)
    self.threatTracker:updateExpectedThreats(observedThreats, currentPos, detectionRadius)
    
    -- Age threats and progress their status
    self.threatTracker:ageThreats()
    
    -- Store direct LOS count for decision-making (to distinguish self-observed from shared intel)
    self.directLOSCount = #visibleThreatNames
    
    -- Single consolidated OBSERVE summary
    local memoryCount = self.threatTracker:count()
    local expectedCount = #self.threatTracker:expectedThreats(currentPos, detectionRadius)
    local expectedStr = expectedCount > 0 and (" Exp:" .. expectedCount) or ""
    env.info("* " .. self.groupName .. " OBSERVE: LOS:" .. #visibleThreatNames .. expectedStr .. " Mem:" .. memoryCount)
end

function GroupCommander:orient()
    -- Gather situational awareness for decision making
    self.ownForceStrength = self:analyzeOwnForce()

    self.threatAssessment = self:assessThreats()

    -- Derive group profile
    local ownPos = self:getOwnPosition()
    self.groupProfile = GroupProfiler.profileGroup(self.groupName, self.initialUnitNames, self.initialAmmoCount, self.fuelRemaining)

    -- Update suitability against current order's mission profile
    if self.orders and self.orders.missionProfile then
        self.suitability = self:getSuitability(self.orders.missionProfile)
    else
        self.suitability = nil
    end
end

--- @class TacticalContext
--- @field groupName string
--- @field ownPosition table
--- @field totalUnits number
--- @field initialAmmoCount number
--- @field threatAssessment table
--- @field statusReport table
--- @field suitability number|nil
--- @field hasActiveOrders boolean
--- @field orderType string|nil
--- @field orderPosition table|nil
--- @field orderProximity number|nil
--- @field orderAlr string|nil
--- @field distanceToOrdered number|nil
--- @field withinObjective boolean|nil
--- @field retreatThreshold number|nil
--- @field orderIsExpired boolean|nil
--- @field orderHasDeadline boolean|nil
--- @return TacticalContext|nil
function GroupCommander:buildDecisionContext()
    local ownPosition = self:getOwnPosition()
    if not ownPosition then return nil end

    local hasActiveOrders = self.orders ~= nil and self.orders:isActive()

    local orderType, orderPosition, orderProximity, orderAlr
    local distanceToOrdered, withinObjective, retreatThreshold
    local orderIsExpired, orderHasDeadline

    if hasActiveOrders then
        orderType     = self.orders.type
        orderPosition = self.orders.position
        orderProximity   = self.orders.proximity or 500
        orderAlr      = self.orders.alr or alr.LOW

        distanceToOrdered = SpatialAgent.distance2D(ownPosition, orderPosition)
        withinObjective   = distanceToOrdered <= orderProximity

        retreatThreshold = 0.4
        if orderAlr == alr.LOW then
            retreatThreshold = 0.2
        elseif orderAlr == alr.HIGH then
            retreatThreshold = 0.8
        end

        orderHasDeadline = self.orders.expirationTime ~= nil
        orderIsExpired   = self.orders:isExpired() or false
    end

    return {
        groupName        = self.groupName,
        ownPosition      = ownPosition,
        totalUnits       = #self.initialUnitNames,
        initialAmmoCount = self.initialAmmoCount,
        threatAssessment = self.threatAssessment,
        statusReport     = self:getStatusReport(),
        suitability      = self.suitability,
        hasActiveOrders  = hasActiveOrders or false,
        orderType        = orderType,
        orderPosition    = orderPosition,
        orderProximity   = orderProximity,
        orderAlr         = orderAlr,
        distanceToOrdered = distanceToOrdered,
        withinObjective  = withinObjective,
        retreatThreshold = retreatThreshold,
        orderIsExpired   = orderIsExpired,
        orderHasDeadline = orderHasDeadline,
    }
end

function GroupCommander:decide()
    -- If an order resolved (completed/aborted) last tick via act(),
    -- doctrine instance may still be awaiting reassignment by the operational layer.
    -- In this case hold in place rather than planning against a finished order's stale context
    -- (e.g. orderPosition is no longer populated).
    if self.orders and self.orders:isFinished() then
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = self:getOwnPosition()
        self.pendingOrderAction = nil
        return
    end

    -- Build a fresh doctrine only when a genuinely new order has been assigned
    -- (identity check, not status) so in-progress phase state isn't discarded
    -- while a doctrine is still working an order that hasn't called orderAction "start" yet.
    if self.orders and self.orders ~= self.doctrineOrder then
        self.doctrineOrder = self.orders
        if self.orders.type == taskTypes.PATROL then
            self.doctrine = PatrolDoctrine.new(self.groupName)
        elseif self.orders.type == taskTypes.RECON then
            self.doctrine = ReconDoctrine.new(self.groupName)
        elseif self.orders.type == taskTypes.RALLY then
            self.doctrine = RallyDoctrine.new(self.groupName)
        elseif self.orders.type == taskTypes.ASSAULT then
            self.doctrine = AssaultDoctrine.new(self.groupName)
        elseif self.orders.type == taskTypes.DEFEND then
            self.doctrine = DefensiveDoctrine.new(self.groupName)
        else
            self.doctrine = AsOrderedDoctrine.new(self.groupName)
        end
    end

    -- TODO decide if it makes sense to reenable this compared to first block above
    -- // it would be one way of tying up residual orders after opscom disbands
    -- if self.orders and self.orders:isFinished() then
    --     self.orders = nil
    --     self.doctrine = DefensiveDoctrine.new(self.groupName)
    -- end

    -- if not self.doctrine then
    --     self.doctrine = DefensiveDoctrine.new(self.groupName)
    -- end

    -- Check if we have valid assessment data
    if not self.ownForceStrength or not self.threatAssessment then
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = self:getOwnPosition()
        return
    end

    -- Build decision context snapshot
    local context = self:buildDecisionContext()
    if not context then
        env.info("ERROR: Could not build tactical context for " .. self.groupName)
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = self:getOwnPosition()
        return
    end
        
    -- Use Doctrine to make tactical decisions
    if not self.doctrine then return end
    local decision = self.doctrine:plan(context)
    if decision then
        self:setDisposition(decision.disposition)
        self.destination = decision.destination
        self.pendingOrderAction = decision.orderAction
    else
        env.info("ERROR: Doctrine returned nil decision for " .. self.groupName)
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = self:getOwnPosition()
        self.pendingOrderAction = nil
    end
end

function GroupCommander:act()
    -- Set ROE based on disposition
    if self.disposition == dispositionTypes.ADVANCE then
        self:setROE(roe.WEAPON_FREE)
    elseif self.disposition == dispositionTypes.RETREAT then
        self:setROE(roe.RETURN_FIRE)
    elseif self.disposition == dispositionTypes.HOLD then
        self:setROE(roe.WEAPON_FREE)
    elseif self.disposition == dispositionTypes.DEFEND then
        self:setROE(roe.WEAPON_FREE)
    else
        self:setROE(roe.WEAPON_HOLD)
    end
    
    -- Apply order lifecycle action returned by Doctrine
    if self.pendingOrderAction and self.orders then
        if self.pendingOrderAction == "start" then
            self.orders:start()
        elseif self.pendingOrderAction == "complete" then
            self.orders:complete()
        elseif self.pendingOrderAction == "abort" then
            self.orders:abort("doctrine_abort")
        end
        self.pendingOrderAction = nil
    end

    -- Only issue move orders for ADVANCE and RETREAT (not HOLD or DEFEND)
    -- If destination has been set to nil, stop the group where they are
    if self.destination then
        if (self.disposition == dispositionTypes.ADVANCE or self.disposition == dispositionTypes.RETREAT) then
            -- Only issue if destination has changed (more than 100m tolerance)
            if not self.lastMoveOrder or 
            math.abs(self.lastMoveOrder.x - self.destination.x) > 100 or 
            math.abs(self.lastMoveOrder.z - self.destination.z) > 100 then
                self:issueMoveOrder(self.destination)
                self.lastMoveOrder = {x = self.destination.x, z = self.destination.z}
                if self.visualizer then
                    self.visualizer:appendGroupMove(self, self.color)
                end
            end
        else
            self:stopMovement()
        end
    else
        self:stopMovement()
    end

    if self.visualizer then
        self.visualizer:syncGroupOrder(self, self.color)
    end
end

function GroupCommander:analyzeOwnForce()
    return GroupProfiler.profileUnits(self:getOwnUnits())
end

function GroupCommander:analyzeThreatCapabilities()
    local threats = self.threatTracker:getRecentThreats()
    local threatUnits = {}
    for unitName, _ in pairs(threats) do
        local unit = Unit.getByName(unitName)
        if unit and unit:isExist() then
            table.insert(threatUnits, unit)
        end
    end
    return GroupProfiler.profileUnits(threatUnits)
end

-- Assess threat situation including staleness, center of mass, and comparative strength
function GroupCommander:assessThreats()
    local threatAnalysis = self:analyzeThreatCapabilities()

    -- Calculate threat center if threats exist
    local threatCenter = nil
    local recentThreats = self.threatTracker:getRecentThreats()
    if threatAnalysis.unitCount > 0 then
        threatCenter = SpatialAgent.calculateCenterOfObjects(recentThreats)
    end

    -- Combine own force with ally intel for favorability calculation
    local combinedForce = self.ownForceStrength
    if self.allyIntel and self.allyIntel.unitCount and self.allyIntel.unitCount > 0 then
        combinedForce = {
            unitCount = self.ownForceStrength.unitCount + self.allyIntel.unitCount,
            offensiveCapability = {
                vsInfantry = self.ownForceStrength.offensiveCapability.vsInfantry + self.allyIntel.offensiveCapability.vsInfantry,
                vsArmor    = self.ownForceStrength.offensiveCapability.vsArmor    + self.allyIntel.offensiveCapability.vsArmor,
                vsAir      = self.ownForceStrength.offensiveCapability.vsAir      + self.allyIntel.offensiveCapability.vsAir,
            },
            composition = {
                infantry   = self.ownForceStrength.composition.infantry   + self.allyIntel.composition.infantry,
                lightArmor = self.ownForceStrength.composition.lightArmor + self.allyIntel.composition.lightArmor,
                heavyArmor = self.ownForceStrength.composition.heavyArmor + self.allyIntel.composition.heavyArmor,
                support    = self.ownForceStrength.composition.support    + self.allyIntel.composition.support,
            },
        }
    end

    local favorability = GroupProfiler.calculateFavorability(combinedForce, threatAnalysis)

    return {
        count        = threatAnalysis.unitCount,
        analysis     = threatAnalysis,
        center       = threatCenter,
        favorability = favorability,
    }
end

function GroupCommander:getSuitability(missionProfile)
    if not missionProfile then return 1.0 end
    local profile = self.groupProfile
    if not profile then return 0.0 end

    -- Proximity score: 1.0 = perfect match, approaches 0 as difference grows.
    -- Handles unbounded capability values (which are summed across unit count).
    local function proximity(actual, ideal)
        return 1 / (1 + math.abs((actual or 0) - ideal))
    end

    local score = 0.0
    local count = 0

    if missionProfile.offensiveCapability then
        local idealCap = missionProfile.offensiveCapability
        local ownCap   = profile.offensiveCapability
        for _, field in ipairs({"vsInfantry", "vsArmor", "vsAir"}) do
            if idealCap[field] ~= nil then
                score = score + proximity(ownCap[field], idealCap[field])
                count = count + 1
            end
        end
    end

    if missionProfile.attritionRate ~= nil then
        score = score + proximity(profile.attritionRate, missionProfile.attritionRate)
        count = count + 1
    end

    if missionProfile.ammoRatio ~= nil then
        score = score + proximity(profile.ammoRatio, missionProfile.ammoRatio)
        count = count + 1
    end

    if count == 0 then return 1.0 end
    return score / count
end

-- Static: remove destroyed instances from the global instances list
function GroupCommander.removeDestroyed()
    local surviving = {}
    local removed = 0
    for _, instance in ipairs(GroupCommander.instances) do
        if not instance.destroyed then
            table.insert(surviving, instance)
        else
            removed = removed + 1
            env.info(string.format("* GroupCommander: Removing destroyed group %s from memory",
                instance.groupName or "unknown"))
        end
    end
    if removed > 0 then
        GroupCommander.instances = surviving
    end
end

function GroupCommander:getStatusReport()
    return ForceStatusAnalyzer.getStatusReport(self.groupName, self.initialUnitNames, self.fuelRemaining)
end

function GroupCommander:getCriticalStatus()
    return ForceStatusAnalyzer.getCriticalStatusReport(self.groupName, self.initialUnitNames, self.fuelRemaining)
end

function GroupCommander:getCollectiveStatus()
    local statusReport = self:getStatusReport()
    return ForceStatusAnalyzer.getCollectiveStatusFromReport(statusReport, #self.initialUnitNames)
end

function GroupCommander:getDestinationToObjective(objectivePosition, objectiveRadius)
    -- Check if we're within objective radius. If so, return nil (stay put).
    -- If not, return the objective position to move toward.
    local ownPos = self:getOwnPosition()
    if not ownPos then
        return objectivePosition  -- Can't determine position, default to moving
    end
    
    if SpatialAgent.isWithinRadius(ownPos, objectivePosition, objectiveRadius) then
        return nil  -- Within radius, stay put
    else
        return objectivePosition  -- Outside radius, move to objective
    end
end

function GroupCommander:getOwnPosition()
    local units = self:getOwnUnits()
    local positions = {}
    for _, unit in ipairs(units) do
        local pos = unit:getPosition().p
        table.insert(positions, pos)
    end
    return SpatialAgent.calculateCenter(positions)
end

function GroupCommander:getOwnUnits()
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        return {}
    end
    
    local units = group:getUnits()
    local validUnits = {}
    for _, unit in ipairs(units) do
        if unit and unit:isExist() then
            table.insert(validUnits, unit)
        end
    end
    return validUnits
end

function GroupCommander:getOwnUnitNames()
    local units = self:getOwnUnits()
    local unitNames = {}
    for _, unit in ipairs(units) do
        table.insert(unitNames, unit:getName())
    end
    return unitNames
end

function GroupCommander:getStatus()
    local collectiveStatus = self:getCollectiveStatus()

    local status = {
        destination = self.destination,
        disposition = self.disposition,
        groupName = self.groupName,
        orderStatus = self.orders and self.orders.status or nil,
        position = self:getOwnPosition(),
        status = collectiveStatus,
        threats = self.threatTracker:getRecentThreats(),
    }
    return status
end

function GroupCommander:getSlowestUnitSpeed()
    local units = self:getOwnUnits()
    local slowestSpeed = nil
    for _, unit in ipairs(units) do
        local speed = unit:getDesc().speedMax
        if not slowestSpeed or speed < slowestSpeed then
            slowestSpeed = speed
        end
    end
    return slowestSpeed or 0
end

-- HELPER METHODS

function GroupCommander:issueMoveOrder(point)
    -- Validate point parameter
    if not point or not point.x or not point.z then
        env.info("ERROR: " .. self.groupName .. " received invalid move order (nil or invalid point)")
        return
    end
    
    -- Convert x/z to lat/lon for logging
    local lat, lon = coord.LOtoLL({x = point.x, y = 0, z = point.z})
    env.info("* " .. self.groupName .. " DECIDE: Move to " .. string.format("%.5f", lat or 0) .. "," .. string.format("%.5f", lon or 0))
    
    -- Verify group exists
    local group = Group.getByName(self.groupName)
    if not group then
        env.info("ERROR: Group " .. self.groupName .. " does not exist!")
        return
    end
    
    if not group:isExist() then
        env.info("ERROR: Group " .. self.groupName .. " is not alive!")
        return
    end
    
    -- Ensure point has y coordinate for MIST
    if not point.y then
        point = {
            x = point.x,
            y = land.getHeight({x = point.x, y = point.z}),
            z = point.z
        }
    end
    
    -- Calculate distance to destination first (needed for road logic)
    local distance = nil
    local ownPos = self:getOwnPosition()
    if ownPos then
        distance = SpatialAgent.distance2D(point, ownPos)
    end
    
    -- Decide whether to use roads based on situation and distance
    -- Default to ignoring roads since DCS pathfinding is often problematic
    local ignoreRoads = true
    
    -- TODO use 'crosscountry' boolean in precalculated control zone edge table to help decide
    -- Only use roads for long-distance movements (>15km) when not in combat
    if distance and distance > 15000 and self.disposition ~= dispositionTypes.RETREAT then
        ignoreRoads = false
    end
    
    -- Set destination radius based on whether using roads
    -- Per MIST docs: roads are auto-used if distance > 1.3 * radius
    -- So we need larger radius to prevent roads being used at medium ranges
    local destRadius = 100
    if not ignoreRoads and distance then
        -- For road movements, use larger radius (10% of distance, max 500m)
        destRadius = math.min(500, distance * 0.1)
    end
    
    local destination = {
        point = point,
        radius = destRadius
    }
    local formation = "Cone"
    local heading = 0
    local speed = 100
        
    mist.groupToPoint(
        self.groupName,
        destination,
        formation,
        heading,
        speed,
        true
    )
end

function GroupCommander:issueOrder(order)
    -- Set initial status if not provided
    if not order.status then
        order.status = orderStatus.ASSIGNED
        order.assignedAt = timer.getTime()
    end
    self.orders = order
end

function GroupCommander:updateThreatIntel(threatIntel)
    -- Receive threat intel from operational commander
    self.threatTracker:mergeThreatIntel(threatIntel)
end

function GroupCommander:updateAllyIntel(allyIntel)
    -- Receive nearby ally strength info from operational commander
    -- allyIntel: GroupProfile from GroupProfiler.profileUnits
    self.allyIntel = allyIntel
end

function GroupCommander:updateFuelConsumption(currentTime, currentPos)
    if currentPos and self.lastPosition then
        -- Calculate distance traveled
        local distanceTraveled = SpatialAgent.distance2D(currentPos, self.lastPosition)
        -- Calculate time elapsed
        local timeElapsed = currentTime - self.lastObserveTime
        
        -- Fuel burn rates (balanced for ground vehicles)
        -- Movement: 250 statute miles (402km) on full tank
        local movementBurnRate = 0.0000025  -- 100% fuel over 402,336m
        -- Idle: 5x the drive time at 30mph (41.7 hours idle on full tank)
        local idleBurnRate = 0.0000067  -- 100% fuel over 41.7 hours (150,012s)
        
        -- Apply fuel consumption
        local movementBurn = distanceTraveled * movementBurnRate
        local idleBurn = timeElapsed * idleBurnRate
        self.fuelRemaining = math.max(0, self.fuelRemaining - movementBurn - idleBurn)
    end
end

function GroupCommander:setALR(riskLevel)
    env.info("Setting ALR to " .. riskLevel .. " for group of color " .. self.color)
    self.alr = riskLevel
end

function GroupCommander:setDisposition(dispositionType)
    self.disposition = dispositionType
end
function GroupCommander:setFormation(formationType)
    env.info("Setting formation to " .. formationType .. " for group of color " .. self.color)
    self.formationType = formationType
end

function GroupCommander:setROE(roeLevel)
    local group = Group.getByName(self.groupName)
    if group and group:isExist() then
        local controller = group:getController()
        controller:setOption(AI.Option.Ground.id.ROE, roeLevel)
        self.roe = roeLevel
    else
        env.info("ERROR: Cannot set ROE, group " .. self.groupName .. " does not exist")
    end
end

-- Helper to stop group movement
function GroupCommander:stopMovement()
    local group = Group.getByName(self.groupName)
    if group and group:isExist() then
        local controller = group:getController()
        controller:setTask({id = 'Hold', params = {}})
    end
    self.lastMoveOrder = nil
end

return GroupCommander

end)
__bundle_register("threat-tracker", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local SpatialAgent = require("spatial-agent")
local threatStatus = constants.threatStatus

-- Threat tracking helper for managing observed enemy units with timestamps
-- Threats are stored in a table indexed by unit name
-- Each threat has multiple sightings from different observers with timestamps
-- This allows threats to persist and be shared even when temporarily out of sight

local ThreatTracker = {}
ThreatTracker.__index = ThreatTracker

function ThreatTracker.new(observerName)
    local self = setmetatable({}, ThreatTracker)
    self.threats = {}
    self.observerName = observerName  -- Name of the commander using this tracker
    return self
end

-- Update threats with newly observed units
-- observedUnits: array of {name, position} for units with LOS
function ThreatTracker:updateThreats(observedUnits)
    local currentTime = timer.getTime()
    
    -- Update or add observed threats
    for _, unitData in ipairs(observedUnits) do
        local threat = self.threats[unitData.name]
        
        if not threat then
            -- New threat
            env.info(self.observerName .. " ThreatTracker: New threat detected - " .. unitData.name .. " (OBSERVED)")
            self.threats[unitData.name] = {
                name = unitData.name,
                position = unitData.position,
                status = threatStatus.OBSERVED,
                sightings = {
                    {
                        observedBy = self.observerName,
                        observedAt = currentTime,
                        position = unitData.position
                    }
                },
                lastSighting = currentTime
            }
        else
            -- Update existing threat
            local oldStatus = threat.status
            threat.position = unitData.position
            threat.status = threatStatus.OBSERVED  -- Reset to observed if we see it again
            threat.lastSighting = currentTime
            
            -- Add new sighting
            table.insert(threat.sightings, {
                observedBy = self.observerName,
                observedAt = currentTime,
                position = unitData.position
            })
        end
    end
end

function ThreatTracker:updateExpectedThreats(observedThreats, observerPosition, detectionRadius)
    local observedNames = {}
    
    for _, unitData in ipairs(observedThreats) do
        observedNames[unitData.name] = true
    end
    
    -- Check for expected threats that were not observed. If we're close enough
    -- to have seen it but did not, its last known position is in doubt (UNCONFIRMED).
    -- If we're too far to check, there's no evidence against it (SUSPECTED).
    for unitName, threat in pairs(self.threats) do
        local notObserved = not observedNames[unitName]
        local isExpected = threat.status ~= threatStatus.ELIMINATED and threat.status ~= threatStatus.LOST
        if notObserved and isExpected then
            local inExpectedRadius = SpatialAgent.isWithinRadius(threat.position, observerPosition, detectionRadius)
            if inExpectedRadius then
                threat.status = threatStatus.UNCONFIRMED
            else
                threat.status = threatStatus.SUSPECTED
            end
        end
    end
end

-- Get the threats table
-- Returns: table indexed by unit name
function ThreatTracker:getThreats()
    return self.threats
end

-- Get a single threat by name
-- Returns: threat data or nil
function ThreatTracker:getThreat(unitName)
    return self.threats[unitName]
end

-- Merge threat intel from external source (e.g., strategic commander)
-- threatIntel: partial threat table with updates to merge
function ThreatTracker:mergeThreatIntel(threatIntel)
    for unitName, incomingThreat in pairs(threatIntel) do
        local existingThreat = self.threats[unitName]
        
        if not existingThreat then
            -- New threat from external intel
            self.threats[unitName] = incomingThreat
        else
            -- Merge with existing threat
            -- Update position if incoming is more recent
            if incomingThreat.lastSighting > existingThreat.lastSighting then
                existingThreat.position = incomingThreat.position
                existingThreat.lastSighting = incomingThreat.lastSighting
            end
            
            -- Update status (prefer more definitive states)
            if incomingThreat.status then
                existingThreat.status = incomingThreat.status
            end
            
            -- Merge sightings
            if incomingThreat.sightings then
                for _, sighting in ipairs(incomingThreat.sightings) do
                    -- Avoid duplicate sightings from same observer at same time
                    local isDuplicate = false
                    for _, existingSighting in ipairs(existingThreat.sightings) do
                        if existingSighting.observedBy == sighting.observedBy and
                           existingSighting.observedAt == sighting.observedAt then
                            isDuplicate = true
                            break
                        end
                    end
                    if not isDuplicate then
                        table.insert(existingThreat.sightings, sighting)
                    end
                end
            end
        end
    end
end

-- Mark a threat with a specific status
-- unitName: name of the threat unit
-- status: threatStatus constant (OBSERVED, SUSPECTED, UNCONFIRMED, LOST, ELIMINATED)
function ThreatTracker:markThreatStatus(unitName, status)
    local threat = self.threats[unitName]
    if threat then
        local oldStatus = threat.status
        threat.status = status
        if oldStatus ~= status then
            threat.statusChangedAt = timer.getTime()
        end
    end
end

-- Get threats we would expect to see in an area
-- position: {x, y, z} position to check
-- radius: search radius in meters
-- Returns: array of threat names that are in area but not LOST or ELIMINATED
function ThreatTracker:expectedThreats(position, radius)
    local expected = {}
    
    for unitName, threat in pairs(self.threats) do
        if threat.status ~= threatStatus.ELIMINATED and threat.status ~= threatStatus.LOST then
            if SpatialAgent.isWithinRadius(threat.position, position, radius) then
                table.insert(expected, unitName)
            end
        end
    end
    
    return expected
end

-- Count threats in memory
-- Returns: number of threats stored
function ThreatTracker:count()
    local count = 0
    for _ in pairs(self.threats) do
        count = count + 1
    end
    return count
end

-- Age threats and progress their status based on time
-- UNCONFIRMED for >5 minutes → LOST
-- LOST or ELIMINATED for >10 minutes → removed
function ThreatTracker:ageThreats()
    local currentTime = timer.getTime()
    local toRemove = {}
    
    for unitName, threat in pairs(self.threats) do
        -- Track when status was last changed
        if not threat.statusChangedAt then
            threat.statusChangedAt = threat.lastSighting
        end
        
        local timeInStatus = currentTime - threat.statusChangedAt
        
        -- Progress UNCONFIRMED → LOST after 5 minutes
        if threat.status == threatStatus.UNCONFIRMED and timeInStatus > 300 then
            threat.status = threatStatus.LOST
            threat.statusChangedAt = currentTime
        end
        
        -- Remove LOST or ELIMINATED threats after 10 minutes
        if (threat.status == threatStatus.LOST or threat.status == threatStatus.ELIMINATED) and timeInStatus > 600 then
            table.insert(toRemove, unitName)
        end
    end
    
    -- Remove threats marked for removal
    for _, unitName in ipairs(toRemove) do
        self.threats[unitName] = nil
    end
end

function ThreatTracker:getRecentThreats(maxAge)
    local currentTime = timer.getTime()
    local recentThreats = {}
    maxAge = maxAge or 120  -- Default 2 minutes
    
    for unitName, threat in pairs(self.threats) do
        -- Only include threats that are actively relevant
        local includeInAnalysis = false
        
        if threat.status == "Observed" then
            includeInAnalysis = true
        elseif threat.status == "Suspected" and threat.lastSighting then
            -- Include suspected threats if seen within last 60 seconds
            local timeSinceLastSeen = currentTime - threat.lastSighting
            if timeSinceLastSeen < maxAge then
                includeInAnalysis = true
            end
        end
        
        if includeInAnalysis then
            recentThreats[unitName] = threat  -- Return threat object indexed by name
        end
    end
    
    return recentThreats
end

-- Check if we have any recently observed or suspected threats
-- Returns: true if there are threats with fresh intel (within maxAge seconds)
function ThreatTracker:hasRecentThreats(maxAge)
    local recentThreats = self:getRecentThreats(maxAge)
    return #recentThreats > 0
end

-- Get the most recent sighting time across all threats
-- Returns: timestamp of most recent sighting, or 0 if no threats
function ThreatTracker:getMostRecentSightingTime()
    local mostRecent = 0
    
    for _, threat in pairs(self.threats) do
        if threat.lastSighting and threat.lastSighting > mostRecent then
            mostRecent = threat.lastSighting
        end
    end
    
    return mostRecent
end

-- Cull threats that haven't been observed recently (for future use)
-- maxAge: maximum age in seconds (threats older than this will be removed)
function ThreatTracker:cullOldThreats(maxAge)
    local currentTime = timer.getTime()
    local culledThreats = {}
    
    for unitName, threatData in pairs(self.threats) do
        local age = currentTime - threatData.observedAt
        if age <= maxAge then
            culledThreats[unitName] = threatData
        end
    end
    
    self.threats = culledThreats
end

return ThreatTracker

end)
__bundle_register("threat-detector", function(require, _LOADED, __bundle_register, __bundle_modules)
-- ThreatDetector provides coalition-agnostic unit detection
-- Can detect units around any collection of observer units using radius and LOS checks
-- Includes probabilistic detection based on distance

local ThreatDetector = {}

-- Default detection parameters
local DEFAULT_DETECTION_RADIUS = 8000 -- meters
local DEFAULT_OBSERVER_ALTITUDE = 2 -- meters above unit position
local DEFAULT_TARGET_ALTITUDE = 2 -- meters above unit position

-- ============================================================================
-- UNIT COLLECTION HELPERS
-- ============================================================================

-- Get unit references from a MIST unit table (array of unit names)
function ThreatDetector.getUnitsFromMistTable(unitNames)
    local units = {}
    for _, unitName in ipairs(unitNames) do
        local unit = Unit.getByName(unitName)
        if unit and unit:isExist() then
            table.insert(units, unit)
        end
    end
    return units
end

-- Get unit references from one or more DCS group references
function ThreatDetector.getUnitsFromGroups(groups)
    local units = {}
    
    -- Handle single group or array of groups
    local groupList = {}
    if type(groups) == "table" and groups.getUnits then
        -- Single group object
        groupList = {groups}
    else
        -- Array of group objects
        groupList = groups
    end
    
    for _, group in ipairs(groupList) do
        if group and group:isExist() then
            local groupUnits = group:getUnits()
            for _, unit in ipairs(groupUnits) do
                if unit and unit:isExist() then
                    table.insert(units, unit)
                end
            end
        end
    end
    
    return units
end

-- Get unit references from group names
function ThreatDetector.getUnitsFromGroupNames(groupNames)
    local groups = {}
    for _, groupName in ipairs(groupNames) do
        local group = Group.getByName(groupName)
        if group and group:isExist() then
            table.insert(groups, group)
        end
    end
    return ThreatDetector.getUnitsFromGroups(groups)
end

-- ============================================================================
-- COALITION HELPERS
-- ============================================================================

-- Convert coalition string to number
-- Accepts: "red", "blue", "neutral" or numbers 0, 1, 2
-- Returns: 0=neutral, 1=red, 2=blue
function ThreatDetector.coalitionToNumber(coalition)
    if type(coalition) == "number" then
        return coalition
    end
    
    if coalition == "red" then
        return 1
    elseif coalition == "blue" then
        return 2
    elseif coalition == "neutral" then
        return 0
    end
    
    return nil
end

-- ============================================================================
-- DETECTION PROBABILITY
-- ============================================================================

-- Calculate detection probability based on distance
-- Returns coefficient from 0.0 to 1.0
function ThreatDetector.calculateDetectionCoefficient(distance, detectionRadius)
    local radius = detectionRadius or DEFAULT_DETECTION_RADIUS
    local halfRadius = radius / 2
    
    if distance <= halfRadius then
        return 1.0
    elseif distance >= radius then
        return 0.2  -- Minimum detection chance at max range
    else
        -- Linear interpolation from 1.0 at halfRadius to 0.2 at full radius
        local t = (distance - halfRadius) / (radius - halfRadius)
        return 1.0 - (t * 0.8)
    end
end

-- ============================================================================
-- RADIUS DETECTION
-- ============================================================================

-- Detect all units within radius of observer units
-- Returns units grouped by coalition: {friendly = {...}, enemy = {...}, neutral = {...}}
function ThreatDetector.detectUnitsInRadius(observerUnits, detectionRadius, observerCoalition)
    local radius = detectionRadius or DEFAULT_DETECTION_RADIUS
    local coalition = ThreatDetector.coalitionToNumber(observerCoalition)
    
    if not observerUnits or #observerUnits == 0 then
        return {friendly = {}, enemy = {}, neutral = {}}
    end
    
    -- Use first observer unit as center point for zone
    local centerUnit = observerUnits[1]
    if not centerUnit or not centerUnit:isExist() then
        return {friendly = {}, enemy = {}, neutral = {}}
    end
    
    local centerUnitName = centerUnit:getName()
    
    -- Get all units in zone
    local allUnits = mist.makeUnitTable({"[all]"})
    local unitsInZone = mist.getUnitsInMovingZones(
        allUnits,
        {centerUnitName},
        radius,
        "cylinder"
    )
    
    -- Classify by coalition
    local detected = {
        friendly = {},
        enemy = {},
        neutral = {}
    }
    
    -- Build set of observer unit names to exclude
    local observerNames = {}
    for _, unit in ipairs(observerUnits) do
        if unit and unit:isExist() then
            observerNames[unit:getName()] = true
        end
    end
    
    for _, unitObject in ipairs(unitsInZone) do
        if unitObject and unitObject.getName then
            local name = unitObject:getName()
            
            -- Skip observer units themselves
            if not observerNames[name] then
                local unit = Unit.getByName(name)
                if unit and unit:isExist() then
                    local unitCoalition = unit:getCoalition()
                    
                    -- Classify by coalition
                    -- Coalition: 0=neutral, 1=red, 2=blue
                    if coalition then
                        if unitCoalition == coalition then
                            table.insert(detected.friendly, unit)
                        elseif unitCoalition == 0 then
                            table.insert(detected.neutral, unit)
                        else
                            table.insert(detected.enemy, unit)
                        end
                    else
                        -- No coalition specified, just categorize
                        if unitCoalition == 1 then
                            table.insert(detected.friendly, unit) -- Use friendly for red
                        elseif unitCoalition == 2 then
                            table.insert(detected.enemy, unit) -- Use enemy for blue
                        else
                            table.insert(detected.neutral, unit)
                        end
                    end
                end
            end
        end
    end
    
    return detected
end

-- ============================================================================
-- LINE OF SIGHT DETECTION
-- ============================================================================

-- Filter detected units to only those with line of sight from observers
-- Applies probabilistic detection based on distance
-- Returns array of units that passed LOS and probability checks
function ThreatDetector.filterByLOS(observerUnits, targetUnits, detectionRadius, observerAlt, targetAlt)
    if not observerUnits or #observerUnits == 0 then
        return {}
    end
    
    if not targetUnits or #targetUnits == 0 then
        return {}
    end
    
    local radius = detectionRadius or DEFAULT_DETECTION_RADIUS
    local obsAlt = observerAlt or DEFAULT_OBSERVER_ALTITUDE
    local tgtAlt = targetAlt or DEFAULT_TARGET_ALTITUDE
    
    -- Build observer and target name arrays
    local observerNames = {}
    for _, unit in ipairs(observerUnits) do
        if unit and unit:isExist() then
            table.insert(observerNames, unit:getName())
        end
    end
    
    local targetNames = {}
    for _, unit in ipairs(targetUnits) do
        if unit and unit:isExist() then
            table.insert(targetNames, unit:getName())
        end
    end
    
    if #observerNames == 0 or #targetNames == 0 then
        return {}
    end
    
    -- Use MIST LOS check with radius filter
    local losResults = mist.getUnitsLOS(
        observerNames,
        obsAlt,
        targetNames,
        tgtAlt,
        radius  -- Maximum detection range
    )
    
    if not losResults or #losResults == 0 then
        return {}
    end
    
    -- Collect visible units with probabilistic detection
    local detectedUnitsSet = {}
    
    for _, observerResult in ipairs(losResults) do
        local observerUnit = observerResult.unit
        
        if observerUnit and observerUnit:isExist() and observerResult.vis then
            for _, targetUnit in ipairs(observerResult.vis) do
                if targetUnit and targetUnit:isExist() then
                    local targetName = targetUnit:getName()
                    
                    -- Only apply probability check once per target
                    if not detectedUnitsSet[targetName] then
                        local distance = mist.utils.get2DDist(
                            observerUnit:getPosition().p,
                            targetUnit:getPosition().p
                        )
                        
                        local coefficient = ThreatDetector.calculateDetectionCoefficient(distance, radius)
                        
                        -- Use coefficient as probability
                        if math.random() < coefficient then
                            detectedUnitsSet[targetName] = targetUnit
                        end
                    end
                end
            end
        end
    end
    
    -- Convert set to array
    local detectedUnits = {}
    for _, unit in pairs(detectedUnitsSet) do
        table.insert(detectedUnits, unit)
    end
    
    return detectedUnits
end

-- ============================================================================
-- COMBINED DETECTION
-- ============================================================================

-- Perform complete detection: radius check + LOS filter + probabilistic detection
-- Returns units grouped by coalition: {friendly = {...}, enemy = {...}, neutral = {...}}
-- All arrays contain units that passed both radius and LOS checks
function ThreatDetector.detectUnits(observerUnits, detectionRadius, observerCoalition, observerAlt, targetAlt)
    -- First detect all units in radius
    local unitsInRadius = ThreatDetector.detectUnitsInRadius(observerUnits, detectionRadius, observerCoalition)
    
    -- Then filter each category by LOS
    local detected = {
        friendly = ThreatDetector.filterByLOS(observerUnits, unitsInRadius.friendly, detectionRadius, observerAlt, targetAlt),
        enemy = ThreatDetector.filterByLOS(observerUnits, unitsInRadius.enemy, detectionRadius, observerAlt, targetAlt),
        neutral = ThreatDetector.filterByLOS(observerUnits, unitsInRadius.neutral, detectionRadius, observerAlt, targetAlt)
    }
    
    return detected
end

return ThreatDetector

end)
__bundle_register("doctrines.tactical.rally-doctrine", function(require, _LOADED, __bundle_register, __bundle_modules)
-- RallyDoctrine: Move to an assigned staging position and hold, without being
-- diverted into engaging threats along the way.
--
-- Rally exists to let a dispersed force mass at a safe distance before a
-- coordinated Assault. Unlike AsOrderedDoctrine (which treats every order as
-- an assault and will chase down standoff engagements), Rally only cares
-- about reaching its assigned point. DCS's own ROE (set to WEAPON_FREE by
-- GroupCommander) already lets units return fire opportunistically along the
-- way - this doctrine just keeps the group on course toward the staging
-- point instead of letting that incidental contact redirect movement.
--
-- Only a serious danger (using the order's own ALR-scaled retreat threshold)
-- will pull a group off task, via Abort.

local constants = require("constants")
local Doctrine = require("doctrine")
local AsOrderedDoctrine = require("doctrines.tactical.as-ordered-doctrine")
local SpatialAgent = require("spatial-agent")

local dispositionTypes = constants.dispositionTypes

local RallyDoctrine = {}
setmetatable(RallyDoctrine, {__index = Doctrine})
RallyDoctrine.__index = RallyDoctrine

function RallyDoctrine.new(commanderName)
    local self = Doctrine.new("Rally", commanderName)
    setmetatable(self, RallyDoctrine)

    self:registerPhase("Advance", RallyDoctrine.advancePhase)
    self:registerPhase("Hold", RallyDoctrine.holdPhase)
    self:registerPhase("Abort", RallyDoctrine.abortPhase)

    return self
end

-- Danger assessment is shared with AsOrderedDoctrine (ammo, attrition, threat
-- favorability, suitability) - it doesn't depend on order type. Only the
-- threshold at which it triggers an abort differs per ALR.
function RallyDoctrine:considerAbort(context)
    return AsOrderedDoctrine.considerAbort(self, context)
end

function RallyDoctrine:advancePhase(context)
    local ownPosition = context.ownPosition
    local stagingPosition = context.orderPosition
    local proximity = context.orderProximity or 500

    local abortThreshold = context.retreatThreshold or 0.4

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "abort",
        }
    end

    local distanceToStaging = SpatialAgent.distance2D(ownPosition, stagingPosition)
    if distanceToStaging <= proximity then
        self:changePhase("Hold")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "complete",
        }
    end

    return {
        disposition = dispositionTypes.ADVANCE,
        destination = stagingPosition,
        orderAction = "start",
    }
end

function RallyDoctrine:holdPhase(context)
    local abortThreshold = context.retreatThreshold or 0.4

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "abort",
        }
    end

    return {
        disposition = dispositionTypes.HOLD,
        destination = nil,
    }
end

function RallyDoctrine:abortPhase(context)
    local threat = context.threatAssessment
    local ownPosition = context.ownPosition

    local retreatDest = nil
    if threat.center then
        local direction = SpatialAgent.calculateDirection(threat.center, ownPosition)
        retreatDest = SpatialAgent.calculateDestination(ownPosition, direction, 1000)
    end

    return {
        disposition = dispositionTypes.RETREAT,
        destination = retreatDest,
        orderAction = "abort",
    }
end

return RallyDoctrine

end)
__bundle_register("doctrines.tactical.as-ordered-doctrine", function(require, _LOADED, __bundle_register, __bundle_modules)
-- OrderExecutionPlan: Assault-oriented behavior for executing orders
--
-- Assumes any order is essentially an assault mission:
-- - Move to destination
-- - Destroy threats near objective
-- - Defend position without pursuing too far
-- - Handle order lifecycle (start, complete, abort)
--
-- Critical status checks override normal behavior to force retreats when heavily damaged.

local constants = require("constants")
local ForceStatusAnalyzer = require("force-status-analyzer")
local Doctrine = require("doctrine")
local SpatialAgent = require("spatial-agent")

local dispositionTypes = constants.dispositionTypes
local orderStatus = constants.orderStatus
local taskTypes = constants.taskTypes

local AsOrderedDoctrine = {}
setmetatable(AsOrderedDoctrine, {__index = Doctrine})
AsOrderedDoctrine.__index = AsOrderedDoctrine

function AsOrderedDoctrine.new(commanderName)
    local self = Doctrine.new("AsOrdered", commanderName)
    setmetatable(self, AsOrderedDoctrine)

    self:registerPhase("Advance", AsOrderedDoctrine.advancePhase)
    self:registerPhase("Engage", AsOrderedDoctrine.engagePhase)
    self:registerPhase("Defend", AsOrderedDoctrine.defendPhase)
    self:registerPhase("Abort", AsOrderedDoctrine.abortPhase)

    return self
end

function AsOrderedDoctrine:considerEngage(context)
    local threat = context.threatAssessment
    local status = context.statusReport
    local totalUnits = context.totalUnits
    local ownPosition = context.ownPosition
    local objectivePosition = context.orderPosition

    local engageAssessment = 0.0

    -- threat favorability
    if threat.count > 0 and threat.favorability < 1.0 then
        engageAssessment = engageAssessment + threat.favorability
    else
        engageAssessment = engageAssessment + threat.favorability / 2
    end

    -- distance
    local distanceToThreat = SpatialAgent.distance2D(ownPosition, threat.center)
    local distanceToObjective = SpatialAgent.distance2D(ownPosition, objectivePosition)
    if distanceToObjective and distanceToThreat and distanceToObjective > 0 and distanceToThreat < distanceToObjective then
        engageAssessment = engageAssessment + distanceToThreat / distanceToObjective
    end

    -- attrition rate
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    engageAssessment = engageAssessment - attritionRate

    -- ammunition
    if ForceStatusAnalyzer.isAmmoLow(status.ammoCount, context.initialAmmoCount) then
        engageAssessment = 0.0
    end

    if ForceStatusAnalyzer.isUnarmed(context.initialAmmoCount) then
        engageAssessment = 0.0
    end

    return engageAssessment
end

function AsOrderedDoctrine:considerDefend(context)
    local objectivePosition = context.orderPosition

    local defendAssessment = 0.0

    local distanceToObjective = SpatialAgent.distance2D(context.ownPosition, objectivePosition)
    if distanceToObjective and distanceToObjective < context.orderProximity then
        defendAssessment = defendAssessment + 1.0
    end

    return defendAssessment
end

function AsOrderedDoctrine:considerAbort(context)
    local threat = context.threatAssessment
    local status = context.statusReport
    local totalUnits = context.totalUnits

    local retreatAssessment = 0.0

    -- ammunition
    if ForceStatusAnalyzer.isAmmoCritical(status.ammoCount, context.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isAmmoLow(status.ammoCount, context.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 0.5
    end

    -- attrition rate
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    retreatAssessment = retreatAssessment + attritionRate

    -- threat favorability
    if threat.count > 0 and threat.favorability < 1.0 then
        retreatAssessment = retreatAssessment + (1 - threat.favorability)
    else
        retreatAssessment = retreatAssessment - (1 / threat.favorability)
    end

    -- suitability: if group no longer meets missionProfile, increase abort pressure
    local suitability = context.suitability
    if suitability and suitability < 0.3 then
        retreatAssessment = retreatAssessment + (0.3 - suitability) * 2
    end

    return retreatAssessment
end

function AsOrderedDoctrine:advancePhase(context)
    -- Move toward objective location
    local destination = context.orderPosition

    local engageThreshold = 0.4
    local abortThreshold = context.retreatThreshold or 0.8
    local defendThreshold = 0.2

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "abort",
        }
    end

    if self:considerEngage(context) >= engageThreshold then
        self:changePhase("Engage")
        return {
            disposition = dispositionTypes.HOLD,
            destination = destination,
            orderAction = "start",
        }
    end

    if self:considerDefend(context) >= defendThreshold then
        self:changePhase("Defend")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "start",
        }
    end

    return {
        disposition = dispositionTypes.ADVANCE,
        destination = destination,
        orderAction = "start",
    }
end

function AsOrderedDoctrine:engagePhase(context)
    -- Engage threats encountered along route

    local threat = context.threatAssessment

    local engageThreshold = 0.3
    local abortThreshold = context.retreatThreshold or 0.8

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil
        }
    end

    if self:considerEngage(context) >= engageThreshold then
        local ownPosition      = context.ownPosition
        local standoffDistance = 1000
        local tolerance        = 100

        -- Standoff position: standoffDistance from threat, on our side of it.
        -- Computed this way rather than from ownPosition so the unit can never
        -- overshoot and pass through the threat.
        local retreatDir  = SpatialAgent.calculateDirection(threat.center, ownPosition)
        local standoffPos = SpatialAgent.calculateDestination(threat.center, retreatDir, standoffDistance)

        if SpatialAgent.distance2D(ownPosition, standoffPos) <= tolerance then
            return {
                disposition = dispositionTypes.HOLD,
                destination = ownPosition,
            }
        end

        return {
            disposition = dispositionTypes.ADVANCE,
            destination = standoffPos,
        }
    end

    self:changePhase("Advance")
    return {
        disposition = dispositionTypes.HOLD,
        destination = nil
    }

end

function AsOrderedDoctrine:defendPhase(context)
    -- Hold position and defend against nearby threats
    local destination = context.orderPosition
    local proximity = context.orderProximity or 500

    if context.orderIsExpired or not context.orderHasDeadline then
        return {
            disposition = dispositionTypes.DEFEND,
            destination = destination,
            proximity   = proximity,
            orderAction = "complete",
        }
    end

    return {
        disposition = dispositionTypes.DEFEND,
        destination = destination,
        proximity   = proximity,
    }
end

function AsOrderedDoctrine:abortPhase(context)
    -- Move away from threats toward safety
    local threat = context.threatAssessment
    local ownPosition = context.ownPosition

    -- Use directly observed threats if available (more stable)
    local retreatDest = nil

    if threat.center then
        local direction = SpatialAgent.calculateDirection(threat.center, ownPosition)
        retreatDest = SpatialAgent.calculateDestination(ownPosition, direction, 1000)
    else
        self:changePhase("Hold")
    end

    return {
        disposition = dispositionTypes.RETREAT,
        destination = retreatDest,
        orderAction = "abort",
    }
end

return AsOrderedDoctrine

end)
__bundle_register("force-status-analyzer", function(require, _LOADED, __bundle_register, __bundle_modules)
-- ForceStatusAnalyzer: Stateless utilities for assessing group and unit status
--
-- This module provides pure functions for analyzing force status, health, ammo,
-- and combat effectiveness. All functions are stateless and can be used by any
-- commander that needs to assess group capabilities.
--
-- Design: Follows the ThreatAnalyzer pattern - stateless utilities that accept
-- DCS Groups, group names, or unit tables and return analysis results.

local ForceStatusAnalyzer = {}

-- ============================================================================
-- Status Report Generation
-- ============================================================================

--- Get a detailed status report for a group
-- @param groupNameOrGroup string|Group - Group name or Group instance
-- @param initialUnitNames table - List of initial unit names for comparison
-- @param fuelRemaining number - Current fuel level (for simulated fuel tracking)
-- @return table Status report with alive count, ammo, health metrics
function ForceStatusAnalyzer.getStatusReport(groupNameOrGroup, initialUnitNames, fuelRemaining)
    local group = groupNameOrGroup
    if type(groupNameOrGroup) == "string" then
        group = Group.getByName(groupNameOrGroup)
    end
    
    if not group or not group:isExist() then
        return {
            aliveCount = 0,
            ammoCount = 0,
            ammmoLowState = nil,
            fuelRemaining = fuelRemaining or 0,
            healthPool = 0,
            healthLowState = nil,
        }
    end

    local totalCount = initialUnitNames and #initialUnitNames or 0
    if totalCount == 0 then
        return {
            aliveCount = 0,
            ammoCount = 0,
            ammmoLowState = nil,
            fuelRemaining = fuelRemaining or 0,
            healthPool = 0,
            healthLowState = nil,
        }
    end
    
    local aliveCount = 0
    local ammoCount = 0
    local ammmoLowState = nil
    local healthPool = 0
    local healthLowState = nil
    
    for _, unitName in ipairs(initialUnitNames) do
        local unit = Unit.getByName(unitName)
        if unit and unit:isExist() then
            local unitAmmoTable = unit:getAmmo()
            local unitHealth = unit:getLife()
            
            -- Sum up all ammo counts from the table
            local unitAmmoTotal = 0
            if unitAmmoTable then
                for _, ammoEntry in ipairs(unitAmmoTable) do
                    if ammoEntry.count then
                        unitAmmoTotal = unitAmmoTotal + ammoEntry.count
                    end
                end
            end

            aliveCount = aliveCount + 1
            ammoCount = ammoCount + unitAmmoTotal
            healthPool = healthPool + unitHealth

            if not ammmoLowState or unitAmmoTotal < ammmoLowState then
                ammmoLowState = unitAmmoTotal
            end

            if not healthLowState or unitHealth < healthLowState then
                healthLowState = unitHealth
            end
        end
    end
    
    return {
        aliveCount = aliveCount,
        ammoCount = ammoCount,
        ammmoLowState = ammmoLowState,
        fuelRemaining = fuelRemaining or 0,
        healthPool = healthPool,
        healthLowState = healthLowState,
    }
end

function ForceStatusAnalyzer.getCriticalStatusReport(groupNameOrGroup, initialUnitNames, fuelRemaining)
    local status = ForceStatusAnalyzer.getStatusReport(groupNameOrGroup, initialUnitNames, fuelRemaining)
    
    if not status or status.aliveCount == 0 then
        return nil  -- No decision needed
    end
    
    local totalUnits = #initialUnitNames
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    local hasAmmoCounts = status.ammoCount ~= nil and status.initialAmmoCount ~= nil
    
    -- CRITICAL: Heavy casualties (>40%) - force retreat
    if attritionRate > 0.4 then
        return {
            level = "CRITICAL",
            reason = "HEAVY_CASUALTIES",
        }
    end
    
    -- CRITICAL: No ammunition - hold or retreat
    if hasAmmoCounts and status.initialAmmoCount > 0 and status.ammoCount == 0 then
        return {
            level = "CRITICAL",
            reason = "NO_AMMO_WITH_THREATS",
        }
    end
    
    -- WARNING: Moderate casualties (30-40%)
    if attritionRate > 0.3 then
        return {
            level = "WARNING",
            reason = "MODERATE_CASUALTIES",
        }
    end

    -- WARNING: Low ammunition
    if hasAmmoCounts and status.initialAmmoCount > 0 and ForceStatusAnalyzer.isAmmoLow(status.ammoCount, status.initialAmmoCount, 20) then
        return {
            level = "WARNING",
            reason = "LOW_AMMO",
        }
    end
    
    return nil  -- No critical conditions
end

--- Get collective status (percentage of units alive)
-- @param aliveCount number - Number of currently alive units
-- @param initialCount number - Initial number of units
-- @return number - Percentage alive (0.0 to 1.0), or 0 if initialCount is 0
function ForceStatusAnalyzer.calculateCollectiveStatus(aliveCount, initialCount)
    if not initialCount or initialCount == 0 then
        return 0
    end
    
    return (aliveCount or 0) / initialCount
end

--- Get collective status from a status report
-- @param statusReport table - Status report from getStatusReport()
-- @param initialCount number - Initial number of units
-- @return number - Percentage alive (0.0 to 1.0)
function ForceStatusAnalyzer.getCollectiveStatusFromReport(statusReport, initialCount)
    return ForceStatusAnalyzer.calculateCollectiveStatus(statusReport.aliveCount, initialCount)
end

-- ============================================================================
-- Ammo Analysis
-- ============================================================================

--- Calculate ammo percentage remaining
-- @param currentAmmo number - Current total ammo count
-- @param baselineAmmo number - Initial/baseline ammo count
-- @return number - Percentage remaining (0-100), or nil if baselineAmmo is 0
function ForceStatusAnalyzer.calculateAmmoPercentage(currentAmmo, baselineAmmo)
    if not baselineAmmo or baselineAmmo == 0 then
        return nil
    end
    
    return (currentAmmo / baselineAmmo) * 100
end

--- Check if ammo is below a threshold percentage
-- @param currentAmmo number - Current total ammo count
-- @param baselineAmmo number - Initial/baseline ammo count
-- @param thresholdPercent number - Threshold percentage (0-100), default 20%
-- @return boolean - True if ammo is below threshold
function ForceStatusAnalyzer.isAmmoLow(currentAmmo, baselineAmmo, thresholdPercent)
    local threshold = thresholdPercent or 20
    local percentage = ForceStatusAnalyzer.calculateAmmoPercentage(currentAmmo, baselineAmmo)
    
    if not percentage then
        return false
    end
    
    return percentage < threshold
end

--- Check if ammo is critically low
-- @param currentAmmo number - Current total ammo count
-- @param baselineAmmo number - Initial/baseline ammo count
-- @param thresholdPercent number - Threshold percentage (0-100), default 5%
-- @return boolean - True if ammo is critically low
function ForceStatusAnalyzer.isAmmoCritical(currentAmmo, baselineAmmo, thresholdPercent)
    local threshold = thresholdPercent or 5
    local percentage = ForceStatusAnalyzer.calculateAmmoPercentage(currentAmmo, baselineAmmo)
    
    if not percentage then
        return false
    end
    
    return percentage < threshold
end

--- Check if ammo is below an absolute threshold
-- @param currentAmmo number - Current total ammo count
-- @param baselineAmmo number - Initial/baseline ammo count
-- @param thresholdPercent number - Threshold as decimal (0.0-1.0), e.g., 0.2 for 20%
-- @return boolean - True if below threshold
function ForceStatusAnalyzer.isAmmoBelowThreshold(currentAmmo, baselineAmmo, thresholdPercent)
    if not baselineAmmo or baselineAmmo == 0 then
        return false
    end
    
    local thresholdAmount = baselineAmmo * thresholdPercent
    return currentAmmo < thresholdAmount
end

function ForceStatusAnalyzer.isUnarmed(baselineAmmo)
    return baselineAmmo == 0
end

-- ============================================================================
-- Attrition Analysis
-- ============================================================================

--- Calculate attrition rate
-- @param aliveCount number - Number of currently alive units
-- @param initialCount number - Initial number of units
-- @return number - Attrition rate (0.0 to 1.0), where 0 = no losses, 1 = total loss
function ForceStatusAnalyzer.calculateAttritionRate(aliveCount, initialCount)
    if not initialCount or initialCount == 0 then
        return 0
    end
    
    return 1 - (aliveCount / initialCount)
end

--- Check if attrition has reached a significant threshold
-- @param aliveCount number - Number of currently alive units
-- @param initialCount number - Initial number of units
-- @param thresholdPercent number - Threshold as decimal (0.0-1.0), default 0.5 (50% losses)
-- @return boolean - True if attrition exceeds threshold
function ForceStatusAnalyzer.hasSignificantAttrition(aliveCount, initialCount, thresholdPercent)
    local threshold = thresholdPercent or 0.5
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(aliveCount, initialCount)
    
    return attritionRate >= threshold
end

-- ============================================================================
-- Health Analysis
-- ============================================================================

--- Calculate average health per unit
-- @param healthPool number - Total health of all units
-- @param aliveCount number - Number of alive units
-- @return number - Average health per unit, or 0 if no units alive
function ForceStatusAnalyzer.calculateAverageHealth(healthPool, aliveCount)
    if not aliveCount or aliveCount == 0 then
        return 0
    end
    
    return healthPool / aliveCount
end

--- Check if the lowest unit health is below a threshold
-- @param lowestHealth number - Health of the weakest unit
-- @param threshold number - Health threshold
-- @return boolean - True if lowest health is below threshold
function ForceStatusAnalyzer.hasWeakUnit(lowestHealth, threshold)
    if not lowestHealth then
        return false
    end
    
    return lowestHealth < threshold
end

-- ============================================================================
-- Unit Counting Utilities
-- ============================================================================

--- Count alive units in a group
-- @param groupNameOrGroup string|Group - Group name or Group instance
-- @return number - Number of alive units
function ForceStatusAnalyzer.countAliveUnits(groupNameOrGroup)
    local group = groupNameOrGroup
    if type(groupNameOrGroup) == "string" then
        group = Group.getByName(groupNameOrGroup)
    end
    
    if not group or not group:isExist() then
        return 0
    end
    
    local units = group:getUnits()
    local count = 0
    
    for _, unit in ipairs(units) do
        if unit and unit:isExist() then
            count = count + 1
        end
    end
    
    return count
end

--- Get all alive units from a group
-- @param groupNameOrGroup string|Group - Group name or Group instance
-- @return table - Array of Unit instances
function ForceStatusAnalyzer.getAliveUnits(groupNameOrGroup)
    local group = groupNameOrGroup
    if type(groupNameOrGroup) == "string" then
        group = Group.getByName(groupNameOrGroup)
    end
    
    if not group or not group:isExist() then
        return {}
    end
    
    local units = group:getUnits()
    local aliveUnits = {}
    
    for _, unit in ipairs(units) do
        if unit and unit:isExist() then
            table.insert(aliveUnits, unit)
        end
    end
    
    return aliveUnits
end

-- ============================================================================
-- Comparative Analysis
-- ============================================================================

--- Compare current status against baseline and return a summary
-- @param currentStatus table - Current status report from getStatusReport()
-- @param baselineAmmo number - Initial ammo count
-- @param initialCount number - Initial unit count
-- @return table - Analysis with percentages and flags
function ForceStatusAnalyzer.compareToBaseline(currentStatus, baselineAmmo, initialCount)
    local analysis = {
        aliveCount = currentStatus.aliveCount,
        collectiveStatus = ForceStatusAnalyzer.calculateCollectiveStatus(currentStatus.aliveCount, initialCount),
        attritionRate = ForceStatusAnalyzer.calculateAttritionRate(currentStatus.aliveCount, initialCount),
        ammoPercent = ForceStatusAnalyzer.calculateAmmoPercentage(currentStatus.ammoCount, baselineAmmo),
        averageHealth = ForceStatusAnalyzer.calculateAverageHealth(currentStatus.healthPool, currentStatus.aliveCount),
        
        -- Flags
        isAmmoLow = ForceStatusAnalyzer.isAmmoLow(currentStatus.ammoCount, baselineAmmo, 20),
        isAmmoCritical = ForceStatusAnalyzer.isAmmoCritical(currentStatus.ammoCount, baselineAmmo, 5),
        hasHighAttrition = ForceStatusAnalyzer.hasSignificantAttrition(currentStatus.aliveCount, initialCount, 0.5),
        hasCriticalAttrition = ForceStatusAnalyzer.hasSignificantAttrition(currentStatus.aliveCount, initialCount, 0.75),
    }
    
    return analysis
end

return ForceStatusAnalyzer

end)
__bundle_register("doctrines.tactical.recon-doctrine", function(require, _LOADED, __bundle_register, __bundle_modules)
-- Proceed toward the given an objective until threats are spotted
-- If threats encountered, mark the recon orders complete and observe from distance
-- If no threats encountered, continue to objective
-- Mark orders complete once at objective

local constants = require("constants")
local dispositionTypes = constants.dispositionTypes
local Doctrine = require("doctrine")
local SpatialAgent = require("spatial-agent")
local ReconDoctrine= {}
setmetatable(ReconDoctrine, {__index = Doctrine})
ReconDoctrine.__index = ReconDoctrine

-- Factory method for creating new Doctrine instances
function ReconDoctrine.new(commanderName)
    local self = Doctrine.new("Recon", commanderName)
    setmetatable(self, ReconDoctrine)

    self.observedThreatCenter = nil

    self:registerPhase("Advance", ReconDoctrine.advancePhase)
    self:registerPhase("Observe", ReconDoctrine.observePhase)

    return self
end

function ReconDoctrine:considerAdvance(context)
    local threat = context.threatAssessment

    local advanceAssessment = 0.0

    if threat.count == 0 then
        advanceAssessment = 1.0
    end

    return advanceAssessment
end

function ReconDoctrine:considerObserve(context)
    local threat = context.threatAssessment

    local observeAssessment = 0.0

    if threat.count > 0 then
        observeAssessment = 1.0
    end

    return observeAssessment
end

function ReconDoctrine:advancePhase(context)
    local threat = context.threatAssessment
    local ownPosition = context.ownPosition
    local objectiveDestination = context.orderPosition

    local observeThreshold = 1.0

    if self:considerObserve(context) >= observeThreshold then
        self:changePhase("Observe")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "start",
        }
    end

    local distanceToDestination = SpatialAgent.distance2D(ownPosition, objectiveDestination)
    local closeEnough = 500
    if distanceToDestination <= closeEnough then
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "complete",
        }
    end

    return {
        disposition = dispositionTypes.ADVANCE,
        destination = context.orderPosition,
        orderAction = "start",
    }
end

function ReconDoctrine:observePhase(context)
    local advanceThreshold = 1.0

    if self:considerAdvance(context) >= advanceThreshold then
        self:changePhase("Advance")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
        }
    end

    return {
        disposition = dispositionTypes.HOLD,
        destination = nil,
        orderAction = "complete",
    }
end

return ReconDoctrine

end)
__bundle_register("doctrines.tactical.assault-doctrine", function(require, _LOADED, __bundle_register, __bundle_modules)
-- Reworking of AsOrderedDoctrine to emphasize occupying position
--
-- Assault a position:
-- - Move to destination
-- - Destroy threats near objective
-- - Defend position without pursuing too far
-- - Handle order lifecycle (start, complete, abort)
--
-- Critical status checks override normal behavior to force retreats when heavily damaged.

local constants = require("constants")
local ForceStatusAnalyzer = require("force-status-analyzer")
local Doctrine = require("doctrine")
local SpatialAgent = require("spatial-agent")

local dispositionTypes = constants.dispositionTypes
local orderStatus = constants.orderStatus
local taskTypes = constants.taskTypes

local AssaultDoctrine = {}
setmetatable(AssaultDoctrine, {__index = Doctrine})
AssaultDoctrine.__index = AssaultDoctrine

function AssaultDoctrine.new(commanderName)
    local self = Doctrine.new("Assault", commanderName)
    setmetatable(self, AssaultDoctrine)

    self:registerPhase("Advance", AssaultDoctrine.advancePhase)
    self:registerPhase("Engage", AssaultDoctrine.engagePhase)
    self:registerPhase("Defend", AssaultDoctrine.defendPhase)
    self:registerPhase("Abort", AssaultDoctrine.abortPhase)

    return self
end

function AssaultDoctrine:considerDefend(context)
    local objectivePosition = context.orderPosition

    local defendAssessment = 0.0

    local distanceToObjective = SpatialAgent.distance2D(context.ownPosition, objectivePosition)
    if distanceToObjective and distanceToObjective < context.orderProximity then
        defendAssessment = defendAssessment + 1.0
    end

    return defendAssessment
end

function AssaultDoctrine:considerAbort(context)
    local threat = context.threatAssessment
    local status = context.statusReport
    local totalUnits = context.totalUnits

    local retreatAssessment = 0.0

    -- ammunition
    if ForceStatusAnalyzer.isAmmoCritical(status.ammoCount, context.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isAmmoLow(status.ammoCount, context.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 0.5
    end

    -- attrition rate
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    retreatAssessment = retreatAssessment + attritionRate

    -- threat favorability
    if threat.count > 0 and threat.favorability < 1.0 then
        retreatAssessment = retreatAssessment + (1 - threat.favorability)
    else
        retreatAssessment = retreatAssessment - (1 / threat.favorability)
    end

    -- suitability: if group no longer meets missionProfile, increase abort pressure
    local suitability = context.suitability
    if suitability and suitability < 0.3 then
        retreatAssessment = retreatAssessment + (0.3 - suitability) * 2
    end

    return retreatAssessment
end

function AssaultDoctrine:advancePhase(context)
    -- Move toward objective location
    local destination = context.orderPosition

    local engageThreshold = 0.4
    local abortThreshold = context.retreatThreshold or 0.8
    local defendThreshold = 0.2

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "abort",
        }
    end

    if self:considerDefend(context) >= defendThreshold then
        self:changePhase("Defend")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "start",
        }
    end

    return {
        disposition = dispositionTypes.ADVANCE,
        destination = destination,
        orderAction = "start",
    }
end

function AssaultDoctrine:defendPhase(context)
    -- Hold position and defend against nearby threats
    local destination = context.orderPosition
    local proximity = context.orderProximity or 500

    if context.orderIsExpired or not context.orderHasDeadline then
        return {
            disposition = dispositionTypes.DEFEND,
            destination = destination,
            proximity   = proximity,
            orderAction = "complete",
        }
    end

    return {
        disposition = dispositionTypes.DEFEND,
        destination = destination,
        proximity   = proximity,
    }
end

function AssaultDoctrine:abortPhase(context)
    -- Move away from threats toward safety
    local threat = context.threatAssessment
    local ownPosition = context.ownPosition

    -- Use directly observed threats if available (more stable)
    local retreatDest = nil

    if threat.center then
        local direction = SpatialAgent.calculateDirection(threat.center, ownPosition)
        retreatDest = SpatialAgent.calculateDestination(ownPosition, direction, 1000)
    else
        self:changePhase("Hold")
    end

    return {
        disposition = dispositionTypes.RETREAT,
        destination = retreatDest,
        orderAction = "abort",
    }
end

return AssaultDoctrine

end)
__bundle_register("ooda-commander", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local oodaStates = constants.oodaStates

local OODACommander = {}
OODACommander.__index = OODACommander

function OODACommander.new(config)
    local self = setmetatable({}, OODACommander)

    local oodaInterval = config.interval or 10

    self.oodaState = oodaStates.OBSERVE
    self.oodaOffset = math.random() * oodaInterval
    self.destroyed = false  -- Flag to stop scheduling

    -- Store schedule ID so we can cancel it later
    self.scheduleId = mist.scheduleFunction(
        OODACommander.oodaTick,
        {self},
        timer.getTime() + self.oodaOffset,
        oodaInterval
    )
    return self
end

function OODACommander:oodaTick()
    if self.oodaState == oodaStates.OBSERVE then
        self:observe()
        self.oodaState = oodaStates.ORIENT
    elseif self.oodaState == oodaStates.ORIENT then
        self:orient()
        self.oodaState = oodaStates.DECIDE
    elseif self.oodaState == oodaStates.DECIDE then
        self:decide()
        self.oodaState = oodaStates.ACT
    elseif self.oodaState == oodaStates.ACT then
        self:act()
        self.oodaState = oodaStates.OBSERVE
    end
    
    -- After any phase, check if destroyed and cancel schedule
    if self.destroyed then
        self:cancelSchedule()
    end
end

function OODACommander:observe()
    error("OODACommander subclass must implement observe()")
end

function OODACommander:orient()
    error("OODACommander subclass must implement orient()")
end

function OODACommander:decide()
    error("OODACommander subclass must implement decide()")
end

function OODACommander:act()
    error("OODACommander subclass must implement act()")
end

-- Cancel the scheduled OODA loop
function OODACommander:cancelSchedule()
    if self.scheduleId then
        mist.removeFunction(self.scheduleId)
        self.scheduleId = nil
    end
end

return OODACommander

end)
__bundle_register("group-profiler", function(require, _LOADED, __bundle_register, __bundle_modules)
-- GroupProfiler: Unified force analysis and status profiling
-- Consolidates ThreatAnalyzer and ForceStatusAnalyzer into a single interface.
-- Returns GroupProfile tables with capability, composition, unit count, and status.
--
-- GroupProfile schema:
-- {
--     offensiveCapability = { vsInfantry=N, vsArmor=N, vsAir=N },
--     composition         = { infantry=N, lightArmor=N, heavyArmor=N, support=N },
--     unitCount           = N,
--     -- Status fields (only from profileGroup, nil from profileUnits):
--     attritionRate       = 0.0-1.0,
--     ammoRatio           = 0.0-1.0,
--     fuelRatio           = 0.0-1.0,
-- }

local constants = require("constants")
local unitClassification = constants.unitClassification

local GroupProfiler = {}

-- ============================================================================
-- UNIT CLASSIFICATION
-- ============================================================================

function GroupProfiler.classifyUnit(unit)
    if not unit or not unit:isExist() then
        return {category = "infantry", threats = {infantry = 0, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 0}}
    end

    local typeName = unit:getTypeName()
    if not typeName then
        return {category = "infantry", threats = {infantry = 0, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 0}}
    end

    local classification = unitClassification[typeName]
    if classification then
        return classification
    end

    env.info("WARNING: GroupProfiler - Unknown unit type '" .. typeName .. "' - using default classification")
    return {category = "infantry", threats = {infantry = 1, ["light-armor"] = 1, ["heavy-armor"] = 0, support = 1}}
end

-- ============================================================================
-- UNIT COLLECTION HELPERS
-- ============================================================================

function GroupProfiler.getUnitsFromGroups(groups)
    local units = {}

    local groupList = {}
    if type(groups) == "table" and groups.getUnits then
        groupList = {groups}
    else
        groupList = groups
    end

    for _, group in ipairs(groupList) do
        if group and group:isExist() then
            local groupUnits = group:getUnits()
            for _, unit in ipairs(groupUnits) do
                if unit and unit:isExist() then
                    table.insert(units, unit)
                end
            end
        end
    end

    return units
end

function GroupProfiler.getUnitsFromGroupNames(groupNames)
    local groups = {}
    for _, groupName in ipairs(groupNames) do
        local group = Group.getByName(groupName)
        if group and group:isExist() then
            table.insert(groups, group)
        end
    end
    return GroupProfiler.getUnitsFromGroups(groups)
end

-- ============================================================================
-- PROFILE CONSTRUCTION
-- ============================================================================

-- Build a capability/composition profile from a list of unit references.
-- Status fields (attritionRate, ammoRatio, fuelRatio) are NOT set.
function GroupProfiler.profileUnits(units)
    local profile = {
        offensiveCapability = {vsInfantry = 0, vsArmor = 0, vsAir = 0},
        composition         = {infantry = 0, lightArmor = 0, heavyArmor = 0, support = 0},
        unitCount           = 0,
    }

    if not units or #units == 0 then
        return profile
    end

    for _, unit in ipairs(units) do
        if unit and unit:isExist() then
            local classification = GroupProfiler.classifyUnit(unit)
            local threats = classification.threats

            profile.unitCount = profile.unitCount + 1

            local cat = classification.category
            if cat == "infantry" then
                profile.composition.infantry = profile.composition.infantry + 1
            elseif cat == "light-armor" then
                profile.composition.lightArmor = profile.composition.lightArmor + 1
            elseif cat == "heavy-armor" then
                profile.composition.heavyArmor = profile.composition.heavyArmor + 1
            elseif cat == "support" then
                profile.composition.support = profile.composition.support + 1
            end

            profile.offensiveCapability.vsInfantry = profile.offensiveCapability.vsInfantry + threats.infantry
            profile.offensiveCapability.vsArmor    = profile.offensiveCapability.vsArmor
                                                     + threats["light-armor"]
                                                     + threats["heavy-armor"]
            profile.offensiveCapability.vsAir      = profile.offensiveCapability.vsAir + threats.support
        end
    end

    return profile
end

-- Build a full profile for a named DCS group, including status ratios.
function GroupProfiler.profileGroup(groupName, initialUnitNames, initialAmmoCount, fuelRemaining)
    local zeroed = {
        offensiveCapability = {vsInfantry = 0, vsArmor = 0, vsAir = 0},
        composition         = {infantry = 0, lightArmor = 0, heavyArmor = 0, support = 0},
        unitCount           = 0,
        attritionRate       = 1,
        ammoRatio           = 0,
        fuelRatio           = 0,
    }

    local group = Group.getByName(groupName)
    if not group or not group:isExist() then
        return zeroed
    end

    -- Collect alive units
    local aliveUnits = {}
    for _, unit in ipairs(group:getUnits()) do
        if unit and unit:isExist() then
            table.insert(aliveUnits, unit)
        end
    end

    local profile = GroupProfiler.profileUnits(aliveUnits)

    -- Attrition rate
    local initialCount = (initialUnitNames and #initialUnitNames) or 0
    if initialCount == 0 then
        profile.attritionRate = 0
    else
        profile.attritionRate = 1 - (profile.unitCount / initialCount)
    end

    -- Ammo ratio
    if not initialAmmoCount or initialAmmoCount == 0 then
        profile.ammoRatio = 1.0  -- unarmed units are always considered "full"
    else
        local currentAmmo = 0
        for _, unit in ipairs(aliveUnits) do
            local ammoTable = unit:getAmmo()
            if ammoTable then
                for _, entry in ipairs(ammoTable) do
                    if entry.count then
                        currentAmmo = currentAmmo + entry.count
                    end
                end
            end
        end
        profile.ammoRatio = currentAmmo / initialAmmoCount
    end

    -- Fuel (simulated, passed in directly)
    profile.fuelRatio = fuelRemaining or 0

    return profile
end

-- ============================================================================
-- FORCE COMPARISON
-- ============================================================================

-- Returns how favorable our position is against the threat.
-- Higher = better for us. math.huge = no opposition.
function GroupProfiler.calculateFavorability(ownProfile, threatProfile)
    local ownCap    = ownProfile.offensiveCapability
    local theirComp = threatProfile.composition

    local ourPower = ownCap.vsInfantry * theirComp.infantry
                   + ownCap.vsArmor    * (theirComp.lightArmor + theirComp.heavyArmor)
                   + ownCap.vsAir      * theirComp.support

    local theirCap = threatProfile.offensiveCapability
    local ownComp  = ownProfile.composition

    local theirPower = theirCap.vsInfantry * ownComp.infantry
                     + theirCap.vsArmor    * (ownComp.lightArmor + ownComp.heavyArmor)
                     + theirCap.vsAir      * ownComp.support

    if ourPower == 0 and theirPower == 0 then return 0 end
    if theirPower == 0 and ourPower > 0 then return math.huge end
    return ourPower / theirPower
end

return GroupProfiler

end)
__bundle_register("doctrines.tactical.defensive-doctrine", function(require, _LOADED, __bundle_register, __bundle_modules)
-- DefensivePosturePlan: Stand-your-ground autonomous behavior
--
-- For units without orders:
-- - Hold position and defend
-- - Retreat if overwhelmed
-- - Advance only with strong favorability
-- - No pursuit beyond local area
--
-- This is a conservative defensive strategy for units not actively committed to objectives.

local constants = require("constants")
local ForceStatusAnalyzer = require("force-status-analyzer")
local Doctrine = require("doctrine")
local SpatialAgent = require("spatial-agent")

local dispositionTypes = constants.dispositionTypes

local DefensiveDoctrine = {}
setmetatable(DefensiveDoctrine, {__index = Doctrine})
DefensiveDoctrine.__index = DefensiveDoctrine

function DefensiveDoctrine.new(commanderName)
    local self = Doctrine.new("Defensive", commanderName)
    setmetatable(self, DefensiveDoctrine)
    self.basePosition = nil

    self:registerPhase("Hold", DefensiveDoctrine.holdPhase)
    self:registerPhase("Retreat", DefensiveDoctrine.retreatPhase)
    self:registerPhase("Advance", DefensiveDoctrine.advancePhase)

    return self
end

function DefensiveDoctrine:considerRetreat(context)
    local threat = context.threatAssessment
    local status = context.statusReport
    local totalUnits = context.totalUnits

    local retreatAssessment = 0.0

    local ownPosition = context.ownPosition
    if not self.basePosition then
        self.basePosition = context.ownPosition
    end
    local basePosition = context.orderPosition or self.basePosition
    local excursion = SpatialAgent.distance2D(basePosition, ownPosition)
    local defenseRadius = context.defenseRadius or 4000

    -- as distance from base approaches max allowed, increase retreat pressure
    retreatAssessment = retreatAssessment + excursion / defenseRadius

    -- ammunition
    if ForceStatusAnalyzer.isAmmoCritical(status.ammoCount, context.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isAmmoLow(status.ammoCount, context.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 0.5
    end

    -- attrition rate
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    retreatAssessment = retreatAssessment + attritionRate

    -- threat favorability
    if threat.count > 0 and threat.favorability < 1.0 then
        retreatAssessment = retreatAssessment + (1 - threat.favorability)
    else
        retreatAssessment = retreatAssessment - (1 / threat.favorability)
    end

    -- suitability: if group no longer meets missionProfile, increase retreat pressure
    local suitability = context.suitability
    if suitability and suitability < 0.3 then
        retreatAssessment = retreatAssessment + (0.3 - suitability) * 2
    end

    return retreatAssessment
end

function DefensiveDoctrine:considerAdvance(context)
    local threat = context.threatAssessment
    local status = context.statusReport

    local advanceAssessment = 0.0

    local ownPosition = context.ownPosition
    if not self.basePosition then
        self.basePosition = context.ownPosition
    end
    local basePosition = context.orderPosition or self.basePosition
    local excursion = SpatialAgent.distance2D(basePosition, ownPosition)
    local defenseRadius = context.defenseRadius or 4000

    -- decrease advance likelihood as group gets farther from base position
    advanceAssessment = advanceAssessment - excursion / defenseRadius

    -- threat favorability
    if threat.count > 0 then
        if threat.favorability < 1.0 then
            advanceAssessment = advanceAssessment + threat.favorability
        else
            advanceAssessment = advanceAssessment + threat.favorability / 2
        end
    end

    -- attrition rate
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, context.totalUnits)
    advanceAssessment = advanceAssessment - attritionRate

    -- ammunition
    if ForceStatusAnalyzer.isAmmoLow(status.ammoCount, context.initialAmmoCount) then
        advanceAssessment = 0.0
    end

    return advanceAssessment
end

function DefensiveDoctrine:holdPhase(context)
    local retreatThreshold = 1.0
    local advanceThreshold = 0.7

    if self:considerRetreat(context) >= retreatThreshold then
        self:changePhase("Retreat")
    elseif self:considerAdvance(context) >= advanceThreshold then
        self:changePhase("Advance")
    end

    return {disposition = dispositionTypes.HOLD, destination = nil}
end

function DefensiveDoctrine:retreatPhase(context)
    local threat = context.threatAssessment
    local ownPosition = context.ownPosition

    -- Use directly observed threats if available (more stable)
    local retreatDest = nil

    -- TODO reconsider retreat if threat favorability improves, not just if threat disappears
    -- TODO consider aborting doctrine if already retreated and threat is still highly unfavorable
    if threat.center then
        local direction = SpatialAgent.calculateDirection(threat.center, ownPosition)
        retreatDest = SpatialAgent.calculateDestination(ownPosition, direction, 1000)
    else
        self:changePhase("Hold")
    end

    return {
        disposition = dispositionTypes.RETREAT,
        destination = retreatDest
    }
end

function DefensiveDoctrine:advancePhase(context)
    local threat = context.threatAssessment
    local ownPosition = context.ownPosition

    local holdThreshold = 0.5
    local retreatThreshold = 0.3
    local retreatAssessment = self:considerRetreat(context)
    local standoffDistance = 500

    -- Use directly observed threats if available (more stable)
    local advanceDest = nil

    if retreatAssessment >= retreatThreshold then
        self:changePhase("Retreat")
    elseif retreatAssessment >= holdThreshold or not threat.center then
        self:changePhase("Hold")
    else
        local threatDistance = SpatialAgent.distance2D(ownPosition, threat.center)
        local direction = SpatialAgent.calculateDirection(ownPosition, threat.center)
        advanceDest = SpatialAgent.calculateDestination(ownPosition, direction, threatDistance - standoffDistance)
    end

    return {
        disposition = dispositionTypes.ADVANCE,
        destination = advanceDest
    }
end


return DefensiveDoctrine

end)
__bundle_register("control-zones", function(require, _LOADED, __bundle_register, __bundle_modules)
local rgb = require("constants").rgb
local garrisonTemplates = require("constants").garrisonTemplates
local groundTemplates = require("constants").groundTemplates
local Map = require("map")
local isCounterClockwise = require("helpers").isCounterClockwise --Load helper functions
local normalizeAngle = require("helpers").normalizeAngle --Load helper functions
local angularDistance = require("helpers").angularDistance --Load helper functions

local ControlZones = {}
ControlZones.__index = ControlZones

function ControlZones.new(namedZones, groundTemplates)
    local self = setmetatable({}, ControlZones)
    if not namedZones then
        self.allZones = {}      --array of names of zones
        self.zonesByName = {}   --full zone details indexed by zone name
        self.zoneCheckCounter = 1 --zone to be considered by next scheduled ownership check
        self.owner = {}
        self.neighbors = {}
        self.edges = {}
        self.perimeter = {}
        self.front = {
            blue = {},
            red = {}
        }
        self.depthMap = {
            blue = {},
            red = {}
        }
    else
        -- self.zonesByName = namedZones
        --put keys into allZones
    end
    self.maxima = nil
    self.groupCounter = 0
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
    self.centroid = {}
    return self
end

function ControlZones:getNewGroupId()
    --char(65) = A, char(90) = Z
    local alpha = string.char(65 + (self.groupCounter % 26))
    local id = string.rep(alpha, 1 + self.groupCounter / 26)
    self.groupCounter = self.groupCounter + 1
    return id
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
    self.centroid["blue"] = self:centroidOfZones(self:getCluster("blue"))
    self.centroid["red"] = self:centroidOfZones(self:getCluster("red"))

    self.timerId = mist.scheduleFunction(
        ControlZones.checkOwnership,
        {self},
        timer.getTime() + 20,
        2 --every two seconds
    )
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

function ControlZones:changeZoneOwner(name, newOwner)
    local formerOwner = self.owner[name]
    if newOwner == formerOwner then
        env.info("Warning: zone not changed, "..newOwner.." already controls "..name)
        return false
    end
    self.owner[name] = newOwner
    env.info("<<<<<<>>>>>>> Control change: "..name.." switched from "..formerOwner.." to "..newOwner)

    self.map:redrawZone(name, newOwner, self:getZone(name).point)
    if formerOwner ~= "neutral" then
        self:recalculateGeometry(formerOwner)
        for i, front in pairs(self.front[formerOwner]) do
            self.map:drawFrontline(front.points, formerOwner, i == 1, front.isLoop)
        end
    end
    if newOwner ~= "neutral" then
        self:recalculateGeometry(newOwner)
        for i, front in pairs(self.front[newOwner]) do
            self.map:drawFrontline(front.points, newOwner, i == 1, front.isLoop)
        end
    end
end

function ControlZones:checkOwnership()
    local zoneName = self.allZones[self.zoneCheckCounter]
    self:updateZoneOwner(zoneName)

    self.zoneCheckCounter = self.zoneCheckCounter + 1
    if self.zoneCheckCounter > #self.allZones then self.zoneCheckCounter = 1 end
end

function ControlZones:updateZoneOwner(zoneName)
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
                local roadDistance = roadPath and mist.getPathLength(roadPath) or 10*distance
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
    local fronts = {}

    -- Find any isolated zones (no friendly neighbors)
    local ownZones = self:getCluster(color)
    for _, zone in pairs(ownZones) do
        local friendlyNeighbors = self:getNeighbors(zone, color, false)
        if #friendlyNeighbors == 0 then
            local segment = {
                zones = {zone},
                points = {},
                length = nil,
                isLoop = true,
            }
            local pt = self:getZone(zone).point
            local eighth = math.pi/4
            for i=1,8 do
                table.insert(segment.points, {center = pt, heading = i*eighth})
            end
            table.insert(segment.points, {center = pt, heading = eighth})

            table.insert(fronts, segment)
        end
    end

    local edges = self:getPerimeterEdges(color)

    if #edges == 0 then return fronts end
    local globalVisited = {}

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
        local prevOnPerimeter = false

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
                else --enemy neighbor, record heading
                    lastEnemy = neighbor
                    local enemyHeading = self:getHeading(current, neighbor)
                    table.insert(segment.points, {center = z.point, heading = enemyHeading})
                end
            end

            if nextFriendlyZone and frontZones[nextFriendlyZone] then --end if not on frontline (not facing enemy)
                local currentOnPerimeter = table.contains(self.perimeter, current)
                if currentOnPerimeter and prevOnPerimeter and globalVisited[nextFriendlyZone] then
                    foundNext = false
                elseif currentOnPerimeter and nextFriendlyZone == startKey then
                    foundNext = false
                else
                    foundNext = true
                    prevOnPerimeter = currentOnPerimeter
                    prev = current
                    current = nextFriendlyZone
                end
            end
        until (current == startKey) or not foundNext

        if current == startKey then
            -- make a final, extra line back to original zone, offset toward shared enemy neighbor
            if not table.contains(self.perimeter, current) then
                segment.isLoop = true
            end
            if lastEnemy then
                local lastPoint = self:getZone(current).point
                local enemyHeading = mist.utils.getHeadingPoints(lastPoint, self:getZone(lastEnemy).point)
                table.insert(segment.points, {center = lastPoint, heading = enemyHeading})
            end
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

    self.front[color] = fronts

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
        local zone = self:getZone(zonename)
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

function ControlZones:calculateDepthMap(color)
    local depthMap = {}
    local queue = {}
    local maxDepth = 0

    for _, zoneName in ipairs(self:getPerimeterZones(color)) do
        if not depthMap[zoneName] then
            depthMap[zoneName] = 0
            table.insert(queue, zoneName)
        end
    end

    local head = 1
    while head <= #queue do
        local current = queue[head]
        head = head + 1
        for _, neighbor in ipairs(self:getNeighbors(current, color)) do
            if not depthMap[neighbor] then
                depthMap[neighbor] = depthMap[current] + 1
                if depthMap[neighbor] > maxDepth then maxDepth = depthMap[neighbor] end
                table.insert(queue, neighbor)
            end
        end
    end

    self.depthMap[color] = depthMap
    return maxDepth
end

function ControlZones:selectZonesAtDepth(color, targetDepth)
    local result = {}
    for zoneName, depth in pairs(self.depthMap[color]) do
        if depth == targetDepth then
            table.insert(result, zoneName)
        end
    end
    return result
end

-- Returns a random point on the edge between two adjacent zones of the given depth.
-- Pass an optional bias (0-1) to weight t toward the midpoint; default 0 = uniform.
function ControlZones:randomPointOnEdgeAtDepth(color, targetDepth, bias)
    local eligibleEdges = self:edgesAtDepth(color, targetDepth)
    if #eligibleEdges == 0 then return nil end

    local edge = eligibleEdges[math.random(#eligibleEdges)]
    return self:randomPointOnEdge(edge, bias)
end

function ControlZones:edgesAtDepth(color, targetDepth)
    local zones = self:selectZonesAtDepth(color, targetDepth)

    -- Collect all edges where both endpoints are at targetDepth
    local eligibleEdges = {}
    for i = 1, #zones do
        for j = i + 1, #zones do
            local edge = self:getEdge(zones[i], zones[j])
            if edge then
                table.insert(eligibleEdges, edge)
            end
        end
    end

    return eligibleEdges
end

function ControlZones:randomPointOnEdge(e, bias)
    local t = math.random()
    if bias and bias > 0 then
        -- blend toward 0.5 by the bias factor
        t = t + bias * (0.5 - t)
    end

    return {
        x = e.p1.x + t * (e.p2.x - e.p1.x),
        y = e.p1.z + t * (e.p2.z - e.p1.z), --yes, this is awful, but edges use Vec3 coords
    }
end

-- Selects up to targetCount points from candidates using farthest-point sampling,
-- guaranteeing maximum spread. Each pick is the candidate farthest from all
-- already-selected points. Stops early if the next-best candidate is closer than
-- minSeparation (optional). Accepts and returns tables of {x, y} points.
function ControlZones:farthestPointSample(candidates, targetCount, minSeparation)
    if #candidates == 0 then return {} end
    targetCount = math.min(targetCount, #candidates)

    local selected = {}
    local used = {}

    local firstIdx = math.random(#candidates)
    table.insert(selected, candidates[firstIdx])
    used[firstIdx] = true

    while #selected < targetCount do
        local bestIdx = nil
        local bestDist = -1

        for i, candidate in ipairs(candidates) do
            if not used[i] then
                local minDist = math.huge
                for _, sel in ipairs(selected) do
                    local dx = candidate.x - sel.x
                    local dy = candidate.y - sel.y
                    local d = math.sqrt(dx * dx + dy * dy)
                    if d < minDist then minDist = d end
                end
                if minDist > bestDist then
                    bestDist = minDist
                    bestIdx = i
                end
            end
        end

        if not bestIdx then break end
        if minSeparation and bestDist < minSeparation then break end

        table.insert(selected, candidates[bestIdx])
        used[bestIdx] = true
    end

    return selected
end

-- Returns triangles where all three vertices fall within [minDepth, maxDepth].
-- Triangles spanning the boundary of that range (e.g. vertices at depth 1 and 2)
-- produce points that interpolate between those depths, naturally landing in the
-- Goldilocks zone without needing a separate containment check.
function ControlZones:selectTrianglesByDepthRange(color, minDepth, maxDepth)
    local result = {}
    local depthMap = self.depthMap[color]
    if not depthMap then return result end

    for _, tri in ipairs(self.triangles) do
        local d1 = depthMap[tri[1]]
        local d2 = depthMap[tri[2]]
        local d3 = depthMap[tri[3]]
        if d1 and d2 and d3
            and d1 >= minDepth and d1 <= maxDepth
            and d2 >= minDepth and d2 <= maxDepth
            and d3 >= minDepth and d3 <= maxDepth then
            table.insert(result, tri)
        end
    end
    return result
end

-- Returns a uniformly-distributed random point inside a triangle defined by zone names.
-- Uses the sqrt(r1) formula to avoid the non-uniform clustering near the centroid
-- that results from the naive barycentric approach.
function ControlZones:randomPointInTriangle(tri)
    local p1 = self:getZone(tri[1]).point
    local p2 = self:getZone(tri[2]).point
    local p3 = self:getZone(tri[3]).point
    local r1 = math.sqrt(math.random())
    local r2 = math.random()
    return {
        x = (1 - r1) * p1.x + r1 * (1 - r2) * p2.x + r1 * r2 * p3.x,
        y = (1 - r1) * p1.z + r1 * (1 - r2) * p2.z + r1 * r2 * p3.z,
    }
end

function ControlZones:recalculateGeometry(color)
    env.info(".. recalculating geometry for "..color)
    self:getOrderedFrontlines(color)
    self:calculateDepthMap(color)
end

function ControlZones:spawnFARP(color, pt)
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
            -- "UH-60L",
            "OH-6A",
            "AH-6J",
            "OH-58D",
            -- "SA342L",
            -- "SA342M",
            -- "SA342Minigun",
            -- "SA342Mistral",
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
        -- env.info("-> Orienting units in"..zoneName..": "..mist.utils.toDegree(heading))
    else
        heading =  mist.utils.getHeadingPoints(self.centroid[self.owner[zoneName]], self.centroid[opponent])
        env.info("!? could not find nearestEnemy ("..zoneName.." might not be frontline zone?)")
    end
    return heading
end

function ControlZones:spawnStaticInZone(groupName, zoneName, color, template, heading)
    local zn = self:getZone(zoneName)

    local searchRadius = zn.radius
    local clearRadius = 15
    -- heavy calculation? improve performance; get single, larger spot to speed up?
    local spots = Disposition.getSimpleZones(zn.point, searchRadius, clearRadius, 1)

    if not spots or #spots < 1 then
        env.info("!! coundn't spawn garrison for "..zoneName)
        return false
    end

    local vars = {
        type = template, --"Airshow_Crowd",
        country = color == "blue" and "USA" or "USSR",
        category = "Unarmed",
        x = spots[1].x,
        y = spots[1].y,
        name = groupName,
        heading = heading
    }
    local newGroup = mist.dynAddStatic(vars)

    return newGroup --groupName
end

function ControlZones:spawnGroupAtPoint(groupName, point, color, template, heading)
    local unitSet = {}

    local searchRadius = 500
    local clearRadius = 50
    -- heavy calculation? improve performance; get single, larger spot to speed up?
    local spots = Disposition.getSimpleZones(point, searchRadius, clearRadius, #template)

    if #spots < #template then
        env.info("!! not enough spots for spawning all units of "..groupName..". spots found: "..#spots.." of "..#template)
        return nil
    end

    for j, unitName in pairs(template) do
        local variance = math.random(-4, 4)/10
        local hdg = heading + variance
        table.insert(unitSet, j, { type = unitName, x = spots[j].x, y = spots[j].y, heading = hdg})
    end
    local newGroup = mist.dynAdd({ -- mist.dynAddStatic()
        groupName = groupName,
        units = unitSet,
        country = color == "blue" and "USA" or "Russia",
        category = "vehicle",
    })

    return groupName
end

function ControlZones:spawnGroupInZone(groupName, zoneName, color, template, heading)
    local zn = self:getZone(zoneName)
    return self:spawnGroupAtPoint(groupName, zn.point, color, template, heading)
end

function ControlZones:fillFrontGaps(front, color)
    if #front.zones < 2 then
        return {}
    end

    local midpoints = {}
    local MAX_FRONT_GAP = 6000
    local avgHeading =  mist.utils.getHeadingPoints(self.centroid[color], self.centroid[self:getOpponent(color)])

    for i=2, #front.zones do
        local edge = self:getEdge(front.zones[i], front.zones[i-1])
        -- if edge.crosscountry
        if edge.distance.straight > MAX_FRONT_GAP then
            local pt = self:randomPointOnEdge(edge, 0.7)

            local r = math.random(#groundTemplates)
            local template = groundTemplates[color][r]

            table.insert(midpoints, pt)
            self:spawnGroupAtPoint("mid_"..math.random(1000,9000), mist.utils.makeVec3(pt), color, template, avgHeading)
        end
    end

    env.info("padded gaps in frontline: "..#midpoints)
    env.info(mist.utils.tableShow(midpoints))
    return midpoints
end

function ControlZones:spawnFrontlineForces(front, color)
    local reserves = {}
    local avgHeading =  mist.utils.getHeadingPoints(self.centroid[color], self.centroid[self:getOpponent(color)])
    local templates = groundTemplates[color]

    local MAX_FRONT_GAP = 6000
    local MAX_GROUPS_PER_ZONE = 2

    for i, zoneName in ipairs(front.zones) do
        local heading = self:orientToClosestEnemy(zoneName)
        for _ = 1, math.random(MAX_GROUPS_PER_ZONE) do
            local groupName = color.."-"..zoneName.."-"..self:getNewGroupId()
            self:spawnGroupInZone(groupName, zoneName, color, templates[math.random(#templates)], heading)
            table.insert(reserves, groupName)
        end

        if i > 1 then
            local edge = self:getEdge(zoneName, front.zones[i-1])
            if edge.distance.straight > MAX_FRONT_GAP then
                local groupName = color.."-".."midway-"..self:getNewGroupId()
                env.info("Adding group "..groupName.." between zones "..zoneName..front.zones[i-1])
                self:spawnGroupAtPoint(groupName, mist.utils.makeVec3(self:randomPointOnEdge(edge, 0.7)), color, templates[math.random(#templates)], avgHeading)
                table.insert(reserves, groupName)
            end
        end
    end

    return reserves
end
function ControlZones:garrisonZones(zones, color)
    -- on first pass spawn basic template to hold zone,
    local type = garrisonTemplates[color]
    local avgHeading =  mist.utils.getHeadingPoints(self.centroid[color], self.centroid[self:getOpponent(color)])
    for _, zoneName in pairs(zones) do
        -- Static vehicle units are more suited to the limited requirements of garrison forces
        -- but commanded dynamic units don't respond to them by default
        -- self:spawnStaticInZone(zoneName.." garrison", zoneName, color, type, avgHeading)
        self:spawnGroupInZone(zoneName.." garrison", zoneName, color, type, avgHeading)
    end
end

function ControlZones:placeFARPs(color)
    local MIN_FARP_SEPARATION = 9000
    local SETBACK_DISTANCE = 4000

    -- primary: place FARPs in depth 1-2 triangle interiors
    local candidates = {}
    local farpPoints = {}
    local tris = self:selectTrianglesByDepthRange(color, 1, 2)
    for _, tri in pairs(tris) do
        table.insert(candidates, self:randomPointInTriangle(tri))
    end
    -- local farpPoints = self:farthestPointSample(candidates, #candidates, MIN_FARP_SEPARATION)

    -- ensure the side gets at least 1 FARP
    if #candidates == 0 then
        env.info(".......... falling back to alternate FARP placement")
        local heading = mist.utils.getHeadingPoints(self.centroid[self:getOpponent(color)], self.centroid[color])

        -- fallback: offset a point on a depth-1 edge outward past the perimeter
        -- self:edgesAtDepth(color, 1)
        -- self:selectZonesAtDepth(color, 1)
        local pt1 = self:randomPointOnEdgeAtDepth(color, 1)
        local zns = self:selectZonesAtDepth(color, 1)
        if pt1 then
            env.info(".......... edge depth-1")
            local offset1 = mist.projectPoint(pt1, SETBACK_DISTANCE, heading)
            table.insert(farpPoints, offset1)
        elseif #zns then
            env.info(".......... zone depth-1")
            local pt = self:getZone(zns[1]).point
            local offset1 = mist.projectPoint(pt, SETBACK_DISTANCE, heading)
            table.insert(farpPoints, offset1)
        else
            -- self:edgesAtDepth(color, 0)
            local pt0 = self:randomPointOnEdgeAtDepth(color, 0)

            if pt0 then
                env.info(".......... edge depth-0")
                local offset0 = mist.projectPoint(pt0, SETBACK_DISTANCE, heading)
                table.insert(farpPoints, offset0)
            else
                env.info("!! no viable FARP placement found for "..color)
            end
        end
    else
        farpPoints = self:farthestPointSample(candidates, #candidates, MIN_FARP_SEPARATION)
    end

    env.info(".......... "..#candidates.." potential FARP placement points found, narrowed down to "..#farpPoints)
    for _, pt in pairs(farpPoints) do
        self:spawnFARP(color, pt)
    end
end

function ControlZones:kickoff()
    local zoneInfo = {}
    for name, color in pairs(self.owner) do
        zoneInfo[name] = {color = color, point = self:getZone(name).point}
    end
    self.map:drawZones(zoneInfo)
    self.map:drawEdges(self:getAllEdges())
    for color, cmd in pairs(self.commanders) do
        self:garrisonZones(self:getCluster(color), color)

        local fronts = self:getOrderedFrontlines(color)
        self:calculateDepthMap(color)

        self:placeFARPs(color)

        -- draw frontlines
        for i, front in pairs(fronts) do
            self.map:drawFrontline(front.points, color, false, front.isLoop)

            local reserves = self:spawnFrontlineForces(front, color)
            cmd:addReserves(reserves)
        end
    end

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

return {
    isCounterClockwise = isCounterClockwise,
    normalizeAngle = normalizeAngle,
    angularDistance = angularDistance
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

function Map:removeMarks(markIds)
    if not markIds then return end
    for _, id in pairs(markIds) do
        trigger.action.removeMark(id)
    end
end

function Map:placeMarker(text, color, pt)
    if not settings.draw.zones then return end
    local sides = self:getVisibility(color, "zones")
    local labels = {}
    for _, side in pairs(sides) do
        -- local markerId = self:getNewMarker()
        -- trigger.action.circleToAll(side, zoneId, pt, 510, {0,0,0,0.2}, rgb[color], 1)
        local labelId = self:getNewMarker()
        table.insert(labels, labelId)
        trigger.action.textToAll(side, labelId, pt, {0.7,0,0.7,1}, {0,0,0,0.2}, 15, true, text)
    end
    return labels
end

function Map:drawPolygon(points)
    local mk = mist.marker.add({
        pos = points,
        -- name = "",
        markType = "freeform", --7
        markForCoa = -1, --?
        color = {1,1,0,0.5},
        fillColor = {1,1,0,0.2},
        lineType = 1 --1 Solid, 2 Dashed, 3 Dotted, 4 Dot Dash, 5 Long Dash
    })
    return mk.markId --mist helper returns whole table; we want ID only
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

function Map:drawFrontline(points, color, erasePrevious, isLoop)
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
        local lineColor = rgb[color]
        for _, data in pairs(points) do
            local lineId1 = self:getNewMarker()
            local lineId2 = self:getNewMarker()
            table.insert(self.markers.front[color], lineId1)
            table.insert(self.markers.front[color], lineId2)
            local point1 = mist.projectPoint(data.center, OFFSET, data.heading)
            local point2 = mist.projectPoint(data.center, OFFSET+200, data.heading)
            if firstPass then
                if not isLoop then
                    prevPts[1] = mist.projectPoint(point1, OFFSET, data.heading - math.pi/2)
                    prevPts[2] = mist.projectPoint(point2, OFFSET, data.heading - math.pi/2)
                    trigger.action.lineToAll(side, lineId1, prevPts[1], point1, lineColor, 1)
                    trigger.action.lineToAll(side, lineId2, prevPts[2], point2, lineColor, 1)
                end
            else
                trigger.action.lineToAll(side, lineId1, prevPts[1], point1, lineColor, 1)
                trigger.action.lineToAll(side, lineId2, prevPts[2], point2, lineColor, 1)
            end
            prevPts[1] = point1
            prevPts[2] = point2
            firstPass = false
        end
        if not isLoop then
            local finalPt1 = mist.projectPoint(prevPts[1], OFFSET, points[#points].heading + math.pi/2)
            local finalPt2 = mist.projectPoint(prevPts[2], OFFSET, points[#points].heading + math.pi/2)
            local lineId1 = self:getNewMarker()
            local lineId2 = self:getNewMarker()
            table.insert(self.markers.front[color], lineId1)
            table.insert(self.markers.front[color], lineId2)
            trigger.action.lineToAll(side, lineId1, prevPts[1], finalPt1, lineColor, 1)
            trigger.action.lineToAll(side, lineId2, prevPts[2], finalPt2, lineColor, 1)
        end
    end
end

function Map:drawDirective(originPoint, targetPoint, color)
    if not settings.draw.directives then return end
    local Ids = {}
    local sides = self:getVisibility(color, "directives")
    for _, side in pairs(sides) do
        local nextId = self:getNewMarker()
        local lineColor = {1,1,0.2,0.2}
        -- lineColor[4] = 0.2
        lineColor = {rgb[color][1], rgb[color][2], rgb[color][3], 0.2}
        local fillColor = lineColor
        local heading = mist.utils.getHeadingPoints(originPoint, targetPoint)
        local reciprocal = mist.utils.getHeadingPoints(targetPoint, originPoint)
        local distance = 1000
        local lineStart = mist.projectPoint(originPoint, distance+200, heading)
        local arrowEnd = mist.projectPoint(targetPoint, distance, reciprocal)
        trigger.action.arrowToAll(side, nextId, arrowEnd, lineStart, lineColor, fillColor, 1)
        table.insert(Ids, nextId)
    end
    return Ids
end
function Map:drawArrow(originPoint, targetPoint, color)
    if not settings.draw.directives then return end
    local Ids = {}
    local sides = self:getVisibility(color, "directives")
    for _, side in pairs(sides) do
        local nextId = self:getNewMarker()
        -- lineColor = {0.7,0.7,0.7,0.15}
        -- local lineColor = {rgb[color][1], rgb[color][2], rgb[color][3], 0.08}
        local lineColor = {(0.7 + rgb[color][1])/2, (0.7 + rgb[color][2])/2, (0.7 + rgb[color][3])/2, 0.15}
        local fillColor = lineColor
        trigger.action.arrowToAll(side, nextId, targetPoint, originPoint, lineColor, fillColor, 1)
        table.insert(Ids, nextId)
    end
    return Ids
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
        groupOrders = true,
        objectives = true,
    },
    displayToAll = {
        zones = true,
        frontlines = true,
        directives = true,
        groupOrders = false,
        objectives = false,
    }
}

return settings
end)
__bundle_register("coalition-commander", function(require, _LOADED, __bundle_register, __bundle_modules)
-- aka Strategic Commander

-- local constants = require("constants")
local GroupCommander = require("group-commander")
-- local GroupProfiler = require("group-profiler")
local OperationalCommander = require("operational-commander")
local OODACommander = require("ooda-commander")
local Objective = require("objective")
-- local Order = require("order")
-- local OrderCoordinator = require("order-coordinator")
-- local ReconRallyAssaultPlan = require("doctrines.operational.recon-rally-assault-plan")
local CommanderVisualizer = require("commander-visualizer")
local SpatialAgent = require("spatial-agent")
-- local ThreatTracker = require("threat-tracker")

-- local alr = constants.acceptableLevelsOfRisk
-- local orderStatus = constants.orderStatus
-- local taskTypes = constants.taskTypes
-- local dispositionTypes = constants.dispositionTypes

local taskTypes = require("constants").taskTypes
local statusTypes = require("constants").statusTypes

local CoalitionCommander = {}
setmetatable(CoalitionCommander, {__index = OODACommander})
CoalitionCommander.__index = CoalitionCommander

local oodaInterval = 45.0 -- seconds

function CoalitionCommander.new(parent, config)
    local self = OODACommander.new({interval = oodaInterval})
    setmetatable(self, CoalitionCommander)
    self.map = parent
    self.coalition = config.color
    self.color = config.color
    self.opponent = config.color == "blue" and "red" or "blue"
    self.templates = config.groundTemplates
    self.groupId = 1
    self.groups = {} -- e.g. name location task
    self.reserves = {}
    self.groupsByZone = {}
    for _, name in pairs(self.map.allZones) do
        self.groupsByZone[name] = {}
    end
    self.groupsByTask = {}
    for i, j in pairs(taskTypes) do
        self.groupsByTask[j] = {}
    end
    self.opscoms = {}
    self.visualizer = CommanderVisualizer.new(self.map.map)
    self.operations = {
        active = {},
        history = {},
        group = nil,
        status = nil,
    }
    -- attitude/aggressiveness = offensive, defensive, cautious, etc
    return self
end


function CoalitionCommander:addReserves(groups)
    -- self.reserves = groups
    for _, groupName in pairs(groups) do
        local gc = GroupCommander.new(groupName, {
            color = self.color,
            visualizer = self.visualizer,
        })
        table.insert(self.reserves, gc)
    end
end

-- DEPRECATED
-- A preliminary phase to allow commander to choose group templates for all front zones
-- (random for now, TODO apply some strategy to placement of different types)
function CoalitionCommander:initiate(front)
    local reinforcements = {}
    for _, zoneName in pairs(front.zones) do
        for i = 1, math.random(2) do
            local r = math.random(#self.templates)
            local group = self.templates[r]
            local groupName = zoneName.."-"..self:getNewGroupId()
    
            local gc = GroupCommander.new(groupName, {
                color = self.color,
                visualizer = self.visualizer,
            })
            table.insert(self.reserves, gc)

            local groupData = {
                groupName = groupName,
                template = group
            }
            table.insert(reinforcements[zoneName], groupData)
        end
    end

    return reinforcements
end

-- NOTE: Doctrine usage example:
-- To assign a specific strategy to an objective, create the Doctrine and assign it:
--   local objective = Objective.new({...})
--   objective.doctrine = ReconRallyAssaultPlan.new(commanderName, config)
-- The OperationalCommander will use the Doctrine in its DECIDE phase.
-- If no Doctrine is assigned, it defaults to ReconRallyAssaultPlan.
function CoalitionCommander:observe()
    -- Prune destroyed groups from reserves
    local surviving = {}
    for _, gc in ipairs(self.reserves) do
        if gc.destroyed then
            self.visualizer:release("group:" .. gc.groupName)
        else
            table.insert(surviving, gc)
        end
    end
    self.reserves = surviving

    env.info(string.format("****** %s StratCom OBSERVE: blue=%d red=%d zones | reserves=%d | opscoms=%d",
        self.color,
        #self.map:getCluster("blue"),
        #self.map:getCluster("red"),
        #self.reserves,
        #self.opscoms))
end

function CoalitionCommander:orient()
    -- TODO compare current state to previous to extract trends (force strength, territorial control, etc)
    -- Consider observed threats and stalled operations / requests for reinforcements
    -- Identify opscoms whose objective is complete or failed
    self.opscoms_to_disband = {}
    local activeCount = 0
    for i, opscom in ipairs(self.opscoms) do
        local objective = opscom.orderCoordinator.objectives[1]
        if objective and objective:isComplete() then
            table.insert(self.opscoms_to_disband, i)
        else
            activeCount = activeCount + 1
        end
    end

    -- If no active opscoms will remain after disbanding, and reserves are available, find a new target
    -- TODO Select target based on knowledge of enemy strength or outcome of past operations
    self.pending_target = nil
    if activeCount == 0 and #self.reserves > 0 then
        local ownZones = self.map:getCluster(self.color)
        for _, zoneName in ipairs(ownZones) do
            local enemyNeighbors = self.map:getNeighbors(zoneName, self.opponent, true)
            if enemyNeighbors and #enemyNeighbors > 0 then
                local target = enemyNeighbors[math.random(#enemyNeighbors)]
                self.pending_target = {
                    zoneName = target,
                    position = self.map:getZone(target).point,
                }
                break
            end
        end
    end
end

function CoalitionCommander:decide()
    -- Disband completed opscoms (iterate in reverse to safely remove by index)
    table.sort(self.opscoms_to_disband, function(a, b) return a > b end)
    for _, i in ipairs(self.opscoms_to_disband) do
        local opscom = self.opscoms[i]
        self.visualizer:release("opscom:" .. opscom.name)
        self.visualizer:release(self.color .. "_movement")
        local survivors = opscom:disband()
        for _, gc in ipairs(survivors) do
            -- This could be a good point to check residual gc doctrine and orders,
            -- to see if they are still appropriate or should be removed
            table.insert(self.reserves, gc)
        end
        table.remove(self.opscoms, i)
        env.info(string.format("****** %s StratCom ACT: disbanded opscom, %d groups returned to reserves",
            self.color, #survivors))
    end

    -- Select groups from reserves by proximity to the pending target
    -- TODO Balance proximity and suitability for type of operation
    self.pending_groups = {}
    if self.pending_target then
        local maxGroups = 3
        local candidates = {}
        for _, gc in ipairs(self.reserves) do
            local status = gc:getStatus()
            if status.position then
                table.insert(candidates, {
                    gc = gc,
                    dist = SpatialAgent.distance2D(status.position, self.pending_target.position),
                })
            end
        end
        table.sort(candidates, function(a, b) return a.dist < b.dist end)
        for i = 1, math.min(maxGroups, #candidates) do
            table.insert(self.pending_groups, candidates[i].gc)
        end
    end
end

function CoalitionCommander:act()
    -- Create a new opscom if a target and groups are ready
    if self.pending_target and #self.pending_groups > 0 then
        -- Remove assigned groups from reserves
        for _, gc in ipairs(self.pending_groups) do
            for i, reserveGc in ipairs(self.reserves) do
                if reserveGc == gc then
                    table.remove(self.reserves, i)
                    break
                end
            end
        end

        local opscom = OperationalCommander.new({
            color = self.color,
            groupCommanders = self.pending_groups,
            visualizer = self.visualizer,
        })
        opscom.orderCoordinator.objectives = {
            Objective.new({
                type = taskTypes.ASSAULT,
                position = self.pending_target.position,
                radius = 500,
            })
        }
        table.insert(self.opscoms, opscom)
        env.info(string.format("****** %s StratCom ACT: created opscom → targeting %s with %d groups",
            self.color, self.pending_target.zoneName, #self.pending_groups))
        -- draw polygon around units and directive arrow at creation
        self.visualizer:syncOpscom(opscom, self.color)
    end

    -- Keep each active opscom's outline/directive marks in sync with current tasking
    -- for _, opscom in ipairs(self.opscoms) do
    --     self.visualizer:syncOpscom(opscom, self.color)
    -- end
end


-- ============================================================================
-- HELPER METHODS
-- ============================================================================

function CoalitionCommander:getNewGroupId()
    self.groupId = self.groupId + 1
    return self.groupId
end

return CoalitionCommander

end)
__bundle_register("commander-visualizer", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local settings = require("settings")
local rgb = constants.rgb
local normalizeAngle = require("helpers").normalizeAngle --Load helper functions
local angularDistance = require("helpers").angularDistance --Load helper functions

local taskTypeNames = {}
for name, value in pairs(constants.taskTypes) do
    taskTypeNames[value] = name
end

-- Reconciles commander state (orders, dispositions, objectives, opscom tasking)
-- onto persistent map marks. Owns a registry of {signature, markIds} keyed by a
-- stable string per drawable thing, so unchanged state is a no-op and changed
-- state erases the old marks before drawing new ones.
local CommanderVisualizer = {}
CommanderVisualizer.__index = CommanderVisualizer

function CommanderVisualizer.new(map)
    local self = setmetatable({}, CommanderVisualizer)
    self.map = map
    self.registry = {}
    return self
end

-- Draw/update the marks for `key` only if `signature` differs from what's
-- currently registered. `drawFn` is called (with no args) only when a redraw
-- is needed, and must return a list of mark ids.
function CommanderVisualizer:upsert(key, signature, drawFn)
    local entry = self.registry[key]
    if entry and entry.signature == signature then
        return
    end
    if entry then
        self.map:removeMarks(entry.markIds)
    end
    local markIds = drawFn() or {}
    self.registry[key] = { signature = signature, markIds = markIds }
end

-- Erase any marks registered for `key`, if present.
function CommanderVisualizer:release(key)
    local entry = self.registry[key]
    if not entry then return end
    self.map:removeMarks(entry.markIds)
    self.registry[key] = nil
end

-- Draw/update a label at a group's position showing its current order type
-- and disposition, or release the label if the group has no active order.
function CommanderVisualizer:syncGroupOrder(gc, color)
    local key = "group:" .. gc.groupName

    if not gc.orders then
        self:release(key)
        return
    end

    local position = gc:getOwnPosition()
    if not position then
        self:release(key)
        return
    end

    local orderTypeName = taskTypeNames[gc.orders.type] or tostring(gc.orders.type)
    local groupDoctrineName = (gc.doctrine and gc.doctrine.name .. ":" .. gc.doctrine.currentPhaseName) or "?"
    local threatText = "" .. gc.threatAssessment.count .. "x threats for " .. math.floor(gc.threatAssessment.favorability * 10) / 10
    -- local text = gc.groupName .. "\n" .. groupDoctrineName .. "\n" .. orderTypeName
    local text = gc.groupName .. "\n" .. groupDoctrineName .. " [" .. (gc.disposition or "__") .. "]\n" .. threatText
    local roundedPos = math.floor(position.x / 50) .. "," .. math.floor(position.z / 50)
    local signature = table.concat({orderTypeName, gc.disposition, gc.orders.status, threatText, roundedPos}, "|")

    self:upsert(key, signature, function()
        if not settings.draw.groupOrders then return {} end
        local markIds = {}
        local sides = self.map:getVisibility(color, "groupOrders")
        for _, side in pairs(sides) do
            local labelId = self.map:getNewMarker()
            table.insert(markIds, labelId)
            trigger.action.textToAll(side, labelId, mist.projectPoint(position, 100, math.pi), {1,1,1,0.8}, {0,0,0,0.3}, 12, true, text)
        end
        return markIds
    end)
end

function CommanderVisualizer:initMovementMapper(color)
    -- create key that will collect mark ids for all group movement arrows for current objective
    local key = color .. "_movement"

    -- initial entry is empty
    if not self.registry[key] then
        self.registry[key] = { signature = "_", markIds = {} }
    end
end

-- Draw and persist arrows showing each time a group changes its intended destination 
function CommanderVisualizer:appendGroupMove(gc, color)
    local key = color .. "_movement"
    local entry = self.registry[key]
    if not entry or not gc.orders then
        -- self:release(key)
        return
    end

    local position = gc:getOwnPosition()
    if not position then
        -- self:release(key)
        return
    end

    local arrowIds = self.map:drawArrow(position, gc.destination, color)
    if arrowIds then
        for _, mk in pairs(arrowIds) do
            table.insert(self.registry[key].markIds, mk)
        end
    end
end

-- Draw/update a circle + label at an objective's position showing its task
-- type and status.
function CommanderVisualizer:syncObjective(objective, doctrine, color)
    local key = "objective:" .. tostring(objective)

    if objective:isComplete() then
        self:release(key)
        return
    end

    local typeName = taskTypeNames[objective.type] or tostring(objective.type)
    local orderCounts = {}
    for k, v in pairs(objective:getOrderStatusCounts()) do
        orderCounts[k] = tostring(v)
    end
    local objectiveOrders = "Assg:" .. orderCounts.assigned .. " Act:" .. orderCounts.inProgress .. " Dn:" .. orderCounts.completed .. " X:" .. orderCounts.aborted
    local text = doctrine.name .. ":" ..  doctrine.currentPhaseName .. "\n" .. typeName .. " (" .. objective.status .. ") [" .. objectiveOrders .. "]"
    local signature = table.concat({typeName, objective.status, objective.radius, doctrine.name, doctrine.currentPhaseName, objectiveOrders}, "|")

    self:upsert(key, signature, function()
        if not settings.draw.objectives then return {} end
        local markIds = {}
        local sides = self.map:getVisibility(color, "objectives")
        for _, side in pairs(sides) do
            local circleId = self.map:getNewMarker()
            table.insert(markIds, circleId)
            trigger.action.circleToAll(side, circleId, objective.position, objective.radius+300, rgb[color], {0,0,0,0}, 3)
            local labelId = self.map:getNewMarker()
            table.insert(markIds, labelId)
            trigger.action.textToAll(side, labelId, mist.projectPoint(objective.position, 850, math.pi/2), {1,1,1,1}, {0,0,0,0.3}, 13, true, text)
        end
        return markIds
    end)
end

-- Draw/update the outline of tasked groups and directive arrows from each
-- group to the opscom's objective.
function CommanderVisualizer:syncOpscom(opscom, color)
    local key = "opscom:" .. opscom.name

    local objective = opscom.orderCoordinator.objectives[1]
    if not objective then
        self:release(key)
        return
    end

    local groupNames = {}
    local points = {}
    local polygon = {}
    -- Calculate centroid of allied positions
    local alliedCenterX = 0
    local alliedCenterZ = 0
    local center = { x = 0, y = 0, z = 0 }
    local validCount = 0
    for _, gc in ipairs(opscom.groupCommanders) do
        local position = gc:getOwnPosition()
        if position then
            table.insert(groupNames, gc.groupName)
            table.insert(points, position)
            alliedCenterX = alliedCenterX + position.x
            alliedCenterZ = alliedCenterZ + position.z
            validCount = validCount + 1
        end
    end
    table.sort(groupNames)

    center.x = alliedCenterX / validCount
    center.z = alliedCenterZ / validCount
    -- project points from center to form enclosing polygon
    -- for each point project 2 points away from center +/- 45deg
    for i, data in pairs(points) do
        -- get heading center to data
        local heading = mist.utils.getHeadingPoints(center, data)
        local projectedPoint1 = mist.projectPoint(data, 800, heading + math.pi/4)
        local projectedPoint2 = mist.projectPoint(data, 800, heading - math.pi/4)
        table.insert(polygon, projectedPoint1)
        table.insert(polygon, projectedPoint2)
    end
    -- table.insert(polygon, lastPoint)
    -- sort points
    local initialHeading = 0
    table.sort(polygon, function(a, b)
        local headingA = normalizeAngle(mist.utils.getHeadingPoints(center, a))
        local headingB = normalizeAngle(mist.utils.getHeadingPoints(center, b))
        local arcA = angularDistance(initialHeading, headingA)
        local arcB = angularDistance(initialHeading, headingB)
        return arcA < arcB
    end)

    local signature = table.concat(groupNames, ",") .. "|" .. objective.status

    self:upsert(key, signature, function()
        if #polygon == 0 then return {} end
        local markIds = {}
        -- for _, gc in ipairs(opscom.groupCommanders) do
        -- single arrow for whole operation
            local origin = center --gc:getOwnPosition()
            if origin then
                local arrowIds = self.map:drawDirective(origin, objective.position, color)
                if arrowIds then
                    for _, mk in pairs(arrowIds) do
                        table.insert(markIds, mk)
                    end
                end
            end
        -- end
        local polygonId = self.map:drawPolygon(polygon)
        if polygonId then
            table.insert(markIds, polygonId)
        end
        return markIds
    end)
end

return CommanderVisualizer

end)
__bundle_register("objective", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local taskTypes = constants.taskTypes

-- Objective class for strategic-level goals
-- Each objective may have multiple orders assigned to different groups
-- Tracks overall objective status and completion criteria

local Objective = {}
Objective.__index = Objective

-- Objective status values
local ObjectiveStatus = {
    ACTIVE = "Active",       -- Objective is being pursued
    ACHIEVED = "Achieved",   -- Objective successfully completed
    FAILED = "Failed",       -- Objective could not be completed
    CANCELED = "Canceled",   -- Objective was canceled by strategic commander
}

function Objective.new(config)
    local self = setmetatable({}, Objective)
    
    -- Required fields
    self.type = config.type           -- taskTypes constant (DEFEND, RALLY, etc.)
    self.position = config.position   -- {x, z}
    
    -- Optional fields with defaults
    self.radius = config.radius or 500
    self.deadline = config.deadline   -- nil or timer.getTime() + duration
    
    -- Status tracking
    self.status = ObjectiveStatus.ACTIVE
    self.createdAt = timer.getTime()
    self.updatedAt = timer.getTime()
    self.achievedAt = nil
    self.failedAt = nil
    
    -- Associated orders
    self.orders = {}  -- array of Order objects
    
    return self
end

-- Add an order to this objective
function Objective:addOrder(order)
    table.insert(self.orders, order)
    -- Ensure bidirectional reference
    order.objective = self
    self.updatedAt = timer.getTime()
end

-- Remove an order from this objective
function Objective:removeOrder(order)
    for i, existingOrder in ipairs(self.orders) do
        if existingOrder == order then
            table.remove(self.orders, i)
            self.updatedAt = timer.getTime()
            return true
        end
    end
    return false
end

-- Get counts of orders by status
function Objective:getOrderStatusCounts()
    local counts = {
        assigned = 0,
        inProgress = 0,
        completed = 0,
        aborted = 0,
        total = #self.orders
    }
    
    local orderStatus = constants.orderStatus
    for _, order in ipairs(self.orders) do
        if order.status == orderStatus.ASSIGNED then
            counts.assigned = counts.assigned + 1
        elseif order.status == orderStatus.IN_PROGRESS then
            counts.inProgress = counts.inProgress + 1
        elseif order.status == orderStatus.COMPLETED then
            counts.completed = counts.completed + 1
        elseif order.status == orderStatus.ABORTED then
            counts.aborted = counts.aborted + 1
        end
    end
    
    return counts
end

-- Get all active orders (not completed or aborted)
function Objective:getActiveOrders()
    local active = {}
    for _, order in ipairs(self.orders) do
        if order:isActive() then
            table.insert(active, order)
        end
    end
    return active
end

-- Get all finished orders (completed or aborted)
function Objective:getFinishedOrders()
    local finished = {}
    for _, order in ipairs(self.orders) do
        if order:isFinished() then
            table.insert(finished, order)
        end
    end
    return finished
end

-- Mark objective as achieved
function Objective:markAchieved()
    self.status = ObjectiveStatus.ACHIEVED
    self.achievedAt = timer.getTime()
    self.updatedAt = timer.getTime()
end

-- Mark objective as failed
function Objective:markFailed(reason)
    self.status = ObjectiveStatus.FAILED
    self.failedAt = timer.getTime()
    self.failReason = reason
    self.updatedAt = timer.getTime()
end

-- Returns true if the objective is no longer being actively pursued
function Objective:isComplete()
    return self.status ~= ObjectiveStatus.ACTIVE
end

-- Mark objective as canceled
function Objective:markCanceled()
    self.status = ObjectiveStatus.CANCELED
    self.updatedAt = timer.getTime()
end

-- Get a summary of objective state for reporting
function Objective:getSummary()
    local statusCounts = self:getOrderStatusCounts()
    
    return {
        type = self.type,
        status = self.status,
        position = self.position,
        radius = self.radius,
        createdAt = self.createdAt,
        orderCounts = statusCounts,
        timeSinceCreated = timer.getTime() - self.createdAt,
    }
end

Objective.Status = ObjectiveStatus

return Objective

end)
__bundle_register("operational-commander", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local GroupCommander = require("group-commander")
local GroupProfiler = require("group-profiler")
local OODACommander = require("ooda-commander")
local Order = require("order")
local OrderCoordinator = require("order-coordinator")
local ReconRallyAssaultPlan = require("doctrines.operational.recon-rally-assault-plan")
local SpatialAgent = require("spatial-agent")
local ThreatTracker = require("threat-tracker")

local alr = constants.acceptableLevelsOfRisk
local orderStatus = constants.orderStatus
local taskTypes = constants.taskTypes
local dispositionTypes = constants.dispositionTypes

local OperationalCommander = {}
setmetatable(OperationalCommander, {__index = OODACommander})
OperationalCommander.__index = OperationalCommander

local oodaInterval = 30.0 -- seconds

local function isOrderChanged(lastOrder, newOrder, commanderStatus)
    if not lastOrder then
        return true
    end
    if commanderStatus and commanderStatus.orderStatus then
        if commanderStatus.orderStatus == orderStatus.COMPLETED or
           commanderStatus.orderStatus == orderStatus.ABORTED then
            return true
        end
    end
    if lastOrder.type ~= newOrder.type then
        return true
    end
    if not lastOrder.position then
        return true
    end
    if math.abs(lastOrder.position.x - newOrder.position.x) > 100 or
       math.abs(lastOrder.position.z - newOrder.position.z) > 100 then
        return true
    end
    if lastOrder.radius ~= newOrder.radius then
        return true
    end
    return false
end

function OperationalCommander.new(config)
    -- Initialize parent class (sets up OODA loop scheduling)
    local self = OODACommander.new({interval = oodaInterval})
    setmetatable(self, OperationalCommander)

    -- OperationalCommander-specific initialization
    self.color = config.color or "white"
    self.name = config.color .. "Ops"
    self.threatTracker = ThreatTracker.new(self.color .. "OperationalCommander")
    self.orderCoordinator = OrderCoordinator.new(self.color)
    self.lastIssuedOrders = {}
    self.plannedOrders = {}
    self.objectivesNeedingOrders = {}
    self.groupCommanders = config.groupCommanders or {}
    self.visualizer = config.visualizer
    self.visualizer:initMovementMapper(config.color)

    self.reconRadius = config.reconRadius or 8000
    self.assaultRadius = config.assaultRadius or 3000
    self.assaultStagingDistance = config.assaultStagingDistance or 7000
    self.maxReconGroups = config.maxReconGroups or 1
    -- self.threatTracker is fed by merging group snapshots (already-fresh
    -- data) but never ages on its own, so a threat that stops being
    -- reported (killed, retreated, lost LOS) lingers at its last known
    -- position forever. Filter reads by recency instead of relying on
    -- status, since there's no single opscom position to age relative to.
    self.threatMemoryWindow = config.threatMemoryWindow or 120

    self.doctrine = nil

    return self
end

function OperationalCommander:disband()
    self:cancelSchedule()
    local survivors = {}
    for _, gc in ipairs(self.groupCommanders) do
        if not gc.destroyed then
            table.insert(survivors, gc)
        end
    end
    env.info("*** " .. self.color .. " Ops: disbanded, returning " .. #survivors .. " groups to reserves")
    return survivors
end

function OperationalCommander:addGroupCommander(gc)
    table.insert(self.groupCommanders, gc)
end

function OperationalCommander:observe()
    self:aggregateThreatsFromGroups()

    -- Log consolidated OBSERVE summary
    local groupCommanders = self.groupCommanders
    local activeGroups = 0
    for _ in pairs(groupCommanders) do
        activeGroups = activeGroups + 1
    end
    local totalThreats = self.threatTracker:count()
    env.info("*** " .. self.color .. " Ops OBSERVE: " .. activeGroups .. " groups, " .. totalThreats .. " threats tracked")
end

function OperationalCommander:orient()
    -- Clean up destroyed commanders first, before any assessment
    self:cleanupDestroyedCommanders()
    
    -- Sync order statuses from commanders back to order graph
    self.orderCoordinator:syncOrderStatuses(self.groupCommanders)
    
    -- Assess objective progress
    self.objectivesNeedingOrders = {}
    for _, objective in ipairs(self.orderCoordinator.objectives) do
        self:assessObjectiveProgress(objective)
    end
    
    -- Log consolidated ORIENT summary
    local totalOrders = 0
    local activeOrders = 0
    local completedOrders = 0
    local abortedOrders = 0
    for _, objective in ipairs(self.orderCoordinator.objectives) do
        if objective.status == "Active" then
            local counts = objective:getOrderStatusCounts()
            totalOrders = totalOrders + counts.total
            activeOrders = activeOrders + counts.assigned + counts.inProgress
            completedOrders = completedOrders + counts.completed
            abortedOrders = abortedOrders + counts.aborted
        end
    end
    if totalOrders > 0 then
        env.info("*** " .. self.color .. " Ops ORIENT: Orders " .. activeOrders .. "/" .. totalOrders .. " active (" .. completedOrders .. " done, " .. abortedOrders .. " aborted)")
    end
end



function OperationalCommander:decide()
    self.plannedOrders = {}
    self.plannedThisCycle = {}  -- Track which commanders have orders planned this cycle

    if not self.doctrine then
        self.doctrine = ReconRallyAssaultPlan.new(self.name, {
            maxReconGroups         = self.maxReconGroups,
            reconRadius            = self.reconRadius,
            assaultRadius          = self.assaultRadius,
            assaultStagingDistance = self.assaultStagingDistance,
        })
        env.info("*** " .. self.color .. " Ops: Assigned ReconRallyAssaultPlan doctrine")
    end

    for _, objective in ipairs(self.orderCoordinator.objectives) do
        if objective.status == "Active" then
            self:planObjectiveWithDoctrine(objective)
        end
    end
    
    -- Log consolidated DECIDE summary
    if #self.plannedOrders > 0 then
        env.info("*** " .. self.color .. " Ops DECIDE: Planning " .. #self.plannedOrders .. " orders")
    else
        env.info("*** " .. self.color .. " Ops DECIDE: No new orders planned")
    end
end


function OperationalCommander:act()
    -- Update ally intel for all active groups
    self:updateAllyIntelForAllGroups()

    if self.plannedOrders and #self.plannedOrders > 0 then
        self:issuePlannedOrders()
    end

    -- Keep each active objective's map mark in sync with its current status
    if self.visualizer then
        for _, objective in ipairs(self.orderCoordinator.objectives) do
            self.visualizer:syncObjective(objective, self.doctrine, self.color)
        end
    end
end

function OperationalCommander:issuePlannedOrders()
    local issuedCount = 0
    for _, plan in ipairs(self.plannedOrders) do
        local commander = plan.commander
        local order = plan.order
        local lastOrder = self.lastIssuedOrders[commander.groupName]
        local commanderStatus = commander:getStatus()

        if isOrderChanged(lastOrder, order, commanderStatus) then
            -- Send nearby ally strength intel (within support range)
            local allyIntel = self:assessNearbyAllyStrength(order.position, 5000, commander.groupName)
            if allyIntel then
                commander:updateAllyIntel(allyIntel)
            end

            if order.objective then
                order.objective:addOrder(order)
            end

            commander:issueOrder(order)
            self.lastIssuedOrders[commander.groupName] = {
                alr = order.alr,
                position = {x = order.position.x, z = order.position.z},
                radius = order.radius,
                type = order.type,
                issuedAt = timer.getTime(),
            }
            issuedCount = issuedCount + 1
            
            -- Log each order issued
            local orderTypeName = order.type == taskTypes.RALLY and "RALLY" or 
                                order.type == taskTypes.ASSAULT and "ASSAULT" or 
                                order.type == taskTypes.RECON and "RECON" or 
                                order.type == taskTypes.DEFEND and "DEFEND" or 
                                order.type == taskTypes.REPOSITION and "REPOSITION" or 
                                tostring(order.type)
            env.info("*** " .. self.color .. " Ops ACT: " .. orderTypeName .. " → " .. commander.groupName)
        end
    end
    
    -- Log consolidated ACT summary
    env.info("*** " .. self.color .. " Ops ACT: Issued " .. issuedCount .. " orders total")
end


-- ============================================================================
-- HELPER METHODS
-- ============================================================================

-- Clean up destroyed commanders and orphaned objectives
function OperationalCommander:cleanupDestroyedCommanders()
    -- Remove destroyed commanders from the global instances list
    GroupCommander.removeDestroyed()

    -- Prune destroyed commanders from this opscom's managed list
    local surviving = {}
    for _, gc in ipairs(self.groupCommanders) do
        if gc.destroyed then
            if self.visualizer then
                self.visualizer:release("group:" .. gc.groupName)
            end
        else
            table.insert(surviving, gc)
        end
    end
    self.groupCommanders = surviving

    -- If all groups are gone, the objective can no longer be pursued
    if #self.groupCommanders == 0 then
        local objective = self.orderCoordinator.objectives[1]
        if objective and not objective:isComplete() then
            objective:markFailed("all groups destroyed")
            env.info("*** " .. self.color .. " Ops: objective failed - all groups destroyed")
        end
    end

    -- Abort orders assigned to groups that no longer exist
    if self.orderCoordinator and self.orderCoordinator.objectives then
        for _, objective in ipairs(self.orderCoordinator.objectives) do
            if objective.orders then
                for _, order in ipairs(objective.orders) do
                    if order.status ~= constants.orderStatus.ABORTED and
                       order.status ~= constants.orderStatus.COMPLETED then
                        local groupStillExists = false
                        for _, instance in ipairs(self.groupCommanders) do
                            if instance.groupName == order.assignedTo then
                                groupStillExists = true
                                break
                            end
                        end
                        if not groupStillExists then
                            env.info(string.format("*** %s Ops: Aborting order for %s (group missing)",
                                self.color, order.assignedTo or "unknown"))
                            order.status = constants.orderStatus.ABORTED
                            objective.updatedAt = timer.getTime()
                        end
                    end
                end
            end
        end
    end
end


--- @class ObjectiveContext
--- @field objectivePosition table
--- @field objectiveRadius number
--- @field objectiveDeadline number|nil
--- @field statusCounts table
--- @field threatProfile table
--- @field threatCenter table|nil
--- @field threats table
--- @field threatCount number
--- @field nearObjectiveThreatCount number
--- @field availableCommanderCount number
--- @return ObjectiveContext
function OperationalCommander:buildObjectiveContext(objective)
    local GroupProfiler = require("group-profiler")

    local threatsNear = self:getThreatsNearPosition(objective.position, self.reconRadius)
    local threatCount = 0
    local threatUnits = {}
    for unitName, _ in pairs(threatsNear) do
        threatCount = threatCount + 1
        local unit = Unit.getByName(unitName)
        if unit and unit:isExist() then
            table.insert(threatUnits, unit)
        end
    end

    local threatProfile = GroupProfiler.profileUnits(threatUnits)
    local threatCenter = nil
    if threatCount > 0 then
        threatCenter = SpatialAgent.calculateCenterOfObjects(threatsNear)
    end

    -- Scoped tighter than threatCount: used to judge whether the objective
    -- itself is clear (e.g. before declaring Defend), as opposed to
    -- threatCount/threatCenter/threatProfile which deliberately look out to
    -- reconRadius for staging/planning purposes.
    local nearObjectiveThreats = self:getThreatsNearPosition(objective.position, self.assaultRadius)
    local nearObjectiveThreatCount = 0
    for _ in pairs(nearObjectiveThreats) do
        nearObjectiveThreatCount = nearObjectiveThreatCount + 1
    end

    local statusCounts = objective:getOrderStatusCounts()

    local availableCount = 0
    for _, cmd in ipairs(self.groupCommanders) do
        local s = cmd:getStatus()
        if not s.orderStatus or
           s.orderStatus == constants.orderStatus.COMPLETED or
           s.orderStatus == constants.orderStatus.ABORTED then
            availableCount = availableCount + 1
        end
    end

    return {
        objectivePosition       = objective.position,
        objectiveRadius         = objective.radius or 2000,
        objectiveDeadline       = objective.deadline,
        statusCounts            = statusCounts,
        threatProfile           = threatProfile,
        threatCenter            = threatCenter,
        threats                 = threatsNear,
        threatCount             = threatCount,
        nearObjectiveThreatCount = nearObjectiveThreatCount,
        availableCommanderCount = availableCount,
    }
end

-- Plan objective orders using Doctrine strategy.
-- Doctrines signal completion by returning { objectiveComplete = true, ... }.
function OperationalCommander:planObjectiveWithDoctrine(objective)
    local context = self:buildObjectiveContext(objective)
    local result = self.doctrine:plan(context)
    if not result then return end

    if result.objectiveComplete then
        env.info("*** " .. self.color .. " Ops: OBJECTIVE COMPLETE --------------------")
        objective:markAchieved()
    end

    for _, template in ipairs(result.orders or {}) do
        self:assignOrderTemplate(template, objective)
    end
end

-- Evaluate available commanders against a template's missionProfile and issue orders
function OperationalCommander:assignOrderTemplate(template, objective)
    local count          = template.count or 1
    local missionProfile = template.missionProfile

    -- Score available commanders by suitability against the template's missionProfile
    local suitabilityResults = {}
    for _, commander in ipairs(self.groupCommanders) do
        local s = commander:getStatus()
        if not s.orderStatus or
           s.orderStatus == orderStatus.COMPLETED or
           s.orderStatus == orderStatus.ABORTED then
            local suitability = missionProfile and commander:getSuitability(missionProfile) or 1.0
            local dist = (s.position and template.position)
                and SpatialAgent.distance2D(s.position, template.position) or 0
            table.insert(suitabilityResults, {
                commander   = commander,
                suitability = suitability,
                distance    = dist,
            })
        end
    end

    local selected = self:selectGroupCommanders(suitabilityResults, { maxCount = count })

    local commanderPositions = {}
    for _, result in ipairs(selected) do
        local s = result.commander:getStatus()
        if s.position then
            table.insert(commanderPositions, s.position)
        end
    end

    local encirclingPositions
    local stagingAssignments
    if template.targetPosition then
        encirclingPositions = SpatialAgent.calculateEncirclingPositions(template.targetPosition, template.stagingRadius, commanderPositions, template.stagingArc)

        -- RALLY orders get a per-commander staging position fanned around the target.
        -- Assign by proximity (rather than list order) so commanders take the nearest
        -- open staging slot instead of trekking past one another to a farther one.
        local stagingItems = {}
        for _, result in ipairs(selected) do
            table.insert(stagingItems, { position = result.commander:getStatus().position, result = result })
        end
        local assigned = SpatialAgent.assignByProximity(stagingItems, encirclingPositions)

        stagingAssignments = {}
        for _, assignment in ipairs(assigned) do
            stagingAssignments[assignment.item.result.commander.groupName] = assignment.position
        end
    end

    for _, result in ipairs(selected) do
        local commander = result.commander

        local orderPosition = (stagingAssignments and stagingAssignments[commander.groupName]) or template.position

        if not self.plannedThisCycle[commander.groupName] then
            local order = Order.new({
                type           = template.type,
                position       = orderPosition,
                proximity      = template.proximity,
                alr            = template.alr,
                missionProfile = template.missionProfile,
                objective      = objective,
                deadline       = template.deadline,
                assignedTo     = commander.groupName,
            })
            table.insert(self.plannedOrders, {
                commander = commander,
                order     = order,
            })
            self.plannedThisCycle[commander.groupName] = true
        end
    end
end

-- Sort candidates by suitability and return up to maxCount
function OperationalCommander:selectGroupCommanders(suitabilityResults, constraints)
    local maxCount = constraints and constraints.maxCount or 1

    table.sort(suitabilityResults, function(a, b)
        if a.suitability ~= b.suitability then
            return a.suitability > b.suitability
        end
        return a.distance < b.distance
    end)

    local selected = {}
    for _, result in ipairs(suitabilityResults) do
        if #selected >= maxCount then break end
        table.insert(selected, result)
    end

    return selected
end


function OperationalCommander:getAvailableGroupCommanders()
    local available = {}
    for _, commander in ipairs(self.groupCommanders) do
        local status = commander:getStatus()
        local currentStatus = status.orderStatus
        -- Include groups without orders, or with completed/aborted orders
        if not currentStatus or
           currentStatus == orderStatus.COMPLETED or
           currentStatus == orderStatus.ABORTED then
            table.insert(available, commander)
        end
    end
    return available
end

function OperationalCommander:countActiveThreats(threats)
    -- Count only active threats (OBSERVED or SUSPECTED)
    -- Don't count UNCONFIRMED, LOST, or ELIMINATED threats
    local constants = require("constants")
    local threatStatus = constants.threatStatus
    
    local count = 0
    for _, threat in pairs(threats) do
        if threat.status == threatStatus.OBSERVED or threat.status == threatStatus.SUSPECTED then
            count = count + 1
        end
    end
    return count
end

function OperationalCommander:assessObjectiveProgress(objective)
    if not objective or objective.status ~= "Active" then
        return
    end

    local statusCounts = objective:getOrderStatusCounts()
    local activeCount = statusCounts.assigned + statusCounts.inProgress

    -- Check if orders were aborted (tactical retreat)
    if statusCounts.aborted > 0 then
        -- Check if ALL orders are aborted with none in progress
        if statusCounts.aborted == statusCounts.total then
            -- All orders aborted - reassess objective
            -- Groups with aborted orders will be available for reassignment
            table.insert(self.objectivesNeedingOrders, objective)
        else
            -- Some orders aborted, some still active - wait to see how active orders resolve
        end
        return
    end

    -- All orders completed successfully
    if statusCounts.total > 0 and statusCounts.completed == statusCounts.total then
        table.insert(self.objectivesNeedingOrders, objective)
    end
end

function OperationalCommander:aggregateThreatsFromGroups()
    for _, commander in ipairs(self.groupCommanders) do
        local status = commander:getStatus()
        self.threatTracker:mergeThreatIntel(status.threats)
    end
end

function OperationalCommander:getOwnGroupsNearPosition(position, radius)
    local nearbyOwnForces = {}
    for _, commander in ipairs(self.groupCommanders) do
        local status = commander:getStatus()
        if SpatialAgent.isWithinRadius(status.position, position, radius) then
            table.insert(nearbyOwnForces, commander)
        end
    end
    return nearbyOwnForces
end

function OperationalCommander:updateAllyIntelForAllGroups()
    -- Update ally intel for all active groups so they know about nearby friendlies
    local supportRadius = 5000  -- 5km support range
    
    for _, commander in ipairs(self.groupCommanders) do
        local status = commander:getStatus()
        if status.position then
            local allyIntel = self:assessNearbyAllyStrength(status.position, supportRadius, commander.groupName)
            commander:updateAllyIntel(allyIntel)
        end
    end
end

function OperationalCommander:getThreatsNearPosition(position, radius)
    local nearbyThreats = {}
    local allThreats = self.threatTracker:getThreats()
    local currentTime = timer.getTime()
    for unitName, threat in pairs(allThreats) do
        local isStale = not threat.lastSighting or (currentTime - threat.lastSighting) > self.threatMemoryWindow
        if not isStale and SpatialAgent.isWithinRadius(threat.position, position, radius) then
            nearbyThreats[unitName] = threat
        end
    end
    return nearbyThreats
end

function OperationalCommander:assessNearbyAllyStrength(position, radius, excludeGroupName)
    local nearbyGroups = self:getOwnGroupsNearPosition(position, radius)
    local allUnits = {}
    for _, commander in ipairs(nearbyGroups) do
        if commander.groupName ~= excludeGroupName then
            local group = Group.getByName(commander.groupName)
            if group and group:isExist() then
                for _, unit in ipairs(group:getUnits()) do
                    if unit and unit:isExist() then
                        table.insert(allUnits, unit)
                    end
                end
            end
        end
    end
    if #allUnits == 0 then
        return nil
    end
    return GroupProfiler.profileUnits(allUnits)
end

return OperationalCommander

end)
__bundle_register("doctrines.operational.recon-rally-assault-plan", function(require, _LOADED, __bundle_register, __bundle_modules)
-- ReconRallyAssaultPlan: Classic three-phase offensive strategy
-- Phase 1 (Recon):   Scout ahead to identify threats
-- Phase 2 (Rally):   Stage forces at standoff distance for coordinated attack
-- Phase 3 (Assault): Execute synchronized assault on objective
-- Phase 4 (Defend):  Hold objective once secured
--
-- Returns { orders = { ... }, objectiveComplete = true/nil }.
-- OperationalCommander handles commander selection and order assignment.

local constants = require("constants")
local Doctrine = require("doctrine")
local SpatialAgent = require("spatial-agent")

local orderStatus = constants.orderStatus
local taskTypes = constants.taskTypes
local alr = constants.acceptableLevelsOfRisk

local ReconRallyAssaultPlan = {}
setmetatable(ReconRallyAssaultPlan, {__index = Doctrine})
ReconRallyAssaultPlan.__index = ReconRallyAssaultPlan

function ReconRallyAssaultPlan.new(commanderName, config)
    local self = Doctrine.new("ReconRallyAssault", commanderName)
    setmetatable(self, ReconRallyAssaultPlan)

    self.config = {
        maxReconGroups         = (config and config.maxReconGroups)         or 1,
        reconRadius            = (config and config.reconRadius)            or 8000,
        assaultRadius          = (config and config.assaultRadius)          or 3000,
        assaultStagingDistance = (config and config.assaultStagingDistance) or 10000,
    }

    self:registerPhase("Recon",   ReconRallyAssaultPlan.reconPhase)
    self:registerPhase("Rally",   ReconRallyAssaultPlan.rallyPhase)
    self:registerPhase("Assault", ReconRallyAssaultPlan.assaultPhase)
    self:registerPhase("Defend",  ReconRallyAssaultPlan.defendPhase)

    return self
end

function ReconRallyAssaultPlan:reconPhase(context)
    local statusCounts = context.statusCounts

    -- Wait for any active orders to resolve
    if statusCounts.assigned > 0 or statusCounts.inProgress > 0 then
        return {}
    end

    -- Phase delta: only count orders issued since this phase started
    local totalThisPhase     = statusCounts.total     - self.phaseBaseline.total
    local completedThisPhase = statusCounts.completed - self.phaseBaseline.completed
    local abortedThisPhase   = statusCounts.aborted   - self.phaseBaseline.aborted

    -- Recon orders resolved — check if objective itself is already clear
    if totalThisPhase > 0 and (completedThisPhase + abortedThisPhase) >= totalThisPhase then
        if context.nearObjectiveThreatCount == 0 then
            self:changePhase("Defend", statusCounts)
        else
            self:changePhase("Rally", statusCounts)
        end
        return {}
    end

    -- No orders issued yet this phase — dispatch recon
    if totalThisPhase == 0 then
        return {
            orders = {
                {
                    type     = taskTypes.RECON,
                    position = context.objectivePosition,
                    radius   = self.config.reconRadius,
                    alr      = alr.LOW,
                    count    = self.config.maxReconGroups,
                    missionProfile = {
                        offensiveCapability = { vsInfantry = 0, vsArmor = 0, vsAir = 0 },
                        attritionRate = 0.0,
                        ammoRatio     = 0.2,
                    },
                }
            }
        }
    end

    return {}
end

function ReconRallyAssaultPlan:rallyPhase(context)
    local statusCounts  = context.statusCounts
    local threatProfile = context.threatProfile
    local threatCenter  = context.threatCenter

    -- Wait for active orders
    if statusCounts.assigned > 0 or statusCounts.inProgress > 0 then
        return {}
    end

    local totalThisPhase     = statusCounts.total     - self.phaseBaseline.total
    local completedThisPhase = statusCounts.completed - self.phaseBaseline.completed
    local abortedThisPhase   = statusCounts.aborted   - self.phaseBaseline.aborted

    -- Advance to Assault when rally orders resolve
    if totalThisPhase > 0 and (completedThisPhase + abortedThisPhase) >= totalThisPhase then
        self:changePhase("Assault", statusCounts)
        return {}
    end

    -- No threats to rally against — skip straight to Assault
    if not threatProfile or threatProfile.unitCount == 0 or not threatCenter then
        self:changePhase("Assault", statusCounts)
        return {}
    end

    if context.availableCommanderCount == 0 then
        return {}
    end

    -- Issue rally order template
    if totalThisPhase == 0 then
        return {
            orders = {
                {
                    type            = taskTypes.RALLY,
                    targetPosition  = threatCenter,
                    proximity       = 500,
                    stagingArc      = 120,
                    stagingRadius   = self.config.assaultStagingDistance,
                    alr             = alr.MEDIUM,
                    count           = 3,
                    missionProfile  = {
                        attritionRate = 0.0,
                        ammoRatio     = 0.8,
                    },
                }
            }
        }
    end

    return {}
end

function ReconRallyAssaultPlan:assaultPhase(context)
    local statusCounts  = context.statusCounts
    local threatProfile = context.threatProfile
    local threatCenter  = context.threatCenter

    -- Wait for active orders
    if statusCounts.assigned > 0 or statusCounts.inProgress > 0 then
        return {}
    end

    local totalThisPhase     = statusCounts.total     - self.phaseBaseline.total
    local completedThisPhase = statusCounts.completed - self.phaseBaseline.completed
    local abortedThisPhase   = statusCounts.aborted   - self.phaseBaseline.aborted

    -- Assault orders resolved
    if totalThisPhase > 0 and (completedThisPhase + abortedThisPhase) >= totalThisPhase then
        self:changePhase("Recon", statusCounts)
        return {}
    end

    if totalThisPhase == 0 then
        -- Stay focused on assaulting a position rather than units spotted on the group's periphery
        -- local assaultPosition = threatCenter or context.objectivePosition
        local assaultPosition = context.objectivePosition

        -- Build missionProfile from threat capability (need to match or exceed it)
        local missionProfile = {
            attritionRate = 0.0,
            ammoRatio     = 0.9,
        }
        if threatProfile and threatProfile.unitCount > 0 then
            missionProfile.offensiveCapability = {
                vsInfantry = threatProfile.offensiveCapability.vsInfantry,
                vsArmor    = threatProfile.offensiveCapability.vsArmor,
                vsAir      = threatProfile.offensiveCapability.vsAir,
            }
        end

        return {
            orders = {
                {
                    type           = taskTypes.ASSAULT,
                    position       = assaultPosition,
                    radius         = self.config.assaultRadius,
                    alr            = alr.HIGH,
                    count          = context.availableCommanderCount,
                    deadline       = context.objectiveDeadline or (timer.getTime() + 1800),
                    missionProfile = missionProfile,
                }
            }
        }
    end

    return {}
end

function ReconRallyAssaultPlan:defendPhase(context)
    local threatCenter = context.threatCenter

    -- Bias defend position toward objective, acknowledging threats
    local defendPosition = context.objectivePosition
    if threatCenter then
        defendPosition = {
            x = (context.objectivePosition.x + threatCenter.x) / 2,
            z = (context.objectivePosition.z + threatCenter.z) / 2,
        }
    end

    return {
        objectiveComplete = true,
        orders = {
            {
                type           = taskTypes.DEFEND,
                position       = defendPosition,
                radius         = context.objectiveRadius,
                alr            = alr.MEDIUM,
                count          = context.availableCommanderCount,
                missionProfile = {
                    attritionRate = 0.0,
                    ammoRatio     = 0.5,
                },
            }
        }
    }
end

return ReconRallyAssaultPlan

end)
__bundle_register("order-coordinator", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")

local orderStatus = constants.orderStatus

local OrderCoordinator = {}

-- Create a new OrderCoordinator instance
-- This coordinator owns the order graph (objectives and their orders)
function OrderCoordinator.new(coalition)
    local self = {
        coalition = coalition,
        objectives = {},  -- Owns the canonical objective graph
        ordersByCommander = {}  -- Index: commanderName -> order reference
    }
    setmetatable(self, {__index = OrderCoordinator})
    return self
end

-- Add an objective to the coordinator
function OrderCoordinator:addObjective(objective)
    table.insert(self.objectives, objective)
end

-- Get all objectives
function OrderCoordinator:getObjectives()
    return self.objectives
end

-- Get order assigned to a specific commander
function OrderCoordinator:getCommanderOrder(commanderName)
    return self.ordersByCommander[commanderName]
end

-- Sync order statuses from commanders back to the order graph
-- This is a state mutation - should be called at OODA boundaries (ORIENT phase)
function OrderCoordinator:syncOrderStatuses(commanders)
    for _, commander in pairs(commanders) do
        local status = commander:getStatus()

        -- Update all orders assigned to this commander
        for _, objective in ipairs(self.objectives) do
            for _, order in ipairs(objective.orders) do
                if order.assignedTo == commander.groupName then
                    if status.orderStatus and status.orderStatus ~= order.status then
                        order.status = status.orderStatus
                        objective.updatedAt = timer.getTime()
                    end
                end
            end
        end
    end
end

-- Track order assignment to a commander
function OrderCoordinator:assignOrder(commanderName, order)
    self.ordersByCommander[commanderName] = order
end

-- Clear assignment when order completes/aborts
function OrderCoordinator:clearAssignment(commanderName)
    self.ordersByCommander[commanderName] = nil
end

return OrderCoordinator

end)
return __bundle_require("__root")