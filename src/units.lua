-- Per-unit-type data: armor, speed, and weapon loadout.
-- Source of truth is data/unit-data.csv, gathered by tools/unit-data-dump.lua
-- and hand-verified. Regenerate from that CSV rather than hand-editing out of
-- sync. Table keys are exact DCS typeName strings - do not rename them, they
-- must match what DCS/mist expect when spawning (see src/constants.lua's
-- groundTemplates/garrisonTemplates, which reference these same strings).
--
-- armorClass: ordinal tier judged by feel, not real armor thickness -
--   0 = unarmored (infantry, soft-skinned trucks/cars)
--   1 = light (APC/SAM/AAA/artillery chassis)
--   2 = medium (IFV)
--   3 = heavy (MBT)
-- Matches the vs-tier effectiveness columns in weapons.lua.
--
-- speedMax: meters/second, from DCS's own Unit:getDesc().speedMax. Treat this
-- as a fast-lookup approximation - prefer a live getDesc() call when a real
-- Unit reference is available (see GroupCommander:getSlowestUnitSpeed).
--
-- weapons: list of weapon_id keys into weapons.lua. Empty list = unarmed -
-- confirmed by hand for Hummer/Tigr_233036 despite DCS tagging both
-- "Armed vehicles" (see data/unit-data.csv for DCS's own tags, kept there
-- for reference only - they've been found unreliable, e.g. those two).
--
-- Kamaz 43101 and Avenger are intentionally omitted: DCS could not resolve
-- either type name during data collection (silently substituted Leopard-2 -
-- see tools/unit-data-dump.lua's usage notes) and their dumped stats are
-- garbage. Add them back once verified via the Mission Editor.

local units = {
    ["Soldier M4"] = {
        dcsRole = "Infantry",
        armorClass = 0,
        life = 1.04,
        speedMax = 4.00,
        weapons = {"M4_5_56mm_Carbine"},
    },
    ["Soldier M249"] = {
        dcsRole = "Infantry",
        armorClass = 0,
        life = 1.04,
        speedMax = 4.00,
        weapons = {"M249_5_56mm_SAW"},
    },
    ["Infantry AK"] = {
        dcsRole = "Infantry",
        armorClass = 0,
        life = 1.04,
        speedMax = 4.00,
        weapons = {"AK74_5_45mm_Rifle"},
    },
    ["Paratrooper RPG-16"] = {
        dcsRole = "Infantry",
        armorClass = 0,
        life = 1.04,
        speedMax = 4.00,
        weapons = {"RPG_16"},
    },
    ["Hummer"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 2.5,
        speedMax = 31.39,
        weapons = {}, -- confirmed unarmed despite DCS "Armed vehicles" tag
    },
    ["GAZ-66"] = {
        dcsRole = "Truck",
        armorClass = 0,
        life = 2,
        speedMax = 20.83,
        weapons = {},
    },
    ["UAZ-469"] = {
        dcsRole = "Car",
        armorClass = 0,
        life = 1.8,
        speedMax = 27.78,
        weapons = {},
    },
    ["M 818"] = {
        dcsRole = "Truck",
        armorClass = 0,
        life = 2,
        speedMax = 20.83,
        weapons = {},
    },
    ["KAMAZ Truck"] = {
        dcsRole = "Truck",
        armorClass = 0,
        life = 2,
        speedMax = 20.83,
        weapons = {},
    },
    ["Ural-375"] = {
        dcsRole = "Truck",
        armorClass = 0,
        life = 2,
        speedMax = 20.83,
        weapons = {},
    },
    ["Ural-4320-31"] = {
        dcsRole = "Truck",
        armorClass = 0,
        life = 3,
        speedMax = 20.83,
        weapons = {},
    },
    ["Ural-4320T"] = {
        dcsRole = "Truck",
        armorClass = 0,
        life = 2,
        speedMax = 20.83,
        weapons = {},
    },
    ["M1043 HMMWV Armament"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 2.5,
        speedMax = 31.39,
        weapons = {"M2_50cal_MG"},
    },
    ["M1045 HMMWV TOW"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 2.5,
        speedMax = 31.39,
        weapons = {"TOW_ATGM"},
    },
    ["BRDM-2"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 3,
        speedMax = 27.78,
        weapons = {"KPVT_14_5mm_MG", "PKT_7_62mm_MG"},
    },
    ["Tigr_233036"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 2.5,
        speedMax = 40.00,
        weapons = {}, -- confirmed unarmed despite DCS "Armed vehicles" tag
    },
    ["M-113"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 3,
        speedMax = 16.67,
        weapons = {"M2_50cal_MG"},
    },
    ["BMD-1"] = {
        dcsRole = "IFV",
        armorClass = 2,
        life = 3,
        speedMax = 16.95,
        weapons = {"73mm_Smooth_Bore", "PKT_7_62mm_MG", "AT_3B_Sagger_B"},
    },
    ["M-2 Bradley"] = {
        dcsRole = "IFV",
        armorClass = 2,
        life = 6,
        speedMax = 18.33,
        weapons = {"M242_25mm_Cannon", "TOW_ATGM", "M240C_7_62mm_MG"},
    },
    ["BMP-2"] = {
        dcsRole = "IFV",
        armorClass = 2,
        life = 5,
        speedMax = 18.33,
        weapons = {"2A42_30mm_Cannon", "PKT_7_62mm_MG", "AT_5_Konkurs_ATGM"},
    },
    ["BMP-3"] = {
        dcsRole = "IFV",
        armorClass = 2,
        life = 5,
        speedMax = 19.44,
        weapons = {"2A70_100mm_Cannon", "2A72_30mm_Cannon", "PKT_7_62mm_MG", "AT10_9M117_ATGM"},
    },
    ["BTR-60"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 3,
        speedMax = 22.00,
        weapons = {"KPVT_14_5mm_MG", "PKT_7_62mm_MG"},
    },
    ["BTR-80"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 3,
        speedMax = 25.00,
        weapons = {"KPVT_14_5mm_MG", "PKT_7_62mm_MG"},
    },
    ["M-1 Abrams"] = {
        dcsRole = "Tank",
        armorClass = 3,
        life = 32,
        speedMax = 18.53,
        weapons = {"M256_120mm_Cannon", "M2_50cal_MG", "M240C_7_62mm_MG"},
    },
    ["T-72B"] = {
        dcsRole = "Tank",
        armorClass = 3,
        life = 25,
        speedMax = 16.67,
        weapons = {"2A46M_125mm_Cannon", "NSVT_12_7mm_MG", "PKT_7_62mm_MG"},
    },
    ["T-80U"] = {
        dcsRole = "Tank",
        armorClass = 3,
        life = 28,
        speedMax = 19.44,
        weapons = {"2A46M_125mm_Cannon", "NSVT_12_7mm_MG", "PKT_7_62mm_MG"},
    },
    ["Vulcan"] = {
        dcsRole = "AAA",
        armorClass = 1,
        life = 3,
        speedMax = 16.67,
        weapons = {"Vulcan_20mm"},
    },
    ["Strela-10M3"] = {
        dcsRole = "SAM",
        armorClass = 1,
        life = 3,
        speedMax = 16.67,
        weapons = {"SA_13_9M333_IR_SAM"},
    },
    ["Strela-1 9P31"] = {
        dcsRole = "SAM",
        armorClass = 1,
        life = 3,
        speedMax = 27.78,
        weapons = {"SA_9B_9M31M_IR_SAM"},
    },
    ["M-109"] = {
        dcsRole = "Artillery",
        armorClass = 1,
        life = 3,
        speedMax = 15.64,
        weapons = {"M185_155mm_Howitzer"},
    },
    ["2S9 Nona"] = {
        dcsRole = "Artillery",
        armorClass = 1,
        life = 4,
        speedMax = 16.67,
        weapons = {"2A60_120mm_Mortar"},
    },
}

return units
