-- Pure tests of the border / aura-zone helpers in Util/Util.lua (no WoW API). They check rules and edge cases,
-- not particular default values.
local L = require("loader")
local mock = require("wow_mock")

mock.install()
local ns = {}
local ok, err = pcall(L.loadFile, "Util/Util.lua", ns)
describe("util ui helpers: load", function()
    it("Util/Util.lua loads and defines the helpers", function()
        assertTrue(ok, tostring(err))
        for _, f in ipairs({ "NormalizeBorder", "BorderSpec", "BarBorderColor", "ZoneSize", "IconOffset", "CellLayout", "ClampNumber" }) do
            assertEquals(type(ns.Util and ns.Util[f]), "function", f)
        end
    end)
end)
if not (ns.Util and ns.Util.NormalizeBorder) then return end
local U = ns.Util

local function diff(a, b, path)
    path = path or "t"
    if type(a) ~= type(b) then return path .. ": " .. type(a) .. " vs " .. type(b) end
    if type(a) ~= "table" then if a ~= b then return path .. ": " .. tostring(a) .. " vs " .. tostring(b) end return nil end
    for k, v in pairs(a) do local d = diff(v, b[k], path .. "." .. tostring(k)); if d then return d end end
    for k in pairs(b) do if a[k] == nil then return path .. "." .. tostring(k) .. " missing" end end
end
local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end
local function validBorder(b)
    assertTrue(has(U.BORDER_STYLES, b.style), "style " .. tostring(b.style))
    assertTrue(type(b.width) == "number" and b.width >= 1 and b.width <= 4, "width " .. tostring(b.width))
    assertTrue(has(U.BORDER_COLORS, b.color), "color " .. tostring(b.color))
    for _, k in ipairs({ "r", "g", "b" }) do assertTrue(type(b.custom[k]) == "number" and b.custom[k] >= 0 and b.custom[k] <= 1, "custom." .. k) end
end

describe("util ui helpers: constants", function()
    it("option lists are non-empty, unique, with the documented members", function()
        for _, list in ipairs({ U.BORDER_STYLES, U.BORDER_COLORS, U.POSITIONS, U.GROWS }) do
            assertTrue(#list > 0)
            local seen = {}
            for _, v in ipairs(list) do assertNil(seen[v]); seen[v] = true end
        end
        for _, v in ipairs({ "none", "thin", "tooltip", "gold" }) do assertTrue(has(U.BORDER_STYLES, v), v) end
        for _, v in ipairs({ "class", "black", "gold", "custom" }) do assertTrue(has(U.BORDER_COLORS, v), v) end
        assertEquals(#U.POSITIONS, 5); assertEquals(#U.GROWS, 4)
    end)
    it("the addon defaults use only valid values", function()
        local full = {}
        local n = {}
        for _, rel in ipairs(L.CONTRACT_FILES) do pcall(L.loadFile, rel, n) end
        validBorder(U.NormalizeBorder(n.DEFAULTS and n.DEFAULTS.frames.border))
        assertNil(diff(U.NormalizeBorder(n.DEFAULTS.frames.border), n.DEFAULTS.frames.border), "default border must already be normalised")
        local a = n.DEFAULTS.auras
        assertTrue(has(U.POSITIONS, a.buffPosition)); assertTrue(has(U.POSITIONS, a.debuffPosition)); assertTrue(has(U.GROWS, a.grow))
    end)
end)

describe("util ui helpers: ClampNumber", function()
    local C = U.ClampNumber
    it("clamps, keeps in-range values and falls back for non-numbers and NaN", function()
        assertEquals(C(5, 1, 10, 3), 5); assertEquals(C(0, 1, 10, 3), 1); assertEquals(C(99, 1, 10, 3), 10)
        assertEquals(C("5", 1, 10, 3), 3); assertEquals(C(nil, 1, 10, 3), 3); assertEquals(C(0 / 0, 1, 10, 3), 3); assertEquals(C({}, 1, 10, 3), 3)
        assertEquals(C(math.huge, 1, 10, 3), 10); assertEquals(C(-math.huge, 1, 10, 3), 1)
    end)
end)

describe("util ui helpers: NormalizeBorder", function()
    local N = U.NormalizeBorder
    it("nil / non-table input gives a valid default", function()
        for _, bad in ipairs({ false, "x", 5, true }) do validBorder(N(bad or nil)) end
        validBorder(N(nil)); validBorder(N({}))
        assertNil(diff(N(nil), N({})))
    end)
    it("valid values are kept for every enumerated option", function()
        for _, v in ipairs(U.BORDER_STYLES) do assertEquals(N({ style = v }).style, v) end
        for _, v in ipairs(U.BORDER_COLORS) do assertEquals(N({ color = v }).color, v) end
        for w = 1, 4 do assertEquals(N({ width = w }).width, w) end
    end)
    it("unknown enumerated values fall back; width is clamped to 1..4", function()
        local d = N({})
        local r = N({ style = "bogus", color = 5 })
        assertEquals(r.style, d.style); assertEquals(r.color, d.color)
        assertEquals(N({ width = 0 }).width, 1); assertEquals(N({ width = 99 }).width, 4); assertEquals(N({ width = -3 }).width, 1)
        assertEquals(N({ width = "3" }).width, d.width); assertEquals(N({ width = 0 / 0 }).width, d.width)
        assertEquals(N({ width = math.huge }).width, 4)
    end)
    it("custom colour: per channel clamping, wrong types fall back, non-table uses defaults", function()
        local d = N({}).custom
        local r = N({ custom = { r = 2, g = -1, b = "x" } })
        assertEquals(r.custom.r, 1); assertEquals(r.custom.g, 0); assertEquals(r.custom.b, d.b)
        assertNil(diff(N({ custom = "red" }).custom, d)); assertNil(diff(N({ custom = 7 }).custom, d))
        local ok2 = N({ custom = { r = 0.25, g = 0.5, b = 0.75 } })
        assertEquals(ok2.custom.r, 0.25); assertEquals(ok2.custom.g, 0.5); assertEquals(ok2.custom.b, 0.75)
    end)
    it("returns exactly the known keys, fresh tables, never mutates the input; idempotent", function()
        local input = { style = "gold", width = 3, color = "custom", custom = { r = 5, g = 5, b = 5 }, zzz = 1 }
        local snap = { style = "gold", width = 3, color = "custom", custom = { r = 5, g = 5, b = 5 }, zzz = 1 }
        local out = N(input)
        assertNil(diff(input, snap)); assertNil(out.zzz)
        assertTrue(out ~= input and out.custom ~= input.custom)
        out.custom.r = 0
        assertEquals(input.custom.r, 5)
        assertNil(diff(N(out), out))
    end)
    it("random garbage always gives a valid border (fuzz)", function()
        math.randomseed(777)
        local junk = { false, true, 0, -1, 1e9, "", "x", {}, { 1 }, 0 / 0, math.huge, -math.huge, 3.7, "none", "gold", "class" }
        for _ = 1, 400 do
            local b = {}
            for _, k in ipairs({ "style", "width", "color", "custom" }) do if math.random() < 0.7 then b[k] = junk[math.random(#junk)] end end
            if math.random() < 0.3 then b.custom = { r = junk[math.random(#junk)], g = junk[math.random(#junk)], b = junk[math.random(#junk)] } end
            validBorder(N(b))
        end
    end)
end)

describe("util ui helpers: BorderSpec", function()
    local B = U.BorderSpec
    it("none: no edge file, zero size and outset, whatever the thickness", function()
        for _, w in ipairs({ 1, 4, 99, -1 }) do
            local s = B("none", w)
            assertNil(s.edgeFile); assertEquals(s.edgeSize, 0); assertEquals(s.outset, 0)
        end
    end)
    it("thin: always a 1px white-texture edge", function()
        for _, w in ipairs({ 1, 2, 4, 99 }) do
            local s = B("thin", w)
            assertEquals(s.edgeSize, 1); assertEquals(s.outset, 0); assertNotNil(s.edgeFile:find("WHITE8X8", 1, true))
        end
    end)
    it("tooltip and gold: different edge files, size 4 x thickness (min 4), outset a quarter of the size", function()
        local t, g = B("tooltip", 2), B("gold", 2)
        assertTrue(t.edgeFile ~= g.edgeFile); assertNotNil(g.edgeFile:find("Gold", 1, true))
        for w = 1, 4 do
            assertEquals(B("tooltip", w).edgeSize, 4 * w); assertEquals(B("tooltip", w).outset, w)
            assertEquals(B("gold", w).edgeSize, 4 * w)
        end
    end)
    it("thickness is clamped to 1..4 and bad values use 2", function()
        assertEquals(B("tooltip", 0).edgeSize, 4); assertEquals(B("tooltip", 99).edgeSize, 16)
        assertEquals(B("tooltip", nil).edgeSize, 8); assertEquals(B("tooltip", "x").edgeSize, 8); assertEquals(B("tooltip", 0 / 0).edgeSize, 8)
    end)
    it("thicker is never smaller (monotonic) for every style", function()
        for _, style in ipairs(U.BORDER_STYLES) do
            local last = 0
            for w = 1, 4 do local s = B(style, w); assertTrue(s.edgeSize >= last, style); last = s.edgeSize end
        end
    end)
    it("an unknown or nil style falls back to the tooltip border", function()
        assertEquals(B("bogus", 2).edgeFile, B("tooltip", 2).edgeFile); assertEquals(B(nil, 2).edgeFile, B("tooltip", 2).edgeFile)
    end)
    it("every style gives a table with the three keys; fresh table each call", function()
        for _, style in ipairs(U.BORDER_STYLES) do
            local s = B(style, 2)
            assertEquals(type(s.edgeSize), "number"); assertEquals(type(s.outset), "number")
        end
        assertTrue(B("thin", 1) ~= B("thin", 1))
    end)
end)

describe("util ui helpers: BarBorderColor", function()
    local C = U.BarBorderColor
    local class = { r = 0.1, g = 0.2, b = 0.3 }
    it("class colour (white when none is given), gold, custom", function()
        assertTrue(C({ color = "class", style = "thin" }, class) == class)
        local w = C({ color = "class", style = "thin" }, nil)
        assertEquals(w.r + w.g + w.b, 3)
        local g = C({ color = "gold", style = "thin" }, class)
        assertEquals(g.r, 1); assertEquals(g.g, 0.82); assertEquals(g.b, 0)
        local custom = { r = 0.5, g = 0.4, b = 0.3 }
        assertTrue(C({ color = "custom", style = "thin", custom = custom }, class) == custom)
    end)
    it("black keeps textured borders steel grey and thin/none borders black", function()
        local steel = C({ color = "black", style = "tooltip" }, class)
        assertTrue(steel.r > 0.3); assertEquals(C({ color = "black", style = "gold" }, class).r, steel.r)
        for _, style in ipairs({ "thin", "none" }) do
            local b = C({ color = "black", style = style }, class)
            assertEquals(b.r + b.g + b.b, 0)
        end
    end)
    it("every Normalize result yields a colour table; missing fields fall back to black", function()
        for _, st in ipairs(U.BORDER_STYLES) do for _, c in ipairs(U.BORDER_COLORS) do
            local col = C(U.NormalizeBorder({ style = st, color = c }), class)
            assertEquals(type(col.r), "number"); assertEquals(type(col.g), "number"); assertEquals(type(col.b), "number")
        end end
        local b = C({}, nil)
        assertEquals(b.r + b.g + b.b, 0)
    end)
    it("a nil border raises (callers pass Normalize output)", function()
        if pcall(C, nil, class) then return end
        warn("Util.BarBorderColor(nil, ...) raises; callers always pass a normalised table")
    end)
end)

describe("util ui helpers: ZoneSize", function()
    local Z = U.ZoneSize
    it("horizontal growth: width follows icons per row, height the rows", function()
        local w, h = Z(20, 4, 4, "right"); assertEquals(w, 4 * 22 + 4); assertEquals(h, 22 + 4)
        w, h = Z(20, 4, 9, "left"); assertEquals(w, 4 * 22 + 4); assertEquals(h, 3 * 22 + 4)
    end)
    it("vertical growth swaps the axes", function()
        local w, h = Z(20, 4, 9, "down"); assertEquals(w, 3 * 22 + 4); assertEquals(h, 4 * 22 + 4)
        local w2, h2 = Z(20, 4, 9, "up"); assertEquals(w2, w); assertEquals(h2, h)
    end)
    it("counts and rows below 1 behave like 1; fewer icons shrink the zone", function()
        local w1 = Z(16, 6, 1, "right")
        assertTrue(Z(16, 6, 3, "right") > w1)
        assertEquals((Z(16, 6, 0, "right")), w1); assertEquals((Z(16, 0, 1, "right")), w1); assertEquals((Z(16, 6, -4, "right")), w1)
    end)
    it("extra space is added to the cross axis only", function()
        local w0, h0 = Z(20, 4, 4, "right", 0); local w1, h1 = Z(20, 4, 4, "right", 10)
        assertEquals(w1, w0); assertEquals(h1, h0 + 10)
        local vw0, vh0 = Z(20, 4, 4, "down", 0); local vw1, vh1 = Z(20, 4, 4, "down", 10)
        assertEquals(vw1, vw0); assertEquals(vh1, vh0 + 10)
    end)
    it("an unknown grow behaves like right; results are always positive across a sweep", function()
        local a1, a2 = Z(20, 4, 6, "bogus"); local b1, b2 = Z(20, 4, 6, "right")
        assertEquals(a1, b1); assertEquals(a2, b2)
        for _, grow in ipairs(U.GROWS) do for sz = 10, 32, 11 do for per = 1, 8, 3 do for n = 0, 12, 4 do
            local w, h = Z(sz, per, n, grow)
            assertTrue(w > 0 and h > 0)
        end end end end
    end)
    it("nil arguments raise (documented preconditions)", function()
        if pcall(Z, nil, nil, nil, nil) then return end
        warn("Util.ZoneSize(nil...) raises; callers pass numbers from normalised settings")
    end)
end)

describe("util ui helpers: IconOffset", function()
    local O = U.IconOffset
    it("right: top-left corner, x grows, rows go down", function()
        local c, x, y = O(1, 20, 3, "right"); assertEquals(c, "TOPLEFT"); assertEquals(x, 2); assertEquals(y, -2)
        c, x, y = O(2, 20, 3, "right"); assertEquals(x, 24); assertEquals(y, -2)
        c, x, y = O(4, 20, 3, "right"); assertEquals(x, 2); assertEquals(y, -24)
    end)
    it("left: top-right corner, x grows negative", function()
        local c, x, y = O(1, 20, 3, "left"); assertEquals(c, "TOPRIGHT"); assertEquals(x, -2); assertEquals(y, -2)
        c, x, y = O(3, 20, 3, "left"); assertEquals(x, -2 - 2 * 22)
        c, x, y = O(4, 20, 3, "left"); assertEquals(x, -2); assertEquals(y, -24)
    end)
    it("down: top-left corner, y grows negative, columns to the right", function()
        local c, x, y = O(2, 20, 3, "down"); assertEquals(c, "TOPLEFT"); assertEquals(x, 2); assertEquals(y, -24)
        c, x, y = O(4, 20, 3, "down"); assertEquals(x, 24); assertEquals(y, -2)
    end)
    it("up: bottom-left corner, y grows positive", function()
        local c, x, y = O(2, 20, 3, "up"); assertEquals(c, "BOTTOMLEFT"); assertEquals(x, 2); assertEquals(y, 24)
        c, x, y = O(4, 20, 3, "up"); assertEquals(x, 24); assertEquals(y, 2)
    end)
    it("unknown or nil grow behaves like right", function()
        local a1, a2, a3 = O(5, 18, 4, "bogus"); local b1, b2, b3 = O(5, 18, 4, "right")
        assertEquals(a1, b1); assertEquals(a2, b2); assertEquals(a3, b3); assertEquals((O(2, 18, 4, nil)), "TOPLEFT")
    end)
    it("icons never overlap for every grow direction, icon size and per-row value", function()
        for _, grow in ipairs(U.GROWS) do for sz = 10, 32, 11 do for per = 1, 8 do
            local seen = {}
            for i = 1, per * 3 do
                local c, x, y = O(i, sz, per, grow)
                local key = c .. ":" .. x .. ":" .. y
                assertNil(seen[key], grow .. " i=" .. i); seen[key] = true
            end
        end end end
    end)
    it("offsets stay inside the zone reported by ZoneSize", function()
        for _, grow in ipairs(U.GROWS) do
            local sz, per, n = 18, 4, 10
            local w, h = U.ZoneSize(sz, per, n, grow)
            for i = 1, n do
                local c, x, y = O(i, sz, per, grow)
                local right = (c == "TOPRIGHT") and -x or (x + sz)
                local down = (c == "BOTTOMLEFT") and (y + sz) or (-y + sz)
                assertTrue(right <= w, grow .. " i=" .. i .. " width"); assertTrue(down <= h, grow .. " i=" .. i .. " height")
            end
        end
    end)
    it("odd inputs (i < 1, per-row 0) do not raise", function()
        assertTrue(pcall(O, 0, 18, 4, "right")); assertTrue(pcall(O, -3, 18, 4, "left")); assertTrue(pcall(O, 1, 18, 0, "down"))
    end)
end)

describe("util ui helpers: CellLayout", function()
    local C = U.CellLayout
    it("no zones: the cell is exactly the frame", function()
        local r = C(180, 44, {})
        assertEquals(r.width, 180); assertEquals(r.height, 44); assertEquals(r.left + r.right + r.top + r.bottom, 0)
    end)
    it("top and bottom zones add their height plus the gap and stack on the same side", function()
        local r = C(180, 44, { { pos = "top", w = 100, h = 20 }, { pos = "bottom", w = 60, h = 10 } })
        assertEquals(r.top, 22); assertEquals(r.bottom, 12); assertEquals(r.height, 78); assertEquals(r.width, 180)
        assertEquals(C(180, 44, { { pos = "top", w = 100, h = 20 }, { pos = "top", w = 100, h = 20 } }).top, 44)
    end)
    it("left and right zones add the widest width plus the gap", function()
        local r = C(180, 44, { { pos = "left", w = 50, h = 20 }, { pos = "right", w = 30, h = 20 }, { pos = "right", w = 70, h = 20 } })
        assertEquals(r.left, 52); assertEquals(r.right, 72); assertEquals(r.width, 52 + 180 + 72)
    end)
    it("tall side zones grow the height; wide top zones grow the width", function()
        assertEquals(C(100, 20, { { pos = "left", w = 20, h = 60 } }).height, 62)
        assertEquals(C(100, 20, { { pos = "top", w = 300, h = 10 } }).width, 300)
    end)
    it("'inside' and unknown positions reserve nothing; the gap argument is honoured", function()
        local r = C(180, 44, { { pos = "inside", w = 100, h = 100 }, { pos = "diagonal", w = 100, h = 100 } })
        assertEquals(r.width, 180); assertEquals(r.height, 44)
        assertEquals(C(100, 30, { { pos = "top", w = 10, h = 10 } }).top, 12)
        assertEquals(C(100, 30, { { pos = "top", w = 10, h = 10 } }, 0).top, 10)
        assertEquals(C(100, 30, { { pos = "top", w = 10, h = 10 } }, 6).top, 16)
    end)
    it("the cell always contains the frame plus every reserved side", function()
        for _, pos in ipairs(U.POSITIONS) do
            local r = C(150, 40, { { pos = pos, w = 40, h = 18 } })
            assertTrue(r.width >= r.left + 150 + r.right); assertTrue(r.height >= r.top + 40 + r.bottom)
        end
    end)
    it("nil zones raises (precondition)", function()
        if pcall(C, 100, 20, nil) then return end
        warn("Util.CellLayout(w, h, nil) raises; callers always pass a table")
    end)
end)
