local constants = require("constants")
local GroupCommander = require("group-commander")
local Order = require("order")
local ThreatTracker = require("threat-tracker")

local alr = constants.acceptableLevelsOfRisk
local oodaStates = constants.oodaStates
local orderStatus = constants.orderStatus
local taskTypes = constants.taskTypes
local dispositionTypes = constants.dispositionTypes

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
    self.assaultStagingDistance = config.assaultStagingDistance or 10000
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
                        -- Don't cancel just because threats went to MEMORY - require total absence
                        local totalThreats = self:countThreats(currentThreats)
                        if totalThreats == 0 then
                            shouldCancel = true
                            cancelReason = "rally threats no longer exist"
                        else
                            -- Check if threats appeared between the unit and rally point
                            -- (Don't cancel just because threats are at the objective we're rallying toward)
                            local commander = self:getCommanderByName(order.assignedTo)
                            if commander then
                                local commanderStatus = commander:getStatus()
                                if commanderStatus.position then
                                    -- Distance to rally point
                                    local distToRally = mist.vec.mag(mist.vec.sub(commanderStatus.position, order.position))
                                    
                                    -- Distance from rally point to objective
                                    local rallyToObjective = mist.vec.mag(mist.vec.sub(order.position, order.objective.position))
                                    
                                    -- Only cancel if threats appeared much closer than the rally point
                                    -- AND are not near the objective (which is expected)
                                    local threatBlockingRally = false
                                    for unitName, threat in pairs(currentThreats) do
                                        if threat.position then
                                            local distToThreat = mist.vec.mag(mist.vec.sub(commanderStatus.position, threat.position))
                                            local threatToObjective = mist.vec.mag(mist.vec.sub(threat.position, order.objective.position))
                                            
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
                issuedAt = timer.getTime(),
                threatCenter = plan.threatCenter,  -- Store threat center for rally orders
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
    local threatCenter = self:calculateThreatClusterCenter(threats)
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
                local dx = threatCenter.x - lastOrder.threatCenter.x
                local dz = threatCenter.z - lastOrder.threatCenter.z
                local distance = math.sqrt(dx * dx + dz * dz)
                
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
    if not self.groupCommanders then
        self.groupCommanders = self:getOwnGroupCommanders()
    end
    
    local allUnits = {}
    for _, commander in ipairs(self.groupCommanders) do
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
        local attritionRate = totalUnits > 0 and (1 - (statusReport.aliveCount / totalUnits)) or 0
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
            local attritionRate = totalUnits > 0 and (1 - (statusReport.aliveCount / totalUnits)) or 0
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
            local attritionRate = totalUnits > 0 and (1 - (statusReport.aliveCount / totalUnits)) or 0
            local hadAmmoInitially = commander.initialAmmoCount and commander.initialAmmoCount > 0
            local isOutOfAmmo = hadAmmoInitially and statusReport.ammoCount == 0
            
            local reason = isOutOfAmmo and "ammo depleted" or 
                          ("heavy casualties: " .. string.format("%.0f%%", attritionRate * 100))
            
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
    for _, objective in ipairs(self.objectives) do
        if objective.status == "Active" then
            local statusCounts = objective:getOrderStatusCounts()
            
            -- If objective has some aborted orders, send idle units to help
            if statusCounts.aborted > 0 and #effectiveUnits > 0 then
                local threats = self:getThreatsNearPosition(objective.position, self.reconRadius)
                local threatCount = self:countThreats(threats)
                
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
                    -- Get detailed status report to check combat capability
                    local statusReport = commander:getStatusReport()
                    
                    -- Skip units with no offensive capability
                    -- - No ammo (current) means can't assault (includes both depleted and never-armed units)
                    -- - Heavy casualties (>50% losses) means unit is combat ineffective
                    local totalUnits = #commander.initialUnitNames
                    local attritionRate = totalUnits > 0 and (1 - (statusReport.aliveCount / totalUnits)) or 0
                    
                    if statusReport.ammoCount == 0 then
                        env.info("*** " .. self.color .. " Ops: Skipping " .. commander.groupName .. 
                                 " for assault (no ammo)")
                    elseif attritionRate > 0.3 then
                        env.info("*** " .. self.color .. " Ops: Skipping " .. commander.groupName .. 
                                 " for assault (heavy casualties: " .. 
                                 string.format("%.0f%%", attritionRate * 100) .. ")")
                    else
                        -- Unit is combat-effective, score it for assault
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
    
    for _, objective in ipairs(self.objectives) do
        if objective.status == "Captured" or objective.status == "Active" then
            local dist = mist.vec.mag(mist.vec.sub(status.position, objective.position))
            
            -- Check if there are threats near this objective
            local threats = self:getThreatsNearPosition(objective.position, self.reconRadius)
            local threatCount = self:countActiveThreats(threats)
            
            -- Prefer objectives with no active threats
            if threatCount == 0 and dist < minDistance then
                minDistance = dist
                nearestSafeObjective = objective
            end
        end
    end
    
    -- If found a safe objective, position unit 2km behind it (away from frontline)
    if nearestSafeObjective then
        -- Calculate direction from objective to unit (rear direction)
        local dx = status.position.x - nearestSafeObjective.position.x
        local dz = status.position.z - nearestSafeObjective.position.z
        local dist = math.sqrt(dx * dx + dz * dz)
        
        if dist > 1 then
            local dirX = dx / dist
            local dirZ = dz / dist
            
            -- Position 2km behind objective in same direction as unit's current position
            return {
                x = nearestSafeObjective.position.x + (dirX * 2000),
                y = nearestSafeObjective.position.y or 0,
                z = nearestSafeObjective.position.z + (dirZ * 2000)
            }
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
