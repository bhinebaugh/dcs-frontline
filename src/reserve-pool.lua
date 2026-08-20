-- ReservePool: tracks abstract force capacity per template key, independent
-- of whether units matching that key are currently spawned on the map.
--
-- The interface is deliberately narrow (hasCapacity/checkOut/checkIn) so a
-- future version with dynamic or regenerating capacity (a real
-- reinforcement/production flow) can replace this fixed-ledger
-- implementation without any caller changes. V1 just tracks a fixed count
-- per key, set once at construction - no regeneration, no time dependence.
--
-- Accounting is per-unit, not per-group (see the repair/respawn design it
-- backs): a surviving unit's checkIn is immediately offset by its own
-- group's respawn checkOut (net zero impact), while replacement checkOuts
-- for that group's destroyed companions draw down genuinely separate
-- headroom - the gap between a key's initial budget and however many
-- currently exist on the map, never spawned in the first place. A
-- destroyed unit's own slot is never checked in (nothing returns it), so it
-- stays permanently unavailable - that's the "genuine depletion" half of
-- the design, as opposed to the survivor's net-zero half.
--
-- checkOut can fail (returns false) once a key's headroom is exhausted;
-- callers are responsible for deciding what that means (an understrength
-- respawn, a queued request, or simply nothing) rather than assuming it
-- always succeeds.

local ReservePool = {}
ReservePool.__index = ReservePool

-- budgets: table of {key = totalCapacity}. A key missing from budgets
-- defaults to 0 available (not an error) so callers can query/checkOut a
-- key they never explicitly configured - convenient for keys derived
-- dynamically (e.g. a per-template string) rather than enumerated up front.
function ReservePool.new(budgets)
    local self = setmetatable({}, ReservePool)
    self.available = {}
    for key, total in pairs(budgets or {}) do
        self.available[key] = total
    end
    return self
end

function ReservePool:hasCapacity(key)
    return (self.available[key] or 0) > 0
end

-- Consumes one slot for `key`. Returns true if successful, false if no
-- capacity remains.
function ReservePool:checkOut(key)
    if not self:hasCapacity(key) then
        return false
    end
    self.available[key] = self.available[key] - 1
    return true
end

-- Returns one slot for `key` - e.g. a surviving unit rejoining the pool
-- immediately before its group's respawn checks a slot back out (see
-- header), or a convoy becoming available again after restocking.
function ReservePool:checkIn(key)
    self.available[key] = (self.available[key] or 0) + 1
end

-- Current available capacity for `key`, for logging/visualizer use.
function ReservePool:capacityFor(key)
    return self.available[key] or 0
end

return ReservePool
