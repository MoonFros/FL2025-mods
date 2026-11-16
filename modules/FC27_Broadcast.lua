-- ============================================================================
--  EA FC 27 HyperMotion Broadcast & Replay Telemetry
--  Sider Lua module for PES 2021 / SmokePatch Football Life 2025 (FL_2025.exe)
--
--  Feature 1 : HyperMotion goal replay camera + live shot telemetry
--  Feature 2 : Goal / miss / save player popup with match shots + G/A
--  Feature 3 : Post-match Man of the Match full stat card
--
--  Target : Sider 7.3.4 (LuaJIT 2.1, x64), FL_2025.exe v1.0, PES 2021 v1.7.x
--  Output : content\fc27-broadcast\state.json  ->  FC27_Overlay.exe (C# HUD)
--           Sider overlay text (overlay_on)    ->  fallback in-game overlay
--
--  Module sandbox notes (Sider 7.3.4):
--    * globals available: string math table io os(time/clock/date) tonumber
--      tostring type pairs ipairs unpack error assert collectgarbage log
--      memory fs audio match zlib  (+ ffi bit when luajit.ext.enabled = 1)
--    * pcall / xpcall / require / select / next are NOT available.
--      => every failure path must be an explicit nil check, never a pcall.
--    * the module chunk must RETURN a table that has an init(ctx) method, and
--      every registered callback is kept as a field of that table (m.xxx) so
--      the module table stays reachable from Sider's main lua_State.
-- ============================================================================

local m = {}

m.NAME = "EA FC 27 Broadcast"
m.VERSION = "1.0.0"
m.STATE_VERSION = 1

-- ============================================================================
-- 0. Optional LuaJIT FFI
-- ============================================================================
-- `ffi` only exists when sider.ini has luajit.ext.enabled = 1.
local ffi = ffi
local ffi_ok = (ffi ~= nil)
local C = nil

if ffi_ok then
    C = ffi.C
    -- The cdef block is stored on the shared `ffi` module table (not on a
    -- module-local global) so that a Sider hot-reload of this file does not
    -- try to redefine the struct and abort the chunk.
    if not ffi.FC27_cdefs then
        ffi.cdef [[
            typedef struct FC27_MBI {
                void     *BaseAddress;
                void     *AllocationBase;
                uint32_t  AllocationProtect;
                uint16_t  PartitionId;
                uint64_t  RegionSize;
                uint32_t  State;
                uint32_t  Protect;
                uint32_t  Type;
            } FC27_MBI;

            uint64_t FC27_GetTickCount64(void)
                __asm__("GetTickCount64");
            void    *FC27_GetCurrentProcess(void)
                __asm__("GetCurrentProcess");
            int      FC27_ReadProcessMemory(void *proc, const void *addr,
                                            void *buf, size_t size, size_t *read)
                __asm__("ReadProcessMemory");
            size_t   FC27_VirtualQuery(const void *addr, void *mbi, size_t size)
                __asm__("VirtualQuery");
            unsigned int FC27_WinExec(const char *cmd, unsigned int show)
                __asm__("WinExec");
        ]]
        ffi.FC27_cdefs = true
    end
end

-- Scratch buffer for ReadProcessMemory. Big enough for one full stat record
-- (0x2134 = 8516 bytes) plus the kind-179 float.
local RBUF_LEN = 16384
local rbuf = ffi_ok and ffi.new("uint8_t[?]", RBUF_LEN) or nil
local rn = ffi_ok and ffi.new("size_t[1]") or nil
local PROC = ffi_ok and C.FC27_GetCurrentProcess() or nil

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
    if ffi_ok then
        local v = tonumber(C.FC27_GetTickCount64())
        if v and v > 0 then
            if v < last_ms then v = last_ms end  -- never go backwards
            last_ms = v
            return v
        end
    end
    local v = os.time() * 1000 + floor((os.clock() % 1) * 1000)
    if v < last_ms then v = last_ms end
    last_ms = v
    return v
end

m.now_ms = now_ms

local LOG_PREFIX = "[FC27] "
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
    units = "imperial",
    theme = "eafc",
    companion_hud_enabled = 1,
    auto_launch_companion = 1,
    state_write_hz = 10,
    debug_log = 0,
    show_scorebug = 0,
    show_position = 1,

    replay_camera_enabled = 1,
    replay_camera_preset = 1,
    replay_height_cam0 = 0.28,
    replay_height_cam3 = 0.95,
    replay_zoom = 0.56,
    goal_telemetry_duration = 16.0,
    goal_telemetry_delay = 1.2,
    replay_window_max = 45.0,

    shot_popup_enabled = 1,
    shot_popup_duration = 6.5,

    motm_card_enabled = 1,
    motm_card_duration = 22.0,

    stats_poll_ms = 350,
    position_poll_ms = 120,

    hotkey_demo_preview = 0x77,
    hotkey_reshow_card = 0x78,
    hotkey_cycle_replay_cam = 0x76,

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
-- 4. Raw memory layer (FFI / ReadProcessMemory / simulation)
-- ============================================================================
-- m.load(addr, len) fills rbuf and returns true on success.
-- m.u32(off) / m.u16(off) / m.u8(off) / m.f32(off) read from rbuf.
-- Reading through ReadProcessMemory means an invalid address returns false
-- instead of raising an access violation (which would kill the game).
function m.load(addr, len)
    if type(addr) ~= "number" or addr < 0x10000 then return false end
    if len == nil or len <= 0 or len > RBUF_LEN then return false end
    if m.sim then
        local s = m.sim(addr, len)
        if type(s) ~= "string" or #s < len then return false end
        ffi.copy(rbuf, s, len)
        return true
    end
    if not ffi_ok then return false end
    if C.FC27_ReadProcessMemory(PROC, ffi.cast("void *", addr), rbuf, len, rn) == 0 then
        return false
    end
    return tonumber(rn[0]) == len
end

function m.u8(off)
    return ffi.cast("uint8_t *", rbuf + off)[0]
end

function m.u16(off)
    return ffi.cast("uint16_t *", rbuf + off)[0]
end

function m.u32(off)
    return ffi.cast("uint32_t *", rbuf + off)[0]
end

function m.f32(off)
    return ffi.cast("float *", rbuf + off)[0]
end

-- Read a single u32 / f32 by address (convenience, one RPM call each).
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
    return ffi.string(rbuf, len)
end

-- Large read (Player.bin image, .text scans). Goes through ReadProcessMemory
-- in 1 MB chunks so an unmapped page returns nil instead of raising an access
-- violation inside the game process.
local BIG_LEN = 1024 * 1024
local big = ffi_ok and ffi.new("uint8_t[?]", BIG_LEN) or nil

function m.read_big(addr, len)
    if type(addr) ~= "number" or addr < 0x10000 then return nil end
    if len == nil or len <= 0 or len > 128 * 1024 * 1024 then return nil end
    if m.sim then
        local s = m.sim(addr, len)
        if type(s) ~= "string" or #s < len then return nil end
        return string.sub(s, 1, len)
    end
    if not ffi_ok then return nil end
    local parts = {}
    local done = 0
    while done < len do
        local want = len - done
        if want > BIG_LEN then want = BIG_LEN end
        if C.FC27_ReadProcessMemory(PROC, ffi.cast("void *", addr + done), big, want, rn) == 0 then
            return nil
        end
        if tonumber(rn[0]) ~= want then return nil end
        parts[#parts + 1] = ffi.string(big, want)
        done = done + want
    end
    return table.concat(parts)
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
    if ffi_ok then
        local ok, n = true, nil
        n = tonumber(ffi.cast("uint64_t", ffi.cast("void *", p)))
        if n and n > 0x10000 then return n end
        return nil
    end
    local hx = memory and memory.hex and memory.hex(p)
    if hx then return parse_hex(hx) end
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
    added = 0,
    period = 0,
    paused = false,
    running = false,
    stage = 0,
    mis = 0,
    sci = 0,
    sci2 = 0,
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
local function refresh_teams_periodic(now)
    if now < teams_refresh_at then return end
    teams_refresh_at = now + 2000
    refresh_teams()
    m.xi_cache = nil   -- substitutions change the on-pitch XI
end

function m.refresh_match(force)
    local ctx = m.ctx
    if ctx == nil then return end

    local mis = m.ptr_num(ctx.mis)
    if mis then
        if mis ~= m.match.mis then
            m.match.mis = mis
            m.match.home.color = nil
            m.match.away.color = nil
            m.squad_cache = nil
            refresh_teams()
        end
    end

    local st = nil
    if match and match.stats then st = match.stats() end
    if st then
        if st.ptr then
            local sci = m.ptr_num(st.ptr)
            if sci and sci ~= m.match.sci then
                m.match.sci = sci
                m.match.sci2 = m.read_u64(sci + OFF.S_SCI2) or 0
            end
        end
        m.match.home.score = st.home_score or m.match.home.score
        m.match.away.score = st.away_score or m.match.away.score
        m.match.clock_min = st.clock_minutes or 0
        m.match.clock_sec = st.clock_seconds or 0
        m.match.added = st.added_minutes or 0
        m.match.period = st.period or 0
        m.match.valid = true
    end

    refresh_teams_periodic(now_ms())

    local sci = m.match.sci
    if sci and sci ~= 0 then
        if m.load(sci + OFF.S_PAUSED, 4) then
            m.match.paused = (m.u8(0) ~= 0)
            m.match.running = (m.u8(2) ~= 0)
        end
        local sci2 = m.match.sci2
        if sci2 and sci2 ~= 0 then
            if m.load(sci2 + OFF.S2_MATCH_STAGE, 1) then
                m.match.stage = m.u8(0)
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
-- 9. Private heap region discovery (VirtualQueryEx, in process)
-- ============================================================================
m.reg = { stats = 0, pitch = 0, ok = false, tries = 0 }

local function valid_region(base, size_field)
    if not m.load(base, 12) then return false end
    return m.u32(0) == 0 and m.u32(4) == size_field and m.u32(8) == 1
end

local function scan_regions()
    if not ffi_ok then return false end
    local mbi = ffi.new("FC27_MBI[1]")
    local mbi_sz = ffi.sizeof(mbi)
    local page_sz = 4096
    local addr = 0x10000
    local steps = 0
    while steps < 120000 do
        steps = steps + 1
        if C.FC27_VirtualQuery(ffi.cast("const void *", addr), mbi, mbi_sz) == 0 then
            break
        end
        local base = tonumber(ffi.cast("uint64_t", mbi[0].BaseAddress))
        local size = tonumber(mbi[0].RegionSize)
        local state = mbi[0].State
        if size == 0 then break end
        if state == 0x1000 then          -- MEM_COMMIT
            if m.reg.stats == 0 and size == REGION_STATS_SIZE + 0x20 then
                if valid_region(base, REGION_STATS_SIZE) then
                    m.reg.stats = base
                    log_msg("stats region @ " .. hex(base))
                end
            elseif m.reg.pitch == 0 and size == REGION_PITCH_SIZE + 0x20 then
                if valid_region(base, REGION_PITCH_SIZE) then
                    m.reg.pitch = base
                    log_msg("pitch region @ " .. hex(base))
                end
            end
        end
        if m.reg.stats ~= 0 and m.reg.pitch ~= 0 then break end
        addr = base + size
        if addr >= 0x7FFFFFFF0000 then break end
        if addr % page_sz ~= 0 then break end
    end
    m.reg.ok = (m.reg.stats ~= 0)
    if steps >= 120000 then
        log_once("scancap", "region scan hit its step cap - pin the base address in FC27_Broadcast.ini", 60000)
    end
    if not m.reg.ok then
        log_once("noscan", "stats region not found yet (scan #" ..
                 tostring(m.reg.tries) .. ")", 30000)
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
-- 10. Per-player stat records
-- ============================================================================
local function rec_addr(side, idx)
    if m.reg.stats == 0 then return nil end
    return m.reg.stats + OFF.REC_BASE + side * OFF.REC_SIDE + idx * OFF.REC_IDX
end
m.rec_addr = rec_addr

-- sum of the 8 period buckets for stat kind `k`, buffer relative
local function sum8(off)
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
    [1] = { h0 = 0.28, h3 = 0.95, zoom = 0.56 },   -- HyperMotion low sweep
    [2] = { h0 = 0.62, h3 = 1.45, zoom = 0.82 },   -- elevated broadcast
    [3] = nil,
}

function m.cam_init()
    local enabled = cfg_i("replay_camera_enabled", 1) ~= 0
    m.cam.preset = clamp(cfg_i("replay_camera_preset", 1), 1, 3)

    -- preset 1 is the HyperMotion sweep and its three values are tunable
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
    if not ffi_ok then return false end
    local buf = ffi.new("float[1]")
    buf[0] = value
    return m.poke(addr, ffi.string(buf, 4))
end

-- Write `len` bytes from string `s` at `addr`, temporarily making the page RW.
function m.poke(addr, s)
    if type(addr) ~= "number" or addr < 0x10000 then return false end
    if not ffi_ok then return false end
    local len = #s
    if len <= 0 or len > 64 then return false end
    local old = ffi.new("uint32_t[1]")
    local ok = m.VirtualProtect(ffi.cast("void *", addr), len, 0x04, old) -- RW
    if ok == 0 then return false end
    ffi.copy(ffi.cast("void *", addr), s, len)
    m.VirtualProtect(ffi.cast("void *", addr), len, old[0], old)
    return true
end

-- VirtualProtect is already declared by Sider's memory library; declare it
-- under our own alias so this module works even if that ever changes.
if ffi_ok and not ffi.FC27_vp then
    ffi.cdef [[
        int FC27_VirtualProtect(void *addr, size_t len, uint32_t prot,
                                uint32_t *old)
            __asm__("VirtualProtect");
    ]]
    ffi.FC27_vp = true
end

function m.VirtualProtect(p, len, prot, old)
    return C.FC27_VirtualProtect(p, len, prot, old)
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
    last_write = 0,
    last_seq = 0,
    errors = 0,
}

function m.init_state_path(ctx)
    local dir = (ctx and ctx.sider_dir or "") .. "content\\fc27-broadcast"
    if fs and fs.make_dirs then fs.make_dirs(dir) end
    m.state.dir = dir
    m.state.path = dir .. "\\state.json"
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

local function player_snapshot(side, idx)
    local pid = m.squad_id(side, idx)
    local info = m.player_info(pid)
    local st = m.read_player_stats(side, idx)
    local name = (info and info.name) or ("PLAYER " .. tostring(idx + 1))
    local shirt = (info and info.shirt) or 0
    local pos = (info and info.pos) or ""
    if cfg_i("show_position", 1) == 0 then pos = "" end
    local rating = st and st.rating or nil
    return {
        pid = pid or 0,
        name = string.upper(name),
        shirt = shirt,
        pos = pos,
        rating = rating or 0,
        goals = st and (st.goals + st.own_goals) or 0,
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

local function team_of(side)
    local t = m.match[side == 0 and "home" or "away"]
    return { name = t.name, abbr = t.abbr, color = t.color or "#AEFF00", side = side }
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
        dur = cfg_f("goal_telemetry_duration", 16.0)
    end

    local ev = push_event(is_goal and "goal" or "shot", side, idx, {
        player = p,
        team = team_of(side),
        shot = tel,
        stats = shot_stats,
        duration = dur,
        remaining = dur,
    })
    if is_goal then
        -- let the celebration breathe for a moment, then show the card as the
        -- replay starts (0 disables the delay)
        ev.show_at = ev.started + clamp(cfg_f("goal_telemetry_delay", 1.2), 0, 8) * 1000
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
    local best = nil
    for side = 0, 1 do
        for idx = 0, 39 do
            local g, og, as, sh, ot = read_head(side, idx)
            if g then
                local prev = m.ps[side][idx]
                m.ps[side][idx] = { g = g, og = og, as = as, sh = sh, ot = ot }
                if prev and m.baselined then
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
            units = (cfg.units == "metric") and "metric" or "imperial",
            theme = cfg_s("theme", "eafc"),
            scorebug = (cfg_i("show_scorebug", 0) ~= 0),
            scale_hint = 1.0,
            remember = false,
        },
        status = {
            ffi = ffi_ok,
            stats_region = (m.reg.stats ~= 0),
            pitch_region = (m.reg.pitch ~= 0),
            camera = m.cam.ok,
            player_db = m.db_ready,
            names = m.db_ready and "Player.bin" or "none",
            events = m.ev_id,
        },
        match = {
            clock = m.clock_str(),
            period = m.match.period,
            stage = m.match.stage,
            live = m.match.running and not m.match.paused,
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
        },
    }

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
            player = {
                name = p.name or "",
                shirt = p.shirt or 0,
                pos = p.pos or "",
                rating = round(p.rating or 0, 1),
            },
            team = {
                name = (ev.team and ev.team.name) or "",
                abbr = (ev.team and ev.team.abbr) or "",
                color = (ev.team and ev.team.color) or "#AEFF00",
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

    local ok_open = false
    local f
    if io and io.open then
        f = io.open(m.state.path, "wb")
    end
    if not f then
        m.state.errors = m.state.errors + 1
        log_once("stateopen", "cannot write state file: " .. tostring(m.state.path), 20000)
        return
    end
    f:write(m.json_encode(build_state(now)))
    f:close()
    return true
end

-- ---- overlay text (Sider 7.3.4: 2 return values, no colour table) ---------
function m.overlay_text()
    local out = {}
    out[#out + 1] = m.NAME .. " v" .. m.VERSION

    local home, away = m.match.home, m.match.away
    out[#out + 1] = string.format("%s %d - %d %s   %s", home.abbr or "", home.score or 0,
        away.score or 0, away.abbr or "", m.clock_str())

    local ev = m.ev
    if ev then
        local p = ev.player or {}
        local s = ev.stats or {}
        local title = (ev.kind == "motm") and "MAN OF THE MATCH"
                      or (ev.kind == "goal") and "GOAL"
                      or "SHOT"
        out[#out + 1] = string.format("%s  %s #%d (%s)", title, p.name or "",
            p.shirt or 0, (ev.team and ev.team.abbr) or "")
        if ev.shot then
            local sh = ev.shot
            out[#out + 1] = string.format("%s  %s  %0.1f deg  %s  xG %0.2f",
                units_mph(sh.speed_mph, sh.speed_kmh),
                units_dist(sh.distance_yd, sh.distance_m),
                sh.angle_deg,
                sh.outcome or "",
                sh.xg or 0)
        end
        out[#out + 1] = string.format("SHOTS %d  ON TARGET %d  GOALS %d  ASSISTS %d  G/A %d",
            s.shots or 0, s.on_target or 0, s.goals or 0, s.assists or 0, s.ga or 0)
    else
        out[#out + 1] = "F8 demo   F7 camera preset   F9 reshow"
    end

    if not ffi_ok then
        out[#out + 1] = "WARNING: luajit.ext.enabled = 1 required for live stats"
    elseif m.reg.stats == 0 then
        out[#out + 1] = "searching stat region ..."
    end
    return table.concat(out, "\n")
end

-- ============================================================================
-- 17. Hotkeys / demo
-- ============================================================================
local demo_cycle = 0

function m.demo_preview()
    demo_cycle = demo_cycle + 1
    local phase = (demo_cycle - 1) % 3
    if phase == 0 then
        local ev = fire_shot_event(0, 4, "goal", { shots = 4, on_target = 3, goals = 2, assists = 1, ga = 3 })
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

function m.tick(now)
    now = now or now_ms()
    if (now - TICK.last) < 8 then return end
    TICK.last = now

    -- match info
    if (now - m.poll.last_match) >= 200 then
        m.poll.last_match = now
        m.refresh_match()
    end

    -- region discovery: only while a match is going on, at most 3 attempts
    if not m.reg.ok and ffi_ok and m.match.valid and m.reg.tries < 3 then
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

    -- per player stats
    local stat_ms = cfg_i("stats_poll_ms", 350)
    if stat_ms < 100 then stat_ms = 100 end
    if m.reg.stats ~= 0 and (now - m.poll.last_stats) >= stat_ms then
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
        local rem = (ev.duration or 0) - (now - t0) / 1000
        if rem > (ev.duration or 0) then rem = ev.duration end
        ev.remaining = rem > 0 and rem or 0
        if now >= t0 and rem <= 0 then
            if ev.kind == "goal" then m.cam_restore() end
            m.ev = nil
        end
    end

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
function m.on_display_frame(ctx)
    m.ctx = ctx
    m.tick()
end

function m.on_goal_scored(ctx, goal)
    m.ctx = ctx
    if cfg_i("debug_log", 0) ~= 0 then
        log_msg("goal_scored: id=" .. tostring(goal.player_id) ..
                " away=" .. tostring(goal.home_or_away) ..
                " name=" .. tostring(goal.player_name_on_shirt))
    end
    -- The stat poll normally catches the goal; this handler only covers the
    -- case where the stat region is still being discovered.
    if m.reg.stats == 0 or not m.baselined then
        local side = goal.home_or_away or 0
        local ev = {
            id = m.ev_id + 1,
            kind = "goal",
            side = side,
            idx = 0,
            started = now_ms(),
            duration = cfg_f("goal_telemetry_duration", 16.0),
            remaining = cfg_f("goal_telemetry_duration", 16.0),
            player = {
                name = string.upper(tostring(goal.player_name_on_shirt or "GOAL")),
                shirt = 0, pos = "", rating = 0,
            },
            team = team_of(side),
            stats = { shots = 0, on_target = 0, goals = 1, assists = 0, ga = 1 },
        }
        m.ev_id = ev.id
        m.ev = ev
        m.last_ev = ev
        m.cam_start(ev.duration)
    end
end

function m.on_set_teams(ctx)
    m.ctx = ctx
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

function m.on_key_down(ctx, vkey)
    m.ctx = ctx
    local k_demo = cfg_i("hotkey_demo_preview", 0x77)
    local k_reshow = cfg_i("hotkey_reshow_card", 0x78)
    local k_cam = cfg_i("hotkey_cycle_replay_cam", 0x76)

    if vkey == k_demo then
        m.demo_preview()
    elseif vkey == k_reshow then
        if m.last_ev then
            local ev = m.last_ev
            ev.started = now_ms()
            ev.remaining = ev.duration
            m.ev = ev
            if ev.kind == "goal" then m.cam_start(ev.duration) end
        elseif m.motm then
            m.show_motm()
        end
    elseif vkey == k_cam then
        m.cam.preset = (m.cam.preset % 3) + 1
        log_msg("replay camera preset -> " .. tostring(m.cam.preset))
    end
end

function m.on_overlay_on(ctx)
    m.ctx = ctx
    m.tick()
    return m.overlay_text()
end

-- ============================================================================
-- 20. Companion auto-launch
-- ============================================================================
local launched = false

function m.launch_companion(ctx)
    if launched then return end
    if cfg_i("auto_launch_companion", 1) == 0 then return end
    local sider = (ctx and ctx.sider_dir) or ""
    if sider ~= "" then
        local tail = string.sub(sider, -1)
        if tail ~= "\\" and tail ~= "/" then sider = sider .. "\\" end
    end
    local candidates = {
        sider .. "fc27-overlay\\FC27_Overlay.exe",
        sider .. "fc27-overlay/FC27_Overlay.exe",
        sider .. "overlay\\FC27_Overlay.exe",
        sider .. "..\\fc27-overlay\\FC27_Overlay.exe",
    }
    local exe = nil
    for i = 1, #candidates do
        local f = io.open(candidates[i], "rb")
        if f then
            f:close()
            exe = candidates[i]
            break
        end
    end
    if not exe then
        log_once("noexe",
            "companion not built yet - run fc27-overlay\\Start_FC27_Overlay.bat once", 120000)
        return
    end
    launched = true

    -- Preferred: WinExec through FFI - no console window flash, no cmd.exe.
    if ffi_ok and C and C.FC27_WinExec then
        local rc = C.FC27_WinExec('"' .. exe .. '"', 1)
        if rc and rc > 31 then
            log_msg("companion launched: " .. exe)
            return
        end
    end

    -- Fallback: shell out with "start" (works even without FFI).
    if io and io.popen then
        local p = io.popen('start "" "' .. exe .. '"', "r")
        if p then p:close() end
        log_msg("companion launch requested: " .. exe)
        return
    end

    log_msg("companion found but could not be started: " .. exe)
end

-- ============================================================================
-- 21. init
-- ============================================================================
function m.init(ctx)
    m.ctx = ctx
    log_msg(string.format("%s v%s starting (Sider 7.3.4 / LuaJIT)", m.NAME, m.VERSION))

    -- configuration
    local sdir = ctx and ctx.sider_dir or ""
    local ini_path = sdir .. "modules\\FC27_Broadcast.ini"
    local f = io.open(ini_path, "r")
    if not f then
        ini_path = sdir .. "modules/FC27_Broadcast.ini"
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

    -- handlers (kept on m so the module table cannot be collected)
    ctx.register("display_frame", m.on_display_frame)
    ctx.register("livecpk_data_ready", m.on_livecpk_data_ready)
    ctx.register("set_teams", m.on_set_teams)
    ctx.register("set_match_settings", m.on_set_teams)
    ctx.register("goal_scored", m.on_goal_scored)
    ctx.register("context_reset", m.on_context_reset)
    ctx.register("key_down", m.on_key_down)
    ctx.register("overlay_on", m.on_overlay_on)

    -- replay camera pattern scan (cached for the whole session)
    m.cam_init()

    -- optional early region hint from the INI
    apply_region_override()

    -- first state file so the companion can start straight away
    m.write_state(now_ms())

    m.launch_companion(ctx)
    log_msg("ready")
end

-- ============================================================================
-- 22. Test hooks (used by tools/verify_mod.py, harmless in game)
-- ============================================================================
m._test = {
    read_head = read_head,
    detect_events = function() return detect_events() end,
    set_cfg = function(t) for k, v in pairs(t) do cfg[k] = v end end,
    set_region = function(s, p) m.reg.stats = s or 0; m.reg.pitch = p or 0; m.reg.ok = (m.reg.stats ~= 0) end,
    reset = function() m.ev = nil; m.baselined = false; m.ps = { [0] = {}, [1] = {} }; m.fx = {} end,
    state = function() return build_state(now_ms()) end,
}

return m
