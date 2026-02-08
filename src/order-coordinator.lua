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
