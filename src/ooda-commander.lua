local constants = require("constants")
local oodaStates = constants.oodaStates

local OODACommander = {}
OODACommander.__index = OODACommander

function OODACommander.new(config)
    local self = setmetatable({}, OODACommander)

    local oodaInterval = config.interval or 10

    self.oodaState = oodaStates.OBSERVE
    self.oodaOffset = math.random() * oodaInterval

    mist.scheduleFunction(
        OODACommander.oodaTick,
        {self},
        timer.getTime() + self.oodaOffset,
        oodaInterval
    )
    return self
end

function OODACommander:oodaTick()
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

function OODACommander:observe()
    error("OODACommander subclass must implement observe()")
end

function OODACommander:orient()
    error("OODACommander subclass must implement orient()")
end

function OODACommander:decide()
    error("OODACommander subclass must implement decide()")
end

function OODACommander:act()
    error("OODACommander subclass must implement act()")
end

return OODACommander
