-- UnitRecovery: capacity accounting and DCS spawn/despawn utilities for the
-- repair/resupply system, owned by StrategicCommander but exercised mostly
-- by RepairResupplyPlan (src/doctrines/operational/repair-resupply-plan.lua),
-- which owns the actual phase/timing state machine for a given distressed
-- unit + convoy pairing. This module deliberately holds no session state of its
-- own - just the ReservePool ledger and stateless-except-for-that spawn/
-- despawn mechanics, callable from wherever needs them (StrategicCommander
-- dispatches the initial convoy; the doctrine calls back in for the
-- respawn/despawn that happen once resupply resolves).

local constants = require("constants")
local GroupCommander = require("group-commander")
local ReservePool = require("reserve-pool")

local UnitRecovery = {}
UnitRecovery.__index = UnitRecovery

local function convoyKey(color)
    return color .. ":convoy"
end

local function unitKey(color, unitType)
    return color .. ":" .. unitType
end

-- Flat per-unit-type headroom for the first-pass fixed budget - capacity
-- assumed to exist beyond whatever's already spawned at kickoff, since
-- kickoff() doesn't hold anything back (see ReservePool's header on why
-- checkOut needs genuine headroom, not just recycled slots, to ever
-- succeed for a destroyed unit's replacement). Enumerates every unit type
-- that appears in this color's ground and fire-support templates so any
-- of them can be respawned, not just whichever ones happen to be on the
-- map when this is called.
local DEFAULT_UNIT_HEADROOM = 6
local DEFAULT_CONVOY_CAPACITY = 2

function UnitRecovery.defaultBudgets(color)
    local budgets = {}
    local seen = {}
    local function addTemplateSet(templates)
        for _, template in ipairs(templates or {}) do
            for _, unitType in ipairs(template) do
                local key = unitKey(color, unitType)
                if not seen[key] then
                    seen[key] = true
                    budgets[key] = DEFAULT_UNIT_HEADROOM
                end
            end
        end
    end
    addTemplateSet(constants.groundTemplates[color])
    addTemplateSet(constants.fireSupportTemplates[color])
    budgets[convoyKey(color)] = DEFAULT_CONVOY_CAPACITY
    return budgets
end

function UnitRecovery.new(config)
    local self = setmetatable({}, UnitRecovery)
    self.color = config.color
    self.map = config.map -- ControlZones instance
    self.pool = ReservePool.new(config.budgets or UnitRecovery.defaultBudgets(config.color))
    return self
end

function UnitRecovery:hasConvoyCapacity()
    return self.pool:hasCapacity(convoyKey(self.color))
end

-- Spawns a resupply convoy at homeZone and checks out its capacity slot.
-- Returns the new group's name, or nil if no capacity remains.
function UnitRecovery:spawnConvoy(homeZone)
    if not self:hasConvoyCapacity() then
        return nil
    end
    self.pool:checkOut(convoyKey(self.color))

    local templates = constants.resupplyTemplates[self.color]
    local template = templates[math.random(#templates)]
    local heading = self.map:orientToClosestEnemy(homeZone)
    local groupName = self.color .. "-convoy-" .. self.map:getNewGroupId()
    self.map:spawnGroupInZone(groupName, homeZone, self.color, template, heading)
    return groupName
end

-- Destroys a convoy's DCS group and returns its capacity slot.
function UnitRecovery:despawnConvoy(groupName)
    local group = Group.getByName(groupName)
    if group and group:isExist() then
        group:destroy()
    end
    self.pool:checkIn(convoyKey(self.color))
end

-- Despawns a distressed unit's remnant and spawns a fresh full-strength
-- instance of its original template (distressedGc.templateTypes) at
-- `atZone`. See reserve-pool.lua's header for the checkIn/checkOut
-- accounting this performs: surviving units' slots are checked in and
-- immediately re-checked-out (net zero), while slots for destroyed
-- companions are genuine depletions of headroom that was never spawned in
-- the first place. Returns the new group's name, or nil if no capacity
-- remained even for the survivors' own slots (shouldn't normally happen).
function UnitRecovery:respawnGroup(distressedGc, atZone)
    local color = self.color

    for _, unit in ipairs(distressedGc:getOwnUnits()) do
        self.pool:checkIn(unitKey(color, unit:getTypeName()))
    end

    local group = Group.getByName(distressedGc.groupName)
    if group and group:isExist() then
        group:destroy()
    end

    local grantedTypes = {}
    for _, unitType in ipairs(distressedGc.templateTypes) do
        if self.pool:checkOut(unitKey(color, unitType)) then
            table.insert(grantedTypes, unitType)
        end
    end

    if #grantedTypes == 0 then
        env.info(string.format("*** %s UnitRecovery: %s destroyed, no capacity remained to respawn it",
            color, distressedGc.groupName))
        return nil
    end

    local heading = self.map:orientToClosestEnemy(atZone)
    local freshGroupName = color .. "-repaired-" .. self.map:getNewGroupId()
    self.map:spawnGroupInZone(freshGroupName, atZone, color, grantedTypes, heading)

    env.info(string.format("*** %s UnitRecovery: %s respawned fresh as %s (%d/%d original units granted)",
        color, distressedGc.groupName, freshGroupName, #grantedTypes, #distressedGc.templateTypes))
    return freshGroupName
end

-- Convenience wrapper: wraps a raw spawned group name in a GroupCommander,
-- the same construction StrategicCommander:addReserves uses.
function UnitRecovery:wrapGroupCommander(groupName)
    return GroupCommander.new(groupName, {
        color = self.color,
        map   = self.map.map,
    })
end

return UnitRecovery
