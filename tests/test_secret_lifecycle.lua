-- "Everything secret, OUT of combat": the real game returned a secret UnitInRange at PLAYER_LOGIN, outside combat, and a
-- truth test on it crashed the addon. The mock cannot make a truth test raise, so (a) every listed API returns a secret
-- sentinel that raises on compare/arith/concat/index, (b) a source scan flags truth tests on unguarded API results.
local L = require("loader")
local mock = require("wow_mock")
local Scan = require("secret_scan")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role, hp)
    return { name = name, class = class, health = hp or 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" }
end

-- ======================================================================== source scan
describe("secret scan: truth tests on unguarded API results", function()
    it("the scanner flags the bad patterns (self-test)", function()
        local bad = {
            "local r = UnitInRange(unit)\nif r then\n  x()\nend", "local r = UnitInRange(unit)\nlocal y = r and 1 or 2", "local r = UnitIsVisible(unit)\nif not r then return end",
            "if UnitInRange(unit) then x() end", "local v = x and not UnitIsDeadOrGhost(unit)", "local d = UnitIsDeadOrGhost(unit)\nreturn d or false",
            "local t = UnitThreatSituation(unit)\nelseif t then", "local c = UnitIsConnected(unit)\nif c then end",
        }
        for _, src in ipairs(bad) do assertTrue(#Scan.scan("x", "x.lua", src) > 0, "should flag: " .. src) end
    end)
    it("and accepts guarded or non-truth uses (self-test)", function()
        local good = {
            "local r = UnitInRange(unit)\nif issecret(r) then return end\nif r then x() end",
            "local r = UnitInRange(unit)\nif not issecret(r) and r == false then x() end",
            "local r = UnitIsVisible and UnitIsVisible(unit)\nif issecret(r) then return end",
            "local ok = pcall(UnitInRange, unit)", "local r = UnitInRange(unit)\nlocal s = tostring(1)", "local d = flag(UnitIsDeadOrGhost(unit))",
            "local t = UnitThreatSituation(unit)\nif issecret(t) then return end\nlocal x = t and 1",
        }
        for _, src in ipairs(good) do
            local f = Scan.scan("x", "x.lua", src)
            assertEquals(#f, 0, "should be accepted: " .. src .. " -> " .. (f[1] and f[1].why or ""))
        end
    end)
    it("no module takes a truth test on an unguarded secret-capable API result", function()
        local all = {}
        for _, rel in ipairs(toc.files) do
            if rel:lower():match("%.lua$") then
                for _, f in ipairs(Scan.scan(L.path(rel), rel, L.readFile(L.path(rel)))) do all[#all + 1] = f.file .. ":" .. f.line .. ": " .. f.why .. "\n      " .. f.text end
            end
        end
        assertEquals(#all, 0, table.concat(all, "\n"))
    end)
end)

-- ======================================================================== mock sanity
describe("secret mode: the mock returns secrets regardless of combat", function()
    it("every listed API returns a secret sentinel with secretAll, out of combat", function()
        mock.install(); S = mock.state
        S.secretAll = true; S.combat = false
        S.units.party1 = unit("T", "WARRIOR", "TANK")
        for name, fn in pairs({ UnitInRange = function() return UnitInRange("party1") end, UnitIsVisible = function() return UnitIsVisible("party1") end,
            IsSpellInRange = function() return C_Spell.IsSpellInRange("X", "party1") end, UnitIsUnit = function() return UnitIsUnit("party1", "target") end,
            UnitIsDeadOrGhost = function() return UnitIsDeadOrGhost("party1") end, UnitIsConnected = function() return UnitIsConnected("party1") end,
            UnitThreatSituation = function() return UnitThreatSituation("party1") end, UnitGroupRolesAssigned = function() return UnitGroupRolesAssigned("party1") end,
            UnitHealth = function() return UnitHealth("party1") end, UnitPower = function() return UnitPower("party1") end,
            UnitAffectingCombat = function() return UnitAffectingCombat("party1") end }) do
            assertTrue(mock.isSecret((fn())), name .. " must return a secret")
        end
        S.auras.party1 = { { spellId = 1, name = "A", icon = 1, duration = 1, expirationTime = 5, auraInstanceID = 3 } }
        local a = C_UnitAuras.GetUnitAuras("party1", "HELPFUL")[1]
        assertTrue(mock.isSecret(a.name)); assertTrue(mock.isSecret(a.expirationTime)); assertEquals(a.auraInstanceID, 3)
        assertFalse(InCombatLockdown(), "this is OUT of combat")
    end)
    it("a secret sentinel raises on arithmetic, comparison, concatenation, indexing and tostring", function()
        local s = mock.newSecret()
        for _, f in ipairs({ function() return s + 1 end, function() return s < 1 end, function() return s .. "x" end, function() return s.x end, function() return tostring(s) end,
            function() return string.format("%d", s) end, function() return -s end }) do
            assertFalse((pcall(f)))
        end
    end)
end)

-- ======================================================================== lifecycle
local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER"); S.units.party3 = unit("Mage", "MAGE", "DAMAGER")
    S.units.partypet1 = unit("Pet", "HUNTER"); S.units.pet = unit("MyPet", "WARRIOR")
    S.secretAll = opts.secretFromStart ~= false
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    return ns
end
local function login(ns)
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(3)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
end
local function fireAll(units)
    for _, u in ipairs(units) do
        for _, ev in ipairs({ "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_UPDATE", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER", "UNIT_HEAL_PREDICTION", "UNIT_AURA",
            "UNIT_THREAT_SITUATION_UPDATE", "UNIT_CONNECTION", "UNIT_FLAGS", "UNIT_NAME_UPDATE", "UNIT_IN_RANGE_UPDATE", "UNIT_PET" }) do mock.fire(ev, u) end
    end
end
local UNITS = { "player", "party1", "party2", "party3", "party4", "pet", "partypet1" }

describe("secret lifecycle: everything secret, out of combat", function()
    it("login, roster, events, range ticks and layout raise no errors", function()
        local ns = boot(); login(ns)
        assertEquals(#mock.errors, 0, errstr())
        S.auras.player = { { spellId = 20217, name = "Blessing of Kings", icon = 1, duration = 600, expirationTime = S.now + 300, isHelpful = true, auraInstanceID = 11, sourceUnit = "player" } }
        S.auras.party1 = { { spellId = 7001, name = "Poison", icon = 2, duration = 30, expirationTime = S.now + 10, isHarmful = true, isHelpful = false, dispelName = "Poison", auraInstanceID = 21 },
            { spellId = 7002, name = "Bleed", icon = 3, duration = 30, expirationTime = S.now + 20, isHarmful = true, isHelpful = false, auraInstanceID = 22 } }
        fireAll(UNITS)
        mock.fire("PLAYER_TARGET_CHANGED"); mock.fire("PLAYER_ROLES_ASSIGNED"); mock.fire("SPELLS_CHANGED"); mock.fire("MODIFIER_STATE_CHANGED", "LSHIFT", 1)
        mock.flushTimers(); mock.runOnUpdate(20, 0.3); mock.tick(); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0); assertEquals(#mock.softViolations, 0)
    end)
    it("every unit button, border, range visual and aura row survives repeated updates", function()
        local ns = boot(); login(ns)
        for _ = 1, 5 do
            for _, b in ipairs(ns.UnitFrames.buttons) do ns.UnitFrames:UpdateAll(b); ns.UnitFrames:UpdateRange(b) end
            mock.runOnUpdate(4, 0.3)
        end
        ns:Changed("frames"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("tooltips (bar and aura icons) under secret values", function()
        local ns = boot(); login(ns)
        S.auras.party1 = { { spellId = 7001, name = "Poison", icon = 2, duration = 30, expirationTime = S.now + 10, isHarmful = true, isHelpful = false, dispelName = "Poison", auraInstanceID = 21 } }
        mock.fire("UNIT_AURA", "party1"); mock.flushTimers()
        local gt = _G.GameTooltip
        gt.SetOwner = function() end; gt.Show = function() end; gt.Hide = function() end
        gt.AddLine = function() end; gt.AddDoubleLine = function() end; gt.AddTexture = function() end
        for _, u in ipairs({ "player", "party1", "party2" }) do
            local b = ns.UnitFrames.byUnit[u]
            mock.runFrameScript(b, "OnEnter"); mock.runFrameScript(b, "OnLeave")
            ns.UnitFrames:ShowTooltip(b)
        end
        local icon = ns.UnitFrames.byUnit.party1.debuffIcons[1]
        mock.runFrameScript(icon, "OnEnter"); mock.runFrameScript(icon, "OnLeave")
        mock.runOnUpdate(5, 0.3)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("minimap pins and the minimap button under secret values", function()
        local ns = boot(); login(ns)
        S.dead.party1 = true
        mock.runOnUpdate(10, 0.3); mock.fire("PLAYER_ROLES_ASSIGNED"); mock.fire("UNIT_AURA", "party1")
        local mb
        for _, f in ipairs(mock.frames) do if st(f).name == "HealerForeverMinimapButton" then mb = f end end
        assertNotNil(mb)
        for _, sname in ipairs({ "OnEnter", "OnLeave", "OnDragStart", "OnDragStop" }) do mock.runFrameScript(mb, sname) end
        _G.GameTooltip.SetOwner = function() end; _G.GameTooltip.Show = function() end; _G.GameTooltip.AddLine = function() end
        for _, f in ipairs(mock.frames) do
            if st(f).parent == _G.Minimap and f.key then mock.runFrameScript(f, "OnEnter"); mock.runFrameScript(f, "OnLeave") end
        end
        mock.runOnUpdate(5, 0.3)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("buff buttons, smart and tank buttons, extras and /hf debug commands under secret values", function()
        local ns = boot(); login(ns)
        local Fx = require("fixtures")
        Fx.seed(ns, { presets = 2 })
        ns.Presets.AddExtra(ns.db.presets[ns.db.activePreset], "Oath of Light", { TANK = true, HEALER = true, DAMAGER = true, SELF = true }, false)
        ns:Changed("presets"); mock.flushTimers(); mock.tick(); mock.flushTimers()
        for _, cmd in ipairs({ "debug buffs", "debug auras", "errors", "profile", "version", "preset 1" }) do
            local ok, err = pcall(_G.SlashCmdList.HEALERFOREVER, cmd)
            assertTrue(ok, cmd .. ": " .. tostring(err))
        end
        mock.fire("UNIT_AURA", "party2"); mock.fire("UNIT_IN_RANGE_UPDATE", "party1"); mock.flushTimers(); mock.tick(); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("every options pane opens and every control can be driven", function()
        local ns = boot(); login(ns)
        for _, key in ipairs({ "general", "buffs", "spells", "binds", "frames", "auras", "minimap" }) do
            local ok, err = pcall(ns.Options.Show, ns.Options, key)
            assertTrue(ok, key .. ": " .. tostring(err))
        end
        mock.flushTimers()
        local clicked = 0
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if (s.kind == "CheckButton" or s.kind == "Button") and s.scripts.OnClick and not s.secure and s.shown then
                s.checked = not s.checked
                pcall(s.scripts.OnClick, f, "LeftButton"); clicked = clicked + 1
            end
        end
        mock.flushTimers(); mock.runOnUpdate(5, 0.3)
        assertTrue(clicked > 20)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("secrets that begin AFTER a normal login (flipped on mid-session) are handled too", function()
        local ns = boot({ secretFromStart = false }); login(ns)
        fireAll(UNITS); mock.runOnUpdate(5, 0.3)
        S.secretAll = true
        fireAll(UNITS); mock.fire("PLAYER_TARGET_CHANGED"); mock.runOnUpdate(10, 0.3); mock.tick(); mock.flushTimers()
        S.secretAll = false
        fireAll(UNITS); mock.runOnUpdate(5, 0.3)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("everything secret AND in combat AND hostile ticks: still no error, no protected calls", function()
        local ns = boot(); login(ns)
        S.combat = true; S.secret = true; mock.fire("PLAYER_REGEN_DISABLED")
        fireAll(UNITS); mock.runOnUpdate(10, 0.3); mock.tick(); mock.flushTimers()
        S.combat = false; S.secret = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
    end)
    it("save and reload round trip works from a secret session (logout path)", function()
        local ns = boot(); login(ns)
        ns.db.frames.layout = "vertical"
        mock.fire("PLAYER_LOGOUT")
        assertEquals(HealerForeverCharDB.frames.layout, "vertical")
        assertEquals(#mock.errors, 0, errstr())
    end)
end)
