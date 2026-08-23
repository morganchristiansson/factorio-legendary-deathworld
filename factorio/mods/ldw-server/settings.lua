-- Startup settings: unit spawn entries for biter-spawner / spitter-spawner.
-- Semicolon-separated list of "<unit-name> <curve>" entries.
-- A unit already present in the spawner's result_units has its curve
-- REPLACED; unknown units are ADDED. Only these two spawners are touched.
-- Curve = comma-separated "evo=weight" pairs — same shape as the vanilla
-- result_units entries {{0.0,0.3},{0.35,0}}; piecewise-linear between
-- points, clamped to 0 below the first point:
--   "small-stomper-pentapod 0.35=0.01"
--   "medium-biter 0.2=0.00,0.6=0.40"          (override vanilla)
data:extend({
  {
    type = "string-setting",
    name = "ldw-server-biter-pentapods",
    order = "a",
    setting_type = "startup",
    default_value = "small-stomper-pentapod 0.35=0.01",
    allow_blank = true,
  },
  {
    type = "string-setting",
    name = "ldw-server-spitter-pentapods",
    order = "b",
    setting_type = "startup",
    default_value = "small-strafer-pentapod 0.35=0.01",
    allow_blank = true,
  },
})
