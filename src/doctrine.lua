-- Doctrine: Pluggable decision strategy for OODACommanders
-- Receives context from ORIENT phase, returns decisions for ACT phase
-- Works at any command level (operational, tactical, individual)

local Doctrine = {}
Doctrine.__index = Doctrine

-- Factory method for creating new Doctrine instances
function Doctrine.new(name, commanderName)
    local self = setmetatable({}, Doctrine)
    
    self.name = name or "UnnamedPlan"
    self.commanderName = commanderName or "UnknownCommander"
    
    -- State tracking
    self.currentPhaseName = nil
    self.phaseHistory = {}
    self.phases = {}
    self.state = {}
    
    return self
end

-- Main planning method - subclasses must implement
-- @param context PlanningContext table with goal, situation, resources, commander
-- @return decisions table (structure varies by commander type)
function Doctrine:plan(context)
    env.info(self.commanderName .. " " .. self.name .. " executing phase " .. tostring(self.currentPhaseName))
    return self.phases[self.currentPhaseName](self, context)
end

function Doctrine:registerPhase(phaseName, planningFunction)
    if not self.currentPhaseName then
        self.currentPhaseName = phaseName
    end
    self.phases[phaseName] = planningFunction
end

function Doctrine:changePhase(phaseName)
    if self.currentPhaseName then
        table.insert(self.phaseHistory, {
            name = self.currentPhaseName,
            changedAt = timer.getTime()
        })
    end
    env.info(self.commanderName .. " " .. self.name .. " changing to phase " .. phaseName)
    self.currentPhaseName = phaseName
end

return Doctrine
