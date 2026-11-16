-- ============================================================================
--  Example.lua - Sider 7 module skeleton
--
--  Copy this folder, rename things, keep the shape:
--    * the module returns a table with init(ctx)
--    * every callback is stored on the module table (never a local closure),
--      because Sider calls them from a second Lua state and a local function
--      could be collected mid-session
--    * no pcall / xpcall / require / select / next - Sider's sandbox has none
--    * settings come from a same-named .ini next to this file
-- ============================================================================
local m = {}

m.NAME    = "Example"
m.VERSION = "0.1.0"

local LOG = "[" .. m.NAME .. "] "

-- Sider injects a global `log`; the local wrapper must NOT be called `log`
-- or it would recurse into itself.
local function log_msg(s)
    if log then log(LOG .. tostring(s)) end
end

-- --- settings ---------------------------------------------------------------
local cfg = {}
local DEFAULT_CFG = {
    enabled = 1,
}

local function cfg_i(key, default)
    local v = cfg[key]
    if type(v) == "number" then return v end
    if type(v) == "string" then
        local n = tonumber(v)
        if n then return n end
    end
    return default
end

local function load_ini(ctx)
    for k, v in pairs(DEFAULT_CFG) do cfg[k] = v end
    local path = (ctx and ctx.sider_dir or "") .. "modules\\Example.ini"
    local f = io and io.open(path, "rb")
    if not f and ctx and ctx.sider_dir then
        f = io.open((ctx.sider_dir .. "Example.ini"):gsub("\\", "/"), "rb")
    end
    if not f then
        log_msg("ini not found, using defaults")
        return
    end
    for line in f:lines() do
        line = string.gsub(line, "\r", "")
        if not string.find(line, "^%s*#") then
            local k, v = string.match(line, "^([%w_]+)%s*=%s*(.-)%s*$")
            if k and v ~= "" then cfg[k] = tonumber(v) or v end
        end
    end
    f:close()
end

-- --- callbacks (kept on the module table) -----------------------------------
function m.on_display_frame(ctx)
    if cfg_i("enabled", 1) == 0 then return end
    -- per-frame work goes here (keep it cheap: gate on a millisecond budget)
end

function m.on_key_down(ctx, key)
    -- key is a virtual-key code, e.g. 0x76 = F7
end

-- --- init -------------------------------------------------------------------
function m.init(ctx)
    log_msg(string.format("%s v%s starting", m.NAME, m.VERSION))
    load_ini(ctx)
    ctx.register("display_frame", m.on_display_frame)
    ctx.register("key_down", m.on_key_down)
    log_msg("ready")
end

return m
