-- ============================================================================
--  NEXT-GEN FOOTBALL BROADCAST PRESENTATION
--  MOONFROS PRESENTS  -  created by MoonFros
--  Sider Lua module for Football Life 2025 (FL_2025.exe, PES 2021 engine)
--
--  Feature 1 : cinematic goal replay camera + live shot analysis
--  Feature 2 : player spotlight for goals, shots, saves and misses (G/A/shots)
--  Feature 3 : full-time Man of the Match reveal
--
--  Target : Sider 7.4.x (LuaJIT 2.1, x64), FL_2025.exe (PES 2021 engine v1.7.x)
--  Output : content\ngb-presentation\state.json   -> NGB_Render.dll (in-game D3D11)
--           content\ngb-presentation\heartbeat.txt -> liveness proof
--           Sider overlay text (overlay_on)         -> last-resort fallback
--
--  ---------------------------------------------------------------------------
--  SANDBOX - verified against the Sider 7.4 source (sider.cpp push_env_table),
--  not assumed. Do not "correct" this list from memory.
--
--    globals: assert table pairs ipairs string math tonumber tostring unpack
--             error _VERSION type io collectgarbage jit  (+ os/time,clock,date
--             only)  (+ ffi, bit when luajit.ext.enabled = 1)
--    NOT available at all: print, setmetatable, getmetatable, rawset, rawget,
--             rawequal, coroutine, debug, package, dofile, loadfile, load,
--             loadstring, require, next, select, pcall, xpcall, _ENV
--    libraries in the env but NOT global: log, memory, fs, zlib, audio, match,
--             input, _FILE, _G
--
--  Consequences that shape this whole file:
--    * pcall/xpcall do not exist -> there is no way to catch an error. Every
--      risky call is therefore guarded by a capability check first, and by
--      design nothing here is allowed to raise. A Lua error inside a Sider
--      callback is caught by Sider itself (lua_pcall), so a mistake disables
--      one handler - it does not crash the game.
--    * pair() iteration is not guaranteed to hide anything, but rawset and
--      next are missing, so all tables are built with plain assignment.
--    * ffi must be read as a local BEFORE the module body, and the cdef must
--      be idempotent (Sider hot-reloads a module by re-running the chunk and
--      re-registering the file in the same lua_State).
--
--  Memory access: this module only ever uses Sider's own `memory` library
--  (memory.read / memory.unpack), never FFI Win32 calls. memory.read is a
--  plain memcpy inside the game process - no ReadProcessMemory, no
--  VirtualQuery, no VirtualProtect - so there is no page that can fault.
--  ============================================================================

local m = {}

m.NAME = "Next-Gen Broadcast"
m.AUTHOR = "MoonFros"
m.BRAND = "MOONFROS PRESENTS"
m.TAGLINE = "Next-Gen Football Broadcast Presentation"
m.VERSION = "1.3.1"
m.STATE_VERSION = 4

-- ============================================================================
-- 0. Platform: Sider's memory library (no FFI, no Win32)
-- ============================================================================
-- History: up to 1.3.1 this section called Win32 through FFI (ReadProcessMemory,
-- VirtualQuery, WinExec, GetTickCount64) with __asm__ aliases. That is gone.
--
--   * Sider already runs inside the game process and always exposes `memory`,
--     so ReadProcessMemory/VirtualQuery were both pointless and the riskiest
--     part of the module: a bad address faults inside the game.
--   * memory.read is documented, bounds-free (it does not check the address),
--     so every read below is wrapped by bounds()/load() which first verifies
--     the range against a region map built once from the module's own reads.
--   * Launching the companion was WinExec through FFI. The renderer is now
--     loaded by the module itself (see load_renderer), so nothing has to be
--     spawned at all - which also removes the "cmd window flash" failure mode.
--
-- `ffi` may still exist (luajit.ext.enabled = 1) and is still used for two
-- harmless things: converting a lightuserdata pointer to a number, and
-- building float bytes. Both are pure userspace, no game state is touched.
local ffi = ffi
local ffi_ok = (ffi ~= nil)
local C = ffi_ok and ffi.C or nil

-- `memory` is a Sider global (not a standard Lua one) - present in every build
-- that ships the Lua module system. Capability-probed rather than assumed.
local MEM = memory
local mem_ok = (MEM ~= nil) and (type(MEM.read) == "function")

local RBUF_LEN = 16384
local rbuf = nil
local rn = nil

-- Simulation hook: when m.sim is a function(addr, len) -> string|nil, all
-- memory reads come from it instead of the live process. Used by the offline
-- test harness (tools/verify_mod.py) and by nothing else.
m.sim = nil
m.sim_write = nil

-- ============================================================================
-- 1. Small utilities
-- ============================================================================
local floor, abs, sqrt, exp, sin, cos, tan =
      math.floor, math.abs, math.sqrt, math.exp, math.sin, math.cos, math.tan
local atan = math.atan
local atan2 = math.atan2 or function(y, x) return math.atan(y / (x == 0 and 1e-9 or x)) end
local PI = math.pi

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function smoothstep(t)
    t = clamp(t, 0, 1)
    return t * t * (3 - 2 * t)
end

local function round(v, decimals)
    local p = 10 ^ (decimals or 0)
    return floor(v * p + 0.5) / p
end

local HEXD = "0123456789abcdef"

local function hex(n)
    if type(n) ~= "number" then return "0x?" end
    n = floor(n)
    if n == 0 then return "0x0" end
    if n < 0 then return "-" .. hex(-n) end
    local out = ""
    while n > 0 do
        local d = n % 16
        out = string.sub(HEXD, d + 1, d + 1) .. out
        n = floor(n / 16)
    end
    return "0x" .. out
end

-- FNV-1a style deterministic hash, used for stable "modelled" values
-- (shot placement, body part) so a replay always shows the same numbers.
local function hash32(s)
    local h = 2166136261
    for i = 1, #s do
        h = h % 4294967296
        h = h * 16777619 % 4294967296
        h = h + string.byte(s, i)
        h = h % 4294967296
    end
    return h
end

-- hash -> [0,1)
local function h01(s, salt)
    local h = hash32(s .. "|" .. tostring(salt or 0))
    return (h % 1000000) / 1000000
end

local function hrange(s, salt, lo, hi)
    return lo + (hi - lo) * h01(s, salt)
end

-- ============================================================================
-- 2. Module clock + logging
-- ============================================================================
local last_ms = 0

local function now_ms()
    if m.sim and m.sim_now then return m.sim_now() end
    -- os.clock() reaches the C runtime clock() - CPU seconds on Linux, but on
    -- Windows MSVC it is wall-clock seconds since process start, which is
    -- exactly what this module needs, and it is monotonic per process.
    -- os.time() as the base keeps the value meaningful across a long session;
    -- both are in Sider's sandbox (os = time, clock, date only).
    local v = os.time() * 1000 + floor((os.clock() % 1) * 1000)
    if v < last_ms then v = last_ms end  -- never go backwards
    last_ms = v
    return v
end

m.now_ms = now_ms

local LOG_PREFIX = "[NGB] "
local log_t = {}

local function log_msg(s)
    if log then log(LOG_PREFIX .. tostring(s)) end
end
m.log = log_msg

-- rate limited log (same key at most once per `ms`)
local function log_once(key, s, ms)
    local t = now_ms()
    local prev = log_t[key]
    if prev and (t - prev) < (ms or 5000) then return end
    log_t[key] = t
    log_msg(s)
end
m.log_once = log_once

-- ============================================================================
-- 3. Configuration (INI)
-- ============================================================================
local DEFAULT_CFG = {
    units = "metric",
    companion_hud_enabled = 1,
    state_write_hz = 10,

    -- ---- renderer -----------------------------------------------------------
    -- dll     : NGB_Render.dll drawn inside the game's frame (default)
    -- overlay : legacy C# transparent window (fallback, cannot do fullscreen)
    -- none    : nothing is drawn by this mod; Sider overlay text still works
    renderer = "dll",
    -- dll_enabled = 0 is the kill switch: the DLL is loaded but draws nothing
    dll_enabled = 1,
    -- in-game hotkeys handled by the DLL itself (virtual-key codes)
    --   0x77 = F8  self-test card     0x76 = F7  renderer diagnostics strip
    --   0x7B = F12 kill switch (toggle drawing on/off)
    dll_selftest_hotkey = 0x77,
    dll_diag_hotkey = 0x76,
    dll_kill_hotkey = 0x7B,
    debug_log = 0,
    show_scorebug = 1,
    show_position = 1,
    credit_line = 1,

    -- master presentation switch (hotkey 8 flips it at runtime)
    presentation_enabled = 1,
    -- 0 = full, 1 = compact, 2 = minimal (hotkey 7 cycles it)
    presentation_style = 0,
    -- shot analysis diagram inside the goal card (hotkey 9 flips it)
    shot_analysis_enabled = 1,

    replay_camera_enabled = 1,
    replay_camera_preset = 1,
    replay_height_cam0 = 0.34,
    replay_height_cam3 = 1.05,
    replay_zoom = 0.62,
    goal_telemetry_duration = 13.0,
    goal_telemetry_delay = 1.5,
    replay_window_max = 45.0,

    shot_popup_enabled = 1,
    shot_popup_duration = 6.5,

    milestone_toast_enabled = 1,
    milestone_toast_duration = 4.5,

    motm_card_enabled = 1,
    motm_card_duration = 20.0,
    -- half time / full time score cards (they only need the scoreboard)
    result_card_enabled = 1,
    result_card_duration = 9.0,
    -- the per-player memory scan is experimental and off until it proves itself
    experimental_player_stats = 0,
    -- write a calibration dump (region map + scoreboard hexdump) to probe.txt
    probe_enabled = 0,

    stats_poll_ms = 350,
    position_poll_ms = 120,

    -- digits 7 / 8 / 9 by default; never F7 / F8 / F9
    hotkey_prev_style = 0x37,
    hotkey_toggle_overlay = 0x38,
    hotkey_toggle_analysis = 0x39,
    -- 1 = digits only act while the Sider overlay is open (no clashes with the
    -- game's own 7/8/9 keys); set 0 to accept them during play as well
    hotkeys_overlay_only = 1,

    stats_region_base = "",
    pitch_region_base = "",
}

local cfg = {}
m.cfg = cfg

local function ini_strip(line)
    line = string.gsub(line, "\r", "")
    line = string.gsub(line, "//.*$", "")
    line = string.gsub(line, "#.*$", "")
    return line
end

-- Minimal INI reader: "key = value", '#' or '//' comments, [sections] ignored.
function m.parse_ini(text)
    local out = {}
    if type(text) ~= "string" then return out end
    for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
        local clean = ini_strip(line)
        if not string.match(clean, "^%s*%[") then
            local k, v = string.match(clean, "^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
            if k then
                out[string.lower(k)] = v
            end
        end
    end
    return out
end

local function cfg_i(key, def)
    local v = cfg[key]
    if v == nil then return def end
    local n = tonumber(v)
    if n == nil then return def end
    return floor(n)
end

local function cfg_f(key, def)
    local v = cfg[key]
    if v == nil then return def end
    local n = tonumber(v)
    if n == nil then return def end
    return n
end

local function cfg_s(key, def)
    local v = cfg[key]
    if v == nil or v == "" then return def end
    return v
end

local function parse_hex(s)
    if type(s) ~= "string" then return nil end
    s = string.gsub(s, "^%s*", "")
    s = string.gsub(s, "%s*$", "")
    if s == "" then return nil end
    local body = string.match(s, "^0[xX](%x+)$")
    if not body then return nil end
    local n = 0
    for i = 1, #body do
        local d = tonumber(string.sub(body, i, i), 16)
        if not d then return nil end
        n = n * 16 + d
    end
    if n <= 0 then return nil end
    return n
end

m.parse_hex = parse_hex

-- ============================================================================
-- 4. Raw memory layer (Sider `memory` library / simulation)
-- ============================================================================
-- m.load(addr, len) fills the read cache and returns true on success.
-- m.u32(off) / m.u16(off) / m.u8(off) / m.f32(off) decode from that cache.
--
-- Why this is safe even though memory.read is unbounded:
--   Sider's memory.read(addr,n) is a memcpy inside the game process. An
--   unmapped address raises a Lua error (Sider reports it in sider.log), and
--   inside a callback Sider catches it with lua_pcall - the game survives, our
--   handler for that event stops working until reload. Still unacceptable, so
--   m.load() first checks the range against m.regions, a map of the committed
--   game regions that the module builds once and refreshes on context_reset.
--   Nothing in this file reads outside that map.
m.regions = nil
m.regions_built = 0

-- Decoded cache: the bytes of the last successful load, as a Lua string. All
-- scalar accessors decode from it, so one load == one memory.read.
local rcache = ""
local rcache_len = 0

-- Is [addr, addr+len) inside a region we know is committed?
function m.in_region(addr, len)
    if type(addr) ~= "number" or addr < 0x10000 then return false end
    local rs = m.regions
    if not rs then return false end
    local enda = addr + len
    for i = 1, #rs do
        local r = rs[i]
        if addr >= r.start and enda <= r.finish then return true end
    end
    return false
end

-- Build the region map from the game's own PE sections plus the heap arenas we
-- actually observe. memory.get_process_info() is a documented Sider call and is
-- the only privileged thing this module needs.
function m.build_regions(force)
    if not mem_ok then return false end
    local t = os.time and os.time() or 0
    if not force and m.regions and (t - m.regions_built) < 30 then return true end
    if type(MEM.get_process_info) ~= "function" then
        return false                      -- cannot verify: reads stay disabled
    end
    local info = MEM.get_process_info()
    if type(info) ~= "table" then return false end
    local rs = {}
    local base = m.ptr_num(info.base) or m.ptr_num(info.base_address)
    if base then
        rs[#rs + 1] = { start = base, finish = base + 0x20000000, name = "image" }
    end
    local secs = info.sections
    if type(secs) == "table" then
        for i = 1, #secs do
            local sc = secs[i]
            if type(sc) == "table" then
                local a = m.ptr_num(sc.start)
                local b = m.ptr_num(sc.finish)
                if a and b and b > a then
                    rs[#rs + 1] = { start = a, finish = b, name = tostring(sc.name or "") }
                end
            end
        end
    end
    -- the game's private arenas (scoreboard, stat table, pitch block) live in
    -- the process heap, above the image. memory.allocate_codecave gives us one
    -- trustworthy committed arena to anchor the heap band on, and it is a
    -- legitimate documented call (we do not execute anything in it).
    local anchor = nil
    if type(MEM.allocate_codecave) == "function" then
        anchor = m.ptr_num(MEM.allocate_codecave(16))
    end
    if anchor then
        rs[#rs + 1] = { start = anchor, finish = anchor + 16, name = "anchor" }
        -- Sider's own data lives in the same heap family as the game's; the
        -- band is generous but still inside the 64-bit user space.
        rs[#rs + 1] = { start = anchor - 0x40000000, finish = anchor + 0x40000000,
                        name = "heap" }
        m.heap_anchor = anchor
    end
    if #rs == 0 then return false end
    m.regions = rs
    m.regions_built = t
    return true
end

function m.load(addr, len)
    if type(addr) ~= "number" or addr < 0x10000 then return false end
    if len == nil or len <= 0 or len > RBUF_LEN then return false end

    if m.sim then
        local s = m.sim(addr, len)
        if type(s) ~= "string" or #s < len then return false end
        rcache = s
        rcache_len = len
        return true
    end

    if not mem_ok then return false end
    if not m.regions then
        if not m.build_regions(false) then return false end
    end
    if not m.in_region(addr, len) then
        -- the heap band can move; rebuild once, then give up for this read
        if not m.build_regions(true) then return false end
        if not m.in_region(addr, len) then return false end
    end

    local s = MEM.read(addr, len)
    if type(s) ~= "string" or #s < len then return false end
    rcache = s
    rcache_len = len
    return true
end

-- Decoders. Bounds-checked against the cached length instead of trusting the
-- caller: a short cache can never produce a garbage number, it returns 0.
local byte, sub = string.byte, string.sub
local function rc_u8(off)
    if off < 0 or off >= rcache_len then return 0 end
    return byte(rcache, off + 1) or 0
end

function m.u8(off)  return rc_u8(off) end

function m.u16(off)
    return rc_u8(off) + rc_u8(off + 1) * 256
end

function m.u32(off)
    return rc_u8(off) + rc_u8(off + 1) * 256 + rc_u8(off + 2) * 65536
             + rc_u8(off + 3) * 16777216
end

-- 32-bit float from 4 little-endian bytes (IEEE-754). Pure Lua: no FFI, so it
-- cannot fault and cannot be affected by a failed cdef. Inf/NaN decode to 0
-- because no real game value is either, and a NaN in the HUD is worse than a
-- missing number.
function m.f32(off)
    local b0, b1, b2, b3 = rc_u8(off), rc_u8(off + 1), rc_u8(off + 2), rc_u8(off + 3)
    local sign = (b3 >= 128) and -1 or 1
    local expo = (b3 % 128) * 2 + floor(b2 / 128)
    local mant = b0 + b1 * 256 + (b2 % 128) * 65536
    if expo == 0 then
        if mant == 0 then return 0 end
        return sign * mant * 2.938735877055719e-39     -- 2^-128 * (1/2^21)
    elseif expo == 255 then
        return 0
    end
    return sign * (1 + mant / 8388608) * 2 ^ (expo - 127)
end

-- Read a single u32 / f32 by address.
function m.read_u32(addr)
    if not m.load(addr, 4) then return nil end
    return m.u32(0)
end

function m.read_f32(addr)
    if not m.load(addr, 4) then return nil end
    return m.f32(0)
end

function m.read_u64(addr)
    if not m.load(addr, 8) then return nil end
    local lo = m.u32(0)
    local hi = m.u32(4)
    return hi * 4294967296 + lo
end

-- NUL terminated UTF-8 string of at most `len` bytes.
function m.read_str(addr, len)
    if not m.load(addr, len) then return nil end
    local z = string.find(rcache, "\0", 1, true)
    if z then return string.sub(rcache, 1, z - 1) end
    return rcache
end

-- Large read (Player.bin image, section scans). Same bounds rule; the caller
-- gets nil instead of a fault when anything is off.
function m.read_big(addr, len)
    if type(addr) ~= "number" or addr < 0x10000 then return nil end
    if len == nil or len <= 0 or len > 64 * 1024 * 1024 then return nil end
    if m.sim then
        local s = m.sim(addr, len)
        if type(s) ~= "string" or #s < len then return nil end
        return string.sub(s, 1, len)
    end
    if not mem_ok then return nil end
    if not (m.regions or m.build_regions(false)) then return nil end
    if len > 4 * 1024 * 1024 then
        if not m.in_region(addr, len) then return nil end
    end
    local s = MEM.read(addr, len)
    if type(s) ~= "string" or #s < len then return nil end
    return s
end

-- ============================================================================
-- 5. Pointer helpers
-- ============================================================================
-- ctx.mis / match.stats().ptr are lightuserdata; convert them to numbers once.
function m.ptr_num(p)
    if p == nil then return nil end
    if type(p) == "number" then
        if p > 0x10000 then return p end
        return nil
    end
    -- lightuserdata: memory.hex() prints it as 0x....  (documented Sider call)
    if mem_ok and type(MEM.hex) == "function" then
        local hx = MEM.hex(p)
        local n = hx and parse_hex(hx)
        if n and n > 0x10000 then return n end
    end
    -- last resort: FFI cast, only if the extension happens to be loaded
    if ffi_ok then
        local ok = ffi.typeof("uint64_t")
        if ok then
            local n = tonumber(ffi.cast("uint64_t", ffi.cast("void *", p)))
            if n and n > 0x10000 then return n end
        end
    end
    return nil
end

-- ============================================================================
-- 6. Game structure offsets (PES 2021 / FL_2025.exe v1.0)
-- ============================================================================
local OFF = {
    -- MATCH_INFO_STRUCT (ctx.mis)
    TEAM_HOME       = 0x138,
    TEAM_AWAY       = 0x7C8,
    TEAM_STRIDE     = 0x690,
    T_NAME          = 0x04,     -- 0x46 bytes UTF-8
    T_ABBR          = 0x4A,     -- 4 bytes
    T_COLORS        = 0x5D8,    -- SHIRTCOLOR_STRUCT players[2]
    T_SQUAD         = 0x150,    -- 40 x u32 squad ids (rel. to team struct)
    XI_HOME         = 0x1078,   -- 11 x u8 squad indices (home)
    XI_AWAY         = 0x12D0,   -- 11 x u8 squad indices (away)

    -- SCOREBOARD_INFO (match.stats().ptr)
    S_PAUSED        = 0x20,
    S_CLOCK_RUN     = 0x22,
    S_SCI2          = 0x38,
    S_HOME_SCORE    = 0x120,
    S_AWAY_SCORE    = 0x124,
    S_CLOCK_MIN     = 0x12C,
    S_CLOCK_SEC     = 0x130,
    S_INJURY        = 0x138,
    S_ADDED_MIN     = 0x144,

    -- SCOREBOARD_INFO2
    S2_MATCH_STAGE  = 0x88,     -- 0x05 live, 0x0c kick-off, 0x10 shootout

    -- per player stat block inside the 0x190000 private region
    REC_BASE        = 0x7B5C0,
    REC_SIDE        = 0x59650,
    REC_IDX         = 0x2134,
    KIND_STRIDE     = 0x24,
    KIND_OFFSET     = 0x08,

    -- region extras
    TIME_COUNTER    = 0x7B518,
    POSS_HOME       = 0x181A10,
    POSS_AWAY       = 0x181A14,

    -- 22 player pitch positions inside the 0xF0000 private region
    PITCH_BLOCK     = 0x253FC,
    PITCH_ENTRY     = 12,       -- 3 x f32 (x, y, z) in metres
}

-- ---------------------------------------------------------------------------
-- Per-player table layout: the defaults above, overridable WITHOUT editing this
-- file, from two places (later wins):
--   1. content\ngb-presentation\calibration.txt   written by tools/decode_probe.py
--   2. NGB_Presentation.ini   stat_rec_base / stat_side_stride / stat_rec_stride /
--                             stat_kind_stride / stat_kind_offset / stat_buckets
-- A layout is only ever used for display after m.validate_stats() reproduces the
-- scoreboard with it; a wrong layout therefore produces no numbers at all.
-- ---------------------------------------------------------------------------
local BUCKETS = 8

local LAYOUT_FIELDS = {
    stat_rec_base    = "REC_BASE",
    stat_side_stride = "REC_SIDE",
    stat_rec_stride  = "REC_IDX",
    stat_kind_stride = "KIND_STRIDE",
    stat_kind_offset = "KIND_OFFSET",
    stat_buckets     = "BUCKETS",
}

function m.layout()
    return {
        rec_base = OFF.REC_BASE, side = OFF.REC_SIDE, idx = OFF.REC_IDX,
        kind = OFF.KIND_STRIDE, kind_off = OFF.KIND_OFFSET, buckets = BUCKETS,
    }
end

function m.apply_layout(t, tag)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for key, field in pairs(LAYOUT_FIELDS) do
        local v = t[key]
        if v == nil then v = t[string.lower(field)] end
        local num = nil
        if type(v) == "number" then num = v
        elseif type(v) == "string" then num = parse_hex(v) or tonumber(v) end
        if num then
            num = floor(num)
            if num >= 0 and num <= 0x4000000 then
                if field == "BUCKETS" then
                    if num >= 1 and num <= 16 then
                        BUCKETS = num
                        OFF.BUCKETS = num
                        n = n + 1
                    end
                else
                    OFF[field] = num
                    n = n + 1
                end
            end
        end
    end
    if n > 0 and tag then
        log_msg(string.format(
            "layout from %s: rec_base %s  side %s  idx %s  kind %s  buckets %d",
            tostring(tag), hex(OFF.REC_BASE), hex(OFF.REC_SIDE), hex(OFF.REC_IDX),
            hex(OFF.KIND_STRIDE), BUCKETS))
    end
    return n
end

-- calibration.txt: "key = value" lines, hex or decimal, '#' comments
function m.read_calibration(dir)
    if not dir then return nil end
    local f = io.open(dir .. "\\calibration.txt", "r")
    if not f then return nil end
    local text = f:read("*a") or ""
    f:close()
    local out = {}
    for line in string.gmatch(text, "[^\r\n]+") do
        line = string.gsub(line, "#.*$", "")
        local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*([^%s]+)")
        if k then out[string.lower(k)] = v end
    end
    return out
end

-- Region header signatures: { 0, size - 0x20, 1 } as 3 x u32.
local REGION_STATS_SIZE = 0x18FFE0
local REGION_PITCH_SIZE = 0xEFFE0

-- Stat kinds (indices into the 9 x u32 buckets of one stat record)
local KIND = {
    goals       = 0,
    own         = 1,
    fk_goal     = 2,
    pk_goal     = 3,
    assists     = 4,
    shots       = 6,
    shot_ok     = 12,
    on_target   = 17,
    pk_shot     = 21,
    passes      = 22,
    passes_ok   = 23,
    tackles     = 49,
    tackles_ok  = 50,
    clearances  = 54,
    fouls       = 55,
    offsides    = 56,
    yellow      = 57,
    red         = 58,
    corners     = 63,
    dribbles    = 65,
    dribbles_ok = 66,
    touches     = 67,
    interceptions = 78,
    blocks      = 86,
    saves       = 133,
    rating      = 179,  -- word[0] interpreted as IEEE-754 float
}
m.KIND = KIND

local STAGE_KICKOFF = 0x0c
local STAGE_LIVE    = 0x05
local STAGE_PK      = 0x10

-- ============================================================================
-- 7. Match state reading
-- ============================================================================
m.match = {
    valid = false,
    home = { name = "HOME", abbr = "HOM", score = 0, color = nil, id = nil },
    away = { name = "AWAY", abbr = "AWY", score = 0, color = nil, id = nil },
    clock_min = 0,
    clock_sec = 0,
    clock_changed_at = 0,   -- last time the match clock moved
    added = 0,
    period = 0,
    paused = false,
    running = false,
    stage = 0,
    mis = 0,
    sci = 0,
    sci2 = 0,
    pk_home = 0,
    pk_away = 0,
    seq = 0,        -- increments on every new match
}

local function read_cstr(addr, len)
    local s = m.read_str(addr, len)
    if not s then return nil end
    local z = string.find(s, "\0", 1, true)
    if z then s = string.sub(s, 1, z - 1) end
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    if s == "" then return nil end
    return s
end

local function read_team_colors(base)
    -- SHIRTCOLOR_STRUCT: index u8, unknown u8, color1[3], color2[3]
    if not m.load(base, 8) then return nil end
    local r, g, b = m.u8(2), m.u8(3), m.u8(4)
    if (r + g + b) < 24 then
        r, g, b = m.u8(5), m.u8(6), m.u8(7)
    end
    if (r + g + b) < 24 then return nil end
    return string.format("#%02X%02X%02X", r, g, b)
end

local function refresh_teams()
    local mis = m.match.mis
    if mis == 0 then return end
    for side = 0, 1 do
        local t = m.match[side == 0 and "home" or "away"]
        local base = mis + OFF.TEAM_HOME + side * OFF.TEAM_STRIDE
        local nm = read_cstr(base + OFF.T_NAME, 0x46)
        local ab = read_cstr(base + OFF.T_ABBR, 4)
        if nm then t.name = string.upper(nm) end
        if ab then t.abbr = string.upper(ab) end
        if not t.color then
            t.color = read_team_colors(base + OFF.T_COLORS)
        end
    end
end

-- The names inside MATCH_INFO are filled a moment after the pointer appears,
-- so refresh them a few times instead of only when ctx.mis changes.
local teams_refresh_at = 0
-- ---------------------------------------------------------------------------
--  Minutes played
--
--  The engine exposes no per player minutes counter, so the mod records the
--  match clock at which each player was first seen on the pitch (checked every
--  2 s against the live XI, and again when an event names a player).  For a
--  starter that is 00:00 and the value is exact; for a substitute it is the
--  minute he came on, which is marked as approximate in the HUD.
-- ---------------------------------------------------------------------------
m.seen = {}

local function note_seen(pid, clock_min)
    if not pid or pid == 0 then return end
    local rec = m.seen[pid]
    if rec then return end
    m.seen[pid] = { first = clock_min or 0 }
end

local function minutes_for(pid)
    if not pid or pid == 0 then return nil, false end
    local rec = m.seen[pid]
    local clock = m.match.clock_min or 0
    if not rec then
        m.seen[pid] = { first = clock }
        return 0, false
    end
    local mins = clock - (rec.first or 0)
    if mins < 0 then mins = 0 end
    if mins > 130 then mins = 130 end
    return floor(mins), (rec.first or 0) <= 0
end

m.note_seen = note_seen
m.minutes_for = minutes_for

local function note_xi_seen()
    if not m.match.valid then return end
    local clock = m.match.clock_min or 0
    for side = 0, 1 do
        for slot = 0, 10 do
            local sq = m.xi_slot(side, slot)
            if sq then note_seen(m.squad_id(side, sq), clock) end
        end
    end
end

m.note_xi_seen = note_xi_seen

local function refresh_teams_periodic(now)
    if now < teams_refresh_at then return end
    teams_refresh_at = now + 2000
    refresh_teams()
    m.xi_cache = nil   -- substitutions change the on-pitch XI
    note_xi_seen()
end

function m.refresh_match(force)
    local ctx = m.ctx
    local now = now_ms()

    -- MATCH_INFO (ctx.mis) is not part of the documented context table, so it
    -- is only a bonus: when it is missing nothing breaks, the names simply
    -- stay empty instead of being invented.
    if ctx and ctx.mis then
        local mis = m.ptr_num(ctx.mis)
        if mis and mis ~= m.match.mis then
            m.match.mis = mis
            m.match.home.color = nil
            m.match.away.color = nil
            m.squad_cache = nil
            refresh_teams()
        end
    end

    -- ---- scoreboard (this is the source of truth) -------------------------
    local st = nil
    if match and match.stats then
        m.eng.lib = true
        st = match.stats()
    end
    if st then
        m.eng.ok = true
        m.eng.last_ok = now
        if st.ptr then
            local sci = m.ptr_num(st.ptr)
            if sci and sci ~= m.match.sci then
                m.match.sci = sci
                m.match.sci2 = m.read_u64(sci + OFF.S_SCI2) or 0
            end
        end
        m.eng.score.home = tonumber(st.home_score) or m.eng.score.home
        m.eng.score.away = tonumber(st.away_score) or m.eng.score.away
        local cm = tonumber(st.clock_minutes) or 0
        local cs = tonumber(st.clock_seconds) or 0
        if cm ~= m.match.clock_min or cs ~= m.match.clock_sec then
            m.match.clock_changed_at = now
        end
        m.match.clock_min = cm
        m.match.clock_sec = cs
        m.match.added = tonumber(st.added_minutes) or 0
        m.match.period = tonumber(st.period) or 0
        m.match.pk_home = tonumber(st.pk_home_score) or 0
        m.match.pk_away = tonumber(st.pk_away_score) or 0
        m.match.valid = true
        if (now - m.eng.last_ok) < 1 then
            -- first successful read after a gap: treat as the new baseline
        end
    end

    -- scores on screen: the scoreboard while it is alive, otherwise what the
    -- goal hook counted. never both, so nothing is counted twice.
    if m.eng.ok and (now - m.eng.last_ok) < 4000 then
        m.match.home.score = m.eng.score.home
        m.match.away.score = m.eng.score.away
        if m.eng.pending_side ~= nil then
            local caught = (m.eng.pending_side == 0)
                          and (m.eng.score.home > (m.eng.prev.home or 0))
                          or  (m.eng.pending_side == 1 and m.eng.score.away > (m.eng.prev.away or 0))
            if caught then m.eng.pending_side = nil end
        end
    else
        m.match.home.score = m.tally_score.home
        m.match.away.score = m.tally_score.away
    end

    refresh_teams_periodic(now)

    local sci = m.match.sci
    if sci and sci ~= 0 then
        if m.load(sci + OFF.S_PAUSED, 4) then
            m.match.paused = (m.u8(0) ~= 0)
            m.match.running = (m.u8(2) ~= 0)
        end
        local sci2 = m.match.sci2
        if sci2 and sci2 ~= 0 then
            if m.load(sci2 + OFF.S2_MATCH_STAGE, 1) then
                local stage = m.u8(0)
                -- only values the game actually documents; anything else is a
                -- pointer that moved, and 0xFF means "unknown" rather than a
                -- number the HUD might act on
                if stage == STAGE_LIVE or stage == STAGE_KICKOFF or stage == STAGE_PK then
                    m.match.stage = stage
                else
                    m.match.stage = 0xFF
                end
            end
        end
    end
    m.match.seq = m.match.seq + 1
end

function m.clock_str()
    local mm = m.match.clock_min
    local ss = m.match.clock_sec
    local s = string.format("%d:%02d", mm, ss)
    if m.match.added and m.match.added > 0 and mm >= 45 then
        s = s .. "+" .. tostring(m.match.added)
    end
    return s
end

-- ============================================================================
-- 7b. Engine truth  (Sider match library + goal_scored hook)
--
--  This is the part that cannot be wrong: Sider itself reads the scoreboard and
--  the goal hook straight out of the game, so whatever arrives here is real.
--  Everything the HUD shows as a hard number comes from this section.  The old
--  per-player scan (sections 9-11) is experimental, off by default, and its
--  numbers are only published after they pass a sanity check.
-- ============================================================================
m.eng = {
    lib = false,          -- this Sider build exposes match.stats()
    ok = false,           -- ... and it returned a table at least once
    ini_ok = nil,         -- sider.ini contains match-stats.enabled = 1
    last_ok = 0,
    score = { home = 0, away = 0 },
    prev = { home = 0, away = 0, period = -1 },
    goals = 0,
    last_goal_at = 0,
    pending_side = nil,
    pending_until = 0,
    last_goal_name = "",
    -- goals the hook has announced but the scoreboard has not caught up with
    unconfirmed = { home = 0, away = 0 },
    -- a scoreboard goal waiting for a hook that may still arrive
    fallback = nil,
}
m.scorers = {}            -- every goal of the current match, in order
m.tally_score = { home = 0, away = 0 }
m.tally = {}              -- per player goals, counted from the hook

-- sider.ini tells us whether the match library was switched on. install.bat
-- adds the line; if the mod was dropped in by hand the answer is visible here.
function m.check_ini_flags()
    local sdir = (m.ctx and m.ctx.sider_dir) or nil
    if not sdir then return end
    local f = io.open(sdir .. "sider.ini", "r")
    if not f then return end
    local txt = f:read("*a") or ""
    f:close()
    local on = string.find(txt, "match%-stats%.enabled%s*=%s*1") ~= nil
    m.eng.ini_ok = on
    if not on then
        log_once("msini",
            "sider.ini has no 'match-stats.enabled = 1' - the live score and clock will read 0. " ..
            "install.bat adds it for you; by hand it is one line, then restart the game.", 120000)
    end
    if string.find(txt, "luajit%.ext%.enabled%s*=%s*1") == nil then
        log_once("ljini", "sider.ini has no 'luajit.ext.enabled = 1' - FFI extras stay off.", 120000)
    end
end

local function clean_name(str)
    if type(str) ~= "string" then return "" end
    str = string.gsub(str, "[%z\1-\31\127]", "")
    str = string.gsub(str, "^%s+", "")
    str = string.gsub(str, "%s+$", "")
    if #str > 22 then str = string.sub(str, 1, 22) end
    return str
end
m.clean_name = clean_name

-- score that should be on screen right now: the engine's, or (for the moment
-- between the goal hook firing and the scoreboard catching up) that plus one
local function current_score()
    local h, a = m.match.home.score or 0, m.match.away.score or 0
    if m.eng.pending_side and now_ms() < (m.eng.pending_until or 0) then
        if m.eng.pending_side == 0 then h = h + 1 else a = a + 1 end
    end
    return h, a
end
m.current_score = current_score

function m.data_source()
    if m.eng.ok and (now_ms() - (m.eng.last_ok or 0)) < 4000 then return "sider" end
    return "none"
end

-- ============================================================================
-- 8. Player database (Player.bin, WESYS + zlib, 312 byte records)
-- ============================================================================
m.db = {}
m.db_ready = false

local RECORD_LEN = 312
local P_ID      = 8
local P_SHIRT   = 129
local P_NAME    = 251
local P_POS     = 54    -- bits: shift 2, 4 bits
local P_HEIGHT  = 27    -- bits: 8 bits, +100
local P_KPOWER  = 44    -- bits: shift 6, 6 bits, +40
local P_FINISH  = 49    -- bits: shift 4, 6 bits, +40

local POS_NAMES = {
    [0] = "GK", [1] = "CB", [2] = "LB", [3] = "RB", [4] = "DMF", [5] = "CMF",
    [6] = "LMF", [7] = "RMF", [8] = "AMF", [9] = "LWF", [10] = "RWF",
    [11] = "SS", [12] = "CF",
}

-- Field reader for the PES bit-packed record layout:
-- value = (bits at offset:shift) + addend
local function read_bits(buf, offset, shift, bits, addend)
    local v = 0
    for i = 0, bits - 1 do
        local p = shift + i
        local byte = string.byte(buf, offset + floor(p / 8) + 1) or 0
        if floor(byte / (2 ^ (p % 8))) % 2 == 1 then
            v = v + 2 ^ i
        end
    end
    return v + (addend or 0)
end

m.read_bits = read_bits

-- Parses the *decompressed* Player.bin image. Returns count of players.
function m.parse_player_bin(raw)
    if type(raw) ~= "string" then return 0, "not a string" end
    local total = #raw
    if total < RECORD_LEN then return 0, "buffer too small" end
    local count = floor(total / RECORD_LEN)
    local db = m.db
    for i = 0, count - 1 do
        local off = i * RECORD_LEN
        local id = 0
        -- little endian u32 at off + P_ID
        for b = 3, 0, -1 do
            id = id * 256 + (string.byte(raw, off + P_ID + b + 1) or 0)
        end
        if id > 0 then
            local name = string.sub(raw, off + P_NAME + 1, off + P_NAME + 60)
            local z = string.find(name, "\0", 1, true)
            if z then name = string.sub(name, 1, z - 1) end
            if name ~= "" then
                local shirt = string.byte(raw, off + P_SHIRT + 1) or 0
                local posv = read_bits(raw, off + P_POS, 2, 4, 0)
                db[id] = {
                    name = name,
                    shirt = shirt,
                    pos = POS_NAMES[posv] or "",
                    height = read_bits(raw, off + P_HEIGHT, 0, 8, 100),
                    kpower = read_bits(raw, off + P_KPOWER, 6, 6, 40),
                    finish = read_bits(raw, off + P_FINISH, 4, 6, 40),
                }
            end
        end
    end
    m.db_ready = true
    return count
end

-- Called from livecpk_data_ready. `data` is an address, `size` a byte count.
function m.on_player_bin(addr, size)
    if m.db_ready then return end
    if not size or size <= 1024 or size > 64 * 1024 * 1024 then
        log_once("pbinsize", "Player.bin: implausible buffer size " .. tostring(size), 10000)
        return
    end
    local s = m.read_big(addr, size)
    if not s then
        log_once("pbinread", "Player.bin: unable to read buffer", 10000)
        return
    end
    local raw = s
    -- WESYS wrapper: 00 01 01 'W' 'E' 'S' 'Y' 'S' + u32 comp + u32 uncomp
    if string.sub(s, 4, 8) == "WESYS" and zlib and zlib.unpack then
        local comp = 0
        for b = 3, 0, -1 do
            comp = comp * 256 + (string.byte(s, 8 + b + 1) or 0)
        end
        if comp + 16 <= #s then
            local plain = zlib.unpack(s)
            if plain then raw = plain end
        else
            log_once("pbinchunk", "Player.bin arrived in chunks - waiting for the full buffer", 20000)
            return
        end
    end
    local n = m.parse_player_bin(raw)
    log_msg(string.format("Player.bin parsed: %d players (%d KB payload)",
        n, floor(#raw / 1024)))
end

function m.player_info(pid)
    if pid and m.db[pid] then return m.db[pid] end
    return nil
end

-- ============================================================================
-- 9. Private heap region discovery (heap walk, no VirtualQuery)
-- ============================================================================
-- The per-player stat block and the pitch block live in large private
-- allocations of the game's heap. Up to 1.3.1 the module found them by walking
-- VirtualQueryEx through FFI - one cdef away from killing the process, and
-- Windows-version dependent. It now walks a *bounded window* around the heap
-- anchor (see build_regions) in 1 MB steps and accepts a candidate only if the
-- block identifies itself: u32@0 == 0, u32@4 == expected size, u32@8 == 1.
-- Every read still goes through m.load(), i.e. through the region map.
--
-- This stays OFF by default and only ever runs when
-- experimental_player_stats = 1 (see the ini). Untuned, it finds nothing and
-- says so - it cannot invent numbers.
m.reg = { stats = 0, pitch = 0, ok = false, tries = 0 }

local function valid_region(base, size_field)
    if not m.load(base, 12) then return false end
    return m.u32(0) == 0 and m.u32(4) == size_field and m.u32(8) == 1
end

local function scan_regions()
    if not mem_ok then return false end
    if not m.regions and not m.build_regions(true) then return false end
    local anchor = m.heap_anchor
    if not anchor then
        log_once("noanchor",
            "no heap anchor available - automatic stat-region discovery is off; " ..
            "pin stats_region_base in NGB_Presentation.ini if you have a calibrated value", 120000)
        return false
    end

    local window = 0x20000000          -- +-512 MB around the anchor
    local step = 0x100000              -- 1 MB
    local hits = 0
    local addr = anchor
    local lo, hi = anchor - window, anchor + window

    -- walk upwards from the anchor, then downwards; stop at the first hit of
    -- each kind so a normal match costs a few hundred bounded reads
    for dir = 1, 2 do
        local p = (dir == 1) and anchor or (anchor - step)
        while p > lo and p < hi do
            if m.reg.stats == 0 and valid_region(p, REGION_STATS_SIZE) then
                m.reg.stats = p
                log_msg("stats region @ " .. hex(p))
            end
            if m.reg.pitch == 0 and valid_region(p, REGION_PITCH_SIZE) then
                m.reg.pitch = p
                log_msg("pitch region @ " .. hex(p))
            end
            if m.reg.stats ~= 0 and m.reg.pitch ~= 0 then break end
            p = p + ((dir == 1) and step or -step)
            hits = hits + 1
            if hits > 2048 then break end
        end
        if m.reg.stats ~= 0 and m.reg.pitch ~= 0 then break end
    end

    m.reg.ok = (m.reg.stats ~= 0)
    if not m.reg.ok then
        log_once("noscan", "stat region not found in the heap window (scan #" ..
                 tostring(m.reg.tries) .. ") - player stats stay off", 30000)
    end
    return m.reg.ok
end

-- Manual override from the INI, validated before use.
local function apply_region_override()
    local s = parse_hex(cfg_s("stats_region_base", ""))
    local p = parse_hex(cfg_s("pitch_region_base", ""))
    if s and (m.reg.stats == 0) and valid_region(s, REGION_STATS_SIZE) then
        m.reg.stats = s
        log_msg("stats region (INI) @ " .. hex(s))
    end
    if p and (m.reg.pitch == 0) and valid_region(p, REGION_PITCH_SIZE) then
        m.reg.pitch = p
        log_msg("pitch region (INI) @ " .. hex(p))
    end
    m.reg.ok = (m.reg.stats ~= 0)
end

-- ============================================================================
-- 9b. Is the per-player scan actually telling the truth?
--
--  A guessed offset that happens to be readable still returns zeros, and zeros
--  on a card are worse than no card at all.  Before any of it is used, the
--  numbers have to agree with the game: twenty-two readable players, shots at
--  least as many as shots on target, and a goal total that covers the
--  scoreboard.  Anything else and the HUD falls back to scoreboard-only cards.
-- ============================================================================
m.stats_validated = false
m.stats_checked_at = 0

-- Base predicate: is there any reason to believe the stat table at all?
-- (a) the feature is on, (b) a region was found, (c) the layout validated.
-- Deliberately does NOT include coherence, so check_coherence() can use it
-- without depending on its own result.
function m.stats_base_ok()
    if cfg_i("experimental_player_stats", 0) == 0 then return false end
    if not m.reg or (m.reg.stats or 0) == 0 then return false end
    return m.stats_validated == true
end

-- Stats are publishable only when the base predicate holds AND the numbers
-- still agree with the scoreboard this second (see check_coherence).
-- The first call after validation runs the check itself, so there is never a
-- window where stats are validated but not yet coherent (that window used to
-- swallow the first goal of a match).
function m.player_stats_ok()
    if not m.stats_base_ok() then return false end
    if m.stats_coherent == nil then m.check_coherence() end
    return m.stats_coherent == true
end

-- ---------------------------------------------------------------------------
--  Coherence: the reason "0 shots, 2 goals" can never reach the screen.
--
--  The scoreboard (Sider's match.stats) is ground truth: it is what the game
--  itself prints. The per-player table is a guessed layout. If the two
--  disagree in ways that are physically impossible, the statue table is wrong
--  for this exe build and is switched off - rather than showing a striker with
--  two goals and zero shots.
--
--  Rules, checked on every publishing tick (not just at discovery):
--    * a player's shots  >= his goals + own goals
--    * a player's goals  <= 12, shots <= 60, passes <= 400   (sanity caps)
--    * sum(player goals) >= scoreboard total (a goal is always somebody's)
--    * sum(player shots) >= scoreboard total (a goal came from a shot)
--  Any failure => m.stats_coherent = false => the HUD shows "-".
-- ---------------------------------------------------------------------------
function m.check_coherence()
    if not m.stats_base_ok() then
        m.stats_coherent = false
        m.coherence_reason = "stat table not validated for this build"
        return false
    end
    local goals, shots, players = 0, 0, 0
    for side = 0, 1 do
        for idx = 0, 10 do
            local r = m.read_player_stats(side, idx)
            if r then
                players = players + 1
                local pg = (r.goals or 0) + (r.own_goals or 0)
                -- An own goal is not a shot by that player, so only *his* goals
                -- have to be covered by his shot count. This is the "0 shots /
                -- 2 goals" symptom in reverse: ignoring own goals here used to
                -- flag a perfectly good table as incoherent the moment a
                -- defender put one in his own net.
                if (r.shots or 0) < (r.goals or 0) then
                    m.stats_coherent = false
                    m.coherence_reason = string.format(
                        "player %d/%d: %d shots but %d goals", side, idx,
                        r.shots or 0, r.goals or 0)
                    return false
                end
                goals = goals + pg
                shots = shots + (r.shots or 0)
            end
        end
    end
    if players < 20 then
        m.stats_coherent = false
        m.coherence_reason = "only " .. players .. " player records readable"
        return false
    end
    local board = (m.eng.score.home or 0) + (m.eng.score.away or 0)
    if goals < board then
        m.stats_coherent = false
        m.coherence_reason = string.format(
            "players claim %d goals, scoreboard says %d", goals, board)
        return false
    end
    if shots < board then
        m.stats_coherent = false
        m.coherence_reason = string.format(
            "players claim %d shots, scoreboard says %d goals", shots, board)
        return false
    end
    m.stats_coherent = true
    m.coherence_reason = ""
    return true
end

function m.validate_stats()
    if (m.reg.stats or 0) == 0 then return false end
    local players, goals, shots = 0, 0, 0
    for side = 0, 1 do
        for idx = 0, 10 do
            local r = m.read_player_stats(side, idx)
            if r then
                players = players + 1
                if r.shots < r.on_target then return false end
                if r.goals > 12 or r.shots > 60 or r.passes > 400 then return false end
                goals = goals + r.goals + r.own_goals
                shots = shots + r.shots
            end
        end
    end
    if players < 20 then return false end
    local board = (m.eng.score.home or 0) + (m.eng.score.away or 0)
               + (m.match.pk_home or 0) + (m.match.pk_away or 0)
    if goals < board then return false end
    if shots < board then return false end
    return true
end

-- ============================================================================
-- 10. Per-player stat records
-- ============================================================================
local function rec_addr(side, idx)
    if m.reg.stats == 0 then return nil end
    return m.reg.stats + OFF.REC_BASE + side * OFF.REC_SIDE + idx * OFF.REC_IDX
end
m.rec_addr = rec_addr

-- sum of the period buckets for stat kind `k`, buffer relative.
-- 8 buckets is the normal layout; anything else (only ever set by a calibration
-- file) takes the slow loop.
local function sum8(off)
    if BUCKETS ~= 8 then
        local total = 0
        for i = 0, BUCKETS - 1 do total = total + m.u32(off + i * 4) end
        return total
    end
    local a = m.u32(off)
    local b = m.u32(off + 4)
    local c = m.u32(off + 8)
    local d = m.u32(off + 12)
    local e = m.u32(off + 16)
    local f = m.u32(off + 20)
    local g = m.u32(off + 24)
    local h = m.u32(off + 28)
    return a + b + c + d + e + f + g + h
end

local HEAD_KINDS = 18  -- kinds 0 .. 17 in one read (goals .. on target)

-- Fast detection read: goals, own goals, assists, shots, on target.
-- Returns 5 numbers or nil.
local function read_head(side, idx)
    local a = rec_addr(side, idx)
    if not a then return nil end
    if not m.load(a + OFF.KIND_OFFSET, HEAD_KINDS * OFF.KIND_STRIDE) then return nil end
    local S = OFF.KIND_STRIDE
    return sum8(0 * S), sum8(1 * S), sum8(4 * S), sum8(6 * S), sum8(17 * S)
end

-- Full record read used for the popup, MOTM and the post-match screen.
function m.read_player_stats(side, idx)
    local a = rec_addr(side, idx)
    if not a then return nil end
    local kinds = 180
    if not m.load(a + OFF.KIND_OFFSET, kinds * OFF.KIND_STRIDE + 4) then return nil end
    local S = OFF.KIND_STRIDE
    local function k(name)
        return sum8(KIND[name] * S)
    end
    local rating = m.f32(KIND.rating * S)
    if rating < 1.0 or rating > 10.0 then rating = nil end
    return {
        goals = k("goals"),
        own_goals = k("own"),
        fk_goals = k("fk_goal"),
        pk_goals = k("pk_goal"),
        assists = k("assists"),
        shots = k("shots"),
        on_target = k("on_target"),
        passes = k("passes"),
        passes_ok = k("passes_ok"),
        tackles = k("tackles"),
        tackles_ok = k("tackles_ok"),
        clearances = k("clearances"),
        fouls = k("fouls"),
        offsides = k("offsides"),
        corners = k("corners"),
        dribbles = k("dribbles"),
        dribbles_ok = k("dribbles_ok"),
        touches = k("touches"),
        interceptions = k("interceptions"),
        blocks = k("blocks"),
        saves = k("saves"),
        rating = rating,
    }
end

-- Squad ids: mis + T_SQUAD + side*stride, 40 x u32 (roster order == stat idx)
function m.squad_id(side, idx)
    if m.match.mis == 0 then return nil end
    if not m.squad_cache then m.squad_cache = { {}, {} } end
    local side_t = m.squad_cache[side + 1]
    if side_t[idx] then return side_t[idx] end
    local addr = m.match.mis + OFF.TEAM_HOME + side * OFF.TEAM_STRIDE
                    + OFF.T_SQUAD + idx * 4
    local pid = m.read_u32(addr)
    if pid and pid > 0 and pid < 10000000 then
        side_t[idx] = pid
        return pid
    end
    return nil
end

-- XI slot (0..10) of squad index `idx`, or nil when the player is on the bench.
function m.xi_slot(side, idx)
    if m.match.mis == 0 then return nil end
    if not m.xi_cache then m.xi_cache = { {}, {} } end
    local side_t = m.xi_cache[side + 1]
    if side_t[idx] ~= nil then
        if side_t[idx] == -1 then return nil end
        return side_t[idx]
    end
    local base = m.match.mis + (side == 0 and OFF.XI_HOME or OFF.XI_AWAY)
    if not m.load(base, 11) then return nil end
    for slot = 0, 10 do
        if m.u8(slot) == idx then
            side_t[idx] = slot
            return slot
        end
    end
    side_t[idx] = -1
    return nil
end

-- ============================================================================
-- 11. Pitch positions (22 players, metres from the centre spot)
-- ============================================================================
m.pitch = { valid = false, dir = 1, players = {} }

local function read_pitch()
    if m.reg.pitch == 0 then return false end
    local base = m.reg.pitch + OFF.PITCH_BLOCK
    if not m.load(base, 22 * OFF.PITCH_ENTRY) then return false end
    local ok = 0
    for i = 0, 21 do
        local o = i * OFF.PITCH_ENTRY
        local x, y, z = m.f32(o), m.f32(o + 4), m.f32(o + 8)
        if abs(x) <= 70 and abs(y) <= 45 and z >= -2 and z <= 25 then
            m.pitch.players[i] = { x = x, y = y, z = z }
            ok = ok + 1
        else
            m.pitch.players[i] = nil
        end
    end
    m.pitch.valid = (ok >= 16)
    if m.pitch.valid then
        local gk = m.pitch.players[0]
        if gk and abs(gk.x) >= 25 then
            -- home keeper deep on the left => home attacks the +x goal
            m.pitch.dir = (gk.x < 0) and 1 or -1
        end
    end
    return m.pitch.valid
end

function m.player_xy(side, idx)
    if not m.pitch.valid then return nil end
    local slot = m.xi_slot(side, idx)
    if slot == nil then return nil end
    local entry = side * 11 + slot
    return m.pitch.players[entry]
end

-- ============================================================================
-- 12. Shot telemetry (ballistics + goal-mouth geometry)
-- ============================================================================
-- Pitch: 105 x 68 m centred on 0,0. Goals at x = +/-52.5, half width 3.66 m.
local GOAL_X = 52.5
local GOAL_HALF = 3.66
local GRAV = 9.81
local MPS_TO_MPH = 2.2369363
local M_TO_YD = 1.0936133
local M_TO_FT = 3.2808399

function m.xg(dist, angle_rad)
    local logit = -1.1 + 1.4 * angle_rad - 0.075 * dist
    local v = 1 / (1 + exp(-logit))
    return clamp(v, 0.02, 0.95)
end

-- Launch speed (m/s) from the player's kicking power + shot distance.
function m.shot_speed(dist, kpower)
    local kp = clamp(kpower or 78, 40, 99)
    local v = 20.5 + (kp - 40) * 0.28
    local df = clamp((dist - 11) / 30, 0, 1)
    v = v * (1 + df * 0.22)
    return v
end

-- Ballistic solve: elevation to hit (dist, height) with speed v.
function m.solve_elevation(dist, height, v)
    if dist < 0.5 then dist = 0.5 end
    local k = GRAV * dist * dist / (2 * v * v)
    local disc = dist * dist - 4 * k * (height + k)
    if disc < 0 then
        -- not reachable with this speed: aim flatter, let the ball come down late
        return atan(dist / (2 * k)), false
    end
    local u = (dist - sqrt(disc)) / (2 * k)
    return atan(u), true
end

-- Complete telemetry record for one shot.
--   side, idx   : shooter (stat record addressing)
--   outcome     : "goal" | "own_goal" | "on_target" | "off_target"
--   minute      : match minute (for the deterministic placement hash)
function m.telemetry(side, idx, outcome, minute, pid)
    local info = m.player_info(pid)
    local pos = m.player_xy(side, idx)
    local dir = m.pitch.dir or 1
    -- an own goal is finished into the *scorer's* own net, i.e. the opposite
    -- goal of the one he normally attacks
    local target_side = side
    if outcome == "own_goal" then target_side = 1 - side end
    local gx = (target_side == 0) and (GOAL_X * dir) or (-GOAL_X * dir)

    local x, y
    local source = "measured"
    if pos then
        x, y = pos.x, pos.y
    else
        -- Fallback: typical shooting position, 20 m out, slightly off centre.
        x = gx - dir * 20.0
        y = hrange(tostring(pid or idx), minute, -7, 7)
        source = "estimated"
    end
    -- Guard against a shooter standing behind his own goal line.
    if (gx - x) * dir < 2 then
        x = gx - dir * 8
        source = "estimated"
    end

    local dx = gx - x
    local dy = 0 - y
    local dist = sqrt(dx * dx + dy * dy)
    if dist < 1 then dist = 1 end

    -- angle subtended by the two posts as seen from the shooter
    local a1 = atan2(GOAL_HALF - y, dx)
    local a2 = atan2(-GOAL_HALF - y, dx)
    local angle = abs(a1 - a2)
    if angle > PI then angle = 2 * PI - angle end

    local xg = m.xg(dist, angle)

    -- Deterministic goal-face placement (metres from the centre of the goal)
    local salt = tostring(pid or 0) .. ":" .. tostring(minute or 0)
    local tx, ty
    if outcome == "goal" or outcome == "own_goal" then
        tx = hrange(salt, 1, -2.85, 2.85)
        ty = hrange(salt, 2, 0.15, 2.25)
    elseif outcome == "on_target" then
        tx = hrange(salt, 3, -3.25, 3.25)
        ty = hrange(salt, 4, 0.20, 2.10)
    else
        if h01(salt, 5) < 0.55 then
            tx = hrange(salt, 6, 3.9, 6.2) * (h01(salt, 7) < 0.5 and -1 or 1)
            ty = hrange(salt, 8, 0.1, 1.4)
        else
            tx = hrange(salt, 9, -2.6, 2.6)
            ty = hrange(salt, 10, 2.7, 4.6)
        end
    end

    -- Ballistics
    local v0 = m.shot_speed(dist, info and info.kpower or nil)
    local elev, reachable = m.solve_elevation(dist, ty, v0)
    if not reachable then
        v0 = v0 * 1.12
        elev = m.solve_elevation(dist, ty, v0)
    end
    local vx = v0 * cos(elev)
    local vz = v0 * sin(elev)
    local flight = dist / vx
    local apex = (vz * vz) / (2 * GRAV)
    local hang = flight

    -- 3D trajectory polyline (16 points, pitch coordinates in metres)
    local traj = {}
    local ux = dx / dist
    local uy = dy / dist
    local N = 15
    for i = 0, N do
        local t = flight * (i / N)
        local px = x + ux * vx * t
        local py = y + uy * vx * t
        local pz = vz * t - 0.5 * GRAV * t * t
        if pz < 0 then pz = 0 end
        traj[#traj + 1] = { round(px, 2), round(py, 2), round(pz, 2) }
    end

    -- Body part
    local body
    if ty > 1.85 and dist < 13 then
        body = "head"
    else
        local rightFoot = (y * dir) < 0
        body = rightFoot and "right_foot" or "left_foot"
    end

    return {
        speed_mps = v0,
        speed_mph = v0 * MPS_TO_MPH,
        speed_kmh = v0 * 3.6,
        distance_m = dist,
        distance_yd = dist * M_TO_YD,
        angle_deg = angle * 180 / PI,
        elevation_deg = elev * 180 / PI,
        apex_m = apex,
        apex_ft = apex * M_TO_FT,
        hang_s = hang,
        xg = xg,
        target_x = tx,
        target_y = ty,
        outcome = outcome,
        body = body,
        origin_source = source,
        origin_x = x,
        origin_y = y,
        traj = traj,
    }
end

-- ============================================================================
-- 13. Replay camera (rheight0 / rheight3 / rzoom)
-- ============================================================================
m.cam = {
    ok = false,
    addrs = {},       -- { h0 = addr, h3 = addr, zoom = addr }
    base = {},        -- baseline floats read at init
    last = {},        -- last values we wrote
    active = false,
    preset = 1,
}

local CAM_PATTERNS = {
    -- mov dword [rbp+disp8], 0.4f ; addss xmm0, xmm8 ; movss [rbp+disp8], xmm0
    h0 = {
        literal = "\xf3\x41\x0f\x58\xc0\xf3\x0f\x11\x45",
        check = function(buf, p)
            if p < 11 then return nil end
            if string.byte(buf, p - 10) ~= 0xC7 then return nil end
            if string.byte(buf, p - 9) ~= 0x45 then return nil end
            if string.sub(buf, p - 7, p - 4) ~= "\xcd\xcc\xcc\x3e" then return nil end
            return p - 10 + 3
        end,
        expect = 0.4,
    },
    -- f3 0f 58 e0 / f3 0f 11 46 14 / c7 46 10 66 66 a6 3f   (1.3f)
    h3 = {
        literal = "\xf3\x0f\x58\xe0\xf3\x0f\x11\x46\x14\xc7\x46\x10\x66\x66\xa6\x3f",
        check = function(buf, p)
            return p + 12
        end,
        expect = 1.3,
    },
    -- c7 46 30 c3 f5 28 3f   (0.66f)
    zoom = {
        literal = "\xc7\x46\x30\xc3\xf5\x28\x3f",
        check = function(buf, p)
            return p + 3
        end,
        expect = 0.66,
    },
}

local function scan_sections(patterns)
    local found = {}
    if not ffi_ok then return found end
    local pinfo = memory and memory.get_process_info and memory.get_process_info()
    if not pinfo or not pinfo.sections then return found end
    local CHUNK = 4 * 1024 * 1024
    local OVERLAP = 32

    for _, sec in ipairs(pinfo.sections) do
        local start = tonumber(ffi.cast("uint64_t", sec.start))
        local finish = tonumber(ffi.cast("uint64_t", sec.finish))
        if start and finish and finish > start then
            local off = 0
            while off < (finish - start) do
                local want = CHUNK
                if off + want > (finish - start) then want = (finish - start) - off end
                if want > OVERLAP then
                    local from = start + off
                    local back = math.min(off, OVERLAP)
                    local buf = m.read_big(from - back, want + back)
                    if buf then
                        local buf_start = from - back
                        for name, pat in pairs(patterns) do
                            if not found[name] then
                                local i = 1
                                while true do
                                    local p = string.find(buf, pat.literal, i, true)
                                    if not p then break end
                                    local rel = pat.check(buf, p)
                                    if rel then
                                        local addr = buf_start + rel - 1
                                        local v = m.read_f32(addr)
                                        if v and abs(v - pat.expect) < 0.001 then
                                            found[name] = addr
                                            log_msg(string.format(
                                                "replay cam %s @ %s (base %0.3f)",
                                                name, hex(addr), v))
                                            break
                                        end
                                    end
                                    i = p + 1
                                end
                            end
                        end
                    end
                end
                off = off + CHUNK
            end
        end
    end
    return found
end

local CAM_TARGETS = {
    [1] = { h0 = 0.28, h3 = 0.95, zoom = 0.56 },   -- cinematic low sweep
    [2] = { h0 = 0.62, h3 = 1.45, zoom = 0.82 },   -- elevated broadcast
    [3] = nil,
}

function m.cam_init()
    local enabled = cfg_i("replay_camera_enabled", 1) ~= 0
    m.cam.preset = clamp(cfg_i("replay_camera_preset", 1), 1, 3)

    -- preset 1 is the cinematic sweep and its three values are tunable
    CAM_TARGETS[1] = {
        h0 = clamp(cfg_f("replay_height_cam0", 0.28), 0.02, 2.0),
        h3 = clamp(cfg_f("replay_height_cam3", 0.95), 0.02, 4.0),
        zoom = clamp(cfg_f("replay_zoom", 0.56), 0.05, 2.0),
    }
    if not enabled or m.cam.preset == 3 then
        log_msg("replay camera: disabled by configuration")
        return
    end
    if not ffi_ok then
        log_msg("replay camera: FFI unavailable, skipping")
        return
    end

    local patterns = {}
    for name, pat in pairs(CAM_PATTERNS) do
        patterns[name] = pat
    end
    local found = scan_sections(patterns)
    local n = 0
    for name, addr in pairs(found) do
        m.cam.addrs[name] = addr
        m.cam.base[name] = m.read_f32(addr)
        m.cam.last[name] = m.cam.base[name]
        n = n + 1
    end
    m.cam.ok = (n >= 2)
    if not m.cam.ok then
        log_msg("replay camera: pattern scan found " .. tostring(n) ..
                "/3 values - leaving the game camera untouched")
    else
        log_msg(string.format("replay camera ready (%d/3 values, preset %d)",
            n, m.cam.preset))
    end
end

local function cam_write(name, value)
    local addr = m.cam.addrs[name]
    if not addr then return end
    local last = m.cam.last[name]
    if last and abs(last - value) < 0.0015 then return end
    m.cam.last[name] = value
    m.write_f32(addr, value)
end

function m.write_f32(addr, value)
    if m.sim then if m.sim_write then m.sim_write(addr, value) end; return true end
    -- 4 little-endian float bytes, built without FFI so this works even when
    -- luajit.ext.enabled is not set.
    local b = f32_bytes(value)
    return m.poke(addr, b)
end

-- IEEE-754 encode, pure Lua, so no cdef can fail here.
local LOG2 = math.log(2)
local function f32_bytes(v)
    if v ~= v then return string.char(0, 0, 0, 0) end        -- NaN -> 0
    local sign = 0
    if v < 0 then sign = 128; v = -v end
    if v == 0 then return string.char(0, 0, 0, 0) end
    local e = floor(math.log(v) / LOG2)
    if e < -126 then e = -126 end
    if e > 127 then return string.char(0, 0, 128, 127) end   -- cap: +inf
    local mant = floor((v / 2 ^ e - 1) * 8388608 + 0.5)
    if mant >= 8388608 then mant = 0; e = e + 1 end
    local expo = e + 127
    return string.char(mant % 256,
                       floor(mant / 256) % 256,
                       floor(mant / 65536) % 128 + (expo % 2) * 128,
                       sign + floor(expo / 2))
end

-- Write `len` bytes from string `s` at `addr`.
-- Sider's memory.write() is documented and does the page protection dance for
-- us (it is the same call kserv.lua/camera.lua have used for years), so the
-- module no longer calls VirtualProtect itself. Only the replay-camera floats
-- are ever written, and the original values are restored on restore/reload.
function m.poke(addr, s)
    if type(addr) ~= "number" or addr < 0x10000 then return false end
    if type(s) ~= "string" then return false end
    local len = #s
    if len <= 0 or len > 64 then return false end
    if m.sim then if m.sim_write then m.sim_write(addr, s) end; return true end
    if not mem_ok or type(MEM.write) ~= "function" then return false end
    if not (m.regions or m.build_regions(false)) then return false end
    if not m.in_region(addr, len) then return false end
    MEM.write(addr, s)
    return true
end

function m.cam_restore()
    if not m.cam.ok then return end
    for name, value in pairs(m.cam.base) do
        if m.cam.last[name] and abs(m.cam.last[name] - value) > 0.0005 then
            m.cam.last[name] = value
            m.write_f32(m.cam.addrs[name], value)
        end
    end
    m.cam.active = false
end

function m.cam_start(duration_s)
    if not m.cam.ok then return end
    m.cam.active = true
    m.cam.start_ms = now_ms()
    m.cam.dur_ms = (duration_s or 14) * 1000
end

local CAM_EASE_IN = 1200
local CAM_EASE_OUT = 900

function m.cam_update()
    if not m.cam.ok then return end
    if not m.cam.active then return end
    local t = now_ms() - (m.cam.start_ms or 0)
    local dur = m.cam.dur_ms or 0
    if t < 0 or t > dur then
        m.cam_restore()
        return
    end

    local targets = CAM_TARGETS[m.cam.preset] or CAM_TARGETS[1]
    local w
    if t < CAM_EASE_IN then
        w = smoothstep(t / CAM_EASE_IN)
    elseif t > dur - CAM_EASE_OUT then
        w = smoothstep((dur - t) / CAM_EASE_OUT)
    else
        w = 1
    end
    -- slow drift inside the replay so the shot never feels static
    local drift = 0
    if w >= 1 then
        drift = 0.06 * sin((t - CAM_EASE_IN) / 2200)
    end

    for name, target in pairs(targets) do
        local base = m.cam.base[name]
        if base then
            local v = lerp(base, target * (1 + drift), w)
            cam_write(name, v)
        end
    end
end

-- ============================================================================
-- 14. State file (state.json) + overlay text
-- ============================================================================
local function jstr(s)
    s = tostring(s)
    s = string.gsub(s, "\\", "\\\\")
    s = string.gsub(s, "\"", "\\\"")
    s = string.gsub(s, "[\r\n\t]", " ")
    s = string.gsub(s, "%c", "")
    return "\"" .. s .. "\""
end

local function jnum(v)
    if type(v) ~= "number" then return "0" end
    if v ~= v or v == math.huge or v == -math.huge then return "0" end
    if v == floor(v) and abs(v) < 1e15 then
        return string.format("%.0f", v)
    end
    return string.format("%.3f", v)
end

local function jbool(v)
    if v then return "true" end
    return "false"
end

local function jenc(v, out)
    local t = type(v)
    if t == "table" then
        local n = #v
        if n > 0 then
            out[#out + 1] = "["
            for i = 1, n do
                if i > 1 then out[#out + 1] = "," end
                jenc(v[i], out)
            end
            out[#out + 1] = "]"
        else
            out[#out + 1] = "{"
            local first = true
            for k, val in pairs(v) do
                if not first then out[#out + 1] = "," end
                first = false
                out[#out + 1] = jstr(k)
                out[#out + 1] = ":"
                jenc(val, out)
            end
            out[#out + 1] = "}"
        end
    elseif t == "number" then
        out[#out + 1] = jnum(v)
    elseif t == "boolean" then
        out[#out + 1] = jbool(v)
    elseif t == "nil" then
        out[#out + 1] = "null"
    else
        out[#out + 1] = jstr(v)
    end
end

function m.json_encode(v)
    local out = {}
    jenc(v, out)
    return table.concat(out, "")
end

m.state = {
    path = nil,
    tmp_path = nil,
    dir = nil,
    last_write = 0,
    last_seq = 0,
    errors = 0,
    writes_ok = 0,
    writes_failed = 0,
}

-- heartbeat bookkeeping (see write_heartbeat in section 20b)
m.hb = { last = 0, path = nil }

-- Create a folder. Only fs.make_dirs exists in Sider's fs library (fs.lua in
-- the Sider source) - it returns nil on success, or an error string, and
-- "Directory already exists" is a success for us.
local function ensure_dir(dir)
    if not dir then return false end
    if fs and type(fs.make_dirs) == "function" then
        local err = fs.make_dirs(dir)
        if err == nil then return true end
        if type(err) == "string" and string.find(err, "already exists") then
            return true
        end
        log_msg("fs.make_dirs(" .. dir .. ") -> " .. tostring(err))
    else
        log_once("nofs", "Sider's fs library is missing - the installer must " ..
                 "create content\\ngb-presentation by hand", 60000)
    end
    -- verify by trying to open a file for write in it
    local probe = dir .. "\\.ngb-write-test"
    local f = io.open(probe, "wb")
    if f then f:close()
        local junk = io.open(probe, "rb")
        if junk then junk:close() end
        return true
    end
    return false
end

m.ensure_dir = ensure_dir

function m.init_state_path(ctx)
    local dir = (ctx and ctx.sider_dir or "") .. "content\\ngb-presentation"
    if not ensure_dir(dir) then
        log_msg("WARN: could not create " .. dir .. " - the installer normally does this")
    end
    m.state.dir = dir
    m.state.path = dir .. "\\state.json"
    m.state.tmp_path = dir .. "\\state.json.tmp"
    m.hb.path = dir .. "\\heartbeat.txt"
    log_msg("state file: " .. tostring(m.state.path))
end

local function units_mph(mph, kmh)
    if (cfg.units == "metric") then
        return string.format("%.1f km/h", kmh)
    end
    return string.format("%.1f mph", mph)
end

local function units_dist(yd, mt)
    if cfg.units == "metric" then
        return string.format("%.1f m", mt)
    end
    return string.format("%.1f yd", yd)
end

local function units_height(ft, mt)
    if cfg.units == "metric" then
        return string.format("%.2f m", mt)
    end
    return string.format("%.2f ft", ft)
end

m.units_mph = units_mph
m.units_dist = units_dist
m.units_height = units_height

-- ============================================================================
-- 14b. Calibration probe
--
--  Off by default.  When switched on in the .ini it writes
--  content\\ngb-presentation\\probe.txt: the scoreboard as Sider reports it,
--  a hexdump of the SCOREBOARD_INFO block, and a map of the game's committed
--  memory regions.  That is everything needed to pin the per-player table of a
--  specific FL_2025.exe build down, instead of guessing at offsets.
-- ============================================================================
local function hexdump(buf, len, base)
    local out = {}
    for row = 0, math.floor((len - 1) / 16) do
        local line = string.format("%016X  ", (base or 0) + row * 16)
        local txt = ""
        for i = 0, 15 do
            local o = row * 16 + i
            if o < len then
                local b = string.byte(buf, o + 1)
                line = line .. string.format("%02X ", b)
                if b >= 32 and b < 127 then txt = txt .. string.char(b) else txt = txt .. "." end
            else
                line = line .. "   "
            end
        end
        out[#out + 1] = line .. " " .. txt
    end
    return table.concat(out, "\n")
end

-- ============================================================================
-- 14b2. Overlay heartbeat
-- ============================================================================
-- The companion writes <content>\ngb-presentation\overlay_alive.txt every two
-- seconds. Reading it here is what lets the mod answer "is the overlay actually
-- running?" instead of the player having to guess.
function m.watch_overlay(now)
    if not m.state.dir then return end
    if (now - (m.overlay_checked or 0)) < 2000 then return end
    m.overlay_checked = now
    local f = io.open(m.state.dir .. "\\overlay_alive.txt", "r")
    if not f then
        m.overlay_seen = m.overlay_seen      -- keep the last timestamp
        return
    end
    local text = f:read("*a") or ""
    f:close()
    if text == "" or text == m.overlay_text_seen then return end
    m.overlay_text_seen = text
    m.overlay_seen = now
    local ver, pid, up = string.match(text, "^(%d+%.%d+%.%d+)%s+pid%s+(%d+)%s+([%d%.]+)")
    if ver then
        m.overlay_info = { version = ver, pid = tonumber(pid) or 0, up = tonumber(up) or 0 }
    end
    log_once("overlaybeat", "overlay heartbeat: " .. string.gsub(text, "[\r\n]+", " "), 30000)
end

-- ============================================================================
-- 14c. Region dump (calibration input for tools/decode_probe.py)
-- ============================================================================
-- Writes <Sider>\content\ngb-presentation\probe_region.bin: the private stats
-- region byte for byte, plus a small .txt with the base address, the score and
-- the layout in force. The decoder reconstructs the record grid from the file
-- alone; nothing here changes what the mod displays.
function m.probe_dump(dir)
    if not ffi_ok or not dir then return false end
    if m.probe_dumped then return false end
    local base = m.reg.stats or 0
    if base == 0 then
        log_msg("region dump skipped: no stats region located yet")
        return false
    end
    local span = REGION_STATS_SIZE
    if span > 0x400000 then span = 0x400000 end
    local f = io.open(dir .. "\\probe_region.bin", "wb")
    if not f then
        log_msg("cannot write probe_region.bin")
        return false
    end
    local written = 0
    local chunk = 0x4000
    while written < span do
        local n = chunk
        if written + n > span then n = span - written end
        local bytes = m.read_big(base + written, n)
        if not bytes or #bytes < n then break end
        f:write(bytes)
        written = written + n
    end
    f:close()
    m.probe_dumped = true

    local meta = io.open(dir .. "\\probe_region.txt", "w")
    if meta then
        local L = m.layout()
        local h, a = current_score()
        meta:write("ngb region dump\n")
        meta:write(string.format("module %s\n", m.VERSION))
        meta:write(string.format("region_base %s\n", hex(base)))
        meta:write(string.format("size %d\n", written))
        meta:write(string.format("score %d %d\n", h, a))
        meta:write(string.format(
            "layout rec_base %s side %s idx %s kind %s kind_off %s buckets %d\n",
            hex(L.rec_base), hex(L.side), hex(L.idx), hex(L.kind), hex(L.kind_off), L.buckets))
        meta:write("\nall offsets below are relative to region_base; hand the .bin and\n")
        meta:write("this .txt to tools/decode_probe.py (or send them to the author).\n")
        meta:close()
    end
    log_msg(string.format("region dump written: base %s  %d bytes", hex(base), written))
    return true
end

function m.probe_write(tag)
    if not m.state.dir then return end
    local f = io.open(m.state.dir .. "\\probe.txt", "a")
    if not f then
        log_once("probeopen", "cannot write probe.txt", 30000)
        return false
    end
    f:write("\n==== " .. os.date("%Y-%m-%d %H:%M:%S") .. "  " .. tostring(tag) .. " ====\n")
    f:write("module " .. m.VERSION .. "  ffi=" .. tostring(ffi_ok) .. "\n")
    local st = nil
    if match and match.stats then st = match.stats() end
    if st then
        f:write(string.format("score %d-%d  pk %s-%s  period %s  clock %s:%s  added %s  ptr %s\n",
            tonumber(st.home_score) or -1, tonumber(st.away_score) or -1,
            tostring(st.pk_home_score), tostring(st.pk_away_score),
            tostring(st.period), tostring(st.clock_minutes), tostring(st.clock_seconds),
            tostring(st.added_minutes), tostring(st.ptr)))
    else
        f:write("match.stats() returned nil (match-stats.enabled = " ..
                tostring(m.eng.ini_ok) .. ")\n")
    end
    f:write(string.format("guessed stats region %s  pitch region %s  validated %s\n",
        hex(m.reg.stats or 0), hex(m.reg.pitch or 0), tostring(m.stats_validated)))

    -- the layout currently in force, so a decoder knows what was already tried
    local L = m.layout()
    f:write(string.format("LAYOUT rec_base %s  side %s  idx %s  kind %s  kind_off %s  buckets %d\n",
        hex(L.rec_base), hex(L.side), hex(L.idx), hex(L.kind), hex(L.kind_off), L.buckets))

    -- one line per squad slot: what the current layout decodes to
    if m.reg.stats and m.reg.stats ~= 0 then
        f:write("PLAYERS side idx goals own assists shots on_target passes touches rating\n")
        for side = 0, 1 do
            for idx = 0, 39 do
                local ps = m.read_player_stats(side, idx)
                if ps then
                    f:write(string.format("%d %d %d %d %d %d %d %d %d %s\n", side, idx,
                        ps.goals or 0, ps.own_goals or 0, ps.assists or 0, ps.shots or 0,
                        ps.on_target or 0, ps.passes or 0, ps.touches or 0,
                        ps.rating and string.format("%.2f", ps.rating) or "nil"))
                end
            end
        end
    end

    -- raw dump, for tools/decode_probe.py (probe_dump_region = 1)
    if cfg_i("probe_dump_region", 0) ~= 0 then m.probe_dump(m.state.dir) end
    local buf, sci = nil, m.match.sci
    if sci and sci ~= 0 then
        buf = m.read_big(sci, 0x200)
        if buf then
            f:write("SCOREBOARD_INFO @ " .. hex(sci) .. "\n" .. hexdump(buf, 0x200, sci) .. "\n")
        end
    end
    local rs = m.regions
    if rs then
        f:write("mapped regions (from memory.get_process_info)\n")
        for i = 1, #rs do
            local r = rs[i]
            f:write(string.format("%016X - %016X  %s\n", r.start, r.finish,
                tostring(r.name or "")))
        end
    end
    if m.heap_anchor then
        f:write(string.format("heap anchor: %016X\n", m.heap_anchor))
    end
    f:close()
    log_msg("probe written: " .. tostring(m.state.dir) .. "\\probe.txt")
    return true
end

-- ============================================================================
-- 15. Events (goal / shot / MOTM)
-- ============================================================================
m.ev = nil          -- active event
m.ev_id = 0
m.last_ev = nil
m.ev_hist = {}      -- ring buffer for the log / diagnostics

local function push_event(kind, side, idx, extra)
    m.ev_id = m.ev_id + 1
    local ev = {
        id = m.ev_id,
        kind = kind,
        side = side,
        idx = idx,
        started = now_ms(),
        duration = 0,
        remaining = 0,
        seq = m.ev_id,
    }
    for k, v in pairs(extra or {}) do ev[k] = v end
    m.ev = ev
    m.last_ev = ev
    m.ev_hist[#m.ev_hist + 1] = ev
    if #m.ev_hist > 32 then table.remove(m.ev_hist, 1) end
    return ev
end

m.push_event = push_event

-- ---------------------------------------------------------------------------
--  Toast channel (hotkey confirmations, assist credit, hat-trick callouts).
--  Kept separate from m.ev so a notification never replaces a card.
-- ---------------------------------------------------------------------------
m.toast = nil
m.toast_seq = 0

local function set_toast(text, kind, hold)
    if not text or text == "" then return end
    m.toast_seq = m.toast_seq + 1
    m.toast = {
        text = tostring(text),
        kind = kind or "info",
        hold = clamp(cfg_f("milestone_toast_duration", 4.5), 1.0, 12.0),
        seq = m.toast_seq,
        until_ms = now_ms() + (hold or clamp(cfg_f("milestone_toast_duration", 4.5), 1.0, 12.0)) * 1000,
    }
    log_msg("toast: " .. tostring(text))
end

m.set_toast = set_toast

local function presentation_on()
    return cfg_i("presentation_enabled", 1) ~= 0
end

m.presentation_on = presentation_on


local function player_snapshot(side, idx)
    local pid = m.squad_id(side, idx)
    local info = m.player_info(pid)
    local st = m.read_player_stats(side, idx)
    local name = (info and info.name) or ("PLAYER " .. tostring(idx + 1))
    local shirt = (info and info.shirt) or 0
    local pos = (info and info.pos) or ""
    if cfg_i("show_position", 1) == 0 then pos = "" end
    local rating = st and st.rating or nil
    note_seen(pid, m.match.clock_min)
    local mins, exact = minutes_for(pid)
    return {
        pid = pid or 0,
        minutes = mins or 0,
        minutes_exact = exact,
        name = string.upper(name),
        shirt = shirt,
        pos = pos,
        rating = rating or 0,
        goals = st and (st.goals + st.own_goals) or 0,
        goals_only = st and st.goals or 0,
        assists = st and st.assists or 0,
        ga = st and ((st.goals + st.own_goals) + st.assists) or 0,
        shots = st and st.shots or 0,
        on_target = st and st.on_target or 0,
        passes = st and st.passes or 0,
        passes_ok = st and st.passes_ok or 0,
        tackles_ok = st and st.tackles_ok or 0,
        dribbles_ok = st and st.dribbles_ok or 0,
        touches = st and st.touches or 0,
        saves = st and st.saves or 0,
        interceptions = st and st.interceptions or 0,
    }
end

m.player_snapshot = player_snapshot

-- ---------------------------------------------------------------------------
--  Milestones (first goal / brace / hat-trick / bigger hauls)
-- ---------------------------------------------------------------------------
local function milestone_for(goals_this_match, match_goals)
    if not goals_this_match or goals_this_match <= 0 then return nil end
    if goals_this_match >= 5 then
        return { key = "haul", label = tostring(goals_this_match) .. " GOALS", tone = "gold" }
    end
    if goals_this_match == 4 then return { key = "four", label = "4 GOALS", tone = "gold" } end
    if goals_this_match == 3 then return { key = "hat_trick", label = "HAT-TRICK", tone = "gold" } end
    if goals_this_match == 2 then return { key = "brace", label = "BRACE", tone = "accent" } end
    if (match_goals or 0) <= 1 then return { key = "opener", label = "OPENER", tone = "accent" } end
    return { key = "first", label = "FIRST GOAL", tone = "accent" }
end

m.milestone_for = milestone_for

local function team_of(side)
    local t = m.match[side == 0 and "home" or "away"]
    return { name = t.name, abbr = t.abbr, color = t.color or "#D8F26B", side = side }
end

-- Accumulated per player "broadcast" extras (peak shot speed, total xG).
m.fx = {}

local function fx_for(pid)
    local f = m.fx[pid]
    if not f then
        f = { max_mph = 0, xg = 0, shots = 0, best = nil }
        m.fx[pid] = f
    end
    return f
end

-- ---- goal / shot handling -------------------------------------------------
local function fire_shot_event(side, idx, outcome, shot_stats)
    local p = player_snapshot(side, idx)
    local minute = m.match.clock_min
    local tel = m.telemetry(side, idx, outcome, minute, p.pid)
    local fx = fx_for(p.pid)
    if tel.speed_mph > fx.max_mph then
        fx.max_mph = tel.speed_mph
        fx.best = tel
    end
    fx.xg = fx.xg + tel.xg
    fx.shots = fx.shots + 1

    local dur = cfg_f("shot_popup_duration", 6.5)
    local is_goal = (outcome == "goal" or outcome == "own_goal")
    if is_goal then
        dur = cfg_f("goal_telemetry_duration", 13.0)
    end

    if not presentation_on() then
        log_msg("presentation off - event not displayed")
        return nil
    end

    -- assist credit: taken from the same poll as the goal (see detect_events)
    local assist = nil
    if is_goal and outcome == "goal" and shot_stats and shot_stats.assist_side then
        local ai = m.player_info(m.squad_id(shot_stats.assist_side, shot_stats.assist_idx))
        if ai then assist = { name = string.upper(ai.name), shirt = ai.shirt or 0 } end
    end

    local ev = push_event(is_goal and "goal" or "shot", side, idx, {
        player = p,
        team = team_of(side),
        shot = tel,
        stats = shot_stats,
        assist = assist,
        duration = dur,
        remaining = dur,
    })
    if is_goal then
        -- this goal has been announced, so a later scoreboard jump is the board
        -- catching up, not a second goal
        local credited = (outcome == "own_goal") and (1 - side) or side
        local key = (credited == 0) and "home" or "away"
        m.eng.unconfirmed[key] = (m.eng.unconfirmed[key] or 0) + 1
        m.eng.fallback = nil

        -- let the celebration breathe for a moment, then show the card as the
        -- replay starts (0 disables the delay)
        ev.show_at = ev.started + clamp(cfg_f("goal_telemetry_delay", 1.5), 0, 8) * 1000
        if outcome == "goal" then
            local total = (m.match.home.score or 0) + (m.match.away.score or 0)
            ev.milestone = milestone_for(p.goals_only or 0, total)
        end
        if assist and cfg_i("milestone_toast_enabled", 1) ~= 0 then
            set_toast("ASSIST  |  " .. assist.name, "assist")
        end
        if ev.milestone and ev.milestone.key == "hat_trick"
           and cfg_i("milestone_toast_enabled", 1) ~= 0 then
            set_toast("HAT-TRICK  |  " .. p.name, "milestone")
        end
    end
    log_msg(string.format("%s  %s  %s  %s  %0.1f mph  xG %0.2f",
        is_goal and "GOAL" or "SHOT", string.upper(m.match[side == 0 and "home" or "away"].abbr or "?"),
        p.name, tel.outcome, tel.speed_mph, tel.xg))

    if is_goal then
        m.cam_start(dur)
        m.goal_window_until = now_ms() + (cfg_f("replay_window_max", 45) * 1000)
    end
    return ev
end

m.fire_shot_event = fire_shot_event

-- ============================================================================
-- 15b. Goals, half time and full time  (all fed by the scoreboard + hook)
-- ============================================================================
local function score_line_text(h, a)
    return tostring(h) .. " - " .. tostring(a)
end
m.score_line_text = score_line_text

local function scorers_copy()
    local out = {}
    for i = 1, #m.scorers do
        local g = m.scorers[i]
        out[i] = { name = g.name, side = g.side, minute = g.minute, kind = g.kind or "goal" }
    end
    return out
end

-- one goal, presented
function m.goal_hook(g)
    if not presentation_on() then
        log_msg("presentation off - goal card not displayed")
        return nil
    end
    local now = now_ms()
    local side = (tonumber(g.side) == 1) and 1 or 0
    local name = clean_name(g.name or "")
    local pid = tonumber(g.pid) or 0
    local minute = tonumber(g.minute) or m.match.clock_min or 0
    local own = (g.kind == "own_goal")

    if pid ~= 0 then
        m.tally[pid] = (m.tally[pid] or 0) + 1
    end
    local tally = (pid ~= 0) and m.tally[pid] or 0
    m.tally_score.home = m.tally_score.home or 0
    m.tally_score.away = m.tally_score.away or 0
    if g.counted ~= false then
        local credited = side
        if own then
            if side == 0 then m.tally_score.away = m.tally_score.away + 1
            else m.tally_score.home = m.tally_score.home + 1 end
            credited = 1 - side          -- an own goal credits the other side
        else
            if side == 0 then m.tally_score.home = m.tally_score.home + 1
            else m.tally_score.away = m.tally_score.away + 1 end
        end
        -- remember it, so the scoreboard catching up later is not treated as a
        -- goal without a hook (that was the duplicate scorer in 1.2.0)
        m.eng.unconfirmed[credited == 0 and "home" or "away"] =
            (m.eng.unconfirmed[credited == 0 and "home" or "away"] or 0) + 1
        m.eng.fallback = nil
    end

    local h, a = current_score()
    local total = h + a
    m.scorers[#m.scorers + 1] = {
        name = name, side = (side == 0) and "home" or "away",
        minute = minute, kind = own and "own_goal" or "goal",
    }
    m.eng.goals = (m.eng.goals or 0) + 1
    m.eng.last_goal_at = now
    m.eng.last_goal_name = name

    local dur = cfg_f("goal_telemetry_duration", 13.0)
    local milestone = nil
    if not own and tally > 0 then
        milestone = milestone_for(tally, total)
    end

    local ev = push_event("goal", side, nil, {
        player_known = (name ~= ""),
        player = {
            name = string.upper(name),
            shirt = 0, pos = "", rating = 0,
            minutes = minute, minutes_exact = true,
            pid = pid,
        },
        team = team_of(side),
        minute = minute,
        score = { home = h, away = a },
        score_line = score_line_text(h, a),
        tally = tally,
        kind_detail = own and "own_goal" or "goal",
        milestone = milestone,
        duration = dur,
        remaining = dur,
    })
    ev.show_at = ev.started + clamp(cfg_f("goal_telemetry_delay", 1.2), 0, 8) * 1000

    if milestone and cfg_i("milestone_toast_enabled", 1) ~= 0
       and (milestone.key == "hat_trick" or milestone.key == "haul") then
        set_toast(milestone.label .. "  |  " .. string.upper(name), "milestone")
    end

    log_msg(string.format("GOAL  %s  %s  %d'  %s", side == 0 and "home" or "away",
        name ~= "" and name or "(scorer unknown)", minute, score_line_text(h, a)))

    if cfg_i("probe_enabled", 0) ~= 0 then
        m.probe_write("goal " .. tostring(name) .. " " .. string.upper(tostring(m.match[side == 0 and "home" or "away"].abbr or "")))
    end

    if cfg_i("replay_camera_enabled", 1) ~= 0 then
        m.cam_start(dur)
    end
    m.goal_window_until = now + (cfg_f("replay_window_max", 45) * 1000)
    return ev
end

-- a goal the scoreboard reported but the hook did not: show it without a name
function m.goal_fallback(side)
    return m.goal_hook({ side = side, name = "", pid = 0,
                         minute = m.match.clock_min, kind = "goal", counted = false })
end

-- half time / full time
function m.show_result(kind, extra)
    if cfg_i("result_card_enabled", 1) == 0 then return nil end
    if not presentation_on() then return nil end
    local h, a = current_score()
    local dur = cfg_f("result_card_duration", 9.0)
    local ev = push_event("fulltime", 0, nil, {
        result = kind,
        score = { home = h, away = a },
        score_line = score_line_text(h, a),
        scorers = scorers_copy(),
        pk = { home = m.match.pk_home or 0, away = m.match.pk_away or 0 },
        duration = dur,
        remaining = dur,
    })
    log_msg(string.format("%s  %s", string.upper(kind), score_line_text(h, a)))
    return ev
end

-- scoreboard watcher: catches a goal whose hook did not fire, and a reset.
--
-- Counting, not timing: the hook is the authority. Every hook goal adds one to
-- m.eng.unconfirmed[side], and a scoreboard jump that is covered by those
-- counters is simply the board catching up - which is exactly what happens in
-- FL25, where the score changes several seconds after the celebration. Only a
-- jump the hook cannot explain becomes a card, and even then it waits
-- goal_fallback_delay_ms so a slow hook can still claim it.
local function watch_scoreboard(now)
    if not m.eng.ok then return end
    local h, a = m.eng.score.home or 0, m.eng.score.away or 0
    local ph, pa = m.eng.prev.home or 0, m.eng.prev.away or 0
    if h < ph or a < pa then
        -- score went backwards: a new match (or a VAR reversal). re-baseline.
        m.eng.prev.home, m.eng.prev.away = h, a
        m.eng.unconfirmed.home, m.eng.unconfirmed.away = 0, 0
        m.eng.fallback = nil
        if h == 0 and a == 0 then
            m.tally_score.home, m.tally_score.away = 0, 0
            m.scorers = {}
            m.tally = {}
            m.eng.goals = 0
            m.ft_shown = false
        end
        return
    end
    if h == ph and a == pa then return end

    local dh, da = h - ph, a - pa
    m.eng.prev.home, m.eng.prev.away = h, a

    -- goals the hook already announced are not news
    local used_h = math.min(dh, m.eng.unconfirmed.home or 0)
    m.eng.unconfirmed.home = (m.eng.unconfirmed.home or 0) - used_h
    dh = dh - used_h
    local used_a = math.min(da, m.eng.unconfirmed.away or 0)
    m.eng.unconfirmed.away = (m.eng.unconfirmed.away or 0) - used_a
    da = da - used_a
    if dh <= 0 and da <= 0 then
        m.eng.fallback = nil
        return
    end

    local side = (dh > 0) and 0 or 1
    m.eng.fallback = { side = side, at = now }
    log_msg(string.format("scoreboard moved to %d-%d without a hook yet - waiting %d ms",
        h, a, cfg_i("goal_fallback_delay_ms", 2500)))
end

-- called from the tick: show the unnamed card only if the hook never arrived
local function flush_fallback(now)
    local f = m.eng.fallback
    if not f then return end
    local wait = cfg_i("goal_fallback_delay_ms", 2500)
    if wait < 0 then wait = 0 end
    if (now - f.at) < wait then return end
    m.eng.fallback = nil
    log_msg("scoreboard goal without a hook event - showing an unnamed goal card")
    m.goal_fallback(f.side)
end

-- half time / full time watcher
local function watch_period(now)
    if not m.eng.ok then return end
    local p = m.match.period or 0
    local prev = m.eng.prev.period or -1
    if p ~= prev then
        if prev == 1 and p == 2 and cfg_i("result_card_enabled", 1) ~= 0 then
            m.show_result("half_time")
        end
        m.eng.prev.period = p
    end
    if cfg_i("result_card_enabled", 1) ~= 0 and not m.ft_shown then
        local limit = (p >= 3) and 120 or 90
        -- the clock stopping is the signal, because it is observable; the
        -- scoreboard's own "clock is running" byte differs between builds
        local frozen = (now - (m.match.clock_changed_at or 0)) > 8000
        if p >= 2 and (m.match.clock_min or 0) >= limit and frozen and not m.match.paused then
            if not m.ft_at then m.ft_at = now end
            if (now - m.ft_at) > 1500 then
                m.ft_shown = true
                m.show_result("full_time")
            end
        end
    end
end


-- ---- MOTM -----------------------------------------------------------------
m.motm = nil

local function composite_rating(st)
    if st.rating then return st.rating end
    local goals = st.goals + st.own_goals
    local r = 6.0
    r = r + goals * 0.85 + st.assists * 0.55
    r = r + st.on_target * 0.10 + (st.shots - st.on_target) * 0.03
    if st.passes > 0 then
        r = r + (st.passes_ok / st.passes - 0.75) * 1.1
    end
    r = r + st.tackles_ok * 0.07 + st.dribbles_ok * 0.03
    r = r + st.saves * 0.12 + st.interceptions * 0.02
    if st.touches > 0 then
        r = r + math.min(st.touches, 90) / 900
    end
    return clamp(r, 3.0, 9.9)
end

function m.motm_score(st, side, won)
    local goals = st.goals + st.own_goals
    local s = composite_rating(st) * 10
    s = s + goals * 12 + st.assists * 7
    s = s + st.on_target * 1.2 + (st.shots - st.on_target) * 0.3
    if st.passes > 0 then
        local pct = st.passes_ok / st.passes * 100
        s = s + st.passes_ok * 0.06 + (pct - 70) * 0.15
    end
    s = s + st.tackles_ok * 1.0 + st.dribbles_ok * 0.5 + st.saves * 2.5
    s = s + st.interceptions * 0.25
    if won then s = s + 3 end
    return s
end

function m.compute_motm()
    local best, best_score, best_side, best_idx, best_stats = nil, -1e9, 0, 0, nil
    local home_s, away_s = m.match.home.score, m.match.away.score
    for side = 0, 1 do
        local won = (side == 0 and home_s > away_s) or (side == 1 and away_s > home_s)
        for idx = 0, 39 do
            local st = m.read_player_stats(side, idx)
            if st and (st.touches > 0 or st.passes > 0) then
                local sc = m.motm_score(st, side, won)
                if sc > best_score then
                    best_score, best_side, best_idx, best_stats = sc, side, idx, st
                end
            end
        end
    end
    if not best_stats then
        return nil
    end
    local p = player_snapshot(best_side, best_idx)
    local fx = fx_for(p.pid)
    p.rating = best_stats.rating or composite_rating(best_stats)
    local pass_pct = 0
    if best_stats.passes > 0 then
        pass_pct = best_stats.passes_ok / best_stats.passes * 100
    end
    local motm = {
        player = p,
        team = team_of(best_side),
        side = best_side,
        score = best_score,
        rating = p.rating,
        stats = {
            goals = best_stats.goals + best_stats.own_goals,
            assists = best_stats.assists,
            ga = (best_stats.goals + best_stats.own_goals) + best_stats.assists,
            shots = best_stats.shots,
            on_target = best_stats.on_target,
            passes = best_stats.passes,
            passes_ok = best_stats.passes_ok,
            pass_pct = pass_pct,
            tackles_ok = best_stats.tackles_ok,
            tackles = best_stats.tackles,
            dribbles_ok = best_stats.dribbles_ok,
            touches = best_stats.touches,
            saves = best_stats.saves,
            interceptions = best_stats.interceptions,
            clearances = best_stats.clearances,
            peak_mph = fx.max_mph,
            xg = fx.xg,
        },
        score_line = string.format("%s %d - %d %s",
            m.match.home.name, m.match.home.score, m.match.away.score, m.match.away.name),
    }
    return motm
end

function m.show_motm()
    local m_ = m.compute_motm()
    if not m_ then
        log_once("nomotm", "MOTM: no player with recorded minutes", 20000)
        return
    end
    m.motm = m_
    local dur = cfg_f("motm_card_duration", 22.0)
    push_event("motm", m_.side, 0, {
        player = m_.player,
        team = m_.team,
        stats = m_.stats,
        motm = m_,
        duration = dur,
        remaining = dur,
    })
    log_msg("MOTM: " .. m_.player.name .. " (" .. m_.team.abbr ..
            ") rating " .. string.format("%0.1f", m_.player.rating))
end

-- ============================================================================
-- 16. Polling / detection loop
-- ============================================================================
m.ps = { [0] = {}, [1] = {} }
m.baselined = false
m.poll = { last_stats = 0, last_pos = 0, last_state = 0, last_match = 0 }

local function detect_events()
    if not m.player_stats_ok() then return end
    local best = nil
    local assist_rises = {}
    for side = 0, 1 do
        for idx = 0, 39 do
            local g, og, as, sh, ot = read_head(side, idx)
            if g then
                local prev = m.ps[side][idx]
                m.ps[side][idx] = { g = g, og = og, as = as, sh = sh, ot = ot }
                if prev and m.baselined then
                    if as > prev.as then
                        assist_rises[#assist_rises + 1] = { side = side, idx = idx }
                    end
                    -- priority: goal > own goal > shot
                    if g > prev.g then
                        if not best or best.rank < 3 then
                            best = { rank = 3, side = side, idx = idx, kind = "goal" }
                        end
                    elseif og > prev.og then
                        if not best or best.rank < 2 then
                            best = { rank = 2, side = side, idx = idx, kind = "own_goal" }
                        end
                    elseif sh > prev.sh then
                        if not best or best.rank < 1 then
                            best = { rank = 1, side = side, idx = idx, kind = "shot",
                                     ot_rise = (ot > prev.ot) }
                        end
                    end
                end
            end
        end
    end
    if not m.baselined then
        m.baselined = true
        log_msg("stat baseline captured")
        return
    end
    if not best then return end

    -- pick up the full stat line for the popup (shots / G / A totals)
    local st = m.read_player_stats(best.side, best.idx) or {}
    local stats = {
        shots = st.shots or 0,
        on_target = st.on_target or 0,
        goals = (st.goals or 0) + (st.own_goals or 0),
        assists = st.assists or 0,
    }
    stats.ga = stats.goals + stats.assists

    -- an assist credited in the same poll and on the scoring side belongs to
    -- this goal; more than one candidate means we cannot be sure, so we stay quiet
    if best.kind == "goal" then
        local cands = {}
        for i = 1, #assist_rises do
            local a = assist_rises[i]
            if a.side == best.side and not (a.side == best.side and a.idx == best.idx) then
                cands[#cands + 1] = a
            end
        end
        if #cands == 1 then
            stats.assist_side = cands[1].side
            stats.assist_idx = cands[1].idx
        end
    end

    local outcome
    if best.kind == "goal" then
        outcome = "goal"
    elseif best.kind == "own_goal" then
        outcome = "own_goal"
    else
        outcome = best.ot_rise and "on_target" or "off_target"
    end

    if best.kind == "shot" and cfg_i("shot_popup_enabled", 1) == 0 then
        return
    end
    fire_shot_event(best.side, best.idx, outcome, stats)
end

-- ---- post-match detection -------------------------------------------------
m.post = { seen = false, flow_at = 0, shown = false }

local function check_post_match(now)
    if m.post.shown then return end
    if cfg_i("motm_card_enabled", 1) == 0 then return end
    -- full time: clock past 90 (or 120 with extra time), stopped, not paused
    local live_done = false
    if m.match.valid and m.match.clock_min > 0 then
        local limit = (m.match.period >= 3) and 120 or 90
        if m.match.clock_min >= limit and not m.match.running and not m.match.paused then
            live_done = true
        end
    end
    if m.post.seen or live_done then
        if not m.post.seen then m.post.seen = true end
        if m.post.flow_at == 0 then m.post.flow_at = now end
        if (now - m.post.flow_at) > 2600 then
            m.post.shown = true
            m.show_motm()
        end
    end
end

-- ---- state file -----------------------------------------------------------
local function build_state(now)
    local st = {
        v = m.STATE_VERSION,
        seq = m.state.last_seq + 1,
        ts = now,
        module = m.NAME,
        version = m.VERSION,
        hud = {
            enabled = (cfg_i("companion_hud_enabled", 1) ~= 0),
            master = presentation_on(),
            style = clamp(cfg_i("presentation_style", 0), 0, 2),
            analysis = (cfg_i("shot_analysis_enabled", 1) ~= 0),
            units = (cfg.units == "metric") and "metric" or "imperial",
            scorebug = (cfg_i("show_scorebug", 1) ~= 0),
            credit = (cfg_i("credit_line", 1) ~= 0) and m.BRAND or "",
            author = m.AUTHOR,
            tagline = m.TAGLINE,
            scale_hint = 1.0,
        },
        -- problem 3: the process the renderer/C# companion must attach to.
        -- pid/exe are read from inside the game; hwnd/backbuffer come from the
        -- DLL renderer (the only component that sees the swapchain). Empty
        -- strings, never guesses, when a value is unknown.
        game = (function()
            -- m.* lookup at call time: this block is defined before the
            -- renderer section that supplies the reader
            local rep = (m.read_render_report and m.read_render_report()) or {}
            return {
                pid = m.ident.pid or 0,
                exe = m.ident.exe or "",
                exe_path = m.ident.path or "",
                pid_source = m.ident.source or "unknown",
                hwnd = rep.hwnd or "",
                backbuffer = rep.backbuffer or "",
                renderer_fps = rep.fps or "",
                renderer_frames = rep.frames or "",
                renderer_enabled = rep.enabled or "",
            }
        end)(),
        -- schema v4: everything the renderer/diagnostics need to say "what is
        -- actually running". Never guessed: absent means unknown.
        diag = {
            schema = m.STATE_VERSION,
            module = m.VERSION,
            lua = tostring(_VERSION),
            luajit = (jit and jit.version) or "",
            ffi = ffi_ok,
            mem_lib = mem_ok,
            match_lib = (match ~= nil and type(match.stats) == "function"),
            renderer = m.renderer.state,
            renderer_detail = m.renderer.detail,
            started_at = m.started_at or 0,
            ticks = m.ev_stat.tick or 0,
            tick_source = m.ev_stat.ticks_from or "",
            state_writes = m.ev_stat.state_writes or 0,
            state_writes_ok = m.state.writes_ok or 0,
            state_writes_failed = m.state.writes_failed or 0,
            last_error = m.ev_stat.last_error or "",
            events = m.event_snapshot(),
        },
        status = {
            ffi = ffi_ok,
            stats_region = (m.reg.stats ~= 0),
            pitch_region = (m.reg.pitch ~= 0),
            camera = m.cam.ok,
            player_db = m.db_ready,
            names = m.db_ready and "Player.bin" or "none",
            events = m.ev_id,
            overlay_visible = (now - (m.overlay_seen or 0)) < 400,
            style = clamp(cfg_i("presentation_style", 0), 0, 2),
            analysis = (cfg_i("shot_analysis_enabled", 1) ~= 0),
            -- what this build can actually deliver, so the HUD can hide what
            -- it cannot fill in instead of printing zeros
            data = {
                scoreboard = m.data_source(),
                clock = m.data_source(),
                player_stats = m.player_stats_ok(),
                scorer_hook = m.eng.lib,
                match_stats_ini = m.eng.ini_ok,
                goals = m.eng.goals or 0,
                player_stats_ok = m.player_stats_ok(),
                overlay_alive = (now_ms() - (m.overlay_seen or 0)) < 6000,
                overlay_version = (m.overlay_info and m.overlay_info.version) or "",
                -- does the stat table agree with the scoreboard right now?
                -- (shots >= goals on every player, team totals >= the board).
                -- When this is false the HUD prints "-" instead of a number.
                stats_coherent = m.stats_coherent == true,
            },
        },
        match = {
            clock = m.clock_str(),
            period = m.match.period,
            stage = m.match.stage,
            live = (m.data_source() == "sider") and not m.match.paused,
            home = {
                name = m.match.home.name,
                abbr = m.match.home.abbr,
                score = m.match.home.score,
                color = m.match.home.color or "#4FC3F7",
            },
            away = {
                name = m.match.away.name,
                abbr = m.match.away.abbr,
                score = m.match.away.score,
                color = m.match.away.color or "#FF7043",
            },
            score_line = score_line_text(m.match.home.score or 0, m.match.away.score or 0),
            pk_home = m.match.pk_home or 0,
            pk_away = m.match.pk_away or 0,
        },
        scorers = scorers_copy(),
    }

    if m.toast then
        st.hud.toast = {
            text = m.toast.text,
            kind = m.toast.kind,
            seq = m.toast.seq,
            hold = m.toast.hold,
        }
    end

    local ev = m.ev
    if ev then
        local p = ev.player or {}
        local s = ev.stats or {}
        local e = {
            id = ev.id,
            kind = ev.kind,
            remaining = round(ev.remaining or 0, 2),
            duration = ev.duration or 0,
            side = (ev.side == 0) and "home" or "away",
            minute = ev.minute or m.match.clock_min or 0,
            player_known = (ev.player_known == true),
            tally = ev.tally or 0,
            score_line = ev.score_line or "",
            detail = ev.kind_detail or "goal",
            player = {
                name = p.name or "",
                shirt = p.shirt or 0,
                pos = p.pos or "",
                rating = round(p.rating or 0, 1),
                minutes = p.minutes or 0,
                minutes_exact = (p.minutes_exact == true),
            },
            team = {
                name = (ev.team and ev.team.name) or "",
                abbr = (ev.team and ev.team.abbr) or "",
                color = (ev.team and ev.team.color) or "#D8F26B",
            },
            stats = {
                shots = s.shots or 0,
                on_target = s.on_target or 0,
                goals = s.goals or 0,
                assists = s.assists or 0,
                ga = s.ga or 0,
                passes = s.passes or 0,
                pass_pct = round(s.pass_pct or 0, 0),
                tackles_ok = s.tackles_ok or 0,
                dribbles_ok = s.dribbles_ok or 0,
                touches = s.touches or 0,
                saves = s.saves or 0,
                peak_mph = round(s.peak_mph or 0, 1),
                xg = round(s.xg or 0, 2),
            },
        }
        if ev.score then
            e.score = { home = ev.score.home or 0, away = ev.score.away or 0 }
        end
        if ev.kind == "fulltime" then
            e.result = ev.result or "full_time"
            e.scorers = ev.scorers or {}
            if ev.pk then e.pk = { home = ev.pk.home or 0, away = ev.pk.away or 0 } end
        end
        if ev.milestone then
            e.milestone = {
                key = ev.milestone.key,
                label = ev.milestone.label,
                tone = ev.milestone.tone or "accent",
            }
        end
        if ev.assist then
            e.assist = { name = ev.assist.name or "", shirt = ev.assist.shirt or 0 }
        end
        local sh = ev.shot
        if sh then
            e.shot = {
                speed_mph = round(sh.speed_mph, 1),
                speed_kmh = round(sh.speed_kmh, 1),
                distance_yd = round(sh.distance_yd, 1),
                distance_m = round(sh.distance_m, 1),
                angle_deg = round(sh.angle_deg, 1),
                elevation_deg = round(sh.elevation_deg, 1),
                apex_ft = round(sh.apex_ft, 1),
                apex_m = round(sh.apex_m, 2),
                hang_s = round(sh.hang_s, 2),
                xg = round(sh.xg, 2),
                outcome = sh.outcome,
                body = sh.body,
                source = sh.origin_source,
                speed_source = "modelled",
                distance_source = (sh.origin_source == "measured") and "measured" or "estimated",
                target_x = round(sh.target_x, 2),
                target_y = round(sh.target_y, 2),
                origin_x = round(sh.origin_x, 2),
                origin_y = round(sh.origin_y, 2),
                traj = sh.traj,
            }
        end
        if ev.kind == "motm" and ev.motm then
            local mm = ev.motm
            e.motm = {
                score_line = mm.score_line,
                stats = {
                    goals = mm.stats.goals,
                    assists = mm.stats.assists,
                    ga = mm.stats.ga,
                    shots = mm.stats.shots,
                    on_target = mm.stats.on_target,
                    passes = mm.stats.passes,
                    passes_ok = mm.stats.passes_ok,
                    pass_pct = round(mm.stats.pass_pct, 0),
                    tackles = mm.stats.tackles,
                    tackles_ok = mm.stats.tackles_ok,
                    dribbles_ok = mm.stats.dribbles_ok,
                    touches = mm.stats.touches,
                    saves = mm.stats.saves,
                    interceptions = mm.stats.interceptions,
                    peak_mph = round(mm.stats.peak_mph or 0, 1),
                    xg = round(mm.stats.xg or 0, 2),
                },
            }
        end
        st.event = e
    end
    return st
end

m.build_state = build_state

function m.write_state(now)
    if not m.state.path then return end
    local hz = cfg_i("state_write_hz", 10)
    if hz < 1 then hz = 1 end
    if hz > 30 then hz = 30 end
    local interval = 1000 / hz
    if (now - m.state.last_write) < interval then return end
    m.state.last_write = now
    m.state.last_seq = m.state.last_seq + 1

    -- Atomic publish: write state.json.tmp, then rename it over state.json.
    -- The renderer reads state.json 60x/second; without this it can catch a
    -- truncated file mid-write and throw a card away (or draw a half score).
    -- os.rename is not in Sider's sandbox (os = time, clock, date only), so the
    -- rename is done the portable way: write the temp file, then copy it over
    -- the target with a single write+close. The window where state.json is
    -- short is now one io.open rather than a full serialisation.
    local body = m.json_encode(build_state(now))
    local tmp = m.state.tmp_path or (m.state.path .. ".tmp")
    local target = m.state.path

    local f = io.open(tmp, "wb")
    if not f then
        m.state.writes_failed = (m.state.writes_failed or 0) + 1
        m.state.errors = m.state.errors + 1
        log_once("stateopen", "cannot write state file: " .. tostring(tmp), 20000)
        return false
    end
    f:write(body)
    f:close()

    local g = io.open(target, "wb")
    if not g then
        m.state.writes_failed = (m.state.writes_failed or 0) + 1
        m.state.errors = m.state.errors + 1
        log_once("stateopen2", "cannot write " .. tostring(target), 20000)
        return false
    end
    g:write(body)
    g:close()

    m.state.writes_ok = (m.state.writes_ok or 0) + 1
    m.ev_stat.state_writes = (m.ev_stat.state_writes or 0) + 1
    return true
end

-- ---- overlay text (Sider 7.3.4: 2 return values, no colour table) ---------
function m.overlay_text()
    local out = {}
    out[#out + 1] = m.BRAND
    out[#out + 1] = string.format("%s v%s  -  %s", m.NAME, m.VERSION, m.TAGLINE)
    out[#out + 1] = string.rep("-", 52)

    local home, away = m.match.home, m.match.away
    out[#out + 1] = string.format("%s %d - %d %s    %s", home.abbr or "", home.score or 0,
        away.score or 0, away.abbr or "", m.clock_str())

    -- active state indicator
    local function yn(v) return v and "ON" or "OFF" end
    local style_names = { [0] = "FULL", [1] = "COMPACT", [2] = "MINIMAL" }
    out[#out + 1] = string.format("PRESENTATION %s   STYLE %s   ANALYSIS %s",
        yn(presentation_on()),
        style_names[clamp(cfg_i("presentation_style", 0), 0, 2)],
        yn(cfg_i("shot_analysis_enabled", 1) ~= 0))

    -- where the numbers come from, in plain words
    local src = m.data_source()
    if src == "sider" then
        out[#out + 1] = string.format("ENGINE   scoreboard ok (%d'%02d)   goals seen %d",
            m.match.clock_min or 0, m.match.clock_sec or 0, m.eng.goals or 0)
    elseif m.eng.ini_ok == false then
        out[#out + 1] = "ENGINE   OFF  ->  add  match-stats.enabled = 1  to sider.ini"
    elseif not m.eng.lib then
        out[#out + 1] = "ENGINE   OFF  ->  this Sider build has no match library"
    else
        out[#out + 1] = "ENGINE   waiting for a match (scoreboard returns nothing yet)"
    end
    local alive = (now_ms() - (m.overlay_seen or 0)) < 6000
    local inf = m.overlay_info or {}
    if alive and inf.version and inf.version ~= m.VERSION then
        -- the exe is older than the module: the exact situation that makes new
        -- fixes look like they were never applied
        out[#out + 1] = string.format(
            "OVERLAY   STALE %s, module is %s  ->  run install.bat again",
            inf.version, m.VERSION)
    elseif alive then
        out[#out + 1] = string.format("OVERLAY   running %s   (cards draw over the game)",
            inf.version or "")
    else
        out[#out + 1] = "OVERLAY   NOT RUNNING  ->  run ngb-overlay\\Start_NGB_Overlay.bat"
    end
    local regs = string.format("PLAYER DATA %s   camera %s   names %s   hud %s",
        m.player_stats_ok() and "ok" or "off",
        m.cam.ok and "ok" or "--",
        m.db_ready and "ok" or "--",
        (m.state.path and m.state.errors == 0) and "writing" or "ERROR")
    out[#out + 1] = regs

    local ev = m.ev
    if ev then
        local p = ev.player or {}
        local s_ = ev.stats or {}
        local title = (ev.kind == "motm") and "MAN OF THE MATCH" or "GOAL"
        if ev.kind == "shot" then
            title = "SHOT"
            if ev.shot and ev.shot.outcome == "on_target" then title = "SHOT - ON TARGET" end
            if ev.shot and ev.shot.outcome == "off_target" then title = "SHOT - OFF TARGET" end
        end
        local badge = ""
        if ev.milestone then badge = "   [" .. ev.milestone.label .. "]" end
        out[#out + 1] = string.format("%s  %s #%d (%s)%s", title, p.name or "",
            p.shirt or 0, (ev.team and ev.team.abbr) or "", badge)
        if ev.shot and (ev.kind == "shot" or ev.kind == "goal") then
            out[#out + 1] = string.format("  %s  %s  %0.1f deg  xG %0.2f  (%s)",
                units_mph(ev.shot.speed_mph, ev.shot.speed_kmh),
                units_dist(ev.shot.distance_yd, ev.shot.distance_m),
                ev.shot.angle_deg, ev.shot.xg or 0,
                ev.shot.origin_source == "measured" and "measured" or "model")
        end
        if m.player_stats_ok() then
            out[#out + 1] = string.format("  SHOTS %d   ON TARGET %d   GOALS %d   ASSISTS %d   G/A %d   MIN %s",
                s_.shots or 0, s_.on_target or 0, s_.goals or 0, s_.assists or 0, s_.ga or 0,
                tostring(p.minutes or 0))
        else
            out[#out + 1] = string.format("  %d'%02d   %s   goals this match %d",
                ev.minute or 0, 0, ev.score_line or "", ev.tally or 0)
        end
        if ev.assist then out[#out + 1] = "  ASSIST  " .. tostring(ev.assist.name) end
    else
        out[#out + 1] = "idle - waiting for a shot, goal or full time"
    end

    -- ---- diagnostics panel (the in-game answer to "why is nothing showing?")
    -- Everything here is observed, never assumed: tick source, renderer state,
    -- state file age, back buffer and the first-fire count of each event.
    do
        local rs = m.renderer_status()
        local rtxt = m.renderer.state or "unknown"
        if m.renderer.state == "dll" then
            if rs and rs.hooks == "1" then
                rtxt = "DLL  hooks " .. tostring(rs.frames or "0") .. " frames"
            elseif rs then
                rtxt = "DLL loaded, NOT hooked"
            end
        end
        local detail = m.renderer_detail or m.renderer.detail or ""
        out[#out + 1] = string.format("RENDERER  %s   ticks %d via %s",
            rtxt, m.ev_stat.tick or 0,
            (m.ev_stat.ticks_from ~= "" and m.ev_stat.ticks_from) or "nothing")
        if detail ~= "" and m.renderer.state ~= "dll" then
            out[#out + 1] = "          " .. tostring(detail)
        end

        local written = m.state.last_write or 0
        local age = (written > 0) and (now_ms() - written) or -1
        out[#out + 1] = string.format("STATE     %s   age %s   writes %d ok / %d failed",
            tostring(m.state.path or "none"),
            (age >= 0 and (tostring(age) .. " ms")) or "never",
            m.state.writes_ok or 0, m.state.writes_failed or 0)

        -- first fire of each registered event: the only honest proof that
        -- ctx.register() worked (it cannot report failure)
        local parts = {}
        for _, n in ipairs({ "display_frame", "overlay_on", "key_down", "set_teams",
                             "set_match_settings", "goal_scored", "context_reset",
                             "livecpk_data_ready" }) do
            local e = m.events and m.events[n]
            if e then
                parts[#parts + 1] = string.format("%s:%d", n, e.fired or 0)
            end
        end
        out[#out + 1] = "EVENTS    " .. table.concat(parts, " ")
        if (m.ev_stat.last_error or "") ~= "" then
            out[#out + 1] = "LAST ERR  " .. tostring(m.ev_stat.last_error)
        end
        local rep = m.read_render_report and m.read_render_report()
        if rep and rep.backbuffer then
            out[#out + 1] = string.format("BACKBUF   %s   hwnd %s",
                rep.backbuffer, rep.hwnd or "?")
        end
    end

    if m.toast then out[#out + 1] = "> " .. m.toast.text end

    out[#out + 1] = "KEYS  [7] style   [8] presentation   [9] shot analysis"
    if not ffi_ok then
        out[#out + 1] = "ERROR: set luajit.ext.enabled = 1 in sider.ini (live stats need it)"
    elseif m.reg.stats == 0 then
        out[#out + 1] = "searching for the stat region ... start a match"
    end
    out[#out + 1] = "Created by " .. m.AUTHOR
    return table.concat(out, "\n")
end

-- ============================================================================
-- 17. Hotkeys / demo
-- ============================================================================
local demo_cycle = 0

function m.demo_preview(phase_in)
    demo_cycle = demo_cycle + 1
    local phase = phase_in or ((demo_cycle - 1) % 3)
    if phase == 0 then
        local ev = fire_shot_event(0, 4, "goal", { shots = 4, on_target = 3, goals = 3, assists = 1, ga = 4 })
        if ev then
            ev.milestone = { key = "hat_trick", label = "HAT-TRICK", tone = "gold" }
            ev.assist = { name = "B. SAKA", shirt = 7 }
        end
        return ev
    elseif phase == 1 then
        local ev = fire_shot_event(1, 7, "off_target", { shots = 3, on_target = 1, goals = 0, assists = 1, ga = 1 })
        return ev
    else
        m.motm = m.motm or {
            player = { name = "DUMMY PLAYER", shirt = 9, pos = "CF", rating = 8.7 },
            team = team_of(0),
            score_line = "HOME 2 - 1 AWAY",
            stats = { goals = 2, assists = 1, ga = 3, shots = 5, on_target = 4, passes = 34,
                      passes_ok = 30, pass_pct = 88, tackles = 3, tackles_ok = 2,
                      dribbles_ok = 4, touches = 61, saves = 0, interceptions = 1,
                      peak_mph = 78.4, xg = 1.12 },
        }
        local mm = m.motm
        local dur = cfg_f("motm_card_duration", 22.0)
        return push_event("motm", 0, 0, {
            player = mm.player, team = mm.team, stats = mm.stats, motm = mm,
            duration = dur, remaining = dur,
        })
    end
end

-- ============================================================================
-- 18. Main tick
-- ============================================================================
local TICK = { last = 0 }

function m.tick(now, source)
    -- tolerate the old single-argument form m.tick("overlay_on"): a string was
    -- meant as the source name, never as a timestamp
    if type(now) == "string" then now, source = nil, now end
    now = now or now_ms()
    if (now - TICK.last) < 8 then return end
    TICK.last = now
    m.ev_stat.tick = (m.ev_stat.tick or 0) + 1
    if source then m.ev_stat.ticks_from = source end

    -- heartbeat first: it must keep beating even if everything below bails out
    m.write_heartbeat(now)

    -- match info
    if (now - m.poll.last_match) >= 200 then
        m.poll.last_match = now
        m.refresh_match()
    end

    -- region discovery: only while a match is going on, at most 3 attempts
    if not m.reg.ok and mem_ok and m.match.valid and m.reg.tries < 3 then
        if (now - (m.reg.last_try or 0)) > 6000 then
            m.reg.last_try = now
            m.reg.tries = m.reg.tries + 1
            apply_region_override()
            if not m.reg.ok then scan_regions() end
        end
    end

    -- position block
    local pos_ms = cfg_i("position_poll_ms", 120)
    if pos_ms < 60 then pos_ms = 60 end
    if m.reg.pitch ~= 0 and (now - m.poll.last_pos) >= pos_ms then
        m.poll.last_pos = now
        read_pitch()
    end

    m.watch_overlay(now)

    -- scoreboard watchers: no memory region involved, they run on their own
    -- clock so a goal is caught even when everything else is unavailable
    if (now - (m.poll.last_watch or 0)) >= 200 then
        m.poll.last_watch = now
        if not m.match.paused then
            watch_scoreboard(now)
            watch_period(now)
            flush_fallback(now)
        end
    end

    -- is the experimental player scan telling the truth? ask it once a while
    if cfg_i("experimental_player_stats", 0) ~= 0 then
        if m.reg.stats ~= 0 and not m.stats_validated and (now - (m.stats_checked_at or 0)) > 5000 then
            m.stats_checked_at = now
            m.stats_validated = m.validate_stats()
            log_msg("player stat table validation: " .. tostring(m.stats_validated))
        elseif m.stats_validated and (now - (m.stats_checked_at or 0)) > 30000 then
            m.stats_checked_at = now
            m.stats_validated = m.validate_stats()
        end
        -- every 2 s (and once immediately after validation): do the player
        -- numbers still describe the scoreboard?
        if m.stats_validated and
           (not m.coh_checked_at or (now - m.coh_checked_at) > 2000) then
            m.coh_checked_at = now
            local was = m.stats_coherent
            m.check_coherence()
            if was ~= m.stats_coherent then
                log_msg("stats coherence -> " .. tostring(m.stats_coherent) ..
                        (m.stats_coherent and "" or ("  (" .. tostring(m.coherence_reason) .. ")")))
            end
        end
    end

    -- per player stats (only once the scan has proved it agrees with the game)
    local stat_ms = cfg_i("stats_poll_ms", 350)
    if stat_ms < 100 then stat_ms = 100 end
    if m.player_stats_ok() and (now - m.poll.last_stats) >= stat_ms then
        m.poll.last_stats = now
        if not m.match.paused then detect_events() end
    end

    -- replay camera sweep
    m.cam_update()
    if m.cam.active and m.goal_window_until and now > m.goal_window_until then
        m.cam_restore()
    end

    -- event expiry (an optional show_at offset delays the card without
    -- shortening its lifetime)
    local ev = m.ev
    if ev then
        local t0 = ev.started
        if ev.show_at and ev.show_at > t0 then t0 = ev.show_at end
        local rem
        if now < t0 then
            -- held back on purpose (goal_telemetry_delay): nothing on screen
            rem = 0
        else
            rem = (ev.duration or 0) - (now - t0) / 1000
        end
        if rem < 0 then rem = 0 end
        if rem > (ev.duration or 0) then rem = ev.duration end
        ev.remaining = rem
        if now >= t0 and rem <= 0 then
            if ev.kind == "goal" then m.cam_restore() end
            m.ev = nil
        end
    end

    -- toast expiry
    if m.toast and now > (m.toast.until_ms or 0) then m.toast = nil end

    -- post-match MOTM
    check_post_match(now)

    -- HUD state file
    if cfg_i("companion_hud_enabled", 1) ~= 0 then
        m.write_state(now)
    end
end

-- ============================================================================
-- 19. Sider event handlers  (all anchored on m)
-- ============================================================================
-- Forward declaration: the handlers below call note_event() but its body is
-- defined with the diagnostics in section 20b. Without this the handlers would
-- resolve a *global* (nil) at call time and every event would raise.
local note_event

function m.on_display_frame(ctx)
    m.ctx = ctx
    note_event("display_frame")
    m.ev_stat.last_event = "display_frame"
    m.ev_stat.ticks_from = "display_frame"
    m.tick()
end

function m.on_goal_scored(ctx, goal)
    m.ctx = ctx
    note_event("goal_scored")
    m.ev_stat.last_event = "goal_scored"
    if type(goal) ~= "table" then
        log_once("goalshape", "goal_scored fired without a table payload - ignored", 5000)
        return
    end
    local side = (tonumber(goal.home_or_away) == 1) and 1 or 0
    local name = tostring(goal.player_name_on_shirt or "")
    if cfg_i("debug_log", 0) ~= 0 then
        log_msg("goal_scored: id=" .. tostring(goal.player_id) ..
                " offset=" .. tostring(goal.player_offset) ..
                " away=" .. tostring(goal.home_or_away) ..
                " name=" .. name)
    end
    m.goal_hook({
        side = side,
        name = name,
        pid = tonumber(goal.player_id) or 0,
        offset = tonumber(goal.player_offset) or 0,
        minute = m.match.clock_min or 0,
        kind = "goal",
    })
end

function m.on_set_teams(ctx, home, away)
    m.ctx = ctx
    note_event("set_teams")
    m.ev_stat.last_event = "set_teams"
    if home then m.teams = { home = tonumber(home), away = tonumber(away) } end
    m.seen = {}
    m.match.mis = 0          -- force a full re-read on the next frame
    m.match.home.color = nil
    m.match.away.color = nil
    m.squad_cache = nil
    m.xi_cache = nil
    m.baselined = false
    m.ps = { [0] = {}, [1] = {} }
end

function m.on_livecpk_data_ready(ctx, filename, data, size, total_size, offset, cpk_filename)
    m.ctx = ctx
    note_event("livecpk_data_ready")
    m.ev_stat.last_event = "livecpk_data_ready"
    if type(filename) ~= "string" then return end
    local lower = string.lower(filename)

    if string.find(lower, "player%.bin$") then
        m.on_player_bin(data, total_size or size)
        return
    end
    -- post-match screen transition (documented PES 2021 flow file)
    if string.find(lower, "matchsetuprematch%.json$") then
        m.post.seen = true
        if m.post.flow_at == 0 then m.post.flow_at = now_ms() end
        log_msg("post-match flow file seen")
    end
end

function m.on_context_reset(ctx)
    m.ctx = ctx
    note_event("context_reset")
    m.ev_stat.last_event = "context_reset"
    m.cam_restore()
    m.ev = nil
    m.motm = nil
    m.baselined = false
    m.ps = { [0] = {}, [1] = {} }
    m.squad_cache = nil
    m.xi_cache = nil
    m.fx = {}
    m.post = { seen = false, flow_at = 0, shown = false }
    m.reg.stats = 0
    m.reg.pitch = 0
    m.reg.ok = false
    m.reg.tries = 0
    m.match.valid = false
    m.match.mis = 0
    m.match.sci = 0
    m.match.sci2 = 0
    log_msg("context reset")
end

local STYLE_NAMES = { [0] = "FULL", [1] = "COMPACT", [2] = "MINIMAL" }

function m.cycle_style()
    local cur = clamp(cfg_i("presentation_style", 0), 0, 2)
    local nxt = (cur + 1) % 3
    m.cfg.presentation_style = nxt
    set_toast("PRESENTATION: " .. STYLE_NAMES[nxt], "style", 2.0)
    log_msg("presentation style -> " .. STYLE_NAMES[nxt])
    return nxt
end

function m.toggle_presentation()
    local on = presentation_on()
    m.cfg.presentation_enabled = on and 0 or 1
    if not on then
        m.ev = nil          -- switching back on must not replay a stale card
        m.cam_restore()
    end
    set_toast(on and "PRESENTATION OFF" or "PRESENTATION ON", "toggle", 2.0)
    return not on
end

function m.toggle_analysis()
    local on = cfg_i("shot_analysis_enabled", 1) ~= 0
    m.cfg.shot_analysis_enabled = on and 0 or 1
    set_toast(on and "SHOT ANALYSIS OFF" or "SHOT ANALYSIS ON", "toggle", 2.0)
    return not on
end

-- Digit hotkeys (7 / 8 / 9 by default - never F7 / F8 / F9).
-- With hotkeys_overlay_only = 1 they only act while the Sider overlay is open,
-- so they can never clash with the game's own 7 / 8 / 9 keys.
function m.on_key_down(ctx, vkey)
    m.ctx = ctx
    note_event("key_down")
    m.ev_stat.last_event = "key_down"
    local k_style = cfg_i("hotkey_prev_style", 0x37)
    local k_overlay = cfg_i("hotkey_toggle_overlay", 0x38)
    local k_analysis = cfg_i("hotkey_toggle_analysis", 0x39)

    if vkey ~= k_style and vkey ~= k_overlay and vkey ~= k_analysis then return end
    if cfg_i("hotkeys_overlay_only", 1) ~= 0
       and (now_ms() - (m.overlay_seen or 0)) > 1500 then
        return   -- overlay is closed: leave the digits to the game
    end

    if vkey == k_style then
        m.cycle_style()
    elseif vkey == k_overlay then
        m.toggle_presentation()
    elseif vkey == k_analysis then
        m.toggle_analysis()
    end
end

function m.on_overlay_on(ctx)
    m.ctx = ctx
    note_event("overlay_on")
    m.ev_stat.last_event = "overlay_on"
    m.overlay_seen = now_ms()
    -- the Sider overlay is a *fallback* now: when the DLL renderer is drawing,
    -- the overlay keeps its own status text, not a second set of cards
    m.tick(nil, "overlay_on")
    -- the credit is drawn once at the top of the overlay, so it never touches
    -- the game picture itself
    return m.overlay_text()
end

-- ============================================================================
-- 20. In-game renderer bridge (NGB_Render.dll)
-- ============================================================================
-- The cards used to be drawn by a separate C# window (NGB_Overlay.exe) that a
-- WinExec spawned. That is why nothing appeared when the game was unfocused,
-- in exclusive fullscreen, or under a window the process-name guess missed.
--
-- The renderer is now a DLL loaded *into the game process* by this module:
--
--   Sider calls m.init(ctx)
--        -> m.load_renderer()
--        -> ffi.load(<sider>ngb-render\NGB_Render.dll)        (x64, same process)
--        -> NGB_Start(config_utf8)                            (called from the
--                                                              game thread)
--
-- The DLL finds the game's swapchain, hooks Present/ResizeBuffers, and draws
-- the cards onto the game's own back buffer. No window of its own, no window
-- search, no focus dependency, works in exclusive fullscreen.
--
-- Loading rules, in order:
--   1. ini: renderer = dll        (default)
--      ini: renderer = none       (draw nothing; Sider overlay text only)
--      ini: renderer = overlay    (fall back to the C# window, if present)
--   2. if FFI is off, ffi.load cannot be called -> log why, fall back.
--   3. if the DLL is missing or refuses to start -> log why, fall back.
-- Never silent: every branch logs one line with the reason.
--
-- Safety: the DLL is the only thing that ever touches the game's rendering.
-- It does not read game memory, it does not write game files, and every hook
-- is guarded by SEH with an automatic self-disable (see ngb-render/).
m.renderer = {
    wanted = "dll",
    state = "not started",     -- "dll", "overlay", "none"
    detail = "",
    handle = nil,
    started_at = 0,
    last_error = "",
}

-- FFI signatures for the loader. Declared once, guarded: a failed cdef here
-- must not abort the module (that was problem 8).
local function declare_loader()
    if not ffi_ok then return false, "ffi unavailable (luajit.ext.enabled = 0)" end
    if ffi.NGB_loader_cdefs then return true end
    local ok = true
    -- cdef returns nothing; a duplicate definition raises, so set the flag
    -- only after the call and check the flag first (idempotent across reloads).
    ffi.cdef [[
        void *LoadLibraryA(const char *name);
        int   FreeLibrary(void *handle);
        void *GetProcAddress(void *handle, const char *name);
        unsigned int SetErrorMode(unsigned int mode);
        unsigned int GetCurrentProcessId(void);
        unsigned int GetModuleFileNameA(void *mod, char *buf, unsigned int size);
        void *GetCurrentProcess(void);
    ]]
    ffi.NGB_loader_cdefs = true
    return true
end

-- ---------------------------------------------------------------------------
-- Process identity (problem 3: the C# overlay used to *guess* exe names)
--
-- We are running inside the game process, so we can simply ask it. This is the
-- only reliable answer, and it is what state.json publishes for the renderer.
-- Every step is individually guarded: a missing ffi or a failed call leaves the
-- field empty (rendered as "unknown") instead of aborting the module.
-- ---------------------------------------------------------------------------
m.ident = { pid = 0, exe = "", hwnd = "", backbuffer = "", source = "unknown" }

local function read_identity()
    local idn = m.ident
    if idn.pid ~= 0 or not ffi_ok then return idn end
    local ok = declare_loader()
    if not ok then return idn end
    -- the calls are cheap and cannot fault; still, guard each one separately so
    -- one missing export does not cost us the other field
    local got_pid = false
    local f = C and C.GetCurrentProcessId
    if f then
        local v = f()
        if v and v > 0 then idn.pid = tonumber(v) or 0; got_pid = idn.pid > 0 end
    end
    local fm = C and C.GetModuleFileNameA
    if fm then
        local buf = ffi.new("char[512]")
        local n = fm(nil, buf, 512)
        if n and n > 0 then
            local path = ffi.string(buf, tonumber(n))
            idn.exe = string.match(path, "([^\\/]+)$") or path
            idn.path = path
        end
    end
    idn.source = (got_pid and idn.exe ~= "") and "ffi" or (got_pid and "ffi-pid" or "unknown")
    return idn
end
m.read_identity = read_identity

-- The DLL renderer knows the swapchain, so it is the only component that can
-- report the window handle and the real back-buffer size. It writes them to
-- render.txt; we fold them into state.json so there is one file to read.
local function render_dir(ctx)
    local sdir = (ctx and ctx.sider_dir) or m.sider_dir or "."
    if string.sub(sdir, -1) ~= "\\" and string.sub(sdir, -1) ~= "/" then sdir = sdir .. "\\" end
    return sdir .. "ngb-render\\"
end
m.render_dir = render_dir

local function read_render_report()
    if not io or not io.open or not m.sider_dir then return nil end
    local f = io.open(render_dir({ sider_dir = m.sider_dir }) .. "render.txt", "r")
    if not f then return nil end
    local out = {}
    for line in f:lines() do
        local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then out[k] = v end
    end
    f:close()
    if not out.hwnd and not out.backbuffer then return nil end
    return out
end
m.read_render_report = read_render_report

-- LoadLibraryA helper with no FFI cdef risk: uses the raw symbol so a build
-- whose cdef already declares LoadLibraryA (unlikely) still works.
local function load_library(path)
    local ok, err = declare_loader()
    if not ok then return nil, err end
    local h = C.LoadLibraryA(path)
    if h == nil then return nil, "LoadLibraryA failed (file missing, or not x64)" end
    -- luajit returns cdata; convert to a number so it can be compared/stored
    return h, nil
end

local function get_proc(handle, name)
    local fn = C.GetProcAddress(handle, name)
    if fn == nil then return nil end
    return fn
end

function m.renderer_path(ctx)
    local sdir = (ctx and ctx.sider_dir) or ""
    local tail = string.sub(sdir, -1)
    if tail ~= "\\" and tail ~= "/" then sdir = sdir .. "\\" end
    return sdir .. "ngb-render\\NGB_Render.dll"
end

-- Fire NGB_Start(config) once. config is a UTF-8 key=value block the DLL
-- parses; it carries the state file path so the DLL never has to guess.
function m.load_renderer(ctx)
    m.renderer.wanted = string.lower(cfg_s("renderer", "dll"))
    if m.renderer.wanted == "none" then
        m.renderer.state = "none"
        m.renderer.detail = "renderer = none in NGB_Presentation.ini"
        log_msg("renderer: disabled by configuration (renderer = none)")
        return false
    end
    if m.renderer.wanted ~= "dll" then
        m.renderer.state = "overlay"
        m.renderer.detail = "renderer = " .. m.renderer.wanted .. " (legacy window)"
        log_msg("renderer: configured as '" .. m.renderer.wanted .. "' - using the C# overlay")
        return false
    end

    local path = m.renderer_path(ctx)
    local f = io.open(path, "rb")
    if not f then
        m.renderer.state = "overlay"
        m.renderer.detail = "NGB_Render.dll not found at " .. path
        log_msg("renderer: NO DLL at " .. path ..
                " - falling back to the C# overlay. Re-run install.bat.")
        return false
    end
    f:close()

    if not ffi_ok then
        m.renderer.state = "overlay"
        m.renderer.detail = "ffi off - cannot LoadLibrary"
        log_msg("renderer: luajit.ext.enabled = 0, so the DLL cannot be loaded. " ..
                "Add that line to sider.ini, or the C# overlay is used instead.")
        return false
    end

    local handle, err = load_library(path)
    if not handle then
        m.renderer.state = "overlay"
        m.renderer.detail = tostring(err)
        log_msg("renderer: " .. tostring(err) .. " - falling back to the C# overlay")
        return false
    end

    local start = get_proc(handle, "NGB_Start")
    if not start then
        m.renderer.state = "overlay"
        m.renderer.detail = "NGB_Start export missing"
        log_msg("renderer: NGB_Render.dll has no NGB_Start export - wrong file? " ..
                "Falling back to the C# overlay")
        return false
    end

    -- Config block: KEY=VALUE pairs. The DLL accepts both ';' and newlines as
    -- separators (a Lua string with embedded newlines is awkward through ffi,
    -- so ';' is what we send).
    local dir = tostring(m.state.dir)
    if string.sub(dir, -1) ~= "\\" and string.sub(dir, -1) ~= "/" then dir = dir .. "\\" end
    local cfgtext = table.concat({
        "state_file=" .. tostring(m.state.path),
        "log_file=" .. dir .. "ngb-dll.log",
        "dir=" .. dir,
        "version=" .. m.VERSION,
        "debug=" .. tostring(cfg_i("debug_log", 0)),
        "enabled=" .. tostring(cfg_i("dll_enabled", 1)),
        "hotkey_selftest=" .. tostring(cfg_i("dll_selftest_hotkey", 0x77)),
        "hotkey_diag=" .. tostring(cfg_i("dll_diag_hotkey", 0x76)),
        "hotkey_kill=" .. tostring(cfg_i("dll_kill_hotkey", 0x7B)),
    }, ";")

    -- ffi.string of a Lua string -> const char*; the DLL copies it immediately
    local started = start(cfgtext)
    if not started or tonumber(started) == 0 then
        -- the DLL refused (no probe swapchain, MinHook failed, ...). It has
        -- already written the reason to ngb-dll.log; do not pretend it worked.
        m.renderer.state = "overlay"
        m.renderer.detail = "NGB_Start returned 0 - see " .. dir .. "ngb-dll.log"
        log_msg("renderer: NGB_Start reported failure; the C# overlay is the " ..
                "fallback. Reason is in " .. dir .. "ngb-dll.log")
        return false
    end

    local state_proc = get_proc(handle, "NGB_GetState")
    m.renderer.handle = handle
    m.renderer.state = "dll"
    m.renderer.started_at = now_ms()
    m.renderer.get_state = state_proc
    m.renderer.detail = path
    log_msg("renderer: NGB_Render.dll loaded and NGB_Start() called - " ..
            "cards are drawn inside the game's own frame")
    return true
end

-- Ask the DLL what it is doing (used by the diagnostics panel and state.json).
-- Returns nil when the DLL is not loaded or the export is missing.
function m.renderer_status()
    if m.renderer.state ~= "dll" or not m.renderer.get_state then return nil end
    local s = m.renderer.get_state()
    if type(s) ~= "string" then return nil end
    local t = {}
    for k, v in string.gmatch(s, "([%w_]+)=([^;]*)") do t[k] = v end
    return t
end

-- ============================================================================
-- 20b. Startup diagnostics (STAGE 0)
-- ============================================================================
-- Everything in this block exists to answer "why is nothing showing?" without
-- the player having to guess. It is deliberately cheap: no string formatting
-- unless something actually happened.
--
-- The event table below is the verified list from the Sider 7.4 source
-- (sider_context_register in sider.cpp). `register` is a void C function: it
-- CANNOT report success. An unknown name is only reported by Sider itself, as
--   WARN: trying to register for unknown event: "..."
-- in sider.log, and ctx.register() still returns silently. So the module
-- registers xpcall-free, then proves each handler by counting its first call
-- in m.ev_fired. That is the only trustworthy "did it register" answer.
m.events = {
    -- name                = { wanted = bool, fired = 0, first = 0 }
    display_frame         = { wanted = true },
    overlay_on            = { wanted = true },
    key_down              = { wanted = true },
    set_teams             = { wanted = true },
    set_match_settings    = { wanted = true },   -- real, verified in sider.cpp
    goal_scored           = { wanted = true },   -- real, verified in sider.cpp
    context_reset         = { wanted = true },
    livecpk_data_ready    = { wanted = true },
    show                  = { wanted = false },
    hide                  = { wanted = false },
}
m.ev_stat = { display_frame = 0, tick = 0, ticks_from = "", state_writes = 0,
              heartbeat_writes = 0, last_error = "" }

-- Called at the top of every handler. Cheap: one table lookup + increment.
function note_event(name)
    local e = m.events[name]
    if not e then return end
    e.fired = (e.fired or 0) + 1
    if not e.first then
        e.first = now_ms()
        log_msg(string.format("event '%s' fired for the first time (after %d ms)",
            name, e.first))
    end
end
m.note_event = note_event

-- One line per registered event, at startup, in the documented Sider format.
local function declare_events(ctx)
    local names = { "display_frame", "overlay_on", "key_down", "set_teams",
                    "set_match_settings", "goal_scored", "context_reset",
                    "livecpk_data_ready" }
    for i = 1, #names do
        local n = names[i]
        local handler = m.handler_for and m.handler_for[n]
        if handler then
            ctx.register(n, handler)
            m.events[n].registered = true
            log_msg("ctx.register(\"" .. n .. "\"): requested (Sider logs the result)")
            -- Sider prints: > Registered for "x" event   (or WARN: unknown event)
        else
            log_msg("ctx.register(\"" .. n .. "\") SKIPPED: no handler on the module")
        end
    end
end

-- Which Sider / LuaJIT / folder layout are we actually in?
local function log_environment(ctx)
    log_msg(string.format("%s v%s starting", m.NAME, m.VERSION))
    log_msg("sider_dir = " .. tostring(ctx and ctx.sider_dir))
    log_msg("lua = " .. tostring(_VERSION))
    if jit and jit.version then log_msg("luajit = " .. tostring(jit.version)) end
    log_msg("ffi = " .. tostring(ffi_ok) ..
            "   bit = " .. tostring(bit ~= nil))
    log_msg("memory lib = " .. tostring(mem_ok) ..
            (mem_ok and "" or "  <-- READS DISABLED, no stats possible"))
    log_msg("match lib = " .. tostring(match ~= nil and type(match.stats) == "function"))
    log_msg("io.open, os.time, os.clock = " ..
            tostring(io and io.open ~= nil) .. ", " ..
            tostring(os and os.time ~= nil) .. ", " ..
            tostring(os and os.clock ~= nil))
    -- folder layout: FL26/27 installs use a SiderAddons folder; say which we see
    local sdir = (ctx and ctx.sider_dir) or ""
    local f = io.open(sdir .. "..\\SiderAddons\\sider.exe", "rb")
    if f then f:close()
        log_msg("folder layout: SiderAddons detected next to sider_dir")
    end
    log_msg("renderer wanted = " .. tostring(cfg_s("renderer", "dll")))
end
m.log_environment = log_environment

-- A compact "which events have fired" table for state.json / diagnostics.
function m.event_snapshot()
    local out = {}
    local names = { "display_frame", "overlay_on", "key_down", "set_teams",
                    "set_match_settings", "goal_scored", "context_reset",
                    "livecpk_data_ready" }
    for i = 1, #names do
        local e = m.events[names[i]]
        out[names[i]] = (e and e.fired) or 0
    end
    return out
end

-- ---- heartbeat -------------------------------------------------------------
-- content\ngb-presentation\heartbeat.txt, rewritten at most once a second.
-- It is the one file that proves "the module is alive and ticking": if it is
-- not updating, the module is not running, whatever else the HUD says.
function m.write_heartbeat(now)
    if not m.state.dir then return false end
    if (now - (m.hb.last or 0)) < 1000 then return false end
    m.hb.last = now
    local path = m.state.dir .. "\\heartbeat.txt"
    local f = io.open(path, "wb")
    if not f then return false end
    local fired = {}
    local names = { "display_frame", "overlay_on", "key_down", "set_teams",
                    "set_match_settings", "goal_scored", "context_reset",
                    "livecpk_data_ready" }
    for i = 1, #names do
        local e = m.events[names[i]]
        fired[#fired + 1] = names[i] .. "=" .. tostring(e.fired or 0)
    end
    f:write(table.concat({
        "module " .. m.VERSION,
        "state_version " .. tostring(m.STATE_VERSION),
        "at " .. os.date("%Y-%m-%d %H:%M:%S"),
        "uptime_ms " .. tostring(now - (m.started_at or now)),
        "last_event " .. tostring(m.ev_stat.last_event or "-"),
        "ticks " .. tostring(m.ev_stat.tick),
        "tick_source " .. tostring(m.ev_stat.ticks_from),
        "state_writes " .. tostring(m.ev_stat.state_writes),
        "heartbeat_writes " .. tostring(m.ev_stat.heartbeat_writes),
        "renderer " .. tostring(m.renderer.state),
        "score " .. tostring(m.eng.score.home) .. "-" .. tostring(m.eng.score.away),
        "clock " .. m.clock_str(),
        "data " .. m.data_source(),
        "events " .. table.concat(fired, " "),
        "last_error " .. tostring(m.ev_stat.last_error),
    }, "\n") .. "\n")
    f:close()
    m.ev_stat.heartbeat_writes = m.ev_stat.heartbeat_writes + 1
    return true
end

-- ============================================================================
-- 21. init
-- ============================================================================
-- handler lookup used by declare_events(): keeps a single source of truth
m.handler_for = {
    display_frame      = function(ctx) return m.on_display_frame(ctx) end,
    overlay_on         = function(ctx) return m.on_overlay_on(ctx) end,
    key_down           = function(ctx, vkey) return m.on_key_down(ctx, vkey) end,
    set_teams          = function(ctx, h, a) return m.on_set_teams(ctx, h, a) end,
    set_match_settings = function(ctx) return m.on_set_teams(ctx) end,
    goal_scored        = function(ctx, g) return m.on_goal_scored(ctx, g) end,
    context_reset      = function(ctx) return m.on_context_reset(ctx) end,
    livecpk_data_ready = function(ctx, ...) return m.on_livecpk_data_ready(ctx, ...) end,
}

function m.init(ctx)
    m.ctx = ctx
    m.sider_dir = (ctx and ctx.sider_dir) or ""
    m.started_at = now_ms()
    log_environment(ctx)
    -- problem 3: ask the game who it is, instead of guessing exe names later
    read_identity()

    -- configuration
    local sdir = ctx and ctx.sider_dir or ""
    local ini_path = sdir .. "modules\\NGB_Presentation.ini"
    local f = io.open(ini_path, "r")
    if not f then
        ini_path = sdir .. "modules/NGB_Presentation.ini"
        f = io.open(ini_path, "r")
    end
    if f then
        cfg = m.parse_ini(f:read("*a"))
        f:close()
    else
        log_msg("INI not found, using defaults: " .. tostring(ini_path))
    end
    for k, v in pairs(DEFAULT_CFG) do
        if cfg[k] == nil then cfg[k] = v end
    end
    if type(cfg.units) == "string" then
        cfg.units = string.lower(cfg.units)
    end
    if cfg.units ~= "metric" then cfg.units = "imperial" end
    m.cfg = cfg

    if not ffi_ok then
        log_msg("WARNING: LuaJIT FFI is off. Add 'luajit.ext.enabled = 1' to sider.ini " ..
                "for live stats, telemetry and the replay camera.")
    end

    m.init_state_path(ctx)

    -- per-player table layout: a calibration file from tools/decode_probe.py
    -- first, then the ini (an explicit ini value always wins)
    m.apply_layout(m.read_calibration(m.state.dir), "calibration.txt")
    m.apply_layout(cfg, "NGB_Presentation.ini")

    -- handlers, registered through the diagnostic table so each one is logged
    -- and its first fire is timestamped (see declare_events above)
    declare_events(ctx)

    -- replay camera pattern scan (cached for the whole session)
    m.cam_init()

    -- optional early region hint from the INI
    apply_region_override()

    -- is the match library switched on in sider.ini?
    m.check_ini_flags()

    if not m.eng.lib then
        log_once("nomatlib",
            "this Sider build does not expose the 'match' library - goal cards will only " ..
            "appear from the goal hook, without the score", 60000)
    end

    -- first state file so the companion can start straight away
    m.write_state(now_ms())

    -- the DLL draws the cards inside the game's own frame; if it cannot load
    -- we fall back to the C# window and say exactly why (never silently)
    m.load_renderer(ctx)
    read_identity()
    log_msg(string.format("game identity: pid %d  exe %s  (source %s)",
        m.ident.pid or 0, (m.ident.exe ~= "" and m.ident.exe or "unknown"),
        m.ident.source or "unknown"))
    log_msg("ready")
end

-- ============================================================================
-- 22. Test hooks (used by tools/verify_mod.py, harmless in game)
-- ============================================================================
m._test = {
    read_head = read_head,
    goal = function(t) return m.goal_hook(t) end,
    result = function(k) return m.show_result(k) end,
    probe = function(t) return m.probe_write(t) end,
    validate = function() return m.validate_stats() end,
    detect_events = function() return detect_events() end,
    set_cfg = function(t) for k, v in pairs(t) do cfg[k] = v end end,
    set_region = function(s, p) m.reg.stats = s or 0; m.reg.pitch = p or 0; m.reg.ok = (m.reg.stats ~= 0) end,
    reset = function() m.ev = nil; m.baselined = false; m.ps = { [0] = {}, [1] = {} }; m.fx = {} end,
    state = function() return build_state(now_ms()) end,
}

return m
