-- Raid layout, pure helpers (Util/RaidLayout.lua): which layout is wanted (DesiredLayout), the group grid (GroupOrder,
-- GridCells), the bijection of the 40 raid buttons onto the 40 cells (AssignCells), settings validation (Normalize),
-- the text layout rule (TextLayout: the number is never shrunk for width below 10 px and never cut, the name is cut first
-- and dropped below 6 px) and the debuff icon size (DebuffIconSize).
local L = require("loader")
local mock = require("wow_mock")

local ns, missing, errs = L.loadContract({})
if not ns.RaidLayout then
    it("Util/RaidLayout.lua loads", function() error("RaidLayout missing: " .. table.concat(missing, ",") .. " " .. tostring(errs["Util/RaidLayout.lua"])) end)
    return
end
local RL = ns.RaidLayout
local D = ns.DEFAULTS.raid

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end
local function cfg(over)
    local c = RL.Normalize(deepcopy(D), D)
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

-- ------------------------------------------------------------------------------------------------ DesiredLayout
describe("raid layout: DesiredLayout (which layout is wanted)", function()
    local function want(ctx)
        local layout, reason = RL.DesiredLayout(ctx)
        assertTrue(type(reason) == "string" and reason ~= "", "a readable reason is always given")
        return layout
    end
    it("Always party / Always raid win over everything (raid, battleground, arena, solo)", function()
        for _, inst in ipairs({ "none", "party", "raid", "pvp", "arena" }) do
            for _, inRaid in ipairs({ true, false }) do
                for _, size in ipairs({ 0, 3, 5, 6, 25, 40 }) do
                    assertEquals(want({ mode = "party", inRaid = inRaid, size = size, instanceType = inst, onlyAbove5 = false, oneSubgroup = false }), "party")
                    assertEquals(want({ mode = "raid", inRaid = inRaid, size = size, instanceType = inst, onlyAbove5 = true, oneSubgroup = true }), "raid")
                end
            end
        end
    end)
    it("Always raid also applies solo (the raid buttons then show you and your party)", function()
        assertEquals(want({ mode = "raid", inRaid = false, size = 0, instanceType = "none" }), "raid")
    end)
    it("auto: not in a raid -> party", function()
        assertEquals(want({ mode = "auto", inRaid = false, size = 0, instanceType = "none", onlyAbove5 = true }), "party")
        assertEquals(want({ mode = "auto", inRaid = false, size = 5, instanceType = "party", onlyAbove5 = false }), "party")
    end)
    it("auto: battleground -> raid even outside a raid group; arena -> party even in a raid", function()
        assertEquals(want({ mode = "auto", inRaid = false, size = 5, instanceType = "pvp", onlyAbove5 = true, oneSubgroup = true }), "raid")
        assertEquals(want({ mode = "auto", inRaid = true, size = 3, instanceType = "pvp", onlyAbove5 = true, oneSubgroup = true }), "raid")
        assertEquals(want({ mode = "auto", inRaid = true, size = 10, instanceType = "arena", onlyAbove5 = false, oneSubgroup = false }), "party")
    end)
    it("auto in a raid: 'only above 5' keeps the party layout only for <= 5 players all in one subgroup", function()
        local function t(size, onlyAbove5, oneSubgroup) return want({ mode = "auto", inRaid = true, size = size, instanceType = "raid", onlyAbove5 = onlyAbove5, oneSubgroup = oneSubgroup }) end
        assertEquals(t(5, true, true), "party")
        assertEquals(t(2, true, true), "party")
        assertEquals(t(6, true, true), "raid", "6 players never fit the party frames")
        assertEquals(t(5, true, false), "raid", "a 5-man raid split over subgroups needs the raid layout")
        assertEquals(t(4, true, nil), "raid", "an unknown subgroup layout (secret roster) uses the raid layout")
        assertEquals(t(5, false, true), "raid", "option off: any raid uses the raid layout")
        assertEquals(t(25, true, false), "raid")
        assertEquals(t(40, false, false), "raid")
    end)
    it("auto in a raid with an unknown size counts as a full raid", function()
        assertEquals(want({ mode = "auto", inRaid = true, size = nil, instanceType = "none", onlyAbove5 = true, oneSubgroup = true }), "raid")
    end)
    it("the reason says why (setting, battleground, arena, not in a raid, size)", function()
        local _, r1 = RL.DesiredLayout({ mode = "party" }); assertTrue(r1:find("party", 1, true) ~= nil, r1)
        local _, r2 = RL.DesiredLayout({ mode = "auto", instanceType = "pvp" }); assertTrue(r2:find("battleground", 1, true) ~= nil, r2)
        local _, r3 = RL.DesiredLayout({ mode = "auto", instanceType = "arena" }); assertTrue(r3:find("arena", 1, true) ~= nil, r3)
        local _, r4 = RL.DesiredLayout({ mode = "auto", inRaid = false }); assertTrue(r4:find("not in a raid", 1, true) ~= nil, r4)
        local _, r5 = RL.DesiredLayout({ mode = "auto", inRaid = true, size = 17 }); assertTrue(r5:find("17", 1, true) ~= nil, r5)
    end)
    it("no context at all does not raise and keeps the party layout", function()
        assertEquals(want(nil), "party")
    end)
end)

-- ------------------------------------------------------------------------------------------------ grid
local function rectsOverlap(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

-- every cell of a grid as a rectangle
local function cellRects(grid, c)
    local out = {}
    for g = 1, 8 do
        for s = 1, 5 do
            local cell = grid.cells[g][s]
            out[#out + 1] = { x = cell.x, y = cell.y, w = c.width, h = c.height, group = g, slot = s, cell = cell }
        end
    end
    return out
end

describe("raid layout: GroupOrder and GridCells", function()
    it("GroupOrder: all 8 groups in order when empty groups are kept", function()
        local order, visible = RL.GroupOrder({ 0, 5, 0, 1 }, { hideEmptyGroups = false })
        assertDeepEquals(order, { 1, 2, 3, 4, 5, 6, 7, 8 }); assertEquals(visible, 8)
    end)
    it("GroupOrder: hide empty groups puts the non-empty ones first (ascending) and only counts them", function()
        local order, visible = RL.GroupOrder({ [2] = 5, [4] = 1, [7] = 3 }, { hideEmptyGroups = true })
        assertDeepEquals(order, { 2, 4, 7, 1, 3, 5, 6, 8 }); assertEquals(visible, 3)
        local _, none = RL.GroupOrder({}, { hideEmptyGroups = true })
        assertEquals(none, 1, "at least one group is visible (anchor never 0 size)")
    end)

    local sweep = {}
    for _, arrange in ipairs({ "columns", "rows" }) do
        for _, per in ipairs({ 8, 4, 2 }) do
            for _, labels in ipairs({ true, false }) do
                for _, size in ipairs({ { 40, 14, 0 }, { 64, 24, 2 }, { 120, 40, 8 }, { 77, 19, 5 } }) do
                    sweep[#sweep + 1] = { groupArrange = arrange, groupsPerLine = per, groupLabels = labels, width = size[1], height = size[2], spacing = size[3] }
                end
            end
        end
    end

    it("40 unique cells that never overlap, for columns/rows x 8/4/2 x labels x sizes", function()
        for _, over in ipairs(sweep) do
            local c = cfg(over)
            local grid = RL.GridCells(c)
            local rects = cellRects(grid, c)
            assertEquals(#rects, 40)
            for i = 1, #rects do
                for j = i + 1, #rects do
                    assertFalse(rectsOverlap(rects[i], rects[j]), string.format("%s/%d labels=%s %dx%d sp=%d: cells G%d.%d and G%d.%d overlap",
                        c.groupArrange, c.groupsPerLine, tostring(c.groupLabels), c.width, c.height, c.spacing,
                        rects[i].group, rects[i].slot, rects[j].group, rects[j].slot))
                end
            end
        end
    end)
    it("neighbour bars in a group are exactly `spacing` apart; groups are spacing + 6 apart", function()
        for _, over in ipairs(sweep) do
            local c = cfg(over)
            local grid = RL.GridCells(c)
            local a, b = grid.cells[1][1], grid.cells[1][2]
            if c.groupArrange == "columns" then
                assertEquals(b.y - a.y, c.height + c.spacing); assertEquals(b.x, a.x)
            else
                assertEquals(b.x - a.x, c.width + c.spacing); assertEquals(b.y, a.y)
            end
            local g2 = grid.cells[2][1]
            if c.groupsPerLine > 1 then
                if c.groupArrange == "columns" then assertEquals(g2.x - a.x, grid.blockW + c.spacing + RL.GROUP_GAP)
                else assertEquals(g2.y - a.y, grid.blockH + c.spacing + RL.GROUP_GAP) end
            end
        end
    end)
    it("groups per line: 8 = one line, 4 = 4x2, 2 = 2x4 (columns); rows mirror it", function()
        local function lines(c)
            local grid = RL.GridCells(c)
            local xs, ys = {}, {}
            for g = 1, 8 do xs[grid.cells[g][1].x] = true; ys[grid.cells[g][1].y] = true end
            local nx, ny = 0, 0
            for _ in pairs(xs) do nx = nx + 1 end
            for _ in pairs(ys) do ny = ny + 1 end
            return nx, ny
        end
        for per, want in pairs({ [8] = { 8, 1 }, [4] = { 4, 2 }, [2] = { 2, 4 } }) do
            local nx, ny = lines(cfg({ groupArrange = "columns", groupsPerLine = per }))
            assertDeepEquals({ nx, ny }, want, "columns per line " .. per)
            nx, ny = lines(cfg({ groupArrange = "rows", groupsPerLine = per }))
            assertDeepEquals({ ny, nx }, want, "rows per line " .. per)
        end
    end)
    it("the anchor size is exactly the bounding box of the visible groups (labels included)", function()
        for _, over in ipairs(sweep) do
            local c = cfg(over)
            for _, visible in ipairs({ 1, 2, 3, 5, 8 }) do
                local grid = RL.GridCells(c, { 1, 2, 3, 4, 5, 6, 7, 8 }, visible)
                local maxX, maxY = 0, 0
                for k = 1, visible do
                    for s = 1, 5 do
                        local cell = grid.cells[k][s]
                        maxX = math.max(maxX, cell.x + c.width); maxY = math.max(maxY, cell.y + c.height)
                    end
                end
                assertEquals(grid.width, maxX, "width " .. over.groupArrange .. "/" .. over.groupsPerLine .. " visible " .. visible)
                assertEquals(grid.height, maxY, "height visible " .. visible)
            end
        end
    end)
    it("group labels are shown only for visible groups and never cover a bar", function()
        for _, over in ipairs(sweep) do
            local c = cfg(over)
            local grid = RL.GridCells(c, { 3, 1, 2, 4, 5, 6, 7, 8 }, 3)
            local rects = cellRects(grid, c)
            for k, g in ipairs({ 3, 1, 2, 4, 5, 6, 7, 8 }) do
                local lab = grid.labels[g]
                assertEquals(lab.shown, c.groupLabels and k <= 3, "label G" .. g)
                if c.groupLabels then
                    local lr = c.groupArrange == "columns" and { x = lab.x, y = lab.y, w = c.width, h = RL.LABEL_H }
                        or { x = lab.x, y = lab.y, w = RL.LABEL_W, h = c.height }
                    for _, r in ipairs(rects) do assertFalse(rectsOverlap(lr, r), "label G" .. g .. " covers G" .. r.group .. "." .. r.slot) end
                end
            end
        end
    end)
end)

-- ------------------------------------------------------------------------------------------------ AssignCells
local function roster(n, groupOf, extra)
    local r = {}
    for i = 1, n do
        local e = { index = i, group = groupOf and groupOf(i) or math.ceil(i / 5) }
        for k, v in pairs(extra and extra(i) or {}) do e[k] = v end
        r[#r + 1] = e
    end
    return r
end

local function assertBijection(plan, label)
    local seen = {}
    for i = 1, 40 do
        local cell = plan.byButton[i]
        assertNotNil(cell, label .. ": button " .. i .. " has no cell")
        assertNil(seen[cell], label .. ": buttons " .. tostring(seen[cell]) .. " and " .. i .. " share a cell")
        seen[cell] = i
    end
    local n = 0
    for g = 1, 8 do for s = 1, 5 do n = n + 1; assertNotNil(seen[plan.grid.cells[g][s]], label .. ": cell G" .. g .. "." .. s .. " unused") end end
    assertEquals(n, 40)
end

describe("raid layout: AssignCells (40 buttons onto 40 cells)", function()
    it("is a bijection for every raid size 0..40 and both 'hide empty' settings", function()
        for _, hide in ipairs({ true, false }) do
            for n = 0, 40 do
                local plan = RL.AssignCells(roster(n), cfg({ hideEmptyGroups = hide }))
                assertBijection(plan, "n=" .. n .. " hide=" .. tostring(hide))
            end
        end
    end)
    it("members sit in their own group's cells, in raid index order", function()
        local groups = { 3, 1, 3, 1, 8, 3 }
        local plan = RL.AssignCells(roster(6, function(i) return groups[i] end), cfg({ hideEmptyGroups = false }))
        assertBijection(plan, "mixed")
        assertEquals(plan.byButton[2].group, 1); assertEquals(plan.byButton[2].slot, 1)
        assertEquals(plan.byButton[4].group, 1); assertEquals(plan.byButton[4].slot, 2)
        assertEquals(plan.byButton[1].group, 3); assertEquals(plan.byButton[1].slot, 1)
        assertEquals(plan.byButton[3].group, 3); assertEquals(plan.byButton[3].slot, 2)
        assertEquals(plan.byButton[6].group, 3); assertEquals(plan.byButton[6].slot, 3)
        assertEquals(plan.byButton[5].group, 8); assertEquals(plan.byButton[5].slot, 1)
    end)
    it("unused buttons fill the remaining free cells, so a mid-combat joiner never covers a bar", function()
        local plan = RL.AssignCells(roster(10), cfg())
        local member = {}
        for i = 1, 10 do member[plan.byButton[i]] = true end
        for i = 11, 40 do assertNil(member[plan.byButton[i]], "button " .. i .. " sits on a member's cell") end
    end)
    it("a group with more than 5 entries (bad roster data) overflows into free cells, still a bijection", function()
        local plan = RL.AssignCells(roster(8, function() return 1 end), cfg())
        assertBijection(plan, "overflow")
        for i = 1, 5 do assertEquals(plan.byButton[i].group, 1, "the first five keep group 1") end
        assertEquals(plan.counts[1], 5)
    end)
    it("bad and duplicate indexes are ignored; a bad group falls back to ceil(i / 5)", function()
        local secret = mock.newSecret()
        local r = { { index = 0, group = 1 }, { index = 41, group = 1 }, { index = 2.5, group = 1 }, { index = "3", group = 1 },
            { index = 7, group = 2 }, { index = 7, group = 1 }, "junk", { group = 1 },
            { index = 12, group = 0 }, { index = 13, group = 9 }, { index = 14, group = 1.5 }, { index = 15, group = secret } }
        local plan = RL.AssignCells(r, cfg({ hideEmptyGroups = false }))
        assertBijection(plan, "bad input")
        assertEquals(plan.byButton[7].group, 2, "the first entry for a duplicate index wins")
        assertEquals(plan.byButton[12].group, 3); assertEquals(plan.byButton[13].group, 3)
        assertEquals(plan.byButton[14].group, 3); assertEquals(plan.byButton[15].group, 3, "secret group -> ceil(15/5)")
        assertEquals(plan.counts[1], 0, "no valid entry landed in group 1")
    end)
    it("hide empty groups: non-empty groups are drawn first and only they size the anchor", function()
        local c = cfg({ hideEmptyGroups = true, groupArrange = "columns", groupsPerLine = 8 })
        local plan = RL.AssignCells(roster(3, function(i) return ({ 6, 2, 6 })[i] end), c)
        assertBijection(plan, "hide empty")
        assertDeepEquals({ plan.order[1], plan.order[2] }, { 2, 6 })
        assertEquals(plan.visible, 2)
        assertEquals(plan.byButton[2].x, 0, "group 2 is drawn first")
        assertEquals(plan.grid.width, 2 * c.width + c.spacing + RL.GROUP_GAP)
        for i = 1, 3 do
            local cell = plan.byButton[i]
            assertTrue(cell.x + c.width <= plan.grid.width and cell.y + c.height <= plan.grid.height, "member " .. i .. " inside the anchor")
        end
        local all = RL.AssignCells(roster(3, function(i) return ({ 6, 2, 6 })[i] end), cfg({ hideEmptyGroups = false }))
        assertEquals(all.visible, 8); assertEquals(all.byButton[1].group, 6)
        assertEquals(all.byButton[1].x, 5 * (c.width + c.spacing + RL.GROUP_GAP), "group 6 keeps its place when empty groups are shown")
    end)
    it("sort within groups: role (tank, healer, damage, unknown last) and class, ties by raid index", function()
        local roles = { "DAMAGER", nil, "HEALER", "TANK", "DAMAGER" }
        local plan = RL.AssignCells(roster(5, nil, function(i) return { role = roles[i] } end), cfg({ sortWithin = "role" }))
        local bySlot = {}
        for i = 1, 5 do bySlot[plan.byButton[i].slot] = i end
        assertDeepEquals(bySlot, { 4, 3, 1, 5, 2 })
        local classes = { "WARRIOR", "DRUID", nil, "MAGE", "DRUID" }
        plan = RL.AssignCells(roster(5, nil, function(i) return { class = classes[i] } end), cfg({ sortWithin = "class" }))
        bySlot = {}
        for i = 1, 5 do bySlot[plan.byButton[i].slot] = i end
        assertDeepEquals(bySlot, { 2, 5, 4, 1, 3 })
        plan = RL.AssignCells(roster(5, nil, function(i) return { role = roles[i], class = classes[i] } end), cfg({ sortWithin = "none" }))
        for i = 1, 5 do assertEquals(plan.byButton[i].slot, i, "none keeps raid index order") end
    end)
end)

-- ------------------------------------------------------------------------------------------------ Normalize
describe("raid layout: Normalize (saved raid settings are validated)", function()
    it("nil / non-table input gives exactly the defaults", function()
        assertDeepEquals(RL.Normalize(nil, D), D)
        assertDeepEquals(RL.Normalize("junk", D), D)
        assertDeepEquals(RL.Normalize({}, D), D)
        assertDeepEquals(RL.Normalize({ buffs = 5, debuffs = "x" }, D), D)
    end)
    it("the defaults are what the owner decided (plan 1)", function()
        assertEquals(D.layoutMode, "auto"); assertEquals(D.onlyAbove5, true)
        assertDeepEquals(D.point, { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 60, y = -330 })
        assertEquals(D.scale, 100); assertEquals(D.width, 64); assertEquals(D.height, 24); assertEquals(D.spacing, 2)
        assertEquals(D.groupArrange, "columns"); assertEquals(D.groupsPerLine, 8); assertEquals(D.groupLabels, true)
        assertEquals(D.sortWithin, "none"); assertEquals(D.hideEmptyGroups, true)
        assertEquals(D.showNames, true); assertEquals(D.nameSize, 7); assertEquals(D.nameLength, 7)
        assertEquals(D.healthText, "deficit"); assertEquals(D.muteFull, true); assertEquals(D.showIncoming, true); assertEquals(D.rangeAlpha, 50)
        assertDeepEquals(D.buffs, { show = true, size = 10, rebuffPercent = 5, showEnding = true, endingLook = "pulse", multi = "state", inCombat = "hide" })
        assertDeepEquals(D.debuffs, { show = true, display = "glowIcons", max = 3, size = 10 })
        assertNil(D.order, "raid keys must not be named order (atomic globally)"); assertNil(D.custom, "nor custom")
    end)
    it("numbers are clamped to their range", function()
        local r = RL.Normalize({ scale = 10, width = 500, height = 2, spacing = -3, nameSize = 99, nameLength = 1, rangeAlpha = 0,
            buffs = { size = 1, rebuffPercent = 50 }, debuffs = { max = 9, size = 100 } }, D)
        assertEquals(r.scale, 50); assertEquals(r.width, 120); assertEquals(r.height, 14); assertEquals(r.spacing, 0)
        assertEquals(r.nameSize, 10); assertEquals(r.nameLength, 3); assertEquals(r.rangeAlpha, 10)
        assertEquals(r.buffs.size, 8); assertEquals(r.buffs.rebuffPercent, 20); assertEquals(r.debuffs.max, 3); assertEquals(r.debuffs.size, 16)
        r = RL.Normalize({ scale = 151, width = 39, height = 41, spacing = 9, nameSize = 5, nameLength = 13, rangeAlpha = 101,
            buffs = { size = 17, rebuffPercent = 0 }, debuffs = { max = 0, size = 7 } }, D)
        assertEquals(r.scale, 150); assertEquals(r.width, 40); assertEquals(r.height, 40); assertEquals(r.spacing, 8)
        assertEquals(r.nameSize, 6); assertEquals(r.nameLength, 12); assertEquals(r.rangeAlpha, 100)
        assertEquals(r.buffs.size, 16); assertEquals(r.buffs.rebuffPercent, 1); assertEquals(r.debuffs.max, 1); assertEquals(r.debuffs.size, 8)
    end)
    it("scale and range alpha snap to steps of 5; other numbers round to whole pixels", function()
        local r = RL.Normalize({ scale = 103, rangeAlpha = 12, width = 64.4, height = 23.6 }, D)
        assertEquals(r.scale, 105); assertEquals(r.rangeAlpha, 10); assertEquals(r.width, 64); assertEquals(r.height, 24)
        r = RL.Normalize({ scale = 97.4, rangeAlpha = 77.5 }, D)
        assertEquals(r.scale, 95); assertEquals(r.rangeAlpha, 80)
    end)
    it("NaN, infinity, strings and booleans in number fields fall back to the default", function()
        for _, bad in ipairs({ 0 / 0, math.huge, -math.huge, "64", true, {} }) do
            local r = RL.Normalize({ width = bad, scale = bad, buffs = { size = bad }, debuffs = { max = bad } }, D)
            assertEquals(r.width, D.width); assertEquals(r.scale, D.scale); assertEquals(r.buffs.size, D.buffs.size); assertEquals(r.debuffs.max, D.debuffs.max)
        end
    end)
    it("enums only accept their listed values", function()
        local r = RL.Normalize({ layoutMode = "RAID", groupArrange = "grid", groupsPerLine = 3, sortWithin = 1, healthText = "lost",
            buffs = { endingLook = "glow", multi = "all", inCombat = "show" }, debuffs = { display = "letters" } }, D)
        assertEquals(r.layoutMode, "auto"); assertEquals(r.groupArrange, "columns"); assertEquals(r.groupsPerLine, 8)
        assertEquals(r.sortWithin, "none"); assertEquals(r.healthText, "deficit")
        assertEquals(r.buffs.endingLook, "pulse"); assertEquals(r.buffs.multi, "state"); assertEquals(r.buffs.inCombat, "hide")
        assertEquals(r.debuffs.display, "glowIcons")
        for name, list in pairs(RL.ENUMS) do
            for _, v in ipairs(list) do
                local input = { buffs = {}, debuffs = {} }
                local holder = (name == "endingLook" or name == "multi" or name == "inCombat") and input.buffs or (name == "display" and input.debuffs or input)
                holder[name] = v
                local out = RL.Normalize(input, D)
                local got = (holder == input.buffs and out.buffs[name]) or (holder == input.debuffs and out.debuffs[name]) or out[name]
                assertEquals(got, v, name .. "=" .. v .. " is valid")
            end
        end
        for _, v in ipairs({ 8, 4, 2 }) do assertEquals(RL.Normalize({ groupsPerLine = v }, D).groupsPerLine, v) end
    end)
    it("booleans must be booleans (1, 'true', nil fall back)", function()
        local r = RL.Normalize({ onlyAbove5 = "false", groupLabels = 0, hideEmptyGroups = nil, showNames = 1, muteFull = {},
            buffs = { show = "no", showEnding = 1 }, debuffs = { show = "yes" } }, D)
        assertEquals(r.onlyAbove5, true); assertEquals(r.groupLabels, true); assertEquals(r.hideEmptyGroups, true)
        assertEquals(r.showNames, true); assertEquals(r.muteFull, true); assertEquals(r.buffs.show, true)
        assertEquals(r.buffs.showEnding, true); assertEquals(r.debuffs.show, true)
        r = RL.Normalize({ onlyAbove5 = false, buffs = { show = false }, debuffs = { show = false } }, D)
        assertEquals(r.onlyAbove5, false); assertEquals(r.buffs.show, false); assertEquals(r.debuffs.show, false)
    end)
    it("a broken point falls back to a COPY of the default point; a good point is kept", function()
        for _, bad in ipairs({ "x", { point = "TOP" }, { point = "TOP", relativePoint = "TOP", x = "1", y = 2 },
            { point = "TOP", relativePoint = "TOP", x = 0 / 0, y = 2 }, { point = 1, relativePoint = "TOP", x = 1, y = 2 } }) do
            local r = RL.Normalize({ point = bad }, D)
            assertDeepEquals(r.point, D.point)
            assertTrue(r.point ~= D.point, "never the DEFAULTS table itself (a drag would change the defaults)")
        end
        local good = { point = "CENTER", relativePoint = "BOTTOM", x = 12.5, y = -3 }
        assertDeepEquals(RL.Normalize({ point = good }, D).point, good)
    end)
    it("valid values are kept, unknown keys survive, and Normalize is idempotent", function()
        local input = { layoutMode = "raid", onlyAbove5 = false, scale = 85, width = 90, height = 30, spacing = 4, groupArrange = "rows",
            groupsPerLine = 2, groupLabels = false, sortWithin = "class", hideEmptyGroups = false, showNames = false, nameSize = 9,
            nameLength = 10, point = { point = "CENTER", relativePoint = "CENTER", x = 5, y = 6 }, healthText = "percent", muteFull = false, showIncoming = false, rangeAlpha = 35, futureKey = "kept",
            buffs = { show = false, size = 14, rebuffPercent = 12, showEnding = false, endingLook = "sweep", multi = "stack", inCombat = "dim" },
            debuffs = { show = false, display = "icons", max = 2, size = 12 } }
        local want = deepcopy(input)
        local r = RL.Normalize(input, D)
        assertDeepEquals(r, want)
        assertDeepEquals(RL.Normalize(deepcopy(r), D), r)
    end)
    it("without defaults it asserts loudly (a programming error, not a silent reset)", function()
        local saved = ns.DEFAULTS
        ns.DEFAULTS = nil
        local ok = pcall(RL.Normalize, {}, nil)
        ns.DEFAULTS = saved
        assertFalse(ok)
    end)
end)

-- ------------------------------------------------------------------------------------------------ TextLayout
describe("raid layout: TextLayout (number never shrunk for width below 10 px, never cut; name cut first)", function()
    -- size the centre number gets from the bar height alone (mockup raid-style-d: max(9, min(18, round(h / 2))))
    local function heightSize(h) return math.max(9, math.min(18, math.floor(h * 0.5 + 0.5))) end

    it("sweep 40-120 x 14-40 x name 6-10 x names on/off: every rule holds", function()
        local n = 0
        for w = 40, 120 do
            for h = 14, 40 do
                for nameSize = 6, 10 do
                    for _, names in ipairs({ true, false }) do
                        n = n + 1
                        local c = { width = w, height = h, nameSize = nameSize, showNames = names }
                        local t = RL.TextLayout(c, 0, { len = 5 })
                        local label = string.format("w=%d h=%d name=%d names=%s", w, h, nameSize, tostring(names))
                        assertTrue(t.tfs >= math.min(10, heightSize(h)), label .. ": number shrunk to " .. t.tfs)
                        assertTrue(t.tfs <= heightSize(h), label .. ": number larger than the bar allows")
                        assertTrue(t.numLeft >= 1 and t.numLeft + t.numW <= w, label .. ": number cut (" .. t.numLeft .. "+" .. t.numW .. ")")
                        assertTrue(t.top >= 0 and t.top + t.tfs <= h + 1, label .. ": number leaves the bar vertically")
                        assertTrue(t.nameW == 0 or t.nameW >= 6, label .. ": name narrower than 6 px is dropped")
                        if not names then assertEquals(t.nameW, 0, label) end
                        if t.stacked and names then
                            assertTrue(t.top >= nameSize + 2, label .. ": stacked number overlaps the name line")
                        elseif t.nameW > 0 then
                            assertTrue(3 + t.nameW <= t.numLeft, label .. ": side-by-side name runs into the number")
                        end
                    end
                end
            end
        end
        assertTrue(n > 20000)
    end)
    it("width never shrinks the number below 10 px: a narrow bar cuts / drops the name instead", function()
        local wide = RL.TextLayout({ width = 120, height = 24, nameSize = 7, showNames = true }, 0, { len = 6 })
        local narrow = RL.TextLayout({ width = 40, height = 24, nameSize = 7, showNames = true }, 0, { len = 6 })
        assertEquals(narrow.tfs, 10)
        assertTrue(wide.tfs >= narrow.tfs)
        local side = RL.TextLayout({ width = 40, height = 14, nameSize = 10, showNames = true }, 0, { len = 5 })
        assertFalse(side.stacked)
        assertTrue(side.nameW > 0 and side.nameW < 40 - 4, "side by side: the name is cut to the room left of the number")
        assertTrue(3 + side.nameW <= side.numLeft)
        local dropped = RL.TextLayout({ width = 40, height = 14, nameSize = 10, showNames = true }, 0, { len = 6 })
        assertEquals(dropped.nameW, 0, "less than 6 px left of the number: the name is dropped, the number kept")
        assertTrue(dropped.numLeft + dropped.numW <= 40)
    end)
    it("a right reserve (debuff icons) moves the number left but never below 10 px", function()
        local free = RL.TextLayout({ width = 64, height = 24, nameSize = 7, showNames = true }, 0, { len = 5 })
        local reserved = RL.TextLayout({ width = 64, height = 24, nameSize = 7, showNames = true }, 30, { len = 5 })
        assertTrue(reserved.numLeft <= free.numLeft)
        assertTrue(reserved.tfs >= 10)
    end)
    it("buff markers narrow the name; small (state) text and empty text are handled", function()
        local plain = RL.TextLayout({ width = 80, height = 30, nameSize = 7, showNames = true }, 0, { len = 5 })
        local buffs = RL.TextLayout({ width = 80, height = 30, nameSize = 7, showNames = true }, 0, { len = 5, buffW = 23 })
        assertEquals(plain.nameW - buffs.nameW, 23)
        local small = RL.TextLayout({ width = 64, height = 24, nameSize = 7, showNames = true }, 0, { len = 7, big = false })
        assertTrue(small.tfs >= 7 and small.tfs <= 11)
        local empty = RL.TextLayout({ width = 64, height = 24, nameSize = 7, showNames = true }, 0, { len = 0 })
        assertTrue(empty.stacked); assertEquals(empty.numW, 0)
    end)
end)

-- ------------------------------------------------------------------------------------------------ TextLayout (text fix)
-- In game the centre text ran off the bar's LEFT edge (overflowing state texts, numbers squeezed by the icon reserve)
-- and the name touched the number. Rules: numLeft >= 2 always; state texts are sized for capitals (0.75 em) and shrink
-- to fit down to 6 px, then run right; stacked needs a 2 px gap under the name line; side by side the name ends 3 px
-- left of the number and starts >= 2 px; the name is dropped (< 6 px) before the number has to move.
describe("raid layout: TextLayout left clamp, state text shrink, 2 px gaps", function()
    local function heightSize(h) return math.max(9, math.min(18, math.floor(h * 0.5 + 0.5))) end
    local function stateSize(h) return math.max(7, math.min(11, math.floor(h * 0.36 + 0.5))) end
    -- where the number would go without the >= 2 clamp (the right-edge rule included)
    local function unclamped(t, w, areaR)
        local x
        if t.stacked then x = math.floor((areaR - t.numW) / 2 + 0.5) else x = math.floor(areaR - 2 - t.numW + 0.5) end
        if x + t.numW > w - 2 then x = w - 2 - t.numW end
        return x
    end

    it("sweep w 40-120 x h 14-40 x reserve 0-60 x name 6/8/10 x len 1-9 x number/state: every rule holds", function()
        local n, clamped, shrunk6, overflow, sideNames, dropped = 0, 0, 0, 0, 0, 0
        for w = 40, 120, 4 do
            for h = 14, 40, 2 do
                for _, nameSize in ipairs({ 6, 8, 10 }) do
                    for _, reserve in ipairs({ 0, 12, 23, 34, 45, 60 }) do
                        for _, len in ipairs({ 1, 3, 4, 5, 7, 9 }) do
                            for _, big in ipairs({ true, false }) do
                                n = n + 1
                                local c = { width = w, height = h, nameSize = nameSize, showNames = true }
                                local t = RL.TextLayout(c, reserve, { len = len, big = big })
                                local areaR = w - reserve
                                local label = string.format("w=%d h=%d name=%d res=%d len=%d big=%s", w, h, nameSize, reserve, len, tostring(big))
                                -- left clamp
                                assertTrue(t.numLeft >= 2, label .. ": numLeft " .. t.numLeft .. " left of the inner edge")
                                local free = unclamped(t, w, areaR)
                                if free < 2 then
                                    clamped = clamped + 1
                                    assertEquals(t.numLeft, 2, label .. ": clamped to exactly 2")
                                else
                                    assertEquals(t.numLeft, free, label .. ": moved although it had room")
                                end
                                if t.numW <= w - 4 then assertTrue(t.numLeft + t.numW <= w - 2, label .. ": past the right inner edge") end
                                if big then
                                    assertTrue(t.tfs >= math.min(10, heightSize(h)), label .. ": number below 10 px")
                                    assertEquals(t.numW, math.ceil(len * t.tfs * 0.6), label .. ": number width model")
                                else
                                    -- state text: capitals at 0.75 em, shrinks to fit the free area down to 6 px, then runs right
                                    assertEquals(t.numW, math.ceil(len * t.tfs * 0.75), label .. ": capitals width model")
                                    assertTrue(t.tfs >= 6 and t.tfs <= stateSize(h), label .. ": state size " .. t.tfs)
                                    if t.tfs > 6 then assertTrue(len * t.tfs * 0.75 <= areaR - 3, label .. ": wider than the free area above 6 px") end
                                    if t.tfs < stateSize(h) then
                                        assertTrue(len * (t.tfs + 1) * 0.75 > areaR - 3, label .. ": shrunk further than needed")
                                    end
                                    if t.tfs == 6 and stateSize(h) > 6 then shrunk6 = shrunk6 + 1 end
                                    if len * t.tfs * 0.75 > areaR - 3 then overflow = overflow + 1; assertEquals(t.tfs, 6, label) end
                                end
                                -- stacked: 2 px gap under the name line (nameSize + 2 tall)
                                assertEquals(t.stacked, h - (nameSize + 2) - 2 >= t.tfs, label .. ": stacked iff the 2 px gap fits")
                                if t.stacked then
                                    assertTrue(t.top >= nameSize + 3, label .. ": stacked number top " .. t.top .. " < nameSize + 3")
                                    assertTrue(t.top + t.tfs <= h, label .. ": stacked number leaves the bar")
                                else
                                    -- side by side: the name ends 3 px left of the number, starts at >= 2 px, or is dropped
                                    assertTrue(t.nameW == 0 or t.nameW >= 6, label .. ": name under 6 px kept")
                                    if t.nameW > 0 then
                                        sideNames = sideNames + 1
                                        assertTrue(t.nameW <= t.numLeft - 5, label .. ": name wider than numLeft - 5")
                                        assertTrue(t.numLeft - 3 - t.nameW >= 2, label .. ": name starts left of 2 px")
                                        assertTrue(free >= 2, label .. ": the number moved while the name was still shown")
                                    else
                                        dropped = dropped + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        assertTrue(n > 50000)
        -- the sweep really reaches every branch
        assertTrue(clamped > 0, "left clamp reached"); assertTrue(shrunk6 > 0, "6 px floor reached")
        assertTrue(overflow > 0, "overflow reached"); assertTrue(sideNames > 0, "side-by-side names reached")
        assertTrue(dropped > 0, "dropped names reached")
    end)
    it("narrowing a short bar: the name shrinks, is dropped, and only then does the number reach the left clamp", function()
        local c = { width = 60, height = 14, nameSize = 10, showNames = true }
        local lastName, nameGoneAt, clampAt = nil, nil, nil
        for reserve = 0, 60 do
            local t = RL.TextLayout(c, reserve, { len = 5 })
            assertFalse(t.stacked)
            if lastName then assertTrue(t.nameW <= lastName, "name never grows as the room shrinks (reserve " .. reserve .. ")") end
            lastName = t.nameW
            if t.nameW == 0 and not nameGoneAt then nameGoneAt = reserve end
            if t.numLeft == 2 and not clampAt then clampAt = reserve end
            if t.nameW > 0 then assertTrue(t.numLeft - 3 - t.nameW >= 2, "reserve " .. reserve .. ": name start") end
        end
        assertNotNil(nameGoneAt); assertNotNil(clampAt)
        assertTrue(nameGoneAt < clampAt, "name dropped at reserve " .. nameGoneAt .. ", number clamped at " .. clampAt)
    end)
    it("state text examples: CAN'T RES shrinks on a narrow bar, then runs right from 2 px", function()
        local c = { width = 64, height = 24, nameSize = 7, showNames = true }
        local roomy = RL.TextLayout(c, 0, { len = 9, big = false })
        assertEquals(roomy.tfs, 9, "64 px x 24: 9 capitals fit at the height size 9 (64 - 3 >= 9 * 9 * 0.75)")
        local mid = RL.TextLayout(c, 10, { len = 9, big = false })
        assertEquals(mid.tfs, 7, "54 px free: shrinks to 7 (floor(51 / 6.75))")
        local tight = RL.TextLayout(c, 23, { len = 9, big = false })
        assertEquals(tight.tfs, 6)
        assertTrue(tight.numLeft >= 2)
        local over = RL.TextLayout({ width = 40, height = 24, nameSize = 7, showNames = true }, 34, { len = 9, big = false })
        assertEquals(over.tfs, 6); assertEquals(over.numLeft, 2)
        assertTrue(over.numLeft + over.numW > 40 - 34, "runs right over the icons")
        -- 9 capitals at 6 px (41 px) don't fit a 40 px bar at all: the start stays at 2 px, the end is clipped on the right
        assertTrue(over.numW > 40 - 4)
    end)
    it("stacked boundary: exactly a 2 px gap stacks, 1 px puts the number beside the name", function()
        -- h 24, name 7 (line 9): tfs 12 (h / 2); 24 - 9 - 2 = 13 >= 12 stacked
        local t = RL.TextLayout({ width = 120, height = 24, nameSize = 7, showNames = true }, 0, { len = 5 })
        assertTrue(t.stacked); assertTrue(t.top >= 10)
        -- find a height where h - nameH - 2 == tfs exactly, and one where it is tfs - 1
        local exact, short
        for h = 14, 40 do
            local tt = RL.TextLayout({ width = 120, height = h, nameSize = 10, showNames = true }, 0, { len = 5 })
            local gap = h - 12 - tt.tfs
            if gap == 2 then exact = tt end
            if gap == 1 then short = tt end
        end
        assertNotNil(exact); assertTrue(exact.stacked, "2 px gap stacks"); assertEquals(exact.top, 13)
        assertNotNil(short); assertFalse(short.stacked, "1 px gap: side by side")
    end)
    it("number minimum 10 px even with a huge reserve; names off / empty text keep the clamp", function()
        local t = RL.TextLayout({ width = 40, height = 30, nameSize = 7, showNames = true }, 40, { len = 6 })
        assertEquals(t.tfs, 10); assertEquals(t.numLeft, 2)
        local nn = RL.TextLayout({ width = 40, height = 14, nameSize = 7, showNames = false }, 40, { len = 5 })
        assertEquals(nn.nameW, 0); assertTrue(nn.numLeft >= 2)
        local empty = RL.TextLayout({ width = 40, height = 14, nameSize = 7, showNames = true }, 40, { len = 0 })
        assertEquals(empty.numW, 0); assertTrue(empty.numLeft >= 2)
    end)
end)

-- ------------------------------------------------------------------------------------------------ DebuffIconSize
describe("raid layout: DebuffIconSize", function()
    it("follows max(7, min(base, floor((floor(w * 0.45) - 1) / max) - 1))", function()
        assertEquals(RL.DebuffIconSize(64, 3, 10), 8)
        assertEquals(RL.DebuffIconSize(64, 1, 10), 10)
        assertEquals(RL.DebuffIconSize(120, 3, 16), 16)
        assertEquals(RL.DebuffIconSize(40, 3, 10), 7)
        assertEquals(RL.DebuffIconSize(100, 2, 16), 20 > 16 and 16 or 20)
        assertEquals(RL.DebuffIconSize(80, 3, 16), 10)
    end)
    it("stays within [7, base] and the icons fit 45% of the bar unless the 7 px floor wins", function()
        for w = 40, 120 do
            for count = 1, 3 do
                for base = 8, 16 do
                    local s = RL.DebuffIconSize(w, count, base)
                    assertTrue(s >= 7 and s <= base, string.format("w=%d n=%d base=%d -> %d", w, count, base, s))
                    if s > 7 then assertTrue(count * (s + 1) + 1 <= math.floor(w * 0.45), string.format("w=%d n=%d -> %d too wide", w, count, s)) end
                end
            end
        end
    end)
    it("a missing or zero count counts as one icon", function()
        assertEquals(RL.DebuffIconSize(64, nil, 10), RL.DebuffIconSize(64, 1, 10))
        assertEquals(RL.DebuffIconSize(64, 0, 10), RL.DebuffIconSize(64, 1, 10))
    end)
end)
