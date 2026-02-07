local constants = require("constants")
local unitClassification = constants.unitClassification

-- ThreatAnalyzer provides coalition-agnostic force analysis
-- Can analyze any arbitrary collection of DCS units and compare opposing forces
-- 
-- The threat matrix works bidirectionally:
-- - Unit's threats.armor = offensive capability against armor
-- - Enemy's threats.infantry = my vulnerability to that enemy (if I'm infantry)

local ThreatAnalyzer = {}

-- ============================================================================
-- UNIT COLLECTION HELPERS
-- ============================================================================

-- Get unit references from a MIST unit table (array of unit names)
function ThreatAnalyzer.getUnitsFromMistTable(unitNames)
    local units = {}
    for _, unitName in ipairs(unitNames) do
        local unit = Unit.getByName(unitName)
        if unit and unit:isExist() then
            table.insert(units, unit)
        end
    end
    return units
end

-- Get unit references from one or more DCS group references
function ThreatAnalyzer.getUnitsFromGroups(groups)
    local units = {}
    
    -- Handle single group or array of groups
    local groupList = {}
    if type(groups) == "table" and groups.getUnits then
        -- Single group object
        groupList = {groups}
    else
        -- Array of group objects
        groupList = groups
    end
    
    for _, group in ipairs(groupList) do
        if group and group:isExist() then
            local groupUnits = group:getUnits()
            for _, unit in ipairs(groupUnits) do
                if unit and unit:isExist() then
                    table.insert(units, unit)
                end
            end
        end
    end
    
    return units
end

-- Get unit references from group names
function ThreatAnalyzer.getUnitsFromGroupNames(groupNames)
    local groups = {}
    for _, groupName in ipairs(groupNames) do
        local group = Group.getByName(groupName)
        if group and group:isExist() then
            table.insert(groups, group)
        end
    end
    return ThreatAnalyzer.getUnitsFromGroups(groups)
end

-- ============================================================================
-- UNIT CLASSIFICATION
-- ============================================================================

function ThreatAnalyzer.classifyUnit(unit)
    if not unit or not unit:isExist() then
        return {category = "infantry", threats = {infantry = 0, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 0}}
    end
    
    local typeName = unit:getTypeName()
    if not typeName then
        return {category = "infantry", threats = {infantry = 0, ["light-armor"] = 0, ["heavy-armor"] = 0, support = 0}}
    end
    
    local classification = unitClassification[typeName]
    if classification then
        return classification
    end
    
    -- Log unknown unit types to help with configuration
    env.info("WARNING: ThreatAnalyzer - Unknown unit type '" .. typeName .. "' - using default classification")
    
    -- Default classification for unknown units (assume infantry-like)
    return {category = "infantry", threats = {infantry = 1, ["light-armor"] = 1, ["heavy-armor"] = 0, support = 1}}
end

-- ============================================================================
-- FORCE ANALYSIS
-- ============================================================================

-- Analyze a collection of units and return comprehensive force assessment
function ThreatAnalyzer.analyzeUnits(units)
    local analysis = {
        count = 0,
        composition = {
            infantry = 0,
            ["light-armor"] = 0,
            ["heavy-armor"] = 0,
            support = 0
        },
        offensiveCapability = {
            vsInfantry = 0,
            vsArmor = 0,
            vsAir = 0
        }
    }
    
    if not units or #units == 0 then
        return analysis
    end
    
    for _, unit in ipairs(units) do
        if unit and unit:isExist() then
            local classification = ThreatAnalyzer.classifyUnit(unit)
            
            -- Count units by category
            analysis.count = analysis.count + 1
            if classification.category == "infantry" then
                analysis.composition.infantry = analysis.composition.infantry + 1
            elseif classification.category == "light-armor" then
                analysis.composition["light-armor"] = analysis.composition["light-armor"] + 1
            elseif classification.category == "heavy-armor" then
                analysis.composition["heavy-armor"] = analysis.composition["heavy-armor"] + 1
            elseif classification.category == "support" then
                analysis.composition.support = analysis.composition.support + 1
            end
            
            -- Accumulate offensive capabilities
            analysis.offensiveCapability.vsInfantry = analysis.offensiveCapability.vsInfantry + classification.threats.infantry
            -- vsArmor combines threats to both light and heavy armor
            analysis.offensiveCapability.vsArmor = analysis.offensiveCapability.vsArmor + 
                                                    classification.threats["light-armor"] + 
                                                    classification.threats["heavy-armor"]
            analysis.offensiveCapability.vsAir = analysis.offensiveCapability.vsAir + classification.threats.support
        end
    end
    
    return analysis
end

-- Calculate combat power of a force against an enemy
-- Returns how much damage this force can inflict on the enemy based on actual unit counts
function ThreatAnalyzer.calculateCombatPower(forceAnalysis, enemyAnalysis)
    if forceAnalysis.count == 0 or enemyAnalysis.count == 0 then
        return 0
    end
    
    -- Calculate damage we can do to each enemy unit type (capability * enemy count)
    local damageToInfantry = forceAnalysis.offensiveCapability.vsInfantry * enemyAnalysis.composition.infantry
    local damageToArmor = forceAnalysis.offensiveCapability.vsArmor * 
                          (enemyAnalysis.composition["light-armor"] + enemyAnalysis.composition["heavy-armor"])
    local damageToSupport = forceAnalysis.offensiveCapability.vsAir * enemyAnalysis.composition.support
    
    local totalPower = damageToInfantry + damageToArmor + damageToSupport
    
    return totalPower
end

-- ============================================================================
-- FORCE COMPARISON
-- ============================================================================

-- Compare two opposing forces and return favorability assessment
-- Returns positive values when friendly force is favored, negative when enemy is favored
function ThreatAnalyzer.compareForces(friendlyUnits, enemyUnits)
    local friendlyAnalysis = ThreatAnalyzer.analyzeUnits(friendlyUnits)
    local enemyAnalysis = ThreatAnalyzer.analyzeUnits(enemyUnits)
    
    -- Handle edge cases
    if friendlyAnalysis.count == 0 and enemyAnalysis.count == 0 then
        return {
            favorability = 0,
            friendly = friendlyAnalysis,
            enemy = enemyAnalysis,
            friendlyVulnerability = {overall = 0, fromInfantry = 0, fromArmor = 0, fromAir = 0},
            enemyVulnerability = {overall = 0, fromInfantry = 0, fromArmor = 0, fromAir = 0}
        }
    end
    
    if enemyAnalysis.count == 0 then
        return {
            favorability = math.huge,
            friendly = friendlyAnalysis,
            enemy = enemyAnalysis,
            friendlyVulnerability = {overall = 0, fromInfantry = 0, fromArmor = 0, fromAir = 0},
            enemyVulnerability = {overall = 0, fromInfantry = 0, fromArmor = 0, fromAir = 0}
        }
    end
    
    if friendlyAnalysis.count == 0 then
        return {
            favorability = -math.huge,
            friendly = friendlyAnalysis,
            enemy = enemyAnalysis,
            friendlyVulnerability = {overall = 0, fromInfantry = 0, fromArmor = 0, fromAir = 0},
            enemyVulnerability = {overall = 0, fromInfantry = 0, fromArmor = 0, fromAir = 0}
        }
    end
    
    -- Calculate combat power for both sides
    local friendlyPower = ThreatAnalyzer.calculateCombatPower(friendlyAnalysis, enemyAnalysis)
    local enemyPower = ThreatAnalyzer.calculateCombatPower(enemyAnalysis, friendlyAnalysis)
    
    -- Calculate favorability as ratio of our power to their power
    -- Higher = we can hurt them more than they can hurt us
    local favorability = 1.0
    if enemyPower > 0 then
        favorability = friendlyPower / enemyPower
    elseif friendlyPower > 0 then
        favorability = math.huge
    end
    
    return {
        favorability = favorability,
        friendly = friendlyAnalysis,
        enemy = enemyAnalysis,
        friendlyPower = friendlyPower,
        enemyPower = enemyPower
    }
end

return ThreatAnalyzer
