local taskTypes = require("constants").taskTypes
local statusTypes = require("constants").statusTypes

local CoalitionCommander = {}
CoalitionCommander.__index = CoalitionCommander

function CoalitionCommander.new(parent, config, groundTemplates)
    local self = setmetatable({}, CoalitionCommander)
    self.map = parent
    self.coalition = config.color
    self.color = config.color
    self.opponent = config.color == "blue" and "red" or "blue"
    self.templates = groundTemplates
    self.groups = {} -- e.g. name location task
    self.groupsByZone = {}
    for _, name in pairs(self.map.allZones) do
        self.groupsByZone[name] = {}
    end
    self.groupsByTask = {}
    for i, j in pairs(taskTypes) do
        self.groupsByTask[j] = {}
    end
    self.operations = {
        active = {},
        history = {},
        group = nil,
        status = nil,
    }
    -- attitude/aggressiveness = offensive, defensive, cautious, etc
    return self
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

function CoalitionCommander:chooseZoneReinforcements(zones)
    local reinforcements = {}
    for _, zoneName in pairs(zones) do
        local r = math.random(#self.templates)
        local group = self.templates[r]
        local groupName = zoneName.."-"..self.map:getNewGroupId()
        reinforcements[zoneName] = {
            groupName = groupName,
            template = group
        }
        self:addGroup(groupName, r, taskTypes.DEFEND, zoneName, zoneName)
    end
    return reinforcements
end

function CoalitionCommander:designateAssault()
    local frontlineReserves = {}
    local frontZones = self.map:getPerimeterZones(self.color)

    for _, zoneName in pairs(frontZones) do
        local groupsInZone = self.groupsByZone[zoneName]
        if #groupsInZone > 1 then
            local defensive = 0
            local zoneReserves = {}
            for _, groupName in pairs(groupsInZone) do
                if self.groups[groupName] and self.groups[groupName].task == taskTypes.DEFEND then
                    defensive = defensive + 1
                    table.insert(zoneReserves, groupName)
                end
            end
            if #zoneReserves > 1 then
                table.insert(frontlineReserves, {zone = zoneName, groups = zoneReserves})
            end
        end
    end

    if #frontlineReserves < 1 then
        env.info("    no frontline zones have groups available for offensive tasking")
        return nil
    end
    local randomReserves = frontlineReserves[math.random(#frontlineReserves)]

    local enemyNeighbors = self.map:getNeighbors(randomReserves.zone, self.opponent)
    local target = enemyNeighbors[math.random(#enemyNeighbors)]

    --for now, choose single group
    if #randomReserves.groups > 1 then --can task multiple groups if available
        env.info("    "..#randomReserves.groups.." groups available at "..randomReserves.zone)
    end
    local taskedGroup = randomReserves.groups[1]

    self:updateGroup(taskedGroup, {task = taskTypes.ASSAULT, target = target})
    table.insert(self.operations.active, {type = "assault", origin = randomReserves.zone, destination = target, group = taskedGroup})
    env.info("    tasking "..taskedGroup.." to assault "..target)

    return {
        group = taskedGroup,
        origin = self.map:getZone(randomReserves.zone),
        destination = self.map:getZone(target),
    }

end

function CoalitionCommander:issueOrders()
    env.info(self.color.." generating orders")
    if #self.operations.active > 4 then --limit number of active operations
        env.info("    pass (at capacity)")
        return nil
    end
    if math.random() < 0.5 then
        env.info("    pass (random)")
        return nil
    end

    local params = self:designateAssault()

    return params
end

return CoalitionCommander
