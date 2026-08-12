-- EngagementAnalyzer: two-sided, distance-aware tactical comparisons.
--
-- GroupProfiler builds single-sided profiles ("what does this force have",
-- including a per-tier engagement range - see its header). This module
-- compares two of them to answer questions that need both sides at once.
--
-- Kept separate from GroupProfiler.calculateFavorability on purpose:
-- favorability is a pure firepower ratio ("who wins if this fight happens
-- right now"), while range advantage is closer to a threshold effect than a
-- smooth multiplier - being outside the enemy's max range means they cannot
-- hurt you yet, not "hurt you slightly less". Blending the two into one
-- score would hide that distinction. Doctrines are expected to combine both
-- as independent weighted inputs instead, the same pattern already used for
-- ammo/attrition/favorability/suitability in considerAbort/considerRetreat.

local GroupProfiler = require("group-profiler")
local capabilityTiers = GroupProfiler.capabilityTiers

local EngagementAnalyzer = {}

-- How far out `profile` can engage a force with the given composition: the
-- farthest range at which `profile` has any effectiveness against a tier
-- actually present in `targetComposition`. This is a best-case distance
-- ("can hit *something* out here"), not a per-tier breakdown - a mixed
-- target composition may only be reachable at this range for one of its
-- tiers, not all of them.
local function reachAgainst(profile, targetComposition)
    local best = 0
    for _, tier in ipairs(capabilityTiers) do
        if (targetComposition[tier] or 0) > 0 then
            local tierRange = profile.range[tier] or 0
            if tierRange > best then
                best = tierRange
            end
        end
    end
    return best
end

-- Signed range gap as a fraction of the longer side, in [-1, 1]. Positive
-- means we have the range advantage. Self-bounding regardless of how
-- extreme the absolute ranges get (e.g. infantry vs. artillery) since it's
-- normalized by the longer reach, not either side's own reach - no separate
-- cap needed. Zero when neither side has any effective reach against the
-- other (nothing to compare).
local function advantageRatio(ourReach, theirReach)
    local longer = math.max(ourReach, theirReach)
    if longer == 0 then return 0 end
    local shorter = math.min(ourReach, theirReach)
    local ratio = (longer - shorter) / longer
    if ourReach < theirReach then
        return -ratio
    end
    return ratio
end

-- Compare two GroupProfiles' engagement envelopes against each other's
-- actual composition (not their full theoretical range table - only tiers
-- the opponent actually has units in count).
--
-- Returns:
--   ourReach        - farthest range at which we can hit something of theirs
--   theirReach       - farthest range at which they can hit something of ours
--   advantage        - ourReach - theirReach, in meters; positive means we
--                       can open the engagement before they can respond
--   advantageRatio   - same comparison, normalized to [-1, 1] - see above.
--                       Meant for doctrines to add as a weighted term
--                       alongside ammo/attrition/favorability/suitability,
--                       not to be blended into favorability itself.
--   standoffDistance - suggested distance to keep from this specific threat:
--                       theirReach if we outrange them (sit just outside
--                       their reach, still inside ours), otherwise ourReach
--                       (closing further than that doesn't help us hit back;
--                       being outranged is what should drive retreat/abort
--                       pressure via advantageRatio, not positioning)
function EngagementAnalyzer.assessRange(ownProfile, threatProfile)
    local ourReach   = reachAgainst(ownProfile, threatProfile.composition)
    local theirReach = reachAgainst(threatProfile, ownProfile.composition)

    local standoffDistance = theirReach
    if theirReach > ourReach then
        standoffDistance = ourReach
    end

    return {
        ourReach         = ourReach,
        theirReach       = theirReach,
        advantage        = ourReach - theirReach,
        advantageRatio   = advantageRatio(ourReach, theirReach),
        standoffDistance = standoffDistance,
    }
end

return EngagementAnalyzer
