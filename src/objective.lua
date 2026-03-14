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
