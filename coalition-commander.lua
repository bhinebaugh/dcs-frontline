local CoalitionCommander = {}
CoalitionCommander.__index = CoalitionCommander

function CoalitionCommander.new(parent, config, groundTemplates)
    local self = setmetatable({}, CoalitionCommander)
    self.map = parent
    self.coalition = config.color
    self.opponent = config.color == "blue" and "red" or "blue"
    self.templates = groundTemplates[self.coalition]
    self.groups = {}
    self.operations = {
        active = {},
        history = {}
    }
    -- reference to zone "map", to ask for the state of things
    -- attitude/aggressiveness = offensive, defensive, cautious, etc
    return self
end

function CoalitionCommander:chooseTarget()
    local r = math.random(#self.map.front[self.coalition])
    local randomBorderEdge = self.map.front[self.coalition][r]
    local origin = randomBorderEdge.p1
    local enemyNeighbors = self.map:getNeighbors(origin, self.opponent)

    local target = enemyNeighbors[math.random(#enemyNeighbors)]
    -- SpawnGroupInZone(origin, self.coalition)
    table.insert(self.operations.active, {origin = origin, target = target})
    self.map:drawDirective(origin, target)
end

return CoalitionCommander
