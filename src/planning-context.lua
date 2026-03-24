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
    local availableCount = 0
    for _, cmd in ipairs(commander.groupCommanders) do
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
