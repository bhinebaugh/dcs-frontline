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
