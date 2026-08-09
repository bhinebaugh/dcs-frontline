-- ReconRallyAssaultPlan: Classic three-phase offensive strategy
-- Phase 1 (Recon):   Scout ahead to identify threats
-- Phase 2 (Rally):   Stage forces at standoff distance for coordinated attack
-- Phase 3 (Assault): Execute synchronized assault on objective
-- Phase 4 (Defend):  Hold objective once secured
--
-- Returns { orders = { ... }, objectiveComplete = true/nil }.
-- OperationalCommander handles commander selection and order assignment.

local constants = require("constants")
local Doctrine = require("doctrine")
local SpatialAgent = require("spatial-agent")

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
    local statusCounts = context.statusCounts

    -- Wait for any active orders to resolve
    if statusCounts.assigned > 0 or statusCounts.inProgress > 0 then
        return {}
    end

    -- Phase delta: only count orders issued since this phase started
    local totalThisPhase     = statusCounts.total     - self.phaseBaseline.total
    local completedThisPhase = statusCounts.completed - self.phaseBaseline.completed
    local abortedThisPhase   = statusCounts.aborted   - self.phaseBaseline.aborted

    -- Recon orders resolved — check if objective itself is already clear
    if totalThisPhase > 0 and (completedThisPhase + abortedThisPhase) >= totalThisPhase then
        if context.nearObjectiveThreatCount == 0 then
            self:changePhase("Defend", statusCounts)
        else
            self:changePhase("Rally", statusCounts)
        end
        return {}
    end

    -- No orders issued yet this phase — dispatch recon
    if totalThisPhase == 0 then
        return {
            orders = {
                {
                    type     = taskTypes.RECON,
                    position = context.objectivePosition,
                    radius   = self.config.reconRadius,
                    alr      = alr.LOW,
                    count    = self.config.maxReconGroups,
                    missionProfile = {
                        offensiveCapability = { vsUnarmored = 0, vsLight = 0, vsMedium = 0, vsHeavy = 0, vsAir = 0 },
                        attritionRate = 0.0,
                        ammoRatio     = 0.2,
                    },
                }
            }
        }
    end

    return {}
end

function ReconRallyAssaultPlan:rallyPhase(context)
    local statusCounts  = context.statusCounts
    local threatProfile = context.threatProfile
    local threatCenter  = context.threatCenter

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

    if context.availableCommanderCount == 0 then
        return {}
    end

    -- Issue rally order template
    if totalThisPhase == 0 then
        return {
            orders = {
                {
                    type            = taskTypes.RALLY,
                    targetPosition  = threatCenter,
                    proximity       = 500,
                    stagingArc      = 120,
                    stagingRadius   = self.config.assaultStagingDistance,
                    alr             = alr.MEDIUM,
                    count           = 3,
                    missionProfile  = {
                        attritionRate = 0.0,
                        ammoRatio     = 0.8,
                    },
                }
            }
        }
    end

    return {}
end

function ReconRallyAssaultPlan:assaultPhase(context)
    local objectiveRadius = context.objectiveRadius
    local statusCounts  = context.statusCounts
    local threatProfile = context.threatProfile
    local threatCenter  = context.threatCenter

    -- Wait for active orders
    if statusCounts.assigned > 0 or statusCounts.inProgress > 0 then
        return {}
    end

    local totalThisPhase     = statusCounts.total     - self.phaseBaseline.total
    local completedThisPhase = statusCounts.completed - self.phaseBaseline.completed
    local abortedThisPhase   = statusCounts.aborted   - self.phaseBaseline.aborted

    -- Assault orders resolved
    if totalThisPhase > 0 and (completedThisPhase + abortedThisPhase) >= totalThisPhase then
        self:changePhase("Recon", statusCounts)
        return {}
    end

    if totalThisPhase == 0 then
        -- Stay focused on assaulting a position rather than units spotted on the group's periphery
        -- local assaultPosition = threatCenter or context.objectivePosition
        local assaultPosition = context.objectivePosition

        -- Build missionProfile from threat capability (need to match or exceed it)
        local missionProfile = {
            attritionRate = 0.0,
            ammoRatio     = 0.9,
        }
        if threatProfile and threatProfile.unitCount > 0 then
            missionProfile.offensiveCapability = {
                vsUnarmored = threatProfile.offensiveCapability.vsUnarmored,
                vsLight     = threatProfile.offensiveCapability.vsLight,
                vsMedium    = threatProfile.offensiveCapability.vsMedium,
                vsHeavy     = threatProfile.offensiveCapability.vsHeavy,
                vsAir       = threatProfile.offensiveCapability.vsAir,
            }
        end

        return {
            orders = {
                {
                    type           = taskTypes.ASSAULT,
                    position       = assaultPosition,
                    proximity      = objectiveRadius or self.config.assaultRadius,
                    alr            = alr.HIGH,
                    count          = context.availableCommanderCount,
                    deadline       = context.objectiveDeadline or (timer.getTime() + 1800),
                    missionProfile = missionProfile,
                }
            }
        }
    end

    return {}
end

function ReconRallyAssaultPlan:defendPhase(context)
    local threatCenter = context.threatCenter

    -- Bias defend position toward objective, acknowledging threats
    local defendPosition = context.objectivePosition
    if threatCenter then
        defendPosition = {
            x = (context.objectivePosition.x + threatCenter.x) / 2,
            z = (context.objectivePosition.z + threatCenter.z) / 2,
        }
    end

    return {
        objectiveComplete = true,
        orders = {
            {
                type           = taskTypes.DEFEND,
                position       = defendPosition,
                radius         = context.objectiveRadius,
                alr            = alr.MEDIUM,
                count          = context.availableCommanderCount,
                missionProfile = {
                    attritionRate = 0.0,
                    ammoRatio     = 0.5,
                },
            }
        }
    }
end

return ReconRallyAssaultPlan
