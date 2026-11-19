-- Aura button mouse setup never runs in combat. Real client log (count 80): "ADDON_ACTION_BLOCKED: Button:SetPropagateMouseMotion()",
-- in combat, from the AuraContainer initializeFrame -> configureFrame "mouse" step: the game creates aura buttons mid-fight and the mouse
-- setters are blocked there. Fix: applyMouse defers in combat (weak pending table, flushed by ns:AfterCombat("aura-mouse")), skips a
-- frame already in the wanted state, Auras.Prepare defers in combat, and the XML template sets clicks off / motion on at creation.
-- The mock blocks every mouse setter on aura buttons in combat (M.blocked + M.errors) and S.auraPoolLazy grows the pool mid-fight.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role) return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" } end

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    if opts.containers ~= false then mock.enableContainers() end
    S.auraPoolLazy = opts.lazy ~= false and opts.containers ~= false
    S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER")
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    if opts.cfg then opts.cfg(ns.db.auras); ns:Changed("auras") end
    mock.setGroup(3)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.3); mock.flushTimers()
    return ns
end
local function auras(u, nBuff, nDebuff)
    local list = {}
    for i = 1, nBuff do list[#list + 1] = { spellId = 6000 + i, name = "Buff" .. i, icon = 100 + i, duration = 300, expirationTime = S.now + 200, isHelpful = true, isHarmful = false, auraInstanceID = 100 + i, sourceUnit = "player" } end
    for i = 1, nDebuff do list[#list + 1] = { spellId = 7000 + i, name = "Debuff" .. i, icon = 300 + i, duration = 60, expirationTime = S.now + 40, isHarmful = true, isHelpful = false, auraInstanceID = 200 + i } end
    S.auras[u] = list
end
local function frames(ns, u, kind)
    local c = ns.UnitFrames.byUnit[u].auraContainers[kind]
    return rawget(c.frame, "__container").groups[c.kind].frames
end
local function allFrames(ns)
    local out = {}
    for _, u in ipairs({ "player", "party1", "party2" }) do
        local b = ns.UnitFrames.byUnit[u]
        if b and b.auraContainers then
            for _, kind in ipairs({ "buff", "debuff" }) do for _, f in ipairs(frames(ns, u, kind)) do out[#out + 1] = { f = f, kind = kind, u = u } end end
        end
    end
    return out
end
local function enterCombat() S.combat = true; mock.fire("PLAYER_REGEN_DISABLED"); mock.flushTimers() end
local function leaveCombat() S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers() end
local MOUSE_METHODS = { EnableMouse = true, SetPropagateMouseClicks = true, SetPropagateMouseMotion = true, SetMouseClickEnabled = true, SetMouseMotionEnabled = true }
local function mouseCallsInCombat()
    local n = 0
    for _, c in ipairs(mock.calls) do if c.combat and MOUSE_METHODS[c.method] then n = n + 1 end end
    return n
end

describe("mock: aura buttons block mouse setters in combat; the pool can grow mid-fight", function()
    it("every mouse setter on an aura button is blocked in combat (recorded, state unchanged) and works out of combat", function()
        local ns = boot({ lazy = false })
        local f = frames(ns, "party1", "buff")[1]
        assertNotNil(f)
        local snap = {}
        for _, k in ipairs({ "mouse", "mouseClick", "mouseMotion", "propagateMotion", "propagateClicks" }) do snap[k] = st(f)[k] end
        S.combat = true
        for m in pairs(MOUSE_METHODS) do f[m](f, true) end
        for k, v in pairs(snap) do assertEquals(st(f)[k], v, k .. " changed by a blocked call") end
        assertEquals(#mock.blocked, 5)
        local n = 0
        for _, e in ipairs(mock.errors) do if e:find("^ADDON_ACTION_BLOCKED: Button:") then n = n + 1 end end
        assertEquals(n, 5)
        assertTrue(st(f).propagateMotion ~= true and st(f).propagateClicks ~= true, "blocked calls changed nothing")
        S.combat = false
        f:SetPropagateMouseMotion(true); assertTrue(st(f).propagateMotion)
        assertEquals(#mock.blocked, 5)
    end)
    it("S.auraPoolLazy: no buttons until auras exist; new auras in combat create buttons and run initializeFrame mid-fight", function()
        local ns = boot()
        assertEquals(#frames(ns, "party1", "buff"), 0)
        enterCombat()
        auras("party1", 2, 1); mock.fire("UNIT_AURA", "party1"); mock.flushTimers()
        assertEquals(#frames(ns, "party1", "buff"), 2); assertEquals(#frames(ns, "party1", "debuff"), 1)
        assertNotNil(frames(ns, "party1", "buff")[1].wiredIcon, "initializeFrame ran (icon wired)")
        leaveCombat()
    end)
end)

for _, cfgName in ipairs({ "default", "inside", "tooltips off" }) do
    local cfgFn = cfgName == "inside" and function(a) a.buffPosition = "inside"; a.debuffPosition = "inside" end
        or cfgName == "tooltips off" and function(a) a.tooltipIcons = false end or nil
    describe("aura mouse in combat (" .. cfgName .. " config)", function()
        it("buttons created in combat get NO mouse setter call, are pending, nothing is blocked; after combat they get the wanted state", function()
            local ns = boot({ cfg = cfgFn })
            enterCombat()
            auras("party1", 3, 2); auras("party2", 1, 1)
            mock.fire("UNIT_AURA", "party1"); mock.fire("UNIT_AURA", "party2"); mock.flushTimers()
            local list = allFrames(ns)
            assertTrue(#list >= 7, "buttons created mid-fight: " .. #list)
            for _, it_ in ipairs(list) do assertNil(st(it_.f).mouseCalls, it_.u .. " " .. it_.kind .. " mouse setter called in combat") end
            assertEquals(ns.Auras.MousePendingCount(), #list)
            assertEquals(#mock.blocked, 0, "blocked: " .. (mock.blocked[1] and mock.blocked[1].method or ""))
            assertEquals(mouseCallsInCombat(), 0)
            assertEquals(#mock.errors, 0, errstr())
            leaveCombat()
            assertEquals(ns.Auras.MousePendingCount(), 0)
            local a = ns.db.auras
            for _, it_ in ipairs(list) do
                local s = st(it_.f)
                local pos = it_.kind == "buff" and a.buffPosition or a.debuffPosition
                assertEquals(s.mouseClick, false, "clicks fall through")
                assertEquals(s.mouseMotion, a.tooltipIcons and true or false, "motion = tooltipIcons")
                assertEquals(s.propagateMotion, pos == "inside", it_.kind .. " propagation = inside")
            end
            assertEquals(#mock.blocked, 0); assertEquals(#mock.errors, 0, errstr())
        end)
        it("a button already in the wanted state is skipped: re-configuring (out of combat or in) makes no further mouse calls", function()
            local ns = boot({ cfg = cfgFn })
            auras("party1", 2, 2); mock.fire("UNIT_AURA", "party1"); mock.flushTimers()
            local list = allFrames(ns)
            assertTrue(#list >= 4)
            local before = {}
            for i, it_ in ipairs(list) do before[i] = st(it_.f).mouseCalls or 0; assertTrue(before[i] > 0, "configured once") end
            -- a geometry change that keeps the mouse state re-runs configureFrame on every button
            ns.db.auras.buffSize = ns.db.auras.buffSize + 2; ns.db.auras.debuffSize = ns.db.auras.debuffSize + 2
            ns:Changed("auras"); mock.flushTimers(); mock.refreshContainers()
            for i, it_ in ipairs(list) do assertEquals(st(it_.f).mouseCalls or 0, before[i], "no repeated mouse calls on " .. it_.kind) end
            assertEquals(ns.Auras.MousePendingCount(), 0)
            -- in combat a matching button is not even queued
            enterCombat()
            ns.Auras.FlushMouse()
            assertEquals(ns.Auras.MousePendingCount(), 0); assertEquals(#mock.blocked, 0)
            leaveCombat()
        end)
        it("a mouse option changed later is applied to existing buttons (the skip only matches the SAME state)", function()
            local ns = boot({ cfg = cfgFn })
            auras("party1", 2, 0); mock.fire("UNIT_AURA", "party1"); mock.flushTimers()
            local f = frames(ns, "party1", "buff")[1]
            local want = not ns.db.auras.tooltipIcons
            ns.db.auras.tooltipIcons = want; ns:Changed("auras"); mock.flushTimers(); mock.refreshContainers()
            assertEquals(st(f).mouseMotion, want)
        end)
    end)
end

describe("aura mouse: Auras.Prepare in combat", function()
    it("container path: Prepare in combat makes no mouse call and nothing is blocked; it runs after combat", function()
        local ns = boot({ lazy = false })
        local b = ns.UnitFrames.byUnit.party1
        enterCombat()
        local n0 = #mock.calls
        ns.db.auras.tooltipIcons = not ns.db.auras.tooltipIcons
        ns.Auras.Prepare(b)
        for i = n0 + 1, #mock.calls do assertFalse(MOUSE_METHODS[mock.calls[i].method] ~= nil, "mouse call in combat: " .. mock.calls[i].method) end
        assertEquals(#mock.blocked, 0)
        leaveCombat()
        for _, f in ipairs(frames(ns, "party1", "buff")) do assertEquals(st(f).mouseMotion, ns.db.auras.tooltipIcons) end
        assertEquals(#mock.errors, 0, errstr())
    end)
    for _, pos in ipairs({ "top", "inside" }) do
        it("fallback path (" .. pos .. "): Prepare in combat makes no mouse call; the icons get their mouse setup when combat ends", function()
            local ns = boot({ containers = false, cfg = function(a) a.buffPosition = pos; a.tooltipIcons = true end })
            local b = ns.UnitFrames.byUnit.party1
            assertNil(b.auraContainers, "fallback path")
            -- reset the recorded state so the after-combat run is visible
            for _, icon in ipairs(b.buffIcons or {}) do local s = st(icon); s.mouse, s.propClicks, s.propMotion = nil, nil, nil end
            enterCombat()
            local n0 = #mock.calls
            ns.Auras.Prepare(b)
            for i = n0 + 1, #mock.calls do assertFalse(MOUSE_METHODS[mock.calls[i].method] ~= nil, "mouse call in combat: " .. mock.calls[i].method) end
            for _, icon in ipairs(b.buffIcons or {}) do assertNil(st(icon).mouse, "untouched in combat") end
            leaveCombat()
            assertTrue(#(b.buffIcons or {}) > 0, "fallback icons exist")
            for _, icon in ipairs(b.buffIcons) do
                assertNotNil(st(icon).mouse, "set after combat")
                if pos == "inside" then assertTrue(st(icon).propClicks, "inside: clicks propagate") end
            end
            assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
        end)
    end
end)

describe("aura mouse: the XML template and the source", function()
    it("Auras.xml: HealerForeverAuraButtonTemplate sets enableMouseClicks=\"false\" and enableMouseMotion=\"true\" at creation", function()
        local xml = L.readFile(L.path("Frames/Auras.xml"))
        local tag = xml:match("<AuraButton%s+name=\"HealerForeverAuraButtonTemplate\"[^>]*>")
        assertNotNil(tag, "template tag")
        assertTrue(tag:find('enableMouseClicks="false"', 1, true) ~= nil, tag)
        assertTrue(tag:find('enableMouseMotion="true"', 1, true) ~= nil, tag)
    end)
    it("Auras.lua calls the mouse setters only inside setMouseNow, Auras.Prepare (combat-guarded) and createZone (creation time)", function()
        local src = L.readFile(L.path("Frames/Auras.lua"))
        local allowed = { setMouseNow = true, ["Auras.Prepare"] = true, createZone = true }
        local current, bad, seen = "?", {}, {}
        local n = 0
        for line in (src .. "\n"):gmatch("(.-)\n") do
            n = n + 1
            local fname = line:match("^local function ([%w_%.:]+)") or line:match("^function ([%w_%.:]+)")
            if fname then current = fname end
            if not line:match("^%s*%-%-") then
                for m in pairs(MOUSE_METHODS) do
                    if line:find(":" .. m .. "(", 1, true) then
                        seen[current] = true
                        if not allowed[current] then bad[#bad + 1] = n .. " (" .. current .. "): " .. m end
                    end
                end
            end
        end
        assertEquals(#bad, 0, table.concat(bad, "\n"))
        assertTrue(seen.setMouseNow and seen["Auras.Prepare"], "the scan found the expected call sites")
    end)
end)
