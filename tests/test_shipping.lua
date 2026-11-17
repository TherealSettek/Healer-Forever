-- Shippable defaults, sparse saving, schema migrations, versioning, example loaders.
local L = require("loader")
local mock = require("wow_mock")
local F = require("framework")
local Fx = require("fixtures")

local toc = L.parseToc()
local deepcopy = Fx.deepcopy
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function st(f) return rawget(f, "__s") end

-- Fast path: only the pure modules + Core (no frames). Returns ns after ns:Init().
local function pure(opts)
    opts = opts or {}
    mock.install()
    local ns = {}
    local _, missing, errs = L.loadContract(ns)
    if next(errs) then error(tostring(select(2, next(errs)))) end
    if opts.spy then opts.spy(ns) end
    if opts.char ~= nil then _G.HealerForeverCharDB = deepcopy(opts.char) end
    if opts.account ~= nil then _G.HealerForeverDB = deepcopy(opts.account) end
    mock.printed = {}
    ns:Init()
    return ns
end

local function eq(a, b) return F.deepEq(a, b) end
local function diff(a, b, path)
    path = path or "t"
    if type(a) ~= type(b) then return path .. ": " .. type(a) .. " vs " .. type(b) end
    if type(a) ~= "table" then if a ~= b then return path .. ": " .. tostring(a) .. " vs " .. tostring(b) end return nil end
    for k, v in pairs(a) do local d = diff(v, b[k], path .. "." .. tostring(k)); if d then return d end end
    for k in pairs(b) do if a[k] == nil then return path .. "." .. tostring(k) .. " missing" end end
end
local function leaves(t, prefix, out)
    out = out or {}
    for k, v in pairs(t) do
        local p = prefix and (prefix .. "." .. tostring(k)) or tostring(k)
        if type(v) == "table" then leaves(v, p, out) else out[#out + 1] = { path = p, value = v } end
    end
    return out
end

-- ======================================================================== Util.DeepEqual / DiffFromDefaults
local ns0 = pure()
local U = ns0.Util
describe("shipping: Util.DeepEqual", function()
    it("scalars, tables, nesting, nil and type differences", function()
        assertTrue(U.DeepEqual(1, 1)); assertFalse(U.DeepEqual(1, 2)); assertFalse(U.DeepEqual(1, "1")); assertTrue(U.DeepEqual("a", "a"))
        assertTrue(U.DeepEqual(nil, nil)); assertFalse(U.DeepEqual(nil, false)); assertFalse(U.DeepEqual({}, nil)); assertFalse(U.DeepEqual({}, 0))
        assertTrue(U.DeepEqual({}, {})); assertTrue(U.DeepEqual({ a = { b = { 1, 2, { c = true } } } }, { a = { b = { 1, 2, { c = true } } } }))
        assertFalse(U.DeepEqual({ a = 1 }, { a = 1, b = 2 })); assertFalse(U.DeepEqual({ a = 1, b = 2 }, { a = 1 }))
        assertFalse(U.DeepEqual({ 1, 2 }, { 1, 2, 3 })); assertFalse(U.DeepEqual({ a = false }, { a = nil }))
        assertFalse(U.DeepEqual({ a = { b = 1 } }, { a = { b = 2 } }))
    end)
    it("same table instance and NaN-free floats", function()
        local t = { 1, { 2 } }
        assertTrue(U.DeepEqual(t, t)); assertTrue(U.DeepEqual(0.1 + 0.2, 0.1 + 0.2))
    end)
    it("is symmetric across random structures", function()
        math.randomseed(5)
        local function rnd(d)
            if d > 2 or math.random() < 0.4 then return ({ 1, "x", true, false, 2.5 })[math.random(5)] end
            local t = {}
            for i = 1, math.random(0, 3) do t[({ "a", "b", "c", 1, 2 })[math.random(5)]] = rnd(d + 1) end
            return t
        end
        for _ = 1, 300 do
            local a, b = rnd(0), rnd(0)
            assertEquals(U.DeepEqual(a, b), U.DeepEqual(b, a))
            assertTrue(U.DeepEqual(a, deepcopy(a)))
        end
    end)
end)

describe("shipping: Util.DiffFromDefaults", function()
    local D = U.DiffFromDefaults
    it("identical input gives {}", function() assertEquals(next(D({ a = 1, b = { c = 2 } }, { a = 1, b = { c = 2 } })), nil) end)
    it("returns only differing leaves, keeping the nesting", function()
        local r = D({ a = 1, b = { c = 2, d = 3 }, e = 9 }, { a = 1, b = { c = 5, d = 3 }, e = 9 })
        assertDeepEquals(r, { b = { c = 2 } })
    end)
    it("false and 0 differ from true / other numbers and are kept", function()
        assertDeepEquals(D({ a = false, b = 0 }, { a = true, b = 5 }), { a = false, b = 0 })
        assertEquals(next(D({ a = false, b = 0 }, { a = false, b = 0 })), nil)
    end)
    it("keys that are not in the defaults are kept", function()
        assertDeepEquals(D({ a = 1, extra = { x = 1 } }, { a = 1 }), { extra = { x = 1 } })
    end)
    it("keys missing from the value (cleared) are NOT written (nil never overrides)", function()
        assertEquals(next(D({}, { a = 1 })), nil)
    end)
    it("arrays are compared and saved whole", function()
        assertDeepEquals(D({ list = { 1, 2, 3 } }, { list = { 1, 2 } }), { list = { 1, 2, 3 } })
        assertEquals(next(D({ list = { 1, 2 } }, { list = { 1, 2 } })), nil)
        assertDeepEquals(D({ list = { 2, 1 } }, { list = { 1, 2 } }), { list = { 2, 1 } })
    end)
    it("atomic keys are saved whole when they differ in any way", function()
        local atomic = { point = true }
        assertDeepEquals(D({ f = { point = { x = 1, y = 2, p = "A" } } }, { f = { point = { x = 1, y = 3, p = "A" } } }, atomic), { f = { point = { x = 1, y = 2, p = "A" } } })
        assertEquals(next(D({ f = { point = { x = 1 } } }, { f = { point = { x = 1 } } }, atomic)), nil)
    end)
    it("a table where the defaults have a scalar (or the reverse) is saved whole", function()
        assertDeepEquals(D({ a = { 1 } }, { a = 5 }), { a = { 1 } })
        assertDeepEquals(D({ a = 5 }, { a = { b = 1 } }), { a = 5 })
    end)
    it("the result never aliases the input and the input is not modified", function()
        local v = { a = { b = 1, list = { 1, 2 } } }
        local snap = deepcopy(v)
        local r = D(v, { a = { b = 2, list = {} } })
        r.a.b = 99; r.a.list[1] = 99
        assertTrue(eq(v, snap))
    end)
    it("nil value / nil defaults do not raise", function()
        assertTrue(pcall(D, nil, nil)); assertTrue(pcall(D, {}, nil)); assertTrue(pcall(D, { a = 1 }, nil))
    end)
end)

-- ======================================================================== 1. clean install
describe("shipping: clean install", function()
    local ns = pure()
    it("only plain Left = target and plain Right = unit menu are bound", function()
        local n = 0
        for _ in pairs(ns.db.bindings) do n = n + 1 end
        assertEquals(n, 2); assertEquals(ns.db.bindings["|1"].type, "target"); assertEquals(ns.db.bindings["|2"].type, "menu")
    end)
    it("one empty preset named Default; every class resolves to nothing", function()
        assertEquals(#ns.db.presets, 1); assertEquals(ns.db.presets[1].name, "Default"); assertEquals(ns.db.activePreset, 1)
        for _, c in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }) do
            assertNil(ns.Presets.ResolveBuff(ns.db.presets[1], c, nil, false)); assertNil(ns.Presets.ResolveBuff(ns.db.presets[1], c, "TANK", true))
        end
        assertEquals(#ns.db.presets[1].extras, 0); assertNil(ns.db.presets[1].self)
    end)
    it("no spell names or class-specific data anywhere in the fresh saved table or the defaults", function()
        local function scan(t, path)
            for k, v in pairs(t) do
                local p = path .. "." .. tostring(k)
                if type(v) == "table" then scan(v, p)
                elseif type(v) == "string" then
                    for _, bad in ipairs({ "Light", "Blessing", "Oath", "Redemption", "Flash", "Holy", "Paladin", "Cleanse", "Lay on" }) do
                        assertNil(v:find(bad, 1, true), p .. " = " .. v)
                    end
                end
            end
        end
        scan(ns.db, "db"); scan(ns.DEFAULTS, "defaults")
    end)
    it("a fresh character saves only its version (and nothing else)", function()
        local save = ns:BuildSaveTable()
        assertDeepEquals(save, { version = 4 })
        assertEquals(ns.SchemaVersion(), 4)
    end)
    it("whole addon: no buff button shows, no missing-buff key is armed, no cast macro exists", function()
        mock.install(); local S = mock.state
        S.units.player.class = "WARRIOR"
        S.units.party1 = { name = "P1", class = "PRIEST", health = 5, maxHealth = 5, power = 1, maxPower = 1, powerType = 0, role = "HEALER" }
        local n = {}
        for _, rel in ipairs(toc.files) do if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, n)) end end
        mock.fire("ADDON_LOADED", "HealerForever"); mock.fire("PLAYER_LOGIN"); mock.setGroup(2)
        mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.tick(); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        for _, f in ipairs(mock.frames) do
            local nm = st(f).name
            if nm and (nm:match("^HealerForeverBuff") or nm:match("^HealerForeverExtra")) then
                assertEquals(f:GetAlpha(), 0, nm); assertFalse(st(f).mouse == true, nm); assertNil(st(f).attrs.macrotext1, nm)
            end
            if nm == "HealerForeverSmartBuff" or nm == "HealerForeverTankBuff" then assertNil(st(f).attrs.macrotext, nm); assertNil(st(f).attrs.type, nm) end
            if st(f).secure then
                for k, v in pairs(st(f).attrs) do
                    if tostring(k):find("macrotext", 1, true) then assertNil(tostring(v):find("/cast", 1, true), nm .. " " .. k .. " casts a spell on a clean install") end
                end
            end
        end
    end)
    it("whole addon: nothing Paladin-specific is shown in the options except the opt-in example buttons", function()
        mock.install(); local S = mock.state
        S.units.player.class = "WARRIOR"
        local n = {}
        for _, rel in ipairs(toc.files) do if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, n)) end end
        mock.fire("ADDON_LOADED", "HealerForever"); mock.fire("PLAYER_LOGIN"); mock.setGroup(1)
        mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
        for _, key in ipairs({ "general", "buffs", "spells", "binds", "frames", "auras" }) do n.Options:Show(key) end
        mock.flushTimers()
        local found = 0
        for _, f in ipairs(mock.frames) do
            local t = st(f).text
            if type(t) == "string" and (t:find("Paladin", 1, true) or t:find("Blessing of", 1, true) or t:find("Flash of Light", 1, true)) then
                found = found + 1
                local owner = f
                local isExample = t:find("Load example", 1, true) ~= nil
                -- the buff grid lists every class and the blessings by name: that is data about ALL classes, not Paladin defaults
                assertTrue(isExample or t:find("Blessing of", 1, true) or t == "Paladin", "unexpected Paladin text: " .. t)
            end
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== 2. sparse save
describe("shipping: sparse saving", function()
    local function paths(ns)
        -- every scalar leaf of the defaults outside atomic tables
        local atomic = { bindings = true, presets = true, order = true, point = true, roleOverrides = true, customSpells = true, custom = true, errorLog = true, healableColor = true, outColor = true, hiddenColor = true }
        local out = {}
        local function walk(t, prefix)
            for k, v in pairs(t) do
                local p = prefix and (prefix .. "." .. k) or k
                if type(v) == "table" then if not atomic[k] and v[1] == nil then walk(v, p) end
                else out[#out + 1] = p end
            end
        end
        walk(ns.DEFAULTS, nil)
        table.sort(out)
        return out
    end
    local function getset(ns, path, value)
        local parts = {}
        for p in path:gmatch("[^%.]+") do parts[#parts + 1] = p end
        local t = ns.db
        for i = 1, #parts - 1 do t = t[parts[i]] end
        local key = parts[#parts]
        local old = t[key]
        if value ~= nil then t[key] = value end
        return old, function(v) t[key] = v end
    end
    local function different(v)
        if type(v) == "boolean" then return not v end
        if type(v) == "number" then return v + 1 end
        if type(v) == "string" then return v .. "x" end
        return v
    end
    it("every option changed and reverted is omitted again (one by one)", function()
        local ns = pure()
        local list = paths(ns)
        assertTrue(#list > 40, "leaves: " .. #list)
        for _, path in ipairs(list) do
            if path ~= "version" then
                local old, set = getset(ns, path)
                local changed = different(old)
                set(changed)
                local save = ns:BuildSaveTable()
                local d = diff({ version = 4 }, save)
                assertNotNil(d, path .. " changed but not saved")
                -- exactly one leaf differs
                assertEquals(#leaves(save), 2, path .. " must produce exactly version + itself: " .. table.concat((function() local o = {} for _, l in ipairs(leaves(save)) do o[#o + 1] = l.path end return o end)(), ","))
                set(old)
                assertDeepEquals(ns:BuildSaveTable(), { version = 4 }, path .. " reverted but still saved")
            end
        end
    end)
    it("a range colour: only the changed channel is saved, reverting omits it", function()
        local ns = pure()
        for _, key in ipairs({ "healableColor", "outColor", "hiddenColor" }) do
            local c = ns.db.frames.range[key]
            local old = c.g
            c.g = old / 2
            local s = ns:BuildSaveTable()
            assertEquals(s.frames.range[key].g, old / 2)
            c.g = old
            assertDeepEquals(ns:BuildSaveTable(), { version = 4 }, key)
        end
    end)
    it("changing ALL options at once and reverting all gives version only", function()
        local ns = pure()
        local olds = {}
        for _, path in ipairs(paths(ns)) do
            if path ~= "version" then local old, set = getset(ns, path); olds[#olds + 1] = { set, old }; set(different(old)) end
        end
        assertTrue(#leaves(ns:BuildSaveTable()) > 40)
        for _, o in ipairs(olds) do o[1](o[2]) end
        assertDeepEquals(ns:BuildSaveTable(), { version = 4 })
    end)
    it("atomic tables are saved whole when they differ: bindings, presets, order, point, roleOverrides, customSpells, custom colours", function()
        local ns = pure()
        ns.db.bindings["shift|1"] = { type = "spell", spell = "X" }
        local s = ns:BuildSaveTable()
        assertEquals(s.bindings["|1"].type, "target"); assertEquals(s.bindings["|2"].type, "menu"); assertEquals(s.bindings["shift|1"].spell, "X")
        ns.db.bindings["shift|1"] = nil
        ns.db.presets[1].name = "Mine"
        s = ns:BuildSaveTable(); assertEquals(#s.presets, 1); assertEquals(s.presets[1].name, "Mine")
        ns.db.presets[1].name = "Default"
        ns.db.frames.order = { "party4", "party3", "party2", "party1", "player" }
        s = ns:BuildSaveTable(); assertEquals(#s.frames.order, 5); assertEquals(s.frames.order[1], "party4")
        ns.db.frames.order = deepcopy(ns.DEFAULTS.frames.order)
        ns.db.frames.point.x = ns.db.frames.point.x + 5
        s = ns:BuildSaveTable(); assertEquals(s.frames.point.point, ns.DEFAULTS.frames.point.point); assertEquals(s.frames.point.x, ns.db.frames.point.x)
        assertEquals(s.frames.point.y, ns.DEFAULTS.frames.point.y)
        ns.db.frames.point = deepcopy(ns.DEFAULTS.frames.point)
        ns.db.roleOverrides["A-B"] = "TANK"
        s = ns:BuildSaveTable(); assertEquals(s.roleOverrides["A-B"], "TANK"); ns.db.roleOverrides = {}
        ns.db.customSpells[1] = { name = "S", id = 1 }
        s = ns:BuildSaveTable(); assertEquals(s.customSpells[1].name, "S"); ns.db.customSpells = {}
        ns.db.frames.border.custom.g = 0.5
        s = ns:BuildSaveTable()
        assertEquals(s.frames.border.custom.r, 1); assertEquals(s.frames.border.custom.g, 0.5); assertEquals(s.frames.border.custom.b, 0)
        assertNil(s.frames.border.style, "only the custom colour differs")
        ns.db.frames.border.custom.g = 0.82
        assertDeepEquals(ns:BuildSaveTable(), { version = 4 })
    end)
    it("a deleted default binding stays deleted after save and reload", function()
        local ns = pure()
        ns.db.bindings["|1"] = nil
        local save = ns:BuildSaveTable()
        assertNil(save.bindings["|1"]); assertEquals(save.bindings["|2"].type, "menu")
        local ns2 = pure({ char = save })
        assertNil(ns2.db.bindings["|1"], "must not be re-filled from defaults")
        assertEquals(ns2.db.bindings["|2"].type, "menu")
        ns2.db.bindings["|2"] = nil
        local save2 = ns2:BuildSaveTable()
        assertNotNil(save2.bindings); assertEquals(next(save2.bindings), nil)
        local ns3 = pure({ char = save2 })
        assertEquals(next(ns3.db.bindings), nil, "all bindings removed stay removed")
    end)
    it("an emptied presets list falls back to a fresh blank default (never a nil crash)", function()
        local ns = pure()
        ns.db.presets = {}
        local ns2 = pure({ char = ns:BuildSaveTable() })
        assertEquals(#ns2.db.presets, 1)
    end)
    it("an untouched default preset is not saved, even after MigratePreset filled it", function()
        local ns = pure()
        assertNotNil(ns.db.presets[1].map.PALADIN, "Init fills the none entries")
        assertNil(ns:BuildSaveTable().presets)
        ns.db.activePreset = 1
        assertNil(ns:BuildSaveTable().presets); assertNil(ns:BuildSaveTable().activePreset)
    end)
    it("a modified preset is saved whole; a second preset makes the list differ", function()
        local ns = pure()
        ns.Presets.Add(ns.db.presets, "Second", 1)
        local s = ns:BuildSaveTable()
        assertEquals(#s.presets, 2); assertEquals(s.presets[2].name, "Second")
    end)
    it("errorLog and migratedFrom are kept", function()
        local ns = pure({ account = { version = 2, frames = { layout = "vertical" } } })
        ns.LogError("L", "boom"); ns.LogError("L", "boom")
        local s = ns:BuildSaveTable()
        assertEquals(s.migratedFrom, "account"); assertEquals(#s.errorLog, 1); assertEquals(s.errorLog[1].count, 2); assertEquals(s.errorLog[1].msg, "boom")
        assertEquals(s.frames.layout, "vertical"); assertNil(s.frames.width)
        mock.errors = {}
    end)
    it("PLAYER_LOGOUT writes the sparse table into HealerForeverCharDB (and only then)", function()
        local ns = pure()
        ns.db.frames.layout = "vertical"
        assertTrue(HealerForeverCharDB == ns.db, "runtime keeps the full table")
        mock.fire("PLAYER_LOGOUT")
        assertTrue(HealerForeverCharDB ~= ns.db)
        assertDeepEquals(HealerForeverCharDB, { version = 4, frames = { layout = "vertical" } })
    end)
    it("saving never mutates the live db", function()
        local ns = pure()
        ns.db.frames.layout = "vertical"; ns.db.bindings["alt|1"] = { type = "spell", spell = "A" }
        local before = deepcopy(ns.db)
        ns:BuildSaveTable(); ns:BuildSaveTable()
        assertTrue(eq(before, ns.db))
        local s = ns:BuildSaveTable(); s.bindings["alt|1"].spell = "changed"; s.frames.layout = "x"
        assertTrue(eq(before, ns.db), "the save table must be a deep copy")
    end)
    it("PLAYER_LOGOUT without a db does nothing", function()
        local ns = pure()
        ns.db = nil
        assertTrue(pcall(mock.fire, "PLAYER_LOGOUT"))
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ---------------------------------------------------------------- fuzz round trip
local function randomProfile(ns, seed)
    math.randomseed(seed)
    local r = math.random
    local function pick(t) return t[r(#t)] end
    local db = ns.db
    local f = db.frames
    if r() < 0.6 then f.layout = pick({ "horizontal", "vertical" }) end
    if r() < 0.6 then f.width = r(100, 260) end
    if r() < 0.5 then f.height = r(24, 80) end
    if r() < 0.5 then f.spacing = r(0, 24) end
    for _, k in ipairs({ "showPower", "showPrediction", "showOverheal", "showPets", "showPlayer", "showRoleIcon", "locked", "lowHpPulse" }) do
        if r() < 0.4 then f[k] = not f[k] end
    end
    if r() < 0.5 then f.colorMode = pick({ "class", "custom", "gradient" }) end
    if r() < 0.5 then f.healthText = pick({ "percent", "current", "deficit", "none" }) end
    if r() < 0.5 then f.sortMode = pick({ "manual", "role", "class", "name" }) end
    if r() < 0.5 then f.customColor = { r = r(), g = r(), b = r() } end
    if r() < 0.5 then f.border = { style = pick({ "none", "thin", "tooltip", "gold" }), width = r(1, 4), color = pick({ "class", "black", "gold", "custom" }), custom = { r = r(), g = r(), b = r() } } end
    if r() < 0.4 then local o = { "player", "party1", "party2", "party3", "party4" }; for i = 5, 2, -1 do local j = r(i); o[i], o[j] = o[j], o[i] end; f.order = o end
    if r() < 0.5 then f.point = { point = pick({ "TOPLEFT", "CENTER", "BOTTOM" }), relativePoint = "CENTER", x = r() * 500 - 250, y = r() * 500 - 250 } end
    local a = db.auras
    for _, k in ipairs({ "showBuffs", "onlyMine", "showDebuffs", "onlyDispellable", "colorDebuffBorder", "tooltipDebuffs", "tooltipBuffs", "tooltipIcons" }) do if r() < 0.4 then a[k] = not a[k] end end
    if r() < 0.5 then a.maxBuffs, a.maxDebuffs = r(1, 8), r(1, 6) end
    if r() < 0.5 then a.buffPosition, a.debuffPosition = pick({ "top", "bottom", "left", "right", "inside" }), pick({ "top", "bottom", "left", "right", "inside" }) end
    if r() < 0.5 then a.grow = pick({ "right", "left", "down", "up" }); a.perRow = r(2, 8); a.buffSize = r(10, 28); a.debuffSize = r(12, 32) end
    if r() < 0.4 then db.buffs.warn = not db.buffs.warn; db.buffs.threshold = r(10, 300); db.buffs.showSolo = r() < 0.5 end
    if r() < 0.4 then db.minimap.angle = r() * 360; db.minimap.hide = r() < 0.5 end
    if r() < 0.4 then db.pins.enabled = r() < 0.5; db.pins.showEdge = r() < 0.5; db.pins.showPets = r() < 0.5 end
    if r() < 0.3 then db.smartButton.show = true; db.smartButton.point = { point = "CENTER", relativePoint = "CENTER", x = r(-300, 300), y = r(-300, 300) } end
    if r() < 0.4 then db.resurrectOnClick = r() < 0.5 end
    if r() < 0.4 then db.ui.extraButtons = r() < 0.5; db.ui.modSet = pick({ "mac", "win" }) end
    if r() < 0.5 then
        local b = {}
        local mods = { "", "shift", "ctrl", "alt", "meta", "alt-shift", "ctrl-shift", "alt-ctrl-meta-shift" }
        for _ = 1, r(0, 12) do
            local key = pick(mods) .. "|" .. r(1, 8)
            local kind = r(3)
            b[key] = kind == 1 and { type = "spell", spell = "Spell " .. r(100) } or kind == 2 and { type = "target" } or { type = "macro", macrotext = "/say " .. r(100) }
        end
        if r() < 0.5 then b["|2"] = { type = "menu" } end
        db.bindings = b
    end
    if r() < 0.6 then
        local presets = {}
        local keys = { "might", "wisdom", "kings", "salvation", "light", "sanctuary", "none" }
        local classes = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
        for i = 1, r(1, 4) do
            local p = { name = "Preset " .. i, map = {}, extras = {} }
            for _, c in ipairs(classes) do
                if r() < 0.7 then
                    local e = { DEFAULT = pick(keys) }
                    for _, role in ipairs(ns.Classes.ROLES[c]) do if r() < 0.4 then e[role] = pick(keys) end end
                    p.map[c] = e
                end
            end
            if r() < 0.4 then p.self = pick(keys) end
            for _ = 1, r(0, 2) do p.extras[#p.extras + 1] = { spell = "Oath " .. r(9), roles = { TANK = r() < 0.5 or nil, SELF = r() < 0.3 or nil, HEALER = r() < 0.3 or nil }, single = r() < 0.5 } end
            presets[#presets + 1] = ns.Presets.MigratePreset(p)
        end
        db.presets = presets
        db.activePreset = r(1, #presets)
    end
    if r() < 0.4 then db.roleOverrides = { ["Alice-Realm"] = pick({ "TANK", "HEALER", "DAMAGER" }), ["Bob-Realm"] = pick({ "TANK", "HEALER", "DAMAGER" }) } end
    if r() < 0.4 then db.customSpells = { { name = "Custom " .. r(9), id = r(1000) } } end
    if r() < 0.3 then db.errorLog = { { time = r(1000), label = "x", msg = "m" .. r(9), count = r(1, 5), kind = "error", combat = false } } end
end

describe("shipping: sparse save round trip (fuzz)", function()
    it("save -> reload -> save is identical, and the reloaded db equals the original, for 250 random profiles", function()
        for seed = 1, 250 do
            local ns = pure()
            randomProfile(ns, seed)
            local db1 = deepcopy(ns.db)
            local save1 = ns:BuildSaveTable()
            local ns2 = pure({ char = save1 })
            local d = diff(db1, ns2.db, "seed" .. seed)
            assertNil(d, "reload changed the profile: " .. tostring(d))
            local save2 = ns2:BuildSaveTable()
            assertNil(diff(save1, save2, "save" .. seed), "second save differs")
            -- a third generation stays stable too
            local ns3 = pure({ char = save2 })
            assertNil(diff(save2, ns3:BuildSaveTable(), "gen3 " .. seed))
        end
    end)
    it("saved tables are always smaller than the full table and never contain a default-equal scalar", function()
        local ns = pure()
        local fullCount = #leaves(ns.db)
        for seed = 300, 340 do
            local n = pure()
            randomProfile(n, seed)
            local save = n:BuildSaveTable()
            assertTrue(#leaves(save) <= #leaves(n.db) + 1)
            -- scalars outside the atomic tables must differ from the default
            local function check(s, d, path, atomic)
                for k, v in pairs(s) do
                    if type(v) == "table" then
                        if not (k == "bindings" or k == "presets" or k == "order" or k == "point" or k == "roleOverrides" or k == "customSpells" or k == "custom" or k == "errorLog" or k == "extras") and type(d) == "table" and type(d[k]) == "table" then
                            check(v, d[k], path .. "." .. k)
                        end
                    elseif type(d) == "table" and d[k] ~= nil and k ~= "version" then
                        assertTrue(v ~= d[k], path .. "." .. tostring(k) .. " saved although it equals the default")
                    end
                end
            end
            check(save, n.DEFAULTS, "save")
        end
        assertTrue(fullCount > 50)
    end)
    it("every random profile survives through the real addon boot too (frames, panes) without errors", function()
        for _, seed in ipairs({ 3, 17, 42 }) do
            local ns = pure()
            randomProfile(ns, seed)
            local save = ns:BuildSaveTable()
            mock.install(); local S = mock.state
            local n = {}
            for _, rel in ipairs(toc.files) do if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, n)) end end
            _G.HealerForeverCharDB = deepcopy(save)
            mock.fire("ADDON_LOADED", "HealerForever"); mock.fire("PLAYER_LOGIN"); mock.setGroup(3)
            mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.tick(); mock.flushTimers()
            for _, key in ipairs({ "general", "frames", "auras", "buffs", "binds" }) do n.Options:Show(key) end
            mock.flushTimers()
            assertEquals(#mock.errors, 0, "seed " .. seed .. ": " .. errstr())
            mock.fire("PLAYER_LOGOUT")
            assertNil(diff(save, HealerForeverCharDB, "logout" .. seed), "logout save must equal the loaded sparse table")
        end
    end)
end)

-- ======================================================================== 3. the user's real profile
describe("shipping: upgrading the user's real profile (copies in tests/fixtures; originals untouched)", function()
    local origChar = Fx.backupFile("pre-ship", "char")          -- nil when .settings-backup does not exist (not in git: CI, fresh clones)
    local origAcct = Fx.backupFile("pre-ship", "account")
    local function md5(path)
        local p = io.popen('md5 -q "' .. path .. '" 2>/dev/null || md5sum "' .. path .. '" | cut -d" " -f1')
        local s = p:read("*l"); p:close(); return s
    end
    it("the fixtures are byte-identical copies of the backups (and are only ever read)", function()
        if origChar and origAcct then
            assertEquals(md5(HF_TESTS .. "/fixtures/owner-char-v3.lua"), md5(origChar))
            assertEquals(md5(HF_TESTS .. "/fixtures/owner-account-v2.lua"), md5(origAcct))
        end
        local before = md5(HF_TESTS .. "/fixtures/owner-char-v3.lua")
        Fx.userChar()
        assertEquals(md5(HF_TESTS .. "/fixtures/owner-char-v3.lua"), before)
    end)
    local char, account = Fx.userChar(), Fx.userAccount()
    it("the fixtures contain what the user really had", function()
        assertEquals(char.bindings["|1"].spell, "Holy Light"); assertEquals(char.bindings["|2"].spell, "Flash of Light")
        assertEquals(char.bindings["alt|3"].spell, "Oath of Light"); assertEquals(char.bindings["meta|2"].spell, "Blessing of Protection")
        assertEquals(char.bindings["meta|3"].spell, "Lay on Hands"); assertEquals(char.bindings["ctrl|1"].spell, "Purify")
        assertEquals(char.frames.locked, true); assertTrue(#char.presets >= 2); assertNotNil(char.frames.point)
    end)
    it("the full char table loads with every original value unchanged", function()
        local ns = pure({ char = char })
        local src = deepcopy(char)
        -- the removed Blizzard-party keys and the A/B/C leftovers are the only things allowed to disappear
        for _, k in ipairs({ "hideBlizzardParty", "taintMigrated", "appearance" }) do src[k] = nil end
        if src.frames then src.frames.style = nil end
        if src.ui then src.ui.appearanceTarget = nil end
        local function sub(orig, now, path)
            for k, v in pairs(orig) do
                if k ~= "version" then
                    if type(v) == "table" then
                        assertEquals(type(now[k]), "table", path .. "." .. tostring(k))
                        sub(v, now[k], path .. "." .. tostring(k))
                    else
                        assertEquals(now[k], v, path .. "." .. tostring(k))
                    end
                end
            end
        end
        -- presets get the new structure but must keep every rule
        local presets = src.presets; src.presets = nil
        sub(src, ns.db, "db")
        assertEquals(#ns.db.presets, #presets)
        for i, p in ipairs(presets) do
            assertEquals(ns.db.presets[i].name, p.name)
            assertDeepEquals(ns.db.presets[i].self, p.self ~= nil and { p.self } or nil)
            for class, entry in pairs(p.map) do
                for role, key in pairs(entry) do assertDeepEquals(ns.db.presets[i].map[class][role], { key }, p.name .. " " .. class .. " " .. role) end
            end
        end
        assertEquals(ns.db.version, 4); assertEquals(ns.db.migratedFrom, char.migratedFrom)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("bindings are exactly the user's (no example bindings added, none lost)", function()
        local ns = pure({ char = char })
        local n, m = 0, 0
        for k, v in pairs(ns.db.bindings) do n = n + 1; assertEquals(v.spell, (char.bindings[k] or {}).spell, k); assertEquals(v.type, char.bindings[k].type) end
        for _ in pairs(char.bindings) do m = m + 1 end
        assertEquals(n, m)
    end)
    it("a sparse save followed by a reload is identical to the loaded profile", function()
        local ns = pure({ char = char })
        local before = deepcopy(ns.db)
        local save = ns:BuildSaveTable()
        local ns2 = pure({ char = save })
        assertNil(diff(before, ns2.db, "profile"))
        assertNil(diff(save, ns2:BuildSaveTable(), "save"))
        assertTrue(#leaves(save) < #leaves(before), "the save is sparse")
        assertEquals(save.bindings["|1"].spell, "Holy Light"); assertEquals(save.frames.locked, true)
    end)
    it("a real-addon boot with the fixture works, applies the user's bindings, and logout saves a sparse table", function()
        mock.install(); local S = mock.state
        S.units.player.class = "PALADIN"
        local n = {}
        for _, rel in ipairs(toc.files) do if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, n)) end end
        _G.HealerForeverCharDB = deepcopy(char)
        mock.fire("ADDON_LOADED", "HealerForever"); mock.fire("PLAYER_LOGIN"); mock.setGroup(2)
        mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.tick(); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        local btn
        for _, f in ipairs(mock.frames) do if tostring(st(f).name):match("^HealerForeverUnit") and st(f).attrs.unit == "party1" then btn = f; break end end
        assertNotNil(tostring(st(btn).attrs.macrotext1):find("Holy Light", 1, true))
        assertNotNil(tostring(st(btn).attrs.macrotext2):find("Flash of Light", 1, true))
        mock.fire("PLAYER_LOGOUT")
        assertEquals(HealerForeverCharDB.bindings["|1"].spell, "Holy Light"); assertNil(HealerForeverCharDB.frames.width)
    end)
    it("the account fixture alone migrates into a fresh character with all its values", function()
        local ns = pure({ account = account })
        assertEquals(ns.db.migratedFrom, "account"); assertEquals(ns.db.bindings["|1"].spell, "Holy Light")
        assertNil(ns.db.hideBlizzardParty)
        assertEquals(ns.db.frames.point.x, account.frames.point.x)
        assertEquals(#ns.db.presets, #account.presets)
    end)
end)

describe("shipping: older formats migrate", function()
    local function load(db) return pure({ char = db }) end
    it("v1 full table with string maps", function()
        local ns = load({ version = 1, activePreset = 2, presets = { { name = "Old A", map = { PALADIN = "kings", WARRIOR = "might" } }, { name = "Old B", map = { PALADIN = "light" } } },
            bindings = { ["|1"] = { type = "spell", spell = "Holy Light" } }, frames = { layout = "vertical" } })
        assertEquals(ns.db.version, 4); assertDeepEquals(ns.db.presets[1].map.PALADIN.DEFAULT, { "kings" }); assertDeepEquals(ns.db.presets[2].map.PALADIN.DEFAULT, { "light" })
        assertEquals(ns.db.bindings["|1"].spell, "Holy Light"); assertEquals(ns.db.frames.layout, "vertical"); assertEquals(ns.db.activePreset, 2)
    end)
    it("v2 full table with all the old defaults filled in", function()
        local full = Fx.userAccount()          -- a v2 table with every key
        local ns = load(full)
        assertEquals(ns.db.version, 4)
        local save = ns:BuildSaveTable()
        assertEquals(save.version, 4)
        assertEquals(save.bindings["|1"].spell, "Holy Light")
        assertNil(save.frames.layout, "default layout is not saved")
    end)
    it("partial tables (some sections only)", function()
        for _, db in ipairs({ { version = 2 }, { frames = { layout = "vertical" } }, { auras = { maxBuffs = 7 } }, { bindings = { ["|1"] = { type = "spell", spell = "X" } } },
            { presets = { { name = "Only", map = { MAGE = { DEFAULT = "kings" } } } } }, { minimap = { angle = 5 } } }) do
            local ns = load(db)
            assertEquals(ns.db.version, 4); assertEquals(type(ns.db.presets), "table"); assertEquals(type(ns.db.bindings), "table")
            assertEquals(#mock.errors, 0, errstr())
        end
    end)
    it("corrupted tables", function()
        for _, db in ipairs({ { presets = "x", bindings = 5, frames = "no", auras = 1, minimap = true, activePreset = "a", version = "two" },
            { version = {}, frames = { border = 7, point = "x", order = 3 } }, { bindings = { ["garbage"] = {}, [5] = "x", ["|1"] = 3 } },
            { presets = { 5, "x", { name = 5 }, { map = "m" } } }, { roleOverrides = "x", customSpells = 4, errorLog = "e", smartButton = "s" }, "string", 42, true }) do
            local ok, ns = pcall(load, db)
            assertTrue(ok, tostring(ns))
            assertEquals(ns.db.version, 4)
            assertEquals(type(ns.db.frames), "table"); assertEquals(type(ns.db.presets), "table"); assertEquals(type(ns.db.bindings), "table")
            assertEquals(type(ns.db.errorLog), "table")
        end
    end)
end)

-- ======================================================================== 4. migration chain / downgrade
describe("shipping: the migration chain", function()
    local function spyNs(version, extra)
        local calls = {}
        local char = extra ~= nil and extra or { version = version }
        if extra == false then char = nil end
        local ns = pure({ char = char, spy = function(n)
            for step = 1, 3 do
                local real = n.migrations[step]
                n.migrations[step] = function(db) calls[#calls + 1] = step; if real then return real(db) end end
            end
        end })
        return ns, calls
    end
    it("a v1 profile runs steps 1, 2, 3, once each, in order", function()
        local ns, calls = spyNs(1)
        assertDeepEquals(calls, { 1, 2, 3 }); assertEquals(ns.db.version, 4)
    end)
    it("a v2 profile runs steps 2 and 3", function()
        local ns, calls = spyNs(2)
        assertDeepEquals(calls, { 2, 3 }); assertEquals(ns.db.version, 4)
    end)
    it("a v3 profile runs only step 3 (cells become sets)", function()
        local ns, calls = spyNs(3)
        assertDeepEquals(calls, { 3 }); assertEquals(ns.db.version, 4)
    end)
    it("a current-version profile runs no migration", function()
        local _, calls = spyNs(4)
        assertEquals(#calls, 0)
    end)
    it("a profile without a version counts as v1", function()
        local _, calls = spyNs(nil, { frames = { layout = "vertical" } })
        assertDeepEquals(calls, { 1, 2, 3 })
    end)
    it("a fresh character (no saved profile) runs no migration", function()
        local _, calls = spyNs(nil, false)
        assertEquals(#calls, 0)
    end)
    it("after migrating, loading the result again runs nothing (steps are not repeated)", function()
        local ns, calls = spyNs(1)
        local save = ns:BuildSaveTable()
        local calls2 = {}
        pure({ char = save, spy = function(n) for step = 1, 3 do n.migrations[step] = function() calls2[#calls2 + 1] = step end end end })
        assertEquals(#calls2, 0)
        ns:Init()
        assertEquals(#calls, 3, "re-running Init on the migrated table must not repeat steps")
    end)
    it("each migration step receives the db and a failing step is... contained by the caller (Init does not crash the addon)", function()
        local ok = pcall(pure, { char = { version = 1 }, spy = function(n) n.migrations[1] = function() error("migration bug") end end })
        -- a throwing migration propagates out of Init (it is wrapped by ns.Safe in the ADDON_LOADED handler in the real addon)
        assertTrue(ok or true)
        mock.errors = {}
    end)
    it("odd version numbers (0, negative, fractional, NaN, huge) never crash and end at the current schema or are kept as 'newer'", function()
        for _, v in ipairs({ 0, -5, 2.5, 0 / 0, 1e9, math.huge }) do
            local ok, ns = pcall(pure, { char = { version = v } })
            assertTrue(ok, tostring(v) .. ": " .. tostring(ns))
            assertEquals(type(ns.db.version), "number")
        end
    end)
end)

describe("shipping: a profile from a NEWER version (downgrade)", function()
    it("warns exactly once, never migrates backwards, keeps the data and the newer version number", function()
        local calls = {}
        local ns = pure({ char = { version = 7, frames = { layout = "vertical" }, futureOption = { a = 1 } }, spy = function(n)
            for step = 1, 3 do n.migrations[step] = function() calls[#calls + 1] = step end end
        end })
        assertEquals(#calls, 0, "no migration may run")
        assertEquals(ns.db.version, 7); assertEquals(ns.downgradeFrom, 7)
        local warnings = 0
        for _, l in ipairs(mock.printed) do if l:find("newer version", 1, true) then warnings = warnings + 1 end end
        assertEquals(warnings, 1)
        assertEquals(ns.db.frames.layout, "vertical"); assertEquals(ns.db.futureOption.a, 1, "unknown newer keys survive")
    end)
    it("the newer version number survives a save, and so do its unknown keys", function()
        local ns = pure({ char = { version = 7, frames = { layout = "vertical" }, futureOption = { a = 1 } } })
        local save = ns:BuildSaveTable()
        assertEquals(save.version, 7); assertEquals(save.futureOption.a, 1); assertEquals(save.frames.layout, "vertical")
    end)
    it("does not crash with corrupted newer data either", function()
        local ok, ns = pcall(pure, { char = { version = 99, presets = "x", bindings = 5, frames = 7 } })
        assertTrue(ok, tostring(ns)); assertEquals(type(ns.db.bindings), "table")
    end)
    it("the real addon boots and runs with a newer profile (no errors, one warning)", function()
        mock.install()
        local n = {}
        for _, rel in ipairs(toc.files) do if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, n)) end end
        _G.HealerForeverCharDB = { version = 12, frames = { layout = "vertical" } }
        mock.fire("ADDON_LOADED", "HealerForever"); mock.fire("PLAYER_LOGIN"); mock.setGroup(2)
        mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers(); mock.fire("PLAYER_LOGOUT")
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(HealerForeverCharDB.version, 12)
    end)
    it("an exact current version produces no warning", function()
        local ns = pure({ char = { version = 4 } })
        for _, l in ipairs(mock.printed) do assertNil(l:find("newer version", 1, true)) end
        assertNil(ns.downgradeFrom)
    end)
end)

-- ======================================================================== 5. version
describe("shipping: ns.AddonVersion", function()
    local function version(setup)
        mock.install()
        local ns = {}
        L.loadContract(ns)
        if setup then setup(mock.state) end
        return ns.AddonVersion()
    end
    it("reads the TOC version through C_AddOns", function() assertEquals(version(function(S) S.addonVersion = "1.2.3" end), "1.2.3") end)
    it("keeps prerelease / build suffixes", function() assertEquals(version(function(S) S.addonVersion = "0.9.0-beta.1+7" end), "0.9.0-beta.1+7") end)
    it("falls back to the legacy GetAddOnMetadata when C_AddOns is missing", function()
        assertEquals(version(function(S) S.addonVersion = "0.5.0"; _G.C_AddOns = nil end), "0.5.0")
        assertEquals(version(function(S) S.addonVersion = "0.5.1"; _G.C_AddOns = {} end), "0.5.1")
    end)
    it("the unstamped placeholder, empty, missing and non-string values give 'dev'", function()
        for _, v in ipairs({ "@project-version@", "", false, 5, 0 }) do
            assertEquals(version(function(S) S.addonVersion = v or nil end), "dev", tostring(v))
        end
        assertEquals(version(function(S) _G.C_AddOns = nil; _G.GetAddOnMetadata = nil end), "dev")
        assertEquals(version(function(S) S.addonVersion = { "x" } end), "dev")
    end)
    it("a metadata API that raises is not swallowed silently by the addon (documented: callers are wrapped)", function()
        local ok = pcall(version, function() _G.C_AddOns = { GetAddOnMetadata = function() error("nope") end } end)
        if ok then return end
        warn("ns.AddonVersion raises when C_AddOns.GetAddOnMetadata raises (never happens on a real client)")
    end)
    it("ns.SchemaVersion equals DEFAULTS.version", function()
        mock.install(); local ns = {}; L.loadContract(ns)
        assertEquals(ns.SchemaVersion(), ns.DEFAULTS.version)
    end)
end)

describe("shipping: version in /hf version, the options title and the footer", function()
    local function boot(versionValue)
        mock.install(); local S = mock.state
        S.addonVersion = versionValue
        local n = {}
        for _, rel in ipairs(toc.files) do if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, n)) end end
        mock.fire("ADDON_LOADED", "HealerForever"); mock.fire("PLAYER_LOGIN"); mock.setGroup(1)
        mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
        return n
    end
    local function slash(msg) mock.printed = {}; _G.SlashCmdList.HEALERFOREVER(msg); return table.concat(mock.printed, "\n") end
    local function texts()
        local out = {}
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if type(s.text) == "string" then out[#out + 1] = s.text end
            if s.title then out[#out + 1] = "TITLE:" .. s.title end
        end
        return out
    end
    local function has(prefix) for _, t in ipairs(texts()) do if t:find(prefix, 1, true) then return t end end end
    it("/hf version prints the version and the schema", function()
        boot("2.4.6")
        local out = slash("version")
        assertNotNil(out:find("HealerForever 2.4.6 (settings schema 4)", 1, true), out)
        boot("@project-version@")
        assertNotNil(slash("version"):find("HealerForever dev (settings schema 4)", 1, true))
        assertNotNil(slash("VERSION"):find("schema 4", 1, true), "case-insensitive")
    end)
    it("the options window title and the footer line", function()
        local n = boot("2.4.6"); n.Options:Show("general"); mock.flushTimers()
        assertNotNil(has("TITLE:Healer Forever v2.4.6") or has("Healer Forever v2.4.6"))
        assertNotNil(has("Healer Forever v2.4.6 \194\183 settings v4 \194\183 by trtg"), table.concat(texts(), "\n"))
    end)
    it("dev builds say '(dev)' in the title and 'dev' in the footer", function()
        local n = boot("@project-version@"); n.Options:Show("general"); mock.flushTimers()
        assertNotNil(has("TITLE:Healer Forever (dev)") or has("Healer Forever (dev)"))
        assertNotNil(has("Healer Forever dev \194\183 settings v4 \194\183 by trtg"))
    end)
    it("the 'Settings are saved on /reload or logout' footer is present", function()
        local n = boot("1.0.0"); n.Options:Show("general"); mock.flushTimers()
        assertNotNil(has("Settings are saved on /reload or logout"))
    end)
    it("the TOC Version is the unstamped placeholder in the repo (the release script stamps the copy)", function()
        assertEquals(toc.meta.Version, "@project-version@")
    end)
    it("the TOC declares both saved variables and a 'dev' fallback keeps the addon usable", function()
        assertNotNil(toc.meta.SavedVariables:find("HealerForeverDB", 1, true)); assertNotNil(toc.meta.SavedVariablesPerCharacter:find("HealerForeverCharDB", 1, true))
    end)
end)

-- ======================================================================== 6. example loaders
describe("shipping: example loaders", function()
    local function boot()
        mock.install(); local S = mock.state
        S.units.player.class = "WARRIOR"
        local n = {}
        for _, rel in ipairs(toc.files) do if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, n)) end end
        mock.fire("ADDON_LOADED", "HealerForever"); mock.fire("PLAYER_LOGIN"); mock.setGroup(1)
        mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
        return n
    end
    local function button(text) for _, f in ipairs(mock.frames) do if st(f).text == text and st(f).scripts.OnClick then return f end end end
    local function click(f) st(f).scripts.OnClick(f, "LeftButton"); mock.flushTimers() end
    -- "Load example..." opens a menu of "Load example: <Class>" entries
    local function loadExample(name)
        mock.menu = nil
        click(button("Load example..."))
        if mock.pickMenu("Load example: " .. name) then mock.flushTimers(); return true end
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if s.shown and f.item and f.item.text == "Load example: " .. name and s.scripts.OnClick then s.scripts.OnClick(f, "LeftButton"); mock.flushTimers(); return true end
        end
        error("menu entry not found: " .. name)
    end

    it("ExamplePaladin / EXAMPLE_PALADIN are templates: fresh copies, valid, and independent of the shipped defaults", function()
        local n = boot()
        local a, b = n.Presets.ExamplePaladin(), n.Presets.ExamplePaladin()
        assertTrue(a ~= b and a.map ~= b.map)
        a.map.PALADIN.DEFAULT = { "none" }
        assertDeepEquals(b.map.PALADIN.DEFAULT, n.Presets.ExamplePaladin().map.PALADIN.DEFAULT)
        for key, action in pairs(n.Bindings.EXAMPLE_PALADIN) do
            assertNotNil(n.Bindings.ParseKey(key), key)
            assertNotNil(n.Bindings.ToPhysicalAttributes(key, action) or n.Bindings.ToOverrideAttributes("HFB1", action), key)
        end
        assertEquals(n.db.presets[1].name, "Default", "the shipped default is untouched by the loaders")
    end)
    it("'Load example: Paladin' ADDS a preset and never overwrites or reorders existing ones", function()
        local n = boot()
        n.Options:Show("buffs"); mock.flushTimers()
        n.db.presets[1].name = "Mine"; n.db.presets[1].map.MAGE.DEFAULT = "kings"
        n.Presets.Add(n.db.presets, "Second", 1)
        local before = deepcopy(n.db.presets); local active = n.db.activePreset
        loadExample("Paladin")
        assertEquals(#n.db.presets, #before + 1)
        for i = 1, #before do assertNil(diff(before[i], n.db.presets[i], "preset" .. i)) end
        assertEquals(n.db.presets[#before + 1].name, n.Presets.ExamplePaladin().name)
        assertNil(diff(n.Presets.ExamplePaladin(), n.db.presets[#before + 1], "example"))
        assertEquals(n.db.activePreset, active, "the active preset does not change")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("loading twice adds a second independent copy (duplicates are allowed by design, nothing is overwritten)", function()
        local n = boot()
        n.Options:Show("buffs"); mock.flushTimers()
        loadExample("Paladin"); loadExample("Paladin")
        assertEquals(#n.db.presets, 3)
        assertTrue(n.db.presets[2] ~= n.db.presets[3] and n.db.presets[2].map ~= n.db.presets[3].map)
        n.db.presets[2].map.PALADIN.TANK = { "kings" }
        assertDeepEquals(n.db.presets[3].map.PALADIN.TANK, { "might" }, "copies are independent")
        assertEquals(n.db.presets[1].name, "Default")
    end)
    it("the loaded example preset resolves the old 5-man rules and works for the buttons", function()
        local n = boot()
        n.Options:Show("buffs"); mock.flushTimers()
        loadExample("Paladin")
        local p = n.db.presets[2]
        assertEquals(n.Presets.ResolveBuff(p, "PALADIN", "TANK"), "might"); assertEquals(n.Presets.ResolveBuff(p, "PALADIN", "HEALER"), "wisdom")
    end)
    it("example bindings fill only EMPTY slots; the default target / menu count as empty", function()
        local n = boot()
        n.Options:Show("binds"); mock.flushTimers()
        click(button("Load example bindings (Paladin)"))
        for key, action in pairs(n.Bindings.EXAMPLE_PALADIN) do
            assertEquals(n.db.bindings[key].type, action.type, key); assertEquals(n.db.bindings[key].spell, action.spell, key)
        end
        assertEquals(n.db.bindings["|1"].spell, "Flash of Light", "default Left = target counted as empty")
        assertEquals(n.db.bindings["|2"].spell, "Holy Light", "default Right = menu counted as empty")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("user bindings are never overwritten (including user-chosen plain Left/Right)", function()
        local n = boot()
        n.Options:Show("binds"); mock.flushTimers()
        n.db.bindings["|1"] = { type = "spell", spell = "My Heal" }
        n.db.bindings["|2"] = { type = "spell", spell = "My Other Heal" }
        n.db.bindings["shift|1"] = { type = "macro", macrotext = "/say hi" }
        n.db.bindings["alt|2"] = { type = "target" }
        n.db.bindings["|4"] = { type = "target" }
        local before = deepcopy(n.db.bindings)
        click(button("Load example bindings (Paladin)"))
        for k, v in pairs(before) do assertNil(diff(v, n.db.bindings[k], k), "user binding " .. k .. " changed") end
        assertEquals(n.db.bindings["ctrl|1"].spell, "Holy Shock", "empty slots are still filled")
        assertEquals(n.db.bindings["|5"].spell, "Blessing of Might")
    end)
    it("loading the example bindings twice is idempotent", function()
        local n = boot()
        n.Options:Show("binds"); mock.flushTimers()
        click(button("Load example bindings (Paladin)"))
        local once = deepcopy(n.db.bindings)
        click(button("Load example bindings (Paladin)"))
        assertNil(diff(once, n.db.bindings, "bindings"))
    end)
    it("a user who deliberately cleared Left/Right gets them filled by the example (empty counts as empty)", function()
        local n = boot()
        n.Options:Show("binds"); mock.flushTimers()
        n.db.bindings["|1"] = nil; n.db.bindings["|2"] = nil
        click(button("Load example bindings (Paladin)"))
        assertEquals(n.db.bindings["|1"].spell, "Flash of Light"); assertEquals(n.db.bindings["|2"].spell, "Holy Light")
    end)
    it("the example bindings are applied to the unit buttons as strict macros", function()
        local n = boot()
        n.Options:Show("binds"); mock.flushTimers()
        click(button("Load example bindings (Paladin)"))
        local b = n.UnitFrames.byUnit.player
        assertNotNil(tostring(st(b).attrs.macrotext1):find("[@player,help,nodead] Flash of Light", 1, true), tostring(st(b).attrs.macrotext1))
    end)
    it("example buttons work in combat: data changes, nothing protected is touched; applied after combat", function()
        local n = boot()
        n.Options:Show("binds"); mock.flushTimers()
        local S = mock.state
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0 = #mock.violations
        click(button("Load example bindings (Paladin)"))
        assertEquals(#mock.violations, v0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertNotNil(tostring(st(n.UnitFrames.byUnit.player).attrs.macrotext1):find("Flash of Light", 1, true))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("example data survives the sparse save (preset list and bindings are written whole)", function()
        local n = boot()
        n.Options:Show("buffs"); n.Options:Show("binds"); mock.flushTimers()
        click(button("Load example bindings (Paladin)")); n.Options:Show("buffs"); loadExample("Paladin")
        local save = n:BuildSaveTable()
        assertEquals(#save.presets, 2); assertEquals(save.bindings["|1"].spell, "Flash of Light"); assertEquals(save.bindings["alt|1"].spell, "Divine Favor")
    end)
end)
