-- aka Strategic Commander

-- local constants = require("constants")
-- local GroupCommander = require("group-commander")
-- local GroupProfiler = require("group-profiler")
local OperationalCommander = require("operational-commander")
local OODACommander = require("ooda-commander")
local Objective = require("objective")
-- local Order = require("order")
-- local OrderCoordinator = require("order-coordinator")
-- local PlanningContext = require("planning-context")
-- local ReconRallyAssaultPlan = require("doctrines.operational.recon-rally-assault-plan")
-- local SpatialAgent = require("spatial-agent")
-- local ThreatTracker = require("threat-tracker")

-- local alr = constants.acceptableLevelsOfRisk
-- local orderStatus = constants.orderStatus
-- local taskTypes = constants.taskTypes
-- local dispositionTypes = constants.dispositionTypes

local taskTypes = require("constants").taskTypes
local statusTypes = require("constants").statusTypes

local CoalitionCommander = {}
setmetatable(CoalitionCommander, {__index = OODACommander})
CoalitionCommander.__index = CoalitionCommander

function CoalitionCommander.new(parent, config)
    local self = OODACommander.new({interval = 120.0})
    setmetatable(self, CoalitionCommander)
    self.map = parent
    self.coalition = config.color
    self.color = config.color
    self.opponent = config.color == "blue" and "red" or "blue"
    self.templates = config.groundTemplates
    self.groupId = 1
    self.groups = {} -- e.g. name location task
    self.groupsByZone = {}
    for _, name in pairs(self.map.allZones) do
        self.groupsByZone[name] = {}
    end
    self.groupsByTask = {}
    for i, j in pairs(taskTypes) do
        self.groupsByTask[j] = {}
    end
    self.opscom = {}
    self.operations = {
        active = {},
        history = {},
        group = nil,
        status = nil,
    }
    -- attitude/aggressiveness = offensive, defensive, cautious, etc
    return self
end

-- setup
-- assign groups in zones along front
-- lump into sections for opscoms
function CoalitionCommander:initiate(front)
    local opscom = OperationalCommander.new({color = self.color})
    table.insert(self.opscom, opscom)

    -- local frontlineForces = self:chooseZoneReinforcements(front.zones)
    local reinforcements = {}
    for _, zoneName in pairs(front.zones) do
        local r = math.random(#self.templates)
        local group = self.templates[r]
        local groupName = zoneName.."-"..self:getNewGroupId()
        reinforcements[zoneName] = {
            groupName = groupName,
            template = group
        }
        -- self:addGroup(groupName, r, taskTypes.DEFEND, zoneName, zoneName)
    end
    -- front.length

    -- assign operation/objectives
    -- .rallyPoints
    -- .orderCoordinator.objectives
    local randomZone = front.zones[math.random(#front.zones)]
    local enemyNeighbors = self.map:getNeighbors(randomZone, self.opponent, true)
    local target = enemyNeighbors[math.random(#enemyNeighbors)]
    local targetPosition = self.map:getZone(target).point

    opscom.orderCoordinator.objectives = {
        Objective.new({
            type = taskTypes.ASSAULT,
            position = targetPosition,
            radius = 500,
        })
    }

    return reinforcements
end

-- assess overall situation,
-- by looking at territory, front characteristics, strength and distribution, current combat, intel, enemy losses
-- compare to desired outcome (strategic objective)
-- NOTE: Doctrine usage example:
-- To assign a specific strategy to an objective, create the Doctrine and assign it:
--   local objective = Objective.new({...})
--   objective.doctrine = ReconRallyAssaultPlan.new(commanderName, config)
-- The OperationalCommander will use the Doctrine in its DECIDE phase.
-- If no Doctrine is assigned, it defaults to ReconRallyAssaultPlan.
function CoalitionCommander:observe()
end

function CoalitionCommander:orient()
end

function CoalitionCommander:decide()
end

function CoalitionCommander:act()
end


function CoalitionCommander:getNewGroupId()
    self.groupId = self.groupId + 1
    return self.groupId
end

function CoalitionCommander:addGroup(groupName, templateID, task, target, zoneName)
    self.groups[groupName] = {
        name = groupName,
        template = templateID,
        strength = #self.templates[templateID],
        task = task or taskTypes.DEFEND,
        location = zoneName,
        status = statusTypes.HOLD, -- preparing, en route, complete/at destination
        target = target or nil,
        origin = zoneName, --or point, or other value
    }
    table.insert(self.groupsByTask[task], groupName)
    if zoneName then
        table.insert(self.groupsByZone[zoneName], groupName)
    end
end
function CoalitionCommander:updateGroup(groupName, params)
    local grp = self.groups[groupName]
    for k, v in pairs(params) do
        if k == "task" then
            local oldTask = grp.task
            local newTask = v
            for i, g in pairs(self.groupsByTask[oldTask]) do
                if g == groupName then table.remove(self.groupsByTask[oldTask], i) end
            end
            table.insert(self.groupsByTask[newTask], groupName)
            --if groups was not already EN_ROUTE...
            if newTask == taskTypes.ASSAULT or newTask == taskTypes.REINFORCE or newTask == taskTypes.RECON then
                grp.status = statusTypes.EN_ROUTE
                for i, g in pairs(self.groupsByZone[grp.location]) do
                    if g == groupName then table.remove(self.groupsByZone[grp.location], i) end
                end
            end
        end
        self.groups[groupName][k] = v
    end
end
function CoalitionCommander:removeGroup(groupName)
    local task = self.groups[groupName].task
    local zone = self.groups[groupName].location
    local status = self.groups[groupName].status
    for i, g in pairs(self.groupsByTask[task]) do
        if g == groupName then table.remove(self.groupsByTask[task], i) end
    end
    if zone and status == statusTypes.HOLD then
        for i, g in pairs(self.groupsByZone[zone]) do
            if g == groupName then table.remove(self.groupsByZone[zone], i) end
        end
    end
    self.groups[groupName] = nil
end

function CoalitionCommander:registerUnitLost(unitName, groupName)
    env.info(self.coalition.." command: receiving report on "..unitName.." of "..groupName)
    local grp = self.groups[groupName]
    env.info("    "..self.coalition.." command lost "..unitName.." in assault on "..grp.target)
    grp.strength = grp.strength - 1
    env.info("    group strength is now "..grp.strength)
end
function CoalitionCommander:registerGroupLost(groupName)
    env.info(self.coalition.." command: receiving report on "..groupName)
    local grp = self.groups[groupName]
    if grp then
        env.info("    lost "..grp.name.." - assault on "..grp.target.." failed")
        for i, op in pairs(self.operations.active) do
            if op.group == groupName then
                table.insert(self.operations.history, op)
                self.operations.active[i] = nil
                env.info("+++ updated operations list")
                env.info(mist.utils.tableShow(self.operations.active))
                env.info("--- past operations list")
                env.info(mist.utils.tableShow(self.operations.history))
            end
        end
        self:removeGroup(groupName)
    else
        env.info("    ("..groupName.." was already reported lost)")
    end
end

return CoalitionCommander
