local constants = require("constants")
local GroupCommander = require("group-commander")
local Order = require("order")
local ThreatTracker = require("threat-tracker")

local alr = constants.acceptableLevelsOfRisk
local dispositionTypes = constants.dispositionTypes
local oodaStates = constants.oodaStates
local orderStatus = constants.orderStatus
local roe = constants.rulesOfEngagement
local taskTypes = constants.taskTypes

local StrategicCommander = {}
StrategicCommander.__index = StrategicCommander

local oodaInterval = 30.0 -- seconds

function StrategicCommander.new(config)
    local self = setmetatable({}, StrategicCommander)

    self.color = config.color or "white"
    self.oodaState = oodaStates.OBSERVE
    self.oodaOffset = math.random() * oodaInterval
    self.threatTracker = ThreatTracker.new(self.color .. "StrategicCommander")
    self.objectives = {}
    self.lastIssuedOrders = {}
    
    mist.scheduleFunction(
        StrategicCommander.oodaTick,
        {self},
        timer.getTime() + self.oodaOffset,
        oodaInterval
    )
    return self
end

function StrategicCommander:oodaTick()
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
end

function StrategicCommander:observe()
    env.info(self.color .. "StrategicCommander: OBSERVE")
    -- Known own force positions, status, and times
    -- Known enemy force positions, status, and times
    self:aggregateThreatsFromGroups()
    -- Control zone statuses
    -- Existing objectives and their statuses
    -- Historical objectives and outcomes
end

function StrategicCommander:orient()
    env.info(self.color .. "StrategicCommander: ORIENT")
    
    -- Sync order statuses from GroupCommanders
    self:syncOrderStatuses()
    
    -- Analyze enemy objectives and likely courses of action
    -- Assess current objectives for liklihood of success 
    -- Set one primary objective if none exists
    self.prioirtyObjective = self:assessObjectives()

    -- Assess new opportunities for objectives
    -- Identify stale information and intelligence gaps
end

function StrategicCommander:decide()
    env.info(self.color .. "StrategicCommander: DECIDE")
    -- Stale information in need of updated status
    -- Prioritize actions for each own force group
    local ownGroupCommanders = self:getOwnGroupCommanders()

    -- Retreating forces to safe locations
    self.retreatingGroups = self:extractRetreatingGroups(ownGroupCommanders)

    -- Units with STANDBY orders need reevaluation
    -- These could be units that stopped retreating due to stale threats, or any other reason
    self.standbyGroups = self:extractStandbyGroups(ownGroupCommanders)
    
    -- Reserves to reinforce threatened forces
    self.reinforcementGroups = self:extractReinforcingGroups(ownGroupCommanders)

    -- Low supply groups to resupply points
    -- Reconnaissance to gather needed intelligence
    -- Reposition for coordinated action on objectives
    self.rallyingGroups = self:extractRallyingGroups(ownGroupCommanders)

    -- Offensive actions on objectives
    -- Logistics to resupply points needing replenishment
end

function StrategicCommander:act()
    env.info(self.color .. "StrategicCommander: ACT")
    -- Request communications updates from own forces
    -- Issue orders to own force groups based on decisions made
    for _, retreatPair in pairs(self.reinforcementGroups) do
        local reinforcingCommander = retreatPair.reinforcingCommander
        local retreatingCommander = retreatPair.retreatingCommander
        local retreatPosition = retreatPair.retreatPosition

        -- Find nearest rally point to the retreating unit
        local rallyPoint = self:findNearestRallyPoint(retreatPosition)
        
        if not rallyPoint then
            env.info(self.color .. "StrategicCommander: No rally points configured, skipping reinforcement order")
        else
            local rallyPosition = rallyPoint.position
            
            -- Issue RALLY order to retreating unit
            local retreatingLastOrder = self.lastIssuedOrders[retreatingCommander.groupName]
            local retreatingOrderChanged = not retreatingLastOrder or
                retreatingLastOrder.type ~= taskTypes.RALLY or
                math.abs(retreatingLastOrder.position.x - rallyPosition.x) > 100 or
                math.abs(retreatingLastOrder.position.z - rallyPosition.z) > 100

            if retreatingOrderChanged then
                env.info(
                    self.color .. "StrategicCommander: ordering " ..
                    retreatingCommander.groupName .. " to rally at safe position x=" ..
                    rallyPosition.x .. " z=" .. rallyPosition.z
                )
                
                local retreatingOrder = Order.new({
                    assignedTo = retreatingCommander.groupName,
                    objective = nil,
                    position = rallyPosition,
                    radius = rallyPoint.radius,
                    type = taskTypes.RALLY,
                    alr = alr.LOW,  -- Low risk at rally point
                    deadline = timer.getTime() + 600,  -- 10 minute deadline
                })
                
                retreatingCommander:issueOrder(retreatingOrder)
                
                self.lastIssuedOrders[retreatingCommander.groupName] = {
                    alr = alr.LOW,
                    position = {x = rallyPosition.x, z = rallyPosition.z},
                    type = taskTypes.RALLY,
                }
            end
            
            -- Issue RALLY order to reinforcing unit
            local reinforcingLastOrder = self.lastIssuedOrders[reinforcingCommander.groupName]
            local reinforcingOrderChanged = not reinforcingLastOrder or
                reinforcingLastOrder.type ~= taskTypes.RALLY or
                math.abs(reinforcingLastOrder.position.x - rallyPosition.x) > 100 or
                math.abs(reinforcingLastOrder.position.z - rallyPosition.z) > 100

            if reinforcingOrderChanged then
                env.info(
                    self.color .. "StrategicCommander: ordering " ..
                    reinforcingCommander.groupName .. " to rally with " ..
                    retreatingCommander.groupName .. " at position x=" ..
                    rallyPosition.x .. " z=" .. rallyPosition.z
                )
                
                local reinforcingOrder = Order.new({
                    assignedTo = reinforcingCommander.groupName,
                    objective = nil,
                    position = rallyPosition,
                    radius = rallyPoint.radius,
                    type = taskTypes.RALLY,
                    alr = alr.MEDIUM,  -- Medium risk en route to rally
                    deadline = timer.getTime() + 600,  -- 10 minute deadline
                })
                
                reinforcingCommander:issueOrder(reinforcingOrder)
                
                self.lastIssuedOrders[reinforcingCommander.groupName] = {
                    alr = alr.MEDIUM,
                    position = {x = rallyPosition.x, z = rallyPosition.z},
                    type = taskTypes.RALLY,
                }
            end
        end
    end

    for _, commander in pairs(self.rallyingGroups) do
        -- Assign each remaining commander to act on primary objective
        if self.prioirtyObjective then
            -- Check if this order has already been issued (more than 100m tolerance)
            local lastOrder = self.lastIssuedOrders[commander.groupName]
            local orderChanged = not lastOrder or
                lastOrder.type ~= self.prioirtyObjective.type or
                math.abs(lastOrder.position.x - self.prioirtyObjective.position.x) > 100 or
                math.abs(lastOrder.position.z - self.prioirtyObjective.position.z) > 100 or
                lastOrder.radius ~= self.prioirtyObjective.radius

            if orderChanged then
                env.info(
                    self.color .. "StrategicCommander: ordering " ..
                    commander.groupName .. " to act on objective " ..
                    self.prioirtyObjective.type
                )
                
                -- Push relevant threat intel before issuing order
                local relevantThreats = self:getThreatsNearPosition(
                    self.prioirtyObjective.position, 
                    3000  -- 3km radius
                )
                if relevantThreats then
                    commander:updateThreatIntel(relevantThreats)
                end
                
                -- Create Order instance and add to objective
                local order = Order.new({
                    assignedTo = commander.groupName,
                    objective = self.prioirtyObjective,
                    position = self.prioirtyObjective.position,
                    radius = self.prioirtyObjective.radius,
                    type = self.prioirtyObjective.type,
                    alr = alr.MEDIUM,
                    deadline = self.prioirtyObjective.deadline,
                })
                
                self.prioirtyObjective:addOrder(order)
                commander:issueOrder(order)
                
                self.lastIssuedOrders[commander.groupName] = {
                    alr = alr.MEDIUM,
                    position = {x = self.prioirtyObjective.position.x, z = self.prioirtyObjective.position.z},
                    radius = self.prioirtyObjective.radius,
                    type = self.prioirtyObjective.type,
                }
            end
        end
    end
end

function StrategicCommander:assessObjective(objective)
    local nearbyThreats = self:getThreatsNearPosition(
        objective.position,
        10000
    )
    local nearbyOwnForces = self:getOwnGroupsNearPosition(
        objective.position,
        10000
    )
    local liklihoodOfSuccess = #nearbyOwnForces / (#nearbyThreats + 1)
    return liklihoodOfSuccess
end

function StrategicCommander:assessObjectives()
    local highestProbabilityObjective = nil
    local highestProbability = -math.huge
    for _, objective in pairs(self.objectives) do
        -- Evaluate each objective's likelihood of success
        -- Update objective status accordingly
        local probability = self:assessObjective(objective)
        if probability > highestProbability then
            highestProbability = probability
            highestProbabilityObjective = objective
        end
    end
    env.info(
        self.color .. "StrategicCommander: Highest probability objective is " ..
        (highestProbabilityObjective and highestProbabilityObjective.type or "none") ..
        " with probability " .. highestProbability
    )
    return highestProbabilityObjective
end

function StrategicCommander:aggregateThreatsFromGroups()
    -- Aggregate threats from all group commanders using mergeThreatIntel
    local groupCommanders = self:getOwnGroupCommanders()
    
    for _, commander in pairs(groupCommanders) do
        local status = commander:getStatus()
        -- Merge each group's threats into strategic view
        self.threatTracker:mergeThreatIntel(status.threats)
    end
end

function StrategicCommander:extractReinforcingGroups(ownGroupCommanders)
    local reinforcingGroups = {}
    for _, commander in pairs(ownGroupCommanders) do
        local status = commander:getStatus()
        if status.disposition == dispositionTypes.REINFORCE then
            table.insert(reinforcingGroups, commander)
            table.remove(ownGroupCommanders, _)
        end
    end
    env.info(
        self.color .. "StrategicCommander: Identified " ..
        #reinforcingGroups .. " reinforcing groups."
    )
    return reinforcingGroups
end

function StrategicCommander:extractRallyingGroups(ownGroupCommanders)
    local rallyingGroups = {}
    for _, commander in pairs(ownGroupCommanders) do
        local status = commander:getStatus()
        if status.disposition == dispositionTypes.HOLD then
            table.insert(rallyingGroups, commander)
            table.remove(ownGroupCommanders, _)
        end
    end
    env.info(
        self.color .. "StrategicCommander: Identified " ..
        #rallyingGroups .. " rallying groups."
    )
    return rallyingGroups
end

function StrategicCommander:extractRetreatingGroups(ownGroupCommanders)
    local retreatingGroups = {}
    for _, commander in pairs(ownGroupCommanders) do
        local status = commander:getStatus()
        if status.disposition == dispositionTypes.RETREAT then
            table.insert(retreatingGroups, commander)
            table.remove(ownGroupCommanders, _)
        end
    end
    env.info(
        self.color .. "StrategicCommander: Identified " ..
        #retreatingGroups .. " retreating groups."
    )
    return retreatingGroups
end

function StrategicCommander:extractStandbyGroups(ownGroupCommanders)
    local standbyGroups = {}
    for _, commander in pairs(ownGroupCommanders) do
        local status = commander:getStatus()
        if status.orderStatus == orderStatus.STANDBY then
            table.insert(standbyGroups, commander)
            table.remove(ownGroupCommanders, _)
        end
    end
    env.info(
        self.color .. "StrategicCommander: Identified " ..
        #standbyGroups .. " standby groups."
    )
    return standbyGroups
end

function StrategicCommander:findNearestRallyPoint(position)
    -- Find the nearest rally point to the given position
    if not self.rallyPoints or #self.rallyPoints == 0 then
        return nil
    end
    local nearestRallyPoint = nil
    local nearestDistance = math.huge
    for _, rallyPoint in ipairs(self.rallyPoints) do
        local dist = mist.vec.mag(mist.vec.sub(rallyPoint.position, position))
        if dist < nearestDistance then
            nearestDistance = dist
            nearestRallyPoint = rallyPoint
        end
    end
    return nearestRallyPoint
end

function StrategicCommander:getOwnGroupCommanders()
    return GroupCommander.getInstances(self.color)
end

function StrategicCommander:getOwnGroupsNearPosition(position, radius)
    local groupCommanders = self:getOwnGroupCommanders()
    local nearbyOwnForces = {}
    for _, commander in pairs(groupCommanders) do
        local status = commander:getStatus()
        local dist = mist.vec.mag(
            mist.vec.sub(status.position, position)
        )
        if dist <= radius then
            table.insert(nearbyOwnForces, commander)
        end
    end
    return nearbyOwnForces
end

function StrategicCommander:getThreatsNearPosition(position, radius)
    local nearbyThreats = {}
    local allThreats = self.threatTracker:getThreats()
    
    for unitName, threat in pairs(allThreats) do
        local dist = mist.vec.mag(mist.vec.sub(threat.position, position))
        if dist <= radius then
            nearbyThreats[unitName] = threat
        end
    end
    
    return nearbyThreats
end

function StrategicCommander:syncOrderStatuses()
    -- Query GroupCommanders for their order status and update Order objects
    local groupCommanders = self:getOwnGroupCommanders()
    
    for _, commander in pairs(groupCommanders) do
        local status = commander:getStatus()
        
        -- Find this group's order in our objectives
        for _, objective in ipairs(self.objectives) do
            for _, order in ipairs(objective.orders) do
                if order.assignedTo == commander.groupName then
                    -- Update order status from group commander's report
                    if status.orderStatus and status.orderStatus ~= order.status then
                        env.info(self.color .. "StrategicCommander: Order for " .. 
                                commander.groupName .. " status changed: " .. 
                                order.status .. " -> " .. status.orderStatus)
                        order.status = status.orderStatus
                        objective.updatedAt = timer.getTime()
                    end
                end
            end
        end
    end
end

return StrategicCommander
