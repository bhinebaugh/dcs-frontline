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
local constants = require("constants")
local taskTypes = constants.taskTypes

local GroupCommander = require("group-commander")
local Objective = require("objective")
local OperationalCommander = require("operational-commander")

-- NOTE: Doctrine usage example:
-- To assign a specific strategy to an objective, create the Doctrine and assign it:
--   local objective = Objective.new({...})
--   objective.doctrine = ReconRallyAssaultPlan.new(commanderName, config)
-- The OperationalCommander will use the Doctrine in its DECIDE phase.
-- If no Doctrine is assigned, it defaults to ReconRallyAssaultPlan.

-- Initial objective for Alpha is to defend the bridge
-- near the coordinates:
local blueAttackPosition = coord.LLtoLO(
    42 + 35/60 + 31/3600,
    41 + 56/60 + 26/3600
)

-- Known safe rally point for Blue forces
local blueRallyPosition = coord.LLtoLO(
    42 + 20/60 + 50/3600,
    41 + 50/60 + 50/3600
)

-- Initial objective for Bravo is to reposition to the
-- Kvemo-Khoshka village at these coordinates:
-- local redAttackPosition = coord.LLtoLO(
--     42 + 37/60 + 03/3600,
--     41 + 44/60 + 0/3600
-- )
local redAttackPosition = coord.LLtoLO(
    44 + 5/60 + 10/3600,
    44 + 16/60 + 35/3600
)

-- Known safe rally point for Red forces
local redRallyPosition = coord.LLtoLO(
    42 + 43/60 + 53/3600,
    42 + 02/60 + 56/3600
)

local opsBlue = OperationalCommander.new({color = "blue"})
local opsRed = OperationalCommander.new({color = "red"})

-- Assign rally points to strategic commanders
opsBlue.rallyPoints = {
    {position = blueRallyPosition, radius = 500}
}

opsRed.rallyPoints = {
    {position = redRallyPosition, radius = 500}
}

-- Create and assign objectives directly
opsBlue.orderCoordinator.objectives = {
    Objective.new({
        type = taskTypes.ASSAULT,
        position = redAttackPosition,
        radius = 500,
    })
}

opsRed.orderCoordinator.objectives = {
    Objective.new({
        type = taskTypes.ASSAULT,
        position = redAttackPosition,
        deadline = timer.getTime() + 1800,  -- 30 minute deadline
    })
}

local function createGroupCommandersForCoalition(coalitionSide, color, opsCommander)
    local groups = coalition.getGroups(coalitionSide, Group.Category.GROUND) or {}
    for _, group in ipairs(groups) do
        if group and group:isExist() then
            local groupName = group:getName()
            GroupCommander.new(groupName, {
                color = color,
                stratcom = opsCommander
            })
        end
    end
end

createGroupCommandersForCoalition(coalition.side.BLUE, "blue", opsBlue)
createGroupCommandersForCoalition(coalition.side.RED, "red", opsRed)

-- ## General scenario setup
-- 1. Blue pushes up to secure the town North of Zugdidi
-- 2. Red pushes southwest to seize Gali
-- 3. Each faction should start with recon units scouting ahead
-- 4. As they make contact, assault orders should be given
-- 7. Each faction should commit forces until one side is destroyed
-- 8. Individual groups will retreat despite orders, if they take heavy losses


end)
__bundle_register("operational-commander", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local GroupCommander = require("group-commander")
local GroupProfiler = require("group-profiler")
local OODACommander = require("ooda-commander")
local Order = require("order")
local OrderCoordinator = require("order-coordinator")
local PlanningContext = require("planning-context")
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

    self.reconRadius = config.reconRadius or 8000
    self.assaultRadius = config.assaultRadius or 3000
    self.assaultStagingDistance = config.assaultStagingDistance or 10000
    self.maxReconGroups = config.maxReconGroups or 1

    return self
end

function OperationalCommander:observe()
    self:aggregateThreatsFromGroups()
    
    -- Log consolidated OBSERVE summary
    local groupCommanders = GroupCommander.getInstances(self.color)
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
    local groupCommanders = GroupCommander.getInstances(self.color)
    self.orderCoordinator:syncOrderStatuses(groupCommanders)
    
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
    
    for _, objective in ipairs(self.orderCoordinator.objectives) do
        if objective.status == "Active" then
            -- Assign default Doctrine if none exists
            if not objective.doctrine then
                objective.doctrine = ReconRallyAssaultPlan.new(self.name, {
                    maxReconGroups         = self.maxReconGroups,
                    reconRadius            = self.reconRadius,
                    assaultRadius          = self.assaultRadius,
                    assaultStagingDistance = self.assaultStagingDistance,
                })
                env.info("*** " .. self.color .. " Ops: Assigned ReconRallyAssaultPlan to objective")
            end

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
    
    if not self.plannedOrders or #self.plannedOrders == 0 then
        return
    end

    local issuedCount = 0
    for _, plan in ipairs(self.plannedOrders) do
        local commander = plan.commander
        local order = plan.order
        local lastOrder = self.lastIssuedOrders[commander.groupName]
        local commanderStatus = commander:getStatus()

        if PlanningContext.isOrderChanged(lastOrder, order, commanderStatus) then
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

    -- Abort orders assigned to groups that no longer exist
    if self.orderCoordinator and self.orderCoordinator.objectives then
        for _, objective in ipairs(self.orderCoordinator.objectives) do
            if objective.orders then
                for _, order in ipairs(objective.orders) do
                    if order.status ~= constants.orderStatus.ABORTED and
                       order.status ~= constants.orderStatus.COMPLETED then
                        local groupStillExists = false
                        for _, instance in ipairs(GroupCommander.getInstances(self.color)) do
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


-- Plan objective orders using Doctrine strategy
function OperationalCommander:planObjectiveWithDoctrine(objective)
    local context = PlanningContext.deriveObjectivePlanningContext(objective, self)
    if not context then
        env.info("ERROR: Could not derive planning context for objective " .. (objective.name or "unknown"))
        return
    end

    local orderTemplates = objective.doctrine:plan(context)

    if not orderTemplates or #orderTemplates == 0 then
        return
    end

    for _, template in ipairs(orderTemplates) do
        self:assignOrderTemplate(template, objective)
    end
end

-- Evaluate available commanders against a template's missionProfile and issue orders
function OperationalCommander:assignOrderTemplate(template, objective)
    local count          = template.count or 1
    local missionProfile = template.missionProfile

    -- Score available commanders by suitability against the template's missionProfile
    local suitabilityResults = {}
    for _, commander in ipairs(GroupCommander.getInstances(self.color)) do
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
    if template.targetPosition then
        encirclingPositions = SpatialAgent.calculateEncirclingPositions(template.targetPosition, template.radius, commanderPositions, template.stagingArc)
    end

    for i, result in ipairs(selected) do
        local commander = result.commander

        -- RALLY orders get a per-commander staging position fanned around the target
        local orderPosition = encirclingPositions and encirclingPositions[i] or template.position

        if not self.plannedThisCycle[commander.groupName] then
            local order = Order.new({
                type           = template.type,
                position       = orderPosition,
                radius         = template.radius,
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
    for _, commander in pairs(GroupCommander.getInstances(self.color)) do
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
    for _, commander in pairs(GroupCommander.getInstances(self.color)) do
        local status = commander:getStatus()
        self.threatTracker:mergeThreatIntel(status.threats)
    end
end

function OperationalCommander:getOwnGroupsNearPosition(position, radius)
    local nearbyOwnForces = {}
    for _, commander in pairs(GroupCommander.getInstances(self.color)) do
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
    
    for _, commander in pairs(GroupCommander.getInstances(self.color)) do
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
    for unitName, threat in pairs(allThreats) do
        if SpatialAgent.isWithinRadius(threat.position, position, radius) then
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
    
    -- Check for expected threats within detection radius that were not observed
    for unitName, threat in pairs(self.threats) do
        local notObserved = not observedNames[unitName]
        local inExpectedRadius = SpatialAgent.isWithinRadius(threat.position, observerPosition, detectionRadius)
        local isExpected = threat.status ~= threatStatus.ELIMINATED and threat.status ~= threatStatus.LOST
        if notObserved and inExpectedRadius and isExpected then
            env.info(self.observerName .. " ThreatTracker: Expected threat not observed - " .. unitName .. " (SUSPECTED)")
            threat.status = threatStatus.UNCONFIRMED
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

return SpatialAgent

end)
__bundle_register("doctrines.operational.recon-rally-assault-plan", function(require, _LOADED, __bundle_register, __bundle_modules)
-- ReconRallyAssaultPlan: Classic three-phase offensive strategy
-- Phase 1 (Recon):   Scout ahead to identify threats
-- Phase 2 (Rally):   Stage forces at standoff distance for coordinated attack
-- Phase 3 (Assault): Execute synchronized assault on objective
-- Phase 4 (Defend):  Hold objective once secured
--
-- Returns order templates (plain data). OperationalCommander handles
-- commander selection and order assignment.

local constants = require("constants")
local Doctrine = require("doctrine")

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
    local objective    = context.goal
    local situation    = context.situation
    local statusCounts = situation.statusCounts

    -- Wait for any active orders to resolve
    if statusCounts.assigned > 0 or statusCounts.inProgress > 0 then
        return {}
    end

    -- Phase delta: only count orders issued since this phase started
    local totalThisPhase     = statusCounts.total     - self.phaseBaseline.total
    local completedThisPhase = statusCounts.completed - self.phaseBaseline.completed
    local abortedThisPhase   = statusCounts.aborted   - self.phaseBaseline.aborted

    -- Advance to Rally when recon orders are resolved
    if totalThisPhase > 0 and (completedThisPhase + abortedThisPhase) >= totalThisPhase then
        self:changePhase("Rally", statusCounts)
        return {}
    end

    -- No orders issued yet this phase — dispatch recon
    if totalThisPhase == 0 then
        return {
            {
                type     = taskTypes.RECON,
                position = objective.position,
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
    end

    return {}
end

function ReconRallyAssaultPlan:rallyPhase(context)
    local objective     = context.goal
    local situation     = context.situation
    local statusCounts  = situation.statusCounts
    local threatProfile = situation.threatProfile
    local threatCenter  = situation.threatCenter

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

    if situation.availableCommanderCount == 0 then
        return {}
    end

    -- Issue rally order template
    if totalThisPhase == 0 then
        return {
            {
                type            = taskTypes.RALLY,
                targetPosition  = threatCenter,
                stagingDistance = self.config.assaultStagingDistance,
                stagingArc      = 120,
                radius          = 5000,
                alr             = alr.MEDIUM,
                count           = 3,
                missionProfile  = {
                    attritionRate = 0.0,
                    ammoRatio     = 0.8,
                },
            }
        }
    end

    return {}
end

function ReconRallyAssaultPlan:assaultPhase(context)
    local objective     = context.goal
    local situation     = context.situation
    local statusCounts  = situation.statusCounts
    local threatProfile = situation.threatProfile
    local threatCenter  = situation.threatCenter

    -- Wait for active orders
    if statusCounts.assigned > 0 or statusCounts.inProgress > 0 then
        return {}
    end

    local totalThisPhase     = statusCounts.total     - self.phaseBaseline.total
    local completedThisPhase = statusCounts.completed - self.phaseBaseline.completed
    local abortedThisPhase   = statusCounts.aborted   - self.phaseBaseline.aborted

    -- Advance to Defend when assault orders resolve
    if totalThisPhase > 0 and (completedThisPhase + abortedThisPhase) >= totalThisPhase then
        self:changePhase("Defend", statusCounts)
        return {}
    end

    if totalThisPhase == 0 then
        local assaultPosition = threatCenter or objective.position

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
            {
                type           = taskTypes.ASSAULT,
                position       = assaultPosition,
                radius         = self.config.assaultRadius,
                alr            = alr.HIGH,
                count          = situation.availableCommanderCount,
                deadline       = objective.deadline or (timer.getTime() + 1800),
                missionProfile = missionProfile,
            }
        }
    end

    return {}
end

function ReconRallyAssaultPlan:defendPhase(context)
    local objective    = context.goal
    local situation    = context.situation
    local threatCenter = situation.threatCenter

    objective:markAchieved()

    -- Bias defend position toward objective, acknowledging threats
    local defendPosition = objective.position
    if threatCenter then
        defendPosition = {
            x = (objective.position.x + threatCenter.x) / 2,
            z = (objective.position.z + threatCenter.z) / 2,
        }
    end

    return {
        {
            type           = taskTypes.DEFEND,
            position       = defendPosition,
            radius         = objective.radius or 2000,
            alr            = alr.MEDIUM,
            count          = situation.availableCommanderCount,
            missionProfile = {
                attritionRate = 0.0,
                ammoRatio     = 0.5,
            },
        }
    }
end

return ReconRallyAssaultPlan

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
-- @param context PlanningContext table with goal, situation, resources, commander
-- @return decisions table (structure varies by commander type)
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
__bundle_register("planning-context", function(require, _LOADED, __bundle_register, __bundle_modules)
-- PlanningContext: Stateless context derivation utilities
-- Builds context structs passed to Doctrine:plan() at each command level.
-- Extracted from OrderCoordinator to keep that class focused on order graph ownership.

local constants = require("constants")
local SpatialAgent = require("spatial-agent")

local alr = constants.acceptableLevelsOfRisk
local orderStatus = constants.orderStatus

local PlanningContext = {}

-- ============================================================================
-- GROUP COMMANDER CONTEXT (tactical level)
-- ============================================================================

-- Derive order context for GroupCommander's ORIENT phase
function PlanningContext.deriveOrderContext(order, commanderPos, commanderALR)
    if not order or not order:isActive() then
        return nil
    end

    if not commanderPos then
        return nil
    end

    local orderedPosition = order.position
    local orderedRadius = order.radius or 500

    local distanceToOrdered = SpatialAgent.distance2D(commanderPos, orderedPosition)
    local withinObjective = distanceToOrdered <= orderedRadius

    local orderedALR = order.alr or alr.LOW
    local retreatThreshold = 0.4

    if orderedALR == alr.LOW then
        retreatThreshold = 0.8
    elseif orderedALR == alr.HIGH then
        retreatThreshold = 0.2
    end

    return {
        position         = orderedPosition,
        radius           = orderedRadius,
        type             = order.type,
        alr              = orderedALR,
        distanceToOrdered = distanceToOrdered,
        withinObjective  = withinObjective,
        retreatThreshold = retreatThreshold,
    }
end

-- Build tactical context for GroupCommander's DECIDE phase
function PlanningContext.buildTacticalContext(commander)
    if not commander then
        return nil
    end

    return {
        situation = {
            threatAssessment = commander.threatAssessment,
            statusReport     = commander:getStatusReport(),
            orderContext     = commander.orderContext,
            hasActiveOrders  = (commander.orders and commander.orders:isActive()),
            suitability      = commander.suitability,
        },
        commander = commander,
    }
end

-- ============================================================================
-- OPERATIONAL COMMANDER CONTEXT
-- ============================================================================

-- Derive planning context for OperationalCommander's ORIENT phase (per objective).
-- The resulting context is passed to operational Doctrines via plan().
-- Doctrines receive only data — no commander references.
function PlanningContext.deriveObjectivePlanningContext(objective, commander)
    local GroupProfiler = require("group-profiler")

    -- Gather threats near objective
    local threatsNear = commander:getThreatsNearPosition(objective.position, commander.reconRadius)
    local threatCount = 0
    local threatUnits = {}
    for unitName, _ in pairs(threatsNear) do
        threatCount = threatCount + 1
        local unit = Unit.getByName(unitName)
        if unit and unit:isExist() then
            table.insert(threatUnits, unit)
        end
    end

    -- Build threat GroupProfile
    local threatProfile = GroupProfiler.profileUnits(threatUnits)

    -- Compute threat center of mass
    local threatCenter = nil
    if threatCount > 0 then
        threatCenter = SpatialAgent.calculateCenterOfObjects(threatsNear)
    end

    -- Order status counts
    local statusCounts = objective:getOrderStatusCounts()

    -- Count available group commanders
    local GroupCommander = require("group-commander")
    local allCommanders = GroupCommander.getInstances(commander.color)
    local availableCount = 0
    for _, cmd in ipairs(allCommanders) do
        local s = cmd:getStatus()
        if not s.orderStatus or
           s.orderStatus == constants.orderStatus.COMPLETED or
           s.orderStatus == constants.orderStatus.ABORTED then
            availableCount = availableCount + 1
        end
    end

    return {
        goal = objective,
        situation = {
            statusCounts            = statusCounts,
            threatProfile           = threatProfile,
            threatCenter            = threatCenter,
            threats                 = threatsNear,
            threatCount             = threatCount,
            availableCommanderCount = availableCount,
        },
    }
end

-- ============================================================================
-- ORDER CHANGE DETECTION
-- ============================================================================

-- Check if an order has changed enough to warrant re-issuing (stateless utility)
function PlanningContext.isOrderChanged(lastOrder, newOrder, commanderStatus)
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

return PlanningContext

end)
__bundle_register("group-commander", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local DefensiveDoctrine = require("doctrines.tactical.defensive-doctrine")
local ForceStatusAnalyzer = require("force-status-analyzer")
local GroupProfiler = require("group-profiler")
local OODACommander = require("ooda-commander")
local PlanningContext = require("planning-context")
local AsOrderedDoctrine = require("doctrines.tactical.as-ordered-doctrine")
local PatrolDoctrine = require("doctrines.tactical.patrol-doctrine")
local ReconDoctrine = require("doctrines.tactical.recon-doctrine")
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
    
    -- Simulated fuel tracking (DCS doesn't model fuel for ground units)
    self.fuelRemaining = 1.0  -- Start at 100%
    self.lastPosition = nil
    self.lastObserveTime = timer.getTime()
    
    -- Active Doctrine (persists across OODA cycles until order type changes)
    self.doctrine = nil
    self.doctrineType = nil
    
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
    env.info(self.groupName .. " OBSERVE: LOS:" .. #visibleThreatNames .. expectedStr .. " Mem:" .. memoryCount)
end

function GroupCommander:orient()
    -- Gather situational awareness for decision making
    self.ownForceStrength = self:analyzeOwnForce()

    self.threatAssessment = self:assessThreats()

    -- Derive order context and group profile
    local ownPos = self:getOwnPosition()
    self.orderContext = PlanningContext.deriveOrderContext(self.orders, ownPos, self.alr)
    self.groupProfile = GroupProfiler.profileGroup(self.groupName, self.initialUnitNames, self.initialAmmoCount, self.fuelRemaining)

    -- Update suitability against current order's mission profile
    if self.orders and self.orders.missionProfile then
        self.suitability = self:getSuitability(self.orders.missionProfile)
    else
        self.suitability = nil
    end
end

function GroupCommander:decide()
    if self.orders and self.orders.status == orderStatus.ASSIGNED then
        if self.orders.type == taskTypes.PATROL then
            self.doctrine = PatrolDoctrine.new(self.groupName)
        elseif self.orders.type == taskTypes.RECON then
            self.doctrine = ReconDoctrine.new(self.groupName)
        else
            self.doctrine = AsOrderedDoctrine.new(self.groupName)
        end
    end

    if self.orders and self.orders:isFinished() then
        self.orders = nil
        self.doctrine = DefensiveDoctrine.new(self.groupName)
    end

    if not self.doctrine then
        self.doctrine = DefensiveDoctrine.new(self.groupName)
    end

    -- Check if we have valid assessment data
    if not self.ownForceStrength or not self.threatAssessment then
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = self:getOwnPosition()
        return
    end

    -- Get tactical planning context
    local context = PlanningContext.buildTacticalContext(self)
    if not context then
        env.info("ERROR: Could not build tactical context for " .. self.groupName)
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = self:getOwnPosition()
        return
    end
        
    -- Use Doctrine to make tactical decisions
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
    if self.destination and (self.disposition == dispositionTypes.ADVANCE or self.disposition == dispositionTypes.RETREAT) then
        -- Only issue if destination has changed (more than 100m tolerance)
        if not self.lastMoveOrder or 
           math.abs(self.lastMoveOrder.x - self.destination.x) > 100 or 
           math.abs(self.lastMoveOrder.z - self.destination.z) > 100 then
            self:issueMoveOrder(self.destination)
            self.lastMoveOrder = {x = self.destination.x, z = self.destination.z}
        end
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
            env.info(string.format("*** GroupCommander: Removing destroyed group %s from memory",
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
    env.info(self.groupName .. " DECIDE: Move to " .. string.format("%.5f", lat or 0) .. "," .. string.format("%.5f", lon or 0))
    
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
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames

    local advanceAssessment = 0.0

    if threat.count == 0 then
        advanceAssessment = 1.0
    end

    return advanceAssessment
end

function ReconDoctrine:considerObserve(context)
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames

    local observeAssessment = 0.0

    if threat.count > 0 then
        observeAssessment = 1.0
    end

    return observeAssessment
end

function ReconDoctrine:advancePhase(context)
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames

    local ownPosition = commander:getOwnPosition()
    local objectiveDestination = commander.orders.position

    local observeThreshold = 1.0
    
    if self:considerObserve(context) >= observeThreshold then
        self:changePhase("Observe")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil
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
        destination = commander.orders.position,
        orderAction = "start",
    }
end

function ReconDoctrine:observePhase(context)
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames

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
    local commander = context.commander
    local orders = commander.orders

    if not self.state.StartingPoint then
        self.state.StartingPoint = commander:getOwnPosition()
    end

    if not self.state.Destination then
        self.state.Destination = orders and orders.position or self.state.StartingPoint
    end

    local distanceToDestination = self.state.Destination and SpatialAgent.distance2D(commander:getOwnPosition(), self.state.Destination)
    env.info(commander.groupName .. " is " .. tostring(distanceToDestination) .. " meters from patrol destination")
    local isAtDestination = distanceToDestination and distanceToDestination < 50

    if isAtDestination then
        env.info(commander.groupName .. " has reached patrol destination, switching to InboundLeg")
        self:changePhase("InboundLeg")
        return {disposition = dispositionTypes.HOLD, destination = nil}
    else
        return {disposition = dispositionTypes.ADVANCE, destination = self.state.Destination, orderAction = "start"}
    end
end

function PatrolDoctrine:inboundPhase(context)
    local commander = context.commander

    local isAtStart = self.state.StartingPoint and SpatialAgent.distance2D(commander:getOwnPosition(), self.state.StartingPoint) < 50

    if isAtStart then
        env.info(commander.groupName .. " has returned to starting point, switching to OutboundLeg")
        self:changePhase("OutboundLeg")
        return {disposition = dispositionTypes.HOLD, destination = nil}
    else
        return {disposition = dispositionTypes.ADVANCE, destination = self.state.StartingPoint}
    end
end


return PatrolDoctrine

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
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames
    local ownPosition = commander:getOwnPosition()
    local objectivePosition = situation.orderContext and situation.orderContext.position or nil

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
    if ForceStatusAnalyzer.isAmmoLow(status.ammoCount, commander.initialAmmoCount) then
        engageAssessment = 0.0
    end

    if ForceStatusAnalyzer.isUnarmed(commander.initialAmmoCount) then
        engageAssessment = 0.0
    end
    
    return engageAssessment
end

function AsOrderedDoctrine:considerDefend(context)
    local commander = context.commander
    local situation = context.situation
    local objectivePosition = situation.orderContext and situation.orderContext.position or nil

    local defendAssessment = 0.0

    local distanceToObjective = SpatialAgent.distance2D(commander:getOwnPosition(), objectivePosition)
    if distanceToObjective and distanceToObjective < situation.orderContext.radius then
        defendAssessment = defendAssessment + 1.0
    end

    return defendAssessment
end

function AsOrderedDoctrine:considerAbort(context)
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames

    local retreatAssessment = 0.0

    -- ammunition
    if ForceStatusAnalyzer.isAmmoCritical(status.ammoCount, commander.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isAmmoLow(status.ammoCount, commander.initialAmmoCount) then
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
    local suitability = context.situation.suitability
    if suitability and suitability < 0.3 then
        retreatAssessment = retreatAssessment + (0.3 - suitability) * 2
    end

    return retreatAssessment
end

function AsOrderedDoctrine:advancePhase(context)
    -- Move toward objective location
    local commander = context.commander
    local orders = commander.orders
    local destination = orders and orders.position or nil

    local engageThreshold = 0.4
    local abortThreshold = 0.8
    local defendThreshold = 0.2

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil
        }
    end

    if self:considerEngage(context) >= engageThreshold then
        self:changePhase("Engage")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil
        }
    end

    if self:considerDefend(context) >= defendThreshold then
        self:changePhase("Defend")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
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

    local threat = context.situation.threatAssessment

    local engageThreshold = 0.3
    local abortThreshold = 0.8

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil
        }
    end

    if self:considerEngage(context) >= engageThreshold then
        local ownPosition      = context.commander:getOwnPosition()
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
    local commander = context.commander
    local destination = context.situation.orderContext.position
    local radius = context.situation.orderContext.radius or 500

    local hasExpiration = commander.orders and commander.orders.expirationTime
    local isExpired = context.commander.orders:isExpired()

    if isExpired or not hasExpiration then
        return {
            disposition = dispositionTypes.DEFEND,
            destination = destination,
            radius      = radius,
            orderAction = "complete",
        }
    end

    return {
        disposition = dispositionTypes.DEFEND,
        destination = destination,
        radius      = radius,
    }
end

function AsOrderedDoctrine:abortPhase(context)
    -- Move away from threats toward safety
    local commander = context.commander
    local situation = context.situation

    local threat = situation.threatAssessment
    local ownPosition = commander:getOwnPosition()

    -- Use directly observed threats if available (more stable)
    local retreatDest = nil

    if threat.center then
        local direction = SpatialAgent.calculateDirection(threat.center, ownPosition)
        retreatDest = SpatialAgent.calculateDestination(threat.center, direction, 1000)
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

    self:registerPhase("Hold", DefensiveDoctrine.holdPhase)
    self:registerPhase("Retreat", DefensiveDoctrine.retreatPhase)
    self:registerPhase("Advance", DefensiveDoctrine.advancePhase)
    
    return self
end

function DefensiveDoctrine:considerRetreat(context)
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames

    local retreatAssessment = 0.0

    -- ammunition
    if ForceStatusAnalyzer.isAmmoCritical(status.ammoCount, commander.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isAmmoLow(status.ammoCount, commander.initialAmmoCount) then
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
    local suitability = context.situation.suitability
    if suitability and suitability < 0.3 then
        retreatAssessment = retreatAssessment + (0.3 - suitability) * 2
    end

    return retreatAssessment
end

function DefensiveDoctrine:considerAdvance(context)
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames

    local advanceAssessment = 0.0

    -- threat favorability
    if threat.count > 0 and threat.favorability < 1.0 then
        advanceAssessment = advanceAssessment + threat.favorability
    else
        advanceAssessment = advanceAssessment + threat.favorability / 2
    end

    -- attrition rate
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    advanceAssessment = advanceAssessment - attritionRate

    -- ammunition
    if ForceStatusAnalyzer.isAmmoLow(status.ammoCount, commander.initialAmmoCount) then
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
    local commander = context.commander
    local situation = context.situation

    local threat = situation.threatAssessment
    local ownPosition = commander:getOwnPosition()

    -- Use directly observed threats if available (more stable)
    local retreatDest = nil

    if threat.center then
        local direction = SpatialAgent.calculateDirection(threat.center, ownPosition)
        retreatDest = SpatialAgent.calculateDestination(threat.center, direction, 1000)
    else
        self:changePhase("Hold")
    end

    return {
        disposition = dispositionTypes.RETREAT,
        destination = retreatDest
    }
end

function DefensiveDoctrine:advancePhase(context)
    local commander = context.commander
    local situation = context.situation

    local threat = situation.threatAssessment
    local ownPosition = commander:getOwnPosition()

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
return __bundle_require("__root")