local constants = require("constants")
local GroupCommander = require("group-commander")
local Order = require("order")
local ThreatTracker = require("threat-tracker")

local alr = constants.acceptableLevelsOfRisk
local oodaStates = constants.oodaStates
local orderStatus = constants.orderStatus
local taskTypes = constants.taskTypes

local OperationalCommander = {}
OperationalCommander.__index = OperationalCommander

local oodaInterval = 30.0 -- seconds

function OperationalCommander.new(config)
    local self = setmetatable({}, OperationalCommander)

    self.color = config.color or "white"
    self.oodaState = oodaStates.OBSERVE
    self.oodaOffset = math.random() * oodaInterval
    self.threatTracker = ThreatTracker.new(self.color .. "OperationalCommander")
    self.objectives = {}
    self.lastIssuedOrders = {}
    self.plannedOrders = {}
    self.objectivesNeedingOrders = {}
    self.phase = "RECON"

    self.reconRadius = config.reconRadius or 8000
    self.assaultRadius = config.assaultRadius or 3000
    self.assaultStagingDistance = config.assaultStagingDistance or 4000
    self.maxReconGroups = config.maxReconGroups or 1

    mist.scheduleFunction(
        OperationalCommander.oodaTick,
        {self},
        timer.getTime() + self.oodaOffset,
        oodaInterval
    )
    return self
end

function OperationalCommander:oodaTick()
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

function OperationalCommander:observe()
    env.info(self.color .. "OperationalCommander: OBSERVE")
    self:aggregateThreatsFromGroups()
end

function OperationalCommander:orient()
    env.info(self.color .. "OperationalCommander: ORIENT")
    self:syncOrderStatuses()
    self.objectivesNeedingOrders = {}
    for _, objective in ipairs(self.objectives) do
        self:assessObjectiveProgress(objective)
    end
end

function OperationalCommander:decide()
    env.info(self.color .. "OperationalCommander: DECIDE")
    self.plannedOrders = {}
    
    -- Process each active objective
    for _, objective in ipairs(self.objectives) do
        if objective.status == "Active" then
            self:planObjectiveOrders(objective)
        end
    end
end

function OperationalCommander:planObjectiveOrders(objective)
    local statusCounts = objective:getOrderStatusCounts()
    local threats = self:getThreatsNearPosition(objective.position, self.reconRadius)
    local threatCount = self:countThreats(threats)
    
    -- If no orders exist, start with RECON
    if statusCounts.total == 0 then
        env.info(self.color .. "OperationalCommander: Objective needs RECON orders")
        self:planReconOrders(objective)
        return
    end
    
    -- If all orders completed, determine next phase
    if statusCounts.completed == statusCounts.total then
        -- Get the type of the last completed orders
        local lastOrderType = nil
        if #objective.orders > 0 then
            lastOrderType = objective.orders[#objective.orders].type
        end
        
        if lastOrderType == taskTypes.RECON then
            if threatCount == 0 then
                -- No threats found, objective is clear
                objective:markAchieved()
                env.info(self.color .. "OperationalCommander: RECON complete, no threats - objective achieved")
            else
                -- Threats found, proceed to RALLY
                env.info(self.color .. "OperationalCommander: RECON complete, threats found - issuing RALLY orders")
                self:planRallyOrders(objective)
            end
        elseif lastOrderType == taskTypes.RALLY then
            -- RALLY complete, proceed to ASSAULT
            env.info(self.color .. "OperationalCommander: RALLY complete - issuing ASSAULT orders")
            self:planAssaultOrders(objective, threats)
        elseif lastOrderType == taskTypes.ASSAULT then
            if threatCount == 0 then
                -- Assault complete and no threats remain
                objective:markAchieved()
                env.info(self.color .. "OperationalCommander: ASSAULT complete, no threats - objective achieved")
            else
                -- More threats remain, continue assault
                env.info(self.color .. "OperationalCommander: ASSAULT complete but threats remain - issuing more ASSAULT orders")
                self:planAssaultOrders(objective, threats)
            end
        end
    end
end

function OperationalCommander:planReconOrders(objective)
    local availableCommanders = self:getAvailableGroupCommanders()
    local candidates = self:getCommandersByDistance(availableCommanders, objective.position)
    local count = math.min(self.maxReconGroups, #candidates)
    
    for i = 1, count do
        local commander = candidates[i].commander
        local order = Order.new({
            assignedTo = commander.groupName,
            objective = objective,
            position = objective.position,
            radius = objective.radius,
            type = taskTypes.RECON,
            alr = alr.LOW,
            deadline = timer.getTime() + 900,
        })
        
        table.insert(self.plannedOrders, {
            commander = commander,
            order = order,
        })
    end
end

function OperationalCommander:planRallyOrders(objective)
    local availableCommanders = self:getAvailableGroupCommanders()
    
    if #availableCommanders == 0 then
        return
    end
    
    -- Calculate assault staging positions around the objective
    local stagingPositions = self:calculateAssaultStagingPositions(
        objective.position,
        #availableCommanders
    )
    
    for i, commander in ipairs(availableCommanders) do
        local stagingPos = stagingPositions[i]
        local order = Order.new({
            assignedTo = commander.groupName,
            objective = objective,
            position = stagingPos,
            radius = 300,
            type = taskTypes.RALLY,
            alr = alr.MEDIUM,
            deadline = timer.getTime() + 600,
        })
        
        table.insert(self.plannedOrders, {
            commander = commander,
            order = order,
        })
    end
end

function OperationalCommander:calculateAssaultStagingPositions(objectivePosition, numPositions)
    local positions = {}
    local distance = self.assaultStagingDistance
    local angleStep = (2 * math.pi) / numPositions
    
    for i = 1, numPositions do
        local angle = angleStep * (i - 1)
        local offsetX = math.cos(angle) * distance
        local offsetZ = math.sin(angle) * distance
        
        table.insert(positions, {
            x = objectivePosition.x + offsetX,
            y = objectivePosition.y or 0,
            z = objectivePosition.z + offsetZ
        })
    end
    
    return positions
end

function OperationalCommander:planAssaultOrders(objective, threats)
    local availableCommanders = self:getAvailableGroupCommanders()
    
    for _, commander in pairs(availableCommanders) do
        local order = Order.new({
            assignedTo = commander.groupName,
            objective = objective,
            position = objective.position,
            radius = objective.radius,
            type = taskTypes.ASSAULT,
            alr = alr.HIGH,
            deadline = objective.deadline or (timer.getTime() + 1800),
        })
        
        table.insert(self.plannedOrders, {
            commander = commander,
            order = order,
            threats = threats,
        })
    end
end

function OperationalCommander:getAvailableGroupCommanders()
    local available = {}
    for _, commander in pairs(self:getOwnGroupCommanders()) do
        local status = commander:getStatus()
        local currentStatus = status.orderStatus
        -- Include groups without orders, or with completed/aborted orders
        -- ABORTED groups can be reassigned after tactical retreat
        if not currentStatus or
           currentStatus == orderStatus.STANDBY or
           currentStatus == orderStatus.COMPLETED or
           currentStatus == orderStatus.ABORTED then
            table.insert(available, commander)
        end
    end
    return available
end

function OperationalCommander:countThreats(threats)
    local count = 0
    for _ in pairs(threats) do
        count = count + 1
    end
    return count
end

function OperationalCommander:taskTypeName(taskType)
    for name, value in pairs(taskTypes) do
        if value == taskType then
            return name
        end
    end
    return tostring(taskType)
end

function OperationalCommander:act()
    env.info(self.color .. "OperationalCommander: ACT")
    if not self.plannedOrders or #self.plannedOrders == 0 then
        return
    end

    for _, plan in ipairs(self.plannedOrders) do
        local commander = plan.commander
        local order = plan.order
        local lastOrder = self.lastIssuedOrders[commander.groupName]

        if self:isOrderChanged(lastOrder, order) then
            env.info(
                self.color .. "OperationalCommander: issuing " ..
                self:taskTypeName(order.type) .. " to " .. commander.groupName
            )

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
            }
        end
    end
end

function OperationalCommander:assessObjectiveProgress(objective)
    if not objective or objective.status ~= "Active" then
        return
    end

    local statusCounts = objective:getOrderStatusCounts()
    local activeCount = statusCounts.assigned + statusCounts.inProgress + statusCounts.standby

    -- Check if orders were aborted (tactical retreat)
    if statusCounts.aborted > 0 then
        -- Check if ALL orders are aborted with none in progress
        if statusCounts.aborted == statusCounts.total then
            -- All orders aborted - reassess objective
            -- Groups with aborted orders will be available for reassignment
            env.info(self.color .. "OperationalCommander: All orders aborted, will reassess objective")
            table.insert(self.objectivesNeedingOrders, objective)
        else
            -- Some orders aborted, some still active - wait to see how active orders resolve
            env.info(self.color .. "OperationalCommander: Some orders aborted (" .. 
                     statusCounts.aborted .. "/" .. statusCounts.total .. "), monitoring situation")
        end
        return
    end

    -- All orders completed successfully
    if statusCounts.total > 0 and statusCounts.completed == statusCounts.total then
        table.insert(self.objectivesNeedingOrders, objective)
    end
end

function OperationalCommander:getCommandersByDistance(commanders, position)
    local list = {}
    for _, commander in pairs(commanders) do
        local status = commander:getStatus()
        if status.position then
            local dist = mist.vec.mag(mist.vec.sub(status.position, position))
            table.insert(list, {commander = commander, distance = dist})
        end
    end

    table.sort(list, function(a, b)
        return a.distance < b.distance
    end)

    return list
end

function OperationalCommander:isOrderChanged(lastOrder, newOrder)
    if not lastOrder then
        return true
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

function OperationalCommander:aggregateThreatsFromGroups()
    local groupCommanders = self:getOwnGroupCommanders()
    for _, commander in pairs(groupCommanders) do
        local status = commander:getStatus()
        self.threatTracker:mergeThreatIntel(status.threats)
    end
end

function OperationalCommander:findNearestRallyPoint(position)
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

function OperationalCommander:getOwnGroupCommanders()
    return GroupCommander.getInstances(self.color)
end

function OperationalCommander:getOwnGroupsNearPosition(position, radius)
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

function OperationalCommander:getThreatsNearPosition(position, radius)
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

function OperationalCommander:syncOrderStatuses()
    local groupCommanders = self:getOwnGroupCommanders()

    for _, commander in pairs(groupCommanders) do
        local status = commander:getStatus()
        for _, objective in ipairs(self.objectives) do
            for _, order in ipairs(objective.orders) do
                if order.assignedTo == commander.groupName then
                    if status.orderStatus and status.orderStatus ~= order.status then
                        env.info(self.color .. "OperationalCommander: Order for " ..
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

return OperationalCommander
