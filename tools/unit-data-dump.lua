-- Unit Data Dump Tool
--
-- One-off diagnostic script for collecting per-unit-type stats directly from DCS
-- rather than guessing them: spawns a single instance of every unit type listed
-- below, reads back DCS's own Unit:getDesc() data (max speed, life/hitpoints,
-- category, and DCS's built-in "attributes" tag set - e.g. "Tanks", "IFV", "SAM")
-- plus Unit:getAmmo() (DCS's real ammo/weapon type identifiers), logs CSV lines
-- per unit to the DCS log, then despawns it.
--
-- This is standalone (no `require`s) and is NOT part of the bundled mission -
-- it doesn't go through ./build. Run it directly.
--
-- USAGE:
-- 1. In the Mission Editor, open (or create) a test mission that already loads
--    mist (this script calls mist.dynAdd, same as ControlZones does).
-- 2. Add a trigger: ONCE -> DO SCRIPT FILE -> tools/unit-data-dump.lua
--    (must run AFTER the trigger that loads mist).
-- 3. Run the mission. It dumps everything in a single frame, then you can exit.
-- 4. Open the DCS log (normally
--    %USERPROFILE%\Saved Games\DCS\Logs\dcs.log, or DCS.openbeta\Logs\dcs.log)
--    and pull out every line starting with "UNITDATA," or "AMMODATA,". Paste
--    each set under its header row into a CSV file.
-- 5. Fill in the trailing empty "weapons" and "armor_class" columns of
--    UNITDATA rows by hand - armor_class is your own judgment call (see the
--    plan notes: 0=unarmored, 1=light, 2=medium, 3=heavy as a starting point).
--
-- On AMMODATA: DCS reports ammo per round/munition TYPE, not per weapon
-- SYSTEM - a single gun (e.g. a 125mm cannon) will usually show up as two or
-- three separate ammo entries (AP rounds, HEAT rounds, etc.), each with its
-- own DCS type name, and there's no field linking an ammo entry back to "the
-- weapon it belongs to." Use the entry's displayName/typeName (which usually
-- embeds the caliber/gun designation) plus your knowledge of the unit's
-- loadout to decide whether to fold multiple entries under one weapon_id or
-- track them separately.

local unitList = {
    -- {typeName, country} - country is only a best-effort guess to make the
    -- unit spawnable; it does not affect the stats being dumped. If a type
    -- fails to spawn, fix the country here and re-run just that entry.
    {"Soldier M4", "USA"},
    {"Soldier M249", "USA"},
    {"Infantry AK", "Russia"},
    {"Paratrooper RPG-16", "Russia"},
    {"Hummer", "USA"},
    {"GAZ-66", "Russia"},
    {"UAZ-469", "Russia"},
    {"M 818", "USA"},
    {"KAMAZ Truck", "Russia"},
    {"Kamaz 43101", "Russia"},
    {"Ural-375", "Russia"},
    {"Ural-4320-31", "Russia"},
    {"Ural-4320T", "Russia"},
    {"M1043 HMMWV Armament", "USA"},
    {"M1045 HMMWV TOW", "USA"},
    {"BRDM-2", "Russia"},
    {"Tigr_233036", "Russia"},
    {"M-113", "USA"},
    {"BMD-1", "Russia"},
    {"M-2 Bradley", "USA"},
    {"BMP-2", "Russia"},
    {"BMP-3", "Russia"},
    {"BTR-60", "Russia"},
    {"BTR-80", "Russia"},
    {"M-1 Abrams", "USA"},
    {"T-72B", "Russia"},
    {"T-80U", "Russia"},
    {"Avenger", "USA"},
    {"Vulcan", "USA"},
    {"Strela-10M3", "Russia"},
    {"Strela-1 9P31", "Russia"},
    {"M-109", "USA"},
    {"2S9 Nona", "Russia"},
    {"SAU Msta", "Russia"},
    -- Add new candidate unit types here as you scope in fire support / CAS / SAM
    -- units - e.g. {"MLRS", "USA"}, {"Ural-375 Att", "Russia"}, etc.
}

-- Known-good in-map point (reused from src/sandbox.lua's BlueDefendPosition).
local origin = coord.LLtoLO(
    46 + 29 / 60 + 18 / 3600,
    38 + 08 / 60 + 05 / 3600
)

local function dumpAttributes(attributes)
    if not attributes then return "" end
    local names = {}
    for name, isSet in pairs(attributes) do
        if isSet then table.insert(names, name) end
    end
    table.sort(names)
    return table.concat(names, ";")
end

-- Weapon.Category: 0=SHELL, 1=MISSILE, 2=ROCKET, 3=BOMB
local function dumpAmmo(typeName, unit)
    local ammo = unit:getAmmo()
    if not ammo or #ammo == 0 then
        env.info("AMMODATA," .. typeName .. ",NONE,,,,")
        return
    end

    for _, entry in ipairs(ammo) do
        local desc = entry.desc or {}
        env.info(string.format(
            "AMMODATA,%s,%s,%s,%s,%s",
            typeName, tostring(entry.count or 0), tostring(desc.typeName or ""),
            tostring(desc.displayName or ""), tostring(desc.category or "")
        ))
    end
end

env.info("UNITDATA,type,category,life,speed_ms,speed_kmh,attributes,weapons,armor_class")
env.info("AMMODATA,type,count,dcs_type_name,dcs_display_name,dcs_category")

for i, entry in ipairs(unitList) do
    local typeName, country = entry[1], entry[2]
    local groupName = "DUMP_" .. i .. "_" .. typeName:gsub("[^%w]", "_")
    -- Vec2 ground-plane coordinates (x, y), same convention as ControlZones:spawnGroupAtPoint.
    -- Spread units out along a line so they don't spawn on top of each other.
    local spawnPoint = {x = origin.x + (i * 200), y = origin.z}

    local ok, err = pcall(function()
        mist.dynAdd({
            groupName = groupName,
            units = {{type = typeName, x = spawnPoint.x, y = spawnPoint.y, heading = 0}},
            country = country,
            category = "vehicle",
        })

        local group = Group.getByName(groupName)
        local unit = group and group:getUnit(1)
        if not unit or not unit:isExist() then
            error("failed to spawn or find unit")
        end

        local desc = unit:getDesc()
        local speedMs = desc.speedMax or 0
        local speedKmh = speedMs * 3.6
        local attrs = dumpAttributes(desc.attributes)

        env.info(string.format(
            "UNITDATA,%s,%s,%s,%.2f,%.1f,%s,,",
            typeName, tostring(desc.category), tostring(desc.life or ""), speedMs, speedKmh, attrs
        ))

        dumpAmmo(typeName, unit)

        group:destroy()
    end)

    if not ok then
        env.info("UNITDATA_ERROR," .. typeName .. "," .. tostring(err))
    end
end

env.info("UNITDATA_DONE")
