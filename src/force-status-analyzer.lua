-- ForceStatusAnalyzer: Stateless utilities for assessing group and unit status
--
-- This module provides pure functions for analyzing force status, health, ammo,
-- and combat effectiveness. All functions are stateless and can be used by any
-- commander that needs to assess group capabilities.
--
-- Design: Follows the ThreatAnalyzer pattern - stateless utilities that accept
-- DCS Groups, group names, or unit tables and return analysis results.

local ForceStatusAnalyzer = {}

-- ============================================================================
-- Status Report Generation
-- ============================================================================

--- Get a detailed status report for a group
-- @param groupNameOrGroup string|Group - Group name or Group instance
-- @param initialUnitNames table - List of initial unit names for comparison
-- @param fuelRemaining number - Current fuel level (for simulated fuel tracking)
-- @return table Status report with alive count, ammo, health metrics
function ForceStatusAnalyzer.getStatusReport(groupNameOrGroup, initialUnitNames, fuelRemaining)
    local group = groupNameOrGroup
    if type(groupNameOrGroup) == "string" then
        group = Group.getByName(groupNameOrGroup)
    end
    
    if not group or not group:isExist() then
        return {
            aliveCount = 0,
            ammoCount = 0,
            ammmoLowState = nil,
            fuelRemaining = fuelRemaining or 0,
            healthPool = 0,
            healthLowState = nil,
        }
    end

    local totalCount = initialUnitNames and #initialUnitNames or 0
    if totalCount == 0 then
        return {
            aliveCount = 0,
            ammoCount = 0,
            ammmoLowState = nil,
            fuelRemaining = fuelRemaining or 0,
            healthPool = 0,
            healthLowState = nil,
        }
    end
    
    local aliveCount = 0
    local ammoCount = 0
    local ammmoLowState = nil
    local healthPool = 0
    local healthLowState = nil
    
    for _, unitName in ipairs(initialUnitNames) do
        local unit = Unit.getByName(unitName)
        if unit and unit:isExist() then
            local unitAmmoTable = unit:getAmmo()
            local unitHealth = unit:getLife()
            
            -- Sum up all ammo counts from the table
            local unitAmmoTotal = 0
            if unitAmmoTable then
                for _, ammoEntry in ipairs(unitAmmoTable) do
                    if ammoEntry.count then
                        unitAmmoTotal = unitAmmoTotal + ammoEntry.count
                    end
                end
            end

            aliveCount = aliveCount + 1
            ammoCount = ammoCount + unitAmmoTotal
            healthPool = healthPool + unitHealth

            if not ammmoLowState or unitAmmoTotal < ammmoLowState then
                ammmoLowState = unitAmmoTotal
            end

            if not healthLowState or unitHealth < healthLowState then
                healthLowState = unitHealth
            end
        end
    end
    
    return {
        aliveCount = aliveCount,
        ammoCount = ammoCount,
        ammmoLowState = ammmoLowState,
        fuelRemaining = fuelRemaining or 0,
        healthPool = healthPool,
        healthLowState = healthLowState,
    }
end

--- Get collective status (percentage of units alive)
-- @param aliveCount number - Number of currently alive units
-- @param initialCount number - Initial number of units
-- @return number - Percentage alive (0.0 to 1.0), or 0 if initialCount is 0
function ForceStatusAnalyzer.calculateCollectiveStatus(aliveCount, initialCount)
    if not initialCount or initialCount == 0 then
        return 0
    end
    
    return (aliveCount or 0) / initialCount
end

--- Get collective status from a status report
-- @param statusReport table - Status report from getStatusReport()
-- @param initialCount number - Initial number of units
-- @return number - Percentage alive (0.0 to 1.0)
function ForceStatusAnalyzer.getCollectiveStatusFromReport(statusReport, initialCount)
    return ForceStatusAnalyzer.calculateCollectiveStatus(statusReport.aliveCount, initialCount)
end

-- ============================================================================
-- Ammo Analysis
-- ============================================================================

--- Calculate ammo percentage remaining
-- @param currentAmmo number - Current total ammo count
-- @param baselineAmmo number - Initial/baseline ammo count
-- @return number - Percentage remaining (0-100), or nil if baselineAmmo is 0
function ForceStatusAnalyzer.calculateAmmoPercentage(currentAmmo, baselineAmmo)
    if not baselineAmmo or baselineAmmo == 0 then
        return nil
    end
    
    return (currentAmmo / baselineAmmo) * 100
end

--- Check if ammo is below a threshold percentage
-- @param currentAmmo number - Current total ammo count
-- @param baselineAmmo number - Initial/baseline ammo count
-- @param thresholdPercent number - Threshold percentage (0-100), default 20%
-- @return boolean - True if ammo is below threshold
function ForceStatusAnalyzer.isAmmoLow(currentAmmo, baselineAmmo, thresholdPercent)
    local threshold = thresholdPercent or 20
    local percentage = ForceStatusAnalyzer.calculateAmmoPercentage(currentAmmo, baselineAmmo)
    
    if not percentage then
        return false
    end
    
    return percentage < threshold
end

--- Check if ammo is critically low
-- @param currentAmmo number - Current total ammo count
-- @param baselineAmmo number - Initial/baseline ammo count
-- @param thresholdPercent number - Threshold percentage (0-100), default 5%
-- @return boolean - True if ammo is critically low
function ForceStatusAnalyzer.isAmmoCritical(currentAmmo, baselineAmmo, thresholdPercent)
    local threshold = thresholdPercent or 5
    local percentage = ForceStatusAnalyzer.calculateAmmoPercentage(currentAmmo, baselineAmmo)
    
    if not percentage then
        return false
    end
    
    return percentage < threshold
end

--- Check if ammo is below an absolute threshold
-- @param currentAmmo number - Current total ammo count
-- @param baselineAmmo number - Initial/baseline ammo count
-- @param thresholdPercent number - Threshold as decimal (0.0-1.0), e.g., 0.2 for 20%
-- @return boolean - True if below threshold
function ForceStatusAnalyzer.isAmmoBelowThreshold(currentAmmo, baselineAmmo, thresholdPercent)
    if not baselineAmmo or baselineAmmo == 0 then
        return false
    end
    
    local thresholdAmount = baselineAmmo * thresholdPercent
    return currentAmmo < thresholdAmount
end

-- ============================================================================
-- Attrition Analysis
-- ============================================================================

--- Calculate attrition rate
-- @param aliveCount number - Number of currently alive units
-- @param initialCount number - Initial number of units
-- @return number - Attrition rate (0.0 to 1.0), where 0 = no losses, 1 = total loss
function ForceStatusAnalyzer.calculateAttritionRate(aliveCount, initialCount)
    if not initialCount or initialCount == 0 then
        return 0
    end
    
    return 1 - (aliveCount / initialCount)
end

--- Check if attrition has reached a significant threshold
-- @param aliveCount number - Number of currently alive units
-- @param initialCount number - Initial number of units
-- @param thresholdPercent number - Threshold as decimal (0.0-1.0), default 0.5 (50% losses)
-- @return boolean - True if attrition exceeds threshold
function ForceStatusAnalyzer.hasSignificantAttrition(aliveCount, initialCount, thresholdPercent)
    local threshold = thresholdPercent or 0.5
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(aliveCount, initialCount)
    
    return attritionRate >= threshold
end

-- ============================================================================
-- Health Analysis
-- ============================================================================

--- Calculate average health per unit
-- @param healthPool number - Total health of all units
-- @param aliveCount number - Number of alive units
-- @return number - Average health per unit, or 0 if no units alive
function ForceStatusAnalyzer.calculateAverageHealth(healthPool, aliveCount)
    if not aliveCount or aliveCount == 0 then
        return 0
    end
    
    return healthPool / aliveCount
end

--- Check if the lowest unit health is below a threshold
-- @param lowestHealth number - Health of the weakest unit
-- @param threshold number - Health threshold
-- @return boolean - True if lowest health is below threshold
function ForceStatusAnalyzer.hasWeakUnit(lowestHealth, threshold)
    if not lowestHealth then
        return false
    end
    
    return lowestHealth < threshold
end

-- ============================================================================
-- Unit Counting Utilities
-- ============================================================================

--- Count alive units in a group
-- @param groupNameOrGroup string|Group - Group name or Group instance
-- @return number - Number of alive units
function ForceStatusAnalyzer.countAliveUnits(groupNameOrGroup)
    local group = groupNameOrGroup
    if type(groupNameOrGroup) == "string" then
        group = Group.getByName(groupNameOrGroup)
    end
    
    if not group or not group:isExist() then
        return 0
    end
    
    local units = group:getUnits()
    local count = 0
    
    for _, unit in ipairs(units) do
        if unit and unit:isExist() then
            count = count + 1
        end
    end
    
    return count
end

--- Get all alive units from a group
-- @param groupNameOrGroup string|Group - Group name or Group instance
-- @return table - Array of Unit instances
function ForceStatusAnalyzer.getAliveUnits(groupNameOrGroup)
    local group = groupNameOrGroup
    if type(groupNameOrGroup) == "string" then
        group = Group.getByName(groupNameOrGroup)
    end
    
    if not group or not group:isExist() then
        return {}
    end
    
    local units = group:getUnits()
    local aliveUnits = {}
    
    for _, unit in ipairs(units) do
        if unit and unit:isExist() then
            table.insert(aliveUnits, unit)
        end
    end
    
    return aliveUnits
end

-- ============================================================================
-- Comparative Analysis
-- ============================================================================

--- Compare current status against baseline and return a summary
-- @param currentStatus table - Current status report from getStatusReport()
-- @param baselineAmmo number - Initial ammo count
-- @param initialCount number - Initial unit count
-- @return table - Analysis with percentages and flags
function ForceStatusAnalyzer.compareToBaseline(currentStatus, baselineAmmo, initialCount)
    local analysis = {
        aliveCount = currentStatus.aliveCount,
        collectiveStatus = ForceStatusAnalyzer.calculateCollectiveStatus(currentStatus.aliveCount, initialCount),
        attritionRate = ForceStatusAnalyzer.calculateAttritionRate(currentStatus.aliveCount, initialCount),
        ammoPercent = ForceStatusAnalyzer.calculateAmmoPercentage(currentStatus.ammoCount, baselineAmmo),
        averageHealth = ForceStatusAnalyzer.calculateAverageHealth(currentStatus.healthPool, currentStatus.aliveCount),
        
        -- Flags
        isAmmoLow = ForceStatusAnalyzer.isAmmoLow(currentStatus.ammoCount, baselineAmmo, 20),
        isAmmoCritical = ForceStatusAnalyzer.isAmmoCritical(currentStatus.ammoCount, baselineAmmo, 5),
        hasHighAttrition = ForceStatusAnalyzer.hasSignificantAttrition(currentStatus.aliveCount, initialCount, 0.5),
        hasCriticalAttrition = ForceStatusAnalyzer.hasSignificantAttrition(currentStatus.aliveCount, initialCount, 0.75),
    }
    
    return analysis
end

return ForceStatusAnalyzer
