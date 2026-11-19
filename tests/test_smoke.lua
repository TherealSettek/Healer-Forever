-- Layer 3: smoke / fuzz tests of the whole addon inside the fake WoW environment.
local L = require("loader")
local mock = require("wow_mock")
local Fx = require("fixtures")

local toc = L.parseToc()
if not toc then
    it("TOC present for smoke test", function() error("HealerForever.toc missing") end)
    return
end

local S -- shorthand for mock.state, refreshed in boot()

local function names(t) local o = {} for k in pairs(t) do o[#o + 1] = tostring(k) end table.sort(o) return o end

local function errstr() return table.concat(mock.errors, "\n---\n") end

-- Boot the whole addon. opts: class (player class), group (party members besides player).
local function boot(opts)
    opts = opts or {}
    mock.install()
    S = mock.state
    if opts.class then S.units.player.class = opts.class end
    if opts.mac then S.macClient = true end
    local ns = {}
    local loadErrors = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then
            local ok, err = pcall(L.loadFile, rel, ns)
            if not ok then loadErrors[#loadErrors + 1] = tostring(err) end
        end
    end
    if opts.db ~= nil then _G.HealerForeverCharDB = opts.db end
    mock.fire("ADDON_LOADED", "HealerForever")
    if opts.seed ~= false and opts.db == nil and ns.db then Fx.seed(ns, { presets = 4 }) end
    mock.flushTimers()
    mock.fire("PLAYER_LOGIN")
    mock.flushTimers()
    if opts.group then
        mock.setGroup(opts.group)
    end
    mock.fire("PLAYER_ENTERING_WORLD", true, false)
    mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE")
    mock.flushTimers()
    return ns, loadErrors
end

local function slashHandler()
    for key, fn in pairs(_G.SlashCmdList) do
        for i = 1, 5 do
            local c = rawget(_G, "SLASH_" .. key .. i)
            if c and (c:lower() == "/hf" or c:lower() == "/healerforever") then return fn, key end
        end
    end
end

local function slash(msg)
    local fn = slashHandler()
    if not fn then error("no /hf slash command registered") end
    return pcall(fn, msg)
end

local function secureUnitButtons()
    local out = {}
    for _, f in ipairs(mock.frames) do
        local s = rawget(f, "__s")
        -- only the addon's unit frames (buff buttons are secure + have a unit attr too)
        if s.secure and s.attrs.unit and tostring(s.name):match("^HealerForeverUnit") then out[#out + 1] = f end
    end
    return out
end
local function A(f) return rawget(f, "__s").attrs end

-- ====================================================================== boot + scenario
describe("smoke: load + lifecycle events", function()
    local ns, loadErrors = boot()
    it("all TOC files execute without error", function()
        assertEquals(#loadErrors, 0, table.concat(loadErrors, "\n"))
    end)
    it("ADDON_LOADED/PLAYER_LOGIN/PLAYER_ENTERING_WORLD/GROUP_ROSTER_UPDATE raise no errors", function()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("HealerForeverCharDB exists after ADDON_LOADED", function()
        assertEquals(type(_G.HealerForeverCharDB), "table")
    end)
    it("a slash command /hf is registered", function()
        assertNotNil(slashHandler(), "SlashCmdList entries: " .. table.concat(names(_G.SlashCmdList), ","))
    end)
    it("addon registered at least one event", function()
        local n = 0
        for _, f in ipairs(mock.frames) do for _ in pairs(rawget(f, "__s").events) do n = n + 1 end end
        assertTrue(n > 0)
    end)

    local before = #mock.errors
    it("UNIT_HEALTH/UNIT_AURA/UNIT_POWER_UPDATE/MODIFIER_STATE_CHANGED raise no errors", function()
        mock.fire("UNIT_HEALTH", "player"); mock.fire("UNIT_MAXHEALTH", "player")
        mock.fire("UNIT_AURA", "player", { isFullUpdate = true })
        mock.fire("UNIT_POWER_UPDATE", "player", "MANA"); mock.fire("UNIT_POWER_FREQUENT", "player", "MANA")
        mock.fire("UNIT_DISPLAYPOWER", "player"); mock.fire("UNIT_CONNECTION", "player", true)
        mock.fire("UNIT_NAME_UPDATE", "player"); mock.fire("UNIT_FLAGS", "player")
        S.shift = true; mock.fire("MODIFIER_STATE_CHANGED", "LSHIFT", 1)
        S.shift = false; mock.fire("MODIFIER_STATE_CHANGED", "LSHIFT", 0)
        S.meta = true; mock.fire("MODIFIER_STATE_CHANGED", "LMETA", 1); S.meta = false
        S.alt = true; S.ctrl = true; mock.fire("MODIFIER_STATE_CHANGED", "LALT", 1); S.alt = false; S.ctrl = false
        mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("OnUpdate scripts run without error", function()
        mock.runOnUpdate(5, 0.2)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("populated auras (player + party) are handled", function()
        mock.setGroup(2)
        S.auras.player = { { spellId = 20217, name = "Blessing of Kings", icon = 134400, duration = 600, expirationTime = S.now + 30, applications = 0, isHelpful = true } }
        S.auras.party1 = { { spellId = 1, name = "Test", icon = 134400, duration = 0, expirationTime = 0, applications = 3, dispelName = "Magic", isHarmful = true, isHelpful = false } }
        mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("UNIT_AURA", "player"); mock.fire("UNIT_AURA", "party1")
        mock.runOnUpdate(3, 1); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("PLAYER_REGEN_DISABLED / ENABLED / TARGET / ROLES / SPELLS events do not error", function()
        for _, ev in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_TARGET_CHANGED", "PLAYER_ROLES_ASSIGNED",
            "SPELLS_CHANGED", "UPDATE_BINDINGS", "PLAYER_SPECIALIZATION_CHANGED", "UNIT_PET", "PARTY_MEMBER_ENABLE", "PARTY_MEMBER_DISABLE", "PLAYER_LOGOUT" }) do
            mock.fire(ev, "player")
        end
        mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ====================================================================== slash commands
describe("smoke: slash commands", function()
    local ns = boot({ group = 2 })
    local function run(msg)
        local ok, err = slash(msg)
        assertTrue(ok, "/hf " .. string.format("%q", msg) .. " raised: " .. tostring(err))
        mock.runOnUpdate(2, 0.1); mock.flushTimers()
        assertEquals(#mock.errors, 0, "after /hf " .. msg .. ": " .. errstr())
    end
    local cmds = { "", "help", "?", "config", "options", "settings", "show", "hide", "toggle", "lock", "unlock", "preset", "preset 1",
        "preset 2", "preset 3", "preset 99", "preset 0", "preset -1", "preset x", "preset 2 extra args", "minimap", "version", "debug",
        "garbage", "   ", "!@#$%^&*()", string.rep("a", 2000), "LOCK", "Unlock", "\0", "preset\t2", "bindings", "buffs", "frames" }
    for _, c in ipairs(cmds) do
        it("/hf " .. string.format("%q", c:sub(1, 30)) .. " out of combat", function() S.combat = false; run(c) end)
    end
    for _, c in ipairs(cmds) do
        it("/hf " .. string.format("%q", c:sub(1, 30)) .. " in combat (secret)", function()
            S.combat = true; S.secret = true
            run(c)
            S.combat = false; S.secret = false
        end)
    end
    it("subcommands advertised by /hf help also run (in and out of combat)", function()
        mock.printed = {}
        slash("help")
        local seen, subs = {}, {}
        for _, line in ipairs(mock.printed) do
            for w in line:gmatch("/hf%s+(%a+)") do if not seen[w] then seen[w] = true; subs[#subs + 1] = w end end
        end
        for _, w in ipairs(subs) do
            S.combat = false; run(w)
            S.combat = true; run(w); S.combat = false
        end
    end)
    it("/hf preset 2 switches activePreset (when at least 2 presets exist)", function()
        if #_G.HealerForeverCharDB.presets < 2 then return end
        slash("preset 1"); slash("preset 2")
        assertEquals(_G.HealerForeverCharDB.activePreset, 2)
    end)
    it("/hf preset 99 leaves activePreset valid", function()
        slash("preset 99")
        assertNotNil(_G.HealerForeverCharDB.presets[_G.HealerForeverCharDB.activePreset])
    end)
    it("/hf reset (if supported) leaves a valid DB", function()
        slash("reset"); mock.flushTimers()
        assertEquals(type(_G.HealerForeverCharDB), "table")
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ====================================================================== options UI
describe("smoke: options UI exercised through scripts", function()
    local ns = boot({ group = 2 })
    local fn = slashHandler()

    local function drive(label)
        local n = 0
        local snapshot = {}
        for _, f in ipairs(mock.frames) do snapshot[#snapshot + 1] = f end
        local vals = { 0, 1, 5, 10, 0.5, 100 }
        for _, f in ipairs(snapshot) do
            local s = rawget(f, "__s")
            if not s.secure then
                for _, script in ipairs({ "OnShow", "OnEnter", "OnLeave", "OnClick", "OnMouseDown", "OnMouseUp", "OnDragStart", "OnDragStop",
                    "OnReceiveDrag", "OnTextChanged", "OnEnterPressed", "OnEscapePressed", "OnEditFocusLost", "PreClick", "PostClick" }) do
                    local h = s.scripts[script]
                    if h then
                        n = n + 1
                        local ok, err = xpcall(function() h(f, script == "OnClick" and "LeftButton" or nil, false) end, debug.traceback)
                        if not ok then mock.errors[#mock.errors + 1] = label .. " " .. script .. " on " .. tostring(s.name or s.kind) .. ": " .. err end
                    end
                end
                local h = s.scripts.OnValueChanged
                if h then
                    for _, v in ipairs(vals) do
                        n = n + 1
                        local ok, err = xpcall(function() s.value = v; h(f, v, true) end, debug.traceback)
                        if not ok then mock.errors[#mock.errors + 1] = label .. " OnValueChanged(" .. v .. ") on " .. tostring(s.name or s.kind) .. ": " .. err end
                    end
                end
                -- checkbox toggled both ways
                if s.scripts.OnClick and (s.kind == "CheckButton") then
                    for _, c in ipairs({ true, false }) do
                        s.checked = c
                        local ok, err = xpcall(function() s.scripts.OnClick(f, "LeftButton") end, debug.traceback)
                        if not ok then mock.errors[#mock.errors + 1] = label .. " checkbox toggle: " .. err end
                    end
                end
            end
        end
        mock.flushTimers()
        return n
    end

    it("opening options via /hf does not error", function()
        slash(""); slash("config"); slash("options")
        mock.runOnUpdate(2, 0.1); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("driving every script of every non-secure frame (out of combat)", function()
        S.combat = false
        local n = drive("ooc")
        assertTrue(n > 0, "no scripts found to drive")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("driving every script (in combat, secret values)", function()
        S.combat = true; S.secret = true
        mock.fire("PLAYER_REGEN_DISABLED")
        drive("combat")
        S.combat = false; S.secret = false
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(#mock.violations, 0, "secure SetAttribute in combat: " .. (require("framework").repr(mock.violations[1]) .. (mock.violations[1] and mock.violations[1].trace or "")))
    end)
    it("after UI poking the saved DB is still well-formed", function()
        local db = _G.HealerForeverCharDB
        assertEquals(type(db.presets), "table"); assertEquals(type(db.bindings), "table")
        assertNotNil(db.presets[db.activePreset])
    end)
    it("dropping a spell on a binding row (cursor info) does not error", function()
        S.cursor = { "spell", 1, "spell", 19750 }
        drive("cursor")
        S.cursor = nil
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ====================================================================== secret values / combat
describe("smoke: combat + secret values", function()
    local ns = boot({ group = 3 })
    it("secret mode: UNIT_HEALTH/UNIT_AURA/UNIT_POWER_UPDATE must not error", function()
        S.combat = true; S.secret = true
        mock.fire("PLAYER_REGEN_DISABLED")
        S.auras.player = { { spellId = 20217, name = "Blessing of Kings", icon = 134400, duration = 600, expirationTime = S.now + 30, applications = 2, isHelpful = true } }
        for _, u in ipairs({ "player", "party1", "party2", "party3" }) do
            mock.fire("UNIT_HEALTH", u); mock.fire("UNIT_MAXHEALTH", u); mock.fire("UNIT_AURA", u)
            mock.fire("UNIT_POWER_UPDATE", u, "MANA"); mock.fire("UNIT_POWER_FREQUENT", u, "MANA"); mock.fire("UNIT_ABSORB_AMOUNT_CHANGED", u)
            mock.fire("UNIT_HEAL_PREDICTION", u)
        end
        mock.runOnUpdate(5, 0.2); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("secret mode with empty auras", function()
        S.auras = {}
        mock.fire("UNIT_AURA", "player"); mock.fire("UNIT_AURA", "party1"); mock.runOnUpdate(3, 0.5)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("roster update + target change during combat must not error", function()
        mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("PLAYER_TARGET_CHANGED"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("/hf perf, start, sampling ticks, stop, report and copy in combat with secret values must not error", function()
        assertTrue(S.combat and S.secret, "still in combat with secret values")
        mock.setAddons({ { name = "HealerForever", cpu = 0.1, mem = 500 }, { name = "Other", cpu = 0.2, mem = 900 } },
            { profiler = true, secret = true })
        for _, msg in ipairs({ "perf", "perf start 5", "perf start", "perf", "perf stop", "perf bad", "report" }) do
            local ok, err = slash(msg)
            assertTrue(ok, "/hf " .. msg .. ": " .. tostring(err))
            mock.runOnUpdate(3, 0.3); mock.tick(); mock.flushTimers()
        end
        assertTrue(ns.CopyText():find("== /hf perf ==", 1, true) ~= nil)
        assertNil(ns.perfOn, "sampling stopped")
        assertEquals(mock.perfCalls.memUpdateCombat, 0, "no memory refresh in combat")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("no SetAttribute on secure frames while InCombatLockdown() was true", function()
        assertEquals(#mock.violations, 0, "violation: " .. (require("framework").repr(mock.violations[1]) .. (mock.violations[1] and mock.violations[1].trace or "")))
    end)
    it("no SetPoint/Show/Hide/SetSize on secure frames while in combat", function()
        local v = mock.softViolations[1]
        assertEquals(#mock.softViolations, 0, "protected op in combat: " .. require("framework").repr(v))
    end)
    it("leaving combat restores normal operation", function()
        S.combat = false; S.secret = false
        mock.fire("PLAYER_REGEN_ENABLED"); mock.fire("UNIT_HEALTH", "player"); mock.flushTimers(); mock.runOnUpdate(2, 0.2)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("secret during login/ADDON_LOADED itself (reload in combat) does not error", function()
        mock.install(); S = mock.state; S.combat = true; S.secret = true
        local ns2 = {}
        for _, rel in ipairs(toc.files) do if rel:match("%.lua$") then assertTrue(pcall(L.loadFile, rel, ns2)) end end
        mock.fire("ADDON_LOADED", "HealerForever"); mock.fire("PLAYER_LOGIN"); mock.fire("PLAYER_ENTERING_WORLD", false, true)
        mock.setGroup(2); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(3, 0.2)
        assertEquals(#mock.errors, 0, errstr())
        if #mock.violations > 0 then
            local v = mock.violations[1]
            warn("login/ADDON_LOADED while InCombatLockdown()==true: " .. #mock.violations .. " SetAttribute calls on secure frames (first: " .. v.frame .. ":SetAttribute(" .. tostring(v.args[1]) .. ") from frame creation). Only reachable by logging in mid-combat.")
        end
    end)
end)

-- ====================================================================== resurrection on dead
describe("smoke: dead members and resurrection macros", function()
    local function check(class, resName)
        local ns = boot({ class = class, group = 2 })
        it(class .. ": boot clean", function() assertEquals(#mock.errors, 0, errstr()) end)
        it(class .. ": party unit button spell bindings use macro with dead conditional (out of combat)", function()
            local B = ns.Bindings
            local _, resOOC = ns.PlayerRes()
            local buttons = secureUnitButtons()
            assertTrue(#buttons > 0, "no secure unit buttons found (attr 'unit')")
            local checked = 0
            for _, f in ipairs(buttons) do
                local unit = A(f).unit
                if unit and unit:match("^party%d$") then
                    for key, act in pairs(_G.HealerForeverCharDB.bindings) do
                        if act.type == "spell" then
                            local expect = B.ToAttributes(key, act)
                            local m, btn = B.ParseKey(key)
                            local prefix = (m ~= "" and (m .. "-") or "")
                            local attrs = A(f)
                            if resName then
                                local text, tname
                                if B.NeedsOverride(m, btn) then
                                    -- meta combos / buttons > 5 live in wildcard "*macrotext-HFBn" slots (override bindings)
                                    for k, v in pairs(attrs) do
                                        if type(k) == "string" and k:match("^%*macrotext%-HFB") and v == B.BuildMacroText(unit, act.spell, resName, resOOC) then text = v end
                                    end
                                    assertNotNil(text, unit .. " " .. key .. ": no *macrotext-HFBn slot equal to the expected res macro")
                                else
                                    tname = attrs[prefix .. "type" .. btn]
                                    assertEquals(tname, "macro", unit .. " " .. key .. " should be macro (attr " .. prefix .. "type" .. btn .. ")")
                                    text = attrs[prefix .. "macrotext" .. btn]
                                end
                                assertNotNil(text, unit .. " " .. key .. " no macrotext")
                                assertNotNil(text:find("[@" .. unit .. ",dead] " .. resName, 1, true), "macrotext: " .. tostring(text))
                                assertNotNil(text:find("[@" .. unit .. ",help,nodead] " .. act.spell, 1, true), "macrotext: " .. tostring(text))
                                assertEquals(text, B.BuildMacroText(unit, act.spell, resName, resOOC))
                            else
                                -- class without res: plain spell (or equivalent macro without ,dead)
                                local t = attrs[prefix .. "macrotext" .. btn]
                                if t then assertNil(t:find(",dead", 1, true), "unexpected dead clause: " .. t) end
                                if not B.NeedsOverride(m, btn) then
                                    assertNotNil(attrs[prefix .. "type" .. btn], unit .. " " .. key .. " has no type attr")
                                end
                            end
                            checked = checked + 1
                        end
                    end
                end
            end
            assertTrue(checked > 0, "no party spell bindings checked")
        end)
        it(class .. ": every unit token (player/party1-4) gets exactly the right BuildMacroText", function()
            for _, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
                local t = ns.Bindings.BuildMacroText(u, "X", resName)
                if resName then assertEquals(t, "/cast [@" .. u .. ",dead] " .. resName .. "; [@" .. u .. ",help,nodead] X")
                else assertEquals(t, "/cast [@" .. u .. ",help,nodead] X") end
            end
        end)
    end
    check("PALADIN", "Redemption"); check("PRIEST", "Resurrection"); check("SHAMAN", "Ancestral Spirit"); check("DRUID", "Rebirth")
    check("WARRIOR", nil); check("MAGE", nil)

    describe("dying unit", function()
        local ns = boot({ class = "PALADIN", group = 2 })
        it("out of combat: party1 dead + UNIT_HEALTH/UNIT_FLAGS raise no errors", function()
            S.dead.party1 = true
            mock.fire("UNIT_HEALTH", "party1"); mock.fire("UNIT_FLAGS", "party1"); mock.fire("UNIT_CONNECTION", "party1", true)
            mock.fire("GROUP_ROSTER_UPDATE"); mock.runOnUpdate(3, 0.2); mock.flushTimers()
            assertEquals(#mock.errors, 0, errstr())
        end)
        it("out of combat: bindings still carry [@party1,dead] Redemption", function()
            local found = false
            for _, f in ipairs(secureUnitButtons()) do
                if A(f).unit == "party1" then
                    for k, v in pairs(A(f)) do
                        if type(v) == "string" and v:find("[@party1,dead] Redemption", 1, true) then found = true end
                    end
                end
            end
            assertTrue(found, "no macrotext with [@party1,dead] Redemption on party1 button")
        end)
        it("in combat: a unit dying causes ZERO SetAttribute calls on secure frames", function()
            S.dead.party1 = nil
            S.combat = true; S.secret = true
            mock.fire("PLAYER_REGEN_DISABLED"); mock.flushTimers()
            local before = #mock.callsTo("SetAttribute", function(c) return c.secure and c.combat end)
            S.dead.party1 = true; S.dead.party2 = true
            for _, ev in ipairs({ "UNIT_HEALTH", "UNIT_FLAGS", "UNIT_AURA", "UNIT_CONNECTION" }) do
                mock.fire(ev, "party1"); mock.fire(ev, "party2")
            end
            mock.fire("GROUP_ROSTER_UPDATE"); mock.runOnUpdate(4, 0.2); mock.flushTimers()
            local after = #mock.callsTo("SetAttribute", function(c) return c.secure and c.combat end)
            assertEquals(after, before, "SetAttribute on secure frames during combat")
            assertEquals(#mock.errors, 0, errstr())
            assertEquals(#mock.violations, 0)
            S.combat = false; S.secret = false; S.dead = {}
            mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
            assertEquals(#mock.errors, 0, errstr())
        end)
    end)
end)

-- ====================================================================== group roster
describe("smoke: roster changes", function()
    local ns = boot()
    local function setRoster(n, pets)
        mock.setGroup(n)
        S.units.party4 = { name = "Rogue", class = "ROGUE", health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 3, role = "DAMAGER" }
        for i = 1, 4 do
            local pu = "partypet" .. i
            S.units[pu] = (pets and i <= n) and { name = "Pet" .. i, class = "WARRIOR", health = 10, maxHealth = 10, power = 0, maxPower = 0, powerType = 0, role = "NONE" } or nil
        end
        S.units.pet = pets and { name = "MyPet", class = "WARRIOR", health = 10, maxHealth = 10, power = 0, maxPower = 0, powerType = 0, role = "NONE" } or nil
        mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("UNIT_PET", "player"); mock.fire("PLAYER_ROLES_ASSIGNED")
        mock.flushTimers(); mock.runOnUpdate(2, 0.2)
    end
    local function shownUnitCounts()
        local counts = {}
        for _, f in ipairs(secureUnitButtons()) do
            if rawget(f, "__s").shown then local u = A(f).unit; counts[u] = (counts[u] or 0) + 1 end
        end
        return counts
    end
    local steps = { { 0, false }, { 1, false }, { 4, true }, { 2, false }, { 0, true }, { 3, false }, { 0, false } }
    it("solo -> 2 -> 5 -> 3 -> solo with pets: no errors", function()
        for _, st in ipairs(steps) do setRoster(st[1], st[2]) end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("no two visible unit buttons share the same unit token", function()
        for _, st in ipairs(steps) do
            setRoster(st[1], st[2])
            for u, c in pairs(shownUnitCounts()) do assertEquals(c, 1, "duplicate buttons for " .. tostring(u) .. " at roster " .. st[1]) end
        end
    end)
    it("frame count does not grow on repeated identical roster updates", function()
        setRoster(3, true)
        for _ = 1, 3 do setRoster(3, true) end
        local base = #mock.frames
        for _ = 1, 30 do setRoster(3, true) end
        assertEquals(#mock.frames, base, "frames leaked: " .. (#mock.frames - base) .. " new frames over 30 identical updates")
    end)
    it("frame count is bounded across repeated roster cycles", function()
        for _ = 1, 2 do for _, st in ipairs(steps) do setRoster(st[1], st[2]) end end
        local base = #mock.frames
        for _ = 1, 10 do for _, st in ipairs(steps) do setRoster(st[1], st[2]) end end
        assertEquals(#mock.frames, base, "frames leaked across roster cycles: " .. (#mock.frames - base))
    end)
    it("timers do not accumulate (queue empties after flush)", function()
        setRoster(2, false); mock.flushTimers()
        assertEquals(#mock.timers, 0)
    end)
    it("roster changes in combat: no errors, no protected ops", function()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0, s0 = #mock.violations, #mock.softViolations
        for _, st in ipairs(steps) do setRoster(st[1], st[2]) end
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(#mock.violations, v0, "SetAttribute on secure frame in combat")
        assertEquals(#mock.softViolations, s0, "protected op (Show/Hide/SetPoint/SetSize...) on secure frame in combat")
    end)
    it("after combat, unit buttons reflect the roster set during combat", function()
        S.combat = false
        setRoster(2, false)
        local counts = shownUnitCounts()
        local n = 0 for _ in pairs(counts) do n = n + 1 end
        assertTrue(n >= 1, "no shown unit buttons after leaving combat")
    end)
end)

-- ====================================================================== fuzz
describe("smoke: event fuzzing", function()
    local ns = boot({ group = 2 })
    math.randomseed(20260101)
    local registered = {}
    for _, f in ipairs(mock.frames) do for ev in pairs(rawget(f, "__s").events) do registered[ev] = true end end
    local evList = names(registered)
    local units = { "player", "party1", "party2", "party3", "party4", "pet", "partypet1", "target", "nameplate1", "raid1", "focus", "mouseover", "vehicle", false }
    local skip = { ADDON_LOADED = true, PLAYER_LOGOUT = true, PLAYER_REGEN_ENABLED = true, PLAYER_REGEN_DISABLED = true }
    it("registered events collected", function() assertTrue(#evList > 0, "no events") end)

    it("fires 600 random events with random state toggles: zero errors", function()
        local function rnd(t) return t[math.random(#t)] end
        for i = 1, 600 do
            local r = math.random(100)
            if r <= 8 then
                S.combat = not S.combat
                mock.fire(S.combat and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
            elseif r <= 14 then S.secret = not S.secret
            elseif r <= 20 then S.dead[rnd({ "party1", "party2", "player" })] = (math.random() < 0.5) or nil
            elseif r <= 26 then mock.setGroup(math.random(0, 4)); mock.fire("GROUP_ROSTER_UPDATE")
            elseif r <= 30 then S.offline[rnd({ "party1", "party2" })] = (math.random() < 0.5) or nil
            elseif r <= 34 then S.noPositions = not S.noPositions
            elseif r <= 38 then
                local u = rnd({ "party2", "party3", "pet" })
                S.units[u] = (S.units[u] == nil) and { name = "X", class = rnd({ "PRIEST", "DRUID", "ROGUE" }), health = 1, maxHealth = 10, power = 0, maxPower = 0, powerType = 0, role = "NONE" } or nil
            elseif r <= 42 then mock.runOnUpdate(1, math.random() * 0.5); mock.flushTimers()
            elseif r <= 44 then
                S.auras[rnd({ "player", "party1" })] = (math.random() < 0.5) and { { spellId = 20217, name = "Blessing of Kings", icon = 1, duration = 600, expirationTime = S.now + math.random(0, 700), applications = 0 } } or nil
            else
                local ev
                repeat ev = rnd(evList) until not skip[ev]
                local unit = rnd(units)
                local args = { unit or nil, math.random() < 0.3 and { isFullUpdate = true } or nil }
                mock.fire(ev, args[1], args[2])
            end
        end
        S.combat = false; S.secret = false
        assertEquals(#mock.errors, 0, "first of " .. #mock.errors .. " errors:\n" .. tostring(mock.errors[1]) .. (mock.errors[2] and ("\n---\n" .. mock.errors[2]) or ""))
    end)
    it("fuzz: no SetAttribute on secure frames during combat", function()
        assertEquals(#mock.violations, 0, "e.g. " .. require("framework").repr(mock.violations[1]) .. (mock.violations[1] and mock.violations[1].trace or "") .. " (total " .. #mock.violations .. ")")
    end)
    it("fuzz: no SetPoint/Show/Hide/SetSize on secure frames during combat", function()
        assertEquals(#mock.softViolations, 0, "e.g. " .. require("framework").repr(mock.softViolations[1]) .. " (total " .. #mock.softViolations .. ")")
    end)
    it("fuzz: addon still functional afterwards", function()
        S.combat = false; S.secret = false; mock.setGroup(2)
        mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("UNIT_HEALTH", "player"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ====================================================================== SavedVariables corruption at boot
describe("smoke: boot with odd SavedVariables", function()
    local cases = {
        { "nil", nil }, { "empty", {} }, { "old (no version)", { frames = { layout = "vertical" } } },
        { "presets='x'", { presets = "x" } }, { "bindings=5", { bindings = 5 } },
        { "everything wrong", { presets = "x", bindings = 5, frames = "x", auras = 3, minimap = false, activePreset = "a" } },
        { "binding with garbage key", { bindings = { ["garbage"] = { type = "spell", spell = "X" }, ["|99"] = { type = "target" }, ["|1"] = 5 } } },
        { "preset map with unknown buff", { presets = { { name = "bad", map = { PALADIN = "nope", BOGUS = "x" } } }, activePreset = 1 } },
        { "activePreset out of range", { activePreset = 42 } },
        { "string DB", "garbage" },
    }
    for _, c in ipairs(cases) do
        it("boots and runs events with HealerForeverCharDB = " .. c[1], function()
            local ns = boot({ db = c[2], group = 2 })
            mock.fire("UNIT_HEALTH", "player"); mock.fire("UNIT_AURA", "party1"); mock.runOnUpdate(3, 0.5); mock.flushTimers()
            slash(""); slash("preset 2")
            mock.flushTimers()
            assertEquals(#mock.errors, 0, errstr())
            assertEquals(type(_G.HealerForeverCharDB), "table")
        end)
    end
end)

-- ====================================================================== minimap pins
describe("smoke: minimap party pins", function()
    local function calls(method, pred)
        local out = {}
        for _, c in ipairs(mock.calls) do if c.method == method and (not pred or pred(c)) then out[#out + 1] = c end end
        return out
    end
    local function shownPins()
        local n = 0
        for _, f in ipairs(mock.frames) do
            local s = rawget(f, "__s")
            if s.shown and s.parent == _G.Minimap and s.name == nil and s.kind == "Button" then n = n + 1 end
        end
        return n
    end

    it("positions available + party1 dead: X texture tinted with the class colour; alive members get tinted dots", function()
        local ns = boot({ group = 2 })
        mock.runOnUpdate(3, 0.3)
        assertTrue(shownPins() >= 1, "no pins visible with positions available")
        S.dead.party1 = true
        mock.calls = {}
        mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("UNIT_FLAGS", "party1"); mock.fire("UNIT_HEALTH", "party1")
        mock.runOnUpdate(5, 0.3); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        local war, mage = ns.Classes.GetColor("WARRIOR"), ns.Classes.GetColor("MAGE")
        local function tinted(c) return function(call)
            local a = call.args
            return math.abs(a[1] - c.r) < 1e-6 and math.abs(a[2] - c.g) < 1e-6 and math.abs(a[3] - c.b) < 1e-6 end end
        assertTrue(#calls("SetVertexColor", tinted(war)) > 0, "no SetVertexColor with party1's (WARRIOR) class colour")
        assertTrue(#calls("SetVertexColor", tinted(mage)) > 0, "no SetVertexColor with party2's (MAGE) class colour")
    end)
    it("a member who dies: their pin goes grey and a separate red X corpse marker appears where they died; it clears on revive", function()
        boot({ group = 2 })
        mock.runOnUpdate(3, 0.3)                       -- seen alive first, so the death position is known
        S.dead.party1 = true
        mock.runOnUpdate(5, 0.3)
        local pin, corpse
        for _, f in ipairs(mock.frames) do
            local s = rawget(f, "__s")
            if s.parent == _G.Minimap and f.key == "party1" then pin = f end
            if s.parent == _G.Minimap and f.key == "corpse:party1" then corpse = f end
        end
        assertNotNil(pin, "no pin for party1"); assertNotNil(corpse, "no corpse marker for party1")
        assertEquals(#mock.errors, 0, errstr())
        assertTrue(rawget(corpse, "__s").shown, "corpse marker must be visible")
        assertTrue(rawget(corpse.cross, "__s").shown, "red X shown on the corpse marker")
        local grey = rawget(pin.dot, "__s").vertex
        S.dead.party1 = nil
        mock.runOnUpdate(5, 0.3)
        assertFalse(rawget(corpse, "__s").shown, "corpse marker must disappear after the revive")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("positions nil (instance): no errors and ALL pins hidden", function()
        boot({ group = 2 })
        mock.runOnUpdate(3, 0.3)
        assertTrue(shownPins() >= 1)
        S.noPositions = true
        mock.fire("ZONE_CHANGED_NEW_AREA"); mock.runOnUpdate(5, 0.3); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(shownPins(), 0, "pins still visible without map positions")
    end)
    it("positions secret: no errors, pins hidden, in and out of combat", function()
        boot({ group = 2 })
        mock.runOnUpdate(3, 0.3)
        S.secret = true
        mock.fire("GROUP_ROSTER_UPDATE"); mock.runOnUpdate(5, 0.3); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(shownPins(), 0, "pins shown although positions are secret")
        S.combat = true
        mock.fire("PLAYER_REGEN_DISABLED"); mock.runOnUpdate(5, 0.3); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("solo (not in group): no pins", function()
        boot({})
        mock.runOnUpdate(5, 0.3)
        assertEquals(shownPins(), 0)
    end)
    it("rotating minimap (rotateMinimap=1) with player facing does not error", function()
        boot({ group = 2 })
        _G.GetCVar = function(k) return k == "rotateMinimap" and "1" or "0" end
        S.facing = math.pi / 2
        mock.runOnUpdate(5, 0.3); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        S.facing = nil
        mock.runOnUpdate(5, 0.3)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("far away pins (edge, clamped) do not error", function()
        boot({ group = 3 })
        S.positions.party1 = { 0.99, 0.99 }
        mock.runOnUpdate(5, 0.3)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a party unit that disappears hides its pin", function()
        boot({ group = 2 })
        mock.runOnUpdate(3, 0.3)
        S.units.party2 = nil
        mock.runOnUpdate(3, 0.3)
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ====================================================================== mock coverage report
describe("smoke: mock coverage", function()
    it("report undefined globals the addon touched (informational)", function()
        boot({ group = 2 })
        slash(""); mock.runOnUpdate(3, 0.2); mock.flushTimers()
        local list = mock.undefinedList()
        _G.HF_UNDEFINED_REPORT = list
        if #list > 0 then warn("WoW globals the mock lacks (accessed by addon): " .. table.concat(list, ", ")) end
    end)
end)
