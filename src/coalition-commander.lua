local CoalitionCommander = {}
CoalitionCommander.__index = CoalitionCommander

function CoalitionCommander.new(parent, config, groundTemplates)
    local self = setmetatable({}, CoalitionCommander)
    self.map = parent
    self.coalition = config.color
    self.color = config.color
    self.opponent = config.color == "blue" and "red" or "blue"
    self.templates = groundTemplates
    self.groups = {}
    self.operations = {
        active = {},
        history = {},
        group = nil,
        status = nil,
    }
    -- attitude/aggressiveness = offensive, defensive, cautious, etc
    return self
end

function CoalitionCommander:chooseZoneReinforcements()
    local reinforcements = {}
    local frontZones = self.map:getPerimeterZones(self.color)
    for _, zoneName in pairs(frontZones) do
        local r = math.random(#self.templates)
        local group = self.templates[r]
        reinforcements[zoneName] = group
    end
    return reinforcements
end

function CoalitionCommander:chooseTarget()
    local r = math.random(#self.map.front[self.coalition])
    local randomBorderEdge = self.map.front[self.coalition][r]
    local origin = randomBorderEdge.p1
    local enemyNeighbors = self.map:getNeighbors(origin, self.opponent)

    local target = enemyNeighbors[math.random(#enemyNeighbors)]
    table.insert(self.operations.active, {type = "assault", origin = origin, destination = target, group = nil})
    self.map:drawDirective(origin, target)
end

function CoalitionCommander:launchAssault()
    -- match available groups with active operation
    if next(self.operations.active) == nil then
        env.info("NO ACTIVE OPERATIONS no units tasks")
        return false
    end
    local op = self.operations.active[1]
    env.info("active operations for "..self.coalition)
    env.info(mist.utils.tableShow(op))
    local tgt = self.map:getZone(op.destination)
    env.info("destination "..tgt.x..", "..tgt.y)

    local zoneGroups = self.map:getGroupsInZone(op.origin)
    env.info("groups available ")
    env.info(mist.utils.tableShow(zoneGroups))

    --select a group from zone, randomly at first
    if #zoneGroups > 1 then
        op.group = zoneGroups[math.random(#zoneGroups)]
    else
        op.group = zoneGroups[1] --self.map:spawnGroupInZone(op.origin, self.color, groundTemplates[self.color][1])
    end

    return {
        group = op.group,
        destination = tgt.point
    }
end

return CoalitionCommander
