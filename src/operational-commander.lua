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

-- self.name doubles as this opscom's map-mark/visualizer key
-- (CommanderVisualizer:syncOpscom) and its doctrine's log-line commander
-- name, so it must be unique per instance - "<color>Ops" alone collided the
-- moment more than one opscom of the same color could be active at once
-- (e.g. an assault opscom and a fire-support opscom under the same
-- Operation), silently stomping each other's map marks.
local nextInstanceId = 1

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
    if lastOrder.proximity ~= newOrder.proximity then
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
    local roleSuffix = config.role and ("-" .. config.role) or ""
    self.name = config.color .. "Ops" .. roleSuffix .. "-" .. nextInstanceId
    nextInstanceId = nextInstanceId + 1
    self.threatTracker = ThreatTracker.new(self.color .. "OperationalCommander")
    self.orderCoordinator = OrderCoordinator.new(self.color)
    self.lastIssuedOrders = {}
    self.plannedOrders = {}
    self.objectivesNeedingOrders = {}
    self.groupCommanders = config.groupCommanders or {}
    self.visualizer = config.visualizer --shares visualizer with coalition commander

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

    -- Pre-built doctrine instance, e.g. from StrategicCommander for a
    -- non-assault role - nil defaults to ReconRallyAssaultPlan below in
    -- decide(), unchanged from before.
    self.doctrine = config.doctrine
    -- clear out any residual orders to ensure all groups are available for new tasking
    for _, gc in ipairs(self.groupCommanders) do
        gc:clearOrders()
    end

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
                proximity = order.proximity,
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
        if not gc.destroyed then
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
-- groupReplacements (optional): {[groupName] = newGroupCommander or false} -
-- for a doctrine coordinating specific named groups rather than an
-- interchangeable pool (see repair-resupply-plan.lua), a way to swap a
-- managed group out for a freshly-spawned replacement, or drop one from the
-- roster entirely (false/nil value) once it's no longer needed - e.g. a
-- resupply convoy retiring after restocking, before the objective completes
-- and disband() hands back whatever's still in groupCommanders.
function OperationalCommander:planObjectiveWithDoctrine(objective)
    local context = self:buildObjectiveContext(objective)
    local result = self.doctrine:plan(context)
    if not result then return end

    if result.groupReplacements then
        self:applyGroupReplacements(result.groupReplacements)
    end

    if result.objectiveFailed then
        env.info("*** " .. self.color .. " Ops: OBJECTIVE FAILED (" .. tostring(result.objectiveFailed) .. ") --------------------")
        objective:markFailed(result.objectiveFailed)
    elseif result.objectiveComplete then
        env.info("*** " .. self.color .. " Ops: OBJECTIVE COMPLETE --------------------")
        objective:markAchieved()
    end

    for _, template in ipairs(result.orders or {}) do
        self:assignOrderTemplate(template, objective)
    end
end

function OperationalCommander:applyGroupReplacements(replacements)
    for oldName, replacement in pairs(replacements) do
        for i, gc in ipairs(self.groupCommanders) do
            if gc.groupName == oldName then
                table.remove(self.groupCommanders, i)
                break
            end
        end
        if replacement then
            table.insert(self.groupCommanders, replacement)
        end
    end
end

-- Evaluate available commanders against a template's missionProfile and issue orders.
-- template.assignTo (optional): a groupName string - targets that specific
-- commander directly instead of running suitability selection across the
-- whole pool. For a doctrine coordinating specific named groups (see
-- repair-resupply-plan.lua) rather than "any N suitable groups."
function OperationalCommander:assignOrderTemplate(template, objective)
    if template.assignTo then
        for _, commander in ipairs(self.groupCommanders) do
            if commander.groupName == template.assignTo and not self.plannedThisCycle[commander.groupName] then
                local order = Order.new({
                    type           = template.type,
                    position       = template.position,
                    proximity      = template.proximity,
                    alr            = template.alr,
                    missionProfile = template.missionProfile,
                    objective      = objective,
                    deadline       = template.deadline,
                    assignedTo     = commander.groupName,
                })
                table.insert(self.plannedOrders, { commander = commander, order = order })
                self.plannedThisCycle[commander.groupName] = true
                break
            end
        end
        return
    end

    local count          = template.count or 1
    local missionProfile = template.missionProfile

    -- Score available commanders by suitability against the template's missionProfile
    local suitabilityResults = {}
    for _, commander in ipairs(self.groupCommanders) do
        local s = commander:getStatus()
        if not s.orderStatus or
           s.orderStatus == orderStatus.COMPLETED or
           s.orderStatus == orderStatus.ABORTED then
            -- A hard floor, not just a low suitability score: a group in
            -- dire condition (critical ammo/health/fuel) is excluded from
            -- new tasking entirely, regardless of how well it'd otherwise
            -- match missionProfile - suitability alone only deprioritizes
            -- via sort order, which still picks a dire group when it's the
            -- best (or only) candidate available.
            if commander:isConditionCritical() then
                env.info(string.format("*** %s Ops: excluding %s from order assignment (dire condition)",
                    self.color, commander.groupName))
            else
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
