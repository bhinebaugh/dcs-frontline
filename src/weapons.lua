-- Weapon database: per-weapon range and effectiveness.
-- Source of truth is data/weapons-template.csv (filled in from the DCS
-- Encyclopedia and, for SAM/AAA engagement ranges, Mission Editor range rings).
-- Regenerate this file from that CSV rather than hand-editing it out of sync.
--
-- range / minRange: meters. minRange is the dead zone (e.g. ATGM minimum
-- arming distance, indirect fire minimum elevation) - 0 where none applies.
--
-- effectiveness: unitless 0-10 scale, calibrated relative to other weapons
-- rather than derived from any real penetration/ballistics data.
--   unarmored / light / medium / heavy - vs the armorClass tiers in units.lua
--   air                                - vs aircraft/helicopters (SAM/AAA/MANPAD)

local weapons = {
    ["M4_5_56mm_Carbine"] = {
        displayName = "M4 5.56mm Carbine",
        kind = "small-arms",
        range = 500,
        minRange = 0,
        effectiveness = {unarmored = 3, light = 2, medium = 0, heavy = 0, air = 1},
    },
    ["M249_5_56mm_SAW"] = {
        displayName = "M249 5.56mm SAW",
        kind = "mg",
        range = 700,
        minRange = 0,
        effectiveness = {unarmored = 6, light = 4, medium = 1, heavy = 0, air = 2},
    },
    ["AK74_5_45mm_Rifle"] = {
        displayName = "AK74 5.45mm Rifle",
        kind = "small-arms",
        range = 500,
        minRange = 0,
        effectiveness = {unarmored = 4, light = 2, medium = 0, heavy = 0, air = 1},
    },
    ["Vulcan_20mm"] = {
        displayName = "Vulcan 20mm Cannon",
        kind = "autocannon",
        range = 2000,
        minRange = 500,
        effectiveness = {unarmored = 2, light = 2, medium = 0, heavy = 0, air = 7},
    },
    ["M2_50cal_MG"] = {
        displayName = "M2 .50 cal MG",
        kind = "mg",
        range = 1200,
        minRange = 0,
        effectiveness = {unarmored = 8, light = 10, medium = 6, heavy = 3, air = 3},
    },
    ["TOW_ATGM"] = {
        displayName = "TOW ATGM",
        kind = "atgm",
        range = 3800,
        minRange = 65,
        effectiveness = {unarmored = 5, light = 7, medium = 8, heavy = 9, air = 1},
    },
    ["KPVT_14_5mm_MG"] = {
        displayName = "KPVT 14.5mm MG",
        kind = "mg",
        range = 1600,
        minRange = 0,
        effectiveness = {unarmored = 9, light = 8, medium = 6, heavy = 3, air = 5},
    },
    ["PKT_7_62mm_MG"] = {
        displayName = "PKT 7.62mm MG",
        kind = "mg",
        range = 1600,
        minRange = 0,
        effectiveness = {unarmored = 7, light = 6, medium = 4, heavy = 0, air = 1},
    },
    ["M185_155mm_Howitzer"] = {
        displayName = "M185 155mm Howitzer",
        kind = "indirect",
        range = 22000,
        minRange = 200,
        effectiveness = {unarmored = 8, light = 8, medium = 5, heavy = 2, air = 0},
    },
    ["2A60_120mm_Mortar"] = {
        displayName = "2A60 120mm Mortar",
        kind = "indirect",
        range = 7000,
        minRange = 0,
        effectiveness = {unarmored = 8, light = 7, medium = 4, heavy = 2, air = 0},
    },
    ["73mm_Smooth_Bore"] = {
        displayName = "73mm Smooth Bore",
        kind = "cannon",
        range = 3000,
        minRange = 400,
        effectiveness = {unarmored = 6, light = 8, medium = 8, heavy = 6, air = 2},
    },
    ["AT_3B_Sagger_B"] = {
        displayName = "9M14M Sagger B ATGM",
        kind = "atgm",
        range = 4000,
        minRange = 0,
        effectiveness = {unarmored = 5, light = 7, medium = 8, heavy = 9, air = 0},
    },
    ["M242_25mm_Cannon"] = {
        displayName = "M242 25mm Cannon",
        kind = "autocannon",
        range = 2500,
        minRange = 500,
        effectiveness = {unarmored = 5, light = 8, medium = 7, heavy = 6, air = 4},
    },
    ["M240C_7_62mm_MG"] = {
        displayName = "M240C 7.62mm MG",
        kind = "mg",
        range = 1200,
        minRange = 0,
        effectiveness = {unarmored = 7, light = 6, medium = 4, heavy = 0, air = 1},
    },
    ["2A42_30mm_Cannon"] = {
        displayName = "2A42 30mm Cannon",
        kind = "autocannon",
        range = 2500,
        minRange = 400,
        effectiveness = {unarmored = 6, light = 9, medium = 8, heavy = 7, air = 5},
    },
    ["AT_5_Konkurs_ATGM"] = {
        displayName = "AT-5 Konkurs ATGM",
        kind = "atgm",
        range = 3000,
        minRange = 100,
        effectiveness = {unarmored = 5, light = 7, medium = 8, heavy = 9, air = 1},
    },
    ["2A70_100mm_Cannon"] = {
        displayName = "2A70 100mm Cannon",
        kind = "cannon",
        range = 2500,
        minRange = 400,
        effectiveness = {unarmored = 4, light = 8, medium = 9, heavy = 9, air = 0},
    },
    ["2A72_30mm_Cannon"] = {
        displayName = "2A72 30mm Cannon",
        kind = "autocannon",
        range = 2500,
        minRange = 1000,
        effectiveness = {unarmored = 6, light = 9, medium = 8, heavy = 7, air = 5},
    },
    ["AT10_9M117_ATGM"] = {
        displayName = "AT10 9M117 ATGM",
        kind = "atgm",
        range = 4000,
        minRange = 400,
        effectiveness = {unarmored = 5, light = 7, medium = 8, heavy = 9, air = 1},
    },
    ["RPG_16"] = {
        displayName = "RPG-16",
        kind = "rocket",
        range = 500,
        minRange = 100,
        effectiveness = {unarmored = 5, light = 10, medium = 9, heavy = 7, air = 1},
    },
    ["SA_13_9M333_IR_SAM"] = {
        displayName = "SA13 9M333 IR SAM",
        kind = "sam",
        range = 5000,
        minRange = 800,
        effectiveness = {unarmored = 2, light = 0, medium = 0, heavy = 0, air = 8},
    },
    ["SA_9B_9M31M_IR_SAM"] = {
        displayName = "SA9 9M31M IR SAM",
        kind = "sam",
        range = 4200,
        minRange = 800,
        effectiveness = {unarmored = 2, light = 0, medium = 0, heavy = 0, air = 9},
    },
    ["M256_120mm_Cannon"] = {
        displayName = "M256 120mm Cannon",
        kind = "cannon",
        range = 4000,
        minRange = 400,
        effectiveness = {unarmored = 5, light = 8, medium = 9, heavy = 10, air = 0},
    },
    ["2A46M_125mm_Cannon"] = {
        displayName = "2A46M 125mm Cannon",
        kind = "cannon",
        range = 3500,
        minRange = 400,
        effectiveness = {unarmored = 5, light = 8, medium = 9, heavy = 10, air = 0},
    },
    ["NSVT_12_7mm_MG"] = {
        displayName = "NSVT 12.7mm MG",
        kind = "mg",
        range = 1600,
        minRange = 0,
        effectiveness = {unarmored = 8, light = 10, medium = 6, heavy = 3, air = 5},
    },
}

return weapons
