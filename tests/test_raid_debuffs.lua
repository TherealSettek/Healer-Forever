-- Dispellable debuffs on the raid bars (Phase 3): one game-drawn icon AuraContainer per raid button (filter
-- HARMFUL|RAID_PLAYER_DISPELLABLE, max, icon size from Reserves / DebuffIconSize, raid template without mouse), its unit
-- (token in the raid layout, "none" otherwise, never set in combat, a new player behind a token re-set after combat);
-- the bar glow: a per-bar glow container with one invisible carrier (HealerForeverRaidGlowButtonTemplate) whose plain
-- holder frame owns the glow texture handed to the game once (AddDispelTypeTexture, Border, showWhenHarmful); "glow"
-- (icon container "none"), "icons" (glow never attached), the fallback to icons when the glow fails (logged once,
-- re-laid out), the outset vs spacing, templates, frames the game creates mid-fight (no mouse / protected calls), and
-- the preview (RS.Render) using the same display mode.
local mock = require("wow_mock")
local H = require("raid_helpers")
local L = require("loader")

if not L.parseToc() then it("TOC present", function() error("no TOC") end) return end
local st, errstr = H.st, H.errstr

local function clean(label)
    assertEquals(#mock.errors, 0, (label or "") .. " errors:\n" .. errstr())
    assertEquals(H.violations(), "", (label or "") .. " protected calls in combat")
    assertEquals(#mock.blocked, 0, (label or "") .. " blocked calls")
end

local function boot(opts)
    opts = opts or {}
    local ns = H.boot({ group = 4, raid = opts.raid == nil and 10 or opts.raid, setup = opts.setup, afterLoad = opts.afterLoad })
    return ns, ns.RaidFrames, ns.RaidStyle
end
local function container(button) return rawget(button.debuffContainer.frame, "__container") end
local function debuff(id, name, dispel)
    return { spellId = id, auraInstanceID = id, name = name, icon = 2000 + id, duration = 20, expirationTime = mock.state.now + 15,
        applications = 0, isHarmful = true, isHelpful = false, dispelName = dispel, sourceUnit = "boss1" }
end
local function setUnitCalls(c, combat)
    local out = {}
    for _, x in ipairs(mock.containerCalls) do
        if x.container == c and x.method == "SetUnit" and (combat == nil or x.combat == combat) then out[#out + 1] = x.args[1] end
    end
    return out
end

describe("raid debuffs: containers", function()
    it("one debuff container per raid button: dispellable filter, max = debuffs.max, icon size from Reserves", function()
        local ns, RF = boot()
        clean()
        local cfg = ns.db.raid
        local res = ns.RaidLayout.Reserves(cfg, 0)
        assertEquals(res.isz, ns.RaidLayout.DebuffIconSize(cfg.width, cfg.debuffs.max, math.min(cfg.debuffs.size, cfg.height - 2)))
        for i, b in ipairs(RF.buttons) do
            assertNotNil(b.debuffContainer, "raid" .. i)
            local c = container(b)
            local n = 0
            for _, g in pairs(c.groups) do
                n = n + 1
                assertEquals(g.filter, "HARMFUL|RAID_PLAYER_DISPELLABLE")
                assertEquals(g.maxFrameCount, 3)
            end
            assertEquals(n, 1, "one aura group")
            assertEquals(c.layout.elementWidth or c.layout.elementHeight, res.isz)
            assertFalse(st(b.debuffContainer.frame).secure and true or false)
        end
    end)
    it("changing max / size re-configures the containers (out of combat)", function()
        local ns, RF = boot()
        ns.db.raid.debuffs.max = 1; ns.db.raid.debuffs.size = 14; ns.db.raid.width = 100
        ns:Changed("raid"); mock.flushTimers()
        local c = container(RF.buttons[3])
        for _, g in pairs(c.groups) do assertEquals(g.maxFrameCount, 1) end
        local res = ns.RaidLayout.Reserves(ns.db.raid, RF.buttons[3].buffMarkers or 0)
        assertEquals(c.layout.elementHeight, res.isz)
        assertEquals(res.isz, 14)
        clean()
    end)
    it("unit: the raid token while the raid layout is active, 'none' in party mode and for empty slots", function()
        local _, RF = boot()
        assertEquals(container(RF.buttons[3]).unit, "raid3")
        assertEquals(container(RF.buttons[20]).unit, "none", "no raid20 in a 10-man raid")
        H.roster(0)
        for _, b in ipairs(RF.buttons) do assertEquals(container(b).unit, "none") end
        clean()
    end)
    it("debuffs.show off: every container points at 'none'", function()
        local ns, RF = boot()
        ns.db.raid.debuffs.show = false; ns:Changed("raid"); mock.flushTimers()
        assertEquals(container(RF.buttons[3]).unit, "none")
        clean()
    end)
    it("never SetUnit in combat: roster and layout changes wait; a new player behind a token is re-set after combat", function()
        local _, RF = boot()
        H.enterCombat()
        mock.state.guids = { raid3 = "Player-9-someone-else" }
        H.roster(12)
        H.roster(0)
        assertEquals(#setUnitCalls(container(RF.buttons[3]), true), 0, "SetUnit in combat")
        for _, b in ipairs(RF.buttons) do assertEquals(#setUnitCalls(container(b), true), 0) end
        H.leaveCombat()
        assertEquals(container(RF.buttons[3]).unit, "none", "left the raid: none after combat")
        -- back in a raid; a different player behind raid3 while in combat
        H.roster(10)
        assertEquals(container(RF.buttons[3]).unit, "raid3")
        mock.containerCalls = {}
        H.enterCombat()
        mock.state.guids = { raid3 = "Player-9-another-one" }
        H.roster(10)
        assertEquals(#setUnitCalls(container(RF.buttons[3])), 0)
        H.leaveCombat()
        local calls = setUnitCalls(container(RF.buttons[3]), false)
        assertDeepEquals(calls, { "none", "raid3" }, "re-pointed after combat for the new player")
        clean()
    end)
end)

local function glowC(b) return b.glowContainer and rawget(b.glowContainer.frame, "__container") end
local function group(c) return c and select(2, next(c.groups)) end
local function carrier(b) local g = group(glowC(b)); return g and g.frames[1] end
local function addCalls(tex)
    local n = 0
    for _, x in ipairs(mock.containerCalls) do
        if x.method == "button:AddDispelTypeTexture" and x.args[1] == tex then n = n + 1 end
    end
    return n
end
local function glowLogCount(ns)
    local n = 0
    for _, e in ipairs(ns.db.errorLog or {}) do if e.label == "raid-glow" then n = n + (e.count or 1) end end
    return n
end
-- is f inside (a descendant of) root?
local function inside(f, root)
    local p, guard = f, 0
    while type(p) == "table" and guard < 30 do
        if p == root then return true end
        p = rawget(p, "__s") and rawget(p, "__s").parent
        guard = guard + 1
    end
    return false
end

describe("raid debuffs: the bar glow (one invisible carrier per bar, the glow texture in our holder)", function()
    it("glowIcons: per bar a glow container with ONE carrier (raid glow template, dispellable filter); its holder's texture is registered once", function()
        local ns, RF = boot()
        assertTrue(RF.glowSupported)
        for _ = 1, 3 do ns:Changed("raid"); mock.flushTimers() end
        H.roster(12); H.roster(10)
        for i, b in ipairs(RF.buttons) do
            local label = "raid" .. i
            local g = group(glowC(b))
            assertNotNil(g, label .. " glow container")
            assertEquals(g.filter, "HARMFUL|RAID_PLAYER_DISPELLABLE", label)
            assertEquals(g.maxFrameCount, 1, label .. " max 1 carrier")
            assertEquals(g.templateNames[1], "HealerForeverRaidGlowButtonTemplate", label)
            local c = carrier(b)
            assertNotNil(c, label .. " carrier")
            assertTrue(b.glowHost == c, label .. " glow host is the carrier")
            local holder = b.glowHolder
            assertNotNil(holder, label .. " holder")
            assertTrue(st(holder).parent == c, label .. " holder is a child of the carrier (hides with it)")
            assertFalse(st(holder).secure and true or false)
            assertEquals(st(holder).kind, "Frame")
            local opts = c.dispelTextures[holder.glow]
            assertNotNil(opts, label .. " glow texture handed to the game")
            assertEquals(opts.style, Enum.CustomAuraButtonDispelTypeTextureStyle.Border)
            assertEquals(opts.showWhenHarmful, true)
            assertEquals(addCalls(holder.glow), 1, label .. " registered once")
            -- the carrier gets nothing else wired: no icon / cooldown / timer / count, no mouse calls
            assertNil(c.wiredIcon); assertNil(c.wiredCooldown); assertNil(c.wiredTime)
            assertEquals(st(c).mouseCalls or 0, 0)
            -- above the health bar, just under the name / number text
            assertEquals(holder:GetFrameLevel(), b.textFrame:GetFrameLevel() - 1, label .. " holder level")
            assertTrue(holder:GetFrameLevel() > b.health:GetFrameLevel(), label .. " above the bar")
        end
        local b3 = RF.buttons[3]
        assertEquals(glowC(b3).unit, "raid3")
        assertEquals(st(b3.glowFrame).alpha, 1, "glowIcons: our glow frame visible")
        assertEquals(st(b3.debuffZone).alpha, 1, "glowIcons: our icon zone visible")
        assertTrue(st(b3.glowHolder).shown)
        assertFalse(st(b3.dispelGlow).shown, "RS.Build's own glow texture is the preview's only")
        clean()
    end)
    it("the game re-initialising the carrier (pooled frame reused, also in combat) keeps its one holder", function()
        local _, RF = boot()
        local b = RF.buttons[2]
        local c, holder = carrier(b), b.glowHolder
        local init = group(glowC(b)).initializeFrame
        assertNotNil(init)
        local frames = #mock.frames
        for _ = 1, 3 do init(c) end
        H.enterCombat(); init(c); H.leaveCombat()
        assertTrue(b.glowHolder == holder, "same holder")
        assertEquals(addCalls(holder.glow), 1, "glow registered again on re-init")
        assertEquals(#mock.frames, frames, "no new frames")
        clean()
    end)
    it("icons: no glow container, carrier or holder; switching to glowIcons creates them (out of combat), back to icons sets them to 'none'", function()
        local ns, RF = boot({ afterLoad = function(n) n.db.raid.debuffs.display = "icons" end })
        for _, b in ipairs(RF.buttons) do
            assertNil(b.glowContainer, "no glow container in icons mode")
            assertNil(b.glowHolder)
            assertEquals(st(b.glowFrame).alpha, 0)
            assertNotNil(b.debuffContainer)
        end
        -- the only dispel textures handed over are the aura buttons' own DispelBorder parts (no glow holder texture)
        local n = 0
        for _, x in ipairs(mock.containerCalls) do
            if x.method == "button:AddDispelTypeTexture" then
                n = n + 1
                local owner = st(x.args[1]).parent
                assertEquals(st(owner).kind, "AuraButton", "texture owned by an aura button")
                assertTrue(owner.DispelBorder == x.args[1], "only the button's own DispelBorder")
            end
        end
        assertTrue(n > 0, "the icon borders were seen")
        for _, c in ipairs(mock.containers) do
            local g = group(c)
            assertTrue(g == nil or g.templateNames[1] ~= "HealerForeverRaidGlowButtonTemplate", "no glow carriers")
        end
        local b = RF.buttons[4]
        assertEquals(container(b).unit, "raid4")
        ns.db.raid.debuffs.display = "glowIcons"; ns:Changed("raid"); mock.flushTimers()
        assertNotNil(b.glowContainer, "created on the switch")
        assertNotNil(b.glowHolder)
        assertEquals(addCalls(b.glowHolder.glow), 1)
        assertEquals(glowC(b).unit, "raid4")
        assertEquals(st(b.glowFrame).alpha, 1)
        ns.db.raid.debuffs.display = "icons"; ns:Changed("raid"); mock.flushTimers()
        assertEquals(glowC(b).unit, "none", "icons again: glow container points at none")
        assertEquals(st(b.glowFrame).alpha, 0)
        assertFalse(st(b.glowHolder).shown)
        assertEquals(container(b).unit, "raid4")
        assertEquals(addCalls(b.glowHolder.glow), 1, "never registered twice")
        clean()
    end)
    it("glow: the icon container points at 'none' and our icon zone is invisible; only our own frames are alpha'd", function()
        local ns, RF = boot()
        local b = RF.buttons[4]
        local function gameOwned()
            local out = {}
            for _, f in ipairs(mock.frames) do
                for _, root in ipairs({ b.debuffContainer.frame, b.glowContainer.frame }) do
                    if f ~= root and inside(f, root) and not inside(f, b.glowHolder) then out[#out + 1] = f end
                end
            end
            return out
        end
        local before = {}
        for _, f in ipairs(gameOwned()) do before[f] = { st(f).alpha, st(f).shown } end
        ns.db.raid.debuffs.display = "glow"; ns:Changed("raid"); mock.flushTimers()
        assertEquals(container(b).unit, "none", "glow only: no icons drawn")
        assertEquals(glowC(b).unit, "raid4")
        assertEquals(st(b.debuffZone).alpha, 0)
        assertEquals(st(b.glowFrame).alpha, 1)
        assertTrue(st(b.glowHolder).shown)
        -- switching the display never touches what the game owns (aura buttons and their parts): same alpha as before
        local checked = 0
        for _, f in ipairs(gameOwned()) do
            if before[f] then
                checked = checked + 1
                assertEquals(st(f).alpha, before[f][1], "display switch changed the alpha of a game-owned " .. tostring(st(f).kind))
            end
        end
        assertTrue(checked >= 4, "aura buttons and parts were checked (" .. checked .. ")")
        -- a fresh boot in glow mode never creates the icon containers
        local _, RF2 = boot({ afterLoad = function(n) n.db.raid.debuffs.display = "glow" end })
        assertNil(RF2.buttons[4].debuffContainer)
        assertNotNil(RF2.buttons[4].glowHolder)
        clean()
    end)
    it("AddDispelTypeTexture failing: glowSupported=false, ONE raid-glow log, every bar falls back to icons and is re-laid out", function()
        local ns, RF, RS = boot({ setup = function(S) S.containerFail = { ["button:AddDispelTypeTexture"] = true } end,
            afterLoad = function(n) n.db.raid.debuffs.display = "glow" end })
        assertEquals(RF.glowSupported, false)
        assertEquals(glowLogCount(ns), 1, "logged once")
        assertEquals(RS.DebuffMode(ns.db.raid), "icons")
        assertEquals(ns.db.raid.debuffs.display, "glow", "the saved choice is kept")
        local want = ns.RaidLayout.Reserves(ns.db.raid, 0, "icons")
        assertTrue(want.debW > 0 and ns.RaidLayout.Reserves(ns.db.raid, 0, "glow").debW == 0, "icons reserve a row, glow does not")
        for i, b in ipairs(RF.buttons) do
            assertEquals(st(b.glowFrame).alpha, 0, "raid" .. i .. " glow frame hidden")
            assertTrue(b.glowHolder == nil or not st(b.glowHolder).shown, "raid" .. i .. " no holder shown")
            assertEquals(st(b.debuffZone).alpha, 1, "raid" .. i .. " icons visible")
            assertNotNil(b.debuffContainer, "raid" .. i .. " icon container created by the fallback")
            assertEquals(b.reserves.debW, want.debW, "raid" .. i .. " re-laid out with the icon reserve")
        end
        assertEquals(container(RF.buttons[3]).unit, "raid3")
        -- more changes and roster updates never log again
        for _ = 1, 3 do ns:Changed("raid"); mock.flushTimers() end
        H.roster(12)
        assertEquals(glowLogCount(ns), 1)
        -- the injected failure also hits the containers' own dispel borders (party and raid, logged as
        -- aura-container:dispel-border); every error seen is that one failure, nothing else broke
        for _, e in ipairs(mock.errors) do assertTrue(e:find("AddDispelTypeTexture unavailable", 1, true) ~= nil, e) end
        for _, e in ipairs(ns.db.errorLog) do
            assertTrue(e.label == "raid-glow" or e.label == "aura-container:dispel-border", "unexpected log entry " .. tostring(e.label))
        end
        local _, _, out = H.slash("debug raid")
        assertNotNil(out)
    end)
    it("glow outset: at most 2 px and never more than half the spacing (spacing 0 / 2 / 8); neighbouring glows never overlap", function()
        local ns, RF, RS = boot({ raid = 25 })
        for _, case in ipairs({ { 0, 0 }, { 2, 1 }, { 8, 2 }, { 3, 1 } }) do
            local sp, want = case[1], case[2]
            assertEquals(RS.GlowOutset({ spacing = sp }), want, "GlowOutset spacing " .. sp)
            ns.db.raid.spacing = sp; ns:Changed("raid"); mock.flushTimers()
            local cfg = ns.db.raid
            local rects = {}
            for _, b in ipairs(H.shownRaidButtons(ns)) do
                assertEquals(b.glowOutset, want, "spacing " .. sp)
                local pts = st(b.glowFrame).points
                assertDeepEquals({ pts[#pts - 1][4], pts[#pts - 1][5] }, { -want, want }, "TOPLEFT outset")
                assertDeepEquals({ pts[#pts][4], pts[#pts][5] }, { want, -want }, "BOTTOMRIGHT outset")
                local x, y = H.cellOf(b)
                rects[#rects + 1] = { x - want, y - want, x + cfg.width + want, y + cfg.height + want }
            end
            for i = 1, #rects do
                for j = i + 1, #rects do
                    local a, c = rects[i], rects[j]
                    local apart = a[3] <= c[1] or c[3] <= a[1] or a[4] <= c[2] or c[4] <= a[2]
                    assertTrue(apart, "glows " .. i .. " and " .. j .. " overlap at spacing " .. sp)
                end
            end
        end
        assertEquals(RS.GlowOutset(nil), 2)
        clean()
    end)
end)

describe("raid debuffs: templates", function()
    it("raid icon containers use HealerForeverRaidAuraButtonTemplate; the party template is unchanged", function()
        local ns, RF = boot()
        assertEquals(group(container(RF.buttons[1])).templateNames[1], "HealerForeverRaidAuraButtonTemplate")
        local party = ns.UnitFrames.byUnit.party1
        for _, kind in ipairs({ "buff", "debuff" }) do
            local c = rawget(party.auraContainers[kind].frame, "__container")
            assertEquals(group(c).templateNames[1], "HealerForeverAuraButtonTemplate", "party " .. kind)
        end
        clean()
    end)
    it("Auras.xml: both raid templates take no mouse from creation on; the party template keeps motion for its tooltips", function()
        local xml = L.readFile(L.path("Frames/Auras.xml"))
        local function tag(name) return xml:match('<AuraButton name="' .. name .. '"[^>]*>') end
        local icon, glow, party = tag("HealerForeverRaidAuraButtonTemplate"), tag("HealerForeverRaidGlowButtonTemplate"), tag("HealerForeverAuraButtonTemplate")
        assertNotNil(icon); assertNotNil(glow); assertNotNil(party)
        for _, t in ipairs({ icon, glow }) do
            assertTrue(t:find('virtual="true"', 1, true) ~= nil, t)
            assertTrue(t:find('enableMouseClicks="false"', 1, true) ~= nil, t)
            assertTrue(t:find('enableMouseMotion="false"', 1, true) ~= nil, t)
        end
        assertTrue(icon:find('inherits="HealerForeverAuraButtonTemplate"', 1, true) ~= nil, "icons keep the party parts")
        assertTrue(glow:find('inherits="CustomAuraButtonTemplate"', 1, true) ~= nil)
        assertTrue(party:find('enableMouseMotion="true"', 1, true) ~= nil, "party unchanged")
        -- both raid templates sit inside the forbidden-object ScopedModifier like the party one
        local scoped = xml:match("<ScopedModifier.-</ScopedModifier>")
        assertTrue(scoped and scoped:find("HealerForeverRaidGlowButtonTemplate", 1, true) ~= nil)
        assertTrue(scoped:find("HealerForeverRaidAuraButtonTemplate", 1, true) ~= nil)
    end)
end)

describe("raid debuffs: combat", function()
    it("icon buttons and the glow carrier the game creates mid-fight: wired and glow-hooked with zero mouse or protected calls", function()
        local _, RF = boot({ setup = function(S) S.auraPoolLazy = true end })
        local b = RF.buttons[3]
        assertNil(b.glowHolder, "lazy pool: no carrier yet")
        H.enterCombat()
        mock.state.auras.raid3 = { debuff(7101, "Curse A", "Curse"), debuff(7102, "Magic B", "Magic") }
        mock.fire("UNIT_AURA", "raid3")
        mock.runOnUpdate(3, 0.2)
        clean("lazy pool in combat")
        local frames = group(container(b)).frames
        assertTrue(#frames >= 2, "the game grew the icon pool in combat")
        for _, f in ipairs(frames) do
            assertEquals(st(f).mouseCalls or 0, 0, "mouse setter on a combat-made aura button")
            assertTrue(f.wiredIcon ~= nil, "icon wired")
        end
        local c = carrier(b)
        assertNotNil(c, "the game created the glow carrier in combat")
        assertEquals(st(c).mouseCalls or 0, 0)
        assertNotNil(b.glowHolder, "glow attached in combat")
        assertEquals(addCalls(b.glowHolder.glow), 1)
        H.leaveCombat()
        clean("after combat")
    end)
    it("dispellable debuffs show in combat (game-drawn) and the addon reads no aura data for them", function()
        local _, RF = boot()
        H.enterCombat()
        mock.resetAuraCalls()
        mock.state.auras.raid5 = { debuff(7201, "Poison C", "Poison"), debuff(7202, "Plain D", nil) }
        mock.fire("UNIT_AURA", "raid5")
        local shown = 0
        for _, f in ipairs(select(2, next(container(RF.buttons[5]).groups)).frames) do if st(f).shown then shown = shown + 1 end end
        assertEquals(shown, 1, "only the dispellable one")
        assertEquals(mock.auraCalls.combat, 0)
        clean()
    end)
end)

describe("raid debuffs: preview path", function()
    it("RS.Render: icons limited to debuffs.max, glow in the first type's colour, same display mode as the real bars", function()
        local ns, RF, RS = boot()
        local cfg = ns.db.raid
        local f = ns.NewFrame("Frame", nil, UIParent)
        RS.Render(f, { class = "MAGE", hp = 500, maxHp = 1000, debuffs = { "Magic", "Poison", "Curse", "Disease" } }, cfg)
        assertEquals(f.fakeDebuffCount, 3)
        local col = ns.Classes.DISPEL_COLORS.Magic
        assertEquals(f.glowColor, col)
        assertTrue(st(f.dispelGlow).shown)
        RS.Render(f, { class = "MAGE", hp = 0, maxHp = 1000, state = "dead", debuffs = { "Magic" } }, cfg)
        assertEquals(f.fakeDebuffCount, 0, "no debuffs on a dead bar")
        cfg.debuffs.display = "glow"
        local g = ns.NewFrame("Frame", nil, UIParent)
        RS.Render(g, { class = "MAGE", debuffs = { "Poison" } }, cfg)
        assertEquals(g.fakeDebuffCount, 0, "glow only: no icons"); assertEquals(g.glowColor, ns.Classes.DISPEL_COLORS.Poison)
        cfg.debuffs.display = "icons"
        local h = ns.NewFrame("Frame", nil, UIParent)
        RS.Render(h, { class = "MAGE", debuffs = { "Poison" } }, cfg)
        assertEquals(h.fakeDebuffCount, 1); assertNil(h.glowColor, "icons only: no glow")
        -- after the real glow failed, the preview falls back to icons too
        cfg.debuffs.display = "glowIcons"
        RF.glowSupported = false
        assertEquals(RS.DebuffMode(cfg), "icons")
        local k = ns.NewFrame("Frame", nil, UIParent)
        RS.Render(k, { class = "MAGE", debuffs = { "Magic" } }, cfg)
        assertNil(k.glowColor)
        RF.glowSupported = true
    end)
end)
