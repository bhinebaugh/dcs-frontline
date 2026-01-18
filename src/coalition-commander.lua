local taskTypes = require("constants").taskTypes

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
    for i,j in pairs(taskTypes) do
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
        -- location: zone or en route or point or nearest zone
        -- status: hold, preparing, en route, complete/at destination
        target = target or nil,
        origin = zoneName, --or point, or other value
    }
    table.insert(self.groupsByTask[task], groupName)
    if zoneName then
        table.insert(self.groupsByZone[zoneName], groupName)
    end
end
function CoalitionCommander:updateGroup(groupName, params)
    --stub
end
function CoalitionCommander:removeGroup(groupName)
    local task = self.groups[groupName].task
    -- remove from self.groupsByTask[task]
    -- self.groups[groupName].origin/target
    -- self.groupsByZone
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
    local frontlineForces = {}
    local frontZones = self.map:getPerimeterZones(self.color)

    for _, zoneName in pairs(frontZones) do
        local zoneGroups = self.groupsByZone[zoneName]
        if #zoneGroups > 1 then
            local defensive = 0
            for _, groupName in pairs(zoneGroups) do
                if self.groups[groupName].task == taskTypes.DEFEND then defensive = defensive + 1 end
            end
            if defensive > 1 then
                table.insert(frontlineForces, {zone = zoneName, count = #zoneGroups})
            end
        end
    end

    if #frontlineForces < 1 then
        env.info("...no frontline zones have groups available for offensive tasking")
        return nil
    end
    local tasked = frontlineForces[math.random(#frontlineForces)]
    local enemyNeighbors = self.map:getNeighbors(tasked.zone, self.opponent)
    local target = enemyNeighbors[math.random(#enemyNeighbors)]

    local zoneGroups = self.groupsByZone[tasked.zone]
    local availableGroups = {}
    for _, grp in pairs(zoneGroups) do
        if self.groups[grp].task == taskTypes.DEFEND then
            table.insert(availableGroups, grp)
        end
    end
    local taskedGroup = availableGroups[math.random(#availableGroups)]

    --update group
    self.groups[taskedGroup].task = taskTypes.ASSAULT
    self.groups[taskedGroup].target = target
    table.insert(self.operations.active, {type = "assault", origin = tasked.zone, destination = target, group = taskedGroup})
    env.info("    tasking "..taskedGroup.." to assault "..target)

    return {
        group = taskedGroup,
        origin = self.map:getZone(tasked.zone),
        destination = self.map:getZone(target),
    }

end

function CoalitionCommander:issueOrders()
    env.info(self.color.." generating orders")
    if #self.operations.active > 4 then --limit number of active operations
        env.info("    operations at capacity")
        return nil
    end
    if math.random() < 0.5 then
        env.info("    (random) refrain from launching new offensive")
        return nil
    end

    local params = self:designateAssault()

    return params
end

return CoalitionCommander
