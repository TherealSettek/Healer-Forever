-- Feature-level smoke tests (whole addon in the fake WoW): option panes, click-cast signature,
-- pets, buff buttons, after-combat queue, secret aura counts.
local L = require("loader")
local mock = require("wow_mock")
local Fx = require("fixtures")
local F = require("framework")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end

local S
local function errstr() return table.concat(mock.errors, "\n---\n") end

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    if opts.class then S.units.player.class = opts.class end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.db ~= nil then _G.HealerForeverCharDB = opts.db end
    if opts.setup then opts.setup() end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    if opts.seed ~= false and opts.char == nil and opts.db == nil and opts.account == nil and ns.db then Fx.seed(ns, { presets = 4 }) end
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    if opts.group then mock.setGroup(opts.group) end
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
    return ns
end

local function frameNamed(name) for _, f in ipairs(mock.frames) do if rawget(f, "__s").name == name then return f end end end
local function sa() return #mock.callsTo("SetAttribute") end
local function st(f) return rawget(f, "__s") end

-- ------------------------------------------------------------------ AfterCombat
describe("features: ns:AfterCombat", function()
    local ns = boot({ group = 1 })
    it("out of combat runs immediately and returns true", function()
        local ran = false
        assertTrue(ns:AfterCombat("k1", function() ran = true end))
        assertTrue(ran)
    end)
    it("in combat: queues, prints a note once (non-silent)", function()
        S.combat = true; mock.printed = {}; ns.notedQueue = nil
        local ran = 0
        assertFalse(ns:AfterCombat("a", function() ran = ran + 1 end))
        assertFalse(ns:AfterCombat("b", function() ran = ran + 1 end))
        assertEquals(ran, 0)
        assertEquals(#mock.printed, 1, "expected exactly one 'queued' message, got " .. #mock.printed)
    end)
    it("silent mode prints nothing", function()
        mock.printed = {}; ns.notedQueue = nil
        ns:AfterCombat("silent", function() end, true)
        assertEquals(#mock.printed, 0)
    end)
    it("repeated key replaces the queued function (runs once, latest wins)", function()
        S.combat = true
        local log = {}
        ns:AfterCombat("dup", function() log[#log + 1] = "first" end, true)
        ns:AfterCombat("dup", function() log[#log + 1] = "second" end, true)
        S.combat = false; mock.errors = {}
        mock.fire("PLAYER_REGEN_ENABLED")
        local n = 0 for _, v in ipairs(log) do if v == "second" then n = n + 1 end assertTrue(v ~= "first") end
        assertEquals(n, 1)
    end)
    it("an erroring queued fn does not stop the next one (error goes to the error handler)", function()
        S.combat = true
        local ran = {}
        ns:AfterCombat("e1", function() ran[#ran + 1] = "e1"; error("boom-1") end, true)
        ns:AfterCombat("e2", function() ran[#ran + 1] = "e2" end, true)
        ns:AfterCombat("e3", function() ran[#ran + 1] = "e3"; error("boom-3") end, true)
        ns:AfterCombat("e4", function() ran[#ran + 1] = "e4" end, true)
        S.combat = false; mock.errors = {}
        mock.fire("PLAYER_REGEN_ENABLED")
        assertDeepEquals(ran, { "e1", "e2", "e3", "e4" })
        local booms = 0
        for _, e in ipairs(mock.errors) do if e:find("boom") then booms = booms + 1 end end
        assertEquals(booms, 2, "both errors must be reported via geterrorhandler: " .. errstr())
    end)
    it("queue is empty afterwards (second REGEN_ENABLED re-runs nothing)", function()
        local n = 0
        S.combat = true; ns:AfterCombat("once", function() n = n + 1 end, true); S.combat = false
        mock.errors = {}
        mock.fire("PLAYER_REGEN_ENABLED"); mock.fire("PLAYER_REGEN_ENABLED")
        assertEquals(n, 1)
    end)
    it("COMBAT_ENDED still fires when a queued fn errored", function()
        local fired = false
        ns:On("COMBAT_ENDED", function() fired = true end)
        S.combat = true; ns:AfterCombat("err", function() error("x") end, true); S.combat = false
        mock.fire("PLAYER_REGEN_ENABLED")
        assertTrue(fired); mock.errors = {}
    end)
end)

-- ------------------------------------------------------------------ preset dropdown + actions
describe("features: Buff Presets dropdown, actions and activePreset adjustment on delete", function()
    local function setup(active, nPresets)
        local ns = boot({ group = 1 })
        for _ = #ns.db.presets + 1, nPresets do ns.Presets.Add(ns.db.presets, nil, 1) end
        ns.db.activePreset = active
        for i, p in ipairs(ns.db.presets) do p.name = "P" .. i end
        S.combat = false
        mock.errors = {}
        assertTrue(pcall(function() ns.Options:Show("buffs") end), "could not open buffs pane")
        mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        return ns
    end
    local function button(text)
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if s.scripts.OnClick and s.text == text and s.shown then return f end
        end
    end
    local function click(f) st(f).scripts.OnClick(f, "LeftButton") end
    local function presetDD()
        for _, f in ipairs(mock.frames) do
            local p = st(f).points[1]
            if rawget(f, "Refresh") and p and p[2] == 60 and p[3] == -52 then return f end
        end
    end
    local function popupPickPrefix(prefix)
        for _, e in ipairs(mock.menu and mock.menu.entries or {}) do
            if type(e.text) == "string" and e.text:sub(1, #prefix) == prefix then e.cb(); return true end
        end
        return false
    end
    local function selectPreset(i)
        local dd = presetDD()
        assertNotNil(dd, "preset dropdown not found")
        mock.menu = nil
        click(dd)
        assertTrue(popupPickPrefix(i .. ". P"), "preset " .. i .. " not in dropdown")
        mock.flushTimers()
    end
    local function deleteConfirmed()
        local b = button("Delete")
        assertNotNil(b, "Delete button not found")
        click(b)
        local c = button("Confirm?")
        assertNotNil(c, "Delete must ask for confirmation first")
        click(c)
        assertEquals(#mock.errors, 0, errstr())
    end

    it("pane opens; dropdown lists every preset and marks the active one", function()
        local ns = setup(2, 4)
        local dd = presetDD(); assertNotNil(dd)
        mock.menu = nil
        click(dd)
        local seen = {}
        for i, e in ipairs(mock.menu and mock.menu.entries or {}) do seen[i] = e.text end
        for i = 1, #ns.db.presets do assertNotNil(seen[i], "preset " .. i .. " missing from dropdown") end
        assertNotNil(seen[2]:find("active"), "active preset must be marked: " .. seen[2])
    end)
    it("delete asks to confirm: first click does not delete", function()
        local ns = setup(1, 4)
        local n = #ns.db.presets
        click(button("Delete"))
        assertEquals(#ns.db.presets, n)
        assertNotNil(button("Confirm?"))
    end)
    it("the confirm expires (timer) and a later click asks again", function()
        local ns = setup(1, 4)
        local n = #ns.db.presets
        click(button("Delete"))
        assertNotNil(button("Confirm?"))
        mock.flushTimers()               -- runs the 4s reset timer
        assertNotNil(button("Delete"), "confirm state should have expired")
        click(button("Delete"))
        assertEquals(#ns.db.presets, n)
    end)
    it("delete a preset BELOW the active one -> activePreset shifts down and still points at the same preset", function()
        local ns = setup(3, 4)
        local activeName = ns.db.presets[3].name
        selectPreset(1)
        local b = button("Delete"); st(b).scripts.OnClick(b); st(button("Confirm?")).scripts.OnClick(button("Confirm?")); mock.flushTimers()
        assertEquals(ns.db.activePreset, 2)
        assertEquals(ns.db.presets[ns.db.activePreset].name, activeName)
    end)
    it("delete the ACTIVE preset -> activePreset stays valid", function()
        local ns = setup(2, 4)
        selectPreset(2)
        local b = button("Delete"); st(b).scripts.OnClick(b); local c = button("Confirm?"); st(c).scripts.OnClick(c); mock.flushTimers()
        assertNotNil(ns.db.presets[ns.db.activePreset])
        assertEquals(#ns.db.presets, 3)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("delete the active preset when it is the LAST -> clamped to the new last", function()
        local ns = setup(4, 4)
        selectPreset(4)
        local b = button("Delete"); st(b).scripts.OnClick(b); local c = button("Confirm?"); st(c).scripts.OnClick(c); mock.flushTimers()
        assertEquals(#ns.db.presets, 3)
        assertEquals(ns.db.activePreset, 3)
    end)
    it("delete a preset ABOVE the active one -> activePreset unchanged", function()
        local ns = setup(1, 4)
        local activeName = ns.db.presets[1].name
        selectPreset(3)
        local b = button("Delete"); st(b).scripts.OnClick(b); local c = button("Confirm?"); st(c).scripts.OnClick(c); mock.flushTimers()
        assertEquals(ns.db.activePreset, 1)
        assertEquals(ns.db.presets[1].name, activeName)
    end)
    it("the edit selection stays valid after deleting the last entry (pane refresh does not error)", function()
        local ns = setup(1, 4)
        selectPreset(4)
        local b = button("Delete"); st(b).scripts.OnClick(b); local c = button("Confirm?"); st(c).scripts.OnClick(c); mock.flushTimers()
        ns.Options:Refresh(); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("delete down to the last preset: further deletes are refused with a message", function()
        local ns = setup(1, 3)
        for _ = 1, #ns.db.presets - 1 do
            local b = button("Delete"); st(b).scripts.OnClick(b); local c = button("Confirm?"); st(c).scripts.OnClick(c); mock.flushTimers()
        end
        assertEquals(#ns.db.presets, 1)
        mock.printed = {}
        local b = button("Delete"); st(b).scripts.OnClick(b)
        assertEquals(#ns.db.presets, 1); assertEquals(ns.db.activePreset, 1)
        assertTrue(#mock.printed >= 1, "user should be told the last preset cannot be deleted")
    end)
    it("after any delete the buff buttons refresh without error", function()
        local ns = setup(2, 4)
        selectPreset(1)
        local b = button("Delete"); st(b).scripts.OnClick(b); local c = button("Confirm?"); st(c).scripts.OnClick(c); mock.flushTimers()
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("New: opens the name row, OK adds a preset and selects it", function()
        local ns = setup(1, 3)
        local n = #ns.db.presets
        click(button("New"))
        local box
        for _, f in ipairs(mock.frames) do if st(f).kind == "EditBox" and st(f).shown and st(f).scripts.OnEnterPressed then box = f end end
        assertNotNil(box, "name box not shown")
        st(box).text = "Brand New"
        click(button("OK"))
        assertEquals(#ns.db.presets, n + 1)
        assertEquals(ns.db.presets[n + 1].name, "Brand New")
        for _, c in ipairs({ "PALADIN", "MAGE" }) do assertEquals(type(ns.db.presets[n + 1].map[c]), "table") end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("Duplicate copies the rules deeply under a new name", function()
        local ns = setup(1, 3)
        local n = #ns.db.presets
        selectPreset(2)
        click(button("Duplicate"))
        click(button("OK"))
        assertEquals(#ns.db.presets, n + 1)
        local copy = ns.db.presets[n + 1]
        assertTrue(copy.name ~= "", "copy has a name")
        assertDeepEquals(copy.map, ns.db.presets[2].map)
        assertTrue(copy.map ~= ns.db.presets[2].map)
        assertTrue(copy.map.PALADIN ~= ns.db.presets[2].map.PALADIN)
    end)
    it("Rename changes the selected preset's name (trimmed); empty is rejected; Cancel does nothing", function()
        local ns = setup(1, 3)
        selectPreset(2)
        click(button("Rename"))
        for _, f in ipairs(mock.frames) do if st(f).kind == "EditBox" and st(f).shown and st(f).scripts.OnEnterPressed then st(f).text = "  Renamed  " end end
        click(button("OK"))
        assertEquals(ns.db.presets[2].name, "Renamed")
        click(button("Rename"))
        for _, f in ipairs(mock.frames) do if st(f).kind == "EditBox" and st(f).shown and st(f).scripts.OnEnterPressed then st(f).text = "   " end end
        click(button("OK"))
        assertEquals(ns.db.presets[2].name, "Renamed")
        click(button("Rename")); click(button("Cancel"))
        assertEquals(ns.db.presets[2].name, "Renamed")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("Make active sets the selected preset active", function()
        local ns = setup(1, 3)
        selectPreset(3)
        click(button("Make active"))
        assertEquals(ns.db.activePreset, 3)
    end)
    it("all actions in combat: no protected operations, no errors", function()
        local ns = setup(1, 3)
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        click(button("New")); click(button("Cancel"))
        click(button("Make active"))
        click(button("Duplicate")); click(button("OK"))
        assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
    end)
    it("ns:SetActivePreset ignores invalid indexes; ns:CyclePreset wraps", function()
        local ns = setup(1, 3)
        ns:SetActivePreset(99); assertEquals(ns.db.activePreset, 1)
        ns:SetActivePreset(0); assertEquals(ns.db.activePreset, 1)
        ns:CyclePreset(); assertEquals(ns.db.activePreset, 2)
        for _ = 1, #ns.db.presets - 1 do ns:CyclePreset() end
        assertEquals(ns.db.activePreset, 1)
    end)
end)

-- ------------------------------------------------------------------ click-cast
describe("features: click-cast", function()
    it("repeated SPELLS_CHANGED / PLAYER_TALENT_UPDATE does not rebuild attributes (signature unchanged)", function()
        boot({ group = 2 })
        mock.runOnUpdate(2, 0.2); mock.flushTimers()
        local before = #mock.calls
        for _ = 1, 10 do mock.fire("SPELLS_CHANGED"); mock.fire("PLAYER_TALENT_UPDATE") end
        mock.flushTimers()
        local after = 0
        for i = before + 1, #mock.calls do
            local c = mock.calls[i]
            if c.method == "SetAttribute" and c.frame:match("^HealerForeverUnit") then after = after + 1 end
        end
        assertEquals(after, 0, "unit-button attributes were rebuilt " .. after .. " times by unchanged SPELLS_CHANGED")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("SPELLS_CHANGED with a changed res spell availability DOES rebuild", function()
        local ns = boot({ group = 2 })
        mock.flushTimers()
        local n0 = #mock.calls
        _G.IsPlayerSpell = function() return false end
        _G.IsSpellKnown = function() return false end
        _G.C_SpellBook.IsSpellKnown = function() return false end
        mock.fire("SPELLS_CHANGED"); mock.flushTimers()
        local n = 0
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            if c.method == "SetAttribute" and c.frame:match("^HealerForeverUnit") then n = n + 1 end
        end
        assertTrue(n > 0, "attributes not rebuilt after res spell became unknown")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("SPELLS_CHANGED in combat never calls SetAttribute on secure frames", function()
        boot({ group = 2 })
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        _G.IsPlayerSpell = function() return false end
        local v0 = #mock.violations
        mock.fire("SPELLS_CHANGED"); mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
        assertEquals(#mock.violations, v0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("'menu' is refused on every key except plain Right ('|2')", function()
        local ns = boot({ group = 1 })
        ns.db.bindings = { ["|1"] = { type = "target" }, ["|2"] = { type = "menu" }, ["shift|2"] = { type = "menu" },
            ["|3"] = { type = "menu" }, ["ctrl|1"] = { type = "menu" }, ["|6"] = { type = "menu" }, ["alt|2"] = { type = "menu" } }
        ns:Changed("bindings"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        local b = frameNamed("HealerForeverUnit1")
        assertNotNil(b)
        local a = st(b).attrs
        assertEquals(a["type2"], "togglemenu", "plain right-click menu must work")
        assertNil(a["shift-type2"]); assertNil(a["type3"]); assertNil(a["ctrl-type1"]); assertNil(a["alt-type2"])
        for k, v in pairs(a) do
            if type(k) == "string" and k:match("^%*type%-HFB") then assertTrue(v ~= "togglemenu", "menu leaked into override slot " .. k) end
        end
    end)
    it("target bindings are emitted as macros built by BuildTargetMacro (with res for a PALADIN)", function()
        local ns = boot({ group = 1 })
        ns.db.bindings = { ["|1"] = { type = "target" }, ["shift|1"] = { type = "target" } }
        ns:Changed("bindings"); mock.flushTimers()
        local res, ooc = ns.PlayerRes()
        local a = st(frameNamed("HealerForeverUnit1")).attrs
        local u = a.unit
        assertEquals(a["type1"], "macro")
        assertEquals(a["macrotext1"], ns.Bindings.BuildTargetMacro(u, res, ooc))
        assertEquals(a["shift-macrotext1"], ns.Bindings.BuildTargetMacro(u, res, ooc))
        assertNotNil(a["macrotext1"]:find("/target [@" .. u .. ",nodead]", 1, true))
    end)
    it("target macro has no res part for a class without res (WARRIOR)", function()
        local ns = boot({ group = 1, class = "WARRIOR" })
        ns.db.bindings = { ["|1"] = { type = "target" } }
        ns:Changed("bindings"); mock.flushTimers()
        local a = st(frameNamed("HealerForeverUnit1")).attrs
        assertEquals(a["macrotext1"], "/target [@" .. a.unit .. "]")
    end)
    it("applying click-casts clears override bindings and wraps OnHide once per button", function()
        boot({ group = 2 })
        mock.flushTimers()
        local clears = #mock.callsTo("ClearOverrideBindings")
        local wraps = #mock.callsTo("SecureHandlerWrapScript")
        assertTrue(clears > 0, "ClearOverrideBindings never called")
        assertTrue(wraps > 0, "SecureHandlerWrapScript never called")
        local per = {}
        for _, c in ipairs(mock.callsTo("SecureHandlerWrapScript")) do
            local fr = c.args[1]
            per[fr] = (per[fr] or 0) + 1
            assertEquals(c.args[2], "OnHide")
        end
        for f, n in pairs(per) do assertEquals(n, 1, "wrapped " .. n .. " times: " .. tostring(f)) end
    end)
    it("buttons 6+ and meta use override bindings; physical 1-5 stay plain attributes", function()
        local ns = boot({ group = 1 })
        ns.db.bindings = { ["|1"] = { type = "spell", spell = "A" }, ["|7"] = { type = "spell", spell = "B" },
            ["shift|8"] = { type = "spell", spell = "C" }, ["meta|1"] = { type = "spell", spell = "D" } }
        ns:Changed("bindings"); mock.flushTimers()
        local a = st(frameNamed("HealerForeverUnit1")).attrs
        assertNotNil(a["type1"])
        local slots = 0
        for k in pairs(a) do if type(k) == "string" and k:match("^hf%-bkey%d+$") then slots = slots + 1 end end
        assertTrue(slots >= 1, "no override binding keys registered")
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ------------------------------------------------------------------ pets
describe("features: pets", function()
    it("UNIT_PET('party1') updates the partypet1 button (and only that one)", function()
        local ns = boot({ group = 2 })
        S.units.partypet1 = { name = "Cat", class = "HUNTER", health = 10, maxHealth = 10, power = 0, maxPower = 0, powerType = 0, role = "NONE" }
        S.units.partypet2 = { name = "Imp", class = "WARLOCK", health = 10, maxHealth = 10, power = 0, maxPower = 0, powerType = 0, role = "NONE" }
        local UF = ns.UnitFrames
        local updated = {}
        local orig = UF.UpdateAll
        UF.UpdateAll = function(self, button) updated[#updated + 1] = button.unit; return orig(self, button) end
        mock.fire("UNIT_PET", "party1")
        UF.UpdateAll = orig
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(#updated, 1, "updated: " .. table.concat(updated, ","))
        assertEquals(updated[1], "partypet1")
    end)
    it("UNIT_PET for player updates pet; nil / non-group owner is ignored without error", function()
        local ns = boot({ group = 2 })
        local UF = ns.UnitFrames
        local updated = {}
        local orig = UF.UpdateAll
        UF.UpdateAll = function(self, button) updated[#updated + 1] = button.unit; return orig(self, button) end
        mock.fire("UNIT_PET", "player"); mock.fire("UNIT_PET", nil); mock.fire("UNIT_PET", "target"); mock.fire("UNIT_PET", "nameplate3")
        UF.UpdateAll = orig
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(#updated, 1); assertEquals(updated[1], "pet")
    end)
    it("pet appearing/disappearing in combat: no errors, no protected ops", function()
        boot({ group = 2 })
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0, s0 = #mock.violations, #mock.softViolations
        for i = 1, 6 do
            S.units.partypet1 = (i % 2 == 1) and { name = "Cat", class = "HUNTER", health = 10, maxHealth = 10, power = 0, maxPower = 0, powerType = 0, role = "NONE" } or nil
            mock.fire("UNIT_PET", "party1"); mock.fire("GROUP_ROSTER_UPDATE"); mock.runOnUpdate(1, 0.2)
        end
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0)
    end)
end)

-- ------------------------------------------------------------------ buff buttons
describe("features: buff buttons", function()
    local ns = boot({ group = 2 })
    mock.runOnUpdate(2, 0.5); mock.flushTimers()

    it("buff buttons exist and register AnyDown + AnyUp clicks", function()
        local n = 0
        for _, f in ipairs(mock.frames) do
            local name = st(f).name
            if name and name:match("^HealerForeverBuff%d+$") then
                n = n + 1
                local found = false
                for _, c in ipairs(mock.calls) do
                    if c.obj == f and c.method == "RegisterForClicks" and c.args[1] == "AnyDown" and c.args[2] == "AnyUp" then found = true end
                end
                assertTrue(found, name .. " did not RegisterForClicks('AnyDown','AnyUp')")
            end
        end
        assertTrue(n > 0, "no buff buttons created")
    end)
    it("unit buttons register AnyUp ONLY (SecureUnitButton_OnClick has no down/up filter)", function()
        local btn = frameNamed("HealerForeverUnit1")
        local calls = {}
        for _, c in ipairs(mock.calls) do
            if c.obj == btn and c.method == "RegisterForClicks" then calls[#calls + 1] = c end
        end
        assertEquals(#calls, 1)
        assertEquals(calls[1].n, 1, "exactly one click type")
        assertEquals(calls[1].args[1], "AnyUp")
    end)
    it("a missing buff activates the button and starts the pulse", function()
        local b
        for _, f in ipairs(mock.frames) do local nm = st(f).name; if nm and nm:match("^HealerForeverBuff%d+$") and f.buffKey then b = f; break end end
        assertNotNil(b, "no buff button became active for a member missing a buff")
        assertTrue(st(b.pulse).playing, "pulse not playing on active button")
    end)
    it("pulse stops (and button deactivates) when the buff button becomes inactive", function()
        local b
        for _, f in ipairs(mock.frames) do local nm = st(f).name; if nm and nm:match("^HealerForeverBuff%d+$") and f.buffKey then b = f; break end end
        assertNotNil(b)
        S.dead[b.unit] = true
        mock.fire("UNIT_AURA", b.unit); mock.fire("UNIT_FLAGS", b.unit); mock.flushTimers(); mock.runOnUpdate(2, 0.5)
        assertEquals(#mock.errors, 0, errstr())
        assertNil(b.buffKey, "buffKey not cleared")
        assertFalse(st(b.pulse).playing, "pulse still playing on inactive buff button")
        assertEquals(b:GetAlpha(), 0, "inactive buff button must be invisible")
    end)
    it("pulse restarts when the buff is missing again; stops when the unit leaves", function()
        local b
        for _, f in ipairs(mock.frames) do local nm = st(f).name; if nm and nm:match("^HealerForeverBuff%d+$") and f.unit == "party2" then b = f end end
        assertNotNil(b)
        S.dead = {}
        mock.fire("UNIT_AURA", "party2"); mock.flushTimers()
        assertNotNil(b.buffKey); assertTrue(st(b.pulse).playing)
        S.units.party2 = nil; S.groupSize = 1
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        assertFalse(st(b.pulse).playing, "pulse still playing after unit left")
    end)
    it("buff buttons are hidden by a [combat] state driver and never touched in combat", function()
        S.units.party2 = { name = "Wizard", class = "MAGE", health = 1, maxHealth = 1, power = 1, maxPower = 1, powerType = 0, role = "DAMAGER" }
        S.groupSize = 2
        S.combat = true; S.secret = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0 = #mock.violations
        mock.fire("UNIT_AURA", "party1"); mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("SPELLS_CHANGED"); mock.flushTimers(); mock.runOnUpdate(3, 1)
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(#mock.violations, v0)
        S.combat = false; S.secret = false
    end)
end)

-- ------------------------------------------------------------------ secret stack counts
describe("features: secret aura stack counts in combat", function()
    it("UNIT_AURA with GetAuraApplicationDisplayCount returning a secret does not error", function()
        boot({ group = 2 })
        S.auras.player = { { spellId = 20217, name = "Blessing of Kings", icon = 134400, duration = 600, expirationTime = S.now + 300, applications = 3, isHelpful = true, auraInstanceID = 11 } }
        S.auras.party1 = { { spellId = 5, name = "Poison", icon = 134400, duration = 20, expirationTime = S.now + 10, applications = 4, dispelName = "Poison", isHarmful = true, isHelpful = false, auraInstanceID = 12 } }
        S.combat = true; S.secret = true
        mock.fire("PLAYER_REGEN_DISABLED")
        local sentinel = C_UnitAuras.GetAuraApplicationDisplayCount("player", 11, 2)
        assertTrue(mock.isSecret(sentinel), "mock should return a secret sentinel in secret mode")
        for _, u in ipairs({ "player", "party1" }) do
            mock.fire("UNIT_AURA", u, { isFullUpdate = true })
            mock.fire("UNIT_AURA", u, { addedAuras = {} })
        end
        mock.fire("GROUP_ROSTER_UPDATE"); mock.runOnUpdate(5, 0.5); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        S.combat = false; S.secret = false
        mock.fire("PLAYER_REGEN_ENABLED"); mock.fire("UNIT_AURA", "player"); mock.runOnUpdate(2, 0.5)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a count that is a secret never reaches arithmetic/comparison (SetText gets it verbatim)", function()
        boot({ group = 1 })
        S.auras.player = { { spellId = 1, name = "X", icon = 1, duration = 0, expirationTime = 0, applications = 5, isHelpful = true, auraInstanceID = 3 } }
        S.combat = true; S.secret = true
        mock.fire("UNIT_AURA", "player")
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("features: mock coverage report", function()
    it("lists undefined globals touched (informational)", function()
        boot({ group = 2 })
        local o = frameNamed("UIParent")
        mock.runOnUpdate(3, 0.2); mock.flushTimers()
        local list = mock.undefinedList()
        if #list > 0 then warn("WoW globals the mock lacks (test_features): " .. table.concat(list, ", ")) end
    end)
end)
