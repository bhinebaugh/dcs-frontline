-- ReconRallyAssaultPlan: Classic three-phase offensive strategy
-- Phase 1 (RECON): Scout ahead to identify threats
-- Phase 2 (RALLY): Stage forces at standoff distance for coordinated attack
-- Phase 3 (ASSAULT): Execute synchronized assault on objective
-- Phase 4 (DEFEND): Hold objective once secured

local constants = require("constants")
local GamePlan = require("game-plan")
local Order = require("order")
local SpatialAgent = require("spatial-agent")

local orderStatus = constants.orderStatus
local taskTypes = constants.taskTypes
local alr = constants.acceptableLevelsOfRisk

local ReconRallyAssaultPlan = {}
setmetatable(ReconRallyAssaultPlan, {__index = GamePlan})
ReconRallyAssaultPlan.__index = ReconRallyAssaultPlan

function ReconRallyAssaultPlan.new()
    local self = GamePlan.new({
        name = "ReconRallyAssault",
        description = "Scout → Stage → Assault → Defend strategy for coordinated offensive operations"
    })
    setmetatable(self, ReconRallyAssaultPlan)
    
    return self
end

-- Main planning method
function ReconRallyAssaultPlan:plan(context)
    local objective = context.goal
    local situation = context.situation
    local resources = context.resources
    local commander = context.commander
    
    -- Validate context structure
    if not resources or not resources.availableCommanders then
        env.info("ERROR: ReconRallyAssaultPlan - invalid context, missing resources")
        return {}
    end
    
    -- Determine current phase from objective state
    local phase = self:determinePhase(objective, situation)
    
    -- Plan orders for this phase
    if phase == "RECON" then
        return self:planReconPhase(objective, resources, commander)
    elseif phase == "RALLY" then
        return self:planRallyPhase(objective, resources, situation, commander)
    elseif phase == "ASSAULT" then
        return self:planAssaultPhase(objective, resources, situation, commander)
    elseif phase == "DEFEND" then
        return self:planDefendPhase(objective, resources, situation, commander)
    elseif phase == "WAIT" then
        return {}  -- No orders, waiting for current phase to complete
    end
    
    return {}
end

-- Determine current phase based on objective state
function ReconRallyAssaultPlan:determinePhase(objective, situation)
    local statusCounts = situation.statusCounts
    local threatCount = situation.threatCount
    
    -- If no orders exist, start with RECON
    if statusCounts.total == 0 then
        return "RECON"
    end
    
    -- If orders are in progress, wait
    if statusCounts.inProgress > 0 or statusCounts.assigned > 0 then
        return "WAIT"
    end
    
    -- All orders completed or aborted - determine next phase
    if statusCounts.completed + statusCounts.aborted == statusCounts.total then
        local lastOrderType, lastCompletedCount, lastAbortedCount = self:getLastOrderStats(objective)
        
        if lastOrderType == taskTypes.RECON then
            if threatCount == 0 then
                -- RECON found no threats - check if at objective
                if self:isAtObjective(objective, situation) then
                    return "DEFEND"  -- Objective secured
                else
                    return "RECON"  -- Continue toward objective
                end
            else
                -- Threats found - rally forces
                return "RALLY"
            end
            
        elseif lastOrderType == taskTypes.RALLY then
            local totalRallies = lastCompletedCount + lastAbortedCount
            
            if lastAbortedCount == totalRallies then
                -- All rallies aborted - reissue if threats still exist
                if threatCount > 0 then
                    return "RALLY"
                else
                    return "RECON"
                end
            elseif lastCompletedCount == totalRallies then
                -- All rallies complete - assault
                return "ASSAULT"
            else
                -- Some rallies in progress
                return "WAIT"
            end
            
        elseif lastOrderType == taskTypes.ASSAULT then
            local totalAssaults = lastCompletedCount + lastAbortedCount
            
            if lastCompletedCount > 0 and lastCompletedCount == totalAssaults then
                -- All assaults complete - transition to DEFEND even if threats remain
                return "DEFEND"
            elseif lastAbortedCount == totalAssaults then
                -- All assaults aborted - try again or fall back
                if threatCount > 0 then
                    return "RALLY"
                else
                    return "RECON"
                end
            else
                -- Some assaults still in progress
                return "WAIT"
            end
            
        elseif lastOrderType == taskTypes.DEFEND then
            if threatCount > 0 then
                -- New threats - rally to engage
                return "RALLY"
            else
                -- Continue defending
                return "DEFEND"
            end
        end
    end
    
    return "WAIT"
end

-- Get stats about last order batch
function ReconRallyAssaultPlan:getLastOrderStats(objective)
    local lastOrderType = nil
    local completedCount = 0
    local abortedCount = 0
    
    if #objective.orders > 0 then
        lastOrderType = objective.orders[#objective.orders].type
        
        -- Count how many of this type completed vs aborted
        for i = #objective.orders, 1, -1 do
            if objective.orders[i].type == lastOrderType then
                if objective.orders[i].status == orderStatus.COMPLETED then
                    completedCount = completedCount + 1
                elseif objective.orders[i].status == orderStatus.ABORTED then
                    abortedCount = abortedCount + 1
                end
            else
                break  -- Different order type
            end
        end
    end
    
    return lastOrderType, completedCount, abortedCount
end

-- Check if forces are at objective
function ReconRallyAssaultPlan:isAtObjective(objective, situation)
    -- Get commander from context passed through situation
    local commander = situation.commander
    if not commander then return false end
    
    local GroupCommander = require("group-commander")
    local reconDistance = math.huge
    
    for _, cmd in pairs(GroupCommander.getInstances(commander.color)) do
        local cmdStatus = cmd:getStatus()
        if cmdStatus.position then
            local dist = SpatialAgent.distance2D(cmdStatus.position, objective.position)
            if dist and dist < reconDistance then
                reconDistance = dist
            end
        end
    end
    
    return reconDistance < objective.radius * 2
end

-- ============================================================================
-- PHASE PLANNING METHODS
-- ============================================================================
-- These methods can access:
--   resources.availableCommanders - units with no active orders (polite)
--   resources.allCommanders - ALL units, can recruit/reassign (aggressive)
-- ReconRallyAssault uses only availableCommanders (conservative strategy)

function ReconRallyAssaultPlan:planReconPhase(objective, resources, commander)
    local availableCommanders = resources.availableCommanders
    
    -- Score commanders for RECON (lighter units preferred)
    local scoredCommanders = commander:scoreCommandersForRecon(availableCommanders, objective.position)
    local count = math.min(commander.maxReconGroups, #scoredCommanders)
    
    local orderPlans = {}
    for i = 1, count do
        local cmd = scoredCommanders[i].commander
        local order = Order.new({
            assignedTo = cmd.groupName,
            objective = objective,
            position = objective.position,
            radius = objective.radius,
            type = taskTypes.RECON,
            alr = alr.MEDIUM,
        })
        
        table.insert(orderPlans, {
            commander = cmd,
            order = order
        })
    end
    
    return orderPlans
end

function ReconRallyAssaultPlan:planRallyPhase(objective, resources, situation, commander)
    local availableCommanders = resources.availableCommanders
    local threats = situation.threats
    
    if #availableCommanders == 0 then
        return {}
    end
    
    -- Calculate threat center
    local threatCenter = SpatialAgent.calculateThreatCenter(threats)
    if not threatCenter then
        threatCenter = objective.position
    end
    
    -- Filter commanders who recently rallied at similar position
    local filteredCommanders = self:filterRecentRallies(availableCommanders, commander, threatCenter)
    
    if #filteredCommanders == 0 then
        return {}
    end
    
    -- Score and select best units for assault
    local scoredCommanders = commander:scoreCommandersForAssault(filteredCommanders, threats, threatCenter)
    local selectedCommanders = commander:selectCommandersWithinTimeWindow(scoredCommanders, threatCenter, 1200)
    
    -- Fallback: send closest units if none within time window
    if #selectedCommanders == 0 and #scoredCommanders > 0 then
        selectedCommanders = {scoredCommanders[1], scoredCommanders[2], scoredCommanders[3]}
        -- Remove nils
        local temp = {}
        for _, sc in ipairs(selectedCommanders) do
            if sc then table.insert(temp, sc) end
        end
        selectedCommanders = temp
    end
    
    if #selectedCommanders == 0 then
        return {}
    end
    
    -- Extract commander positions for staging calculation
    local commanderPositions = {}
    for _, cmdInfo in ipairs(selectedCommanders) do
        local status = cmdInfo.commander:getStatus()
        if status.position then
            table.insert(commanderPositions, status.position)
        end
    end
    
    -- Calculate staging positions using SpatialAgent
    local stagingPositions = SpatialAgent.calculateAlliedSideStagingPositions(
        threatCenter,
        commander.assaultStagingDistance,
        commanderPositions,
        120  -- 120° arc
    )

    local longestDistance = 0
    for i, pos in ipairs(stagingPositions) do
        local dist = SpatialAgent.distance2D(commanderPositions[i], pos)
        if dist and dist > longestDistance then
            longestDistance = dist
        end
    end

    local slowestSpeed = math.huge
    for _, cmdInfo in ipairs(selectedCommanders) do
        local speed = cmdInfo.commander:getSlowestUnitSpeed()
        if speed and speed < slowestSpeed then
            slowestSpeed = speed
        end
    end

    local pushTime = timer.getTime() + longestDistance / slowestSpeed
    
    local orderPlans = {}
    for i, commanderInfo in ipairs(selectedCommanders) do
        local cmd = commanderInfo.commander
        local rallyPos = stagingPositions[i]
        
        if rallyPos then
            local order = Order.new({
                assignedTo = cmd.groupName,
                objective = objective,
                position = rallyPos,
                pushTime = pushTime,  -- Hold at rally point until this time
                radius = 1000,
                type = taskTypes.RALLY,
                alr = alr.MEDIUM,
            })
            
            table.insert(orderPlans, {
                commander = cmd,
                order = order,
                threats = threats,
                threatCenter = threatCenter
            })
        end
    end
    
    return orderPlans
end

function ReconRallyAssaultPlan:planAssaultPhase(objective, resources, situation, commander)
    local availableCommanders = resources.availableCommanders
    local threats = situation.threats
    
    -- Calculate threat center
    local threatCenter = SpatialAgent.calculateThreatCenter(threats)
    if not threatCenter then
        threatCenter = objective.position
    end
    
    -- Score commanders for assault
    local scoredCommanders = commander:scoreCommandersForAssault(availableCommanders, threats, threatCenter)
    
    local orderPlans = {}
    for _, commanderInfo in ipairs(scoredCommanders) do
        local cmd = commanderInfo.commander
        local order = Order.new({
            assignedTo = cmd.groupName,
            objective = objective,
            position = threatCenter,
            radius = commander.assaultRadius,
            type = taskTypes.ASSAULT,
            alr = alr.HIGH,
            deadline = objective.deadline or (timer.getTime() + 1800),
        })
        
        table.insert(orderPlans, {
            commander = cmd,
            order = order,
            threats = threats,
            threatCenter = threatCenter
        })
    end
    
    return orderPlans
end

function ReconRallyAssaultPlan:planDefendPhase(objective, resources, situation, commander)
    objective:markAchieved()
    
    local availableCommanders = resources.availableCommanders
    local threats = situation.threats
    
    -- Calculate defensive center (objective or threat center if threats nearby)
    local defendPosition = objective.position
    if threats and next(threats) then
        local threatCenter = SpatialAgent.calculateThreatCenter(threats)
        if threatCenter then
            -- Bias toward objective but acknowledge threats
            defendPosition = {
                x = (objective.position.x + threatCenter.x) / 2,
                z = (objective.position.z + threatCenter.z) / 2
            }
        end
    end
    
    -- Issue DEFEND orders to available groups
    local orderPlans = {}
    for _, cmd in ipairs(availableCommanders) do
        local order = Order.new({
            assignedTo = cmd.groupName,
            objective = objective,
            position = defendPosition,
            radius = objective.radius or 2000,
            type = taskTypes.DEFEND,
            alr = alr.MEDIUM,
        })
        
        table.insert(orderPlans, {
            commander = cmd,
            order = order,
            threats = threats
        })
    end
    
    return orderPlans
end

-- Filter out commanders who recently completed rally at similar threat position
function ReconRallyAssaultPlan:filterRecentRallies(availableCommanders, opsCommander, threatCenter)
    local filtered = {}
    local currentTime = timer.getTime()
    
    for _, commander in ipairs(availableCommanders) do
        local shouldFilter = false
        local lastOrder = opsCommander.lastIssuedOrders[commander.groupName]
        
        if lastOrder and 
           lastOrder.type == taskTypes.RALLY and 
           lastOrder.threatCenter and
           (currentTime - lastOrder.issuedAt) < 300 then  -- Within last 5 min
           
            local threatDist = SpatialAgent.distance2D(lastOrder.threatCenter, threatCenter)
            if threatDist and threatDist < 3000 then  -- Threat center hasn't moved much
                shouldFilter = true
            end
        end
        
        if not shouldFilter then
            table.insert(filtered, commander)
        end
    end
    
    return filtered
end

return ReconRallyAssaultPlan
