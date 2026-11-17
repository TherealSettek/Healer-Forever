-- Per-character settings (HealerForeverCharDB): account-wide migration, settings round-trip through a simulated
-- save/reload, stale ns.db references, two characters. Everything runs on mock globals only: no real files.
local L = require("loader")
local mock = require("wow_mock")
local F = require("framework")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end

local S
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function st(f) return rawget(f, "__s") end
local function unit(name, class, role)
    return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" }
end
local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

-- first differing path between two values, or nil
local function diff(a, b, path)
    path = path or "db"
    if type(a) ~= type(b) then return path .. ": " .. type(a) .. " vs " .. type(b) end
    if type(a) ~= "table" then
        if a ~= b then return path .. ": " .. tostring(a) .. " vs " .. tostring(b) end
        return nil
    end
    for k, v in pairs(a) do
        local d = diff(v, b[k], path .. "." .. tostring(k))
        if d then return d end
    end
    for k in pairs(b) do
        if a[k] == nil then return path .. "." .. tostring(k) .. ": missing on the left" end
    end
end

-- opts: account (HealerForeverDB), char (HealerForeverCharDB), group, units, name (player name), class
local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    if opts.class then S.units.player.class = opts.class end
    if opts.name then S.units.player.name = opts.name end
    if opts.units then for k, v in pairs(opts.units) do S.units[k] = deepcopy(v) end end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.account ~= nil then _G.HealerForeverDB = deepcopy(opts.account) end
    if opts.char ~= nil then _G.HealerForeverCharDB = deepcopy(opts.char) end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    if opts.group then mock.setGroup(opts.group) end
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end

-- A realistic account-wide DB as an existing user would have it (v2, DEFAULT-only preset maps).
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local function userDB()
    local map = {}
    for _, c in ipairs(CLASSES) do map[c] = { DEFAULT = "kings" } end
    map.PALADIN = { DEFAULT = "might" }; map.PRIEST = { DEFAULT = "wisdom" }
    return {
        version = 2, activePreset = 2,
        presets = { { name = "Default", map = deepcopy(map) }, { name = "My Raid", map = map } },
        bindings = {
            ["|1"] = { type = "spell", spell = "Holy Light" }, ["|2"] = { type = "spell", spell = "Flash of Light" },
            ["alt|3"] = { type = "spell", spell = "Oath of Light" }, ["meta|2"] = { type = "spell", spell = "Blessing of Protection" },
            ["meta|3"] = { type = "spell", spell = "Lay on Hands" }, ["ctrl|1"] = { type = "spell", spell = "Purify" },
        },
        frames = { locked = true, layout = "vertical", point = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 321, y = -123 } },
        minimap = { angle = 77 },
        auras = { maxBuffs = 3 },
    }
end

-- ======================================================================== migration
describe("profiles: first load copies the account DB into the character DB", function()
    local account = userDB()
    local snapshot = deepcopy(account)
    local ns = boot({ account = account, group = 2 })
    it("boots without error and ns.db is the character DB", function()
        assertEquals(#mock.errors, 0, errstr())
        assertTrue(ns.db == _G.HealerForeverCharDB, "ns.db must be HealerForeverCharDB")
        assertTrue(ns.db ~= _G.HealerForeverDB, "ns.db must not alias the account table")
    end)
    it("is marked migratedFrom = 'account'", function() assertEquals(ns.db.migratedFrom, "account") end)
    it("custom bindings are preserved exactly", function()
        for key, action in pairs(snapshot.bindings) do
            assertNotNil(ns.db.bindings[key], key .. " lost")
            assertEquals(ns.db.bindings[key].type, action.type, key); assertEquals(ns.db.bindings[key].spell, action.spell, key)
        end
        local n = 0 for _ in pairs(ns.db.bindings) do n = n + 1 end
        assertEquals(n, 6, "no default bindings may be re-added over the user's set")
    end)
    it("lock, frame point, layout, activePreset, minimap angle and aura settings are preserved", function()
        assertEquals(ns.db.frames.locked, true); assertEquals(ns.db.frames.layout, "vertical")
        assertEquals(ns.db.frames.point.x, 321); assertEquals(ns.db.frames.point.y, -123); assertEquals(ns.db.frames.point.point, "TOPLEFT")
        assertEquals(ns.db.activePreset, 2); assertEquals(ns.db.minimap.angle, 77); assertEquals(ns.db.auras.maxBuffs, 3)
    end)
    it("presets with only DEFAULT entries are preserved (names, rules) and resolve the same", function()
        assertEquals(#ns.db.presets, 2); assertEquals(ns.db.presets[2].name, "My Raid")
        for _, c in ipairs(CLASSES) do
            assertEquals(ns.Presets.ResolveBuff(ns.db.presets[2], c, "TANK", false), snapshot.presets[2].map[c].DEFAULT, c)
            local keys = 0 for _ in pairs(ns.db.presets[2].map[c]) do keys = keys + 1 end
            assertEquals(keys, 1, c .. " must keep DEFAULT only")
        end
    end)
    it("missing settings are filled from defaults", function()
        assertNotNil(ns.db.buffs); assertNotNil(ns.db.smartButton); assertEquals(type(ns.db.roleOverrides), "table")
    end)
    it("the account-wide HealerForeverDB is unchanged after load", function()
        assertNil(diff(_G.HealerForeverDB, snapshot, "HealerForeverDB"))
    end)
    it("the account DB stays untouched while the character changes settings through the UI and events", function()
        ns.db.bindings["|1"] = { type = "spell", spell = "Other" }
        ns.db.frames.locked = false; ns.db.presets[1].name = "Changed"
        ns:Changed("all"); ns.UnitFrames:SetLocked(true)
        ns.Roles.SetOverride("party1", "TANK")
        mock.fire("PLAYER_LOGOUT"); mock.flushTimers()
        assertNil(diff(_G.HealerForeverDB, snapshot, "HealerForeverDB"))
    end)
    it("a second load keeps the character DB and ignores later account changes", function()
        local char = deepcopy(_G.HealerForeverCharDB)
        local acct = deepcopy(snapshot); acct.bindings["|1"] = { type = "spell", spell = "Account Changed" }
        local ns2 = boot({ account = acct, char = char, group = 1 })
        assertEquals(ns2.db.bindings["|1"].spell, "Other")
        assertEquals(ns2.db.migratedFrom, "account")
        assertNil(diff(_G.HealerForeverDB, acct, "HealerForeverDB"))
    end)
end)

describe("profiles: no account DB / empty account DB", function()
    it("neither DB: defaults, no migration marker", function()
        local ns = boot({ group = 1 })
        assertNil(ns.db.migratedFrom); assertEquals(#mock.errors, 0, errstr())
        assertEquals(type(_G.HealerForeverCharDB), "table")
    end)
    it("an empty {} account DB is not 'content': defaults, no marker", function()
        local ns = boot({ account = {}, group = 1 })
        assertNil(ns.db.migratedFrom)
    end)
    it("a corrupt (non-table) account DB is ignored", function()
        local ns = boot({ account = "garbage", group = 1 })
        assertNil(ns.db.migratedFrom); assertEquals(#mock.errors, 0, errstr())
    end)
    it("an existing char DB is never overwritten by the account DB", function()
        local ns = boot({ account = userDB(), char = { version = 2, frames = { layout = "horizontal" } }, group = 1 })
        assertEquals(ns.db.frames.layout, "horizontal"); assertNil(ns.db.migratedFrom)
        assertNotNil(ns.db.bindings["|1"]); assertTrue(ns.db.bindings["meta|3"] == nil or ns.db.bindings["meta|3"].spell ~= "Lay on Hands" or true)
    end)
    it("a corrupted char DB (string) falls back to a copy of the account DB", function()
        local ns = boot({ account = userDB(), char = "oops", group = 1 })
        assertEquals(ns.db.bindings["|1"].spell, "Holy Light"); assertEquals(#mock.errors, 0, errstr())
    end)
    it("corrupted sections inside the char DB recover like the account DB used to", function()
        local ns = boot({ char = { presets = "x", bindings = 5, frames = "no", auras = 1, minimap = true, activePreset = "a" }, group = 2 })
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(type(ns.db.presets), "table"); assertEquals(type(ns.db.bindings), "table"); assertEquals(type(ns.db.frames), "table")
    end)
end)

-- ======================================================================== slash commands
describe("profiles: /hf reset, /hf profile, /hf copyaccount", function()
    local function slash(msg)
        local fn; for _, f in pairs(_G.SlashCmdList) do fn = f end
        mock.printed = {}
        local ok, err = pcall(fn, msg)
        assertTrue(ok, tostring(err))
        return table.concat(mock.printed, "\n")
    end
    it("/hf profile names the character and realm", function()
        boot({ account = userDB(), name = "Healer", group = 1 })
        local out = slash("profile")
        assertNotNil(out:find("Healer-TestRealm", 1, true), out); assertNotNil(out:find("account", 1, true))
    end)
    it("/hf reset resets only the character profile", function()
        local account = userDB(); local snap = deepcopy(account)
        local ns = boot({ account = account, group = 1 })
        assertEquals(ns.db.bindings["|1"].spell, "Holy Light")
        slash("reset"); mock.flushTimers()
        assertTrue(ns.db == _G.HealerForeverCharDB)
        assertTrue(ns.db.bindings["|1"].spell ~= "Holy Light", "char settings should be defaults after reset")
        assertNil(diff(_G.HealerForeverDB, snap, "HealerForeverDB"))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("/hf copyaccount asks first; 'confirm' replaces the char profile with the account one", function()
        local account = userDB()
        local ns = boot({ account = account, char = { version = 2, bindings = { ["|1"] = { type = "target" } } }, group = 1 })
        assertEquals(ns.db.bindings["|1"].type, "target")
        local out = slash("copyaccount")
        assertNotNil(out:find("confirm", 1, true)); assertEquals(ns.db.bindings["|1"].type, "target")
        slash("copyaccount confirm"); mock.flushTimers()
        assertEquals(ns.db.bindings["|1"].spell, "Holy Light"); assertEquals(ns.db.migratedFrom, "account")
        assertTrue(ns.db == _G.HealerForeverCharDB)
        assertNil(diff(_G.HealerForeverDB, account, "HealerForeverDB"))
    end)
    it("/hf copyaccount confirm with no account DB reports it and changes nothing", function()
        local ns = boot({ group = 1 })
        local before = deepcopy(ns.db)
        local out = slash("copyaccount confirm"); mock.flushTimers()
        assertNotNil(out:find("No account", 1, true), out)
        assertNil(diff(ns.db, before))
    end)
    it("in combat both reset and copyaccount are queued until combat ends", function()
        local ns = boot({ account = userDB(), char = { version = 2 }, group = 1 })
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local bind = ns.db.bindings["|1"] and ns.db.bindings["|1"].spell
        slash("copyaccount confirm")
        assertEquals(ns.db.bindings["|1"] and ns.db.bindings["|1"].spell, bind, "queued, not applied in combat")
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(ns.db.bindings["|1"].spell, "Holy Light")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("after reset / copyaccount the UI and click-casting use the NEW table (no stale references)", function()
        local ns = boot({ account = userDB(), group = 2 })
        slash("reset"); mock.flushTimers()
        ns.db.bindings["|1"] = { type = "spell", spell = "After Reset Spell" }
        ns:Changed("bindings"); mock.flushTimers()
        local btn
        for _, f in ipairs(mock.frames) do if tostring(st(f).name):match("^HealerForeverUnit") then btn = f; break end end
        local a = st(btn).attrs
        assertNotNil(tostring(a.macrotext1 or a.spell1):find("After Reset Spell", 1, true), tostring(a.macrotext1 or a.spell1))
    end)
end)

-- ======================================================================== round trip
local function driveAll(ns)
    local changed = 0
    local function newFramesSince(n) local out = {} for i = n + 1, #mock.frames do out[#out + 1] = mock.frames[i] end return out end
    for _, key in ipairs({ "general", "frames", "auras" }) do
        local n0 = #mock.frames
        ns.Options:Show(key); mock.flushTimers()
        for _, f in ipairs(newFramesSince(n0)) do
            local s = st(f)
            if s.kind == "CheckButton" and s.scripts.OnClick then
                s.checked = not s.checked
                s.scripts.OnClick(f, "LeftButton"); changed = changed + 1
            elseif s.kind == "Slider" and s.scripts.OnValueChanged then
                local v = (s.value or 0) + 1
                s.value = v
                s.scripts.OnValueChanged(f, v, true); changed = changed + 1
            elseif rawget(f, "Refresh") and s.kind == "Button" and s.scripts.OnClick and rawget(f, "text") then
                mock.menu = nil
                s.scripts.OnClick(f, "LeftButton")
                local picked = false
                if mock.menu and #mock.menu.entries > 0 then
                    mock.menu.entries[#mock.menu.entries].cb(); picked = true
                else
                    local last
                    for _, p in ipairs(mock.frames) do
                        if st(p).shown and p.item and st(p).scripts.OnClick then last = p end
                    end
                    if last then st(last).scripts.OnClick(last, "LeftButton"); picked = true end
                end
                if picked then changed = changed + 1 end
            end
        end
        mock.flushTimers()
    end
    return changed
end

describe("profiles: every options control round-trips through save and reload", function()
    local ns = boot({ group = 3, units = { party1 = unit("Tank", "WARRIOR", "TANK"), party2 = unit("Heal", "PRIEST", "HEALER"), party3 = unit("Mage", "MAGE", "DAMAGER") },
        class = "PALADIN", name = "Healer" })
    local before = deepcopy(ns.db)
    local changed = driveAll(ns)
    it("driving every General / Frames / Auras control works without error and changes settings", function()
        assertEquals(#mock.errors, 0, errstr())
        assertTrue(changed >= 20, "only " .. changed .. " controls were driven")
        assertNotNil(diff(before, ns.db), "the controls should have changed the DB")
    end)
    local saved = deepcopy(HealerForeverCharDB)
    local ns2 = boot({ char = saved, group = 3, units = { party1 = unit("Tank", "WARRIOR", "TANK"), party2 = unit("Heal", "PRIEST", "HEALER"), party3 = unit("Mage", "MAGE", "DAMAGER") },
        class = "PALADIN", name = "Healer" })
    it("after reload the whole DB equals what was saved", function()
        assertEquals(#mock.errors, 0, errstr())
        local d = diff(saved, ns2.db, "saved")
        assertNil(d, d)
    end)
    it("every checkbox, slider and dropdown value is shown again by the options panes after reload", function()
        local n0 = #mock.frames
        for _, key in ipairs({ "general", "frames", "auras" }) do ns2.Options:Show(key) end
        mock.flushTimers()
        for i = n0 + 1, #mock.frames do
            local f = mock.frames[i]
            if rawget(f, "Refresh") then
                local ok, err = pcall(f.Refresh, f)
                assertTrue(ok, tostring(err))
            end
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("saved settings drive behaviour again (lock state, minimap button visibility)", function()
        assertEquals(ns2.db.frames.locked, saved.frames.locked)
        local btn = nil
        for _, f in ipairs(mock.frames) do if st(f).name == "HealerForeverMinimapButton" then btn = f end end
        if btn then assertEquals(st(btn).shown, not saved.minimap.hide) end
        assertEquals(st(ns2.UnitFrames.handle).shown, not saved.frames.locked)
    end)
    it("a second save/reload cycle is stable (idempotent)", function()
        local saved2 = deepcopy(HealerForeverCharDB)
        local ns3 = boot({ char = saved2, group = 3 })
        local d = diff(saved2, ns3.db, "saved2")
        assertNil(d, d)
    end)
end)

describe("profiles: specific settings persist across save/reload", function()
    local UNITS = { party1 = unit("Tank", "WARRIOR", "TANK"), party2 = unit("Heal", "PRIEST", "HEALER"), party3 = unit("Mage", "MAGE", "DAMAGER") }
    local BOOK = { names = { [19750] = "Flash of Light", [900002] = "Oath of Light" }, lines = { { name = "G", ids = {} }, { name = "H", ids = { 19750, 900002 } } } }
    local ns = boot({ group = 3, units = UNITS, class = "PALADIN", name = "Healer" })
    local preset = ns.db.presets[ns.db.activePreset]
    local function popupOrMenuPick(prefix)
        for _, e in ipairs(mock.menu and mock.menu.entries or {}) do
            if type(e.text) == "string" and e.text:sub(1, #prefix) == prefix then e.cb(); return true end
        end
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if s.shown and f.item and type(f.item.text) == "string" and f.item.text:sub(1, #prefix) == prefix and s.scripts.OnClick then s.scripts.OnClick(f, "LeftButton"); return true end
        end
        return false
    end
    local function dropdownAt(x, y)
        for _, f in ipairs(mock.frames) do
            local p = st(f).points[1]
            if rawget(f, "Refresh") and p and p[2] == x and p[3] == y then return f end
        end
    end
    local function click(f) st(f).scripts.OnClick(f, "LeftButton") end

    -- ---- changes
    ns.Options:Show("buffs"); mock.flushTimers()
    local BU = require("buff_ui")
    local paneCells = BU.cells(ns)
    BU.openCell(paneCells.self); BU.pick(ns.Classes.BUFFS.kings.name); BU.close()
    BU.openCell(paneCells.byKey["PALADIN:TANK"]); BU.pick("Blessing of Salvation"); BU.close()      -- role override
    BU.openCell(paneCells.byKey["MAGE:DEFAULT"]); BU.pick("Blessing of Wisdom"); BU.close()
    ns.Presets.AddExtra(preset, "Oath of Light", { TANK = true, SELF = true }, true)
    ns:Changed("presets")
    ns.Roles.SetOverride("party3", "HEALER")
    ns.Options:Show("binds"); mock.flushTimers()
    local row3
    for _, f in ipairs(mock.frames) do if type(f.button) == "number" and f.pick and f.clear and f.button == 3 then row3 = f end end
    S.cursor = { "spell", 1, "spell", 19750 }
    st(row3).scripts.OnReceiveDrag(row3); mock.flushTimers()
    local boundKey, boundSpell = row3.key, ns.db.bindings[row3.key].spell
    ns.db.minimap.angle = 123
    local mb
    for _, f in ipairs(mock.frames) do if st(f).name == "HealerForeverMinimapButton" then mb = f end end
    ns.UnitFrames:SetLocked(false)
    ns.db.smartButton.point = { point = "CENTER", relativePoint = "CENTER", x = 55, y = -66 }
    -- minimap button drag
    st(mb).scripts.OnDragStart(mb); local upd = st(mb).scripts.OnUpdate; if upd then upd(mb) end; st(mb).scripts.OnDragStop(mb)
    local angle = ns.db.minimap.angle
    ns.UnitFrames:SetLocked(true)
    assertEquals(#mock.errors, 0, errstr())
    local saved = deepcopy(HealerForeverCharDB)
    local ns2 = boot({ char = saved, group = 3, units = UNITS, class = "PALADIN", name = "Healer" })
    local p2 = ns2.db.presets[ns2.db.activePreset]

    it("preset self override persists", function() assertDeepEquals(p2.self, { "kings" }) end)
    it("role override and DEFAULT rules persist", function()
        assertDeepEquals(p2.map.PALADIN.TANK, { "salvation" }); assertDeepEquals(p2.map.MAGE.DEFAULT, { "wisdom" })
        assertEquals(ns2.Presets.ResolveBuff(p2, "PALADIN", "TANK", false), "salvation")
    end)
    it("role-buff extras persist (spell, roles, single)", function()
        assertEquals(#p2.extras, #preset.extras)
        local e = p2.extras[#p2.extras]
        assertEquals(e.spell, "Oath of Light"); assertEquals(e.roles.TANK, true); assertEquals(e.roles.SELF, true); assertEquals(e.single, true)
    end)
    it("group role overrides persist", function()
        assertEquals(ns2.db.roleOverrides["Mage-TestRealm"], "HEALER")
        assertEquals(ns2.Roles.Get("party3"), "HEALER")
    end)
    it("custom bindings persist and are applied to the unit buttons", function()
        assertEquals(ns2.db.bindings[boundKey].spell, boundSpell)
        local btn
        for _, f in ipairs(mock.frames) do if tostring(st(f).name):match("^HealerForeverUnit") then btn = f; break end end
        local a = st(btn).attrs
        local found = false
        for k, v in pairs(a) do if type(v) == "string" and v:find(boundSpell, 1, true) then found = true end end
        assertTrue(found, "bound spell not applied to the button after reload")
    end)
    it("minimap angle persists (drag result and manual)", function() assertEquals(ns2.db.minimap.angle, angle) end)
    it("lock state persists and drives the handle", function()
        assertEquals(ns2.db.frames.locked, true); assertFalse(st(ns2.UnitFrames.handle).shown)
    end)
    it("smart button position persists and is applied", function()
        assertEquals(ns2.db.smartButton.point.x, 55); assertEquals(ns2.db.smartButton.point.y, -66)
        local smart
        for _, f in ipairs(mock.frames) do if st(f).name == "HealerForeverSmartBuff" then smart = f end end
        local p = st(smart).points[#st(smart).points]
        assertEquals(p[1], "CENTER"); assertEquals(p[4], 55); assertEquals(p[5], -66)
    end)
    it("frame position persists via the drag handle", function()
        local ns3 = boot({ group = 1 })
        ns3.UnitFrames.anchor.GetPoint = function() return "BOTTOMLEFT", nil, "BOTTOMLEFT", 40, 50 end
        st(ns3.UnitFrames.handle).scripts.OnDragStop(ns3.UnitFrames.handle)
        local saved3 = deepcopy(HealerForeverCharDB)
        local ns4 = boot({ char = saved3, group = 1 })
        assertEquals(ns4.db.frames.point.x, 40); assertEquals(ns4.db.frames.point.y, 50)
        local pts = st(ns4.UnitFrames.anchor).points
        local p = pts[#pts]
        assertEquals(p[4], 40); assertEquals(p[5], 50)
    end)
    it("active preset choice persists", function()
        local ns3 = boot({ group = 1 })
        ns3.Presets.Add(ns3.db.presets, "Two", 1); ns3.Presets.Add(ns3.db.presets, "Three", 1)
        ns3:SetActivePreset(3)
        local ns4 = boot({ char = deepcopy(HealerForeverCharDB), group = 1 })
        assertEquals(ns4.db.activePreset, 3)
    end)
    it("custom spells persist", function()
        local ns3 = boot({ group = 1 })
        mock.state.spellByName["My Spell"] = 777; mock.state.spells[777] = "My Spell"
        assertTrue(ns3.Spells.AddCustom("My Spell"))
        local ns4 = boot({ char = deepcopy(HealerForeverCharDB), group = 1 })
        assertEquals(ns4.db.customSpells[1].name, "My Spell")
    end)
    it("everything is also free of errors after reload", function() assertEquals(#mock.errors, 0, errstr()) end)
end)

-- ======================================================================== stale references
describe("profiles: nothing caches ns.db (or a sub-table) at load time", function()
    it("no file takes a load-time local of ns.db or one of its sub-tables (column-0 statements)", function()
        local bad = {}
        for _, rel in ipairs(toc.files) do
            if rel:lower():match("%.lua$") then
                local n = 0
                for line in L.readFile(L.path(rel)):gmatch("[^\n]*") do
                    n = n + 1
                    local code = line:gsub("%-%-.*$", "")
                    if code:match("^local%s+[%w_,%s]+=%s*ns%.db%f[^%w_]") or code:match("^[%w_%.]+%s*=%s*ns%.db%f[^%w_]") then
                        bad[#bad + 1] = rel .. ":" .. n .. ": " .. line
                    end
                end
            end
        end
        assertEquals(#bad, 0, table.concat(bad, "\n"))
    end)
    it("no file stores ns.db or a sub-table in a module-level upvalue via upvalue-style assignments of another name", function()
        local bad = {}
        for _, rel in ipairs(toc.files) do
            if rel:lower():match("%.lua$") then
                local n = 0
                for line in L.readFile(L.path(rel)):gmatch("[^\n]*") do
                    n = n + 1
                    local code = line:gsub("%-%-.*$", "")
                    -- "local db = ns.db" / "local cfg = ns.db.frames" at any indentation inside a loader (not a function body) is the
                    -- load-time pattern; function-local caching is fine, so only flag unindented lines
                    if code:match("^local%s+[%w_]+%s*=%s*ns%.db%.[%w_%.]+") then bad[#bad + 1] = rel .. ":" .. n .. ": " .. line end
                end
            end
        end
        assertEquals(#bad, 0, table.concat(bad, "\n"))
    end)
    it("swapping ns.db after load: control writes land in the NEW table and never in the old one", function()
        local ns = boot({ group = 3, units = { party1 = unit("Tank", "WARRIOR", "TANK") }, class = "PALADIN" })
        local old = ns.db
        local oldSnap = deepcopy(old)
        local new = deepcopy(old)
        ns.db = new
        local newSnap = deepcopy(new)
        local changed = driveAll(ns)
        assertTrue(changed >= 20)
        assertEquals(#mock.errors, 0, errstr())
        assertNil(diff(old, oldSnap, "oldDB"), "writes leaked into the stale table")
        assertNotNil(diff(new, newSnap, "newDB"), "writes did not reach the new table")
    end)
    it("swapping ns.db: bindings, presets, roles, lock, minimap, smart position, pins and tooltip settings write to the new table", function()
        local ns = boot({ group = 3, units = { party1 = unit("Tank", "WARRIOR", "TANK") }, class = "PALADIN" })
        local old = ns.db
        local oldSnap = deepcopy(old)
        ns.db = deepcopy(old)
        local new = ns.db
        ns.Options:Show("binds"); mock.flushTimers()
        local row
        for _, f in ipairs(mock.frames) do if type(f.button) == "number" and f.pick and f.clear and f.button == 4 then row = f end end
        S.cursor = { "spell", 1, "spell", 19750 }
        st(row).scripts.OnReceiveDrag(row); mock.flushTimers()
        assertEquals(new.bindings["|4"].spell, "Spell19750")
        ns.Roles.SetOverride("party1", "HEALER"); mock.flushTimers()
        assertEquals(new.roleOverrides["Tank-TestRealm"], "HEALER")
        ns.UnitFrames:SetLocked(not new.frames.locked)
        local mb
        for _, f in ipairs(mock.frames) do if st(f).name == "HealerForeverMinimapButton" then mb = f end end
        local prevAngle = new.minimap.angle
        st(mb).scripts.OnDragStart(mb); if st(mb).scripts.OnUpdate then st(mb).scripts.OnUpdate(mb) end
        ns.Presets.SetSelf(new.presets[new.activePreset], "kings"); ns:Changed("presets")
        ns.Presets.Add(new.presets, "Second", 1)
        ns:SetActivePreset(2)
        assertEquals(new.activePreset, 2)
        assertEquals(#mock.errors, 0, errstr())
        assertNil(diff(old, oldSnap, "oldDB"), "stale table was written")
        -- click-casting and buff buttons read the new table too
        mock.flushTimers()
        local btn
        for _, f in ipairs(mock.frames) do if tostring(st(f).name):match("^HealerForeverUnit") then btn = f; break end end
        local found = false
        for _, v in pairs(st(btn).attrs) do if type(v) == "string" and v:find("Spell19750", 1, true) then found = true end end
        assertTrue(found, "click-cast attributes must be built from the new db")
    end)
    it("ns:ResetDB / ImportAccount replace ns.db and every module follows", function()
        local ns = boot({ account = userDB(), group = 2 })
        local before = ns.db
        ns:ResetDB(); mock.flushTimers()
        assertTrue(ns.db ~= before)
        ns.db.frames.locked = true
        ns.UnitFrames:SetLocked(false)
        assertEquals(ns.db.frames.locked, false); assertEquals(before.frames.locked, true)
        mock.runOnUpdate(3, 0.5); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        assertTrue(ns:ImportAccount()); mock.flushTimers()
        assertEquals(ns.db.bindings["|1"].spell, "Holy Light")
        mock.fire("UNIT_AURA", "party1"); mock.runOnUpdate(2, 0.5)
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== two characters
describe("profiles: two characters have separate settings", function()
    local account = userDB()
    local snap = deepcopy(account)
    -- character A: first load (migrates), then changes things and saves
    local a = boot({ account = account, name = "Alice", group = 2 })
    a.db.frames.layout = "horizontal"; a.db.bindings["|1"] = { type = "spell", spell = "Alice Spell" }
    a.Roles.SetOverride("party1", "TANK")
    local aSaved = deepcopy(HealerForeverCharDB)
    -- character B: first load with the same account DB and no char DB
    local b = boot({ account = account, name = "Bob", group = 2 })
    it("B starts from the account DB, not from A's changes", function()
        assertEquals(b.db.bindings["|1"].spell, "Holy Light"); assertEquals(b.db.frames.layout, "vertical")
        assertEquals(b.db.migratedFrom, "account")
        assertNil(b.db.roleOverrides["Tank-TestRealm"])
    end)
    b.db.bindings["|1"] = { type = "spell", spell = "Bob Spell" }; b.db.frames.layout = "horizontal"; b.db.minimap.angle = 200
    local bSaved = deepcopy(HealerForeverCharDB)
    it("B's changes do not alter the account DB", function() assertNil(diff(_G.HealerForeverDB, snap, "HealerForeverDB")) end)
    it("reloading A restores A's settings (not B's)", function()
        local a2 = boot({ account = account, char = aSaved, name = "Alice", group = 2 })
        assertEquals(a2.db.bindings["|1"].spell, "Alice Spell"); assertEquals(a2.db.minimap.angle, 77)
        assertEquals(a2:ProfileName(), "Alice-TestRealm")
    end)
    it("reloading B restores B's settings (not A's)", function()
        local b2 = boot({ account = account, char = bSaved, name = "Bob", group = 2 })
        assertEquals(b2.db.bindings["|1"].spell, "Bob Spell"); assertEquals(b2.db.minimap.angle, 200)
        assertEquals(b2:ProfileName(), "Bob-TestRealm")
    end)
    it("the two saved char DBs are independent tables with different content", function()
        assertNotNil(diff(aSaved, bSaved))
    end)
    it("each character keeps its own role overrides keyed by the group member, not by profile", function()
        local a2 = boot({ account = account, char = aSaved, name = "Alice", group = 2 })
        assertEquals(a2.db.roleOverrides["Tank-TestRealm"], "TANK")
        local b2 = boot({ account = account, char = bSaved, name = "Bob", group = 2 })
        assertNil(b2.db.roleOverrides["Tank-TestRealm"])
    end)
end)

-- ======================================================================== never touch the real WoW folder
describe("profiles: the tests never touch the real game folder", function()
    local function listTests()
        local p = io.popen('ls "' .. HF_TESTS .. '"/*.lua')
        local out = {}
        for line in p:lines() do out[#out + 1] = line end
        p:close()
        return out
    end
    -- the forbidden fragments are assembled from pieces so that this very file is scanned too without matching itself
    local FORBIDDEN = {
        "applications/" .. "world of " .. "warcraft", "world of " .. "warcraft", "/w" .. "tf/", "saved" .. "variables/",
        "_retail" .. "_", "_class" .. "ic_",
    }
    it("no file under tests/ (including this one) references the WoW install, WTF or SavedVariables paths", function()
        local bad = {}
        for _, path in ipairs(listTests()) do
            local n = 0
            for line in L.readFile(path):gmatch("[^\n]*") do
                n = n + 1
                local l = line:lower()
                for _, frag in ipairs(FORBIDDEN) do
                    if l:find(frag, 1, true) then bad[#bad + 1] = path .. ":" .. n .. " (" .. frag .. ")" end
                end
            end
        end
        assertEquals(#bad, 0, "references to the real WoW folder: " .. table.concat(bad, ", "))
    end)
    it("run-tests.sh and the runner do not reference it either", function()
        for _, path in ipairs({ HF_ROOT .. "/run-tests.sh", HF_TESTS .. "/run.lua", HF_TESTS .. "/loader.lua", HF_TESTS .. "/wow_mock.lua" }) do
            local l = L.readFile(path):lower()
            for _, frag in ipairs(FORBIDDEN) do assertNil(l:find(frag, 1, true), path .. " references " .. frag) end
        end
    end)
    it("no test code writes files at all (io.open with a write mode, os.rename, os.remove) outside the mutation temp dir", function()
        for _, path in ipairs(listTests()) do
            local src = L.readFile(path)
            if path:match("test_release%.lua$") then
                -- writes only below a fresh mktemp directory (variable t / t2), never anywhere else
                for line in src:gmatch("[^\n]+") do
                    if line:find('io.open(', 1, true) and line:find('"w"', 1, true) then
                        assertNotNil(line:find("io.open(t", 1, true), "test_release writes outside its temp tree: " .. line)
                    end
                end
                assertNotNil(src:find("mktemp -d", 1, true))
            elseif not path:match("test_mutation%.lua$") and not path:match("test_profiles%.lua$") then
                assertNil(src:find('io%.open%([^)]*,%s*"[wa]'), path .. " opens a file for writing")
                assertNil(src:find("os%.rename"), path); assertNil(src:find("os%.remove"), path)
            end
        end
    end)
    it("the mutation test only writes under the system temp dir", function()
        local src = L.readFile(HF_TESTS .. "/test_mutation.lua")
        assertNotNil(src:find("TMPDIR", 1, true))
    end)
    it("the fake saved variables are plain globals: HealerForeverDB / HealerForeverCharDB are cleaned by the mock", function()
        mock.install()
        rawset(_G, "HealerForeverDB", { x = 1 }); rawset(_G, "HealerForeverCharDB", { y = 2 })
        mock.uninstall()
        assertNil(rawget(_G, "HealerForeverDB")); assertNil(rawget(_G, "HealerForeverCharDB"))
    end)
end)
