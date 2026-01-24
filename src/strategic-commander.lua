local constants = require("constants")
local GroupCommander = require("group-commander")

local alr = constants.acceptableLevelsOfRisk
local oodaStates = constants.oodaStates
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
    self.threats = {}
    self.objectives = {}
    
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
    self.threats = self:getKnownThreats()
    -- Control zone statuses
    -- Existing objectives and their statuses
    -- Historical objectives and outcomes
end

function StrategicCommander:orient()
    env.info(self.color .. "StrategicCommander: ORIENT")
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
    self.retreatingGroups = {}
    for _, commander in pairs(ownGroupCommanders) do
        local status = commander:getStatus()
        if status.roe == roe.RETREAT then
            table.insert(self.retreatingGroups, commander)
            table.remove(ownGroupCommanders, _)
        end
    end

    -- Reserves to reinforce threatened forces
    self.reinforcementGroups = {}
    for _, retreatingCommander in pairs(self.retreatingGroups) do
        local retreatPosition = retreatingCommander:getStatus().retreatPosition
        local nearestReinforcement = nil
        local nearestDistance = math.huge
        for _, commander in pairs(ownGroupCommanders) do
            local status = commander:getStatus()
            local dist = mist.vec.mag(
                mist.vec.sub(status.position, retreatPosition)
            )
            if dist < nearestDistance then
                nearestDistance = dist
                nearestReinforcement = commander
            end
        end
        if nearestReinforcement then
            table.insert(self.reinforcementGroups, {
                reinforcingCommander = nearestReinforcement,
                retreatingCommander = retreatingCommander,
                retreatPosition = retreatPosition
            })
            for i, commander in pairs(ownGroupCommanders) do
                if commander == nearestReinforcement then
                    table.remove(ownGroupCommanders, i)
                end
            end
        end
    end

    -- Low supply groups to resupply points
    -- Reconnaissance to gather needed intelligence
    -- Reposition for coordinated action on objectives
    for _, commander in pairs(ownGroupCommanders) do
        -- Assign each remaining commander to act on primary objective
        if self.prioirtyObjective then
            env.info(
                self.color .. "StrategicCommander: ordering " ..
                commander.name .. " to act on objective " ..
                self.prioirtyObjective.type
            )
            commander:issueOrder({
                alr = alr.MEDIUM,
                position = self.prioirtyObjective.position,
                type = self.prioirtyObjective.type,
            })
        end
    end

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

        env.info(
            self.color .. "StrategicCommander: ordering " ..
            reinforcingCommander.name .. " to reinforce " ..
            retreatingCommander.name .. " at position " ..
            mist.vec.tostring(retreatPosition)
        )
        reinforcingCommander:issueOrder({
            alr = alr.MEDIUM,
            position = retreatPosition,
            type = taskTypes.REINFORCE,
        })
    end
end

function StrategicCommander:assesObjective(objective)
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
    local highestProbability = 0
    for _, objective in pairs(self.objectives) do
        -- Evaluate each objective's likelihood of success
        -- Update objective status accordingly
        local probability = self:assesObjective(objective)
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

function StrategicCommander:getKnownThreats()
    local groupCommanders = self:getOwnGroupCommanders()
    local threats = {}

    for _, commander in pairs(groupCommanders) do
        local status = commander:getStatus()
        for _, threat in pairs(status.threats) do
            threat.sightedAt = timer.getTime()
            threats[threat.name] = threat
        end
    end

    return threats
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
    for _, threat in pairs(self.threats) do
        local dist = mist.vec.mag(mist.vec.sub(threat.position, position))
        if dist <= radius then
            table.insert(nearbyThreats, threat)
        end
    end
    return nearbyThreats
end

return StrategicCommander
