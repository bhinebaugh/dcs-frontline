-- ReconRallyAssaultPlan: Classic three-phase offensive strategy
-- Phase 1 (Recon):   Scout ahead to identify threats
-- Phase 2 (Rally):   Stage forces at standoff distance for coordinated attack
-- Phase 3 (Assault): Execute synchronized assault on objective
-- Phase 4 (Defend):  Hold objective once secured
--
-- Returns order templates (plain data). OperationalCommander handles
-- commander selection and order assignment.

local constants = require("constants")
local Doctrine = require("doctrine")

local orderStatus = constants.orderStatus
local taskTypes = constants.taskTypes
local alr = constants.acceptableLevelsOfRisk

local ReconRallyAssaultPlan = {}
setmetatable(ReconRallyAssaultPlan, {__index = Doctrine})
ReconRallyAssaultPlan.__index = ReconRallyAssaultPlan

function ReconRallyAssaultPlan.new(commanderName, config)
    local self = Doctrine.new("ReconRallyAssault", commanderName)
    setmetatable(self, ReconRallyAssaultPlan)

    self.config = {
        maxReconGroups         = (config and config.maxReconGroups)         or 1,
        reconRadius            = (config and config.reconRadius)            or 8000,
        assaultRadius          = (config and config.assaultRadius)          or 3000,
        assaultStagingDistance = (config and config.assaultStagingDistance) or 10000,
    }

    self:registerPhase("Recon",   ReconRallyAssaultPlan.reconPhase)
    self:registerPhase("Rally",   ReconRallyAssaultPlan.rallyPhase)
    self:registerPhase("Assault", ReconRallyAssaultPlan.assaultPhase)
    self:registerPhase("Defend",  ReconRallyAssaultPlan.defendPhase)

    return self
end

function ReconRallyAssaultPlan:reconPhase(context)
    local objective    = context.goal
    local situation    = context.situation
    local statusCounts = situation.statusCounts

    -- Wait for any active orders to resolve
    if statusCounts.assigned > 0 or statusCounts.inProgress > 0 then
        return {}
    end

    -- Phase delta: only count orders issued since this phase started
    local totalThisPhase     = statusCounts.total     - self.phaseBaseline.total
    local completedThisPhase = statusCounts.completed - self.phaseBaseline.completed
    local abortedThisPhase   = statusCounts.aborted   - self.phaseBaseline.aborted

    -- Advance to Rally when recon orders are resolved
    if totalThisPhase > 0 and (completedThisPhase + abortedThisPhase) >= totalThisPhase then
        self:changePhase("Rally", statusCounts)
        return {}
    end

    -- No orders issued yet this phase — dispatch recon
    if totalThisPhase == 0 then
        return {
            {
                type     = taskTypes.RECON,
                position = objective.position,
                radius   = self.config.reconRadius,
                alr      = alr.LOW,
                count    = self.config.maxReconGroups,
                missionProfile = {
                    offensiveCapability = { vsInfantry = 0, vsArmor = 0, vsAir = 0 },
                    attritionRate = 0.0,
                    ammoRatio     = 0.2,
                },
            }
        }
    end

    return {}
end

function ReconRallyAssaultPlan:rallyPhase(context)
    local objective     = context.goal
    local situation     = context.situation
    local statusCounts  = situation.statusCounts
    local threatProfile = situation.threatProfile
    local threatCenter  = situation.threatCenter

    -- Wait for active orders
    if statusCounts.assigned > 0 or statusCounts.inProgress > 0 then
        return {}
    end

    local totalThisPhase     = statusCounts.total     - self.phaseBaseline.total
    local completedThisPhase = statusCounts.completed - self.phaseBaseline.completed
    local abortedThisPhase   = statusCounts.aborted   - self.phaseBaseline.aborted

    -- Advance to Assault when rally orders resolve
    if totalThisPhase > 0 and (completedThisPhase + abortedThisPhase) >= totalThisPhase then
        self:changePhase("Assault", statusCounts)
        return {}
    end

    -- No threats to rally against — skip straight to Assault
    if not threatProfile or threatProfile.unitCount == 0 or not threatCenter then
        self:changePhase("Assault", statusCounts)
        return {}
    end

    if situation.availableCommanderCount == 0 then
        return {}
    end

    -- Issue rally order template
    if totalThisPhase == 0 then
        return {
            {
                type            = taskTypes.RALLY,
                targetPosition  = threatCenter,
                stagingDistance = self.config.assaultStagingDistance,
                stagingArc      = 120,
                radius          = 5000,
                alr             = alr.MEDIUM,
                count           = 3,
                missionProfile  = {
                    attritionRate = 0.0,
                    ammoRatio     = 0.8,
                },
            }
        }
    end

    return {}
end

function ReconRallyAssaultPlan:assaultPhase(context)
    local objective     = context.goal
    local situation     = context.situation
    local statusCounts  = situation.statusCounts
    local threatProfile = situation.threatProfile
    local threatCenter  = situation.threatCenter

    -- Wait for active orders
    if statusCounts.assigned > 0 or statusCounts.inProgress > 0 then
        return {}
    end

    local totalThisPhase     = statusCounts.total     - self.phaseBaseline.total
    local completedThisPhase = statusCounts.completed - self.phaseBaseline.completed
    local abortedThisPhase   = statusCounts.aborted   - self.phaseBaseline.aborted

    -- Advance to Defend when assault orders resolve
    if totalThisPhase > 0 and (completedThisPhase + abortedThisPhase) >= totalThisPhase then
        self:changePhase("Defend", statusCounts)
        return {}
    end

    if totalThisPhase == 0 then
        local assaultPosition = threatCenter or objective.position

        -- Build missionProfile from threat capability (need to match or exceed it)
        local missionProfile = {
            attritionRate = 0.0,
            ammoRatio     = 0.9,
        }
        if threatProfile and threatProfile.unitCount > 0 then
            missionProfile.offensiveCapability = {
                vsInfantry = threatProfile.offensiveCapability.vsInfantry,
                vsArmor    = threatProfile.offensiveCapability.vsArmor,
                vsAir      = threatProfile.offensiveCapability.vsAir,
            }
        end

        return {
            {
                type           = taskTypes.ASSAULT,
                position       = assaultPosition,
                radius         = self.config.assaultRadius,
                alr            = alr.HIGH,
                count          = situation.availableCommanderCount,
                deadline       = objective.deadline or (timer.getTime() + 1800),
                missionProfile = missionProfile,
            }
        }
    end

    return {}
end

function ReconRallyAssaultPlan:defendPhase(context)
    local objective    = context.goal
    local situation    = context.situation
    local threatCenter = situation.threatCenter

    objective:markAchieved()

    -- Bias defend position toward objective, acknowledging threats
    local defendPosition = objective.position
    if threatCenter then
        defendPosition = {
            x = (objective.position.x + threatCenter.x) / 2,
            z = (objective.position.z + threatCenter.z) / 2,
        }
    end

    return {
        {
            type           = taskTypes.DEFEND,
            position       = defendPosition,
            radius         = objective.radius or 2000,
            alr            = alr.MEDIUM,
            count          = situation.availableCommanderCount,
            missionProfile = {
                attritionRate = 0.0,
                ammoRatio     = 0.5,
            },
        }
    }
end

return ReconRallyAssaultPlan
