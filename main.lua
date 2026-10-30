-- Add the plugin dir and game-common to the Lua path.
local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. _dir .. "common/?.lua;" .. package.path

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local PluginBase = require("plugin_base")
local _          = require("i18n")

require("i18n").extend(lrequire("i18n_fr"))

local DominosaScreen = lrequire("screen")

-- ---------------------------------------------------------------------------
-- DominosaPlugin
-- ---------------------------------------------------------------------------

local DominosaPlugin = PluginBase:extend{
    -- MUST equal the plugin directory's basename (dominosa -> dominosa.koplugin).
    -- Since KOReader 2026.03 (PR #15096) PluginLoader overwrites this with
    -- the directory name unconditionally, so a mismatch does not just get
    -- ignored: settings and stats end up keyed on a name this file never
    -- mentions. Never put `name` in _meta.lua either -- it is deprecated
    -- there and KOReader logs a warning and drops it.
    name      = "dominosa",
    menu_text = _("Dominosa"),
    menu_hint = "tools",
}

function DominosaPlugin:createScreen()
    return DominosaScreen:new{
        plugin = self,
    }
end

return DominosaPlugin
