-- GroupProfiler: Unified force analysis and status profiling
-- Consolidates ThreatAnalyzer and ForceStatusAnalyzer into a single interface.
-- Returns GroupProfile tables with capability, composition, unit count, and status.
--
-- Derives per-unit combat profiles from src/units.lua (armor class + weapon
-- loadout) and src/weapons.lua (per-weapon range/effectiveness), rather than
-- a single hand-tuned threat number per unit type.
--
-- GroupProfile schema:
-- {
--     offensiveCapability = { vsUnarmored=N, vsLight=N, vsMedium=N, vsHeavy=N, vsAir=N },
--     composition         = { unarmored=N, light=N, medium=N, heavy=N, air=N },
--     range               = { unarmored=N, light=N, medium=N, heavy=N, air=N },
--     unitCount           = N,
--     -- Status fields (only from profileGroup, nil from profileUnits):
--     attritionRate       = 0.0-1.0,
--     ammoRatio           = 0.0-1.0,
--     fuelRatio           = 0.0-1.0,
-- }
--
-- composition/offensiveCapability/range tiers mirror the armorClass scale in
-- units.lua (0=unarmored, 1=light, 2=medium, 3=heavy), plus "air" for future
-- airborne (CAS/helicopter) units - no unit is classified into that tier yet,
-- so it stays zero until air units are added to units.lua.
--
-- range[tier] is how far out this force can engage a target of that tier,
-- in meters - the range of whichever weapon provides that tier's
-- offensiveCapability (see computeCombatProfile). It answers "how far out
-- can we reach this kind of target", not "how far can any of our weapons
-- fire" - a tier this force has zero effectiveness against reports range 0,
-- even if some weapon's max range is nonzero, since that weapon isn't what's
-- winning that tier. See engagement-analyzer.lua for two-sided (distance-
-- aware) comparisons built on top of this - GroupProfiler itself stays
-- single-sided ("what does this force have").

local units = require("units")
local weapons = require("weapons")

local GroupProfiler = {}

local armorClassNames = {[0] = "unarmored", [1] = "light", [2] = "medium", [3] = "heavy"}
local capabilityTiers = {"unarmored", "light", "medium", "heavy", "air"}
GroupProfiler.capabilityTiers = capabilityTiers

-- ============================================================================
-- UNIT CLASSIFICATION
-- ============================================================================

-- Combine a unit type's weapon loadout into a single per-tier combat profile.
-- Weapons on one unit are alternatives (it fires whichever suits the target),
-- not simultaneous - so each tier takes the best (max) effectiveness among
-- the unit's own weapons, and range is paired with whichever weapon won that
-- tier (not independently maxed - a unit doesn't get its coax's range with
-- its main gun's effectiveness). Contrast with profileUnits, which sums
-- these per-unit effectiveness profiles across a group (firepower adds up)
-- but takes the max of their ranges (reach doesn't add up - the longest-
-- reaching unit sets the group's engagement envelope for that tier).
local function computeCombatProfile(weaponIds)
    local effectiveness = {unarmored = 0, light = 0, medium = 0, heavy = 0, air = 0}
    local range = {unarmored = 0, light = 0, medium = 0, heavy = 0, air = 0}
    for _, weaponId in ipairs(weaponIds or {}) do
        local weapon = weapons[weaponId]
        if weapon then
            for _, tier in ipairs(capabilityTiers) do
                local value = weapon.effectiveness[tier] or 0
                if value > effectiveness[tier] then
                    effectiveness[tier] = value
                    range[tier] = weapon.range or 0
                end
            end
        end
    end
    return effectiveness, range
end

function GroupProfiler.classifyUnit(unit)
    local empty = {unarmored = 0, light = 0, medium = 0, heavy = 0, air = 0}

    if not unit or not unit:isExist() then
        return {armorClass = 0, effectiveness = empty, range = empty}
    end

    local typeName = unit:getTypeName()
    local unitData = typeName and units[typeName]
    if not unitData then
        env.info("WARNING: GroupProfiler - Unknown unit type '" .. tostring(typeName) .. "' - using default classification")
        return {
            armorClass = 0,
            effectiveness = {unarmored = 1, light = 1, medium = 0, heavy = 0, air = 1},
            range = {unarmored = 500, light = 500, medium = 0, heavy = 0, air = 500},
        }
    end

    local effectiveness, range = computeCombatProfile(unitData.weapons)
    return {
        armorClass    = unitData.armorClass,
        effectiveness = effectiveness,
        range         = range,
    }
end

-- ============================================================================
-- UNIT COLLECTION HELPERS
-- ============================================================================

function GroupProfiler.getUnitsFromGroups(groups)
    local unitList = {}

    local groupList = {}
    if type(groups) == "table" and groups.getUnits then
        groupList = {groups}
    else
        groupList = groups
    end

    for _, group in ipairs(groupList) do
        if group and group:isExist() then
            local groupUnits = group:getUnits()
            for _, unit in ipairs(groupUnits) do
                if unit and unit:isExist() then
                    table.insert(unitList, unit)
                end
            end
        end
    end

    return unitList
end

function GroupProfiler.getUnitsFromGroupNames(groupNames)
    local groups = {}
    for _, groupName in ipairs(groupNames) do
        local group = Group.getByName(groupName)
        if group and group:isExist() then
            table.insert(groups, group)
        end
    end
    return GroupProfiler.getUnitsFromGroups(groups)
end

-- ============================================================================
-- PROFILE CONSTRUCTION
-- ============================================================================

-- Build a capability/composition profile from a list of unit references.
-- Status fields (attritionRate, ammoRatio, fuelRatio) are NOT set.
function GroupProfiler.profileUnits(unitList)
    local profile = {
        offensiveCapability = {vsUnarmored = 0, vsLight = 0, vsMedium = 0, vsHeavy = 0, vsAir = 0},
        composition         = {unarmored = 0, light = 0, medium = 0, heavy = 0, air = 0},
        range               = {unarmored = 0, light = 0, medium = 0, heavy = 0, air = 0},
        unitCount           = 0,
    }

    if not unitList or #unitList == 0 then
        return profile
    end

    for _, unit in ipairs(unitList) do
        if unit and unit:isExist() then
            local classification = GroupProfiler.classifyUnit(unit)
            local effectiveness = classification.effectiveness

            profile.unitCount = profile.unitCount + 1

            local tierName = armorClassNames[classification.armorClass] or "unarmored"
            profile.composition[tierName] = profile.composition[tierName] + 1

            profile.offensiveCapability.vsUnarmored = profile.offensiveCapability.vsUnarmored + effectiveness.unarmored
            profile.offensiveCapability.vsLight      = profile.offensiveCapability.vsLight      + effectiveness.light
            profile.offensiveCapability.vsMedium     = profile.offensiveCapability.vsMedium     + effectiveness.medium
            profile.offensiveCapability.vsHeavy      = profile.offensiveCapability.vsHeavy      + effectiveness.heavy
            profile.offensiveCapability.vsAir        = profile.offensiveCapability.vsAir        + effectiveness.air

            for _, tier in ipairs(capabilityTiers) do
                local unitRange = classification.range[tier] or 0
                if unitRange > profile.range[tier] then
                    profile.range[tier] = unitRange
                end
            end
        end
    end

    return profile
end

-- Build a full profile for a named DCS group, including status ratios.
function GroupProfiler.profileGroup(groupName, initialUnitNames, initialAmmoCount, fuelRemaining)
    local zeroed = {
        offensiveCapability = {vsUnarmored = 0, vsLight = 0, vsMedium = 0, vsHeavy = 0, vsAir = 0},
        composition         = {unarmored = 0, light = 0, medium = 0, heavy = 0, air = 0},
        range               = {unarmored = 0, light = 0, medium = 0, heavy = 0, air = 0},
        unitCount           = 0,
        attritionRate       = 1,
        ammoRatio           = 0,
        fuelRatio           = 0,
    }

    local group = Group.getByName(groupName)
    if not group or not group:isExist() then
        return zeroed
    end

    -- Collect alive units
    local aliveUnits = {}
    for _, unit in ipairs(group:getUnits()) do
        if unit and unit:isExist() then
            table.insert(aliveUnits, unit)
        end
    end

    local profile = GroupProfiler.profileUnits(aliveUnits)

    -- Attrition rate
    local initialCount = (initialUnitNames and #initialUnitNames) or 0
    if initialCount == 0 then
        profile.attritionRate = 0
    else
        profile.attritionRate = 1 - (profile.unitCount / initialCount)
    end

    -- Ammo ratio
    if not initialAmmoCount or initialAmmoCount == 0 then
        profile.ammoRatio = 1.0  -- unarmed units are always considered "full"
    else
        local currentAmmo = 0
        for _, unit in ipairs(aliveUnits) do
            local ammoTable = unit:getAmmo()
            if ammoTable then
                for _, entry in ipairs(ammoTable) do
                    if entry.count then
                        currentAmmo = currentAmmo + entry.count
                    end
                end
            end
        end
        profile.ammoRatio = currentAmmo / initialAmmoCount
    end

    -- Fuel (simulated, passed in directly)
    profile.fuelRatio = fuelRemaining or 0

    return profile
end

-- ============================================================================
-- FORCE COMPARISON
-- ============================================================================

-- Returns how favorable our position is against the threat.
-- Higher = better for us. math.huge = no opposition.
--
-- Weights each capability tier by the FRACTION of the opposing force in
-- that tier (comp[tier] / totalCount), not raw count. This keeps the result
-- sensitive to force size - a force twice as large has twice the summed
-- capability, and that difference survives into the ratio - without
-- double-counting the opponent's headcount a second time via the composition
-- weighting (dividing out totalCount normalizes away raw size, leaving only
-- the composition's shape). It also preserves a genuine nuance: a powerful
-- capability against a tier that's only a small slice of the opposing force
-- (e.g. 1 heavy tank among 8 mostly-light vehicles) counts for less than the
-- same capability against a force made up mostly of that tier.
function GroupProfiler.calculateFavorability(ownProfile, threatProfile)
    local function power(cap, comp, totalCount)
        if totalCount == 0 then return 0 end
        local function fraction(count) return count / totalCount end
        return cap.vsUnarmored * fraction(comp.unarmored)
             + cap.vsLight     * fraction(comp.light)
             + cap.vsMedium    * fraction(comp.medium)
             + cap.vsHeavy     * fraction(comp.heavy)
             + cap.vsAir       * fraction(comp.air)
    end

    local ourPower   = power(ownProfile.offensiveCapability, threatProfile.composition, threatProfile.unitCount)
    local theirPower = power(threatProfile.offensiveCapability, ownProfile.composition, ownProfile.unitCount)

    if ourPower == 0 and theirPower == 0 then return 0 end
    if theirPower == 0 and ourPower > 0 then return math.huge end
    return ourPower / theirPower
end

return GroupProfiler
