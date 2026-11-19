-- Name colour on the unit frames (UF:UpdateName) and the mock's colour-setter argument checks.
-- Real client error (frames.colorMode ~= "class"): "bad argument #4 to 'SetTextColor' (Usage: self:SetTextColor(color [, a]))".
-- classColorFor returns r, g, b AND the class token; passing all four made the token the alpha argument.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role) return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" } end

local MODES = { "custom", "gradient" } -- every colorMode other than "class" (Options/Panes.lua COLORS)

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER"); S.units.party3 = unit("Mage", "MAGE", "DAMAGER")
    if opts.setup then opts.setup(S) end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    if opts.colorMode then ns.db.frames.colorMode = opts.colorMode end
    mock.setGroup(opts.group or 4)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.3); mock.flushTimers()
    return ns
end
local function near(a, b) return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 1e-6 end
local function assertColor(col, c, msg)
    assertNotNil(col, msg .. ": no text colour")
    assertTrue(near(col.r, c.r) and near(col.g, c.g) and near(col.b, c.b), msg .. string.format(": got %s,%s,%s", tostring(col.r), tostring(col.g), tostring(col.b)))
    assertNil(col.a, msg .. ": no alpha argument (the class token must never reach SetTextColor)")
end

describe("mock: colour setters check their arguments like the client", function()
    mock.install()
    local f = CreateFrame("Frame")
    local fs = f:CreateFontString(nil, "ARTWORK")
    local tex = f:CreateTexture(nil, "ARTWORK")
    local bar = CreateFrame("StatusBar")
    local bd = CreateFrame("Frame", nil, nil, "BackdropTemplate")
    local setters = {
        { fs, "SetTextColor" }, { tex, "SetVertexColor" }, { tex, "SetColorTexture" }, { bar, "SetStatusBarColor" },
        { bd, "SetBackdropColor" }, { bd, "SetBackdropBorderColor" },
    }
    for _, s in ipairs(setters) do
        local obj, m = s[1], s[2]
        it(m .. ": (r, g, b) and (r, g, b, a) numbers pass; a colour object and secret numbers pass", function()
            obj[m](obj, 1, 0.5, 0); obj[m](obj, 1, 0.5, 0, 0.3); obj[m](obj, 0, 0, 0, nil)
            obj[m](obj, { r = 1, g = 0, b = 0 }); obj[m](obj, { r = 1, g = 0, b = 0 }, 0.5)
            obj[m](obj, mock.newSecret(), mock.newSecret(), mock.newSecret(), mock.newSecret())
        end)
        it(m .. ": a string 4th argument raises 'bad argument #4' with the client's usage text", function()
            local ok, err = pcall(obj[m], obj, 0.78, 0.61, 0.43, "WARRIOR")
            assertFalse(ok, "accepted a class token as alpha")
            assertTrue(tostring(err):find("bad argument #4 to '" .. m .. "'", 1, true) ~= nil, tostring(err))
            assertTrue(tostring(err):find("Usage: self:" .. m .. "(color [, a])", 1, true) ~= nil, tostring(err))
        end)
        it(m .. ": a missing or non-number r, g or b raises", function()
            for i, args in ipairs({ { nil, 1, 1 }, { 1, "x", 1 }, { 1, 1 }, { true, 1, 1 } }) do
                local ok = pcall(obj[m], obj, args[1], args[2], args[3])
                assertFalse(ok, m .. " case " .. i)
            end
            assertFalse(pcall(obj[m], obj, { r = 1, g = "x", b = 0 }), "bad colour object")
        end)
    end
end)

describe("unit frames: the name colour for every colour mode", function()
    for _, mode in ipairs(MODES) do
        it(mode .. ": boot, roster and UpdateName never raise and every member's name is in its class colour", function()
            local ns = boot({ colorMode = mode })
            assertEquals(ns.db.frames.colorMode, mode)
            local UF = ns.UnitFrames
            for _, u in ipairs({ "party1", "party2", "party3" }) do
                local b = UF.byUnit[u]
                local ok, err = pcall(UF.UpdateName, UF, b)
                assertTrue(ok, mode .. " " .. u .. ": " .. tostring(err))
                assertEquals(st(b.name).text, S.units[u].name)
                assertColor(st(b.name).textColor, ns.Classes.GetColor(S.units[u].class), mode .. " " .. u)
            end
            assertEquals(#mock.errors, 0, errstr())
        end)
        it(mode .. ": a name event and a live switch from 'class' keep the colour correct, with no errors", function()
            local ns = boot()
            ns.db.frames.colorMode = mode; ns:Changed("frames"); mock.flushTimers()
            mock.fire("UNIT_NAME_UPDATE", "party1"); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(1, 0.3); mock.flushTimers()
            local b = ns.UnitFrames.byUnit.party1
            ns.UnitFrames:UpdateName(b)
            assertColor(st(b.name).textColor, ns.Classes.GetColor("WARRIOR"), mode)
            assertEquals(#mock.errors, 0, errstr())
        end)
        it(mode .. ": a secret class token falls back to white (no error), in combat too", function()
            local ns = boot({ colorMode = mode })
            S.secretAll = true; S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
            local b = ns.UnitFrames.byUnit.party2
            local ok, err = pcall(ns.UnitFrames.UpdateName, ns.UnitFrames, b)
            assertTrue(ok, tostring(err))
            local col = st(b.name).textColor
            assertNotNil(col); assertNil(col.a)
            S.secretAll = false; S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
            assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
        end)
    end
    it("class mode: the name stays white (the bar carries the class colour)", function()
        local ns = boot({ colorMode = "class" })
        local b = ns.UnitFrames.byUnit.party1
        ns.UnitFrames:UpdateName(b)
        local col = st(b.name).textColor
        assertTrue(near(col.r, 1) and near(col.g, 1) and near(col.b, 1)); assertNil(col.a)
    end)
end)
