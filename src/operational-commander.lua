local constants = require("constants")
local ForceStatusAnalyzer = require("force-status-analyzer")
local GamePlan = require("game-plan")
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
    self.planningContexts = {}   -- PlanningContext for GamePlan (built in ORIENT)
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
    
    -- Build PlanningContext for each objective (using OrderCoordinator)
    self.planningContexts = {}
    for _, objective in ipairs(self.orderCoordinator.objectives) do
        if objective.status == "Active" then
            local planningContext = self.orderCoordinator:derivePlanningContext(objective, self)
            self.planningContexts[objective] = planningContext
        end
    end
    
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
    local planningContextCount = 0
    for _, objective in ipairs(self.orderCoordinator.objectives) do
        if objective.status == "Active" then
            local counts = objective:getOrderStatusCounts()
            totalOrders = totalOrders + counts.total
            activeOrders = activeOrders + counts.assigned + counts.inProgress
            completedOrders = completedOrders + counts.completed
            abortedOrders = abortedOrders + counts.aborted
        end
        if self.planningContexts[objective] then
            planningContextCount = planningContextCount + 1
        end
    end
    if totalOrders > 0 then
        env.info("*** " .. self.color .. " Ops ORIENT: Orders " .. activeOrders .. "/" .. totalOrders .. " active (" .. completedOrders .. " done, " .. abortedOrders .. " aborted), " .. planningContextCount .. " contexts")
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
    
    -- Process each active objective - GamePlan has full control
    -- GamePlans can recruit any commanders they need, including idle units
    for _, objective in ipairs(self.orderCoordinator.objectives) do
        if objective.status == "Active" then
            -- Assign default GamePlan if none exists
            if not objective.gamePlan then
                local ReconRallyAssaultPlan = require("recon-rally-assault-plan")
                objective.gamePlan = ReconRallyAssaultPlan.new()
                env.info("*** " .. self.color .. " Ops: Assigned default ReconRallyAssaultPlan to objective")
            end
            
            self:planObjectiveWithGamePlan(objective)
        end
    end
    
    -- Units not recruited by any GamePlan will use autonomous GroupCommander behavior
    -- (In the future, GroupCommander will also use GamePlans for tactical decisions)
    
    -- Log consolidated DECIDE summary
    if #self.plannedOrders > 0 then
        env.info("*** " .. self.color .. " Ops DECIDE: Planning " .. #self.plannedOrders .. " orders")
    else
        env.info("*** " .. self.color .. " Ops DECIDE: No new orders planned")
    end
end

-- Plan objective orders using GamePlan strategy
function OperationalCommander:planObjectiveWithGamePlan(objective)
    local planningContext = self.planningContexts[objective]
    
    if not planningContext then
        env.info("ERROR: No planning context for objective " .. (objective.name or "unknown"))
        return
    end
    
    -- Call GamePlan to get order decisions
    local orderPlans = objective.gamePlan:plan(planningContext)
    
    if not orderPlans then
        -- GamePlan returned no orders (valid outcome)
        return
    end
    
    -- Add order plans to plannedOrders for ACT phase
    for _, plan in ipairs(orderPlans) do
        table.insert(self.plannedOrders, plan)
        
        -- Track that this commander has orders planned this cycle
        if plan.commander then
            self.plannedThisCycle[plan.commander.groupName] = true
        end
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

-- ============================================================================
-- HELPER METHODS
-- ============================================================================

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
-- ORDER PLANNING UTILITIES (Used by GamePlans)
-- ============================================================================
-- These methods are utility functions that GamePlans can call via the commander
-- reference in PlanningContext. They handle common planning tasks like scoring
-- units, calculating positions, and selecting commanders for different mission types.

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
