-- Shared helpers for tests that need the old Paladin example data or the user's saved-variable fixtures.
local L = require("loader")
local Fx = {}

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end
Fx.deepcopy = deepcopy

-- Loads a saved-variables style file ("Name = { ... }") WITHOUT touching any global; returns the table.
function Fx.loadSaved(path, varName)
    local chunk, err = loadfile(path)
    assert(chunk, err)
    local env = {}
    setfenv(chunk, env)
    chunk()
    return deepcopy(env[varName])
end
-- The owner's untouched originals live in .settings-backup/ (NOT in git, so absent in CI and fresh clones). Returns the first
-- "<kind>-*-HealerForever.lua" file of a backup folder, or nil when the folder does not exist.
function Fx.backupFile(folder, kind)
    local dir = HF_ROOT .. "/.settings-backup/" .. folder
    local p = io.popen('ls "' .. dir .. '"/' .. kind .. '-*HealerForever.lua 2>/dev/null; ls "' .. dir .. '"/' .. kind .. 'HealerForever.lua 2>/dev/null')
    local path
    for line in p:lines() do if not line:find("%.latest%.lua$") then path = path or line end end
    p:close()
    return path
end
function Fx.userChar() return Fx.loadSaved(HF_TESTS .. "/fixtures/owner-char-v3.lua", "HealerForeverCharDB") end
function Fx.userAccount() return Fx.loadSaved(HF_TESTS .. "/fixtures/owner-account-v2.lua", "HealerForeverDB") end

-- Loads the opt-in Paladin examples exactly like the two "Load example" buttons do: the preset is ADDED (and made
-- active), the bindings only fill EMPTY slots (default plain Left = target / Right = menu count as empty).
function Fx.seed(ns, opts)
    opts = opts or {}
    local presets = ns.db.presets
    local p = ns.Presets.ExamplePaladin()
    -- the shipped blank "Default" preset is replaced so that tests see the example rules as preset 1
    if opts.keepDefault then presets[#presets + 1] = p else presets[1] = p end
    ns.db.activePreset = opts.keepDefault and #presets or 1
    for i = 2, (opts.presets or 1) do
        local extra = deepcopy(p)
        extra.name = "Example copy " .. i
        presets[#presets + 1] = extra
    end
    if opts.bindings ~= false then
        for key, action in pairs(ns.Bindings.EXAMPLE_PALADIN) do
            local existing = ns.db.bindings[key]
            local empty = existing == nil or (key == "|1" and existing.type == "target") or (key == "|2" and existing.type == "menu")
            if empty then ns.db.bindings[key] = deepcopy(action) end
        end
    end
    return ns
end

return Fx
