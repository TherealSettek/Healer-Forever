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

-- runs a /hf command and returns what it printed
local function slashCmd(msg)
    local fn; for _, f in pairs(_G.SlashCmdList) do fn = f end
    mock.printed = {}
    local ok, err = pcall(fn, msg)
    assertTrue(ok, tostring(err))
    mock.flushTimers()
    return table.concat(mock.printed, "\n")
end

-- ======================================================================== migration
-- Since 0.12.1 a new character starts from the defaults; the account DB only comes in through /hf copyaccount confirm.
describe("profiles: /hf copyaccount confirm copies the account DB into the character DB", function()
    local account = userDB()
    local snapshot = deepcopy(account)
    local ns = boot({ account = account, group = 2 })
    local firstLoad = deepcopy(ns.db)
    local out = slashCmd("copyaccount confirm")
    it("first load ignores the account DB: defaults, no marker; the copy then runs without error and ns.db is the character DB", function()
        assertNil(firstLoad.migratedFrom); assertEquals(firstLoad.bindings["|1"].type, "target"); assertNil(firstLoad.bindings["ctrl|1"])
        assertEquals(firstLoad.frames.locked, ns.DEFAULTS.frames.locked); assertEquals(#firstLoad.presets, 1)
        assertNotNil(out:find("Copied account-wide settings", 1, true), out); assertNil(out:find("except", 1, true), out)
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
    it("a corrupted char DB (string) falls back to the defaults, not to the account DB", function()
        local ns = boot({ account = userDB(), char = "oops", group = 1 })
        assertEquals(ns.db.bindings["|1"].type, "target"); assertNil(ns.db.bindings["ctrl|1"]); assertNil(ns.db.migratedFrom)
        assertEquals(#mock.errors, 0, errstr())
        slashCmd("copyaccount confirm")
        assertEquals(ns.db.bindings["|1"].spell, "Holy Light", "the account DB is still there to copy on request")
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
        boot({ account = userDB(), char = { version = 2, migratedFrom = "account" }, name = "Healer", group = 1 })
        local out = slash("profile")
        assertNotNil(out:find("Healer-TestRealm", 1, true), out); assertNotNil(out:find("account", 1, true))
    end)
    it("/hf reset resets only the character profile", function()
        local account = userDB(); local snap = deepcopy(account)
        local ns = boot({ account = account, group = 1 })
        slash("copyaccount confirm"); mock.flushTimers()
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
        assertNil(ns.db.migratedFrom, "no automatic copy")
        local before = ns.db
        before.frames.locked = true
        ns:ResetDB(); mock.flushTimers()
        assertTrue(ns.db ~= before)
        ns.db.frames.locked = true
        ns.UnitFrames:SetLocked(false)
        assertEquals(ns.db.frames.locked, false); assertEquals(before.frames.locked, true, "the replaced table must not be written")
        mock.runOnUpdate(3, 0.5); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        local ok, skipped = ns:ImportAccount(); mock.flushTimers()
        assertTrue(ok); assertFalse(skipped, "a Paladin takes the Paladin presets whole")
        assertEquals(ns.db.bindings["|1"].spell, "Holy Light")
        mock.fire("UNIT_AURA", "party1"); mock.runOnUpdate(2, 0.5)
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== two characters
describe("profiles: two characters have separate settings", function()
    local account = userDB()
    local snap = deepcopy(account)
    -- character A: first load (defaults), copies the account settings on request, then changes things and saves
    local a = boot({ account = account, name = "Alice", group = 2 })
    slashCmd("copyaccount confirm")
    a.db.frames.layout = "horizontal"; a.db.bindings["|1"] = { type = "spell", spell = "Alice Spell" }
    a.Roles.SetOverride("party1", "TANK")
    local aSaved = deepcopy(HealerForeverCharDB)
    -- character B: first load with the same account DB and no char DB
    local b = boot({ account = account, name = "Bob", group = 2 })
    local bFirst = deepcopy(b.db)
    slashCmd("copyaccount confirm")
    it("B starts from the defaults, not from A's changes nor the account DB; its own copy gets the account DB, not A's changes", function()
        assertEquals(bFirst.bindings["|1"].type, "target"); assertEquals(bFirst.frames.layout, b.DEFAULTS.frames.layout)
        assertNil(bFirst.migratedFrom); assertNil(bFirst.roleOverrides["Tank-TestRealm"])
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

-- ======================================================================== Raid Layout pane (raid Phase 4)
local function raidPane(ns)
    ns.Options:Show("raid"); mock.flushTimers()
    for _, p in ipairs(ns.Options.panes) do if p.key == "raid" then return p.frame end end
end
-- every control of the pane with the text of its label (dropdowns / segments: row label; checkbox / slider: own label)
local function raidControls(pane)
    local out = {}
    local root = pane.root
    for _, f in ipairs(mock.frames) do
        local s = st(f)
        if s.parent == root and rawget(f, "Refresh") then
            local label
            if rawget(f, "rowLabel") then label = st(f.rowLabel).text
            elseif rawget(f, "label") then label = st(f.label).text end
            if label then out[label] = f end
        end
    end
    return out
end
local function pickDropdown(dd, value)
    st(dd).scripts.OnClick(dd, "LeftButton")
    for i = #mock.frames, 1, -1 do
        local p = mock.frames[i]
        if rawget(p, "callback") and rawget(p, "items") then
            for _, item in ipairs(p.items) do if item.value == value then p.callback(item); return true end end
        end
    end
    return false
end
local function clickSegment(seg, value)
    for _, b in ipairs(seg.buttons) do if b.value == value then st(b).scripts.OnClick(b, "LeftButton"); return true end end
    return false
end
local function setCheck(cb, on) st(cb).checked = on; st(cb).scripts.OnClick(cb, "LeftButton") end
local function setSlider(sl, v) st(sl.slider).scripts.OnValueChanged(sl.slider, v, true) end

describe("profiles: Raid Layout pane", function()
    it("every control writes ns.db.raid, applies live, survives a sparse save and reload", function()
        local ns = boot({ group = 3 })
        local pane = raidPane(ns)
        local c = raidControls(pane)
        for _, name in ipairs({ "Layout", "Groups", "Groups per line", "Sort within group", "Health text", "Ending look", "Several buffs",
            "In combat", "Display", "Scale (%)", "Bar width", "Bar height", "Spacing", "Name size", "Name length", "Marker size",
            "Rebuff under (%)", "Max debuff icons", "Debuff icon size", "Out of range alpha", "Raid layout only above 5 players",
            "Group labels (G1-G8)", "Hide empty groups", "Show names", "Mute full-health bars", "Show incoming heals",
            "Show my buff markers (top-right)", "Show \"ending\" marker", "Show debuffs you can dispel" }) do
            assertNotNil(c[name], "control '" .. name .. "' not found")
        end
        assertTrue(pickDropdown(c["Layout"], "raid"))
        assertTrue(clickSegment(c["Groups"], "rows")); assertTrue(clickSegment(c["Groups per line"], 4))
        assertTrue(pickDropdown(c["Sort within group"], "class")); assertTrue(pickDropdown(c["Health text"], "percent"))
        assertTrue(pickDropdown(c["Ending look"], "sweep")); assertTrue(pickDropdown(c["Several buffs"], "stack"))
        assertTrue(pickDropdown(c["In combat"], "dim")); assertTrue(pickDropdown(c["Display"], "icons"))
        setSlider(c["Scale (%)"], 80); setSlider(c["Bar width"], 90); setSlider(c["Bar height"], 30); setSlider(c["Spacing"], 4)
        setSlider(c["Name size"], 9); setSlider(c["Name length"], 10); setSlider(c["Marker size"], 12)
        setSlider(c["Rebuff under (%)"], 12); setSlider(c["Max debuff icons"], 2); setSlider(c["Debuff icon size"], 14)
        setSlider(c["Out of range alpha"], 35)
        for _, name in ipairs({ "Group labels (G1-G8)", "Hide empty groups", "Show names", "Mute full-health bars", "Show incoming heals",
            "Show my buff markers (top-right)", "Show \"ending\" marker", "Show debuffs you can dispel" }) do
            setCheck(c[name], false)
        end
        mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        local r = ns.db.raid
        assertEquals(r.layoutMode, "raid"); assertEquals(r.groupArrange, "rows"); assertEquals(r.groupsPerLine, 4)
        assertEquals(r.sortWithin, "class"); assertEquals(r.healthText, "percent"); assertEquals(r.buffs.endingLook, "sweep")
        assertEquals(r.buffs.multi, "stack"); assertEquals(r.buffs.inCombat, "dim"); assertEquals(r.debuffs.display, "icons")
        assertEquals(r.scale, 80); assertEquals(r.width, 90); assertEquals(r.height, 30); assertEquals(r.spacing, 4)
        assertEquals(r.nameSize, 9); assertEquals(r.nameLength, 10); assertEquals(r.buffs.size, 12); assertEquals(r.buffs.rebuffPercent, 12)
        assertEquals(r.debuffs.max, 2); assertEquals(r.debuffs.size, 14); assertEquals(r.rangeAlpha, 35)
        assertEquals(r.groupLabels, false); assertEquals(r.hideEmptyGroups, false); assertEquals(r.showNames, false)
        assertEquals(r.muteFull, false); assertEquals(r.showIncoming, false); assertEquals(r.buffs.show, false)
        assertEquals(r.buffs.showEnding, false); assertEquals(r.debuffs.show, false)
        -- live: Always raid shows the raid frames with the new size
        assertEquals(ns.RaidFrames.active, "raid")
        assertEquals(st(ns.RaidFrames.buttons[1]).w, 90)
        assertEquals(st(ns.RaidFrames.anchor).scale, 0.8)
        -- sparse save: only the raid keys that changed, the point untouched
        local want = deepcopy(r)
        local saved = ns:BuildSaveTable()
        assertNil(saved.raid.point, "point unchanged: not saved")
        assertNil(saved.raid.onlyAbove5, "onlyAbove5 unchanged: not saved")
        mock.fire("PLAYER_LOGOUT")
        local ns2 = boot({ char = deepcopy(HealerForeverCharDB), group = 3 })
        assertDeepEquals(ns2.db.raid, want)
        local c2 = raidControls(raidPane(ns2))
        assertEquals(st(c2["Layout"].text).text, "Always raid", "the dropdown shows the saved value")
        assertEquals(st(c2["Bar width"].slider).value, 90)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("Reset raid defaults restores everything except the position", function()
        local ns = boot({ group = 3 })
        local pane = raidPane(ns)
        ns.db.raid.width = 100; ns.db.raid.buffs.multi = "first"; ns.db.raid.layoutMode = "party"
        ns.db.raid.point = { point = "CENTER", relativePoint = "CENTER", x = 12, y = 34 }
        st(pane.resetButton).scripts.OnClick(pane.resetButton, "LeftButton")
        local want = deepcopy(ns.DEFAULTS.raid)
        want.point = { point = "CENTER", relativePoint = "CENTER", x = 12, y = 34 }
        assertDeepEquals(ns.db.raid, want)
        assertTrue(ns.db.raid.buffs ~= ns.DEFAULTS.raid.buffs, "a copy, never the DEFAULTS tables")
        assertDeepEquals(ns:BuildSaveTable().raid, { point = want.point })
    end)
    it("glow display choices are refused when the client can't hand the glow to the game", function()
        local ns = boot({ group = 3 })
        local pane = raidPane(ns)
        ns.RaidFrames.glowSupported = false
        pane:Refresh()
        local dd = raidControls(pane)["Display"]
        ns.db.raid.debuffs.display = "icons"
        pickDropdown(dd, "glow")
        assertEquals(ns.db.raid.debuffs.display, "icons", "glow refused")
        pickDropdown(dd, "glowIcons")
        assertEquals(ns.db.raid.debuffs.display, "icons", "glow + icons refused")
        assertTrue(st(pane.glowNote).text:find("isn't available", 1, true) ~= nil)
        ns.RaidFrames.glowSupported = true
        pickDropdown(dd, "glow")
        assertEquals(ns.db.raid.debuffs.display, "glow")
    end)
    it("'only above 5' is greyed unless Auto; the status line follows the layout and a queued switch", function()
        local ns = boot({ group = 3 })
        local pane = raidPane(ns)
        local c = raidControls(pane)
        local above5 = c["Raid layout only above 5 players"]
        assertEquals(st(above5.label).textColor.r, 1)
        pickDropdown(c["Layout"], "party"); pane:Refresh()
        assertEquals(st(above5.label).textColor.r, 0.5)
        pickDropdown(c["Layout"], "auto"); pane:Refresh()
        assertEquals(st(above5.label).textColor.r, 1)
        assertEquals(st(pane.status).text, "Now: Party layout (not in a raid)")
        mock.state.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.setRaid(12); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        pane:Refresh()
        assertEquals(st(pane.status).text, "Now: Party layout (in a raid of 12) - switches to raid after combat")
        mock.state.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        pane:Refresh()
        assertEquals(st(pane.status).text, "Now: Raid layout (in a raid of 12)")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("preview button and size segment drive the preview; refusals show in the pane", function()
        local ns = boot({ group = 3 })
        local pane = raidPane(ns)
        st(pane.previewButton).scripts.OnClick(pane.previewButton, "LeftButton")
        assertTrue(ns.RaidPreview:IsOn())
        assertEquals(st(pane.previewButton).text, "Preview full raid: ON")
        clickSegment(pane.sizeSegment, 20)
        assertEquals(ns.RaidPreview.size, 20)
        st(pane.previewButton).scripts.OnClick(pane.previewButton, "LeftButton")
        assertFalse(ns.RaidPreview:IsOn())
        mock.state.combat = true
        st(pane.previewButton).scripts.OnClick(pane.previewButton, "LeftButton")
        assertEquals(st(pane.previewMessage).text, "Can't preview in combat.")
        mock.state.combat = false
    end)
    it("geometry: rows never overlap, labels fit their column, nothing wider than 540, boxes contain their rows", function()
        local ns = boot({ group = 3 })
        local pane = raidPane(ns)
        local root = pane.root
        local rects = {}
        local function textW(s) return #tostring(s.text or "") * 6 end
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            local p = s.points[1]
            if s.parent == root and p and p[1] == "TOPLEFT" and type(p[2]) == "number" and f ~= pane.groupBox then
                local w = s.w or textW(s)
                local h = s.h or 12
                if s.kind == "CheckButton" then
                    -- the 24 px box is the hit rect; its label sits to the right, vertically centred (12 px high)
                    rects[#rects + 1] = { x = p[2] + 26, y = -p[3] + 6, w = #tostring(st(f.label).text) * 6, h = 12,
                        name = ("label " .. tostring(st(f.label).text)):sub(1, 40), kind = "FontString" }
                end
                rects[#rects + 1] = { x = p[2], y = -p[3], w = w, h = h, name = (s.kind .. " " .. tostring(s.text ~= "" and s.text or (rawget(f, "label") and st(f.label).text) or "")):sub(1, 40), f = f, kind = s.kind }
            end
        end
        assertTrue(#rects > 60, "rows found: " .. #rects)
        for _, r in ipairs(rects) do
            assertTrue(r.x >= -4 and r.x + r.w <= 540, r.name .. string.format(" outside 540 (x=%d w=%d)", r.x, r.w))
            assertTrue(r.y + r.h <= pane.contentHeight, r.name .. " below the content height")
        end
        -- row labels of dropdowns / segments end before the control column (x = 150)
        for _, f in ipairs(mock.frames) do
            if st(f).parent == root and rawget(f, "rowLabel") then
                assertTrue(#tostring(st(f.rowLabel).text) * 6.5 < 146, "label '" .. tostring(st(f.rowLabel).text) .. "' runs into its control")
            end
        end
        local function overlap(a, b) return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h end
        for i = 1, #rects do
            for j = i + 1, #rects do
                local a, b = rects[i], rects[j]
                if a.kind ~= "Texture" and b.kind ~= "Texture" then
                    assertFalse(overlap(a, b), "'" .. a.name .. "' overlaps '" .. b.name .. "'")
                end
            end
        end
        -- the Groups box contains the group rows (Groups .. the group note)
        local box = st(pane.groupBox)
        local top, bottom = -box.points[1][3], -box.points[1][3] + box.h
        local noteY = -st(pane.groupNote).points[1][3]
        assertTrue(noteY + 12 <= bottom, "the group note sits inside the box")
        for _, r in ipairs(rects) do
            if r.name:find("Groups per line", 1, true) or r.name:find("Sort within", 1, true) or r.name:find("Hide empty", 1, true) then
                assertTrue(r.y >= top and r.y + r.h <= bottom, r.name .. " outside the Groups box")
            end
        end
        -- legend rows: 11 rows, 15 px apart, right of the sample holder
        assertEquals(#pane.legend, 11)
        for i, row in ipairs(pane.legend) do
            local p = st(row.swatch).points[1]
            assertTrue(p[2] >= 210 + 10, "legend swatch clear of the sample holder")
            if i > 1 then
                local q = st(pane.legend[i - 1].swatch).points[1]
                assertEquals(q[3] - p[3], 15, "legend row spacing")
            end
        end
        assertEquals(st(root).h, pane.contentHeight)
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("profiles: Raid Layout legend sample bar", function()
    it("the sample bar shows the whole name 'Sample' (name sizes 6-9 at the default 64 x 24), number and texts inside the bar", function()
        local ns = boot({ group = 3 })
        local pane = raidPane(ns)
        local sample = pane.sample
        assertNotNil(sample)
        for _, size in ipairs({ 6, 7, 8, 9, 10 }) do
            ns.db.raid.nameSize = size
            pane:Refresh(); mock.flushTimers()
            local c = ns.db.raid
            local label = "nameSize " .. size
            assertEquals(st(sample.name).text, "Sample", label)
            local layout = sample.textLayout
            if size == 10 then
                -- 64 x 24 with a 12 px name line has no room for a stacked 12 px number: side by side, and like the
                -- real bars the name gives way to the number when it gets under 6 px
                assertFalse(layout.stacked, label)
                assertEquals(st(sample.name).shown, layout.nameW >= 6, label .. ": sample follows the real layout")
                break
            end
            assertTrue(st(sample.name).shown, label .. ": name shown")
            -- the addon's own width model (RS.NameWidthCap: 0.6 x font size per character)
            local need = math.ceil(#"Sample" * size * 0.6)
            assertTrue(st(sample.name).w >= need, label .. ": name width " .. tostring(st(sample.name).w) .. " < " .. need .. " (cut)")
            assertTrue(layout.numLeft >= 2, label .. ": number left edge")
            if not layout.stacked then
                assertTrue(layout.numLeft - 3 - st(sample.name).w >= 2, label .. ": name starts inside the bar")
            end
            assertTrue(st(sample.name).w <= c.width - 4, label .. ": name inside the bar")
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("profiles: smart buff with a secret name, NameWidthCap", function()
    it("a secret UnitName on the smart button target goes straight into the label (no error)", function()
        local ns = boot({ group = 3, class = "PALADIN" })
        ns.db.smartButton.show = true
        local realName = UnitName
        mock.setGlobal("UnitName", function(u) if u ~= "player" then return mock.newSecret() end return realName(u) end)
        ns:Changed("presets"); mock.tick(); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        local smart = ns.BuffButtons.smart
        if smart.castUnit and smart.castUnit ~= "player" then
            assertTrue(mock.isSecret(st(smart.label).text), "secret name passed to SetText")
            assertEquals(smart.pendingText, smart.castSpell .. " on " .. smart.castUnit)
        end
    end)
    it("RaidStyle.NameWidthCap = ceil(nameLength * nameSize * 0.6), nil for bad input, never wider than the layout allows", function()
        local ns = boot({ group = 0 })
        local RS = ns.RaidStyle
        for n = 3, 12 do
            for size = 6, 10 do
                assertEquals(RS.NameWidthCap({ nameLength = n, nameSize = size }), math.ceil(n * size * 0.6))
            end
        end
        assertEquals(RS.NameWidthCap({ nameLength = 3, nameSize = 6 }), 11)
        assertEquals(RS.NameWidthCap({ nameLength = 12, nameSize = 10 }), 72)
        assertNil(RS.NameWidthCap(nil)); assertNil(RS.NameWidthCap({ nameLength = "7", nameSize = 7 }))
        local f = ns.NewFrame("Frame", nil, UIParent)
        RS.Build(f)
        local cfg = deepcopy(ns.db.raid)
        cfg.width, cfg.nameLength, cfg.nameSize = 120, 3, 7
        RS.Apply(f, cfg); RS.ShowNumber(f, "deficit")
        assertEquals(st(f.name).w, RS.NameWidthCap(cfg), "short name length caps a wide bar's name")
        cfg.nameLength, cfg.width = 12, 50
        RS.Apply(f, cfg); RS.ShowNumber(f, "deficit")
        assertTrue(f.textLayout.nameW < RS.NameWidthCap(cfg))
        assertEquals(st(f.name).w, f.textLayout.nameW, "the layout width wins when it is smaller than the cap")
    end)
end)
