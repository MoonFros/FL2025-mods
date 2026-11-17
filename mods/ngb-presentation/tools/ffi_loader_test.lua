-- ============================================================================
--  tools/ffi_loader_test.lua
--
--  The gap that let 2.0.1 ship a broken renderer bridge: the main harness has
--  no `ffi` at all, so every line inside m.load_renderer that touches the DLL
--  was dead code in every test run. This file closes that gap with a fake FFI
--  that behaves like the real one where it matters:
--
--    * GetProcAddress returns a "raw address" that CANNOT be called. Calling it
--      raises exactly the error the game reported:
--          [string "..."]: 'void' is not callable
--    * ffi.cast(signature, address) returns a real, callable Lua function.
--
--  So a call site that forgets the cast fails here with the same message a user
--  would see in sider.log, and a call site that casts works.
--
--  Run by verify_mod.py through lupa. Globals it expects:
--      MODSRC        the module source
--      SIDERDIR      a temp Sider folder (ngb-render/NGB_Render.dll must exist)
--  Returns a table of { name, ok, detail }.
-- ============================================================================

MODVERSION = MODVERSION or "0.0.0"   -- supplied by verify_mod.py

local RESULTS = {}
local function check(name, ok, detail)
    RESULTS[#RESULTS + 1] = { name = name, ok = ok and true or false,
                              detail = detail == nil and "" or tostring(detail) }
end

-- ---------------------------------------------------------------------------
--  the fake FFI
-- ---------------------------------------------------------------------------
local VOID = {}
VOID.__call = function(self)
    -- what LuaJIT says when you call a `void *`: this exact wording is what
    -- the user's sider.log contained
    error("'void' is not callable", 2)
end
VOID.__tostring = function(self) return "void*:" .. tostring(self.label) end

local EXPORTS = {}            -- export name -> the "DLL's" Lua implementation
local CASTS = {}              -- export name -> the signature it was cast with
local CALLS = {}              -- export name -> number of calls

local function raw_address(name)
    return setmetatable({ label = name }, VOID)
end

local function find_name(fn)
    for name, impl in pairs(EXPORTS) do
        if impl == fn then return name end
    end
    return "?"
end

local fake_ffi = {}
fake_ffi.C = {
    LoadLibraryA = function(path)
        if type(path) ~= "string" or path == "" then return nil end
        if fake_ffi.fail_load then return nil end
        return raw_address("HMODULE")
    end,
    GetProcAddress = function(handle, name)
        if handle == nil then return nil end
        if EXPORTS[name] then return raw_address(name) end
        return nil
    end,
    GetCurrentProcessId = function() return 4242 end,
    GetModuleFileNameA = function(mod, buf, size) return 0 end,
}

function fake_ffi.cdef()
    fake_ffi.cdef_called = (fake_ffi.cdef_called or 0) + 1
end

function fake_ffi.new(ctype, n)
    if type(ctype) == "string" and string.find(ctype, "char", 1, true) then
        return { buffer = true, size = n or 0 }
    end
    return { cdata = true }
end

-- The one that matters: cast turns a raw address into something callable.
function fake_ffi.cast(ctype, value)
    if type(ctype) ~= "string" then error("bad ctype", 2) end
    if type(value) == "table" and getmetatable(value) == VOID then
        local name = value.label
        local impl = EXPORTS[name]
        CASTS[name] = ctype
        if not impl then
            return function() error("unresolved symbol " .. tostring(name), 2) end
        end
        return function(...)
            CALLS[name] = (CALLS[name] or 0) + 1
            return impl(...)
        end
    end
    -- numbers and strings are returned as they are
    return value
end

function fake_ffi.string(value)
    if type(value) == "string" then return value end
    if type(value) == "table" and value.text then return value.text end
    return tostring(value)
end

fake_ffi.typeof = function() return function(v) return v end end

ffi = fake_ffi
_G.ffi = fake_ffi

-- ---------------------------------------------------------------------------
--  the "DLL"
-- ---------------------------------------------------------------------------
-- the DLL reports NGB_VERSION; keep it equal to the module's so a version bump
-- can never make this test pass by accident
local state_line = "version=" .. MODVERSION .. ";hooked=1;frames=1234;bb=1920x1080;" ..
                   "state_age_ms=42;state_seq=7;dead=0;read=1;query=1;" ..
                   "log=E:\\s\\content\\ngb-presentation\\ngb-dll.log"
local start_cfgs = {}

EXPORTS.NGB_Start = function(cfg)
    start_cfgs[#start_cfgs + 1] = cfg
    if fake_ffi.start_returns ~= nil then return fake_ffi.start_returns end
    return 1
end
EXPORTS.NGB_GetState = function() return state_line end
EXPORTS.NGB_Read = function(addr, buf, len) return len end
EXPORTS.NGB_Write = function(addr, buf, len) return len end
EXPORTS.NGB_Query = function(addr, b, s, p) return 1 end

-- ---------------------------------------------------------------------------
--  load the module with the fake ffi already in place
-- ---------------------------------------------------------------------------
local chunk, err = loadstring(MODSRC, "NGB_Presentation.lua")
if not chunk then
    check("ffi: module parses", false, err)
    return RESULTS
end
check("ffi: module parses", true)

local ok_env, m = pcall(chunk)
if not ok_env or type(m) ~= "table" then
    check("ffi: module loads with ffi present", false, tostring(m))
    return RESULTS
end
check("ffi: module loads with ffi present", true)

-- the raw address really is uncallable: this is the shipped bug, reproduced
local ok_call, callerr = pcall(function() return raw_address("demo")() end)
check("ffi: a bare GetProcAddress result is NOT callable (the 2.0.1 bug)",
      ok_call == false and string.find(tostring(callerr), "not callable", 1, true) ~= nil,
      tostring(callerr))

-- ---------------------------------------------------------------------------
--  exercise the loader
-- ---------------------------------------------------------------------------
local ctx = { sider_dir = SIDERDIR }
m.state = { dir = SIDERDIR .. "content\\ngb-presentation\\",
            path = SIDERDIR .. "content\\ngb-presentation\\state.json" }

local ok_load, res = pcall(m.load_renderer, ctx)
if not ok_load then
    check("ffi: load_renderer runs", false, tostring(res))
    return RESULTS
end
check("ffi: load_renderer runs", true, tostring(m.renderer.detail))

check("ffi: NGB_Start was called", (CALLS.NGB_Start or 0) == 1,
      (CALLS.NGB_Start or 0) .. " calls")
check("ffi: renderer state is dll", m.renderer.state == "dll",
      tostring(m.renderer.state))
check("ffi: every export was cast before use",
      CASTS.NGB_Start ~= nil and CASTS.NGB_GetState ~= nil
      and CASTS.NGB_Read ~= nil and CASTS.NGB_Write ~= nil
      and CASTS.NGB_Query ~= nil,
      "cast: " .. tostring(CASTS.NGB_Start))

local cfg = start_cfgs[1] or ""
check("ffi: config is a Lua string", type(cfg) == "string", type(cfg))
for _, key in ipairs({ "state_file=", "log_file=", "dir=", "version=",
                       "enabled=", "hotkey_selftest=", "hotkey_diag=",
                       "hotkey_kill=" }) do
    check("ffi: config carries " .. key, string.find(cfg, key, 1, true) ~= nil, cfg)
end
check("ffi: config uses ; separators", string.find(cfg, ";", 1, true) ~= nil)
check("ffi: config hotkeys are decimal",
      string.find(cfg, "hotkey_selftest=119", 1, true) ~= nil,   -- 0x77
      cfg)
check("ffi: config version is the module version",
      string.find(cfg, "version=" .. m.VERSION, 1, true) ~= nil)

-- NGB_GetState returns `const char *`: cdata in LuaJIT, not a Lua string
local status = m.renderer_status()
check("ffi: renderer_status parses NGB_GetState", status ~= nil)
if status then
    check("ffi: status version matches the module", status.version == m.VERSION,
          tostring(status.version))
    check("ffi: status frames", status.frames == "1234", tostring(status.frames))
    check("ffi: status backbuffer", status.bb == "1920x1080", tostring(status.bb))
    check("ffi: status log path", status.log ~= nil)
end

-- the memory backend must come alive through the cast pointers
check("ffi: memory backend switched to the DLL", m._test.mem_backend() == "dll",
      m._test.mem_backend())
local buf = fake_ffi.new("char[?]", 8)
check("ffi: NGB_Read is callable", tonumber(m.read_proc(0x1000, buf, 8)) == 8)
check("ffi: NGB_Query is callable", tonumber(m.query_proc(0x1000, buf, buf, buf)) == 1)
check("ffi: NGB_Write is callable", tonumber(m.write_proc(0x1000, buf, 8)) == 8)

-- ---------------------------------------------------------------------------
--  failure paths must degrade, not crash
-- ---------------------------------------------------------------------------
CALLS.NGB_Start = 0
fake_ffi.start_returns = 0
m.renderer.state = "?"
m.renderer.get_state = nil
fake_ffi.start_returns = 0
EXPORTS.NGB_Start = function(cfg) start_cfgs[#start_cfgs + 1] = cfg; return 0 end
CASTS.NGB_Start = nil
local ok_zero = pcall(m.load_renderer, ctx)
check("ffi: NGB_Start returning 0 is handled", ok_zero)
check("ffi: NGB_Start returning 0 falls back to overlay",
      m.renderer.state == "overlay", tostring(m.renderer.state))
check("ffi: the fallback reason is recorded",
      m.renderer.detail ~= nil
      and string.find(m.renderer.detail, "ngb-dll.log", 1, true) ~= nil,
      tostring(m.renderer.detail))

-- missing export: no cast, no call, no crash
EXPORTS.NGB_Start = nil
CASTS.NGB_Start = nil
m.renderer.state = "?"
local ok_missing = pcall(m.load_renderer, ctx)
check("ffi: a missing export is handled", ok_missing)
check("ffi: missing export falls back to overlay", m.renderer.state == "overlay",
      tostring(m.renderer.state))

return RESULTS
