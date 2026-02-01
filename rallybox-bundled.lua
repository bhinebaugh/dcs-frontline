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
opsBlue.objectives = {
    Objective.new({
        type = taskTypes.ASSAULT,
        position = redAttackPosition,
        radius = 500,
    })
}

opsRed.objectives = {
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
    self:aggregateThreatsFromGroups()
    
    -- Log consolidated OBSERVE summary
    local groupCommanders = self:getOwnGroupCommanders()
    local activeGroups = 0
    for _ in pairs(groupCommanders) do
        activeGroups = activeGroups + 1
    end
    local totalThreats = self.threatTracker:count()
    env.info("*** " .. self.color .. " Ops OBSERVE: " .. activeGroups .. " groups, " .. totalThreats .. " threats tracked")
end

function OperationalCommander:orient()
    self:syncOrderStatuses()
    self.objectivesNeedingOrders = {}
    for _, objective in ipairs(self.objectives) do
        self:assessObjectiveProgress(objective)
    end
    
    -- Log consolidated ORIENT summary
    local totalOrders = 0
    local activeOrders = 0
    local completedOrders = 0
    local abortedOrders = 0
    for _, objective in ipairs(self.objectives) do
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

function OperationalCommander:reviewAndCancelObsoleteOrders()
    -- Review active orders and cancel them if they're no longer relevant
    -- This allows the ops commander to adapt to changing threats
    
    for _, objective in ipairs(self.objectives) do
        if objective.status == "Active" then
            local currentThreats = self:getThreatsNearPosition(objective.position, self.reconRadius)
            local threatCount = self:countThreats(currentThreats)
            
            -- Review each active order for this objective
            for _, order in ipairs(objective.orders) do
                if order.status == orderStatus.IN_PROGRESS or order.status == orderStatus.ASSIGNED then
                    local shouldCancel = false
                    local cancelReason = ""
                    
                    -- RALLY orders: Cancel if threats no longer exist or position is now behind new threats
                    if order.type == taskTypes.RALLY then
                        local activeThreats = self:countActiveThreats(currentThreats)
                        if activeThreats == 0 then
                            shouldCancel = true
                            cancelReason = "rally threats no longer active"
                        else
                            -- Check if the rally position is now strategically irrelevant
                            -- (e.g., new threats appeared closer to the unit than the rally point)
                            local commander = self:getCommanderByName(order.assignedTo)
                            if commander then
                                local commanderStatus = commander:getStatus()
                                if commanderStatus.position then
                                    -- Find closest current threat to the unit
                                    local closestThreatDist = math.huge
                                    for unitName, threat in pairs(currentThreats) do
                                        if threat.position then
                                            local dist = mist.vec.mag(mist.vec.sub(commanderStatus.position, threat.position))
                                            if dist < closestThreatDist then
                                                closestThreatDist = dist
                                            end
                                        end
                                    end
                                    
                                    -- Distance to rally point
                                    local distToRally = mist.vec.mag(mist.vec.sub(commanderStatus.position, order.position))
                                    
                                    -- Only cancel if: threats are closer AND unit is still far from rally point
                                    -- If already close to rally (within 1km), let them complete it
                                    if closestThreatDist < distToRally * 0.5 and distToRally > 1000 then
                                        shouldCancel = true
                                        cancelReason = "threats closer than rally point"
                                    end
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
                        env.info("*** " .. self.color .. " Ops: Canceling " .. self:taskTypeName(order.type) .. 
                                 " order for " .. order.assignedTo .. " (" .. cancelReason .. ")")
                        
                        local commander = self:getCommanderByName(order.assignedTo)
                        if commander then
                            local commanderOrders = commander.orders
                            if commanderOrders and commanderOrders == order then
                                commanderOrders:abort("ops_cancel")
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
    for _, objective in ipairs(self.objectives) do
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

        if self:isOrderChanged(lastOrder, order, commanderStatus) then
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
            issuedCount = issuedCount + 1
            
            -- Log each order issued
            env.info("*** " .. self.color .. " Ops ACT: " .. self:taskTypeName(order.type) .. " → " .. commander.groupName)
        end
    end
    
    -- Log consolidated ACT summary
    env.info("*** " .. self.color .. " Ops ACT: Issued " .. issuedCount .. " orders total")
end


function OperationalCommander:planObjectiveOrders(objective)
    local statusCounts = objective:getOrderStatusCounts()
    local threatsNearObjective = self:getThreatsNearPosition(objective.position, self.reconRadius)
    local threatCount = self:countThreats(threatsNearObjective)
    
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
                local reconDistance = self:getDistanceToObjective(objective)
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
            -- Only proceed to ASSAULT if rallies were completed, not just aborted
            -- If rallies were aborted (e.g., units engaged threats directly), they're autonomous
            if lastCompletedCount > 0 then
                -- Some rallies completed, proceed to ASSAULT
                self:planAssaultOrders(objective, threatsNearObjective)
            else
                -- All rallies were aborted - units are likely engaging autonomously
                -- Issue new rally orders only if threats still exist
                if threatCount > 0 then
                    self:planRallyOrders(objective, threatsNearObjective)
                end
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
    local threatCenter = self:calculateThreatClusterCenter(threats)
    if not threatCenter then
        threatCenter = objective.position
    end
    
    -- Select best units for assault based on threat composition and proximity
    -- Prioritize units that can arrive quickly enough and have good matchups
    local scoredCommanders = self:scoreCommandersForAssault(availableCommanders, threats, threatCenter)
    
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
            radius = 300,
            type = taskTypes.RALLY,
            alr = alr.MEDIUM,
            deadline = timer.getTime() + 600,
        })
        
        self:addPlannedOrder(commander, order)
    end
end

function OperationalCommander:calculateAssaultStagingPositions(threatCenter, selectedCommanders)
    -- Calculate rally positions spread around the threat to create flanking/converging attack
    -- Position units in an arc or circle around the threat at staging distance
    local positions = {}
    local distance = self.assaultStagingDistance
    local numUnits = #selectedCommanders
    
    if numUnits == 0 then
        return positions
    end
    
    -- Calculate the average direction from which units are approaching
    local avgDirX = 0
    local avgDirZ = 0
    local validCount = 0
    
    for _, commanderInfo in ipairs(selectedCommanders) do
        local commander = commanderInfo.commander
        local status = commander:getStatus()
        
        if status.position then
            local dx = status.position.x - threatCenter.x
            local dz = status.position.z - threatCenter.z
            local dist = math.sqrt(dx * dx + dz * dz)
            
            if dist > 1 then
                avgDirX = avgDirX + dx / dist
                avgDirZ = avgDirZ + dz / dist
                validCount = validCount + 1
            end
        end
    end
    
    -- Determine base angle for spread
    local baseAngle = 0
    if validCount > 0 then
        -- Average approach direction
        avgDirX = avgDirX / validCount
        avgDirZ = avgDirZ / validCount
        baseAngle = math.atan2(avgDirZ, avgDirX)
    end
    
    -- Spread units in an arc centered on the approach direction
    -- Arc width depends on number of units (narrow for few, wider for many)
    local arcWidth = math.min(math.pi, math.pi * 0.4 + (numUnits - 1) * 0.3)  -- 72° to 180°
    local angleStep = numUnits > 1 and arcWidth / (numUnits - 1) or 0
    local startAngle = baseAngle - arcWidth / 2
    
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
    
    if #idleUnits == 0 then
        return
    end
    
    -- Find objectives that need more forces
    for _, objective in ipairs(self.objectives) do
        if objective.status == "Active" then
            local statusCounts = objective:getOrderStatusCounts()
            
            -- If objective has some aborted orders, send idle units to help
            if statusCounts.aborted > 0 and #idleUnits > 0 then
                local threats = self:getThreatsNearPosition(objective.position, self.reconRadius)
                local threatCount = self:countThreats(threats)
                
                if threatCount > 0 then
                    -- Send as assault
                    for _, commander in ipairs(idleUnits) do
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
    
    for _, commander in pairs(self:getOwnGroupCommanders()) do
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
            local threatCenter = self:calculateThreatClusterCenter(groupInfo.threats)
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
    local threatCenter = self:calculateThreatClusterCenter(threats)
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
    for _, commander in pairs(self:getOwnGroupCommanders()) do
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

function OperationalCommander:countThreats(threats)
    local count = 0
    for _ in pairs(threats) do
        count = count + 1
    end
    return count
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

function OperationalCommander:taskTypeName(taskType)
    for name, value in pairs(taskTypes) do
        if value == taskType then
            return name
        end
    end
    return tostring(taskType)
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

function OperationalCommander:isOrderChanged(lastOrder, newOrder, commanderStatus)
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

function OperationalCommander:updateAllyIntelForAllGroups()
    -- Update ally intel for all active groups so they know about nearby friendlies
    local groupCommanders = self:getOwnGroupCommanders()
    local supportRadius = 5000  -- 5km support range
    
    for _, commander in pairs(groupCommanders) do
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
                    local distance = mist.vec.mag(mist.vec.sub(status.position, targetPosition))
                    
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
                    local distance = mist.vec.mag(mist.vec.sub(status.position, targetPosition))
                    
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

function OperationalCommander:calculateThreatClusterCenter(threats)
    -- Calculate the average position of all threats
    local sumX = 0
    local sumZ = 0
    local count = 0
    
    for _, threat in pairs(threats) do
        if threat.position then
            sumX = sumX + threat.position.x
            sumZ = sumZ + threat.position.z
            count = count + 1
        end
    end
    
    if count == 0 then
        return nil
    end
    
    return {
        x = sumX / count,
        y = 0,
        z = sumZ / count
    }
end

function OperationalCommander:calculateSupportRallyPosition(threatCenter, unitPosition, index, total)
    -- Calculate a rally position for support forces
    -- Position on the same side as the unit's current position to avoid crossing through threats
    local distance = 2000  -- 2km from threat center
    
    if unitPosition then
        -- Calculate vector from threat to unit's current position
        local dx = unitPosition.x - threatCenter.x
        local dz = unitPosition.z - threatCenter.z
        local currentDist = math.sqrt(dx * dx + dz * dz)
        
        if currentDist > 1 then
            -- Normalize and place at staging distance on same side
            local dirX = dx / currentDist
            local dirZ = dz / currentDist
            
            -- Add slight angular offset based on index to spread units out
            local angleOffset = (index - 1) * (math.pi / 4) -- 45 degree spacing
            local cosOffset = math.cos(angleOffset)
            local sinOffset = math.sin(angleOffset)
            
            -- Rotate the direction vector
            local rotatedX = dirX * cosOffset - dirZ * sinOffset
            local rotatedZ = dirX * sinOffset + dirZ * cosOffset
            
            return {
                x = threatCenter.x + (rotatedX * distance),
                y = threatCenter.y or 0,
                z = threatCenter.z + (rotatedZ * distance)
            }
        end
    end
    
    -- Fallback: use evenly spaced positions around threat
    local angleStep = (2 * math.pi) / total
    local angle = angleStep * (index - 1)
    
    local offsetX = math.cos(angle) * distance
    local offsetZ = math.sin(angle) * distance
    
    return {
        x = threatCenter.x + offsetX,
        y = threatCenter.y or 0,
        z = threatCenter.z + offsetZ
    }
end

function OperationalCommander:getDistanceToObjective(objective)
    -- Get the closest distance from any of our units to the objective
    local groupCommanders = self:getOwnGroupCommanders()
    local minDistance = math.huge
    
    for _, commander in pairs(groupCommanders) do
        local status = commander:getStatus()
        if status.position then
            local dist = mist.vec.mag(mist.vec.sub(status.position, objective.position))
            if dist < minDistance then
                minDistance = dist
            end
        end
    end
    
    return minDistance
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
                    local distance = mist.vec.mag(mist.vec.sub(status.position, objective.position))
                    
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

function OperationalCommander:getCommanderByName(groupName)
    local commanders = self:getOwnGroupCommanders()
    for _, commander in pairs(commanders) do
        if commander.groupName == groupName then
            return commander
        end
    end
    return nil
end

function OperationalCommander:syncOrderStatuses()
    local groupCommanders = self:getOwnGroupCommanders()

    for _, commander in pairs(groupCommanders) do
        local status = commander:getStatus()
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

function OperationalCommander:addPlannedOrder(commander, order, threats)
    -- Add an order to the planned orders list and mark the commander as having an order this cycle
    -- This prevents multiple orders being issued to the same unit
    if not self.plannedThisCycle[commander.groupName] then
        table.insert(self.plannedOrders, {
            commander = commander,
            order = order,
            threats = threats,
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

-- Calculate vulnerability of a force to enemy capabilities
-- Uses reverse lookup: enemy's offensive capability against each of our unit types
function ThreatAnalyzer.calculateVulnerability(forceAnalysis, enemyAnalysis)
    local vulnerability = {
        overall = 0,
        fromInfantry = 0,
        fromArmor = 0,
        fromAir = 0
    }
    
    -- Calculate composition ratios
    local totalCount = forceAnalysis.count
    if totalCount == 0 then
        return vulnerability
    end
    
    local infantryRatio = forceAnalysis.composition.infantry / totalCount
    local lightArmorRatio = forceAnalysis.composition["light-armor"] / totalCount
    local heavyArmorRatio = forceAnalysis.composition["heavy-armor"] / totalCount
    local supportRatio = forceAnalysis.composition.support / totalCount
    
    -- Combined armor ratio for vulnerability calculation
    local armorRatio = lightArmorRatio + heavyArmorRatio
    
    -- Enemy's offensive capability against our unit types = our vulnerability
    vulnerability.fromInfantry = infantryRatio * enemyAnalysis.offensiveCapability.vsInfantry
    vulnerability.fromArmor = armorRatio * enemyAnalysis.offensiveCapability.vsArmor
    vulnerability.fromAir = supportRatio * enemyAnalysis.offensiveCapability.vsAir
    
    vulnerability.overall = vulnerability.fromInfantry + vulnerability.fromArmor + vulnerability.fromAir
    
    return vulnerability
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
    
    -- Calculate mutual vulnerabilities
    local friendlyVulnerability = ThreatAnalyzer.calculateVulnerability(friendlyAnalysis, enemyAnalysis)
    local enemyVulnerability = ThreatAnalyzer.calculateVulnerability(enemyAnalysis, friendlyAnalysis)
    
    -- Calculate favorability as ratio of enemy vulnerability to friendly vulnerability
    -- Higher = we can hurt them more than they can hurt us
    local favorability = 1.0
    if friendlyVulnerability.overall > 0 then
        favorability = enemyVulnerability.overall / friendlyVulnerability.overall
    elseif enemyVulnerability.overall > 0 then
        favorability = math.huge
    end
    
    return {
        favorability = favorability,
        friendly = friendlyAnalysis,
        enemy = enemyAnalysis,
        friendlyVulnerability = friendlyVulnerability,
        enemyVulnerability = enemyVulnerability
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
            local dx = threat.position.x - position.x
            local dz = threat.position.z - position.z
            local distance = math.sqrt(dx * dx + dz * dz)
            
            if distance <= radius then
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
__bundle_register("group-commander", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local ThreatAnalyzer = require("threat-analyzer")
local ThreatDetector = require("threat-detector")
local ThreatTracker = require("threat-tracker")
local alr = constants.acceptableLevelsOfRisk
local dispositionTypes = constants.dispositionTypes
local formationTypes = constants.formationTypes
local oodaStates = constants.oodaStates
local orderStatus = constants.orderStatus
local roe = constants.rulesOfEngagement
local taskTypes = constants.taskTypes
local GroupCommander = {}
GroupCommander.__index = GroupCommander
GroupCommander.instances = {}

local oodaInterval = 10.0 -- seconds
local detectionRadius = 8000 -- meters

function GroupCommander.new(groupName, config)
    local self = setmetatable({}, GroupCommander)
    self.alr = alr.LOW
    self.coalition = config.color
    self.color = config.color
    self.destination = nil
    self.disposition = dispositionTypes.HOLD
    self.formationType = formationTypes.OFF_ROAD
    self.groupName = groupName
    self.initialUnitNames = self:getOwnUnitNames()
    self.initialCollectiveStatus = self:getCollectiveStatus()
    self.oodaState = oodaStates.OBSERVE
    self.orders = nil
    self.lastMoveOrder = nil
    self.ownForceStrength = nil
    self.roe = roe.WEAPON_HOLD
    self.threatTracker = ThreatTracker.new(groupName)
    self.threatAnalysis = nil
    self.lastThreatCenter = nil
    self.allyIntel = nil  -- Nearby ally strength info from OpsCom

    self.oodaOffset = math.random() * oodaInterval
    
    -- Register this instance
    table.insert(GroupCommander.instances, self)
    
    mist.scheduleFunction(
        GroupCommander.oodaTick,
        {self},
        timer.getTime() + self.oodaOffset,
        oodaInterval
    )
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

function GroupCommander:oodaTick()
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

function GroupCommander:observe()
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        env.info("WARNING: " .. self.groupName .. " group does not exist - cannot observe")
        return
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
                    local distToLastKnown = math.sqrt(
                        (ownPos.x - threat.position.x)^2 + 
                        (ownPos.z - threat.position.z)^2
                    )
                    
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
    if not self.orders or not self.orders:isActive() then
        self.orderContext = nil
        return
    end
    
    local ownPos = self:getOwnPosition()
    if not ownPos then
        self.orderContext = nil
        return
    end
    
    local orderedPosition = self.orders.position
    local orderedRadius = self.orders.radius or 500
    
    -- Calculate distance to ordered position
    local distanceToOrdered = math.sqrt(
        (ownPos.x - orderedPosition.x)^2 + 
        (ownPos.z - orderedPosition.z)^2
    )
    
    -- Check if we're within the objective radius
    local withinObjective = distanceToOrdered <= orderedRadius
    
    -- Determine thresholds based on ALR
    local orderedALR = self.orders.alr or alr.LOW
    local retreatThreshold = 0.4
    local maxAcceptableVulnerability = 45.0
    
    if orderedALR == alr.LOW then
        retreatThreshold = 0.8
        maxAcceptableVulnerability = 15.0
    elseif orderedALR == alr.HIGH then
        retreatThreshold = 0.2
        maxAcceptableVulnerability = 60.0
    end
    
    -- Store order context
    self.orderContext = {
        position = orderedPosition,
        radius = orderedRadius,
        type = self.orders.type,
        alr = orderedALR,
        distanceToOrdered = distanceToOrdered,
        withinObjective = withinObjective,
        retreatThreshold = retreatThreshold,
        maxAcceptableVulnerability = maxAcceptableVulnerability,
        leashDistance = 3000  -- Don't pursue threats beyond 3km from ordered position
    }
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
    
    -- Calculate vulnerability and favorability if threats exist
    local vulnerability = {overall = 0, fromInfantry = 0, fromArmor = 0, fromAir = 0}
    local favorability = 0
    
    if threatAnalysis.count > 0 then
        -- Calculate our vulnerability considering our own force
        vulnerability = ThreatAnalyzer.calculateVulnerability(self.ownForceStrength, threatAnalysis)
        
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
        
        -- Calculate favorability using combined force (enemy vulnerability / combined vulnerability)
        local enemyVulnerability = ThreatAnalyzer.calculateVulnerability(threatAnalysis, combinedForce)
        local combinedVulnerability = ThreatAnalyzer.calculateVulnerability(combinedForce, threatAnalysis)
        
        if combinedVulnerability.overall > 0 then
            favorability = enemyVulnerability.overall / combinedVulnerability.overall
        elseif enemyVulnerability.overall > 0 then
            favorability = math.huge
        end
        
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
    end
    
    -- Determine if threats are stale using ThreatTracker utility
    local threatsAreStale = self.threatTracker:isIntelStale(60)
    
    -- Store consolidated threat assessment
    self.threatAssessment = {
        count = threatAnalysis.count,
        analysis = threatAnalysis,
        statuses = threatStatuses,
        center = threatCenter,
        vulnerability = vulnerability,
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
    
    -- Normalize
    local distance = math.sqrt(dx * dx + dz * dz)
    if distance < 1 then
        -- Too close, pick arbitrary direction
        dx = 1
        dz = 0
        distance = 1
    end
    
    local dirX = dx / distance
    local dirZ = dz / distance
    
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
        
        local currentDistance = math.sqrt(
            (ownPos.x - threatCenter.x)^2 + 
            (ownPos.z - threatCenter.z)^2
        )
        
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

function GroupCommander:calculateDistanceBetweenUnits(unit1, unit2)
    local pos1 = unit1:getPosition().p
    local pos2 = unit2:getPosition().p
    return mist.utils.get2DDist(pos1, pos2)
end

function GroupCommander:calculateThreatCenter()
    -- Calculate the average position of all threats based on last known positions
    local sumX = 0
    local sumZ = 0
    local validCount = 0
    local statusCounts = {}
    
    local threats = self.threatTracker:getThreats()
    for unitName, threatData in pairs(threats) do
        -- Use stored position from last observation
        if threatData.position then
            sumX = sumX + threatData.position.x
            sumZ = sumZ + threatData.position.z
            validCount = validCount + 1
            statusCounts[threatData.status] = (statusCounts[threatData.status] or 0) + 1
        end
    end
    
    if validCount == 0 then
        return nil
    end
    
    return {
        x = sumX / validCount,
        z = sumZ / validCount
    }
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
    if advanceDestination then
        local destDist = math.sqrt(
            (advanceDestination.x - context.position.x)^2 + 
            (advanceDestination.z - context.position.z)^2
        )
        
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
    
    self.destination = self:getDestinationToObjective(context.position, context.radius)
    
    if self.destination then
        self:setDisposition(dispositionTypes.ADVANCE)
        env.info(self.groupName .. " DECIDE: ADVANCE (moving to objective)")
    else
        self:setDisposition(dispositionTypes.DEFEND)
        env.info(self.groupName .. " DECIDE: DEFEND (at objective)")
        
        -- Complete order if defending at objective
        if context.type == taskTypes.RALLY or context.type == taskTypes.REINFORCE then
            self.orders:complete()
        end
    end
end

-- Decide action when no threats exist
function GroupCommander:decideWithNoThreats()
    local context = self.orderContext
    self.destination = self:getDestinationToObjective(context.position, context.radius)
    
    if self.destination then
        self:setDisposition(dispositionTypes.ADVANCE)
        env.info(self.groupName .. " DECIDE: ADVANCE (no threats, to objective)")
    else
        self:setDisposition(dispositionTypes.DEFEND)
        env.info(self.groupName .. " DECIDE: DEFEND (at objective)")
        
        -- Complete RALLY/REINFORCE orders when arriving at position
        if context.type == taskTypes.RALLY or context.type == taskTypes.REINFORCE then
            self.orders:complete()
        end
    end
end

-- Decide action when threats are stale/unconfirmed
function GroupCommander:decideWithStaleThreats()
    local context = self.orderContext
    
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

function GroupCommander:getCollectiveStatus()
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        return 0
    end

    local totalCount = #self.initialUnitNames
    if totalCount == 0 then
        return 0
    end
    
    local aliveCount = 0
    local ammoCount = 0
    local ammmoLowState = nil
    local fuelQuantity = 0
    local fuelLowState = nil
    local healthPool = 0
    local healthLowState = nil
    for _, unitName in ipairs(self.initialUnitNames) do
        local unit = Unit.getByName(unitName)
        if unit and unit:isExist() then
            local unitAmmoTable = unit:getAmmo()
            local unitFuel = unit:getFuel()
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
            fuelQuantity = fuelQuantity + unitFuel
            healthPool = healthPool + unitHealth

            if not ammmoLowState or unitAmmoTotal < ammmoLowState then
                ammmoLowState = unitAmmoTotal
            end

            if not fuelLowState or unitFuel < fuelLowState then
                fuelLowState = unitFuel
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
        fuelQuantity = fuelQuantity,
        fuelLowState = fuelLowState,
        healthPool = healthPool,
        healthLowState = healthLowState,
    }
end

function GroupCommander:getDestinationToObjective(objectivePosition, objectiveRadius)
    -- Check if we're within objective radius. If so, return nil (stay put).
    -- If not, return the objective position to move toward.
    local ownPos = self:getOwnPosition()
    if not ownPos then
        return objectivePosition  -- Can't determine position, default to moving
    end
    
    local distanceToObjective = math.sqrt(
        (ownPos.x - objectivePosition.x)^2 + 
        (ownPos.z - objectivePosition.z)^2
    )
    
    if distanceToObjective <= objectiveRadius then
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

function GroupCommander:getUnitTypeName(unit)
    if not unit or not unit:isExist() then
        return nil
    end
    
    local typeName = unit:getTypeName()
    return typeName
end

-- Make decisions when following orders
function GroupCommander:handleOrderDecisions()
    -- Start order if just assigned
    if self.orders.status == orderStatus.ASSIGNED then
        self.orders:start()
        env.info(self.groupName .. " DECIDE: Starting order " .. self:taskTypeName(self.orders.type) .. 
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
        self.destination = self:calculateDestinationRelativeToThreats(threat.center, true)
        self.lastThreatCenter = threat.center
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
    
    -- RALLY orders: if threats are closer than rally destination, engage them directly
    -- ASSAULT orders should commit - don't check, just fight
    if context.type == taskTypes.RALLY and threat.center then
        local ownPos = self:getOwnPosition()
        if ownPos then
            local distanceToThreat = math.sqrt(
                (ownPos.x - threat.center.x)^2 + 
                (ownPos.z - threat.center.z)^2
            )
            local distanceToDestination = math.sqrt(
                (ownPos.x - context.position.x)^2 + 
                (ownPos.z - context.position.z)^2
            )
            
            -- If threat is significantly closer than rally point, abandon rally and engage
            -- Use 70% threshold to avoid flip-flopping
            if distanceToThreat < distanceToDestination * 0.7 then
                env.info(self.groupName .. " DECIDE: Threat closer than rally point, engaging directly")
                
                -- Abort the rally order and engage autonomously
                self.orders:abort("closer_threat")
                
                -- Strong position, advance on threats
                if threat.favorability >= advanceThreshold and 
                   threat.vulnerability.overall < context.maxAcceptableVulnerability * 0.5 then
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
    
    -- Strong position, can advance on threats
    if threat.favorability >= advanceThreshold and 
       threat.vulnerability.overall < context.maxAcceptableVulnerability * 0.5 and
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
    
    -- Decision thresholds (default/medium ALR)
    local retreatThreshold = 0.6
    local advanceThreshold = 1.5
    local maxAcceptableVulnerability = 20.0
    
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
    
    -- Weak position, retreat
    if threat.favorability < retreatThreshold or threat.vulnerability.overall > maxAcceptableVulnerability then
        env.info(self.groupName .. " DECIDE: RETREAT (Fav:" .. string.format("%.2f", threat.favorability) .. ")")
        self:setDisposition(dispositionTypes.RETREAT)
        self.destination = self:calculateDestinationRelativeToThreats(threat.center, true)
        self.lastThreatCenter = threat.center
        return
    end
    
    -- Strong position, advance
    if threat.favorability >= advanceThreshold and threat.vulnerability.overall < maxAcceptableVulnerability * 0.5 then
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
        distance = math.sqrt(
            (point.x - ownPos.x)^2 + 
            (point.z - ownPos.z)^2
        )
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
        ignoreRoads
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
    local shouldAbort = threat.favorability < context.retreatThreshold or 
                       threat.vulnerability.overall > context.maxAcceptableVulnerability
    
    if shouldAbort then
        env.info(self.groupName .. " DECIDE: Aborting order due to threat (favorability=" .. 
                 string.format("%.2f", threat.favorability) .. " vuln=" .. 
                 string.format("%.1f", threat.vulnerability.overall) .. ")")
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

function GroupCommander:taskTypeName(taskType)
    for name, value in pairs(taskTypes) do
        if value == taskType then
            return name
        end
    end
    return tostring(taskType)
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