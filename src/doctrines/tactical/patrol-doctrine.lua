local constants = require("constants")
local dispositionTypes = constants.dispositionTypes
local Doctrine = require("doctrine")
local SpatialAgent = require("spatial-agent")
local PatrolDoctrine = {}
setmetatable(PatrolDoctrine, {__index = Doctrine})
PatrolDoctrine.__index = PatrolDoctrine

-- Factory method for creating new Doctrine instances
function PatrolDoctrine.new(commanderName)
    local self = Doctrine.new("Patrol", commanderName)
    setmetatable(self, PatrolDoctrine)

    self:registerPhase("OutboundLeg", PatrolDoctrine.outboundPhase)
    self:registerPhase("InboundLeg", PatrolDoctrine.inboundPhase)

    return self
end

function PatrolDoctrine:outboundPhase(context)
    local commander = context.commander
    local orders = commander.orders

    if not self.state.StartingPoint then
        self.state.StartingPoint = commander:getOwnPosition()
    end

    if not self.state.Destination then
        self.state.Destination = orders and orders.position or self.state.StartingPoint
    end

    local distanceToDestination = self.state.Destination and SpatialAgent.distance2D(commander:getOwnPosition(), self.state.Destination)
    env.info(commander.groupName .. " is " .. tostring(distanceToDestination) .. " meters from patrol destination")
    local isAtDestination = distanceToDestination and distanceToDestination < 50

    if isAtDestination then
        env.info(commander.groupName .. " has reached patrol destination, switching to InboundLeg")
        self:changePhase("InboundLeg")
        return {disposition = dispositionTypes.HOLD, destination = nil}
    else
        return {disposition = dispositionTypes.ADVANCE, destination = self.state.Destination, orderAction = "start"}
    end
end

function PatrolDoctrine:inboundPhase(context)
    local commander = context.commander

    local isAtStart = self.state.StartingPoint and SpatialAgent.distance2D(commander:getOwnPosition(), self.state.StartingPoint) < 50

    if isAtStart then
        env.info(commander.groupName .. " has returned to starting point, switching to OutboundLeg")
        self:changePhase("OutboundLeg")
        return {disposition = dispositionTypes.HOLD, destination = nil}
    else
        return {disposition = dispositionTypes.ADVANCE, destination = self.state.StartingPoint}
    end
end


return PatrolDoctrine
