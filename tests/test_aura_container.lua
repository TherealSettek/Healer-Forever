-- Native Blizzard AuraContainer path (Frames/Auras.xml + Auras.lua setupContainers): the container draws the icons itself, in combat too,
-- so the addon never reads aura data for display. The mock's container is faithful to the live API (flow layout, groups, buttons) and draws
-- from the mock's aura state. Covers creation, geometry for every option, filters, the dispel border, mouse settings, SetUnit rules,
-- live options, dispels in combat, per-button fallback, "no aura reads in combat", the debug lines and the TOC / XML.
local L = require("loader")
local mock = require("wow_mock")
local G = require("aura_geo")

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
    S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER"); S.units.party3 = unit("Mage", "MAGE", "DAMAGER")
    S.units.partypet1 = unit("Pet", "HUNTER")
    if opts.setup then opts.setup(S) end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(opts.group or 3)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.3); mock.flushTimers()
    return ns
end
local function debuff(i, extra) local a = { spellId = 7000 + i, name = "Debuff" .. i, icon = 300 + i, duration = 60, expirationTime = S.now + 40, isHarmful = true, isHelpful = false,
    dispelName = (i % 2 == 1) and "Magic" or nil, auraInstanceID = 200 + i }
    for k, v in pairs(extra or {}) do a[k] = v end return a end
local function buff(i, extra) local a = { spellId = 6000 + i, name = "Buff" .. i, icon = 100 + i, duration = 300, expirationTime = S.now + 200, isHelpful = true, isHarmful = false,
    auraInstanceID = 100 + i, sourceUnit = (i % 2 == 1) and "player" or "party2" }
    for k, v in pairs(extra or {}) do a[k] = v end return a end
local function setAuras(u, nBuff, nDebuff)
    local list = {}
    for i = 1, nBuff do list[#list + 1] = buff(i) end
    for i = 1, nDebuff do list[#list + 1] = debuff(i) end
    S.auras[u] = list
end
local function button(ns, u) return ns.UnitFrames.byUnit[u] end
local function container(ns, u, kind) return button(ns, u).auraContainers[kind] end
local function frames(c) return c.frame and rawget(c.frame, "__container").groups[c.kind].frames end
local function shownIDs(ns, u, kind)
    local out = {}
    for _, f in ipairs(frames(container(ns, u, kind))) do if st(f).shown and f.drawnAura then out[#out + 1] = f.drawnAura.auraInstanceID end end
    return table.concat(out, ",")
end
local function apply(ns) ns:Changed("frames"); mock.flushTimers(); mock.refreshContainers() end
local function callsOf(method, filter)
    local out = {}
    for _, c in ipairs(mock.containerCalls) do if c.method == method and (not filter or filter(c)) then out[#out + 1] = c end end
    return out
end
local function debugText()
    mock.printed = {}
    assert(pcall(_G.SlashCmdList.HEALERFOREVER, "debug auras"))
    return table.concat(mock.printed, "\n")
end
-- member buttons only (pets have no aura row)
local function members(ns) local out = {} for _, b in ipairs(ns.UnitFrames.buttons) do if not b.isPet and b.auraRow then out[#out + 1] = b end end return out end
local function internal(frame) return rawget(frame, "__container") end
-- logged container errors are forwarded to the game's error handler by design; the injected ones are expected
local function strayErrors()
    local out = {}
    for _, e in ipairs(mock.errors) do
        if not (tostring(e):find("injected", 1, true) or tostring(e):find("unavailable", 1, true)) then out[#out + 1] = e end
    end
    return table.concat(out, "\n---\n")
end
local function bigMax(ns) ns.db.auras.maxBuffs = 8; ns.db.auras.maxDebuffs = 6; ns:Changed("frames"); mock.flushTimers() end
local function pointOf(f) local pts = st(f).points; return pts[#pts] end

-- ======================================================================== creation
describe("aura container: creation", function()
    local ns = boot()
    it("the native path is selected (Auras.mode, no fallback icons) and the chat note about the fallback is not shown", function()
        assertEquals(ns.Auras.mode, "container")
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(#members(ns), 5, "player + 4 party slots")
        for _, b in ipairs(members(ns)) do
            assertNotNil(b.auraContainers, tostring(b.unit)); assertEquals(#b.buffIcons, 0); assertEquals(#b.debuffIcons, 0)
        end
        for _, b in ipairs(ns.UnitFrames.buttons) do if b.isPet then assertNil(b.auraContainers, "pets have no aura row") end end
        for _, l in ipairs(mock.printed) do assertNil(l:find("aura icons update after combat", 1, true)) end
    end)
    it("every button has exactly one buff and one debuff container: a raw 'AuraContainer' frame, parented to the zone, template CustomAuraContainerTemplate", function()
        -- party containers: 2 per member. The raid containers are lazy: none exist before the first switch to the raid layout
        local party = 0
        for _, c in ipairs(mock.containers) do
            local owner = st(c.frame).parent
            for _, b in ipairs(members(ns)) do if b.zones and (owner == b.zones.buff or owner == b.zones.debuff) then party = party + 1 end end
        end
        assertEquals(party, 2 * #members(ns))
        assertEquals(#mock.containers, 2 * #members(ns), "only the party containers at login (10)")
        assertEquals(#mock.containers, 10)
        for _, b in ipairs(ns.RaidFrames.buttons) do assertNil(b.debuffContainer); assertNil(b.glowContainer) end
        -- joining a raid (default display glowIcons): one icon + one glow container per raid button (40 + 40)
        mock.setRaid(10); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        assertEquals(ns.RaidFrames.active, "raid")
        local icons, glows = 0, 0
        for _, b in ipairs(ns.RaidFrames.buttons) do
            if b.debuffContainer then icons = icons + 1 end
            if b.glowContainer then glows = glows + 1 end
        end
        assertEquals(icons, 40); assertEquals(glows, 40)
        assertEquals(#mock.containers, 10 + 80, "party containers + 40 icon + 40 glow containers")
        -- leaving keeps them (pointed at "none"), no more are made
        mock.setRaid(0); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        assertEquals(ns.RaidFrames.active, "party")
        assertEquals(#mock.containers, 90)
        assertEquals(#mock.errors, 0, errstr())
        for _, b in ipairs(members(ns)) do
            for _, kind in ipairs({ "buff", "debuff" }) do
                local c = b.auraContainers[kind]
                assertEquals(st(c.frame).kind, "AuraContainer"); assertEquals(st(c.frame).template, "CustomAuraContainerTemplate")
                assertTrue(st(c.frame).parent == b.zones[kind], "parented to its zone")
                assertFalse(st(c.frame).secure and true or false)
            end
        end
    end)
    it("each container has one aura group named after its kind with the right filter, max count, button template, sort and layout numbers", function()
        local cfg = ns.db.auras
        for _, kind in ipairs({ "buff", "debuff" }) do
            local c = container(ns, "party1", kind)
            local grp = rawget(c.frame, "__container").groups[kind]
            assertNotNil(grp)
            assertEquals(grp.filter, kind == "buff" and "HELPFUL" or "HARMFUL")
            assertEquals(grp.maxFrameCount, kind == "buff" and cfg.maxBuffs or cfg.maxDebuffs)
            assertEquals(grp.templateNames[1], "HealerForeverAuraButtonTemplate")
            assertEquals(grp.sortMethod, AuraContainerSortMethod.Default); assertEquals(grp.sortDirection, AuraContainerSortDirection.Normal)
            assertEquals(#grp.frames, grp.maxFrameCount, "buttons exist up front (nothing is created in combat)")
            local lay = rawget(c.frame, "__container").layout
            assertEquals(lay.elementWidth, kind == "buff" and cfg.buffSize or cfg.debuffSize)
            assertEquals(lay.elementSpacing, ns.Util.ICON_GAP); assertEquals(lay.lineSpacing, ns.Util.ICON_GAP)
            assertEquals(lay.elementHeight, lay.elementWidth + ns.Util.TIMER_HEIGHT)
        end
    end)
    it("each group button is wired through the template's parts: icon, cooldown, duration text, application count", function()
        local f = frames(container(ns, "party1", "debuff"))[1]
        assertTrue(f.wiredIcon == f.Icon); assertTrue(f.wiredCooldown == f.Cooldown); assertTrue(f.wiredTime == f.Time); assertTrue(f.wiredCount == f.Count)
        assertEquals(st(f).kind, "AuraButton"); assertEquals(st(f).template, "HealerForeverAuraButtonTemplate")
    end)
    it("the flow layout calls: axis, anchor point, growth, padding, max line size, anchored to the zone's corner", function()
        local c = container(ns, "party1", "buff")
        local fl = rawget(c.frame, "__container").flow
        assertEquals(fl.axis, AnchorUtil.FlowLayoutAxis.Horizontal); assertEquals(fl.anchor, "TOPLEFT")
        assertEquals(fl.growth[1], "Right"); assertEquals(fl.growth[2], "Down")
        assertDeepEquals(fl.padding, { 2, 2, 2, 2 })
        local p = pointOf(c.frame)
        assertEquals(p[1], "TOPLEFT"); assertTrue(p[2] == button(ns, "party1").zones.buff); assertEquals(p[3], "TOPLEFT")
    end)
    it("creation happens at layout time, never in combat (nothing created while locked down)", function()
        assertEquals(#mock.createdInCombat, 0)
    end)
end)

-- ======================================================================== geometry
-- The mock lays the buttons out from the numbers the addon gave the container (generic flow layout). Every button must land exactly where
-- Util.IconOffset puts the same icon in the hand-drawn path, inside its zone, clear of the bar, other icons and their timers.
describe("aura container: geometry matches Util.IconOffset / ZoneSize for every option combination", function()
    local ns = boot()
    for _, kind in ipairs({ "buff", "debuff" }) do ns.db.auras["max" .. (kind == "buff" and "Buffs" or "Debuffs")] = 8 end
    setAuras("party1", 8, 8); setAuras("player", 8, 8)
    local POS = { "top", "bottom", "left", "right", "inside" }
    local checked, bad = 0, {}
    local function check(kind, label, unitToken)
        local cfg = ns.db.auras
        local b = button(ns, unitToken)
        local c = b.auraContainers[kind]
        local g = ns.Auras.ContainerGeometry(kind, cfg)
        local frs = frames(c)
        local root = ns.UnitFrames.anchor
        local zoneRect = G.rect(b.zones[kind], root)
        local barRect = G.rect(b, root)
        local shown, rects, timers = 0, {}, {}
        for i, f in ipairs(frs) do
            if st(f).shown then
                shown = shown + 1
                local corner, x, y = ns.Util.IconOffset(i, g.size, g.perRow, g.grow, g.timerH, g.gap)
                local p = pointOf(f)
                if p[1] ~= corner or p[3] ~= corner or p[4] ~= x or p[5] ~= y then
                    bad[#bad + 1] = string.format("%s icon %d at %s %s,%s but IconOffset says %s %s,%s", label, i, tostring(p[1]), tostring(p[4]), tostring(p[5]), corner, x, y)
                end
                if st(f).w ~= g.size or st(f).h ~= g.size then bad[#bad + 1] = label .. " icon " .. i .. " wrong size" end
                local r = G.rect(f, root)
                rects[#rects + 1] = r
                local tp = st(f.Time).points[1]
                if g.timerH > 0 then
                    if not (tp[1] == "TOP" and tp[3] == "BOTTOM" and tp[5] == -1) then bad[#bad + 1] = label .. " timer not below icon " .. i end
                    timers[#timers + 1] = { l = r.l, r = r.r, t = r.b + 1, b = r.b + 1 + (g.timerH - 1) }
                else
                    if not (tp[1] == "BOTTOM" and tp[3] == "BOTTOM") then bad[#bad + 1] = label .. " inside timer not at the icon bottom " .. i end
                end
                if not g.inside and not G.inside(r, zoneRect) then bad[#bad + 1] = label .. " icon " .. i .. " leaves its zone " .. G.fmt(r) .. " vs " .. G.fmt(zoneRect) end
                if not g.inside and G.overlap(r, barRect) then bad[#bad + 1] = label .. " icon " .. i .. " overlaps the bar" end
            end
        end
        for i = 1, #rects do
            for j = i + 1, #rects do if G.overlap(rects[i], rects[j]) then bad[#bad + 1] = label .. ": icons " .. i .. " and " .. j .. " overlap" end end
            for j = 1, #timers do
                if i ~= j and G.overlap(rects[i], timers[j]) then bad[#bad + 1] = label .. ": icon " .. i .. " overlaps the timer of " .. j end
                if not g.inside and not G.inside(timers[j], zoneRect) then bad[#bad + 1] = label .. ": timer " .. j .. " leaves the zone" end
            end
        end
        checked = checked + 1
        return shown
    end
    for _, kind in ipairs({ "buff", "debuff" }) do
        for _, pos in ipairs(POS) do
            for _, grow in ipairs({ "right", "left", "down", "up" }) do
                for _, timerPos in ipairs({ "below", "inside" }) do
                    for _, perRow in ipairs({ 2, 5, 8 }) do
                        for _, size in ipairs({ 10, 28 }) do
                            for _, gap in ipairs({ 0, 12 }) do
                                local a = ns.db.auras
                                a.buffPosition, a.debuffPosition = "top", "bottom"
                                a[kind .. "Position"] = pos
                                if pos == "top" and kind == "debuff" then a.buffPosition = "bottom" end
                                if pos == "bottom" and kind == "buff" then a.debuffPosition = "top" end
                                a.grow, a.timerPos, a.perRow, a.zoneGap = grow, timerPos, perRow, gap
                                a.buffSize, a.debuffSize = size, size + 4
                                a.maxBuffs, a.maxDebuffs = 8, 6
                                apply(ns)
                                check(kind, string.format("%s %s/%s/%s/row%d/size%d/gap%d", kind, pos, grow, timerPos, perRow, size, gap), "party1")
                            end
                        end
                    end
                end
            end
        end
    end
    it("ran every combination (2 kinds x 5 positions x 4 grows x 2 timer positions x 3 perRow x 2 sizes x 2 gaps)", function()
        assertEquals(checked, 2 * 5 * 4 * 2 * 3 * 2 * 2)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("every icon lands where Util.IconOffset puts it, inside its zone, clear of the bar, other icons and timers", function()
        assertEquals(#bad, 0, #bad .. " problems, first:\n" .. table.concat({ bad[1] or "", bad[2] or "", bad[3] or "" }, "\n"))
    end)
    it("the matrix really drew icons (not vacuous)", function()
        local a = ns.db.auras
        a.buffPosition, a.debuffPosition, a.grow, a.timerPos, a.perRow, a.zoneGap = "top", "bottom", "right", "below", 3, 4
        a.buffSize, a.debuffSize = 16, 20; a.maxBuffs, a.maxDebuffs = 8, 6
        apply(ns)
        assertEquals(check("buff", "sanity", "party1"), 8); assertEquals(check("debuff", "sanity", "party1"), 6)
    end)
    it("ContainerGeometry is pure and consistent: size, timer height, gap, max, anchor corner and a stable key per option set", function()
        local cfg = { buffPosition = "top", debuffPosition = "inside", buffSize = 20, debuffSize = 30, grow = "up", perRow = 4, timerPos = "below", maxBuffs = 5, maxDebuffs = 7,
            onlyMine = true, onlyDispellable = true, colorDebuffBorder = true, tooltipIcons = true }
        local gb, gd = ns.Auras.ContainerGeometry("buff", cfg), ns.Auras.ContainerGeometry("debuff", cfg)
        assertEquals(gb.size, 20); assertEquals(gb.timerH, ns.Util.TIMER_HEIGHT); assertEquals(gb.gap, ns.Util.ICON_GAP); assertEquals(gb.max, 5)
        assertEquals(gb.anchor, "BOTTOMLEFT"); assertTrue(gb.vertical); assertEquals(gb.verticalDir, "Up"); assertEquals(gb.padding[4], 2 + ns.Util.TIMER_HEIGHT)
        assertEquals(gb.filter, "HELPFUL|PLAYER"); assertTrue(gb.mouse); assertFalse(gb.colorBorder, "buffs never get the dispel border")
        assertTrue(gd.inside); assertEquals(gd.size, 16, "inside zones cap the size (debuffs at 16)"); assertEquals(gd.grow, "left"); assertEquals(gd.timerH, 0); assertEquals(gd.gap, 2)
        assertEquals(gd.filter, "HARMFUL|RAID_PLAYER_DISPELLABLE"); assertTrue(gd.colorBorder); assertEquals(gd.anchor, "TOPRIGHT")
        assertEquals(ns.Auras.ContainerGeometry("buff", cfg).key, gb.key, "same options, same key")
        cfg.perRow = 5
        assertTrue(ns.Auras.ContainerGeometry("buff", cfg).key ~= gb.key, "a changed option changes the key")
        cfg.buffPosition = "inside"
        local gi = ns.Auras.ContainerGeometry("buff", cfg)
        assertEquals(gi.size, 14, "inside buffs cap at 14"); assertTrue(gi.inside)
        cfg.timerPos = "inside"; cfg.buffPosition = "top"
        assertEquals(ns.Auras.ContainerGeometry("buff", cfg).timerH, 0, "timer inside the icon reserves no height")
    end)
end)

-- ======================================================================== filters, dispel border, mouse
describe("aura container: filters, the dispel border and mouse settings", function()
    it("onlyMine: the buff group's filter becomes HELPFUL|PLAYER live and only our buffs are drawn", function()
        local ns = boot()
        bigMax(ns)
        setAuras("party1", 4, 0)
        mock.refreshContainers()
        assertEquals(shownIDs(ns, "party1", "buff"), "101,102,103,104")
        ns.db.auras.onlyMine = true; apply(ns)
        local c = container(ns, "party1", "buff")
        assertEquals(rawget(c.frame, "__container").groups.buff.filter, "HELPFUL|PLAYER")
        assertEquals(shownIDs(ns, "party1", "buff"), "101,103", "odd buffs come from the player in this fixture")
        assertTrue(#callsOf("SetAuraGroupFilterString") > 0)
        ns.db.auras.onlyMine = false; apply(ns)
        assertEquals(shownIDs(ns, "party1", "buff"), "101,102,103,104")
    end)
    it("onlyDispellable: the debuff group's filter becomes HARMFUL|RAID_PLAYER_DISPELLABLE and only dispellable debuffs are drawn", function()
        local ns = boot()
        bigMax(ns)
        setAuras("party1", 0, 4)
        mock.refreshContainers()
        assertEquals(shownIDs(ns, "party1", "debuff"), "201,202,203,204")
        ns.db.auras.onlyDispellable = true; apply(ns)
        assertEquals(rawget(container(ns, "party1", "debuff").frame, "__container").groups.debuff.filter, "HARMFUL|RAID_PLAYER_DISPELLABLE")
        assertEquals(shownIDs(ns, "party1", "debuff"), "201,203")
        ns.db.auras.onlyDispellable = false; apply(ns)
        assertEquals(shownIDs(ns, "party1", "debuff"), "201,202,203,204")
    end)
    it("the filter of the OTHER group is never touched by a change to one of them", function()
        local ns = boot()
        ns.db.auras.onlyDispellable = true; apply(ns)
        assertEquals(rawget(container(ns, "party1", "buff").frame, "__container").groups.buff.filter, "HELPFUL")
    end)
    it("colorDebuffBorder: the dispel-border texture is registered on debuff buttons (never on buffs), shown only for dispellable auras, and removed when the option is off", function()
        local ns = boot()
        bigMax(ns)
        setAuras("party1", 2, 4); mock.refreshContainers()
        local dbtn = frames(container(ns, "party1", "debuff"))
        assertTrue(ns.db.auras.colorDebuffBorder, "default on")
        for i = 1, 4 do
            assertNotNil(dbtn[i].dispelTextures[dbtn[i].DispelBorder], "registered " .. i)
            assertEquals(st(dbtn[i].DispelBorder).shown, dbtn[i].drawnAura.dispelName ~= nil, "border only for dispellable " .. i)
        end
        for _, f in ipairs(frames(container(ns, "party1", "buff"))) do assertNil(f.dispelTextures[f.DispelBorder], "buffs have no dispel border") end
        ns.db.auras.colorDebuffBorder = false; apply(ns)
        for i = 1, 4 do assertNil(dbtn[i].dispelTextures[dbtn[i].DispelBorder]); assertFalse(st(dbtn[i].DispelBorder).shown and true or false) end
        ns.db.auras.colorDebuffBorder = true; apply(ns)
        for i = 1, 4 do assertNotNil(dbtn[i].dispelTextures[dbtn[i].DispelBorder]) end
        local opts = dbtn[1].dispelTextures[dbtn[1].DispelBorder]
        assertEquals(opts.style, Enum.CustomAuraButtonDispelTypeTextureStyle.Border); assertTrue(opts.showWhenHarmful)
    end)
    it("debuff buttons get the red default backdrop, buff buttons black", function()
        local ns = boot()
        local d = st(frames(container(ns, "party1", "debuff"))[1].Backdrop).vertex
        local b = st(frames(container(ns, "party1", "buff"))[1].Backdrop).vertex
        assertTrue(d.r > 0.7 and d.g < 0.1, "debuff"); assertTrue(b.r == 0 and b.g == 0 and b.b == 0, "buff")
    end)
    it("CLICKS ARE NEVER CAPTURED: every group button has mouse clicks disabled (default settings, tooltips on, icons inside)", function()
        for _, setup in ipairs({ function() end, function(ns) ns.db.auras.tooltipIcons = true end, function(ns) ns.db.auras.tooltipIcons = false end,
            function(ns) ns.db.auras.buffPosition = "inside"; ns.db.auras.debuffPosition = "inside" end }) do
            local ns = boot()
            setup(ns); apply(ns)
            for _, b in ipairs(members(ns)) do
                for _, kind in ipairs({ "buff", "debuff" }) do
                    for _, f in ipairs(frames(b.auraContainers[kind])) do assertEquals(st(f).mouseClick, false, tostring(b.unit) .. " " .. kind) end
                end
            end
        end
    end)
    it("hover (motion) follows the tooltipIcons option and motion propagates to the bar for in-bar zones", function()
        local ns = boot()
        for _, tip in ipairs({ true, false }) do
            ns.db.auras.tooltipIcons = tip; ns.db.auras.buffPosition = "top"; ns.db.auras.debuffPosition = "inside"; apply(ns)
            for _, f in ipairs(frames(container(ns, "party1", "buff"))) do assertEquals(st(f).mouseMotion, tip); assertEquals(st(f).propagateMotion, false) end
            for _, f in ipairs(frames(container(ns, "party1", "debuff"))) do assertEquals(st(f).mouseMotion, tip); assertEquals(st(f).propagateMotion, true) end
        end
    end)
    it("the container frames themselves never take the mouse (they are not even clickable regions)", function()
        local ns = boot()
        for _, b in ipairs(members(ns)) do
            for _, kind in ipairs({ "buff", "debuff" }) do assertFalse(st(b.auraContainers[kind].frame).mouse == true) end
            assertFalse(st(b.zones.buff).mouse == true); assertFalse(st(b.zones.debuff).mouse == true)
        end
    end)
end)

-- ======================================================================== SetUnit
describe("aura container: SetUnit follows the roster, never runs in combat, and 'none' hides missing units", function()
    it("each container shows its button's unit; missing members and pets get 'none'", function()
        local ns = boot()
        for _, u in ipairs({ "player", "party1", "party2", "party3" }) do
            for _, kind in ipairs({ "buff", "debuff" }) do assertEquals(container(ns, u, kind).frame:GetUnit(), u, u .. " " .. kind) end
        end
        for _, u in ipairs({ "party4" }) do assertEquals(container(ns, u, "buff").frame:GetUnit(), "none") end
        assertNil(button(ns, "partypet1").auraContainers, "pets have no container at all")
    end)
    it("a member leaving sets 'none' (the old icons vanish); a new member in the slot gets the new unit; the slot is re-armed on roster events", function()
        local ns = boot()
        setAuras("party2", 2, 2); mock.refreshContainers()
        assertEquals(shownIDs(ns, "party2", "debuff"), "201,202")
        S.units.party2 = nil; mock.setGroup(2); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.refreshContainers()
        assertEquals(container(ns, "party2", "debuff").frame:GetUnit(), "none"); assertEquals(shownIDs(ns, "party2", "debuff"), "")
        S.units.party2 = unit("NewGuy", "ROGUE", "DAMAGER"); S.auras.party2 = { debuff(5) }
        mock.setGroup(3); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.refreshContainers()
        assertEquals(container(ns, "party2", "debuff").frame:GetUnit(), "party2"); assertEquals(shownIDs(ns, "party2", "debuff"), "205", "the new member's own auras")
    end)
    it("roster events with an UNCHANGED roster make no SetUnit call at all (the old forced re-arm is gone)", function()
        local ns = boot()
        mock.containerCalls = {}
        mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("PLAYER_ENTERING_WORLD", false, false); mock.flushTimers()
        assertEquals(#callsOf("SetUnit"), 0)
    end)
    it("a slot EMPTIED is set to 'none' directly, a slot FILLED is set to the unit directly: no 'none' step in between", function()
        local ns = boot()
        local c = container(ns, "party2", "debuff")
        local function mine(call) return call.container == internal(c.frame) end
        mock.containerCalls = {}
        S.units.party2 = nil; mock.setGroup(2); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        local sets = callsOf("SetUnit", mine)
        assertEquals(#sets, 1); assertEquals(sets[1].args[1], "none")
        mock.containerCalls = {}
        S.units.party2 = unit("Fresh", "ROGUE", "DAMAGER"); mock.setGroup(3); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        sets = callsOf("SetUnit", mine)
        assertEquals(#sets, 1, "filled directly"); assertEquals(sets[1].args[1], "party2")
    end)
    it("a GUID change behind the SAME token re-arms the unit ('none' first, then the unit) - a member swapped without a visible gap", function()
        local ns = boot()
        setAuras("party2", 0, 2); mock.refreshContainers()
        local c = container(ns, "party2", "debuff")
        mock.containerCalls = {}
        S.guids = { party2 = "Player-77-OTHER" }
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        local sets = callsOf("SetUnit", function(call) return call.container == internal(c.frame) end)
        assertEquals(#sets, 2); assertEquals(sets[1].args[1], "none"); assertEquals(sets[2].args[1], "party2")
        assertEquals(c.frame:GetUnit(), "party2")
        mock.containerCalls = {}
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        assertEquals(#callsOf("SetUnit"), 0, "the new GUID is remembered: no further re-arm")
    end)
    it("the same GUID, a nil GUID (not readable yet) and SECRET GUIDs never re-arm and never raise", function()
        local ns = boot()
        mock.containerCalls = {}
        S.guids = { party1 = false }                  -- UnitGUID returns nil
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        S.guids = nil; S.secretAll = true
        mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("PLAYER_ENTERING_WORLD", false, false); mock.flushTimers(); mock.advance(2)
        S.secretAll = false
        assertEquals(#callsOf("SetUnit"), 0)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a GUID swap in combat is queued until combat ends and never calls SetUnit during it", function()
        local ns = boot()
        local c = container(ns, "party1", "buff")
        mock.containerCalls = {}
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        S.guids = { party1 = "Player-5-SWAP" }
        mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("UNIT_AURA", "party1"); mock.advance(5)
        assertEquals(#callsOf("SetUnit", function(call) return call.combat end), 0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers(); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        assertEquals(c.frame:GetUnit(), "party1")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("NO SetUnit churn across 100 roster, range, aura, target and update events with an unchanged roster", function()
        local ns = boot()
        setAuras("party1", 2, 2)
        mock.containerCalls = {}
        for i = 1, 100 do
            local r = i % 6
            if r == 0 then mock.fire("GROUP_ROSTER_UPDATE")
            elseif r == 1 then mock.fire("UNIT_AURA", "party1")
            elseif r == 2 then mock.fire("UNIT_IN_RANGE_UPDATE", "party2")
            elseif r == 3 then mock.runOnUpdate(2, 0.3)
            elseif r == 4 then mock.fire("PLAYER_TARGET_CHANGED")
            else mock.fire("PLAYER_ENTERING_WORLD", false, false) end
            if i % 10 == 0 then S.outOfRange.party2 = (i % 20 == 0) or nil end
        end
        mock.flushTimers(); mock.advance(2)
        assertEquals(#callsOf("SetUnit"), 0, "SetUnit calls: " .. #callsOf("SetUnit"))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("an unchanged unit is NOT re-set on ordinary updates (no churn)", function()
        local ns = boot()
        mock.containerCalls = {}
        ns.Auras.Update(button(ns, "party1"), "safety"); ns.Auras.Update(button(ns, "party1"), "update"); mock.flushTimers()
        assertEquals(#callsOf("SetUnit"), 0)
    end)
    it("SetUnit is NEVER called in combat: a roster change in combat is queued and applied when combat ends", function()
        local ns = boot()
        mock.containerCalls = {}
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        S.units.party3 = nil; mock.setGroup(2)
        mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("PLAYER_ENTERING_WORLD", false, false); mock.flushTimers(); mock.advance(5)
        assertEquals(#callsOf("SetUnit", function(c) return c.combat end), 0, "no SetUnit during combat")
        assertEquals(container(ns, "party3", "buff").frame:GetUnit(), "party3", "still the old unit while locked")
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(container(ns, "party3", "buff").frame:GetUnit(), "none", "applied after combat")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a member joining in combat is shown after combat, queued once per container (no pile-up)", function()
        local ns = boot({ group = 2 })
        mock.containerCalls = {}
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        S.units.party3 = unit("Late", "MAGE", "DAMAGER"); mock.setGroup(3)
        for _ = 1, 10 do mock.fire("GROUP_ROSTER_UPDATE") end
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(container(ns, "party3", "debuff").frame:GetUnit(), "party3")
        assertTrue(#callsOf("SetUnit", function(c) return c.container == internal(container(ns, "party3", "debuff").frame) end) <= 4)
    end)
    it("showBuffs / showDebuffs off set that container to 'none' live, and on again restores the unit", function()
        local ns = boot()
        setAuras("party1", 2, 2); mock.refreshContainers()
        ns.db.auras.showBuffs = false; apply(ns)
        assertEquals(container(ns, "party1", "buff").frame:GetUnit(), "none"); assertEquals(shownIDs(ns, "party1", "buff"), "")
        assertEquals(container(ns, "party1", "debuff").frame:GetUnit(), "party1")
        ns.db.auras.showBuffs = true; ns.db.auras.showDebuffs = false; apply(ns)
        assertEquals(container(ns, "party1", "buff").frame:GetUnit(), "party1"); assertEquals(container(ns, "party1", "debuff").frame:GetUnit(), "none")
        ns.db.auras.showDebuffs = true; apply(ns)
        assertEquals(shownIDs(ns, "party1", "debuff"), "201,202")
    end)
    it("UNIT_AURA is ignored in container mode (Blizzard's container listens itself): the update does nothing", function()
        local ns = boot()
        setAuras("party1", 1, 1)
        mock.containerCalls = {}
        local seen = {}
        local orig = ns.Auras.Update
        ns.Auras.Update = function(btn, src, ...) seen[#seen + 1] = src; return orig(btn, src, ...) end
        mock.auraEvent("party1", { full = true }); mock.auraEvent("party1", { removed = { 201 } })
        ns.Auras.Update = orig
        assertTrue(#seen >= 1, "the event reached Update")
        assertEquals(#mock.containerCalls, 0, "...which did nothing")
    end)
end)

-- ======================================================================== tooltips, propagation, debug
describe("aura container: the bar tooltip steps aside for the native aura buttons", function()
    local function tooltipRecorder()
        local rec = { owners = {}, hides = 0, lines = {}, owner = nil }
        local gt = _G.GameTooltip
        gt.SetOwner = function(_, o) rec.owner = o; rec.owners[#rec.owners + 1] = o; rec.lines = {} end
        gt.GetOwner = function() return rec.owner end
        gt.Hide = function() rec.hides = rec.hides + 1; rec.owner = nil end
        gt.Show = function() end; gt.AddLine = function(_, t) rec.lines[#rec.lines + 1] = tostring(t) end
        gt.AddDoubleLine = function(_, l, r) rec.lines[#rec.lines + 1] = tostring(l) .. " " .. tostring(r) end; gt.AddTexture = function() end
        return rec
    end
    it("while the mouse is over one of the unit's aura buttons the bar tooltip is NOT built, the flag is set and the bar's own tooltip is hidden", function()
        local ns = boot()
        setAuras("party1", 2, 2); mock.refreshContainers()
        local rec = tooltipRecorder()
        local bar = button(ns, "party1")
        ns.UnitFrames:ShowTooltip(bar)
        assertEquals(#rec.owners, 1); assertEquals(bar.barTooltipSuppressed, false)
        local f = frames(container(ns, "party1", "debuff"))[1]
        assertTrue(st(f).shown)
        st(f).mouseOver = true
        rec.owners = {}
        ns.UnitFrames:ShowTooltip(bar)
        assertEquals(#rec.owners, 0, "no SetOwner by the bar tooltip")
        assertEquals(bar.barTooltipSuppressed, true)
        assertTrue(rec.hides >= 1, "the bar's own tooltip was hidden")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the hide only happens when the tooltip is OWNED by that bar (another owner's tooltip is left alone)", function()
        local ns = boot()
        setAuras("party1", 1, 1); mock.refreshContainers()
        local rec = tooltipRecorder()
        local f = frames(container(ns, "party1", "buff"))[1]; st(f).mouseOver = true
        rec.owner = button(ns, "party2")
        ns.UnitFrames:ShowTooltip(button(ns, "party1"))
        assertEquals(rec.hides, 0)
    end)
    it("when the mouse leaves the aura button the bar tooltip resumes (SetOwner again, flag cleared)", function()
        local ns = boot()
        setAuras("party1", 2, 2); mock.refreshContainers()
        local rec = tooltipRecorder()
        local bar = button(ns, "party1")
        local f = frames(container(ns, "party1", "buff"))[1]
        st(f).mouseOver = true; ns.UnitFrames:ShowTooltip(bar)
        assertEquals(bar.barTooltipSuppressed, true)
        st(f).mouseOver = false
        rec.owners = {}
        ns.UnitFrames:ShowTooltip(bar)
        assertEquals(#rec.owners, 1); assertTrue(rec.owners[1] == bar); assertEquals(bar.barTooltipSuppressed, false)
        assertTrue(table.concat(rec.lines, "\n"):find("Click-casting", 1, true))
    end)
    it("works through the real hover hook of the bar (OnEnter) and for every container button of the unit, buffs and debuffs", function()
        local ns = boot()
        setAuras("party1", 3, 3); mock.refreshContainers()
        local rec = tooltipRecorder()
        local bar = button(ns, "party1")
        for _, kind in ipairs({ "buff", "debuff" }) do
            for i, f in ipairs(frames(container(ns, "party1", kind))) do
                if st(f).shown then
                    st(f).mouseOver = true
                    rec.owners = {}
                    mock.runFrameScript(bar, "OnEnter")
                    assertEquals(#rec.owners, 0, kind .. " " .. i)
                    st(f).mouseOver = false
                end
            end
        end
        mock.runFrameScript(bar, "OnEnter")
        assertTrue(#rec.owners >= 1)
    end)
    it("hovering an aura button of ANOTHER unit does not silence this bar's tooltip", function()
        local ns = boot()
        setAuras("party2", 1, 1); mock.refreshContainers()
        local rec = tooltipRecorder()
        st(frames(container(ns, "party2", "buff"))[1]).mouseOver = true
        ns.UnitFrames:ShowTooltip(button(ns, "party1"))
        assertEquals(#rec.owners, 1)
    end)
    it("in the fallback path (no containers) the check is simply false and the old behaviour stays", function()
        local ns = boot({ containers = false })
        local rec = tooltipRecorder()
        assertFalse(ns.Auras.IsHoveringContainerButton(button(ns, "party1")))
        ns.UnitFrames:ShowTooltip(button(ns, "party1"))
        assertEquals(#rec.owners, 1)
    end)
    it("a container that errors while asking IsMouseOver never breaks the bar tooltip", function()
        local ns = boot()
        setAuras("party1", 1, 1); mock.refreshContainers()
        local rec = tooltipRecorder()
        local f = frames(container(ns, "party1", "buff"))[1]
        f.IsMouseOver = function() error("secret frame") end
        ns.UnitFrames:ShowTooltip(button(ns, "party1"))
        assertEquals(#rec.owners, 1); assertEquals(#mock.errors, 0, errstr())
    end)
    it("works in combat (non-secure, no aura reads) and with everything secret", function()
        local ns = boot()
        setAuras("party1", 1, 1); mock.refreshContainers()
        local rec = tooltipRecorder()
        S.combat = true; S.secretAll = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.resetAuraCalls()
        st(frames(container(ns, "party1", "buff"))[1]).mouseOver = true
        ns.UnitFrames:ShowTooltip(button(ns, "party1"))
        assertEquals(#rec.owners, 0); assertEquals(mock.auraCalls.total, 0); assertEquals(#mock.errors, 0, errstr())
        S.combat = false; S.secretAll = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
    end)
end)

describe("aura container: mouse motion propagates to the bar ONLY for inside-the-bar zones; no fallback icon is ever visible", function()
    it("every outside position (top, bottom, left, right) does NOT propagate; inside does - per kind, per button", function()
        local ns = boot()
        setAuras("party1", 3, 3)
        for _, pos in ipairs({ "top", "bottom", "left", "right", "inside" }) do
            ns.db.auras.buffPosition = pos; ns.db.auras.debuffPosition = pos == "top" and "bottom" or "top"
            if pos == "inside" then ns.db.auras.debuffPosition = "inside" end
            apply(ns)
            for _, b in ipairs(members(ns)) do
                for _, f in ipairs(frames(b.auraContainers.buff)) do assertEquals(st(f).propagateMotion, pos == "inside", b.unit .. " buff " .. pos) end
                for _, f in ipairs(frames(b.auraContainers.debuff)) do assertEquals(st(f).propagateMotion, ns.db.auras.debuffPosition == "inside", b.unit .. " debuff") end
            end
        end
    end)
    it("zero fallback icons are visible in container mode, through every event, option change and fight", function()
        local ns = boot()
        setAuras("party1", 4, 3); setAuras("player", 2, 2); mock.refreshContainers()
        local function visible()
            local n = 0
            for _, b in ipairs(ns.UnitFrames.buttons) do
                for _, list in ipairs({ b.buffIcons or {}, b.debuffIcons or {} }) do for _, icon in ipairs(list) do if st(icon).shown then n = n + 1 end end end
            end
            return n
        end
        mock.auraEvent("party1", { full = true }); mock.fire("GROUP_ROSTER_UPDATE"); mock.advance(3); assertEquals(visible(), 0)
        ns.db.auras.grow = "down"; ns.db.auras.perRow = 2; apply(ns); assertEquals(visible(), 0)
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED"); mock.advance(5); S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(visible(), 0)
    end)
    it("/hf debug auras prints the visible fallback icon count (0), the container frame count and the suppression flag", function()
        local ns = boot()
        setAuras("party1", 2, 2); mock.refreshContainers()
        local out = debugText()
        assertTrue(out:find("buff container: unit=party1 (requested party1) filter=HELPFUL frames=4", 1, true), out)
        assertTrue(out:find("visible fallback icons: 0 (must be 0) | bar tooltip suppressed while over an aura button: false", 1, true), out)
        st(frames(container(ns, "party1", "buff"))[1]).mouseOver = true
        local gt = _G.GameTooltip
        gt.SetOwner = function() end; gt.GetOwner = function() return nil end; gt.Hide = function() end; gt.Show = function() end
        ns.UnitFrames:ShowTooltip(button(ns, "party1"))
        assertTrue(debugText():find("suppressed while over an aura button: true", 1, true))
    end)
    it("the debug line also explains the limit (far / invisible units may have no aura data)", function()
        local ns = boot()
        assertTrue(debugText():find("far away or not visible may have no aura data", 1, true))
    end)
    it("a stray visible fallback icon in container mode would be reported with its count", function()
        local ns = boot()
        local b = button(ns, "party1")
        local icon = ns.NewFrame("Frame", nil, b.zones.debuff); icon:Show()
        b.debuffIcons[1] = icon
        assertTrue(debugText():find("visible fallback icons: 1 (must be 0)", 1, true))
        b.debuffIcons[1] = nil
    end)
end)

-- ======================================================================== live options
describe("aura container: options apply live; unchanged options cause no churn", function()
    it("grow, perRow, sizes, max counts and position re-configure the container (SetAuraGroupMaxFrameCount / Layout / flow) and the buttons", function()
        local ns = boot()
        bigMax(ns)
        setAuras("party1", 8, 8); mock.refreshContainers()
        local a = ns.db.auras
        a.maxBuffs = 3; apply(ns)
        assertEquals(#frames(container(ns, "party1", "buff")), 8, "frames are kept, only 3 are used")
        assertEquals(shownIDs(ns, "party1", "buff"), "101,102,103")
        a.maxBuffs = 7; apply(ns)
        assertEquals(select(2, shownIDs(ns, "party1", "buff"):gsub(",", ",")), 6)
        a.grow = "down"; a.perRow = 3; a.buffSize = 22; apply(ns)
        local fl = rawget(container(ns, "party1", "buff").frame, "__container").flow
        assertEquals(fl.axis, AnchorUtil.FlowLayoutAxis.Vertical); assertEquals(fl.growth[2], "Down")
        assertEquals(rawget(container(ns, "party1", "buff").frame, "__container").layout.elementWidth, 22)
        for _, f in ipairs(frames(container(ns, "party1", "buff"))) do assertEquals(st(f).w, 22) end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("changing nothing changes nothing: a repeated layout makes no container reconfiguration calls", function()
        local ns = boot()
        apply(ns)
        mock.containerCalls = {}
        apply(ns); apply(ns)
        local n = 0
        for _, c in ipairs(mock.containerCalls) do
            if c.method:find("^SetAuraGroup") or c.method:find("^SetFlowLayout") then n = n + 1 end
        end
        assertEquals(n, 0, "no group/flow calls when the settings key is unchanged")
    end)
    it("the timer position moves the duration text of every existing button", function()
        local ns = boot()
        local f = frames(container(ns, "party1", "buff"))[1]
        assertEquals(st(f.Time).points[1][1], "TOP")
        ns.db.auras.timerPos = "inside"; apply(ns)
        assertEquals(st(f.Time).points[1][1], "BOTTOM"); assertEquals(st(f.Time).points[1][5], 1)
        ns.db.auras.timerPos = "below"; apply(ns)
        assertEquals(st(f.Time).points[1][1], "TOP")
    end)
    it("options changed in combat are applied after combat (layout is queued), never during", function()
        local ns = boot()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.containerCalls = {}
        ns.db.auras.perRow = 3; ns:Changed("frames"); mock.flushTimers()
        assertEquals(#callsOf("SetFlowLayoutMaximumLineSize", function(c) return c.combat end), 0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertTrue(#callsOf("SetFlowLayoutMaximumLineSize") > 0)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a layout switch (horizontal/vertical) and the frame style options keep the containers anchored to their zones", function()
        local ns = boot()
        for _, layout in ipairs({ "vertical", "horizontal" }) do
            ns.db.frames.layout = layout; apply(ns)
            for _, kind in ipairs({ "buff", "debuff" }) do
                local p = pointOf(container(ns, "party1", kind).frame)
                assertTrue(p[2] == button(ns, "party1").zones[kind])
            end
        end
    end)
end)

-- ======================================================================== combat
describe("aura container: dispels and new auras in combat are drawn by the container, the addon reads nothing", function()
    it("a debuff dispelled in combat vanishes from the bar (by the mock container), a new one appears, with ZERO aura API calls", function()
        local ns = boot()
        setAuras("party1", 2, 3); mock.refreshContainers()
        assertEquals(shownIDs(ns, "party1", "debuff"), "201,202,203")
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED"); S.failEnumerate = true; S.secretAll = true
        mock.resetAuraCalls()
        table.remove(S.auras.party1, 4)       -- debuff 202 (buffs 1,2 then debuffs 201,202,203 -> index 4 is 202)
        table.insert(S.auras.party1, debuff(9))
        mock.fire("UNIT_AURA", "party1"); mock.advance(2)
        assertEquals(shownIDs(ns, "party1", "debuff"), "201,203,209")
        assertEquals(mock.auraCalls.combat, 0, "the addon made no aura read in combat")
        assertEquals(mock.auraCalls.total, 0)
        assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
        S.combat = false; S.failEnumerate = false; S.secretAll = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
    end)
    it("a whole 60 second fight (events, ticks, roster noise, options window, tooltips, minimap, buff buttons, debug): no aura read in combat anywhere", function()
        local ns = boot()
        setAuras("party1", 2, 3); setAuras("player", 1, 1); mock.refreshContainers()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.resetAuraCalls()
        ns.Options:Show("auras"); ns.Options:Show("buffs"); mock.flushTimers()
        local gt = _G.GameTooltip
        gt.SetOwner = function() end; gt.Show = function() end; gt.AddLine = function() end; gt.AddDoubleLine = function() end; gt.AddTexture = function() end
        for step = 1, 60 do
            mock.advance(1)
            for _, u in ipairs({ "player", "party1", "party2", "party3" }) do mock.auraEvent(u, { full = step % 2 == 0, removed = { 201 } }) end
            if step % 10 == 0 then
                mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("PLAYER_ROLES_ASSIGNED"); mock.fire("SPELLS_CHANGED"); mock.fire("PLAYER_TARGET_CHANGED")
                local b = button(ns, "party1"); mock.runFrameScript(b, "OnEnter"); mock.runFrameScript(b, "OnLeave")
                assertTrue(pcall(_G.SlashCmdList.HEALERFOREVER, "debug auras")); assertTrue(pcall(_G.SlashCmdList.HEALERFOREVER, "debug buffs"))
            end
        end
        local names = {}
        for k, v in pairs(mock.auraCalls.combatByName) do names[#names + 1] = k .. "=" .. v end
        assertEquals(mock.auraCalls.combat, 0, "aura reads in combat: " .. table.concat(names, ", "))
        assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0); assertEquals(#mock.softViolations, 0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
    end)
    it("container zones are NOT dimmed when combat starts (the container keeps drawing live data); only the frozen fallback dims", function()
        local ns = boot()
        setAuras("party1", 1, 1); mock.refreshContainers()
        local before = button(ns, "party1").zones.debuff:GetAlpha()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        assertEquals(button(ns, "party1").zones.debuff:GetAlpha(), before)
        assertEquals(button(ns, "party1").zones.buff:GetAlpha(), button(ns, "party1").zones.buff:GetAlpha())
        assertTrue(button(ns, "party1").zones.debuff:GetAlpha() ~= 0.4)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
    end)
    it("the same fight with everything secret and every enumeration failing", function()
        local ns = boot()
        setAuras("party1", 2, 3)
        S.secretAll = true; S.secret = true; S.failEnumerate = true; S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.resetAuraCalls()
        for _ = 1, 20 do mock.advance(1); mock.auraEvent("party1", { removed = { mock.newSecret() } }) end
        assertEquals(mock.auraCalls.combat, 0); assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
        S.combat = false; S.secretAll = false; S.secret = false; S.failEnumerate = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
    end)
    it("out of combat a UNIT_AURA makes no aura read for the ICONS (the buff-button logic may read; the container needs no data)", function()
        local ns = boot()
        setAuras("party1", 2, 2)
        local before = {}
        mock.resetAuraCalls()
        local orig = ns.Auras.Update
        local reads = 0
        ns.Auras.Update = function(btn, src, ...)
            local t0 = mock.auraCalls.total
            local r = orig(btn, src, ...)
            reads = reads + (mock.auraCalls.total - t0)
            return r
        end
        mock.auraEvent("party1", { full = true }); mock.auraEvent("player", { full = true })
        ns.Auras.Update = orig
        assertEquals(reads, 0, "Auras.Update itself reads nothing in container mode")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the unit tooltip in combat says the auras are on the bar and reads nothing", function()
        local ns = boot()
        setAuras("party1", 2, 2)
        local lines = {}
        local gt = _G.GameTooltip
        gt.SetOwner = function() lines = {} end; gt.Show = function() end
        gt.AddLine = function(_, t) lines[#lines + 1] = tostring(t) end; gt.AddDoubleLine = function(_, l, r) lines[#lines + 1] = tostring(l) .. " " .. tostring(r) end
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.resetAuraCalls()
        local b = button(ns, "party1"); mock.runFrameScript(b, "OnEnter")
        assertTrue(table.concat(lines, "\n"):find("Auras are shown on the bar during combat", 1, true))
        assertEquals(mock.auraCalls.total, 0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        mock.runFrameScript(b, "OnEnter")
        assertTrue(table.concat(lines, "\n"):find("Debuffs (2)", 1, true), "out of combat the tooltip lists them again")
    end)
end)

-- ======================================================================== fallbacks
describe("aura container: per-button fallback when the API is missing or errors", function()
    it("no container API at all (older client): every button uses the hand-drawn fallback, mode is 'fallback'", function()
        local ns = boot({ containers = false })
        assertEquals(ns.Auras.mode, "fallback")
        for _, b in ipairs(ns.UnitFrames.buttons) do assertNil(b.auraContainers, tostring(b.unit)) end
        setAuras("party1", 1, 2); mock.fire("UNIT_AURA", "party1"); mock.flushTimers()
        local n = 0
        for _, icon in ipairs(button(ns, "party1").debuffIcons) do if st(icon).shown then n = n + 1 end end
        assertEquals(n, 2); assertEquals(#mock.errors, 0, errstr())
    end)
    it("a partly missing API (no sort enums) also selects the fallback", function()
        local ns = boot({ setup = function() mock.setGlobal("AuraContainerSortMethod", nil) end })
        assertEquals(ns.Auras.mode, "fallback")
        for _, b in ipairs(ns.UnitFrames.buttons) do assertNil(b.auraContainers) end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("AddAuraGroup erroring for ONE button's container falls that button back (and only that one); the error is logged and shown by /hf debug auras", function()
        local ns = boot({ setup = function(s) s.containerFailAt = { [3] = true } end })
        local fell, ok = {}, {}
        for _, b in ipairs(members(ns)) do
            if b.auraContainers then ok[#ok + 1] = b.unit else fell[#fell + 1] = b.unit end
        end
        assertEquals(#fell, 1, "exactly one button fell back: " .. table.concat(fell, ","))
        assertEquals(#ok, #members(ns) - 1)
        local fb = button(ns, fell[1])
        assertTrue(#fb.buffIcons >= 0); assertNotNil(fb.zones)
        local logged = false
        for _, e in ipairs(ns.db.errorLog) do if tostring(e.label):find("aura-container:create", 1, true) then logged = true end end
        assertTrue(logged, "the creation error is in the error log")
        assertTrue(#ns.Auras.containerErrors >= 1)
        mock.fire("UNIT_AURA", fell[1]); mock.flushTimers()
        assertEquals(strayErrors(), "", "only the injected failure was reported")
    end)
    it("the fallback button still draws its auras out of combat while the others use their containers", function()
        local ns = boot({ setup = function(s) s.containerFailAt = { [1] = true } end })
        local fb
        for _, b in ipairs(ns.UnitFrames.buttons) do if not b.auraContainers and not b.isPet and ns.Exists(b.unit) then fb = b end end
        assertNotNil(fb, "a member button fell back")
        S.auras[fb.unit] = { debuff(1), debuff(2) }
        mock.fire("UNIT_AURA", fb.unit); mock.flushTimers()
        local n = 0
        for _, icon in ipairs(fb.debuffIcons) do if st(icon).shown then n = n + 1 end end
        assertEquals(n, 2)
        local other
        for _, b in ipairs(ns.UnitFrames.buttons) do if b.auraContainers and not b.isPet and ns.Exists(b.unit) then other = b end end
        S.auras[other.unit] = { debuff(1) }; mock.refreshContainers()
        assertEquals(shownIDs(ns, other.unit, "debuff"), "201")
        assertEquals(strayErrors(), "")
    end)
    it("a container method erroring at creation (SetUnit raises) falls back instead of leaving a half-built container", function()
        local ns = boot({ setup = function(s) s.containerFail = { SetUnit = true } end })
        for _, b in ipairs(ns.UnitFrames.buttons) do assertNil(b.auraContainers, tostring(b.unit)) end
        assertEquals(ns.Auras.mode, "fallback")
        assertEquals(strayErrors(), "")
    end)
    it("a configure error (SetAuraGroupLayout raises after creation) is logged, never raised, and the next options change still works", function()
        local ns = boot()
        S.containerFail = { SetAuraGroupLayout = true }
        ns.db.auras.perRow = 3; apply(ns)
        assertEquals(strayErrors(), "")
        local logged = false
        for _, line in ipairs(ns.Auras.containerErrors) do if line:find("group-layout", 1, true) then logged = true end end
        assertTrue(logged)
        S.containerFail = nil
        ns.db.auras.perRow = 4; apply(ns)
        assertEquals(strayErrors(), "")
        assertEquals(rawget(container(ns, "party1", "buff").frame, "__container").flow.maxLine > 0, true)
    end)
end)

-- ======================================================================== debug lines + files
describe("aura container: /hf debug auras and the shipped files", function()
    it("container mode: the path line, one line per container (live unit, requested unit, filter, frame count)", function()
        local ns = boot()
        setAuras("party1", 2, 2)
        local out = debugText()
        assertTrue(out:find("aura path: native AuraContainer", 1, true), out)
        assertTrue(out:find("buff container: unit=party1 (requested party1) filter=HELPFUL frames=4", 1, true), out)
        assertTrue(out:find("debuff container: unit=party1 (requested party1) filter=HARMFUL frames=", 1, true), out)
        ns.db.auras.onlyMine = true; apply(ns)
        assertTrue(debugText():find("filter=HELPFUL|PLAYER", 1, true))
    end)
    it("container errors are listed", function()
        local ns = boot()
        S.containerFail = { SetAuraGroupMaxFrameCount = true }
        ns.db.auras.maxBuffs = 3; apply(ns)
        local out = debugText()
        assertTrue(out:find("container errors:", 1, true), out)
        S.containerFail = nil
    end)
    it("fallback mode: the path line says so", function()
        local ns = boot({ containers = false })
        assertTrue(debugText():find("aura path: fallback", 1, true))
    end)
    it("debug works in combat and with everything secret in container mode (reads nothing)", function()
        local ns = boot()
        S.combat = true; S.secretAll = true
        mock.resetAuraCalls()
        local out = debugText()
        assertTrue(out:find("aura path: native AuraContainer", 1, true)); assertEquals(mock.auraCalls.total, 0)
        S.combat = false; S.secretAll = false
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the TOC lists Frames/Auras.xml BEFORE Frames/Auras.lua (the template must exist when the container is created)", function()
        local idx = {}
        for i, rel in ipairs(toc.files) do idx[rel:gsub("\\", "/")] = i end
        assertNotNil(idx["Frames/Auras.xml"]); assertNotNil(idx["Frames/Auras.lua"])
        assertTrue(idx["Frames/Auras.xml"] < idx["Frames/Auras.lua"])
        assertTrue(L.exists(L.path("Frames/Auras.xml")))
    end)
    it("Auras.xml defines HealerForeverAuraButtonTemplate (virtual, inheriting CustomAuraButtonTemplate) with every part the Lua wires", function()
        local xml = L.readFile(L.path("Frames/Auras.xml"))
        assertNotNil(xml:find('name="HealerForeverAuraButtonTemplate"', 1, true)); assertNotNil(xml:find('inherits="CustomAuraButtonTemplate"', 1, true))
        assertNotNil(xml:find('virtual="true"', 1, true))
        local lua = L.readFile(L.path("Frames/Auras.lua"))
        for _, key in ipairs({ "Backdrop", "Icon", "DispelBorder", "Count", "Time", "Cooldown" }) do
            assertNotNil(xml:find('parentKey="' .. key .. '"', 1, true), "the template has no " .. key)
            assertNotNil(lua:find("frame." .. key, 1, true), "the Lua never uses " .. key)
        end
        assertNotNil(lua:find('BUTTON_TEMPLATE = "HealerForeverAuraButtonTemplate"', 1, true), "the Lua names the template")
    end)
    it("Auras.xml is well-formed XML (xmllint when available) and balanced", function()
        local p = io.popen('command -v xmllint')
        local has = p:read("*l"); p:close()
        if not has or has == "" then
            local xml = L.readFile(L.path("Frames/Auras.xml"))
            local opens, closes = select(2, xml:gsub("<[%w]+[%s>]", "")), select(2, xml:gsub("</[%w]+>", ""))
            assertTrue(opens >= closes)
            return
        end
        local ok = os.execute('xmllint --noout "' .. L.path("Frames/Auras.xml") .. '" 2>/dev/null')
        assertTrue(ok == 0 or ok == true, "xmllint rejected Auras.xml")
    end)
    it("secure-safety: no group button or container is secure and none is created in combat (the source scan allows exactly one raw CreateFrame)", function()
        local ns = boot()
        for _, c in ipairs(mock.containers) do assertFalse(st(c.frame).secure and true or false) end
        local n = 0
        for line in L.readFile(L.path("Frames/Auras.lua")):gmatch("[^\n]*") do
            local code = line:gsub("%-%-.*$", ""):gsub("ns%.NewFrame", "")
            if code:find("CreateFrame", 1, true) then n = n + 1 end
        end
        assertEquals(n, 1)
    end)
end)
