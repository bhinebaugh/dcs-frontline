-- ReconRallyAssaultPlan: Classic three-phase offensive strategy
-- Phase 1 (RECON): Scout ahead to identify threats
-- Phase 2 (RALLY): Stage forces at standoff distance for coordinated attack
-- Phase 3 (ASSAULT): Execute synchronized assault on objective
-- Phase 4 (DEFEND): Hold objective once secured

local constants = require("constants")
local Doctrine = require("doctrine")
local Order = require("order")
local SpatialAgent = require("spatial-agent")

local orderStatus = constants.orderStatus
local taskTypes = constants.taskTypes
local alr = constants.acceptableLevelsOfRisk

local ReconRallyAssaultPlan = {}
setmetatable(ReconRallyAssaultPlan, {__index = Doctrine})
ReconRallyAssaultPlan.__index = ReconRallyAssaultPlan

function ReconRallyAssaultPlan.new(commanderName)
    local self = Doctrine.new("ReconRallyAssault", commanderName)
    setmetatable(self, ReconRallyAssaultPlan)

    self:registerPhase("Recon", ReconRallyAssaultPlan.reconPhase)
    self:registerPhase("Rally", ReconRallyAssaultPlan.rallyPhase)
    self:registerPhase("Assault", ReconRallyAssaultPlan.assaultPhase)
    self:registerPhase("Defend", ReconRallyAssaultPlan.defendPhase)
    
    return self
end

function ReconRallyAssaultPlan:reconPhase(context)
    local objective = context.goal
    local situation = context.situation
    local resources = context.resources
    local commander = context.commander
    local availableCommanders = resources.availableCommanders
    local statusCounts = situation.statusCounts

    local orderPlans = {}

    -- Consider existing orders
    if statusCounts.inProgress > 0 or statusCounts.assigned > 0 then
        return orderPlans  -- Wait for current orders to resolve
    end

    -- Consider advancing to Rally
    if statusCounts.total > 0 and statusCounts.completed + statusCounts.aborted == statusCounts.total then
        self:changePhase("Rally")
        return orderPlans
    end

    -- Score commanders for Recon (lighter units preferred)
    local scoredCommanders = commander:scoreCommandersForRecon(availableCommanders, objective.position)
    local count = math.min(commander.maxReconGroups, #scoredCommanders)

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

function ReconRallyAssaultPlan:rallyPhase(context)
    local objective = context.goal
    local situation = context.situation
    local resources = context.resources
    local commander = context.commander
    local availableCommanders = resources.availableCommanders
    local statusCounts = situation.statusCounts
    local threats = situation.threats

    local orderPlans = {}

    -- Consider existing orders
    if statusCounts.inProgress > 0 or statusCounts.assigned > 0 then
        return orderPlans  -- Wait for current orders to resolve
    end

    -- Consider advancing to Assault
    if statusCounts.total > 0 and statusCounts.completed + statusCounts.aborted == statusCounts.total then
        self:changePhase("Assault")
        return orderPlans
    end
    
    -- Consider availability of suitable commanders
    if #availableCommanders == 0 then
        return orderPlans
    end
    
    -- Calculate threat center
    local threatCenter = SpatialAgent.calculateCenterOfObjects(threats)
    if not threatCenter then
        threatCenter = objective.position
    end
    
    -- Score and select best units for assault
    local scoredCommanders = commander:scoreCommandersForAssault(availableCommanders, threats, threatCenter)
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
        return orderPlans
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
        if speed and speed > 0 and speed < slowestSpeed then
            slowestSpeed = speed
        end
    end
    
    -- Fallback to reasonable default if no valid speed found
    if slowestSpeed == math.huge then
        slowestSpeed = 20  -- 20 m/s (~72 km/h) default ground speed
    end

    local pushTime = timer.getTime() + longestDistance / slowestSpeed
    
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

function ReconRallyAssaultPlan:assaultPhase(context)
    local objective = context.goal
    local situation = context.situation
    local resources = context.resources
    local commander = context.commander
    local availableCommanders = resources.availableCommanders
    local statusCounts = situation.statusCounts
    local threats = situation.threats

    local orderPlans = {}

    -- Consider existing orders
    if statusCounts.inProgress > 0 or statusCounts.assigned > 0 then
        return orderPlans  -- Wait for current orders to resolve
    end

    -- Consider advancing to Defend
    if statusCounts.completed + statusCounts.aborted == statusCounts.total then
        self:changePhase("Defend")
        return orderPlans
    end
    
    -- Calculate threat center
    local threatCenter = SpatialAgent.calculateThreatCenter(threats)
    if not threatCenter then
        threatCenter = objective.position
    end
    
    -- Score commanders for assault
    local scoredCommanders = commander:scoreCommandersForAssault(availableCommanders, threats, threatCenter)
    
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

function ReconRallyAssaultPlan:defendPhase(context)
    local objective = context.goal
    local situation = context.situation
    local resources = context.resources
    local commander = context.commander
    local availableCommanders = resources.availableCommanders
    local statusCounts = situation.statusCounts
    local threats = situation.threats

    local orderPlans = {}

    objective:markAchieved()

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


return ReconRallyAssaultPlan
