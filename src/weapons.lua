-- Weapon (ammo type) database: per-round range and effectiveness.
-- Source of truth is data/weapons-template.csv (filled in from the DCS
-- Encyclopedia, Mission Editor range rings for SAM/AAA, and tools/unit-data-dump.lua's
-- AMMODATA output for real DCS ammo identifiers). Regenerate this file from
-- that CSV rather than hand-editing it out of sync.
--
-- Rows are keyed by ammo type, not weapon system - e.g. a tank's AP and HE
-- main gun rounds are two separate entries, since they can have different
-- effectiveness. Where two different platforms fire the identical DCS ammo
-- type with identical effectiveness, they share one row (e.g. "7_62x54" is
-- used by many PKT-armed vehicles). Where the same ammo performs differently
-- by platform (accuracy/rate of fire), rows are kept distinct and suffixed
-- (e.g. "5_56x45_Carbine" vs "5_56x45_SAW").
--
-- dcsTypeName: the exact DCS ammo type identifier from Unit:getAmmo()'s
-- desc.typeName (e.g. "weapons.shells.2A46M_125_AP") - used to positively
-- match a weapon_id to a live ammo entry at runtime for ammo-aware own-force
-- profiling. A few SAM missiles report a bare id with no dotted path
-- (e.g. "SA9M333") - stored as-is.
--
-- range / minRange: meters. minRange is the dead zone (e.g. ATGM minimum
-- arming distance, indirect fire minimum elevation) - 0 where none applies.
--
-- effectiveness: unitless 0-10 scale, calibrated relative to other weapons
-- rather than derived from any real penetration/ballistics data.
--   unarmored / light / medium / heavy - vs the armorClass tiers in units.lua
--   air                                - vs aircraft/helicopters (SAM/AAA/MANPAD)

local weapons = {
    ["5_56x45_Carbine"] = {
        displayName = "5.56mm (Carbine)",
        kind = "small-arms",
        range = 500,
        minRange = 0,
        effectiveness = {unarmored = 3, light = 2, medium = 0, heavy = 0, air = 1},
        dcsTypeName = "weapons.shells.5_56x45",
    },
    ["5_56x45_NOtr_Carbine"] = {
        displayName = "5.56mm no-tracer (Carbine)",
        kind = "small-arms",
        range = 500,
        minRange = 0,
        effectiveness = {unarmored = 3, light = 2, medium = 0, heavy = 0, air = 1},
        dcsTypeName = "weapons.shells.5_56x45_NOtr",
    },
    ["5_56x45_SAW"] = {
        displayName = "5.56mm (SAW)",
        kind = "mg",
        range = 700,
        minRange = 0,
        effectiveness = {unarmored = 6, light = 4, medium = 1, heavy = 0, air = 2},
        dcsTypeName = "weapons.shells.5_56x45",
    },
    ["5_56x45_NOtr_SAW"] = {
        displayName = "5.56mm no-tracer (SAW)",
        kind = "mg",
        range = 700,
        minRange = 0,
        effectiveness = {unarmored = 6, light = 4, medium = 1, heavy = 0, air = 2},
        dcsTypeName = "weapons.shells.5_56x45_NOtr",
    },
    ["5_45x39"] = {
        displayName = "5.45mm",
        kind = "small-arms",
        range = 500,
        minRange = 0,
        effectiveness = {unarmored = 4, light = 2, medium = 0, heavy = 0, air = 1},
        dcsTypeName = "weapons.shells.5_45x39",
    },
    ["5_45x39_NOtr"] = {
        displayName = "5.45mm no-tracer",
        kind = "small-arms",
        range = 500,
        minRange = 0,
        effectiveness = {unarmored = 4, light = 2, medium = 0, heavy = 0, air = 1},
        dcsTypeName = "weapons.shells.5_45x39_NOtr",
    },
    ["M61_20_AP_gr"] = {
        displayName = "20mm AP",
        kind = "autocannon",
        range = 2000,
        minRange = 500,
        effectiveness = {unarmored = 2, light = 2, medium = 0, heavy = 0, air = 7},
        dcsTypeName = "weapons.shells.M61_20_AP_gr",
    },
    ["M61_20_HE_gr"] = {
        displayName = "20mm HE",
        kind = "autocannon",
        range = 2000,
        minRange = 500,
        effectiveness = {unarmored = 2, light = 2, medium = 0, heavy = 0, air = 7},
        dcsTypeName = "weapons.shells.M61_20_HE_gr",
    },
    ["M2_12_7_T"] = {
        displayName = "12.7mm tracer (M2)",
        kind = "mg",
        range = 1200,
        minRange = 0,
        effectiveness = {unarmored = 8, light = 10, medium = 6, heavy = 3, air = 3},
        dcsTypeName = "weapons.shells.M2_12_7_T",
    },
    ["M2_12_7"] = {
        displayName = "12.7mm (M2)",
        kind = "mg",
        range = 1200,
        minRange = 0,
        effectiveness = {unarmored = 8, light = 10, medium = 6, heavy = 3, air = 3},
        dcsTypeName = "weapons.shells.M2_12_7",
    },
    ["TOW2"] = {
        displayName = "BGM-71 TOW",
        kind = "atgm",
        range = 3800,
        minRange = 65,
        effectiveness = {unarmored = 5, light = 7, medium = 8, heavy = 9, air = 1},
        dcsTypeName = "weapons.missiles.TOW2",
    },
    ["KPVT_14_5_T"] = {
        displayName = "14.5mm AP (KPVT)",
        kind = "mg",
        range = 1600,
        minRange = 0,
        effectiveness = {unarmored = 9, light = 8, medium = 6, heavy = 3, air = 5},
        dcsTypeName = "weapons.shells.KPVT_14_5_T",
    },
    ["KPVT_14_5"] = {
        displayName = "14.5mm (KPVT)",
        kind = "mg",
        range = 1600,
        minRange = 0,
        effectiveness = {unarmored = 9, light = 8, medium = 6, heavy = 3, air = 5},
        dcsTypeName = "weapons.shells.KPVT_14_5",
    },
    ["7_62x54"] = {
        displayName = "7.62mm (PKT)",
        kind = "mg",
        range = 1600,
        minRange = 0,
        effectiveness = {unarmored = 7, light = 6, medium = 4, heavy = 0, air = 1},
        dcsTypeName = "weapons.shells.7_62x54",
    },
    ["7_62x54_NOTRACER"] = {
        displayName = "7.62mm no-tracer (PKT)",
        kind = "mg",
        range = 1600,
        minRange = 0,
        effectiveness = {unarmored = 7, light = 6, medium = 4, heavy = 0, air = 1},
        dcsTypeName = "weapons.shells.7_62x54_NOTRACER",
    },
    ["M185_155"] = {
        displayName = "M795 155mm HE",
        kind = "indirect",
        range = 22000,
        minRange = 200,
        effectiveness = {unarmored = 8, light = 8, medium = 5, heavy = 2, air = 0},
        dcsTypeName = "weapons.shells.M185_155",
    },
    ["2A60_120"] = {
        displayName = "3OF49 120mm HE",
        kind = "indirect",
        range = 7000,
        minRange = 0,
        effectiveness = {unarmored = 8, light = 7, medium = 4, heavy = 2, air = 0},
        dcsTypeName = "weapons.shells.2A60_120",
    },
    ["2A28_73"] = {
        displayName = "PG-15 73mm HEAT",
        kind = "cannon",
        range = 3000,
        minRange = 400,
        effectiveness = {unarmored = 6, light = 8, medium = 8, heavy = 6, air = 2},
        dcsTypeName = "weapons.shells.2A28_73",
    },
    ["MALUTKA"] = {
        displayName = "AT-3 Sagger",
        kind = "atgm",
        range = 4000,
        minRange = 0,
        effectiveness = {unarmored = 5, light = 7, medium = 8, heavy = 9, air = 0},
        dcsTypeName = "weapons.missiles.MALUTKA",
    },
    ["M242_25_HE_M792"] = {
        displayName = "M792 25mm HEI-T",
        kind = "autocannon",
        range = 2500,
        minRange = 500,
        effectiveness = {unarmored = 5, light = 8, medium = 7, heavy = 6, air = 4},
        dcsTypeName = "weapons.shells.M242_25_HE_M792",
    },
    ["M242_25_AP_M791"] = {
        displayName = "M791 25mm APDS-T",
        kind = "autocannon",
        range = 2500,
        minRange = 500,
        effectiveness = {unarmored = 5, light = 8, medium = 7, heavy = 6, air = 4},
        dcsTypeName = "weapons.shells.M242_25_AP_M791",
    },
    ["7_62x51tr"] = {
        displayName = "7.62mm tracer (M240)",
        kind = "mg",
        range = 1200,
        minRange = 0,
        effectiveness = {unarmored = 7, light = 6, medium = 4, heavy = 0, air = 1},
        dcsTypeName = "weapons.shells.7_62x51tr",
    },
    ["7_62x51"] = {
        displayName = "7.62mm (M240)",
        kind = "mg",
        range = 1200,
        minRange = 0,
        effectiveness = {unarmored = 7, light = 6, medium = 4, heavy = 0, air = 1},
        dcsTypeName = "weapons.shells.7_62x51",
    },
    ["2A42_30_HE"] = {
        displayName = "3UOF8 30mm HE-T",
        kind = "autocannon",
        range = 2500,
        minRange = 400,
        effectiveness = {unarmored = 6, light = 9, medium = 8, heavy = 7, air = 5},
        dcsTypeName = "weapons.shells.2A42_30_HE",
    },
    ["2A42_30_AP"] = {
        displayName = "3UBR6 30mm APBC-T",
        kind = "autocannon",
        range = 2500,
        minRange = 400,
        effectiveness = {unarmored = 6, light = 9, medium = 8, heavy = 7, air = 5},
        dcsTypeName = "weapons.shells.2A42_30_AP",
    },
    ["KONKURS"] = {
        displayName = "AT-5 Spandrel",
        kind = "atgm",
        range = 3000,
        minRange = 100,
        effectiveness = {unarmored = 5, light = 7, medium = 8, heavy = 9, air = 1},
        dcsTypeName = "weapons.missiles.KONKURS",
    },
    ["UOF_17_100HE"] = {
        displayName = "3UOF17 100mm HE",
        kind = "cannon",
        range = 2500,
        minRange = 400,
        effectiveness = {unarmored = 4, light = 8, medium = 9, heavy = 9, air = 0},
        dcsTypeName = "weapons.shells.UOF_17_100HE",
    },
    ["P_9M117"] = {
        displayName = "AT-10 Stabber",
        kind = "atgm",
        range = 4000,
        minRange = 400,
        effectiveness = {unarmored = 5, light = 7, medium = 8, heavy = 9, air = 1},
        dcsTypeName = "weapons.missiles.P_9M117",
    },
    ["PG_16V"] = {
        displayName = "PG-16 HEAT",
        kind = "rocket",
        range = 500,
        minRange = 100,
        effectiveness = {unarmored = 5, light = 10, medium = 9, heavy = 7, air = 1},
        dcsTypeName = "weapons.nurs.PG_16V",
    },
    ["SA9M333"] = {
        displayName = "9M333 (SA-13 Gopher)",
        kind = "sam",
        range = 5000,
        minRange = 800,
        effectiveness = {unarmored = 2, light = 0, medium = 0, heavy = 0, air = 8},
        dcsTypeName = "SA9M333",
    },
    ["SA9M31M"] = {
        displayName = "9M31 (SA-9 Gaskin)",
        kind = "sam",
        range = 4200,
        minRange = 800,
        effectiveness = {unarmored = 2, light = 0, medium = 0, heavy = 0, air = 9},
        dcsTypeName = "SA9M31M",
    },
    ["M256_120_AP"] = {
        displayName = "M829A2 120mm APFSDS-T",
        kind = "cannon",
        range = 4000,
        minRange = 400,
        effectiveness = {unarmored = 5, light = 8, medium = 9, heavy = 10, air = 0},
        dcsTypeName = "weapons.shells.M256_120_AP",
    },
    ["M256_120_HE"] = {
        displayName = "M830 120mm HEAT-MP-T",
        kind = "cannon",
        range = 4000,
        minRange = 400,
        effectiveness = {unarmored = 5, light = 8, medium = 9, heavy = 10, air = 0},
        dcsTypeName = "weapons.shells.M256_120_HE",
    },
    ["2A46M_125_AP"] = {
        displayName = "3BM42 125mm APFSDS-T",
        kind = "cannon",
        range = 3500,
        minRange = 400,
        effectiveness = {unarmored = 5, light = 8, medium = 9, heavy = 10, air = 0},
        dcsTypeName = "weapons.shells.2A46M_125_AP",
    },
    ["2A46M_125_HE"] = {
        displayName = "3OF26 125mm HE",
        kind = "cannon",
        range = 3500,
        minRange = 400,
        effectiveness = {unarmored = 5, light = 8, medium = 9, heavy = 10, air = 0},
        dcsTypeName = "weapons.shells.2A46M_125_HE",
    },
    ["Utes_12_7x108_T"] = {
        displayName = "12.7mm tracer (NSVT)",
        kind = "mg",
        range = 1600,
        minRange = 0,
        effectiveness = {unarmored = 8, light = 10, medium = 6, heavy = 3, air = 5},
        dcsTypeName = "weapons.shells.Utes_12_7x108_T",
    },
    ["Utes_12_7x108"] = {
        displayName = "12.7mm (NSVT)",
        kind = "mg",
        range = 1600,
        minRange = 0,
        effectiveness = {unarmored = 8, light = 10, medium = 6, heavy = 3, air = 5},
        dcsTypeName = "weapons.shells.Utes_12_7x108",
    },
    ["SVIR"] = {
        displayName = "9M119 Svir (AT-11 Sniper)",
        kind = "atgm",
        range = 4000,
        minRange = 100,
        effectiveness = {unarmored = 5, light = 7, medium = 8, heavy = 9, air = 1},
        dcsTypeName = "weapons.missiles.SVIR",
    },
    ["REFLEX"] = {
        displayName = "9M119 Reflex (AT-11 Sniper)",
        kind = "atgm",
        range = 4000,
        minRange = 100,
        effectiveness = {unarmored = 5, light = 7, medium = 8, heavy = 9, air = 1},
        dcsTypeName = "weapons.missiles.REFLEX",
    },
}

return weapons
