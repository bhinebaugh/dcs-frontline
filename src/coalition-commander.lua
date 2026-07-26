-- aka Strategic Commander

-- local constants = require("constants")
local GroupCommander = require("group-commander")
-- local GroupProfiler = require("group-profiler")
local OperationalCommander = require("operational-commander")
local OODACommander = require("ooda-commander")
local Objective = require("objective")
-- local Order = require("order")
-- local OrderCoordinator = require("order-coordinator")
-- local ReconRallyAssaultPlan = require("doctrines.operational.recon-rally-assault-plan")
local CommanderVisualizer = require("commander-visualizer")
local SpatialAgent = require("spatial-agent")
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

local oodaInterval = 45.0 -- seconds

function CoalitionCommander.new(parent, config)
    local self = OODACommander.new({interval = oodaInterval})
    setmetatable(self, CoalitionCommander)
    self.map = parent
    self.coalition = config.color
    self.color = config.color
    self.opponent = config.color == "blue" and "red" or "blue"
    self.templates = config.groundTemplates
    self.groupId = 1
    self.groups = {} -- e.g. name location task
    self.reserves = {}
    self.groupsByZone = {}
    for _, name in pairs(self.map.allZones) do
        self.groupsByZone[name] = {}
    end
    self.groupsByTask = {}
    for i, j in pairs(taskTypes) do
        self.groupsByTask[j] = {}
    end
    self.opscoms = {}
    self.visualizer = CommanderVisualizer.new(self.map.map)
    self.operations = {
        active = {},
        history = {},
        group = nil,
        status = nil,
    }
    -- attitude/aggressiveness = offensive, defensive, cautious, etc
    return self
end


function CoalitionCommander:addReserves(groups)
    -- self.reserves = groups
    for _, groupName in pairs(groups) do
        local gc = GroupCommander.new(groupName, {
            color = self.color,
            visualizer = self.visualizer,
        })
        table.insert(self.reserves, gc)
    end
end

-- DEPRECATED
-- A preliminary phase to allow commander to choose group templates for all front zones
-- (random for now, TODO apply some strategy to placement of different types)
function CoalitionCommander:initiate(front)
    local reinforcements = {}
    for _, zoneName in pairs(front.zones) do
        for i = 1, math.random(2) do
            local r = math.random(#self.templates)
            local group = self.templates[r]
            local groupName = zoneName.."-"..self:getNewGroupId()
    
            local gc = GroupCommander.new(groupName, {
                color = self.color,
                visualizer = self.visualizer,
            })
            table.insert(self.reserves, gc)

            local groupData = {
                groupName = groupName,
                template = group
            }
            table.insert(reinforcements[zoneName], groupData)
        end
    end

    return reinforcements
end

-- NOTE: Doctrine usage example:
-- To assign a specific strategy to an objective, create the Doctrine and assign it:
--   local objective = Objective.new({...})
--   objective.doctrine = ReconRallyAssaultPlan.new(commanderName, config)
-- The OperationalCommander will use the Doctrine in its DECIDE phase.
-- If no Doctrine is assigned, it defaults to ReconRallyAssaultPlan.
function CoalitionCommander:observe()
    -- Prune destroyed groups from reserves
    local surviving = {}
    for _, gc in ipairs(self.reserves) do
        if gc.destroyed then
            self.visualizer:release("group:" .. gc.groupName)
        else
            table.insert(surviving, gc)
        end
    end
    self.reserves = surviving

    env.info(string.format("****** %s StratCom OBSERVE: blue=%d red=%d zones | reserves=%d | opscoms=%d",
        self.color,
        #self.map:getCluster("blue"),
        #self.map:getCluster("red"),
        #self.reserves,
        #self.opscoms))
end

function CoalitionCommander:orient()
    -- TODO compare current state to previous to extract trends (force strength, territorial control, etc)
    -- Consider observed threats and stalled operations / requests for reinforcements
    -- Identify opscoms whose objective is complete or failed
    self.opscoms_to_disband = {}
    local activeCount = 0
    for i, opscom in ipairs(self.opscoms) do
        local objective = opscom.orderCoordinator.objectives[1]
        if objective and objective:isComplete() then
            table.insert(self.opscoms_to_disband, i)
        else
            activeCount = activeCount + 1
        end
    end

    -- If no active opscoms will remain after disbanding, and reserves are available, find a new target
    -- TODO Select target based on knowledge of enemy strength or outcome of past operations
    self.pending_target = nil
    if activeCount == 0 and #self.reserves > 0 then
        local ownZones = self.map:getCluster(self.color)
        for _, zoneName in ipairs(ownZones) do
            local enemyNeighbors = self.map:getNeighbors(zoneName, self.opponent, true)
            if enemyNeighbors and #enemyNeighbors > 0 then
                local target = enemyNeighbors[math.random(#enemyNeighbors)]
                self.pending_target = {
                    zoneName = target,
                    position = self.map:getZone(target).point,
                }
                break
            end
        end
    end
end

function CoalitionCommander:decide()
    -- Select groups from reserves by proximity to the pending target
    -- TODO Balance proximity and suitability for type of operation
    self.pending_groups = {}
    if self.pending_target then
        local maxGroups = 3
        local candidates = {}
        for _, gc in ipairs(self.reserves) do
            local status = gc:getStatus()
            if status.position then
                table.insert(candidates, {
                    gc = gc,
                    dist = SpatialAgent.distance2D(status.position, self.pending_target.position),
                })
            end
        end
        table.sort(candidates, function(a, b) return a.dist < b.dist end)
        for i = 1, math.min(maxGroups, #candidates) do
            table.insert(self.pending_groups, candidates[i].gc)
        end
    end
end

function CoalitionCommander:act()
    -- Disband completed opscoms (iterate in reverse to safely remove by index)
    table.sort(self.opscoms_to_disband, function(a, b) return a > b end)
    for _, i in ipairs(self.opscoms_to_disband) do
        local opscom = self.opscoms[i]
        self.visualizer:release("opscom:" .. opscom.name)
        self.visualizer:release(self.color .. "_movement")
        local survivors = opscom:disband()
        for _, gc in ipairs(survivors) do
            -- This could be a good point to check residual gc doctrine and orders,
            -- to see if they are still appropriate or should be removed
            table.insert(self.reserves, gc)
        end
        table.remove(self.opscoms, i)
        env.info(string.format("****** %s StratCom ACT: disbanded opscom, %d groups returned to reserves",
            self.color, #survivors))
    end

    -- Create a new opscom if a target and groups are ready
    if self.pending_target and #self.pending_groups > 0 then
        -- Remove assigned groups from reserves
        for _, gc in ipairs(self.pending_groups) do
            for i, reserveGc in ipairs(self.reserves) do
                if reserveGc == gc then
                    table.remove(self.reserves, i)
                    break
                end
            end
        end

        local opscom = OperationalCommander.new({
            color = self.color,
            groupCommanders = self.pending_groups,
            visualizer = self.visualizer,
        })
        opscom.orderCoordinator.objectives = {
            Objective.new({
                type = taskTypes.ASSAULT,
                position = self.pending_target.position,
                radius = 500,
            })
        }
        table.insert(self.opscoms, opscom)
        env.info(string.format("****** %s StratCom ACT: created opscom → targeting %s with %d groups",
            self.color, self.pending_target.zoneName, #self.pending_groups))
        -- draw polygon around units and directive arrow at creation
        self.visualizer:syncOpscom(opscom, self.color)
    end

    -- Keep each active opscom's outline/directive marks in sync with current tasking
    -- for _, opscom in ipairs(self.opscoms) do
    --     self.visualizer:syncOpscom(opscom, self.color)
    -- end
end


-- ============================================================================
-- HELPER METHODS
-- ============================================================================

function CoalitionCommander:getNewGroupId()
    self.groupId = self.groupId + 1
    return self.groupId
end

return CoalitionCommander
