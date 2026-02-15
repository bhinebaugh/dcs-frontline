-- Proceed toward the given an objective until threats are spotted
-- If threats encountered, mark the recon orders complete and observe from distance
-- If no threats encountered, continue to objective
-- Mark orders complete once at objective

local constants = require("constants")
local dispositionTypes = constants.dispositionTypes
local Doctrine = require("doctrine")
local SpatialAgent = require("spatial-agent")
local ReconDoctrine= {}
setmetatable(ReconDoctrine, {__index = Doctrine})
ReconDoctrine.__index = ReconDoctrine

-- Factory method for creating new GamePlan instances
function ReconDoctrine.new(commanderName)
    local self = Doctrine.new("Recon", commanderName)
    setmetatable(self, ReconDoctrine)

    self.observedThreatCenter = nil

    self:registerPhase("Advance", ReconDoctrine.advancePhase)
    self:registerPhase("Observe", ReconDoctrine.observePhase)

    return self
end

function ReconDoctrine:considerAdvance(context)
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames

    local advanceAssessment = 0.0

    if threat.count == 0 then
        advanceAssessment = 1.0
    end

    return advanceAssessment
end

function ReconDoctrine:considerObserve(context)
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames

    local observeAssessment = 0.0

    if threat.count > 0 then
        observeAssessment = 1.0
    end

    return observeAssessment
end

function ReconDoctrine:advancePhase(context)
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames

    local ownPosition = commander:getOwnPosition()
    local objectiveDestination = commander.orders.position

    local observeThreshold = 1.0
    
    if commander.orders.status == constants.orderStatus.ASSIGNED then
        commander.orders:start()
    end


    if self:considerObserve(context) >= observeThreshold then
        self:changePhase("Observe")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil
        }
    end

    local distanceToDestination = SpatialAgent.distance2D(ownPosition, objectiveDestination)
    local closeEnough = 500
    if distanceToDestination <= closeEnough then
        commander.orders:complete()
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil
        }
    end

    return {
        disposition = dispositionTypes.ADVANCE,
        destination = commander.orders.position
    }
end

function ReconDoctrine:observePhase(context)
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames

    local advanceThreshold = 1.0

    if self:considerAdvance(context) >= advanceThreshold then
        self:changePhase("Advance")
        return {
            diposition = dispositionTypes.HOLD,
            destination = nil
        }
    end

    commander.orders:complete()

    return {
        diposition = dispositionTypes.HOLD,
        destination = nil
    } 
end

return ReconDoctrine
