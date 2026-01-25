local constants = require("constants")
local threatStatus = constants.threatStatus

-- Threat tracking helper for managing observed enemy units with timestamps
-- Threats are stored in a table indexed by unit name
-- Each threat has multiple sightings from different observers with timestamps
-- This allows threats to persist and be shared even when temporarily out of sight

local ThreatTracker = {}
ThreatTracker.__index = ThreatTracker

function ThreatTracker.new(observerName)
    local self = setmetatable({}, ThreatTracker)
    self.threats = {}
    self.observerName = observerName  -- Name of the commander using this tracker
    return self
end

-- Update threats with newly observed units
-- observedUnits: array of {name, position} for units with LOS
function ThreatTracker:updateThreats(observedUnits)
    local currentTime = timer.getTime()
    
    -- Update or add observed threats
    for _, unitData in ipairs(observedUnits) do
        local threat = self.threats[unitData.name]
        
        if not threat then
            -- New threat
            env.info(self.observerName .. " ThreatTracker: New threat detected - " .. unitData.name .. " (OBSERVED)")
            self.threats[unitData.name] = {
                name = unitData.name,
                position = unitData.position,
                status = threatStatus.OBSERVED,
                sightings = {
                    {
                        observedBy = self.observerName,
                        observedAt = currentTime,
                        position = unitData.position
                    }
                },
                lastSighting = currentTime
            }
        else
            -- Update existing threat
            local oldStatus = threat.status
            threat.position = unitData.position
            threat.status = threatStatus.OBSERVED  -- Reset to observed if we see it again
            threat.lastSighting = currentTime
            if oldStatus ~= threatStatus.OBSERVED then
                env.info(self.observerName .. " ThreatTracker: " .. unitData.name .. " status changed from " .. oldStatus .. " to OBSERVED")
            end
            
            -- Add new sighting
            table.insert(threat.sightings, {
                observedBy = self.observerName,
                observedAt = currentTime,
                position = unitData.position
            })
        end
    end
end

-- Get the threats table
-- Returns: table indexed by unit name
function ThreatTracker:getThreats()
    return self.threats
end

-- Get a single threat by name
-- Returns: threat data or nil
function ThreatTracker:getThreat(unitName)
    return self.threats[unitName]
end

-- Merge threat intel from external source (e.g., strategic commander)
-- threatIntel: partial threat table with updates to merge
function ThreatTracker:mergeThreatIntel(threatIntel)
    for unitName, incomingThreat in pairs(threatIntel) do
        local existingThreat = self.threats[unitName]
        
        if not existingThreat then
            -- New threat from external intel
            self.threats[unitName] = incomingThreat
        else
            -- Merge with existing threat
            -- Update position if incoming is more recent
            if incomingThreat.lastSighting > existingThreat.lastSighting then
                existingThreat.position = incomingThreat.position
                existingThreat.lastSighting = incomingThreat.lastSighting
            end
            
            -- Update status (prefer more definitive states)
            if incomingThreat.status then
                existingThreat.status = incomingThreat.status
            end
            
            -- Merge sightings
            if incomingThreat.sightings then
                for _, sighting in ipairs(incomingThreat.sightings) do
                    -- Avoid duplicate sightings from same observer at same time
                    local isDuplicate = false
                    for _, existingSighting in ipairs(existingThreat.sightings) do
                        if existingSighting.observedBy == sighting.observedBy and
                           existingSighting.observedAt == sighting.observedAt then
                            isDuplicate = true
                            break
                        end
                    end
                    if not isDuplicate then
                        table.insert(existingThreat.sightings, sighting)
                    end
                end
            end
        end
    end
end

-- Mark a threat with a specific status
-- unitName: name of the threat unit
-- status: threatStatus constant (OBSERVED, SUSPECTED, UNCONFIRMED, LOST, ELIMINATED)
function ThreatTracker:markThreatStatus(unitName, status)
    local threat = self.threats[unitName]
    if threat then
        local oldStatus = threat.status
        threat.status = status
        if oldStatus ~= status then
            threat.statusChangedAt = timer.getTime()
            env.info(self.observerName .. " ThreatTracker: " .. unitName .. " status changed from " .. oldStatus .. " to " .. status)
        end
    end
end

-- Get threats we would expect to see in an area
-- position: {x, y, z} position to check
-- radius: search radius in meters
-- Returns: array of threat names that are in area but not LOST or ELIMINATED
function ThreatTracker:expectedThreats(position, radius)
    local expected = {}
    
    for unitName, threat in pairs(self.threats) do
        if threat.status ~= threatStatus.ELIMINATED and threat.status ~= threatStatus.LOST then
            local dx = threat.position.x - position.x
            local dz = threat.position.z - position.z
            local distance = math.sqrt(dx * dx + dz * dz)
            
            if distance <= radius then
                table.insert(expected, unitName)
            end
        end
    end
    
    return expected
end

-- Count threats in memory
-- Returns: number of threats stored
function ThreatTracker:count()
    local count = 0
    for _ in pairs(self.threats) do
        count = count + 1
    end
    return count
end

-- Age threats and progress their status based on time
-- UNCONFIRMED for >5 minutes → LOST
-- LOST or ELIMINATED for >10 minutes → removed
function ThreatTracker:ageThreats()
    local currentTime = timer.getTime()
    local toRemove = {}
    
    for unitName, threat in pairs(self.threats) do
        -- Track when status was last changed
        if not threat.statusChangedAt then
            threat.statusChangedAt = threat.lastSighting
        end
        
        local timeInStatus = currentTime - threat.statusChangedAt
        
        -- Progress UNCONFIRMED → LOST after 5 minutes
        if threat.status == threatStatus.UNCONFIRMED and timeInStatus > 300 then
            env.info(self.observerName .. " ThreatTracker: " .. unitName .. " status changed from Unconfirmed to Lost (5+ minutes)")
            threat.status = threatStatus.LOST
            threat.statusChangedAt = currentTime
        end
        
        -- Remove LOST or ELIMINATED threats after 10 minutes
        if (threat.status == threatStatus.LOST or threat.status == threatStatus.ELIMINATED) and timeInStatus > 600 then
            env.info(self.observerName .. " ThreatTracker: Removing " .. unitName .. " (" .. threat.status .. " for 10+ minutes)")
            table.insert(toRemove, unitName)
        end
    end
    
    -- Remove threats marked for removal
    for _, unitName in ipairs(toRemove) do
        self.threats[unitName] = nil
    end
end

-- Cull threats that haven't been observed recently (for future use)
-- maxAge: maximum age in seconds (threats older than this will be removed)
function ThreatTracker:cullOldThreats(maxAge)
    local currentTime = timer.getTime()
    local culledThreats = {}
    
    for unitName, threatData in pairs(self.threats) do
        local age = currentTime - threatData.observedAt
        if age <= maxAge then
            culledThreats[unitName] = threatData
        end
    end
    
    self.threats = culledThreats
end

return ThreatTracker
