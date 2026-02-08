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
local ForceStatusAnalyzer = require("force-status-analyzer")
local GroupCommander = require("group-commander")
local OODACommander = require("ooda-commander")
local Order = require("order")
local OrderCoordinator = require("order-coordinator")
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
    self.threatTracker = ThreatTracker.new(self.color .. "OperationalCommander")
    self.orderCoordinator = OrderCoordinator.new(self.color)
    self.lastIssuedOrders = {}
    self.plannedOrders = {}
    self.objectivesNeedingOrders = {}
    self.objectiveContexts = {}  -- Derived snapshot for DECIDE phase
    self.phase = "RECON"

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
    
    -- Derive objective contexts for DECIDE phase
    self:assessObjectiveContexts()
    
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

-- Clean up destroyed commanders and orphaned objectives
function OperationalCommander:cleanupDestroyedCommanders()
    -- Remove destroyed commanders from global instances for memory cleanup
    local allInstances = GroupCommander.getInstances()
    local survivingInstances = {}
    local removed = 0
    
    for _, instance in ipairs(allInstances) do
        if not instance.destroyed then
            table.insert(survivingInstances, instance)
        else
            removed = removed + 1
            local groupName = instance.groupName or "unknown"
            local coalitionName = instance.color or "unknown"
            env.info(string.format("*** %s Ops: Removing destroyed group %s from memory", 
                coalitionName, groupName))
        end
    end
    
    if removed > 0 then
        GroupCommander.instances = survivingInstances
    end
    
    -- Clean up orders assigned to dead groups
    if self.orderCoordinator and self.orderCoordinator.objectives then
        for _, objective in ipairs(self.orderCoordinator.objectives) do
            if objective.orders then
                for _, order in ipairs(objective.orders) do
                    -- Check if this order is assigned to a now-destroyed group
                    if order.status ~= constants.orderStatus.ABORTED and 
                       order.status ~= constants.orderStatus.COMPLETED then
                        -- Check against actual GroupCommander instances for this coalition
                        local groupStillExists = false
                        local wasDestroyed = false
                        local allInstances = GroupCommander.getInstances(self.color)
                        for _, instance in ipairs(allInstances) do
                            if instance.groupName == order.assignedTo then
                                groupStillExists = true
                                if instance.destroyed then
                                    wasDestroyed = true
                                end
                                break
                            end
                        end
                        
                        -- Only abort if group actually doesn't exist or is destroyed
                        if not groupStillExists or wasDestroyed then
                            local coalitionName = self.coalitionName or self.color or "unknown"
                            local assignedTo = order.assignedTo or "unknown"
                            local reason = wasDestroyed and "group destroyed" or "group missing"
                            env.info(string.format("*** %s Ops: Aborting order for %s (%s)",
                                coalitionName, assignedTo, reason))
                            order.status = constants.orderStatus.ABORTED
                            objective.updatedAt = timer.getTime()
                        end
                    end
                end
            end
        end
    end
end

-- Assess objective contexts in ORIENT phase (creates snapshot for DECIDE)
function OperationalCommander:assessObjectiveContexts()
    self.objectiveContexts = {}
    
    for _, objective in ipairs(self.orderCoordinator.objectives) do
        if objective.status == "Active" then
            local statusCounts = objective:getOrderStatusCounts()
            local threatsNear = self:getThreatsNearPosition(objective.position, self.reconRadius)
            local threatCount = 0
            for _ in pairs(threatsNear) do
                threatCount = threatCount + 1
            end
            
            -- Use OrderCoordinator to derive context snapshot
            local context = self.orderCoordinator:deriveObjectiveContext(
                objective,
                statusCounts,
                threatsNear,
                threatCount
            )
            
            table.insert(self.objectiveContexts, context)
        end
    end
end

function OperationalCommander:reviewAndCancelObsoleteOrders()
    -- Review active orders and cancel them if they're no longer relevant
    -- This allows the ops commander to adapt to changing threats
    
    for _, objective in ipairs(self.orderCoordinator.objectives) do
        if objective.status == "Active" then
            local currentThreats = self:getThreatsNearPosition(objective.position, self.reconRadius)
            local threatCount = 0
            for _ in pairs(currentThreats) do
                threatCount = threatCount + 1
            end
            
            -- Review each active order for this objective
            for _, order in ipairs(objective.orders) do
                if order.status == orderStatus.IN_PROGRESS or order.status == orderStatus.ASSIGNED then
                    local shouldCancel = false
                    local cancelReason = ""
                    
                    -- RALLY orders: Cancel if threats no longer exist or position is now behind new threats
                    if order.type == taskTypes.RALLY then
                        -- Don't cancel just because threats went to MEMORY - require total absence
                        local totalThreats = 0
                        for _ in pairs(currentThreats) do
                            totalThreats = totalThreats + 1
                        end
                        if totalThreats == 0 then
                            shouldCancel = true
                            cancelReason = "rally threats no longer exist"
                        else
                            -- Check if threats appeared between the unit and rally point
                            -- (Don't cancel just because threats are at the objective we're rallying toward)
                            for _, cmd in pairs(GroupCommander.getInstances(self.color)) do
                                if cmd.groupName == order.assignedTo then
                                    local commanderStatus = cmd:getStatus()
                                    if commanderStatus.position then
                                        -- Distance to rally point
                                        local distToRally = SpatialAgent.distance2D(commanderStatus.position, order.position)
                                        
                                        -- Distance from rally point to objective
                                        local rallyToObjective = SpatialAgent.distance2D(order.position, order.objective.position)
                                        
                                        -- Only cancel if threats appeared much closer than the rally point
                                        -- AND are not near the objective (which is expected)
                                        local threatBlockingRally = false
                                        for unitName, threat in pairs(currentThreats) do
                                            if threat.position then
                                                local distToThreat = SpatialAgent.distance2D(commanderStatus.position, threat.position)
                                                local threatToObjective = SpatialAgent.distance2D(threat.position, order.objective.position)
                                                
                                                -- Threat is blocking if it's:
                                                -- 1. Much closer than rally point (within 25% of rally distance)
                                                -- 2. NOT near the objective (more than 2km from objective)
                                                -- 3. Unit is still far from rally (more than 2km)
                                                if distToThreat < distToRally * 0.25 and 
                                                   threatToObjective > 2000 and 
                                                   distToRally > 2000 then
                                                    threatBlockingRally = true
                                                    break
                                                end
                                            end
                                        end
                                        
                                        if threatBlockingRally then
                                            shouldCancel = true
                                            cancelReason = "threats blocking path to rally point"
                                        end
                                    end
                                    break -- Found the commander, stop searching
                                end
                            end
                        end
                    end
                    
                    -- ASSAULT orders: Only cancel if threats are completely eliminated in the wider area
                    -- Don't cancel just because threats moved during combat
                    if order.type == taskTypes.ASSAULT then
                        -- Check wider area (3x radius) to avoid canceling during active combat
                        local threatsNearTarget = self:getThreatsNearPosition(order.position, order.radius * 3)
                        local activeThreats = self:countActiveThreats(threatsNearTarget)
                        if activeThreats == 0 then
                            shouldCancel = true
                            cancelReason = "assault threats no longer active"
                        end
                    end
                    
                    -- Cancel the order by aborting it
                    if shouldCancel then
                        local orderTypeName = order.type == taskTypes.RALLY and "RALLY" or 
                                            order.type == taskTypes.ASSAULT and "ASSAULT" or 
                                            order.type == taskTypes.RECON and "RECON" or 
                                            tostring(order.type)
                        env.info("*** " .. self.color .. " Ops: Canceling " .. orderTypeName .. 
                                 " order for " .. order.assignedTo .. " (" .. cancelReason .. ")")
                        
                        -- Find commander by name and abort order
                        for _, cmd in pairs(GroupCommander.getInstances(self.color)) do
                            if cmd.groupName == order.assignedTo then
                                local commanderOrders = cmd.orders
                                if commanderOrders and commanderOrders == order then
                                    commanderOrders:abort("ops_cancel")
                                end
                                break
                            end
                        end
                        
                        order.status = orderStatus.ABORTED
                        objective.updatedAt = timer.getTime()
                    end
                end
            end
        end
    end
end

function OperationalCommander:decide()
    self.plannedOrders = {}
    self.plannedThisCycle = {}  -- Track which commanders have orders planned this cycle
    
    -- Review and cancel obsolete orders before planning new ones
    self:reviewAndCancelObsoleteOrders()
    
    -- Process each active objective
    for _, objective in ipairs(self.orderCoordinator.objectives) do
        if objective.status == "Active" then
            self:planObjectiveOrders(objective)
        end
    end
    
    -- Handle idle units that need orders (aborted, no objective, etc.)
    self:planOrdersForIdleUnits()
    
    -- Respond to threats detected by groups with assault orders
    self:planResponseToDetectedThreats()
    
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

        if OrderCoordinator.isOrderChanged(lastOrder, order, commanderStatus) then
            if plan.threats then
                commander:updateThreatIntel(plan.threats)
            end
            
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
                threatCenter = plan.threatCenter,  -- Store threat center for rally orders
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


function OperationalCommander:planObjectiveOrders(objective)
    local statusCounts = objective:getOrderStatusCounts()
    local threatsNearObjective = self:getThreatsNearPosition(objective.position, self.reconRadius)
    local threatCount = 0
    for _ in pairs(threatsNearObjective) do
        threatCount = threatCount + 1
    end
    
    -- If no orders exist, start with RECON
    if statusCounts.total == 0 then
        self:planReconOrders(objective)
        return
    end
    
    -- If all orders completed or aborted, determine next phase
    -- (aborted orders mean the units are available for new orders)
    if statusCounts.completed + statusCounts.aborted == statusCounts.total then
        -- Get the type of the last completed orders
        local lastOrderType = nil
        local lastCompletedCount = 0
        local lastAbortedCount = 0
        
        if #objective.orders > 0 then
            lastOrderType = objective.orders[#objective.orders].type
            -- Count how many of this order type completed vs aborted
            for i = #objective.orders, 1, -1 do
                if objective.orders[i].type == lastOrderType then
                    if objective.orders[i].status == orderStatus.COMPLETED then
                        lastCompletedCount = lastCompletedCount + 1
                    elseif objective.orders[i].status == orderStatus.ABORTED then
                        lastAbortedCount = lastAbortedCount + 1
                    end
                else
                    break  -- Different order type, stop counting
                end
            end
        end
        
        if lastOrderType == taskTypes.RECON then
            if threatCount == 0 then
                -- RECON found no threats - check if we're at the objective
                local reconDistance = math.huge
                for _, cmd in pairs(GroupCommander.getInstances(self.color)) do
                    local cmdStatus = cmd:getStatus()
                    if cmdStatus.position then
                        local dist = SpatialAgent.distance2D(cmdStatus.position, objective.position)
                        if dist and dist < reconDistance then
                            reconDistance = dist
                        end
                    end
                end
                
                if reconDistance < objective.radius * 2 then
                    -- At objective, no threats - establish DEFEND
                    self:planDefendOrders(objective)
                else
                    -- Not at objective yet, continue RECON
                    self:planReconOrders(objective)
                end
            else
                -- RECON completed because threats were found - RALLY forces to engage them
                self:planRallyOrders(objective, threatsNearObjective)
            end
        elseif lastOrderType == taskTypes.RALLY then
            -- Only proceed to ASSAULT once ALL rallies complete
            -- This ensures a fully coordinated assault with all forces
            local totalRallies = lastCompletedCount + lastAbortedCount
            
            if lastAbortedCount == totalRallies then
                -- All rallies were aborted (e.g., units engaged threats directly)
                -- They're fighting autonomously now
                -- Issue new rally orders only if threats still exist and units need coordination
                if threatCount > 0 then
                    env.info("*** " .. self.color .. " Ops: All rallies aborted, reissuing rally orders")
                    self:planRallyOrders(objective, threatsNearObjective)
                end
            elseif lastCompletedCount == totalRallies then
                -- All rallies completed, launch coordinated assault
                env.info("*** " .. self.color .. " Ops: All " .. totalRallies .. " rallies completed, launching assault")
                self:planAssaultOrders(objective, threatsNearObjective)
            else
                -- Some rallies still in progress, wait for all to complete
                env.info("*** " .. self.color .. " Ops: Waiting for rallies to complete (" .. 
                         lastCompletedCount .. "/" .. totalRallies .. " done)")
            end
        elseif lastOrderType == taskTypes.ASSAULT then
            if threatCount == 0 then
                -- Threats cleared - resume RECON toward objective
                self:planReconOrders(objective)
            else
                -- More threats remain, continue ASSAULT
                self:planAssaultOrders(objective, threatsNearObjective)
            end
        elseif lastOrderType == taskTypes.DEFEND then
            -- Objective secured and being defended
            if threatCount > 0 then
                -- New threats appeared, respond with RALLY then ASSAULT
                self:planRallyOrders(objective, threatsNearObjective)
            end
        end
    end
end

function OperationalCommander:planReconOrders(objective)
    local availableCommanders = self:getAvailableGroupCommanders()
    
    -- Score commanders by suitability for RECON (lighter, less offensive capability)
    local scoredCommanders = self:scoreCommandersForRecon(availableCommanders, objective.position)
    local count = math.min(self.maxReconGroups, #scoredCommanders)
    
    for i = 1, count do
        local commander = scoredCommanders[i].commander
        local order = Order.new({
            assignedTo = commander.groupName,
            objective = objective,
            position = objective.position,
            radius = objective.radius,
            type = taskTypes.RECON,
            alr = alr.LOW,
            deadline = timer.getTime() + 900,
        })
        
        self:addPlannedOrder(commander, order)
    end
end

function OperationalCommander:planRallyOrders(objective, threats)
    local availableCommanders = self:getAvailableGroupCommanders()
    
    env.info("*** " .. self.color .. " Ops planRallyOrders: " .. #availableCommanders .. " available commanders")
    
    if #availableCommanders == 0 then
        env.info("*** " .. self.color .. " Ops planRallyOrders: No available commanders")
        return
    end
    
    -- Calculate center of threat cluster
    local threatCenter = SpatialAgent.calculateThreatCenter(threats)
    if not threatCenter then
        threatCenter = objective.position
    end
    
    -- Filter out commanders who recently completed a rally at a similar threat center
    -- This prevents churning rally orders when threat center moves slightly
    local filteredCommanders = {}
    local currentTime = timer.getTime()
    for _, commander in ipairs(availableCommanders) do
        local lastOrder = self.lastIssuedOrders[commander.groupName]
        local skipRally = false
        
        if lastOrder and lastOrder.type == taskTypes.RALLY then
            -- Check if this was a recent rally (within last 60 seconds)
            local timeSinceRally = currentTime - (lastOrder.issuedAt or 0)
            if timeSinceRally < 60 and lastOrder.threatCenter then
                -- Check if threat center moved significantly (>1.5km threshold)
                local distance = SpatialAgent.distance2D(threatCenter, lastOrder.threatCenter)
                
                if distance < 1500 then
                    env.info("*** " .. self.color .. " Ops: Skipping " .. commander.groupName .. 
                             " for rally (recently rallied, threat center similar: " .. 
                             string.format("%.0f", distance) .. "m shift)")
                    skipRally = true
                end
            end
        end
        
        if not skipRally then
            table.insert(filteredCommanders, commander)
        end
    end
    
    env.info("*** " .. self.color .. " Ops planRallyOrders: " .. #filteredCommanders .. " after filtering recent rallies")
    
    if #filteredCommanders == 0 then
        env.info("*** " .. self.color .. " Ops planRallyOrders: No commanders after filtering")
        return
    end
    
    -- Select best units for assault based on threat composition and proximity
    -- Prioritize units that can arrive quickly enough and have good matchups
    local scoredCommanders = self:scoreCommandersForAssault(filteredCommanders, threats, threatCenter)
    
    env.info("*** " .. self.color .. " Ops planRallyOrders: " .. #scoredCommanders .. " scored commanders")
    
    -- Limit to units within reasonable response time (20 minutes)
    local selectedCommanders = self:selectCommandersWithinTimeWindow(scoredCommanders, threatCenter, 1200)
    
    env.info("*** " .. self.color .. " Ops planRallyOrders: " .. #selectedCommanders .. " within time window")
    
    -- If no units within time window, send the closest 2-3 anyway
    if #selectedCommanders == 0 and #scoredCommanders > 0 then
        local maxToSend = math.min(3, #scoredCommanders)
        for i = 1, maxToSend do
            table.insert(selectedCommanders, scoredCommanders[i])
        end
        env.info("*** " .. self.color .. " Ops planRallyOrders: Using fallback, sending " .. #selectedCommanders .. " closest")
    end
    
    if #selectedCommanders == 0 then
        env.info("*** " .. self.color .. " Ops planRallyOrders: No commanders selected after all filters")
        return
    end
    
    -- Calculate assault staging positions based on each unit's current position
    local stagingPositions = self:calculateAssaultStagingPositions(
        threatCenter,
        selectedCommanders
    )
    
    for i, commanderInfo in ipairs(selectedCommanders) do
        local commander = commanderInfo.commander
        local stagingPos = stagingPositions[i]
        local order = Order.new({
            assignedTo = commander.groupName,
            objective = objective,
            position = stagingPos,
            radius = 500,
            type = taskTypes.RALLY,
            alr = alr.MEDIUM,
            deadline = timer.getTime() + 600,
        })
        
        self:addPlannedOrder(commander, order, threats, threatCenter)
    end
end

function OperationalCommander:calculateAssaultStagingPositions(threatCenter, selectedCommanders)
    -- Calculate rally positions spread around the threat to create flanking/converging attack
    -- Rally positions form an arc on the allied side (never crossing through threat interior)
    local positions = {}
    local distance = self.assaultStagingDistance
    local numUnits = #selectedCommanders
    
    if numUnits == 0 then
        return positions
    end
    
    -- Step 1-3: Find the center of the allied group (centroid of all rallying units)
    local alliedCenterX = 0
    local alliedCenterZ = 0
    local validCount = 0
    
    for _, commanderInfo in ipairs(selectedCommanders) do
        local commander = commanderInfo.commander
        local status = commander:getStatus()
        
        if status.position then
            alliedCenterX = alliedCenterX + status.position.x
            alliedCenterZ = alliedCenterZ + status.position.z
            validCount = validCount + 1
        end
    end
    
    if validCount == 0 then
        -- Fallback: no valid positions
        return positions
    end
    
    alliedCenterX = alliedCenterX / validCount
    alliedCenterZ = alliedCenterZ / validCount
    
    -- Step 4: Draw line from allied center to threat center
    local dx = threatCenter.x - alliedCenterX
    local dz = threatCenter.z - alliedCenterZ
    local approachAngle = math.atan2(dz, dx)
    
    -- Step 5: The ideal rally point is where this line intersects the circle on the near side
    -- This is the point opposite the approach direction (allies approach from behind this point)
    local idealAngle = approachAngle + math.pi  -- Flip 180° to get near side from allied perspective
    
    -- Step 6-8: Distribute units along an arc ±60° from ideal point (120° total span)
    local arcSpan = math.rad(120)  -- Total arc width
    local halfArc = arcSpan / 2    -- ±60° from ideal
    
    -- Calculate positions evenly distributed along the arc
    local angleStep = numUnits > 1 and arcSpan / (numUnits - 1) or 0
    local startAngle = idealAngle - halfArc
    
    for i = 1, numUnits do
        local angle = startAngle + (i - 1) * angleStep
        
        table.insert(positions, {
            x = threatCenter.x + math.cos(angle) * distance,
            y = threatCenter.y or 0,
            z = threatCenter.z + math.sin(angle) * distance
        })
    end
    
    return positions
end

function OperationalCommander:planOrdersForIdleUnits()
    local idleUnits = self:getAvailableGroupCommanders()
    
    -- Also check ALL units (even those with orders) for combat-ineffective retreaters
    -- that need REPOSITION orders to stop endless retreat
    local allUnits = {}
    for _, commander in pairs(GroupCommander.getInstances(self.color)) do
        table.insert(allUnits, commander)
    end
    
    if #idleUnits == 0 and #allUnits == 0 then
        return
    end
    
    -- Separate units into combat-effective and combat-ineffective
    local effectiveUnits = {}
    local ineffectiveUnits = {}
    
    -- Check idle units first
    for _, commander in ipairs(idleUnits) do
        local statusReport = commander:getStatusReport()
        local totalUnits = #commander.initialUnitNames
        local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(statusReport.aliveCount, totalUnits)
        local hadAmmoInitially = commander.initialAmmoCount and commander.initialAmmoCount > 0
        local isOutOfAmmo = hadAmmoInitially and statusReport.ammoCount == 0
        local isUnarmed = statusReport.ammoCount == 0 and not hadAmmoInitially
        
        -- Combat-ineffective: out of ammo, heavy casualties, or unarmed
        if isOutOfAmmo or attritionRate > 0.4 or isUnarmed then
            table.insert(ineffectiveUnits, commander)
        else
            table.insert(effectiveUnits, commander)
        end
    end
    
    -- Check ALL units for combat-ineffective retreaters without REPOSITION orders
    for _, commander in ipairs(allUnits) do
        -- Skip if already has REPOSITION order or is in idle list
        local hasReposOrder = commander.orders and commander.orders:isActive() and 
                            commander.orderContext and commander.orderContext.type == taskTypes.REPOSITION
        local isIdle = false
        for _, idle in ipairs(idleUnits) do
            if idle == commander then
                isIdle = true
                break
            end
        end
        
        if not hasReposOrder and not isIdle then
            local statusReport = commander:getStatusReport()
            local totalUnits = #commander.initialUnitNames
            local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(statusReport.aliveCount, totalUnits)
            local hadAmmoInitially = commander.initialAmmoCount and commander.initialAmmoCount > 0
            local isOutOfAmmo = hadAmmoInitially and statusReport.ammoCount == 0
            local isUnarmed = statusReport.ammoCount == 0 and not hadAmmoInitially
            
            -- If combat-ineffective and currently retreating autonomously, give REPOSITION order
            local needsReposition = false
            if commander.disposition == dispositionTypes.RETREAT then
                -- Combat units out of ammo or heavily damaged
                if isOutOfAmmo or attritionRate > 0.4 then
                    needsReposition = true
                -- Unarmed recon units that have lost direct contact (only seeing shared intel)
                elseif isUnarmed and commander.directLOSCount == 0 then
                    needsReposition = true
                end
            end
            
            if needsReposition then
                -- Abort any active orders first
                if commander.orders and commander.orders:isActive() then
                    commander.orders:abort("combat_ineffective_reposition")
                end
                table.insert(ineffectiveUnits, commander)
            end
        end
    end
    
    -- Remove duplicates from ineffectiveUnits
    local seen = {}
    local uniqueIneffective = {}
    for _, commander in ipairs(ineffectiveUnits) do
        if not seen[commander.groupName] then
            seen[commander.groupName] = true
            table.insert(uniqueIneffective, commander)
        end
    end
    ineffectiveUnits = uniqueIneffective
    
    -- Reposition combat-ineffective units to safety
    if #ineffectiveUnits > 0 then
        for _, commander in ipairs(ineffectiveUnits) do
            local statusReport = commander:getStatusReport()
            local totalUnits = #commander.initialUnitNames
            local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(statusReport.aliveCount, totalUnits)
            local hadAmmoInitially = commander.initialAmmoCount and commander.initialAmmoCount > 0
            local isOutOfAmmo = hadAmmoInitially and statusReport.ammoCount == 0
            local isUnarmed = statusReport.ammoCount == 0 and not hadAmmoInitially
            
            local reason
            if isOutOfAmmo then
                reason = "ammo depleted"
            elseif attritionRate > 0.4 then
                reason = "heavy casualties: " .. string.format("%.0f%%", attritionRate * 100)
            elseif isUnarmed then
                reason = "unarmed unit in contact"
            else
                reason = "combat ineffective"
            end
            
            env.info("*** " .. self.color .. " Ops: Repositioning " .. commander.groupName .. 
                     " to rear (" .. reason .. ")")
            
            -- Find nearest friendly objective as safe position
            local safePosition = self:findNearestFriendlyPosition(commander)
            
            if safePosition then
                local order = Order.new({
                    assignedTo = commander.groupName,
                    objective = nil,  -- No specific objective
                    position = safePosition,
                    radius = 500,
                    type = taskTypes.REPOSITION,
                    alr = alr.LOW,
                    deadline = timer.getTime() + 3600,
                })
                
                self:addPlannedOrder(commander, order, nil)
            end
        end
    end
    
    -- Use remaining combat-effective units for offensive tasks
    if #effectiveUnits == 0 then
        return
    end
    
    -- Find objectives that need more forces
    for _, objective in ipairs(self.orderCoordinator.objectives) do
        if objective.status == "Active" then
            local statusCounts = objective:getOrderStatusCounts()
            
            -- If objective has some aborted orders, send idle units to help
            if statusCounts.aborted > 0 and #effectiveUnits > 0 then
                local threats = self:getThreatsNearPosition(objective.position, self.reconRadius)
                local threatCount = 0
                for _ in pairs(threats) do
                    threatCount = threatCount + 1
                end
                
                if threatCount > 0 then
                    -- Send as assault (only combat-effective units)
                    for _, commander in ipairs(effectiveUnits) do
                        local order = Order.new({
                            assignedTo = commander.groupName,
                            objective = objective,
                            position = objective.position,
                            radius = objective.radius,
                            type = taskTypes.ASSAULT,
                            alr = alr.HIGH,
                            deadline = timer.getTime() + 1800,
                        })
                        
                        self:addPlannedOrder(commander, order, threats)
                    end
                    return  -- All idle units assigned
                end
            end
        end
    end
    
    -- If no objectives need help, send idle units to patrol/recon
    -- (Could expand this to send them to nearest objective or rally point)
end

function OperationalCommander:planResponseToDetectedThreats()
    -- Check if any groups have detected threats and could use support
    local groupsWithThreats = {}
    
    for _, commander in pairs(GroupCommander.getInstances(self.color)) do
        local status = commander:getStatus()
        local threatCount = 0
        
        for _ in pairs(status.threats) do
            threatCount = threatCount + 1
        end
        
        -- Only request support if group has active orders (not finished/idle)
        if threatCount > 0 and status.position and status.orderStatus and 
           status.orderStatus ~= orderStatus.COMPLETED and 
           status.orderStatus ~= orderStatus.ABORTED then
            table.insert(groupsWithThreats, {
                commander = commander, 
                threatCount = threatCount, 
                position = status.position,
                threats = status.threats
            })
        end
    end
    
    if #groupsWithThreats == 0 then
        return
    end
    
    -- For each group in contact, see if we have reserves to send
    local availableReserves = self:getAvailableGroupCommanders()
    
    if #availableReserves == 0 then
        return
    end
    
    -- Respond to each threat situation
    for _, groupInfo in ipairs(groupsWithThreats) do
        if #availableReserves == 0 then
            break
        end
        
        -- Score reserves by suitability for assault against these threats and distance
        local scoredReserves = self:scoreCommandersForAssault(availableReserves, groupInfo.threats, groupInfo.position)
        local reservesInTimeWindow = self:selectCommandersWithinTimeWindow(scoredReserves, groupInfo.position, 1200)
        
        -- If no reserves in time window, send closest 1-2 anyway
        if #reservesInTimeWindow == 0 and #scoredReserves > 0 then
            local maxToSend = math.min(2, #scoredReserves)
            for i = 1, maxToSend do
                table.insert(reservesInTimeWindow, scoredReserves[i])
            end
        end
        
        if #reservesInTimeWindow > 0 then
            -- Calculate center of the threat cluster (not the friendly's position)
            local threatCenter = SpatialAgent.calculateThreatCenter(groupInfo.threats)
            if not threatCenter then
                threatCenter = groupInfo.position  -- Fallback to friendly position
            end
            
            -- Send 1-2 reserves to support (depending on threat size)
            local supportCount = math.min(#reservesInTimeWindow, math.max(1, math.floor(groupInfo.threatCount / 2)))
            
            for i = 1, supportCount do
                local reserve = reservesInTimeWindow[i].commander
                local reserveStatus = reserve:getStatus()
                
                -- Issue RALLY order to position around the threat cluster for coordinated assault
                local rallyPos = self:calculateSupportRallyPosition(threatCenter, reserveStatus.position, i, supportCount)
                local order = Order.new({
                    assignedTo = reserve.groupName,
                    objective = nil,  -- No formal objective, just support
                    position = rallyPos,
                    radius = 300,
                    type = taskTypes.RALLY,
                    alr = alr.MEDIUM,
                    deadline = timer.getTime() + 600,
                })
                
                self:addPlannedOrder(reserve, order, groupInfo.threats)
                
                -- Remove from available reserves
                for idx, r in ipairs(availableReserves) do
                    if r.groupName == reserve.groupName then
                        table.remove(availableReserves, idx)
                        break
                    end
                end
            end
        end
    end
end

function OperationalCommander:planAssaultOrders(objective, threats)
    local availableCommanders = self:getAvailableGroupCommanders()
    
    -- Calculate center of threat cluster
    local threatCenter = SpatialAgent.calculateThreatCenter(threats)
    if not threatCenter then
        threatCenter = objective.position
    end
    
    -- Use assault scoring to send best-matched units
    local scoredCommanders = self:scoreCommandersForAssault(availableCommanders, threats, threatCenter)
    
    for _, commanderInfo in ipairs(scoredCommanders) do
        local commander = commanderInfo.commander
        local order = Order.new({
            assignedTo = commander.groupName,
            objective = objective,
            position = threatCenter,
            radius = self.assaultRadius,
            type = taskTypes.ASSAULT,
            alr = alr.HIGH,
            deadline = objective.deadline or (timer.getTime() + 1800),
        })
        
        self:addPlannedOrder(commander, order, threats)
    end
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
    -- Get friendly groups near position and analyze their combined strength
    -- excludeGroupName: don't include this group (the one receiving the intel)
    local ThreatAnalyzer = require("threat-analyzer")
    local nearbyGroups = self:getOwnGroupsNearPosition(position, radius)
    
    local allUnits = {}
    for _, commander in ipairs(nearbyGroups) do
        if commander.groupName ~= excludeGroupName then
            local group = Group.getByName(commander.groupName)
            if group and group:isExist() then
                local units = group:getUnits()
                for _, unit in ipairs(units) do
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
    
    -- Use ThreatAnalyzer to get combined strength
    return ThreatAnalyzer.analyzeUnits(allUnits)
end

-- ============================================================================
-- UNIT SCORING AND SELECTION HELPERS
-- ============================================================================

function OperationalCommander:scoreCommandersForRecon(commanders, targetPosition)
    -- Score commanders for RECON missions
    -- Prefer: lighter units, smaller groups, closer to target
    local ThreatAnalyzer = require("threat-analyzer")
    local scored = {}
    
    for _, commander in ipairs(commanders) do
        local status = commander:getStatus()
        if status.position then
            local group = Group.getByName(commander.groupName)
            if group and group:isExist() then
                local units = group:getUnits()
                local activeUnits = {}
                for _, unit in ipairs(units) do
                    if unit and unit:isExist() then
                        table.insert(activeUnits, unit)
                    end
                end
                
                if #activeUnits > 0 then
                    local analysis = ThreatAnalyzer.analyzeUnits(activeUnits)
                    local distance = SpatialAgent.distance2D(status.position, targetPosition)
                    
                    -- Lower score is better for RECON
                    -- Score based on: offensive capability (lower is better) + distance + group size
                    local offensiveTotal = analysis.offensiveCapability.vsArmor + analysis.offensiveCapability.vsInfantry
                    local score = (offensiveTotal * 10) + (distance / 100) + (analysis.count * 5)
                    
                    table.insert(scored, {
                        commander = commander,
                        score = score,
                        distance = distance,
                        analysis = analysis
                    })
                end
            end
        end
    end
    
    -- Sort by score (lower is better for RECON)
    table.sort(scored, function(a, b)
        return a.score < b.score
    end)
    
    return scored
end

function OperationalCommander:scoreCommandersForAssault(commanders, threats, targetPosition)
    -- Score commanders for ASSAULT missions
    -- Prefer: favorable matchups, closer to target
    local ThreatAnalyzer = require("threat-analyzer")
    local scored = {}
    
    -- Analyze threat composition
    local threatUnits = {}
    for unitName, threat in pairs(threats) do
        local unit = Unit.getByName(unitName)
        if unit and unit:isExist() then
            table.insert(threatUnits, unit)
        end
    end
    local threatAnalysis = ThreatAnalyzer.analyzeUnits(threatUnits)
    
    for _, commander in ipairs(commanders) do
        local status = commander:getStatus()
        if status.position then
            local group = Group.getByName(commander.groupName)
            if group and group:isExist() then
                local units = group:getUnits()
                local activeUnits = {}
                for _, unit in ipairs(units) do
                    if unit and unit:isExist() then
                        table.insert(activeUnits, unit)
                    end
                end
                
                if #activeUnits > 0 then
                    -- Get detailed status report to check combat capability
                    local statusReport = commander:getStatusReport()
                    
                    -- Skip units with no offensive capability
                    -- - No ammo (current) means can't assault (includes both depleted and never-armed units)
                    -- - Heavy casualties (>50% losses) means unit is combat ineffective
                    local totalUnits = #commander.initialUnitNames
                    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(statusReport.aliveCount, totalUnits)
                    
                    if statusReport.ammoCount == 0 then
                        env.info("*** " .. self.color .. " Ops: Skipping " .. commander.groupName .. 
                                 " for assault (no ammo)")
                    elseif attritionRate > 0.3 then
                        env.info("*** " .. self.color .. " Ops: Skipping " .. commander.groupName .. 
                                 " for assault (heavy casualties: " .. 
                                 string.format("%.0f%%", attritionRate * 100) .. ")")
                    else
                        -- Unit is combat-effective, score it for assault
                        local distance = SpatialAgent.distance2D(status.position, targetPosition)
                        
                        -- Compare forces to get favorability
                        local comparison = ThreatAnalyzer.compareForces(activeUnits, threatUnits)
                        
                        -- Higher score is better for ASSAULT
                        -- Score based on: favorability (higher is better) - distance penalty
                        local favorabilityScore = comparison.favorability
                        if favorabilityScore == math.huge then
                            favorabilityScore = 100
                        elseif favorabilityScore == -math.huge then
                            favorabilityScore = -100
                        end
                        
                        local score = (favorabilityScore * 100) - (distance / 100)
                        
                        table.insert(scored, {
                            commander = commander,
                            score = score,
                            distance = distance,
                            analysis = comparison.friendly,
                            favorability = comparison.favorability
                        })
                    end
                end
            end
        end
    end
    
    -- Sort by score (higher is better for ASSAULT)
    table.sort(scored, function(a, b)
        return a.score > b.score
    end)
    
    return scored
end

function OperationalCommander:selectCommandersWithinTimeWindow(scoredCommanders, targetPosition, timeWindowSeconds)
    -- Filter commanders to those that can arrive within the time window
    -- Assume average ground speed of 20 m/s (~72 km/h, ~45 mph) for off-road military vehicles
    local avgSpeed = 20
    local maxDistance = avgSpeed * timeWindowSeconds
    
    local selected = {}
    for _, commanderInfo in ipairs(scoredCommanders) do
        if commanderInfo.distance <= maxDistance then
            table.insert(selected, commanderInfo)
        end
    end
    
    return selected
end

function OperationalCommander:calculateSupportRallyPosition(threatCenter, unitPosition, index, total)
    -- Calculate a rally position for support forces
    -- Position on the same side as the unit's current position to avoid crossing through threats
    local distance = 2000  -- 2km from threat center
    
    if unitPosition then
        -- Calculate direction from threat to unit's current position
        local dirX, dirZ, currentDist = SpatialAgent.calculateDirection(threatCenter, unitPosition)
        
        if dirX and currentDist > 1 then
            -- Add slight angular offset based on index to spread units out
            local angleOffset = (index - 1) * (math.pi / 4) -- 45 degree spacing
            
            -- Rotate the direction vector
            local rotatedX, rotatedZ = SpatialAgent.rotateVector(dirX, dirZ, angleOffset)
            
            return SpatialAgent.calculateDestination(threatCenter, rotatedX, rotatedZ, distance)
        end
    end
    
    -- Fallback: use evenly spaced positions around threat
    local angleStep = (2 * math.pi) / total
    local angle = angleStep * (index - 1)
    
    local dirX = math.cos(angle)
    local dirZ = math.sin(angle)
    
    return SpatialAgent.calculateDestination(threatCenter, dirX, dirZ, distance)
end

function OperationalCommander:findNearestFriendlyPosition(commander)
    -- Find a safe rear position for combat-ineffective units
    -- Prefer positions away from threats and near friendly objectives
    local status = commander:getStatus()
    if not status.position then
        return nil
    end
    
    -- Look for the nearest objective that's either captured or has no active threats
    local nearestSafeObjective = nil
    local minDistance = math.huge
    
    for _, objective in ipairs(self.orderCoordinator.objectives) do
        if objective.status == "Captured" or objective.status == "Active" then
            local dist = SpatialAgent.distance2D(status.position, objective.position)
            
            -- Check if there are threats near this objective
            local threats = self:getThreatsNearPosition(objective.position, self.reconRadius)
            local threatCount = self:countActiveThreats(threats)
            
            -- Prefer objectives with no active threats
            if threatCount == 0 and dist and dist < minDistance then
                minDistance = dist
                nearestSafeObjective = objective
            end
        end
    end
    
    -- If found a safe objective, position unit 2km behind it (away from frontline)
    if nearestSafeObjective then
        -- Calculate direction from objective to unit (rear direction)
        local dirX, dirZ, dist = SpatialAgent.calculateDirection(nearestSafeObjective.position, status.position)
        
        if dirX and dist > 1 then
            -- Position 2km behind objective in same direction as unit's current position
            return SpatialAgent.calculateDestination(nearestSafeObjective.position, dirX, dirZ, 2000)
        else
            -- Unit is at objective, just stay there
            return nearestSafeObjective.position
        end
    end
    
    -- No safe objective found, move 3km away from current position toward rear
    return {
        x = status.position.x - 3000,
        y = status.position.y or 0,
        z = status.position.z
    }
end

function OperationalCommander:planDefendOrders(objective)
    -- Plan DEFEND orders for units to hold the objective
    local availableCommanders = self:getAvailableGroupCommanders()
    
    if #availableCommanders == 0 then
        return
    end
    
    -- Select at least one unit to defend, prefer stronger units
    local ThreatAnalyzer = require("threat-analyzer")
    local scoredCommanders = {}
    
    for _, commander in ipairs(availableCommanders) do
        local status = commander:getStatus()
        if status.position then
            local group = Group.getByName(commander.groupName)
            if group and group:isExist() then
                local units = group:getUnits()
                local activeUnits = {}
                for _, unit in ipairs(units) do
                    if unit and unit:isExist() then
                        table.insert(activeUnits, unit)
                    end
                end
                
                if #activeUnits > 0 then
                    local analysis = ThreatAnalyzer.analyzeUnits(activeUnits)
                    local distance = SpatialAgent.distance2D(status.position, objective.position)
                    
                    -- Score for defense: prefer stronger units that are close
                    local strength = analysis.offensiveCapability.vsArmor + analysis.offensiveCapability.vsInfantry
                    local score = strength - (distance / 100)
                    
                    table.insert(scoredCommanders, {
                        commander = commander,
                        score = score,
                        distance = distance
                    })
                end
            end
        end
    end
    
    if #scoredCommanders == 0 then
        return
    end
    
    -- Sort by score (higher is better)
    table.sort(scoredCommanders, function(a, b)
        return a.score > b.score
    end)
    
    -- Assign at least 1, up to 2 units to defend
    local defendCount = math.min(2, #scoredCommanders)
    
    for i = 1, defendCount do
        local commander = scoredCommanders[i].commander
        local order = Order.new({
            assignedTo = commander.groupName,
            objective = objective,
            position = objective.position,
            radius = objective.radius,
            type = taskTypes.DEFEND,
            alr = alr.MEDIUM,
            deadline = nil,  -- Indefinite
        })
        
        self:addPlannedOrder(commander, order)
    end
    
    -- Mark objective as achieved once we have defenders in place
    objective:markAchieved()
end

function OperationalCommander:addPlannedOrder(commander, order, threats, threatCenter)
    -- Add an order to the planned orders list and mark the commander as having an order this cycle
    -- This prevents multiple orders being issued to the same unit
    if not self.plannedThisCycle[commander.groupName] then
        table.insert(self.plannedOrders, {
            commander = commander,
            order = order,
            threats = threats,
            threatCenter = threatCenter,
        })
        self.plannedThisCycle[commander.groupName] = true
    end
end

return OperationalCommander

end)
__bundle_register("threat-analyzer", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local unitClassification = constants.unitClassification

-- ThreatAnalyzer provides coalition-agnostic force analysis
-- Can analyze any arbitrary collection of DCS units and compare opposing forces
-- 
-- The threat matrix works bidirectionally:
-- - Unit's threats.armor = offensive capability against armor
-- - Enemy's threats.infantry = my vulnerability to that enemy (if I'm infantry)

local ThreatAnalyzer = {}

-- ============================================================================
-- UNIT COLLECTION HELPERS
-- ============================================================================

-- Get unit references from a MIST unit table (array of unit names)
function ThreatAnalyzer.getUnitsFromMistTable(unitNames)
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
function ThreatAnalyzer.getUnitsFromGroups(groups)
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
function ThreatAnalyzer.getUnitsFromGroupNames(groupNames)
    local groups = {}
    for _, groupName in ipairs(groupNames) do
        local group = Group.getByName(groupName)
        if group and group:isExist() then
            table.insert(groups, group)
        end
    end
    return ThreatAnalyzer.getUnitsFromGroups(groups)
end

-- ============================================================================
-- UNIT CLASSIFICATION
-- ============================================================================

function ThreatAnalyzer.classifyUnit(unit)
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
    
    -- Log unknown unit types to help with configuration
    env.info("WARNING: ThreatAnalyzer - Unknown unit type '" .. typeName .. "' - using default classification")
    
    -- Default classification for unknown units (assume infantry-like)
    return {category = "infantry", threats = {infantry = 1, ["light-armor"] = 1, ["heavy-armor"] = 0, support = 1}}
end

-- ============================================================================
-- FORCE ANALYSIS
-- ============================================================================

-- Analyze a collection of units and return comprehensive force assessment
function ThreatAnalyzer.analyzeUnits(units)
    local analysis = {
        count = 0,
        composition = {
            infantry = 0,
            ["light-armor"] = 0,
            ["heavy-armor"] = 0,
            support = 0
        },
        offensiveCapability = {
            vsInfantry = 0,
            vsArmor = 0,
            vsAir = 0
        }
    }
    
    if not units or #units == 0 then
        return analysis
    end
    
    for _, unit in ipairs(units) do
        if unit and unit:isExist() then
            local classification = ThreatAnalyzer.classifyUnit(unit)
            
            -- Count units by category
            analysis.count = analysis.count + 1
            if classification.category == "infantry" then
                analysis.composition.infantry = analysis.composition.infantry + 1
            elseif classification.category == "light-armor" then
                analysis.composition["light-armor"] = analysis.composition["light-armor"] + 1
            elseif classification.category == "heavy-armor" then
                analysis.composition["heavy-armor"] = analysis.composition["heavy-armor"] + 1
            elseif classification.category == "support" then
                analysis.composition.support = analysis.composition.support + 1
            end
            
            -- Accumulate offensive capabilities
            analysis.offensiveCapability.vsInfantry = analysis.offensiveCapability.vsInfantry + classification.threats.infantry
            -- vsArmor combines threats to both light and heavy armor
            analysis.offensiveCapability.vsArmor = analysis.offensiveCapability.vsArmor + 
                                                    classification.threats["light-armor"] + 
                                                    classification.threats["heavy-armor"]
            analysis.offensiveCapability.vsAir = analysis.offensiveCapability.vsAir + classification.threats.support
        end
    end
    
    return analysis
end

-- Calculate combat power of a force against an enemy
-- Returns how much damage this force can inflict on the enemy based on actual unit counts
function ThreatAnalyzer.calculateCombatPower(forceAnalysis, enemyAnalysis)
    if forceAnalysis.count == 0 or enemyAnalysis.count == 0 then
        return 0
    end
    
    -- Calculate damage we can do to each enemy unit type (capability * enemy count)
    local damageToInfantry = forceAnalysis.offensiveCapability.vsInfantry * enemyAnalysis.composition.infantry
    local damageToArmor = forceAnalysis.offensiveCapability.vsArmor * 
                          (enemyAnalysis.composition["light-armor"] + enemyAnalysis.composition["heavy-armor"])
    local damageToSupport = forceAnalysis.offensiveCapability.vsAir * enemyAnalysis.composition.support
    
    local totalPower = damageToInfantry + damageToArmor + damageToSupport
    
    return totalPower
end

-- ============================================================================
-- FORCE COMPARISON
-- ============================================================================

-- Compare two opposing forces and return favorability assessment
-- Returns positive values when friendly force is favored, negative when enemy is favored
function ThreatAnalyzer.compareForces(friendlyUnits, enemyUnits)
    local friendlyAnalysis = ThreatAnalyzer.analyzeUnits(friendlyUnits)
    local enemyAnalysis = ThreatAnalyzer.analyzeUnits(enemyUnits)
    
    -- Handle edge cases
    if friendlyAnalysis.count == 0 and enemyAnalysis.count == 0 then
        return {
            favorability = 0,
            friendly = friendlyAnalysis,
            enemy = enemyAnalysis,
            friendlyVulnerability = {overall = 0, fromInfantry = 0, fromArmor = 0, fromAir = 0},
            enemyVulnerability = {overall = 0, fromInfantry = 0, fromArmor = 0, fromAir = 0}
        }
    end
    
    if enemyAnalysis.count == 0 then
        return {
            favorability = math.huge,
            friendly = friendlyAnalysis,
            enemy = enemyAnalysis,
            friendlyVulnerability = {overall = 0, fromInfantry = 0, fromArmor = 0, fromAir = 0},
            enemyVulnerability = {overall = 0, fromInfantry = 0, fromArmor = 0, fromAir = 0}
        }
    end
    
    if friendlyAnalysis.count == 0 then
        return {
            favorability = -math.huge,
            friendly = friendlyAnalysis,
            enemy = enemyAnalysis,
            friendlyVulnerability = {overall = 0, fromInfantry = 0, fromArmor = 0, fromAir = 0},
            enemyVulnerability = {overall = 0, fromInfantry = 0, fromArmor = 0, fromAir = 0}
        }
    end
    
    -- Calculate combat power for both sides
    local friendlyPower = ThreatAnalyzer.calculateCombatPower(friendlyAnalysis, enemyAnalysis)
    local enemyPower = ThreatAnalyzer.calculateCombatPower(enemyAnalysis, friendlyAnalysis)
    
    -- Calculate favorability as ratio of our power to their power
    -- Higher = we can hurt them more than they can hurt us
    local favorability = 1.0
    if enemyPower > 0 then
        favorability = friendlyPower / enemyPower
    elseif friendlyPower > 0 then
        favorability = math.huge
    end
    
    return {
        favorability = favorability,
        friendly = friendlyAnalysis,
        enemy = enemyAnalysis,
        friendlyPower = friendlyPower,
        enemyPower = enemyPower
    }
end

return ThreatAnalyzer

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

-- Check if we have any recently observed or suspected threats
-- Returns: true if there are threats with fresh intel (within maxAge seconds)
function ThreatTracker:hasRecentThreats(maxAge)
    local currentTime = timer.getTime()
    maxAge = maxAge or 120  -- Default 2 minutes
    
    for _, threat in pairs(self.threats) do
        if threat.lastSighting then
            local age = currentTime - threat.lastSighting
            if age <= maxAge and (threat.status == "Observed" or threat.status == "Suspected") then
                return true
            end
        end
    end
    
    return false
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

-- Check if threat intel is stale (no fresh observations recently)
-- Returns: true if no observed threats and last sighting was > maxAge ago
function ThreatTracker:isIntelStale(maxAge)
    local currentTime = timer.getTime()
    maxAge = maxAge or 60  -- Default 60 seconds
    
    -- Check if we have any currently observed threats
    local hasObserved = false
    local hasSuspected = false
    
    for _, threat in pairs(self.threats) do
        if threat.status == "Observed" then
            hasObserved = true
            break
        elseif threat.status == "Suspected" then
            hasSuspected = true
        end
    end
    
    -- If we have observed threats, intel is fresh
    if hasObserved then
        return false
    end
    
    -- If we only have suspected threats, check how old they are
    if not hasSuspected then
        return true  -- No observed or suspected threats at all
    end
    
    -- Check time since last sighting
    local mostRecentSighting = self:getMostRecentSightingTime()
    if mostRecentSighting == 0 then
        return true
    end
    
    local timeSinceLastSighting = currentTime - mostRecentSighting
    return timeSinceLastSighting >= maxAge
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
-- @return number Original magnitude
function SpatialAgent.normalizeVector(dx, dz)
    local magnitude = math.sqrt(dx * dx + dz * dz)
    
    if magnitude < 0.001 then  -- Near-zero length
        return 0, 0, 0
    end
    
    return dx / magnitude, dz / magnitude, magnitude
end

--- Rotate a 2D vector by angle
-- @param dx X component
-- @param dz Z component  
-- @param angleRadians Rotation angle in radians (positive = counterclockwise)
-- @return number, number Rotated dx, dz
function SpatialAgent.rotateVector(dx, dz, angleRadians)
    local cosAngle = math.cos(angleRadians)
    local sinAngle = math.sin(angleRadians)
    
    local rotatedX = dx * cosAngle - dz * sinAngle
    local rotatedZ = dx * sinAngle + dz * cosAngle
    
    return rotatedX, rotatedZ
end

--- Calculate direction vector from one position to another
-- @param fromPos Starting position
-- @param toPos Target position
-- @return number, number Direction dx, dz (normalized), or nil if invalid
-- @return number Distance between positions
function SpatialAgent.calculateDirection(fromPos, toPos)
    local dist = SpatialAgent.distance2D(fromPos, toPos)
    if not dist or dist < 0.001 then
        return nil, nil, 0
    end
    
    local p1 = fromPos.p or fromPos
    local p2 = toPos.p or toPos
    
    local dx = p2.x - p1.x
    local dz = p2.z - p1.z
    
    local dirX, dirZ = SpatialAgent.normalizeVector(dx, dz)
    return dirX, dirZ, dist
end

-- ============================================================================
-- TACTICAL POSITIONING
-- ============================================================================

--- Calculate destination point from origin in a direction
-- @param origin Starting position {x, y, z}
-- @param directionX Normalized direction X component
-- @param directionZ Normalized direction Z component
-- @param distance Distance to travel in meters
-- @return table Destination position {x, y, z}
function SpatialAgent.calculateDestination(origin, directionX, directionZ, distance)
    if not origin then
        return nil
    end
    
    local p = origin.p or origin
    
    return {
        x = p.x + (directionX * distance),
        y = p.y or 0,
        z = p.z + (directionZ * distance)
    }
end

--- Calculate multiple staging positions around a center point
-- Positions are spread in an arc or circle for tactical deployment
-- @param center Center position {x, y, z}
-- @param radius Distance from center in meters
-- @param count Number of positions to generate
-- @param spreadAngleDegrees Arc width in degrees (360 = full circle, 120 = front arc)
-- @return table Array of positions
function SpatialAgent.calculateStagingPositions(center, radius, count, spreadAngleDegrees)
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
    return SpatialAgent.calculateStagingPositions(center, radius, count, 360)
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
__bundle_register("order-coordinator", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local SpatialAgent = require("spatial-agent")

local alr = constants.acceptableLevelsOfRisk
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

-- Derive order context for GroupCommander's ORIENT phase
-- This is a stateless calculation utility - commanders control WHEN it's called
function OrderCoordinator.deriveOrderContext(order, commanderPos, commanderALR)
    if not order or not order:isActive() then
        return nil
    end
    
    if not commanderPos then
        return nil
    end
    
    local orderedPosition = order.position
    local orderedRadius = order.radius or 500
    
    -- Calculate distance to ordered position
    local distanceToOrdered = SpatialAgent.distance2D(commanderPos, orderedPosition)
    
    -- Check if we're within the objective radius
    local withinObjective = distanceToOrdered <= orderedRadius
    
    -- Determine thresholds based on ALR
    local orderedALR = order.alr or alr.LOW
    local retreatThreshold = 0.4
    
    if orderedALR == alr.LOW then
        retreatThreshold = 0.8
    elseif orderedALR == alr.HIGH then
        retreatThreshold = 0.2
    end
    
    -- Return derived context snapshot
    return {
        position = orderedPosition,
        radius = orderedRadius,
        type = order.type,
        alr = orderedALR,
        distanceToOrdered = distanceToOrdered,
        withinObjective = withinObjective,
        retreatThreshold = retreatThreshold,
        leashDistance = 3000  -- Don't pursue threats beyond 3km from ordered position
    }
end

-- Derive objective context for OperationalCommander's ORIENT phase
-- Provides useful summaries for decision-making
function OrderCoordinator:deriveObjectiveContext(objective, statusCounts, threatsNear, threatCount)
    -- Determine last order type
    local lastOrderType = nil
    local lastCompletedCount = 0
    local lastAbortedCount = 0
    
    if #objective.orders > 0 then
        lastOrderType = objective.orders[#objective.orders].type
        -- Count how many of this order type completed vs aborted
        for i = #objective.orders, 1, -1 do
            if objective.orders[i].type == lastOrderType then
                if objective.orders[i].status == orderStatus.COMPLETED then
                    lastCompletedCount = lastCompletedCount + 1
                elseif objective.orders[i].status == orderStatus.ABORTED then
                    lastAbortedCount = lastAbortedCount + 1
                end
            else
                break  -- Different order type, stop counting
            end
        end
    end
    
    -- Calculate active assignments (who's working on this objective?)
    local activeAssignments = {}
    for _, order in ipairs(objective.orders) do
        if order.status == orderStatus.IN_PROGRESS or order.status == orderStatus.ASSIGNED then
            table.insert(activeAssignments, order.assignedTo)
        end
    end
    
    -- Return derived context snapshot
    return {
        objective = objective,  -- Reference for convenience
        
        -- Phase tracking
        lastOrderType = lastOrderType,
        lastCompletedCount = lastCompletedCount,
        lastAbortedCount = lastAbortedCount,
        requiresPlanning = (statusCounts.completed + statusCounts.aborted == statusCounts.total),
        
        -- Threat summary
        threatsNear = threatsNear,
        threatCount = threatCount,
        
        -- Order status summary
        statusCounts = statusCounts,
        
        -- Assignment tracking
        activeAssignments = activeAssignments
    }
end

-- Check if an order has changed enough to warrant re-issuing
-- Stateless calculation utility
function OrderCoordinator.isOrderChanged(lastOrder, newOrder, commanderStatus)
    if not lastOrder then
        return true
    end
    
    -- If the commander's current order is COMPLETED or ABORTED, always issue new orders
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
    
    -- Position changed by more than 100m
    if math.abs(lastOrder.position.x - newOrder.position.x) > 100 or
       math.abs(lastOrder.position.z - newOrder.position.z) > 100 then
        return true
    end
    
    if lastOrder.radius ~= newOrder.radius then
        return true
    end
    
    return false
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
__bundle_register("group-commander", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local ForceStatusAnalyzer = require("force-status-analyzer")
local OODACommander = require("ooda-commander")
local OrderCoordinator = require("order-coordinator")
local SpatialAgent = require("spatial-agent")
local ThreatAnalyzer = require("threat-analyzer")
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
    -- Only update position/time if we have a valid currentPos
    if currentPos then
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
    
    -- Check for expected threats we didn't see
    local ownPos = self:getOwnPosition()
    local expectedCount = 0
    if ownPos then
        local expectedInArea = self.threatTracker:expectedThreats(ownPos, detectionRadius)
        expectedCount = #expectedInArea
        for _, threatName in ipairs(expectedInArea) do
            -- If we expected to see it but didn't, update status
            local wasSeen = false
            for _, observed in ipairs(observedThreats) do
                if observed.name == threatName then
                    wasSeen = true
                    break
                end
            end
            if not wasSeen then
                local threat = self.threatTracker:getThreat(threatName)
                if threat then
                    -- Check distance to last known position
                    local distToLastKnown = SpatialAgent.distance2D(ownPos, threat.position)
                    
                    -- If close to last known position, mark UNCONFIRMED
                    -- Otherwise just mark SUSPECTED (we haven't checked yet)
                    if distToLastKnown < 1000 then  -- Within 1km of last known position
                        if threat.status == "Observed" or threat.status == "Suspected" then
                            self.threatTracker:markThreatStatus(threatName, "Unconfirmed")
                        end
                    else
                        if threat.status == "Observed" then
                            self.threatTracker:markThreatStatus(threatName, "Suspected")
                        end
                    end
                end
            end
        end
    end
    
    -- Age threats and progress their status
    self.threatTracker:ageThreats()
    
    -- Store direct LOS count for decision-making (to distinguish self-observed from shared intel)
    self.directLOSCount = #visibleThreatNames
    
    -- Single consolidated OBSERVE summary
    local memoryCount = self.threatTracker:count()
    local expectedStr = expectedCount > 0 and (" Exp:" .. expectedCount) or ""
    env.info(self.groupName .. " OBSERVE: LOS:" .. #visibleThreatNames .. expectedStr .. " Mem:" .. memoryCount)
end

function GroupCommander:orient()
    -- Gather situational awareness for decision making
    self:assessOwnForce()
    self:assessThreats()
    self:assessOrderContext()
end

function GroupCommander:decide()
    -- Check if we have valid assessment data
    if not self.ownForceStrength or not self.threatAssessment then
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = nil
        return
    end
    
    -- Check for critical status conditions that override normal decisions
    if self:handleCriticalStatusConditions() then
        return  -- Status condition forced a decision, skip normal flow
    end
    
    -- Handle order lifecycle
    if self.orders and self.orders:isActive() then
        self:handleOrderDecisions()
    else
        self:handleAutonomousDecisions()
    end
end

function GroupCommander:act()
    -- Set ROE based on disposition
    if self.disposition == dispositionTypes.ADVANCE then
        self:setROE(roe.WEAPON_FREE)
    elseif self.disposition == dispositionTypes.RETREAT then
        self:setROE(roe.RETURN_FIRE)
    elseif self.disposition == dispositionTypes.HOLD then
        self:setROE(roe.RETURN_FIRE)
    elseif self.disposition == dispositionTypes.DEFEND then
        self:setROE(roe.WEAPON_FREE)
    else
        self:setROE(roe.WEAPON_HOLD)
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

-- Assess context related to current orders
function GroupCommander:assessOrderContext()
    -- Use OrderCoordinator to derive context snapshot
    local ownPos = self:getOwnPosition()
    self.orderContext = OrderCoordinator.deriveOrderContext(self.orders, ownPos, self.alr)
end

-- Assess own force strength and capabilities
function GroupCommander:assessOwnForce()
    self.ownForceStrength = self:analyzeOwnForce()
    
    if not self.ownForceStrength then
        env.info("ERROR: Could not analyze own force for " .. self.groupName)
    end
end

function GroupCommander:analyzeOwnForce()
    -- Get all units in our group
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        return nil
    end
    
    local groupUnits = group:getUnits()
    local units = {}
    
    for _, unit in ipairs(groupUnits) do
        if unit and unit:isExist() then
            table.insert(units, unit)
        end
    end
    
    -- Use ThreatAnalyzer for comprehensive force analysis
    return ThreatAnalyzer.analyzeUnits(units)
end

function GroupCommander:analyzeThreatCapabilities()
    -- Get threat units from threat tracker
    -- Only include threats that are Observed or recently Suspected (not stale)
    local threats = self.threatTracker:getThreats()
    local threatUnits = {}
    local currentTime = timer.getTime()
    
    for unitName, threatData in pairs(threats) do
        -- Only include threats that are actively relevant
        local includeInAnalysis = false
        
        if threatData.status == "Observed" then
            includeInAnalysis = true
        elseif threatData.status == "Suspected" and threatData.lastSighting then
            -- Include suspected threats if seen within last 60 seconds
            local timeSinceLastSeen = currentTime - threatData.lastSighting
            if timeSinceLastSeen < 60 then
                includeInAnalysis = true
            end
        end
        
        if includeInAnalysis then
            local unit = Unit.getByName(unitName)
            if unit and unit:isExist() then
                table.insert(threatUnits, unit)
            end
        end
    end
    
    -- Use ThreatAnalyzer for comprehensive force analysis
    return ThreatAnalyzer.analyzeUnits(threatUnits)
end

-- Assess threat situation including staleness, center of mass, and comparative strength
function GroupCommander:assessThreats()
    if not self.ownForceStrength then
        self.threatAssessment = nil
        return
    end
    
    -- Get threat status breakdown
    local threatStatuses = self:checkThreatStatuses()
    
    -- Analyze threat capabilities
    local threatAnalysis = self:analyzeThreatCapabilities()
    
    -- Calculate threat center if threats exist
    local threatCenter = nil
    if threatAnalysis.count > 0 then
        threatCenter = self:calculateThreatCenter()
    end
    
    -- Calculate favorability if threats exist
    local favorability = 0
    
    if threatAnalysis.count > 0 then
        
        -- If we have ally intel, include nearby allies in combined force calculation
        local combinedForce = self.ownForceStrength
        if self.allyIntel and self.allyIntel.count > 0 then
            -- Combine our force with nearby allies
            combinedForce = {
                count = self.ownForceStrength.count + self.allyIntel.count,
                composition = {
                    infantry = self.ownForceStrength.composition.infantry + self.allyIntel.composition.infantry,
                    ["light-armor"] = self.ownForceStrength.composition["light-armor"] + self.allyIntel.composition["light-armor"],
                    ["heavy-armor"] = self.ownForceStrength.composition["heavy-armor"] + self.allyIntel.composition["heavy-armor"],
                    support = self.ownForceStrength.composition.support + self.allyIntel.composition.support
                },
                offensiveCapability = {
                    vsInfantry = self.ownForceStrength.offensiveCapability.vsInfantry + self.allyIntel.offensiveCapability.vsInfantry,
                    vsArmor = self.ownForceStrength.offensiveCapability.vsArmor + self.allyIntel.offensiveCapability.vsArmor,
                    vsAir = self.ownForceStrength.offensiveCapability.vsAir + self.allyIntel.offensiveCapability.vsAir
                }
            }
        end
        
        -- Calculate favorability using combined force (our power / enemy power)
        local ourPower = ThreatAnalyzer.calculateCombatPower(combinedForce, threatAnalysis)
        local enemyPower = ThreatAnalyzer.calculateCombatPower(threatAnalysis, combinedForce)
        
        if enemyPower > 0 then
            favorability = ourPower / enemyPower
        elseif ourPower > 0 then
            favorability = math.huge
        end
        
        -- Get status report for logging
        local statusReport = self:getStatusReport()
        
        -- Log assessment in compact format with ally contribution
        local allyStr = ""
        if self.allyIntel and self.allyIntel.count > 0 then
            allyStr = " +Ally:" .. self.allyIntel.count .. 
                      "(" .. self.allyIntel.composition.infantry .. "/" .. 
                      self.allyIntel.composition["light-armor"] .. "/" .. 
                      self.allyIntel.composition["heavy-armor"] .. ")"
        end
        env.info(self.groupName .. " ORIENT: Us:" .. self.ownForceStrength.count .. 
                 "(" .. self.ownForceStrength.composition.infantry .. "/" .. 
                 self.ownForceStrength.composition["light-armor"] .. "/" .. 
                 self.ownForceStrength.composition["heavy-armor"] .. ")" .. allyStr .. 
                 " vs Them:" .. threatAnalysis.count .. 
                 "(" .. threatAnalysis.composition.infantry .. "/" .. 
                 threatAnalysis.composition["light-armor"] .. "/" .. 
                 threatAnalysis.composition["heavy-armor"] .. 
                 ") Fav:" .. string.format("%.2f", favorability))
        
        -- Log detailed status report
        local avgHealth = statusReport.aliveCount > 0 and (statusReport.healthPool / statusReport.aliveCount) or 0
        env.info(self.groupName .. " STATUS: Units:" .. statusReport.aliveCount .. "/" .. #self.initialUnitNames .. 
                 " HP:" .. string.format("%.0f", avgHealth) .. 
                 " (low:" .. string.format("%.0f", statusReport.healthLowState or 0) .. ")" .. 
                 " Fuel:" .. string.format("%.0f%%", statusReport.fuelRemaining * 100) .. 
                 " Ammo:" .. statusReport.ammoCount .. 
                 " (low:" .. (statusReport.ammmoLowState or 0) .. ")")
    end
    
    -- Determine if threats are stale using ThreatTracker utility
    local threatsAreStale = self.threatTracker:isIntelStale(60)
    
    -- Store consolidated threat assessment
    self.threatAssessment = {
        count = threatAnalysis.count,
        analysis = threatAnalysis,
        statuses = threatStatuses,
        center = threatCenter,
        favorability = favorability,
        stale = threatsAreStale,
        hasRecentIntel = self.threatTracker:hasRecentThreats(120)  -- Any intel within 2 minutes
    }
end

function GroupCommander:calculateDestinationRelativeToThreats(threatCenter, retreat)
    local ownPos = self:getOwnPosition()
    if not ownPos or not threatCenter then
        env.info(self.groupName .. " Cannot calculate destination: missing position data")
        return nil
    end
    
    -- Calculate vector from threat to us
    local dx = ownPos.x - threatCenter.x
    local dz = ownPos.z - threatCenter.z
    
    -- TODO: Revisit this calculation for reasonable diretion choice, especially when close to threats
    -- Normalize
    local dirX, dirZ, distance = SpatialAgent.normalizeVector(dx, dz)
    if distance < 1 then
        -- Too close, pick arbitrary direction
        dirX = 1
        dirZ = 0
        distance = 1
    end
    
    -- Set movement distance based on action
    if retreat then
        -- Move away from threats
        local retreatDistance = 2000  -- 2km retreat
        return {
            x = ownPos.x + (dirX * retreatDistance),
            y = ownPos.y,
            z = ownPos.z + (dirZ * retreatDistance)
        }
    else
        -- Move toward threats (advance)
        local optimalRange = 250   -- Close to 250m for optimal engagement
        local weaponRange = 1000   -- Max weapon range is 1km
        
        local currentDistance = SpatialAgent.distance2D(ownPos, threatCenter)
        
        -- If beyond weapon range, move to weapon range
        -- If within weapon range, close to optimal range for better accuracy
        local targetRange = currentDistance > weaponRange and weaponRange or optimalRange
        
        -- If already at or closer than optimal range, stay put
        if currentDistance <= optimalRange then
            return nil
        end
        
        return {
            x = threatCenter.x + (dirX * targetRange),
            y = threatCenter.y or ownPos.y,
            z = threatCenter.z + (dirZ * targetRange)
        }
    end
end

function GroupCommander:calculateReturnToObjective()
    -- Calculate retreat destination back toward objective/friendly lines
    local ownPos = self:getOwnPosition()
    if not ownPos then
        return nil
    end
    
    local context = self.orderContext
    if context and context.position then
        -- Retreat toward ordered objective
        local dirX, dirZ, distance = SpatialAgent.calculateDirection(ownPos, context.position)
        
        if distance and distance > 1 then
            -- Move 1km back toward objective
            local retreatDistance = math.min(1000, distance)
            return SpatialAgent.calculateDestination(ownPos, dirX, dirZ, retreatDistance)
        end
    end
    
    -- No specific objective, just move backward from current heading
    return {
        x = ownPos.x - 1000,
        y = ownPos.y,
        z = ownPos.z
    }
end

function GroupCommander:calculateThreatCenter(observedOnly)
    -- Calculate the average position of threats based on last known positions
    -- observedOnly: if true, only include threats directly observed by THIS unit (not shared intel)
    local currentTime = timer.getTime()
    local threatsToInclude = {}
    
    local threats = self.threatTracker:getThreats()
    for unitName, threatData in pairs(threats) do
        -- Filter to only this unit's own observations if requested
        local includeThisThreat = true
        if observedOnly then
            -- Check if THIS unit has observed the threat recently (within last 30 seconds)
            local selfObservedRecently = false
            if threatData.sightings then
                for _, sighting in ipairs(threatData.sightings) do
                    if sighting.observedBy == self.groupName and 
                       (currentTime - sighting.observedAt) < 30 then
                        selfObservedRecently = true
                        break
                    end
                end
            end
            
            if not selfObservedRecently then
                -- Skip threats not directly observed by this unit
                includeThisThreat = false
            end
        end
        
        if includeThisThreat then
            table.insert(threatsToInclude, threatData)
        end
    end
    
    -- Use SpatialAgent to calculate center
    return SpatialAgent.calculateThreatCenter(threatsToInclude)
end

function GroupCommander:checkThreatStatuses()
    -- Check threat statuses and return info about whether threats are observed vs suspected/unconfirmed
    local threats = self.threatTracker:getThreats()
    local observed = 0
    local suspected = 0
    local unconfirmed = 0
    local other = 0
    local mostRecentObservation = 0
    
    for unitName, threatData in pairs(threats) do
        if threatData.status == "Observed" then
            observed = observed + 1
        elseif threatData.status == "Suspected" then
            suspected = suspected + 1
        elseif threatData.status == "Unconfirmed" then
            unconfirmed = unconfirmed + 1
        else
            other = other + 1
        end
        
        -- Track most recent observation time
        if threatData.lastSighting and threatData.lastSighting > mostRecentObservation then
            mostRecentObservation = threatData.lastSighting
        end
    end
    
    return {
        observed = observed,
        suspected = suspected,
        unconfirmed = unconfirmed,
        other = other,
        total = observed + suspected + unconfirmed + other,
        allSuspectedOrUnconfirmed = (observed == 0) and ((suspected + unconfirmed) > 0),
        hasUnconfirmed = unconfirmed > 0,
        mostRecentObservation = mostRecentObservation,
        timeSinceLastObservation = mostRecentObservation > 0 and (timer.getTime() - mostRecentObservation) or 0
    }
end

-- Decide to advance on threats (strong position)
function GroupCommander:decideAdvanceOnThreats()
    local threat = self.threatAssessment
    local context = self.orderContext
    
    env.info(self.groupName .. " DECIDE: ADVANCE (on threats, Fav:" .. string.format("%.2f", threat.favorability) .. ")")
    self:setDisposition(dispositionTypes.ADVANCE)
    
    local advanceDestination = self:calculateDestinationRelativeToThreats(threat.center, false)
    
    -- Verify advance doesn't exceed leash
    if advanceDestination and context then
        local destDist = SpatialAgent.distance2D(advanceDestination, context.position)
        
        if destDist > context.leashDistance then
            env.info(self.groupName .. " DECIDE: ADVANCE (leash limit, returning)")
            self.destination = self:getDestinationToObjective(context.position, context.radius)
        else
            self.destination = advanceDestination
        end
    else
        self.destination = advanceDestination
    end
end

-- Decide to move toward ordered position (moderate threat)
function GroupCommander:decideMoveToOrdered()
    local context = self.orderContext
    
    if not context then
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = nil
        return
    end
    
    if context.position and context.radius then
        self.destination = self:getDestinationToObjective(context.position, context.radius)
    else
        self.destination = nil
    end
    
    if self.destination then
        self:setDisposition(dispositionTypes.ADVANCE)
        env.info(self.groupName .. " DECIDE: ADVANCE (moving to objective)")
    else
        self:setDisposition(dispositionTypes.DEFEND)
        env.info(self.groupName .. " DECIDE: DEFEND (at objective)")
        
        -- Complete order if defending at objective
        if context and (context.type == taskTypes.RALLY or context.type == taskTypes.REINFORCE) then
            self.orders:complete()
        end
    end
end

-- Decide action when no threats exist
function GroupCommander:decideWithNoThreats()
    local context = self.orderContext
    if not context then
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = nil
        return
    end
    
    self.destination = self:getDestinationToObjective(context.position, context.radius)
    
    if self.destination then
        self:setDisposition(dispositionTypes.ADVANCE)
        env.info(self.groupName .. " DECIDE: ADVANCE (no threats, to objective)")
    else
        self:setDisposition(dispositionTypes.DEFEND)
        env.info(self.groupName .. " DECIDE: DEFEND (at objective)")
        
        -- Complete RALLY/REINFORCE orders when arriving at position
        if context.type == taskTypes.RALLY or context.type == taskTypes.REINFORCE then
            env.info(self.groupName .. " DECIDE: Completing RALLY order (arrived at rally point)")
            self.orders:complete()
        end
    end
end

-- Decide action when threats are stale/unconfirmed
function GroupCommander:decideWithStaleThreats()
    local context = self.orderContext
    
    if not context then
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = nil
        return
    end
    
    self.destination = self:getDestinationToObjective(context.position, context.radius)
    
    if self.destination then
        self:setDisposition(dispositionTypes.ADVANCE)
        env.info(self.groupName .. " DECIDE: ADVANCE (stale threats, to objective)")
    else
        self:setDisposition(dispositionTypes.HOLD)
        env.info(self.groupName .. " DECIDE: HOLD (stale threats, at objective)")
        
        -- Complete RALLY/REINFORCE orders when arriving at position
        if context.type == taskTypes.RALLY or context.type == taskTypes.REINFORCE then
            self.orders:complete()
        end
    end
end

function GroupCommander:getStatusReport()
    return ForceStatusAnalyzer.getStatusReport(self.groupName, self.initialUnitNames, self.fuelRemaining)
end

function GroupCommander:handleCriticalStatusConditions()
    local statusReport = self:getStatusReport()
    local totalCount = #self.initialUnitNames
    local threat = self.threatAssessment
    
    if totalCount == 0 or statusReport.aliveCount == 0 then
        return false  -- No units to make decisions for
    end
    
    -- Calculate attrition rate
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(statusReport.aliveCount, totalCount)
    local avgAmmoPerUnit = statusReport.ammoCount / statusReport.aliveCount
    
    -- Debug logging for high casualties
    if attritionRate > 0.3 then
        env.info(self.groupName .. " CRITICAL CHECK: Attrition=" .. 
                 string.format("%.0f%%", attritionRate * 100) .. 
                 " (" .. statusReport.aliveCount .. "/" .. totalCount .. ")")
    end
    
    -- CRITICAL: Heavy casualties (>40% losses) - force retreat regardless of favorability
    if attritionRate > 0.4 then
        env.info(self.groupName .. " DECIDE: RETREAT (critical casualties: " .. 
                 string.format("%.0f%%", attritionRate * 100) .. " losses)")
        
        -- Abort any active orders
        if self.orders and self.orders:isActive() then
            self.orders:abort("critical_casualties")
        end
        
        -- Retreat to safety - use only directly observed threats for stable retreat direction
        local observedThreatCenter = self:calculateThreatCenter(true)  -- observedOnly = true
        if observedThreatCenter then
            self.destination = self:calculateDestinationRelativeToThreats(observedThreatCenter, true)
        elseif threat and threat.center then
            -- Fallback to broader threat picture if no direct observations
            self.destination = self:calculateDestinationRelativeToThreats(threat.center, true)
        else
            self.destination = self:calculateReturnToObjective()
        end
        self:setDisposition(dispositionTypes.RETREAT)
        return true
    end
    
    -- CRITICAL: No ammunition - abort assault/attack orders
    -- Check for ANY unit with 0 ammo attempting offensive orders
    if statusReport.ammoCount == 0 then
        -- If we have an assault/attack order, abort it
        if self.orders and self.orders:isActive() then
            local context = self.orderContext
            if context and (context.type == taskTypes.ASSAULT or context.type == taskTypes.ATTACK) then
                env.info(self.groupName .. " DECIDE: Aborting ASSAULT (no ammunition)")
                self.orders:abort("no_ammo")
            end
        end
    end
    
    -- CRITICAL: Depleted ammunition - force retreat/hold (only for units that had ammo)
    -- Units that never had ammo (recon) can continue their non-combat missions
    if self.initialAmmoCount > 0 then
        if ForceStatusAnalyzer.isAmmoCritical(statusReport.ammoCount, self.initialAmmoCount, 5) then
            env.info(self.groupName .. " DECIDE: HOLD (ammunition depleted)")
            
            -- If already engaged with threats, retreat
            if threat.center and threat.count > 0 and not threat.stale then
                env.info(self.groupName .. " DECIDE: RETREAT (no ammo, threats present)")
                -- Use only directly observed threats for stable retreat direction
                local observedThreatCenter = self:calculateThreatCenter(true)
                if observedThreatCenter then
                    self.destination = self:calculateDestinationRelativeToThreats(observedThreatCenter, true)
                else
                    self.destination = self:calculateDestinationRelativeToThreats(threat.center, true)
                end
                self:setDisposition(dispositionTypes.RETREAT)
            else
                -- No immediate threats, just hold position
                self:setDisposition(dispositionTypes.HOLD)
                self.destination = nil
                self:stopMovement()
            end
            return true
        end
    end
    
    -- WARNING: Moderate casualties (30-40% losses) - modify decision thresholds
    if attritionRate > 0.3 then
        -- Force retreat if favorability is marginal (< 0.8 instead of < 0.6)
        if threat.favorability < 0.8 then
            env.info(self.groupName .. " DECIDE: RETREAT (casualties: " .. 
                     string.format("%.0f%%", attritionRate * 100) .. ", Fav:" .. 
                     string.format("%.2f", threat.favorability) .. ")")
            
            -- Abort any active assault/attack orders
            if self.orders and self.orders:isActive() then
                local context = self.orderContext
                if context and (context.type == taskTypes.ASSAULT or context.type == taskTypes.ATTACK) then
                    env.info(self.groupName .. " DECIDE: Aborting ASSAULT due to casualties")
                    self.orders:abort("casualties")
                end
            end
            
            -- Use only directly observed threats for stable retreat direction
            local observedThreatCenter = self:calculateThreatCenter(true)
            if observedThreatCenter then
                self.destination = self:calculateDestinationRelativeToThreats(observedThreatCenter, true)
            elseif threat.center then
                self.destination = self:calculateDestinationRelativeToThreats(threat.center, true)
            else
                self.destination = self:calculateReturnToObjective()
            end
            self:setDisposition(dispositionTypes.RETREAT)
            return true
        end
    end
    
    -- WARNING: Light-moderate casualties (20-30% losses) with unfavorable situation
    if attritionRate > 0.2 then
        -- Retreat early if situation is clearly unfavorable
        if threat.favorability < 0.65 then
            env.info(self.groupName .. " DECIDE: RETREAT (early casualties: " .. 
                     string.format("%.0f%%", attritionRate * 100) .. ", Fav:" .. 
                     string.format("%.2f", threat.favorability) .. ")")
            
            -- Abort any active assault/attack orders
            if self.orders and self.orders:isActive() then
                local context = self.orderContext
                if context and (context.type == taskTypes.ASSAULT or context.type == taskTypes.ATTACK) then
                    env.info(self.groupName .. " DECIDE: Aborting ASSAULT due to unfavorable casualties")
                    self.orders:abort("casualties")
                end
            end
            
            if threat.center then
                -- Use only directly observed threats for stable retreat direction
                local observedThreatCenter = self:calculateThreatCenter(true)
                if observedThreatCenter then
                    self.destination = self:calculateDestinationRelativeToThreats(observedThreatCenter, true)
                else
                    self.destination = self:calculateDestinationRelativeToThreats(threat.center, true)
                end
            else
                self.destination = self:calculateReturnToObjective()
            end
            self:setDisposition(dispositionTypes.RETREAT)
            return true
        end
    end
    
    -- WARNING: Low ammunition - don't advance unless overwhelming advantage
    -- Only applies to units that HAD ammo initially (not unarmed recon vehicles)
    if self.initialAmmoCount > 0 then
        if ForceStatusAnalyzer.isAmmoLow(statusReport.ammoCount, self.initialAmmoCount, 20) and threat.favorability < 2.0 then
            local ammoPercent = ForceStatusAnalyzer.calculateAmmoPercentage(statusReport.ammoCount, self.initialAmmoCount)
            env.info(self.groupName .. " DECIDE: HOLD (low ammo: " .. 
                     string.format("%.0f%%", ammoPercent) .. " remaining, insufficient advantage)")
            self:setDisposition(dispositionTypes.HOLD)
            self.destination = nil
            self:stopMovement()
            return true
        end
    end
    
    return false  -- No critical conditions, proceed with normal decision-making
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
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        return nil
    end
    
    local units = group:getUnits()
    if #units == 0 then
        return nil
    end
    
    -- Use first unit position as group position
    local unit = units[1]
    if unit and unit:isExist() then
        return unit:getPosition().p
    end
    
    return nil
end

function GroupCommander:getOwnUnitNames()
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        return {}
    end
    
    local units = group:getUnits()
    local unitNames = {}
    for _, unit in ipairs(units) do
        if unit and unit:isExist() then
            table.insert(unitNames, unit:getName())
        end
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
        threats = self.threatTracker:getThreats(),
    }
    return status
end

-- Make decisions when following orders
function GroupCommander:handleOrderDecisions()
    -- Start order if just assigned
    if self.orders.status == orderStatus.ASSIGNED then
        self.orders:start()
        local orderTypeName = self.orders.type == taskTypes.RALLY and "RALLY" or
                            self.orders.type == taskTypes.ASSAULT and "ASSAULT" or
                            self.orders.type == taskTypes.RECON and "RECON" or
                            self.orders.type == taskTypes.DEFEND and "DEFEND" or
                            self.orders.type == taskTypes.REPOSITION and "REPOSITION" or
                            self.orders.type == taskTypes.REINFORCE and "REINFORCE" or
                            self.orders.type == taskTypes.ATTACK and "ATTACK" or
                            tostring(self.orders.type)
        env.info(self.groupName .. " DECIDE: Starting order " .. orderTypeName .. 
                 " @ " .. string.format("%.0f,%.0f", self.orders.position.x, self.orders.position.z) .. 
                 " r:" .. self.orders.radius .. " ALR:" .. self.orders.alr)
    end
    
    -- Check for order expiration
    if self.orders:isExpired() then
        self.orders:complete()
        env.info(self.groupName .. " DECIDE: Order complete (deadline)")
        return
    end
    
    local threat = self.threatAssessment
    local context = self.orderContext
    
    -- No order context means we can't make order-based decisions
    if not context then
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = nil
        return
    end
    
    -- Decision thresholds (adjusted by ALR in orderContext)
    local advanceThreshold = 1.5
    
    -- Check if we should abort order due to threat
    if self:shouldAbortForThreat() then
        self.orders:abort("threat_retreat")
        self:setDisposition(dispositionTypes.RETREAT)
        -- Use only directly observed threats for stable retreat direction
        local observedThreatCenter = self:calculateThreatCenter(true)
        if observedThreatCenter then
            self.destination = self:calculateDestinationRelativeToThreats(observedThreatCenter, true)
            self.lastThreatCenter = observedThreatCenter
        else
            self.destination = self:calculateDestinationRelativeToThreats(threat.center, true)
            self.lastThreatCenter = threat.center
        end
        return
    end
    
    -- No threats or threats eliminated
    if threat.count == 0 or not threat.center then
        self:decideWithNoThreats()
        return
    end
    
    -- RECON orders complete when threats are detected (that's the point of recon!)
    if context.type == taskTypes.RECON then
        env.info(self.groupName .. " DECIDE: RECON complete - threats detected")
        self.orders:complete()
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = nil
        return
    end
    
    -- RALLY orders: Check if we've reached the rally point
    if context.type == taskTypes.RALLY then
        -- Check if we're at the rally destination
        local atRallyPoint = (self:getDestinationToObjective(context.position, context.radius) == nil)
        if atRallyPoint then
            env.info(self.groupName .. " DECIDE: Reached rally point, completing RALLY order (Fav:" .. 
                     string.format("%.2f", threat.favorability) .. ")")
            self.orders:complete()
            -- Hold position at rally point and defend while waiting for coordinated assault
            self:setDisposition(dispositionTypes.HOLD)
            self.destination = nil
            self:stopMovement()
            return
        end
    end
    
    -- REPOSITION orders: Move to safe position, complete when arrived
    if context.type == taskTypes.REPOSITION then
        local atPosition = (self:getDestinationToObjective(context.position, context.radius) == nil)
        if atPosition then
            env.info(self.groupName .. " DECIDE: Reached reposition point, completing order")
            self.orders:complete()
            self:setDisposition(dispositionTypes.HOLD)
            self.destination = nil
            self:stopMovement()
            return
        end
        
        -- If threats detected while repositioning, continue to destination (don't engage)
        if threat.count > 0 then
            env.info(self.groupName .. " DECIDE: REPOSITION - continuing to safe position (threats detected)")
            self:setDisposition(dispositionTypes.ADVANCE)
            self.destination = self:getDestinationToObjective(context.position, context.radius)
            return
        end
    end
    
    -- RALLY orders: if threats are closer than rally destination, engage them directly
    -- ASSAULT orders should commit - don't check, just fight
    if context.type == taskTypes.RALLY and threat.center then
        local ownPos = self:getOwnPosition()
        if ownPos then
            local distanceToThreat = SpatialAgent.distance2D(ownPos, threat.center)
            local distanceToDestination = SpatialAgent.distance2D(ownPos, context.position)
            
            -- If threat is significantly closer than rally point, abandon rally and engage
            -- Use 50% threshold to ensure units only engage if threats are genuinely in the way
            -- With 7km rally distance, threats at objective shouldn't trigger this
            if distanceToThreat < distanceToDestination * 0.5 then
                env.info(self.groupName .. " DECIDE: Threat closer than rally point, engaging directly")
                
                -- Abort the rally order and engage autonomously
                self.orders:abort("closer_threat")
                
                -- Strong position, advance on threats
                if threat.favorability >= advanceThreshold then
                    env.info(self.groupName .. " DECIDE: ADVANCE (Fav:" .. string.format("%.2f", threat.favorability) .. ")")
                    self:setDisposition(dispositionTypes.ADVANCE)
                    self.destination = self:calculateDestinationRelativeToThreats(threat.center, false)
                else
                    -- Hold position and engage from here
                    env.info(self.groupName .. " DECIDE: HOLD (moderate, Fav:" .. string.format("%.2f", threat.favorability) .. ")")
                    self:setDisposition(dispositionTypes.HOLD)
                    self.destination = nil
                    self:stopMovement()
                end
                return
            end
        end
    end
    
    -- Threats are stale but maintain course if we have recent intel
    if threat.stale then
        -- If we have recent intel (within 2 minutes), maintain current course
        if threat.hasRecentIntel then
            env.info(self.groupName .. " DECIDE: Maintaining course (threat intel temporarily stale)")
            -- Continue previous action, don't change course for temporary intel gaps
            return  -- Maintain current disposition/destination
        else
            self:decideWithStaleThreats()
            return
        end
    end
    
    -- If retreating with ordered position and no direct LOS, check if contact is broken
    if self.disposition == dispositionTypes.RETREAT then
        if self.directLOSCount == 0 and threat.statuses then
            if threat.statuses.observed == 0 and threat.statuses.suspected == 0 and threat.statuses.unconfirmed > 0 then
                env.info(self.groupName .. " DECIDE: HOLD (threats unconfirmed, contact broken)")
                self:setDisposition(dispositionTypes.HOLD)
                self.destination = nil
                self:stopMovement()
                return
            end
        end
    end
    
    -- Strong position, can advance on threats
    if threat.favorability >= advanceThreshold and 
       context.distanceToOrdered < context.leashDistance then
        self:decideAdvanceOnThreats()
        return
    end
    
    -- Default: move toward or defend ordered position
    self:decideMoveToOrdered()
end

-- Make decisions without orders (autonomous mode)
function GroupCommander:handleAutonomousDecisions()
    local threat = self.threatAssessment
    
    -- Get status to check combat capability
    local statusReport = self:getStatusReport()
    
    -- Unarmed units should not autonomously engage threats
    -- They should hold position or retreat if threatened, but never advance
    if statusReport.ammoCount == 0 then
        -- No ammo - can't engage in combat
        if threat.count > 0 and threat.center then
            -- Threats present - retreat if unfavorable, otherwise hold
            if threat.favorability < 0.8 then
                env.info(self.groupName .. " DECIDE: RETREAT (unarmed, threats present, Fav:" .. 
                         string.format("%.2f", threat.favorability) .. ")")
                self:setDisposition(dispositionTypes.RETREAT)
                -- Use only directly observed threats for stable retreat direction
                local observedThreatCenter = self:calculateThreatCenter(true)
                if observedThreatCenter then
                    self.destination = self:calculateDestinationRelativeToThreats(observedThreatCenter, true)
                    self.lastThreatCenter = observedThreatCenter
                else
                    self.destination = self:calculateDestinationRelativeToThreats(threat.center, true)
                    self.lastThreatCenter = threat.center
                end
            else
                env.info(self.groupName .. " DECIDE: HOLD (unarmed, threats detected)")
                self:setDisposition(dispositionTypes.HOLD)
                self.destination = nil
                self:stopMovement()
            end
        else
            -- No threats - hold position
            env.info(self.groupName .. " DECIDE: HOLD (unarmed, no threats)")
            self:setDisposition(dispositionTypes.HOLD)
            self.destination = nil
            self:stopMovement()
        end
        return
    end
    
    -- Check attrition to prevent heavily damaged units from advancing
    local totalUnits = #self.initialUnitNames
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(statusReport.aliveCount, totalUnits)
    
    -- Decision thresholds (default/medium ALR)
    local retreatThreshold = 0.6
    local advanceThreshold = 1.5
    
    -- Units with heavy casualties should not advance, even if favorability looks good
    if attritionRate > 0.4 then
        advanceThreshold = 999  -- Effectively prevent advancing
    end
    
    -- Add hysteresis based on current disposition to prevent rapid state changes
    -- If already retreating, make it slightly easier to continue retreating
    -- If already advancing, make it slightly easier to continue advancing
    local hysteresis = 0.15
    if self.disposition == dispositionTypes.RETREAT then
        retreatThreshold = retreatThreshold + hysteresis
    elseif self.disposition == dispositionTypes.ADVANCE then
        advanceThreshold = advanceThreshold - hysteresis
    end
    
    -- No threats, hold position
    if threat.count == 0 or not threat.center then
        env.info(self.groupName .. " DECIDE: HOLD (no threats)")
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = nil
        return
    end
    
    -- Threats are stale but maintain course if we have recent intel
    if threat.stale then
        if threat.hasRecentIntel then
            env.info(self.groupName .. " DECIDE: Maintaining course (threat intel temporarily stale)")
            -- Maintain current disposition, don't change course on temporary intel gaps
            return
        else
            env.info(self.groupName .. " DECIDE: HOLD (stale threats)")
            self:setDisposition(dispositionTypes.HOLD)
            self.destination = nil
            self:stopMovement()
            return
        end
    end
    
    -- If retreating and have no direct LOS to threats (only shared intel from allies),
    -- transition to HOLD after breaking contact. This prevents endless retreat driven by ally intel.
    if self.disposition == dispositionTypes.RETREAT then
        if self.directLOSCount == 0 and threat.statuses then
            -- No direct LOS, check if we've broken contact for long enough
            if threat.statuses.observed == 0 and threat.statuses.suspected == 0 and threat.statuses.unconfirmed > 0 then
                env.info(self.groupName .. " DECIDE: HOLD (threats unconfirmed, contact broken)")
                self:setDisposition(dispositionTypes.HOLD)
                self.destination = nil
                self:stopMovement()
                return
            end
        end
    end
    
    -- Weak position, retreat
    if threat.favorability < retreatThreshold then
        env.info(self.groupName .. " DECIDE: RETREAT (Fav:" .. string.format("%.2f", threat.favorability) .. ")")
        self:setDisposition(dispositionTypes.RETREAT)
        -- Use only directly observed threats for stable retreat direction
        local observedThreatCenter = self:calculateThreatCenter(true)
        if observedThreatCenter then
            self.destination = self:calculateDestinationRelativeToThreats(observedThreatCenter, true)
            self.lastThreatCenter = observedThreatCenter
        else
            self.destination = self:calculateDestinationRelativeToThreats(threat.center, true)
            self.lastThreatCenter = threat.center
        end
        return
    end
    
    -- Strong position, advance
    if threat.favorability >= advanceThreshold then
        env.info(self.groupName .. " DECIDE: ADVANCE (Fav:" .. string.format("%.2f", threat.favorability) .. ")")
        self:setDisposition(dispositionTypes.ADVANCE)
        self.destination = self:calculateDestinationRelativeToThreats(threat.center, false)
        return
    end
    
    -- Moderate position, hold
    env.info(self.groupName .. " DECIDE: HOLD (moderate, Fav:" .. string.format("%.2f", threat.favorability) .. ")")
    self:setDisposition(dispositionTypes.HOLD)
    self.destination = nil
    self:stopMovement()
end

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
    -- allyIntel: {count, composition, offensiveCapability} from ThreatAnalyzer
    self.allyIntel = allyIntel
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

-- Check if order should be aborted due to threat
function GroupCommander:shouldAbortForThreat()
    local threat = self.threatAssessment
    local context = self.orderContext
    
    if not threat or not context then
        return false
    end
    
    -- No threats, no need to abort
    if threat.count == 0 or not threat.center or threat.stale then
        return false
    end
    
    -- Check if threat exceeds acceptable risk
    local shouldAbort = threat.favorability < context.retreatThreshold
    
    if shouldAbort then
        env.info(self.groupName .. " DECIDE: Aborting order due to threat (favorability=" .. 
                 string.format("%.2f", threat.favorability) .. ")")
    end
    
    return shouldAbort
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