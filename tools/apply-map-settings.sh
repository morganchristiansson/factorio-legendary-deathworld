#!/usr/bin/env bash
#
# Emit Factorio console commands that apply the values in
# factorio/data/*.json to the running save.
#
# Usage:
#   tools/apply-map-settings.sh                         # print apply commands (compact)
#   tools/apply-map-settings.sh --diff                  # print Lua that logs differences instead of applying
#   tools/apply-map-settings.sh --diff --output print   # same (default)
#   tools/apply-map-settings.sh --diff --output game.print
#   tools/apply-map-settings.sh --diff --output game.player.print
#   tools/apply-map-settings.sh --help
#
# Notes:
# * Map/difficulty settings persist inside the save once applied.
# * Map GEN settings only affect chunks generated afterwards -- existing terrain is unchanged.
# * Both modes output ONLY Factorio Lua/commands to stdout (safe to pipe to RCON).
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    sed -n '2,30p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
}

DIFF=0
PRINT_FUNC="print"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --diff) DIFF=1; shift ;;
        --output) PRINT_FUNC="$2"; shift 2 ;;
        --print) PRINT_FUNC="print"; shift ;;
        --game-print) PRINT_FUNC="game.print"; shift ;;
        --player-print) PRINT_FUNC="game.player.print"; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "error: unknown option: $1 (try --help)" >&2; exit 2 ;;
        *) # backwards compat: ignore optional REV argument (git integration removed)
            shift ;;
    esac
done

to_lua_jq='
def to_lua:
  if type == "string" then @json
  elif type == "null" then "nil"
  elif type == "boolean" then (if . then "true" else "false" end)
  elif type == "number" then tostring
  elif type == "array" then "{" + (map(to_lua) | join(", ")) + "}"
  elif type == "object" then "{" + ([to_entries[] | (if .key | test("^[a-zA-Z_][a-zA-Z0-9_]*$") then "\(.key) = \(.value | to_lua)" else "[\"\(.key)\"] = \(.value | to_lua)" end)] | join(", ")) + "}"
  else tojson end;
def walk(f): def _walk: if type=="object" then with_entries(.value |= _walk) | f elif type=="array" then map(_walk) | f else f end; _walk;
def clean: walk(if type=="object" then with_entries(select(.key | startswith("_") | not)) else . end);
'

if (( DIFF )); then
    # ── map-settings diff (compact table + recursive check) ───────────────
    # difficulty_settings is map-creation only and not writable via LuaMapSettings; skip it
    if [[ "$PRINT_FUNC" == "game.player.print" ]]; then
        PRINT_INIT='local _print = (game.player and game.player.print) or game.print or print'
    elif [[ "$PRINT_FUNC" == "game.print" ]]; then
        PRINT_INIT='local _print = game.print'
    elif [[ "$PRINT_FUNC" == "print" ]]; then
        PRINT_INIT='local _print = print'
    else
        PRINT_INIT="local _print = $PRINT_FUNC"
    fi
    DESIRED_MAP=$(jq -rn --slurpfile m factorio/data/map-settings.json "$to_lua_jq"'
      ($m[0] | clean | del(.difficulty_settings) | to_lua) as $map
      | "local desired=" + $map + "; '"$PRINT_INIT"'; local function diff(cur, des, pre) for k,v in pairs(des) do local path=pre.. \".\" ..k; local ok,cv=pcall(function() return cur and cur[k] end); if not ok then _print(path .. \" (unknown, skip) -> \" .. tostring(v)) elseif type(v)==\"table\" then if cv==nil then _print(path .. \": nil -> \" .. tostring(v)) else diff(cv,v,path) end elseif cv~=v then _print(path .. \": \" .. tostring(cv) .. \" -> \" .. tostring(v)) end end end; diff(game.map_settings, desired, \"map_settings\")"
    ')
    echo "/silent-command do $DESIRED_MAP end"

    # ── map-gen diff (consistent [] notation, per-field) ──────────────────
    DESIRED_GEN=$(jq -rn --slurpfile m factorio/data/map-gen-settings.json "$to_lua_jq"'
      ($m[0].autoplace_controls | to_lua) as $ctrl
      | "local desired=" + $ctrl + "; local m=game.surfaces[\"nauvis\"].map_gen_settings; '"$PRINT_INIT"'; for ctrl, vals in pairs(desired) do local cur=m.autoplace_controls[ctrl]; if not cur then for k,v in pairs(vals) do _print(\"map_gen_settings.autoplace_controls[\\\"\"..ctrl..\"\\\"][\\\"\"..k..\"\\\"]: nil -> \"..tostring(v)) end else for k,v in pairs(vals) do if cur[k]~=v then _print(\"map_gen_settings.autoplace_controls[\\\"\"..ctrl..\"\\\"][\\\"\"..k..\"\\\"]: \"..tostring(cur[k])..\" -> \"..tostring(v)) end end end end"
    ')
    echo "/silent-command do $DESIRED_GEN end"
    exit 0
fi

# ── normal mode: compact apply via tables ─────────────────────────────────

DESIRED_MAP=$(jq -rn --slurpfile m factorio/data/map-settings.json "$to_lua_jq"'
  ($m[0] | clean | del(.difficulty_settings) | to_lua) as $map
  | "local desired=" + $map + "; local function apply(dst, src) for k,v in pairs(src) do local ok,cur=pcall(function() return dst[k] end); if not ok then else if type(v)==\"table\" and cur~=nil then apply(cur, v) else local ok2,err=pcall(function() dst[k]=v end) end end end end; apply(game.map_settings, desired)"
')
echo "/silent-command do $DESIRED_MAP end"

DESIRED_GEN=$(jq -rn --slurpfile m factorio/data/map-gen-settings.json "$to_lua_jq"'
  ($m[0].autoplace_controls | to_lua) as $ctrl
  | "local desired=" + $ctrl + "; local m=game.surfaces[\"nauvis\"].map_gen_settings; for ctrl, vals in pairs(desired) do m.autoplace_controls[ctrl]=m.autoplace_controls[ctrl] or {}; for k,v in pairs(vals) do m.autoplace_controls[ctrl][k]=v end end; game.surfaces[\"nauvis\"].map_gen_settings=m"
')
echo "/silent-command do $DESIRED_GEN end"
