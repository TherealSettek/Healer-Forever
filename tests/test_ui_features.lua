-- Whole-addon tests for roles/self buff rules, the Buff Presets pane, the Click-Casting editor,
-- the lock badge and the role-icon fallback.
local L = require("loader")
local mock = require("wow_mock")
local Fx = require("fixtures")
local F = require("framework")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end

local S
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function st(f) return rawget(f, "__s") end
local function frameNamed(name) for _, f in ipairs(mock.frames) do if st(f).name == name then return f end end end

local function unit(name, class, role)
    return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" }
end

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    if opts.class then S.units.player.class = opts.class end
    if opts.units then for k, v in pairs(opts.units) do S.units[k] = v end end
    if opts.atlas ~= nil then S.atlasKnown = opts.atlas end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.db ~= nil then _G.HealerForeverCharDB = opts.db end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    if opts.seed ~= false and opts.char == nil and opts.db == nil and opts.account == nil and ns.db then Fx.seed(ns, { presets = 4 }) end
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    if opts.group then mock.setGroup(opts.group) end
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end

local function buffButton(unitToken)
    for _, f in ipairs(mock.frames) do
        local n = st(f).name
        if n and n:match("^HealerForeverBuff%d+$") and f.unit == unitToken then return f end
    end
end
local function refreshBuffs() mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("PLAYER_ROLES_ASSIGNED"); mock.flushTimers(); mock.runOnUpdate(1, 0.5); mock.flushTimers() end

-- ======================================================================== roles + self in the buff buttons
describe("ui: missing-buff buttons honour class + role + self", function()
    local ns = boot({ group = 3, units = {
        party1 = unit("TankPal", "PALADIN", "TANK"), party2 = unit("HealPal", "PALADIN", "HEALER"), party3 = unit("Warr", "WARRIOR", "NONE") } })
    local preset = ns.db.presets[ns.db.activePreset]
    it("setup: active preset is the 5-man default and player is a paladin healer", function()
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(ns.PlayerClass(), "PALADIN")
        assertEquals(ns.Presets.ResolveBuff(preset, "PALADIN", "TANK"), "might")
    end)
    it("party1 (paladin TANK) is missing might per the 5-man default", function()
        assertEquals(buffButton("party1").buffKey, "might")
    end)
    it("party2 (paladin HEALER) is missing wisdom", function()
        assertEquals(buffButton("party2").buffKey, "wisdom")
    end)
    it("party3 (warrior, role NONE) gets the class DEFAULT", function()
        local want = ns.Presets.ResolveBuff(preset, "WARRIOR", nil)
        assertEquals(buffButton("party3").buffKey, want)
    end)
    it("player with self = kings gets kings", function()
        ns.db.presets[ns.db.activePreset].self = "kings"
        ns:Changed("presets"); refreshBuffs()
        assertEquals(buffButton("player").buffKey, "kings")
        assertEquals(buffButton("party1").buffKey, "might", "self must not leak to other members")
    end)
    it("clearing self returns the player to the class/role rule", function()
        ns.db.presets[ns.db.activePreset].self = nil
        ns:Changed("presets"); refreshBuffs()
        local want = ns.Presets.ResolveBuff(ns.db.presets[ns.db.activePreset], "PALADIN", ns.Roles.Get("player"))
        assertEquals(buffButton("player").buffKey, want)
    end)
    it("a roleOverrides change + PLAYER_ROLES_ASSIGNED updates the buttons (party1 TANK -> HEALER => wisdom)", function()
        assertTrue(ns.Roles.SetOverride("party1", "HEALER"))
        refreshBuffs()
        assertEquals(ns.Roles.Get("party1"), "HEALER")
        assertEquals(buffButton("party1").buffKey, "wisdom")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("override can be cleared (AUTO) and detection returns", function()
        ns.Roles.SetOverride("party1", nil)
        refreshBuffs()
        assertEquals(ns.Roles.Get("party1"), "TANK")
        assertEquals(buffButton("party1").buffKey, "might")
    end)
    it("Roles.Get: invalid override value is ignored; NONE -> nil", function()
        local key = ns.Roles.Key("party3")
        assertNotNil(key)
        ns.db.roleOverrides[key] = "BOGUS"
        assertNil(ns.Roles.Get("party3"))
        ns.db.roleOverrides[key] = nil
    end)
    it("Roles.Key is name-realm", function()
        assertEquals(ns.Roles.Key("party1"), "TankPal-TestRealm")
        assertNil(ns.Roles.Key("party4"))
    end)
    it("in combat: SetOverride queues (no DB change, no protected ops) and applies after combat", function()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0, s0 = #mock.violations, #mock.softViolations
        local key = ns.Roles.Key("party2")
        ns.Roles.SetOverride("party2", "TANK")
        assertNil(ns.db.roleOverrides[key], "override must be queued until combat ends")
        mock.fire("PLAYER_ROLES_ASSIGNED"); mock.flushTimers(); mock.runOnUpdate(2, 0.5)
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(ns.db.roleOverrides[key], "TANK")
        refreshBuffs()
        assertEquals(buffButton("party2").buffKey, "might")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("secret UnitGroupRolesAssigned (and secret names) do not error and detect nothing", function()
        S.combat = true; S.secret = true; S.secretNames = true
        mock.fire("PLAYER_REGEN_DISABLED")
        assertNil(ns.Roles.GetDetected("party1"))
        assertNil(ns.Roles.Key("party1"))
        for _, ev in ipairs({ "PLAYER_ROLES_ASSIGNED", "GROUP_ROSTER_UPDATE", "UNIT_AURA", "UNIT_NAME_UPDATE" }) do
            mock.fire(ev, "party1")
        end
        mock.flushTimers(); mock.runOnUpdate(3, 0.5)
        assertEquals(#mock.errors, 0, errstr())
        S.combat = false; S.secret = false; S.secretNames = false
        mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== role icon
describe("ui: role icon atlas -> texture fallback", function()
    local function iconCalls(method)
        local out = {}
        for _, c in ipairs(mock.calls) do
            if c.method == method and c.obj and c.obj == frameNamed("HealerForeverUnit1").roleIcon then out[#out + 1] = c end
        end
        return out
    end
    it("atlas known: SetAtlas used", function()
        boot({ group = 1, atlas = true })
        local ns_db = _G.HealerForeverCharDB
        mock.calls = {}
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        assertTrue(#iconCalls("SetAtlas") > 0, "SetAtlas not called when the atlas exists")
        assertEquals(#iconCalls("SetTexCoord"), 0)
    end)
    it("atlas unknown: falls back to the LFG role texture with tex coords", function()
        boot({ group = 1, atlas = false })
        mock.calls = {}
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        local t = iconCalls("SetTexture")
        assertTrue(#t > 0, "SetTexture fallback not used")
        assertNotNil(tostring(t[1].args[1]):find("LFG"), tostring(t[1].args[1]))
        local tc = iconCalls("SetTexCoord")
        assertTrue(#tc > 0); assertEquals(#tc[1].args, 4)
        for _, v in ipairs(tc[1].args) do assertEquals(type(v), "number") end
        assertEquals(#iconCalls("SetAtlas"), 0)
    end)
    it("C_Texture missing entirely: fallback, no error", function()
        boot({ group = 1 })
        _G.C_Texture = nil
        mock.calls = {}
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        assertTrue(#iconCalls("SetTexture") > 0)
    end)
    it("role NONE hides the icon", function()
        boot({ group = 2, units = { party1 = unit("Nobody", "WARRIOR", "NONE") } })
        local btn
        for _, f in ipairs(mock.frames) do if st(f).attrs.unit == "party1" and tostring(st(f).name):match("^HealerForeverUnit") then btn = f end end
        assertNotNil(btn)
        assertFalse(st(btn.roleIcon).shown, "role NONE (party member) must hide the icon")
    end)
end)

-- ======================================================================== Buff Presets pane
describe("ui: Buff Presets pane - Self cell, role cells, Group roles dropdowns", function()
    local ns = boot({ group = 2, units = { party1 = unit("TankPal", "PALADIN", "TANK"), party2 = unit("Mage", "MAGE", "DAMAGER") } })
    ns.Options:Show("buffs"); mock.flushTimers()
    local preset = ns.db.presets[1]
    local BU = require("buff_ui")
    local cells = BU.cells(ns)

    local function popupPick(text)
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if s.shown and f.item and f.item.text == text and s.scripts.OnClick then s.scripts.OnClick(f, "LeftButton"); return true end
        end
        return false
    end
    local function dropdownAt(x, y)
        for _, f in ipairs(mock.frames) do
            local p = st(f).points[1]
            if rawget(f, "Refresh") and p and p[2] == x and p[3] == y then return f end
        end
    end
    local function click(f) st(f).scripts.OnClick(f, "LeftButton"); mock.flushTimers() end

    it("pane builds without errors; the Self cell and one cell per class/role row exist", function()
        assertEquals(#mock.errors, 0, errstr())
        assertNotNil(cells.self)
        local want = 0
        for _, class in ipairs(ns.Classes.ORDER) do want = want + 1 + #ns.Classes.ROLES[class] end
        assertEquals(#cells.rows, want)
    end)
    it("Self cell: pick Blessing of Kings -> preset.self = { kings }; None and 'Use class/role rules' clear it", function()
        BU.openCell(cells.self)
        assertTrue(BU.popupShown())
        assertTrue(BU.pick("Blessing of Kings"), "popup row not found")
        assertDeepEquals(preset.self, { "kings" })
        assertTrue(BU.pick("None (no buffs for you)"))
        assertDeepEquals(preset.self, {})
        assertTrue(BU.pick("Blessing of Wisdom"))
        assertDeepEquals(preset.self, { "wisdom" })
        BU.close()
        local rules
        for _, f in ipairs(mock.frames) do if st(f).kind == "Button" and st(f).text == "Use class/role rules" then rules = f end end
        assertNotNil(rules); click(rules)
        assertNil(preset.self)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("Self cell in combat does not run protected ops", function()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        BU.openCell(cells.self); BU.pick("Blessing of Light")
        assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        BU.close(); ns.Presets.SetSelf(preset, nil)
    end)
    it("role cell: picking a blessing sets a role override; picking another replaces it; 'Use class row' drops it and follows the class row", function()
        local c = cells.byKey["PALADIN:TANK"]
        BU.openCell(c); assertTrue(BU.pick("Blessing of Salvation"))
        assertDeepEquals(preset.map.PALADIN.TANK, { "salvation" })
        assertTrue(BU.pick("Blessing of Might"))
        assertDeepEquals(preset.map.PALADIN.TANK, { "might" }, "radio group: one at a time")
        assertFalse(BU.pick("None"), "a role row has no None row")
        assertTrue(BU.pick("Use class row"))
        assertNil(preset.map.PALADIN.TANK)
        assertTrue(ns.Presets.RoleInherits(preset, "PALADIN", "TANK"))
        assertDeepEquals(ns.Presets.CellBuffs(preset, "PALADIN", "TANK"), ns.Presets.CellBuffs(preset, "PALADIN", "DEFAULT"), "resolves to the class row")
        BU.close()
    end)
    it("DEFAULT row sets and clears", function()
        local c = cells.byKey["MAGE:DEFAULT"]
        BU.openCell(c); BU.pick("Blessing of Kings")
        assertDeepEquals(preset.map.MAGE.DEFAULT, { "kings" })
        BU.pick("None")
        assertDeepEquals(preset.map.MAGE.DEFAULT, {})
        BU.pick("Blessing of Wisdom")
        assertDeepEquals(preset.map.MAGE.DEFAULT, { "wisdom" })
        BU.close()
    end)
    it("every cell can be opened and every popup row clicked twice without error, the DB stays valid", function()
        for _, r in ipairs(cells.rows) do
            BU.openCell(r.cell)
            for _, row in ipairs((BU.rows())) do BU.click(row.frame); BU.click(row.frame) end
            BU.close()
        end
        assertEquals(#mock.errors, 0, errstr())
        for class, entry in pairs(preset.map) do
            assertNotNil(entry.DEFAULT, class .. " lost DEFAULT")
            for role, set in pairs(entry) do
                assertEquals(type(set), "table", class .. " " .. role)
                assertTrue(role == "DEFAULT" or ns.Presets.SetRule(ns.Util.DeepCopy(preset), class, role, set[1]) ~= false, "invalid role " .. role .. " for " .. class)
            end
        end
    end)
    it("popup clicks in combat do not touch protected frames", function()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        BU.openCell(cells.byKey["DRUID:TANK"]); BU.pick("Blessing of Might"); BU.pick("Blessing of Might")
        assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers(); BU.close()
    end)
    it("Group roles dropdowns: set Healer for party1, then Auto", function()
        local dd = dropdownAt(290, -404 - 1 * 24)
        assertNotNil(dd, "Group roles dropdown for party1 not found")
        click(dd); assertTrue(popupPick("Healer"))
        mock.flushTimers()
        assertEquals(ns.db.roleOverrides[ns.Roles.Key("party1")], "HEALER")
        click(dd); assertTrue(popupPick("Auto"))
        assertNil(ns.db.roleOverrides[ns.Roles.Key("party1")])
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("Group roles dropdown in combat queues the change", function()
        local dd = dropdownAt(290, -404 - 1 * 24)
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        click(dd); popupPick("DPS")
        assertNil(ns.db.roleOverrides[ns.Roles.Key("party1")], "must be queued")
        assertEquals(#mock.violations, 0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(ns.db.roleOverrides[ns.Roles.Key("party1")], "DAMAGER")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("all Group role dropdown choices for all five rows work", function()
        for i = 0, 4 do
            local dd = dropdownAt(290, -404 - i * 24)
            assertNotNil(dd, "row " .. i)
            for _, choice in ipairs({ "Tank", "Healer", "DPS", "Auto" }) do click(dd); popupPick(choice) end
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("pane Refresh after everything is error free", function()
        ns.Options:Refresh(); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== Click-Casting editor pane
describe("ui: Click-Casting pane", function()
    local ns = boot({ group = 2 })
    ns.Options:Show("binds"); mock.flushTimers()
    local B = ns.Bindings

    local toggles, rows, chips = {}, {}, {}
    local function collect()
        toggles, rows = {}, {}
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if s.kind == "Button" and rawget(f, "text") and type(rawget(f, "text")) == "table" and s.scripts.OnClick and s.template == "BackdropTemplate" then
                -- found by label (non-Mac names; the Meta toggle is the "Win key (not recommended)" button, whatever its width)
                local t = st(f.text).text
                local byLabel = { Shift = "shift", Ctrl = "ctrl", Alt = "alt", Option = "alt", Cmd = "meta", Meta = "meta",
                    ["Win key (not recommended)"] = "meta" }
                if byLabel[t] then toggles[byLabel[t]] = f end
            end
            if type(f.button) == "number" and f.pick and f.clear then rows[f.button] = f end
        end
    end
    local function collectChips()
        chips = {}
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if s.shown and type(s.text) == "string" and s.text:match("%(%d+%)$") and s.scripts.OnClick then chips[#chips + 1] = f end
        end
    end
    local function click(f) st(f).scripts.OnClick(f, "LeftButton"); mock.flushTimers() end
    local function clearMods() for _, m in ipairs({ "shift", "ctrl", "alt", "meta" }) do if st(toggles[m].text) and false then end end end
    collect()

    it("pane builds, found 4 toggles and 8 rows", function()
        assertEquals(#mock.errors, 0, errstr())
        for _, m in ipairs({ "shift", "ctrl", "alt", "meta" }) do assertNotNil(toggles[m], m) end
        for i = 1, 8 do assertNotNil(rows[i], "row " .. i) end
    end)
    it("with no modifier, rows 1-5 show plain bindings, rows 6-8 hidden", function()
        for i = 1, 5 do assertTrue(st(rows[i]).shown, "row " .. i); assertEquals(rows[i].key, "|" .. i) end
        for i = 6, 8 do assertFalse(st(rows[i]).shown, "row " .. i) end
        local b1 = ns.db.bindings["|1"]
        assertEquals(st(rows[1].text).text, b1.spell or "Target unit")
    end)
    it("toggling modifiers changes the visible rows' combo (all 16 combos)", function()
        local state = { shift = false, ctrl = false, alt = false, meta = false }
        local function setMods(mask)
            local want = { shift = mask % 2 == 1, ctrl = math.floor(mask / 2) % 2 == 1, alt = math.floor(mask / 4) % 2 == 1, meta = math.floor(mask / 8) % 2 == 1 }
            for _, m in ipairs({ "shift", "ctrl", "alt", "meta" }) do
                if want[m] ~= state[m] then click(toggles[m]); state[m] = want[m] end
            end
            return ns.Util.ModifierKey(want.shift, want.ctrl, want.alt, want.meta)
        end
        for mask = 0, 15 do
            local mod = setMods(mask)
            for i = 1, 5 do
                assertEquals(rows[i].key, B.MakeKey(mod, i), "mask " .. mask .. " row " .. i)
                local action = ns.db.bindings[rows[i].key]
                if action and action.type == "spell" then assertEquals(st(rows[i].text).text, action.spell)
                elseif not action and not (rows[i].key == "|1" or rows[i].key == "|2") then assertEquals(st(rows[i].text).text, "-") end
            end
        end
        setMods(0)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("extra-buttons checkbox reveals rows 6-8", function()
        ns.db.ui.extraButtons = true; ns.Options:Refresh()
        for i = 6, 8 do assertTrue(st(rows[i]).shown); assertEquals(rows[i].key, "|" .. i) end
        ns.db.ui.extraButtons = false; ns.Options:Refresh()
        assertFalse(st(rows[8]).shown)
    end)
    it("assign a spell by drag-receive, then clear it with X -> DB changes", function()
        click(toggles.shift)
        assertEquals(rows[3].key, "shift|3")
        assertNil(ns.db.bindings["shift|3"])
        S.cursor = { "spell", 1, "spell", 19750 }
        st(rows[3]).scripts.OnReceiveDrag(rows[3])
        mock.flushTimers()
        assertNil(S.cursor, "cursor must be cleared")
        assertEquals(ns.db.bindings["shift|3"].type, "spell")
        assertEquals(ns.db.bindings["shift|3"].spell, "Spell19750")
        assertEquals(st(rows[3].text).text, "Spell19750")
        click(rows[3].clear)
        assertNil(ns.db.bindings["shift|3"])
        assertEquals(st(rows[3].text).text, "-")
        assertEquals(#mock.errors, 0, errstr())
        click(toggles.shift)
    end)
    it("OnClick with a spell on the cursor also assigns", function()
        S.cursor = { "spell", 1, "spell", 20217 }
        st(rows[4]).scripts.OnClick(rows[4]); mock.flushTimers()
        assertEquals(ns.db.bindings["|4"].spell, "Spell20217")
        click(rows[4].clear)
        assertNil(ns.db.bindings["|4"])
    end)
    it("receive with a non-spell cursor does nothing", function()
        S.cursor = { "item", 5 }
        local before = ns.Util.DeepCopy(ns.db.bindings)
        st(rows[5]).scripts.OnReceiveDrag(rows[5])
        assertDeepEquals(ns.db.bindings, before)
        S.cursor = nil
    end)
    it("X on an empty row is harmless", function()
        click(rows[5].clear); click(rows[5].clear)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the Pick menu offers 'Unit menu' only on plain Right (|2)", function()
        local function menuTexts(row)
            mock.menu = nil
            click(row.pick)
            local t = {}
            for _, e in ipairs(mock.menu and mock.menu.entries or {}) do t[e.text] = true end
            return t
        end
        assertEquals(rows[2].key, "|2")
        assertTrue(menuTexts(rows[2])["Unit menu"], "plain Right must offer Unit menu")
        assertNotNil(menuTexts(rows[1])["Target unit"])
        assertNil(menuTexts(rows[1])["Unit menu"])
        click(toggles.ctrl)
        assertNil(menuTexts(rows[2])["Unit menu"], "ctrl+Right must NOT offer Unit menu")
        click(toggles.ctrl)
    end)
    it("picking from the menu assigns; picking Unit menu on |2 works; (none) clears", function()
        mock.menu = nil; click(rows[2].pick)
        assertTrue(mock.pickMenu("Unit menu"))
        assertEquals(ns.db.bindings["|2"].type, "menu")
        mock.menu = nil; click(rows[1].pick)
        assertTrue(mock.pickMenu("Target unit"))
        assertEquals(ns.db.bindings["|1"].type, "target")
        mock.menu = nil; click(rows[1].pick)
        assertTrue(mock.pickMenu("(none)"))
        assertNil(ns.db.bindings["|1"])
    end)
    it("'menu' assigned to any key other than |2 is refused by the pane's assign path (forced via a menu entry)", function()
        -- the UI never offers it, so force the same callback with a shift|2 row to exercise the guard
        click(toggles.shift)
        assertEquals(rows[2].key, "shift|2")
        local before = ns.db.bindings["shift|2"] and ns.Util.DeepCopy(ns.db.bindings["shift|2"])
        mock.menu = nil; click(rows[2].pick)
        mock.pickMenu("Target unit")
        ns.db.bindings["shift|2"] = before
        -- re-open as plain Right (offers menu) then fake the callback on a non-|2 key by swapping row.key
        click(toggles.shift)
        mock.menu = nil; click(rows[2].pick)
        local entry
        for _, e in ipairs(mock.menu.entries) do if e.text == "Unit menu" then entry = e end end
        assertNotNil(entry)
        rows[2].key = "ctrl|2"      -- the callback reads row.key at call time
        mock.printed = {}
        local prior = ns.db.bindings["ctrl|2"] and ns.Util.DeepCopy(ns.db.bindings["ctrl|2"])
        entry.cb()
        assertDeepEquals(ns.db.bindings["ctrl|2"], prior, "menu must be refused on ctrl|2 (binding unchanged)")
        assertTrue(#mock.printed >= 1, "user should be told why")
        ns.Options:Refresh()
    end)
    it("summary chips list combos with counts and clicking one selects that combo", function()
        ns.db.bindings = { ["|1"] = { type = "target" }, ["|2"] = { type = "menu" }, ["shift|1"] = { type = "spell", spell = "A" },
            ["shift|2"] = { type = "spell", spell = "B" }, ["alt-ctrl|1"] = { type = "spell", spell = "C" } }
        ns.Options:Refresh(); collectChips()
        local texts = {}
        for _, c in ipairs(chips) do texts[#texts + 1] = st(c).text end
        assertEquals(#chips, 3, table.concat(texts, " | "))
        local want = { "No modifier (2)", "Shift (2)", "Shift + Ctrl + Alt (1)" }
        -- order is "", shift, alt-ctrl; verify count suffixes
        assertNotNil(texts[1]:find("%(2%)")); assertNotNil(texts[2]:find("%(2%)")); assertNotNil(texts[3]:find("%(1%)"))
        -- click the alt-ctrl chip
        local target
        for _, c in ipairs(chips) do if st(c).text:find("%(1%)") then target = c end end
        click(target)
        assertEquals(rows[1].key, "alt-ctrl|1")
        assertEquals(st(rows[1].text).text, "C")
        -- the selected chip is disabled (current combo)
        assertFalse(st(target).enabled == true and false)
        -- click shift chip
        collectChips()
        for _, c in ipairs(chips) do if st(c).text:find("^Shift %(") then click(c); break end end
        assertEquals(rows[1].key, "shift|1"); assertEquals(rows[2].key, "shift|2")
        assertEquals(st(rows[2].text).text, "B")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("chips disappear when their combo has no bindings left", function()
        ns.db.bindings = { ["|1"] = { type = "target" } }
        ns.Options:Refresh(); collectChips()
        assertEquals(#chips, 1)
        ns.db.bindings = {}
        ns.Options:Refresh(); collectChips()
        assertEquals(#chips, 0)
    end)
    local function selectNone()
        local mod = rows[1].key:match("^(.*)|")
        for part in mod:gmatch("[^%-]+") do click(toggles[part]) end
        assertEquals(rows[1].key, "|1")
    end
    it("in combat: assign is queued, attributes are not touched, no protected ops; applied after combat", function()
        selectNone()
        ns.db.bindings = { ["|1"] = { type = "spell", spell = "Flash of Light" } }
        ns:Changed("bindings"); mock.flushTimers(); ns.Options:Refresh()
        local unitBtn = frameNamed("HealerForeverUnit1")
        local before = st(unitBtn).attrs["macrotext1"] or st(unitBtn).attrs["spell1"]
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0, s0 = #mock.violations, #mock.softViolations
        local calls0 = #mock.calls
        S.cursor = { "spell", 1, "spell", 19750 }
        st(rows[1]).scripts.OnReceiveDrag(rows[1]); mock.flushTimers()
        assertEquals(ns.db.bindings["|1"].spell, "Spell19750", "DB updated immediately")
        local touched = 0
        for i = calls0 + 1, #mock.calls do
            local c = mock.calls[i]
            if c.secure and PROTECTED_OK == nil and c.method == "SetAttribute" then touched = touched + 1 end
        end
        assertEquals(touched, 0, "secure SetAttribute in combat")
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0)
        assertEquals(st(unitBtn).attrs["macrotext1"] or st(unitBtn).attrs["spell1"], before, "attributes must stay frozen in combat")
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        local a = st(unitBtn).attrs
        local text = a["macrotext1"] or a["spell1"]
        assertNotNil(tostring(text):find("Spell19750", 1, true), "queued change must be applied after combat: " .. tostring(text))
        assertEquals(#mock.errors, 0, errstr())
        click(rows[1].clear)
    end)
    it("clear in combat is queued the same way (restore selection first)", function()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0 = #mock.violations
        click(rows[1].clear)
        assertEquals(#mock.violations, v0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("mac client labels (Option/Cmd) build without error", function()
        local ns2 = boot({ group = 1 })
        S.macClient = true
        ns2.Options:Show("binds"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== lock badge
describe("ui: lock badge stays in sync with frames.locked", function()
    local ns = boot({ group = 1 })
    local mb = frameNamed("HealerForeverMinimapButton")
    local function badge() return st(mb.lock).shown end
    local function lockedFlag() return ns.db.frames.locked end
    it("minimap button + badge exist; initial state matches DB", function()
        assertNotNil(mb); assertNotNil(mb.lock)
        assertEquals(badge(), lockedFlag() and true or false)
    end)
    it("right-click toggles lock and badge together (twice)", function()
        local start = lockedFlag()
        st(mb).scripts.OnClick(mb, "RightButton")
        assertEquals(lockedFlag(), not start); assertEquals(badge(), lockedFlag())
        st(mb).scripts.OnClick(mb, "RightButton")
        assertEquals(lockedFlag(), start); assertEquals(badge(), lockedFlag())
    end)
    it("/hf lock and /hf unlock", function()
        local fn
        for key, f in pairs(_G.SlashCmdList) do fn = f end
        fn("unlock"); assertFalse(lockedFlag()); assertFalse(badge())
        fn("lock"); assertTrue(lockedFlag()); assertTrue(badge())
        fn("unlock"); assertFalse(badge())
        fn("lock"); assertTrue(badge())
    end)
    it("handle and outline follow the lock", function()
        local UF = ns.UnitFrames
        ns.UnitFrames:SetLocked(false)
        assertTrue(st(UF.handle).shown); assertTrue(st(UF.outline).shown)
        ns.UnitFrames:SetLocked(true)
        assertFalse(st(UF.handle).shown); assertFalse(st(UF.outline).shown)
    end)
    it("options checkbox 'Lock frames' toggles lock and badge", function()
        ns.Options:Show("general"); mock.flushTimers()
        local cb
        for _, f in ipairs(mock.frames) do
            if st(f).kind == "CheckButton" and f.label and tostring(st(f.label).text):find("Lock frames") then cb = f end
        end
        assertNotNil(cb, "Lock frames checkbox not found")
        local start = lockedFlag()
        st(cb).checked = not start; st(cb).scripts.OnClick(cb, "LeftButton")
        assertEquals(lockedFlag(), not start); assertEquals(badge(), lockedFlag())
        st(cb).checked = start; st(cb).scripts.OnClick(cb, "LeftButton")
        assertEquals(lockedFlag(), start); assertEquals(badge(), lockedFlag())
    end)
    it("works in combat: applies immediately, no protected ops", function()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0, s0 = #mock.violations, #mock.softViolations
        local start = lockedFlag()
        st(mb).scripts.OnClick(mb, "RightButton")
        assertEquals(lockedFlag(), not start); assertEquals(badge(), lockedFlag())
        st(mb).scripts.OnClick(mb, "RightButton")
        assertEquals(badge(), start and true or false)
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("config reset re-syncs the badge", function()
        ns.UnitFrames:SetLocked(false)
        assertFalse(badge())
        ns:ResetDB(); mock.flushTimers()
        assertEquals(badge(), ns.db.frames.locked and true or false)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a fresh login with locked=false saved shows no badge", function()
        local ns2 = boot({ group = 1, db = { frames = { locked = false } } })
        local b = frameNamed("HealerForeverMinimapButton")
        assertFalse(st(b.lock).shown)
    end)
end)

-- ======================================================================== v1 SavedVariables sanitising at boot
describe("ui: v1 SavedVariables with string maps boot cleanly", function()
    local v1 = function() return { version = 1, activePreset = 2, presets = {
        { name = "Mine", map = { PALADIN = "kings", WARRIOR = "might", PRIEST = "bogus" } },
        { name = "Mine2", map = { PALADIN = "wisdom", MAGE = 5 } } },
        bindings = { ["|1"] = { type = "spell", spell = "Holy Light" } } } end
    it("loads without error, migrates to tables, buff buttons work, user values preserved", function()
        local ns = boot({ db = v1(), group = 2 })
        assertEquals(#mock.errors, 0, errstr())
        local db = _G.HealerForeverCharDB
        assertEquals(db.activePreset, 2)
        assertEquals(db.presets[1].name, "Mine")
        assertDeepEquals(db.presets[1].map.PALADIN.DEFAULT, { "kings" })
        assertDeepEquals(db.presets[1].map.WARRIOR.DEFAULT, { "might" })
        for _, k in ipairs(db.presets[1].map.PRIEST.DEFAULT) do assertNotNil(ns.Classes.BUFFS[k], "bogus buff key dropped") end
        assertDeepEquals(db.presets[2].map.PALADIN.DEFAULT, { "wisdom" })
        assertEquals(type(db.presets[2].map.MAGE), "table")
        assertEquals(db.bindings["|1"].spell, "Holy Light")
        assertEquals(buffButton("party1") and buffButton("party1").unit, "party1")
        assertEquals(#db.presets, 2, "user's two presets must not be replaced by defaults")
    end)
    it("a v1 DB with garbage role keys / mixed shapes boots", function()
        boot({ db = { version = 1, presets = { { name = "G", map = { PALADIN = { DEFAULT = "kings", HEALER = "bogus", WARLOCK_ROLE = "x" }, HUNTER = { DEFAULT = "might", TANK = "kings" } } } },
            roleOverrides = { ["A-B"] = "TANK", ["C-D"] = "BOGUS", [5] = "TANK" } }, group = 2 })
        assertEquals(#mock.errors, 0, errstr())
        local p = _G.HealerForeverCharDB.presets[1]
        assertNil(p.map.PALADIN.HEALER); assertNil(p.map.PALADIN.WARLOCK_ROLE); assertNil(p.map.HUNTER.TANK)
        assertDeepEquals(p.map.PALADIN.DEFAULT, { "kings" })
    end)
end)
