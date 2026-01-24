local constants = require("constants")
local alr = constants.acceptableLevelsOfRisk
local oodaStates = constants.oodaStates
local roe = constants.rulesOfEngagement
local StrategicCommander = {}
StrategicCommander.__index = StrategicCommander

local oodaInterval = 30.0 -- seconds

function StrategicCommander.new(config)
    local self = setmetatable({}, StrategicCommander)

    self.color = config.color or "white"
    self.oodaState = oodaStates.OBSERVE
    self.oodaOffset = math.random() * oodaInterval
    
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
    -- Control zone statuses
    -- Existing objectives and their statuses
    -- Historical objectives and outcomes
end

function StrategicCommander:orient()
    env.info(self.color .. "StrategicCommander: ORIENT")
    -- Analyze enemy objectives and likely courses of action
    -- Assess current objectives for liklihood of success 
    -- Assess new opportunities for objectives
    -- Identify stale information and intelligence gaps
end

function StrategicCommander:decide()
    env.info(self.color .. "StrategicCommander: DECIDE")
    -- Set one primary objective if none exists
    -- Stale information in need of updated status
    -- Prioritize actions for each own force group
       -- Retreating forces to safe locations
       -- Reserves to reinforce threatened forces
       -- Low supply groups to resupply points
       -- Reconnaissance to gather needed intelligence
       -- Reposition for coordinated action on objectives
       -- Offensive actions on objectives
       -- Logistics to resupply points needing replenishment
end

function StrategicCommander:act()
    env.info(self.color .. "StrategicCommander: ACT")
    -- Request communications updates from own forces
    -- Issue orders to own force groups based on decisions made
end

return StrategicCommander
