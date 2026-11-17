-- ============================================================================
--  tools/verify_mod.lua
--  Offline functional test harness for modules/NGB_Presentation.lua
--
--  Runs under LuaJIT (driven by tools/verify_mod.py through the `lupa`
--  package). It rebuilds a miniature PES 2021 / FL_2025 memory image in
--  process memory and feeds it to the real module through its documented
--  `m.sim` hook, so the complete detection pipeline (baseline -> shot ->
--  goal -> own goal -> MOTM -> state.json) is executed exactly as it will
--  run inside the game.
--
--  The harness reports a table of { name, ok, detail } records.
-- ============================================================================

local ffi = require("ffi")

local RESULTS = {}
local function check(name, ok, detail)
    RESULTS[#RESULTS + 1] = { name = name, ok = ok and true or false,
                              detail = (detail == nil) and "" or tostring(detail) }
end

local function nearm(a, b, tol)
    return math.abs(a - b) <= (tol or 1e-6)
end

-- ---------------------------------------------------------------------------
-- 1. Static helpers that do not need a module instance
-- ---------------------------------------------------------------------------
local SRC = MODSRC
local SIDER_DIR = SIDERDIR

-- FFI shim: the pure parts (new/copy/string/cast/sizeof) are the real LuaJIT
-- ones, only the Win32 entry points are stubbed, so the module can be loaded
-- on a non-Windows machine.
local realffi = ffi
local fakeC = {
    NGB_GetTickCount64 = function() return 0 end,
    NGB_GetCurrentProcess = function() return nil end,
    NGB_ReadProcessMemory = function() return 0 end,
    NGB_VirtualQuery = function() return 0 end,
    NGB_VirtualProtect = function() return 1 end,
}
local ffi_stub = setmetatable({ C = fakeC }, {
    __index = function(_, k) return realffi[k] end,
    __newindex = function(_, k, v) realffi[k] = v end,
})

local env = {
    log = function(s) RAWLOG[#RAWLOG + 1] = tostring(s) end,
    io = {
        open = function(path, mode)
            return io.open(string.gsub(path, "\\", "/"), mode)
        end,
        popen = function() return nil end,
    },
    fs = { make_dirs = function() return nil end, find_files = function() return function() return nil end end },
    zlib = {
        unpack = function(s)
            if ZLIB_PAYLOAD then return ZLIB_PAYLOAD end
            return s
        end,
    },
    match = { stats = function() return MATCH_STATS end },
    os = os, string = string, math = math, table = table,
    tonumber = tonumber, tostring = tostring, type = type,
    pairs = pairs, ipairs = ipairs, unpack = unpack, error = error,
    assert = assert, collectgarbage = collectgarbage, _VERSION = _VERSION,
    ffi = ffi_stub,
}

-- Accidental global writes are a classic source of "works on my machine" bugs,
-- so make them loud: any write to a *new* key of the sandbox is an error.
setmetatable(env, {
    __newindex = function(_, k, _)
        error("accidental global write in module: " .. tostring(k), 2)
    end,
})

local chunk, lerr = loadstring(SRC, "NGB_Presentation.lua")
if not chunk then
    check("module loads", false, lerr)
    -- ---------------------------------------------------------------------------
-- 11. Presentation controls (the 7 / 8 / 9 hotkeys)
-- ---------------------------------------------------------------------------
local function hud_now() return m._test.state().hud end

m._test.reset()
m.ev = nil
m.toast = nil
clock_ms = clock_ms + 400; m.tick(clock_ms)

local h0 = hud_now()
check("controls: default style is full", h0.style == 0, h0.style)
check("controls: analysis on by default", h0.analysis == true, tostring(h0.analysis))

-- overlay closed -> digits are ignored, so the game keeps its own 7/8/9 keys
m.on_key_down(CTX, 0x37)
check("hotkey [7] ignored while the overlay is closed", hud_now().style == h0.style,
      hud_now().style)
m.on_key_down(CTX, 0x38)
check("hotkey [8] ignored while the overlay is closed", hud_now().master == h0.master,
      tostring(hud_now().master))

-- overlay open -> 7 cycles the style, 9 toggles analysis, 8 toggles the master
m.on_overlay_on(CTX)
m.on_key_down(CTX, 0x37)
check("hotkey [7] cycles style", hud_now().style == 1, hud_now().style)
m.on_key_down(CTX, 0x37)
check("hotkey [7] cycles style again", hud_now().style == 2, hud_now().style)
m.on_key_down(CTX, 0x37)
check("hotkey [7] wraps back to full", hud_now().style == 0, hud_now().style)
check("hotkey toast exposed in state", hud_now().toast ~= nil
      and hud_now().toast.kind == "style", hud_now().toast and hud_now().toast.text)

m.on_key_down(CTX, 0x39)
check("hotkey [9] disables shot analysis", hud_now().analysis == false, tostring(hud_now().analysis))
m.on_key_down(CTX, 0x39)
check("hotkey [9] enables shot analysis", hud_now().analysis == true, tostring(hud_now().analysis))

-- F7 / F8 / F9 must not be bound
local before_style = hud_now().style
local before_master = hud_now().master
local before_analysis = hud_now().analysis
m.on_key_down(CTX, 0x76); m.on_key_down(CTX, 0x77); m.on_key_down(CTX, 0x78)
check("no F7 / F8 / F9 hotkeys", hud_now().style == before_style
      and hud_now().master == before_master and hud_now().analysis == before_analysis)

-- master switch really stops new cards
m._test.set_region(STATS_BASE, PITCH_BASE)
m.ev = nil
m.baselined = false
clock_ms = clock_ms + 400; m.tick(clock_ms)
clock_ms = clock_ms + 400; m.tick(clock_ms)
m.on_key_down(CTX, 0x38)
check("hotkey [8] switches the presentation off", hud_now().master == false, tostring(hud_now().master))
m.ev = nil
set_stat(0, 4, 0, 4)
clock_ms = clock_ms + 400; m.tick(clock_ms)
clock_ms = clock_ms + 400; m.tick(clock_ms)
check("presentation off: no new card", m.ev == nil, m.ev and m.ev.kind)
m.on_key_down(CTX, 0x38)
check("hotkey [8] switches the presentation back on", hud_now().master == true, tostring(hud_now().master))

return RESULTS
end
setfenv(chunk, env)
local m = chunk()

check("module returns table with init", type(m) == "table" and type(m.init) == "function",
      type(m))
check("module version string", type(m.VERSION) == "string", m.VERSION)

-- ---------------------------------------------------------------------------
-- 2. Pure functions
-- ---------------------------------------------------------------------------
local cfg = m.parse_ini([[
# comment
units = metric
stats_poll_ms = 500   // inline comment
[section]
replay_zoom = 0.5
]])
check("ini: parses keys", cfg.units == "metric" and cfg.stats_poll_ms == "500"
      and cfg.replay_zoom == "0.5", cfg.stats_poll_ms)
check("ini: comment stripped", tostring(cfg.stats_poll_ms) == "500", cfg.stats_poll_ms)

check("hex parser", m.parse_hex("0x7FF6A000") == 0x7FF6A000, m.parse_hex("0x10"))

-- bit unpacking (Player.bin layout): value = bits + addend
-- simpler, always correct bit writer used for the fixtures below
local function wr_bits(buf, off, shift, bits, value)
    for i = 0, bits - 1 do
        local p = shift + i
        local idx = off + math.floor(p / 8)
        local b = ffi.cast("uint8_t *", buf + idx)[0]
        local mask = 2 ^ (p % 8)
        local bitv = math.floor(value / (2 ^ i)) % 2
        if bitv == 1 then
            b = b + mask - (b % (mask * 2) >= mask and mask or 0)
        else
            b = b - (b % (mask * 2) >= mask and mask or 0)
        end
        ffi.cast("uint8_t *", buf + idx)[0] = b
    end
end

local probe = ffi.new("uint8_t[8]")
wr_bits(probe, 2, 3, 6, 21)          -- 21 in a 6 bit field at shift 3
local packed = ffi.string(probe, 8)
local got = m.read_bits(packed, 2, 3, 6, 0)
check("read_bits: 6 bit field", got == 21, got)
wr_bits(probe, 0, 0, 8, 87)
local got2 = m.read_bits(ffi.string(probe, 8), 0, 0, 8, 100)
check("read_bits: addend", got2 == 187, got2)

-- xG model
local near = m.xg(6, 1.1)
local far = m.xg(30, 0.3)
check("xg: near > far", near > far and near > 0.2 and far < 0.15,
      string.format("near=%.3f far=%.3f", near, far))
check("xg: clamped", m.xg(0.5, 3.0) <= 0.95 and m.xg(80, 0.01) >= 0.02)

-- speed model
check("shot speed rises with kicking power",
      m.shot_speed(18, 95) > m.shot_speed(18, 60),
      string.format("%.1f vs %.1f", m.shot_speed(18, 95), m.shot_speed(18, 60)))
local mph = m.shot_speed(18, 90) * 2.2369363
check("shot speed in a realistic band", mph > 45 and mph < 95, string.format("%.1f mph", mph))

-- ballistics: elevation must actually reach the requested height
local dist, v = 20, 30
local elev = m.solve_elevation(dist, 1.2, v)
local vx, vz = v * math.cos(elev), v * math.sin(elev)
local tflight = dist / vx
local h = vz * tflight - 0.5 * 9.81 * tflight * tflight
check("ballistics reach the aim height", nearm(h, 1.2, 0.05), string.format("%.3f", h))

-- ---------------------------------------------------------------------------
-- 3. Memory image
-- ---------------------------------------------------------------------------
local REGIONS = {}
local function region(base, size)
    local r = { base = base, size = size, buf = ffi.new("uint8_t[?]", size) }
    REGIONS[#REGIONS + 1] = r
    return r
end
local function u8(r, off, v)  ffi.cast("uint8_t *", r.buf + off)[0] = v end
local function u32(r, off, v) ffi.cast("uint32_t *", r.buf + off)[0] = v end
local function f32(r, off, v) ffi.cast("float *", r.buf + off)[0] = v end
local function str(r, off, s) ffi.copy(r.buf + off, s, #s) end

local function sim_read(addr, len)
    for i = 1, #REGIONS do
        local r = REGIONS[i]
        if addr >= r.base and (addr + len) <= (r.base + r.size) then
            return ffi.string(r.buf + (addr - r.base), len)
        end
    end
    return nil
end

local MIS_BASE   = 0x200000000
local SCI_BASE   = 0x200010000
local SCI2_BASE  = 0x200011000
local STATS_BASE = 0x300000000
local PITCH_BASE = 0x400000000
local PBIN_BASE  = 0x500000000

local mis  = region(MIS_BASE, 0x2000)
local sci  = region(SCI_BASE, 0x200)
local sci2 = region(SCI2_BASE, 0x200)
local stats = region(STATS_BASE, 0x190000)
local pitch = region(PITCH_BASE, 0xF0000)

-- region headers (what the in-game VirtualQuery scan looks for)
u32(stats, 0, 0); u32(stats, 4, 0x18FFE0); u32(stats, 8, 1)
u32(pitch, 0, 0); u32(pitch, 4, 0xEFFE0); u32(pitch, 8, 1)

-- MATCH_INFO_STRUCT
str(mis, 0x138 + 0x04, "Arsenal")
str(mis, 0x138 + 0x4A, "ARS")
u8(mis, 0x138 + 0x5D8 + 0, 0); u8(mis, 0x138 + 0x5D8 + 2, 239)
u8(mis, 0x138 + 0x5D8 + 3, 1); u8(mis, 0x138 + 0x5D8 + 4, 7)

str(mis, 0x7C8 + 0x04, "Chelsea")
str(mis, 0x7C8 + 0x4A, "CHE")
u8(mis, 0x7C8 + 0x5D8 + 2, 3); u8(mis, 0x7C8 + 0x5D8 + 3, 70)
u8(mis, 0x7C8 + 0x5D8 + 4, 148)

for i = 0, 39 do
    u32(mis, 0x288 + i * 4, 100000 + i)             -- home roster
    u32(mis, 0x288 + 0x690 + i * 4, 200000 + i)     -- away roster
end
for i = 0, 10 do
    u8(mis, 0x1078 + i, i)                          -- home XI = roster 0..10
    u8(mis, 0x12D0 + i, i)                          -- away XI = roster 0..10
end

-- SCOREBOARD_INFO
u32(sci, 0x38, SCI2_BASE)
u8(sci, 0x20, 0)      -- not paused
u8(sci, 0x22, 1)      -- clock running
u32(sci, 0x120, 0)    -- home score
u32(sci, 0x124, 0)    -- away score
u32(sci, 0x12C, 12)   -- clock minutes
u32(sci, 0x130, 30)   -- clock seconds
u32(sci, 0x144, 0)
u8(sci2, 0x88, 0x05)  -- live stage

-- pitch: home XI (0..10) and away XI (11..21), home attacks +x
local function set_pitch(entry, x, y, z)
    local off = 0x253FC + entry * 12
    f32(pitch, off, x); f32(pitch, off + 4, y); f32(pitch, off + 8, z or 0)
end
set_pitch(0, -47.0, 0.5, 0)       -- home keeper: home attacks +x
set_pitch(10, 41.0, -3.0, 0)      -- home GK is entry 0, so slot 10 is a striker
for slot = 1, 9 do set_pitch(slot, -10 + slot * 4, (slot - 5) * 4, 0) end
set_pitch(4, 35.0, 8.0, 0)        -- home shooter (slot 4) at 17.9 m
set_pitch(11, 47.0, -0.5, 0)      -- away keeper: away attacks -x
set_pitch(15, -35.0, -6.0, 0)     -- away shooter (slot 4) at 17.9 m
for slot = 1, 9 do set_pitch(11 + slot, 10 - slot * 4, (slot - 5) * -4, 0) end

-- stat record helpers
local REC_BASE, REC_SIDE, REC_IDX, KIND_STRIDE = 0x7B5C0, 0x59650, 0x2134, 0x24
local function rec_off(side, idx)
    return REC_BASE + side * REC_SIDE + idx * REC_IDX
end
local function set_stat(side, idx, kind, value)
    u32(stats, rec_off(side, idx) + 8 + kind * KIND_STRIDE, value)
end

-- ---------------------------------------------------------------------------
-- 4. Player.bin fixture (WESYS + 312 byte records)
-- ---------------------------------------------------------------------------
local RECORD_LEN = 312
local NPLAYERS = 4
local plain = ffi.new("uint8_t[?]", RECORD_LEN * NPLAYERS)
local fixtures = {
    { id = 100000, name = "B. Saka",     shirt = 7,  pos = 10, height = 178, kp = 82, fin = 88 },
    { id = 100004, name = "M. Odegaard", shirt = 8,  pos = 8,  height = 178, kp = 80, fin = 84 },
    { id = 200000, name = "R. James",    shirt = 24, pos = 3,  height = 180, kp = 85, fin = 70 },
    { id = 200015, name = "C. Palmer",   shirt = 20, pos = 10, height = 189, kp = 86, fin = 85 },
}
for i, p in ipairs(fixtures) do
    local off = (i - 1) * RECORD_LEN
    u32({ buf = plain + off }, 8, p.id)
    ffi.cast("uint8_t *", plain + off + 129)[0] = p.shirt
    ffi.copy(plain + off + 251, p.name, #p.name)
    wr_bits(plain + off, 54, 2, 4, p.pos)
    wr_bits(plain + off, 27, 0, 8, p.height - 100)
    wr_bits(plain + off, 44, 6, 6, p.kp - 40)
    wr_bits(plain + off, 49, 4, 6, p.fin - 40)
end
local plain_str = ffi.string(plain, RECORD_LEN * NPLAYERS)
ZLIB_PAYLOAD = plain_str

local wesys = "\0\1\1WESYS" .. string.char(0, 0, 0, 0) .. string.char(0, 0, 0, 0) .. plain_str
local pbin = region(PBIN_BASE, #wesys)
str(pbin, 0, wesys)

-- ---------------------------------------------------------------------------
-- 5. Module initialisation against the simulated image
-- ---------------------------------------------------------------------------
local CTX = { sider_dir = SIDER_DIR .. "/", mis = MIS_BASE, register = function() end }
local clock_ms = 1000

m.sim = sim_read
m.sim_now = function() return clock_ms end
MATCH_STATS = {
    ptr = SCI_BASE, home_score = 0, away_score = 0,
    clock_minutes = 12, clock_seconds = 30, period = 1, added_minutes = nil,
}

m.init(CTX)
check("init: does not throw", true)
check("init: FFI detected", m._test ~= nil)
m._test.set_region(STATS_BASE, PITCH_BASE)
m._test.set_cfg({ stats_poll_ms = "0", position_poll_ms = "0", state_write_hz = "20" })

-- baseline tick (2 frames so the 8 ms gate and the poll gates open)
for i = 1, 3 do clock_ms = clock_ms + 200; m.tick(clock_ms) end
check("baseline captured", m.baselined == true)
check("teams resolved", m.match.home.name == "ARSENAL" and m.match.away.abbr == "CHE",
      m.match.home.name .. "/" .. m.match.away.abbr)
check("team colours read", tostring(m.match.home.color) == "#EF0107", tostring(m.match.home.color))
check("clock string", m.clock_str() == "12:30", m.clock_str())
check("pitch positions valid", m.pitch.valid == true, tostring(m.pitch.valid))
check("attack direction", m.pitch.dir == 1, tostring(m.pitch.dir))

-- Player.bin
m.on_player_bin(PBIN_BASE, #wesys)
check("Player.bin parsed", m.db_ready == true)
local saka = m.player_info(100000)
check("Player.bin name/shirt", saka and saka.name == "B. Saka" and saka.shirt == 7,
      saka and (saka.name .. "/" .. tostring(saka.shirt)))
check("Player.bin attributes", saka and saka.height == 178 and saka.kpower == 82
      and saka.finish == 88, saka and (saka.height .. "/" .. saka.kpower .. "/" .. saka.finish))
check("Player.bin position", saka and saka.pos == "RWF", saka and saka.pos)

-- roster -> Player.bin link
check("squad id resolves", m.squad_id(0, 0) == 100000, tostring(m.squad_id(0, 0)))
check("xi slot resolves", m.xi_slot(0, 4) == 4, tostring(m.xi_slot(0, 4)))

-- ---------------------------------------------------------------------------
-- 6. Feature 2: shot / miss / save popup
-- ---------------------------------------------------------------------------
set_stat(0, 4, 6, 3)    -- shots
set_stat(0, 4, 17, 2)   -- on target
clock_ms = clock_ms + 400; m.tick(clock_ms)
clock_ms = clock_ms + 400; m.tick(clock_ms)

local ev = m.ev
check("shot: event fired", ev ~= nil and ev.kind == "shot", ev and ev.kind)
check("shot: shooter identified", ev and ev.player and ev.player.pid == 100004,
      ev and tostring(ev.player and ev.player.pid))
check("shot: shooter name", ev and ev.player and ev.player.name == "M. ODEGAARD",
      ev and ev.player and ev.player.name)
check("shot: totals carried", ev and ev.stats and ev.stats.shots == 3
      and ev.stats.on_target == 2, ev and ev.stats and (ev.stats.shots .. "/" .. ev.stats.on_target))
check("shot: outcome on target", ev and ev.shot and ev.shot.outcome == "on_target",
      ev and ev.shot and ev.shot.outcome)

local sh = ev and ev.shot or {}
check("telemetry: distance plausible", sh.distance_m and sh.distance_m > 12 and sh.distance_m < 26,
      sh.distance_m)
check("telemetry: angle plausible", sh.angle_deg and sh.angle_deg > 5 and sh.angle_deg < 60,
      sh.angle_deg)
check("telemetry: imperial conversion", sh.distance_yd and nearm(sh.distance_yd, sh.distance_m * 1.0936133, 0.01),
      sh.distance_yd)
check("telemetry: speed mph", sh.speed_mph and sh.speed_mph > 40 and sh.speed_mph < 100, sh.speed_mph)
check("telemetry: apex/hang", (sh.apex_ft or 0) > 0 and (sh.hang_s or 0) > 0.3,
      tostring(sh.apex_ft) .. "/" .. tostring(sh.hang_s))
check("telemetry: xg range", sh.xg and sh.xg > 0 and sh.xg < 1, sh.xg)
check("telemetry: trajectory", type(sh.traj) == "table" and #sh.traj == 16, type(sh.traj) and #sh.traj)
check("telemetry: origin measured", sh.origin_source == "measured", sh.origin_source)
check("telemetry: goal-face target", sh.target_x and sh.target_y and math.abs(sh.target_x) < 4,
      tostring(sh.target_x) .. "/" .. tostring(sh.target_y))

-- ---------------------------------------------------------------------------
-- 7. Feature 1: goal event + replay camera window
-- ---------------------------------------------------------------------------
set_stat(0, 4, 6, 4)
set_stat(0, 4, 0, 1)    -- goal
set_stat(0, 0, 4, 1)    -- assist credited to a team mate (idx 0 = B. Saka)
MATCH_STATS.home_score = 1
u32(sci, 0x120, 1)
clock_ms = clock_ms + 400; m.tick(clock_ms)
clock_ms = clock_ms + 400; m.tick(clock_ms)

ev = m.ev
check("goal: event fired", ev ~= nil and ev.kind == "goal", ev and ev.kind)
check("goal: duration is telemetry length", ev and ev.duration and ev.duration >= 12,
      ev and ev.duration)
check("goal: G/A totals", ev and ev.stats and ev.stats.goals == 1 and ev.stats.ga == 1,
      ev and ev.stats and (ev.stats.goals .. "/" .. ev.stats.ga))
check("goal: assist attributed", ev and ev.assist and ev.assist.name == "B. SAKA",
      ev and ev.assist and ev.assist.name)
check("goal: opener milestone", ev and ev.milestone and ev.milestone.key == "opener",
      ev and ev.milestone and ev.milestone.label)
check("goal: milestone tone", ev and ev.milestone and ev.milestone.tone == "accent",
      ev and ev.milestone and ev.milestone.tone)
check("goal: minutes tracked", ev and type(ev.player.minutes) == "number"
      and ev.player.minutes >= 0, ev and tostring(ev.player.minutes))
check("goal: replay window armed", (m.goal_window_until or 0) > clock_ms, m.goal_window_until)
check("goal: card delayed into the replay", ev and ev.show_at and ev.show_at > ev.started,
      ev and ev.show_at and (ev.show_at - ev.started))
check("goal: card held back during the delay", ev and ev.remaining == 0,
      ev and tostring(ev.remaining))
clock_ms = clock_ms + 2000; m.tick(clock_ms)   -- past goal_telemetry_delay
ev = m.ev
check("goal: card appears after the delay",
      ev and ev.remaining and ev.remaining > 0 and ev.remaining <= ev.duration,
      ev and tostring(ev.remaining))

-- state.json
clock_ms = clock_ms + 200; m.tick(clock_ms)
local state = m._test.state()
check("state: schema version", state.v == 2, state.v)
check("state: hud master flag", state.hud.master ~= nil, tostring(state.hud.master))
check("state: hud style", state.hud.style ~= nil, tostring(state.hud.style))
check("state: hud analysis flag", state.hud.analysis ~= nil, tostring(state.hud.analysis))
check("state: credit line", state.hud.credit == "MOONFROS PRESENTS", tostring(state.hud.credit))
check("state: player minutes", state.event.player.minutes ~= nil,
      tostring(state.event.player.minutes))
check("state: milestone block", state.event.milestone ~= nil
      and state.event.milestone.label ~= nil, state.event.milestone and state.event.milestone.label)
check("state: assist block", state.event.assist ~= nil and state.event.assist.name ~= nil,
      state.event.assist and state.event.assist.name)
check("state: event block", state.event and state.event.kind == "goal", state.event and state.event.kind)
check("state: shot block present", state.event and state.event.shot ~= nil)
check("state: units", state.hud.units == "metric", state.hud.units)
local json = m.json_encode(state)
local f = io.open(string.gsub(SIDER_DIR, "\\", "/") .. "/content/ngb-presentation/state.json", "wb")
if f then f:write(json); f:close() end
check("state: json non empty", #json > 200, #json)

-- ---------------------------------------------------------------------------
-- 7b. milestones: brace and hat-trick
-- ---------------------------------------------------------------------------
m.ev = nil
set_stat(0, 4, 0, 2)
MATCH_STATS.home_score = 2
u32(sci, 0x120, 2)
clock_ms = clock_ms + 400; m.tick(clock_ms)
clock_ms = clock_ms + 400; m.tick(clock_ms)
ev = m.ev
check("milestone: brace", ev and ev.milestone and ev.milestone.key == "brace",
      ev and ev.milestone and ev.milestone.label)
check("milestone: brace label", ev and ev.milestone and ev.milestone.label == "BRACE",
      ev and ev.milestone and ev.milestone.label)

m.ev = nil
set_stat(0, 4, 0, 3)
MATCH_STATS.home_score = 3
u32(sci, 0x120, 3)
clock_ms = clock_ms + 400; m.tick(clock_ms)
clock_ms = clock_ms + 400; m.tick(clock_ms)
ev = m.ev
check("milestone: hat-trick", ev and ev.milestone and ev.milestone.key == "hat_trick",
      ev and ev.milestone and ev.milestone.label)
check("milestone: gold tone", ev and ev.milestone and ev.milestone.tone == "gold",
      ev and ev.milestone and ev.milestone.tone)
check("toast: hat-trick callout", m.toast ~= nil
      and string.find(m.toast.text, "HAT-TRICK", 1, true) ~= nil,
      m.toast and m.toast.text)

-- ---------------------------------------------------------------------------
-- 8. own goal
-- ---------------------------------------------------------------------------
m.ev = nil
set_stat(1, 6, 1, 1)    -- away player 6 own goal
clock_ms = clock_ms + 400; m.tick(clock_ms)
clock_ms = clock_ms + 400; m.tick(clock_ms)
ev = m.ev
check("own goal: detected", ev ~= nil and ev.kind == "goal" and ev.shot
      and ev.shot.outcome == "own_goal", ev and ev.shot and ev.shot.outcome)
check("own goal: aimed at own net", ev and ev.shot and ev.shot.target_x
      and ev.shot.target_x ~= nil)

-- ---------------------------------------------------------------------------
-- 9. Feature 3: MOTM
-- ---------------------------------------------------------------------------
m.ev = nil
-- give the home striker a monster game and the away keeper a good one
set_stat(0, 10, 0, 2); set_stat(0, 10, 4, 1); set_stat(0, 10, 6, 5)
set_stat(0, 10, 17, 4); set_stat(0, 10, 22, 34); set_stat(0, 10, 23, 30)
set_stat(0, 10, 67, 61); set_stat(0, 10, 65, 6); set_stat(0, 10, 66, 4)
u32(stats, rec_off(0, 10) + 8 + 179 * KIND_STRIDE, 0x41080000)   -- 8.5f
set_stat(1, 11, 133, 7)                                          -- keeper saves
set_stat(0, 4, 22, 20); set_stat(0, 4, 23, 15); set_stat(0, 4, 67, 40)
set_stat(0, 0, 67, 10); set_stat(0, 0, 22, 5); set_stat(0, 0, 23, 4)

-- full time
u32(sci, 0x12C, 90)
u8(sci, 0x22, 0)     -- clock stopped
MATCH_STATS.clock_minutes = 90
MATCH_STATS.period = 2
clock_ms = clock_ms + 400; m.tick(clock_ms)
clock_ms = clock_ms + 3000; m.tick(clock_ms)
clock_ms = clock_ms + 400; m.tick(clock_ms)

check("motm: computed", m.motm ~= nil, m.motm and m.motm.player.name)
if m.motm then
    check("motm: picks the hat-trick scorer", m.motm.player.pid == 100004,
          m.motm.player.name .. " #" .. tostring(m.motm.player.shirt))
    check("motm: rating", m.motm.rating and m.motm.rating >= 7 and m.motm.rating <= 10,
          m.motm.rating)
    check("motm: stat block", m.motm.stats.goals == 3 and m.motm.stats.shots == 4
          and m.motm.stats.pass_pct >= 70,
          m.motm.stats.goals .. "/" .. m.motm.stats.shots .. "/" .. m.motm.stats.pass_pct)
    check("motm: minutes carried", m.motm.player.minutes ~= nil,
          tostring(m.motm.player.minutes))
    check("motm: peak shot speed tracked", m.motm.stats.peak_mph and m.motm.stats.peak_mph > 40,
          m.motm.stats.peak_mph)
    check("motm: xg accumulated", m.motm.stats.xg and m.motm.stats.xg > 0, m.motm.stats.xg)
    check("motm: event is motm", m.ev ~= nil and m.ev.kind == "motm", m.ev and m.ev.kind)
    local stt = m._test.state()
    check("motm: in state json", stt.event and stt.event.kind == "motm"
          and stt.event.motm ~= nil)
end

-- ---------------------------------------------------------------------------
-- 10. Overlay text + robustness
-- ---------------------------------------------------------------------------
local text = m.overlay_text()
check("overlay text has score line", type(text) == "string" and
      string.find(text, "ARS", 1, true) ~= nil, #text)
check("overlay text respects units", string.find(text, "km/h", 1, true) ~= nil
      or string.find(text, "SHOTS", 1, true) ~= nil, "metric default")
check("overlay text carries the brand", string.find(text, "MOONFROS PRESENTS", 1, true) ~= nil)
check("overlay text shows the active state", string.find(text, "PRESENTATION", 1, true) ~= nil)
check("overlay text lists the hotkeys", string.find(text, "[7]", 1, true) ~= nil
      and string.find(text, "[8]", 1, true) ~= nil and string.find(text, "[9]", 1, true) ~= nil)

-- metric toggle
m._test.set_cfg({ units = "metric" })
local text2 = m.overlay_text()
check("metric toggle", m.units_mph(70, 112) == "112.0 km/h", m.units_mph(70, 112))
m._test.set_cfg({ units = "imperial" })

-- missing regions must not error
m._test.set_region(0, 0)
m._test.reset()
clock_ms = clock_ms + 400; m.tick(clock_ms)
check("no stats region: tick survives", true)
check("no stats region: state still valid", m._test.state().v == 2)

-- context reset clears everything
m.on_context_reset(CTX)
check("context reset clears event", m.ev == nil and m.baselined == false)
check("context reset clears regions", m.reg.stats == 0)

-- demo preview works without any region (pure fallback data)
m._test.set_region(STATS_BASE, PITCH_BASE)
local d = m.demo_preview()
check("demo preview produces event", d ~= nil and d.kind == "goal", d and d.kind)
check("demo telemetry estimated", d and d.shot and d.shot.origin_source ~= nil,
      d and d.shot and d.shot.origin_source)

return RESULTS
