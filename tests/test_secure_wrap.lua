-- ns.NewFrame must never override SetScript/HookScript of secure frames: Blizzard's SecureHandlerWrapScript installs
-- restricted closures through them, and a restricted closure called from inside our xpcall wrapper fails with
-- "Cannot call restricted closure from insecure code". The mock reproduces exactly that.
local L = require("loader")
local mock = require("wow_mock")
local Fx = require("fixtures")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.party1 = { name = "Tank", class = "WARRIOR", health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = "TANK" }
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    Fx.seed(ns, { presets = 2 })
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(2)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end
local function unitButtons(ns) return ns.UnitFrames.buttons end
local function frameNamed(name) for _, f in ipairs(mock.frames) do if st(f).name == name then return f end end end

describe("secure wrap: the mock reproduces the in-game failure", function()
    it("a restricted closure runs natively but errors inside an addon xpcall", function()
        mock.install()
        local f = CreateFrame("Button", nil, UIParent, "SecureHandlerBaseTemplate")
        SecureHandlerWrapScript(f, "OnHide", f, "x")
        local closure = st(f).scripts.OnHide
        assertTrue(mock.restricted[closure])
        mock.errors = {}
        mock.runFrameScript(f, "OnHide")
        assertEquals(#mock.errors, 0, "native call must work")
        local ok, err = xpcall(function() closure(f) end, function(e) return e end)
        assertFalse(ok); assertNotNil(tostring(err):find("restricted closure", 1, true))
    end)
end)

describe("secure wrap: ns.NewFrame leaves secure frames' SetScript/HookScript alone", function()
    local ns = boot()
    local templates = { "SecureUnitButtonTemplate", "SecureActionButtonTemplate", "SecureHandlerBaseTemplate", "SecureHandlerEnterLeaveTemplate",
        "SecureHandlerStateTemplate", "SecureUnitButtonTemplate,SecureHandlerEnterLeaveTemplate,SecureHandlerStateTemplate,BackdropTemplate",
        "SecureActionButtonTemplate,BackdropTemplate" }
    for _, tpl in ipairs(templates) do
        it("template '" .. tpl .. "' keeps the native methods", function()
            local f = ns.NewFrame("Button", nil, UIParent, tpl)
            assertNil(rawget(f, "SetScript"), "SetScript must not be overridden on a frame")
            assertNil(rawget(f, "HookScript"), "HookScript must not be overridden on a frame")
            assertFalse(f.hfWrapped == true)
            local fn = function() end
            f:SetScript("OnEnter", fn)
            assertTrue(st(f).scripts.OnEnter == fn, "the handler is stored as given (not wrapped)")
            f:HookScript("OnLeave", fn)
            assertTrue(st(f).hooks.OnLeave[1] == fn)
        end)
    end
    it("a protected frame without a Secure template name is detected through IsProtected", function()
        local f = CreateFrame("Button", nil, UIParent)
        st(f).secure = true
        f.IsProtected = function() return true end
        -- ns.NewFrame creates its own frame; emulate a client where the template name is hidden but IsProtected is true
        local realCreate = _G.CreateFrame
        _G.CreateFrame = function() return f end
        local g = ns.NewFrame("Button", nil, UIParent, "InsecureNamedTemplate")
        _G.CreateFrame = realCreate
        assertTrue(g == f)
        assertNil(rawget(f, "SetScript"), "IsProtected() frames must not be overridden")
    end)
    it("non-secure frames still get the protecting override", function()
        for _, kind in ipairs({ "Frame", "Button", "StatusBar", "Slider" }) do
            local f = ns.NewFrame(kind, nil, UIParent)
            assertNotNil(rawget(f, "SetScript"), kind); assertTrue(f.hfWrapped)
        end
        local f = ns.NewFrame("Frame", nil, UIParent, "BackdropTemplate")
        assertTrue(f.hfWrapped)
        local errs = #(ns.db.errorLog)
        f:SetScript("OnUpdate", function() error("insecure frame handler broke") end)
        assertTrue(pcall(st(f).scripts.OnUpdate, f, 0.1))
        assertEquals(#ns.db.errorLog, errs + 1)
        mock.errors = {}
    end)
    it("every real secure frame the addon created has no instance override", function()
        local checked = 0
        for _, f in ipairs(mock.frames) do
            if st(f).secure and st(f).name and tostring(st(f).name):match("^HealerForever") then
                assertNil(rawget(f, "SetScript"), st(f).name); assertNil(rawget(f, "HookScript"), st(f).name)
                checked = checked + 1
            end
        end
        assertTrue(checked >= 22, "checked " .. checked)
    end)
end)

describe("secure wrap: SecureHandlerWrapScript closures are never routed through ns.Wrap", function()
    local ns = boot()
    it("each unit button's OnHide is the restricted closure itself, installed exactly once", function()
        for _, b in ipairs(unitButtons(ns)) do
            local fn = st(b).scripts.OnHide
            assertNotNil(fn, tostring(st(b).name) .. " has no OnHide wrap")
            assertTrue(mock.restricted[fn], tostring(st(b).name) .. ": OnHide must be the unwrapped restricted closure")
        end
        local per = {}
        for _, c in ipairs(mock.callsTo("SecureHandlerWrapScript")) do per[c.args[1]] = (per[c.args[1]] or 0) + 1 end
        for b, n in pairs(per) do assertEquals(n, 1) end
    end)
    it("running OnHide (as the engine does) raises no error and logs nothing", function()
        for _, b in ipairs(unitButtons(ns)) do mock.runFrameScript(b, "OnHide") end
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(#ns.db.errorLog, 0)
    end)
    it("a wrapped closure WOULD fail: the failure mode is real (regression guard for the mock)", function()
        local b = unitButtons(ns)[2]
        local closure = st(b).scripts.OnHide
        local wrapped = ns.Wrap("OnHide", closure)
        mock.errors = {}
        local n0 = #ns.db.errorLog
        wrapped(b)
        assertEquals(#ns.db.errorLog, n0 + 1, "calling the restricted closure inside ns.Wrap must fail (and be logged)")
        for i = #ns.db.errorLog, 1, -1 do ns.db.errorLog[i] = nil end
        mock.errors = {}
    end)
    it("re-applying click-casting (bindings change, roster change) never wraps the closure either", function()
        ns:Changed("bindings"); mock.flushTimers(); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        for _, b in ipairs(unitButtons(ns)) do
            mock.runFrameScript(b, "OnHide")
            assertTrue(mock.restricted[st(b).scripts.OnHide])
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("hiding and showing buttons through combat transitions keeps OnHide quiet", function()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        for _, b in ipairs(unitButtons(ns)) do mock.runFrameScript(b, "OnHide") end
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("secure wrap: our own handlers on secure frames are still wrapped explicitly", function()
    local ns = boot()
    local function err(msg) return function() error(msg) end end
    it("ns.SecureHook / ns.SecureSetScript wrap the handler and leave the frame's methods alone", function()
        local f = ns.NewFrame("Button", nil, UIParent, "SecureActionButtonTemplate")
        local n0 = #ns.db.errorLog
        ns.SecureHook(f, "OnEnter", err("hook failed"))
        ns.SecureSetScript(f, "OnLeave", err("script failed"))
        assertTrue(pcall(st(f).hooks.OnEnter[1], f)); assertTrue(pcall(st(f).scripts.OnLeave, f))
        assertEquals(#ns.db.errorLog, n0 + 2)
        assertNil(rawget(f, "SetScript"))
        local seen
        ns.SecureHook(f, "OnShow", function(self, a) seen = a end)
        st(f).hooks.OnShow[1](f, 42)
        assertEquals(seen, 42)
        mock.errors = {}
    end)
    it("unit button OnShow / OnEnter / OnLeave hooks: errors are contained and logged", function()
        local b = ns.UnitFrames.byUnit.party1
        local n0 = #ns.db.errorLog
        local realUpdate, realTip = ns.UnitFrames.UpdateAll, ns.UnitFrames.ShowTooltip
        ns.UnitFrames.UpdateAll = err("UpdateAll broke"); ns.UnitFrames.ShowTooltip = err("ShowTooltip broke")
        assertTrue(pcall(function() mock.runFrameScript(b, "OnShow") end))
        assertTrue(pcall(st(b).hooks.OnEnter[1], b))
        ns.UnitFrames.UpdateAll, ns.UnitFrames.ShowTooltip = realUpdate, realTip
        local gt = _G.GameTooltip
        gt.Hide = function() error("Hide broke") end
        assertTrue(pcall(st(b).hooks.OnLeave[1], b))
        assertTrue(#ns.db.errorLog >= n0 + 3, "all three failures logged: " .. (#ns.db.errorLog - n0))
        mock.errors = {}
    end)
    it("buff, role-buff, smart and tank buttons: tooltip/drag handlers are wrapped", function()
        local names = {}
        for _, f in ipairs(mock.frames) do
            local n = st(f).name
            if n and (n:match("^HealerForeverBuff%d") or n:match("^HealerForeverExtra%d") or n == "HealerForeverSmartBuff" or n == "HealerForeverTankBuff") then names[#names + 1] = f end
        end
        assertTrue(#names >= 10)
        _G.GameTooltip.SetOwner = function() error("tooltip refused") end
        local n0 = #ns.db.errorLog
        for _, f in ipairs(names) do
            for _, script in ipairs({ "OnEnter", "OnLeave", "OnDragStart", "OnDragStop" }) do
                local hs = st(f).hooks[script]
                if hs then for _, h in ipairs(hs) do assertTrue(pcall(h, f), st(f).name .. " " .. script) end end
                if st(f).scripts[script] then assertTrue(pcall(st(f).scripts[script], f), st(f).name .. " " .. script) end
            end
        end
        assertTrue(#ns.db.errorLog > n0, "at least one failure was logged, none escaped")
        mock.errors = {}
    end)
    it("no handler installed through our secure helpers is the raw function (all are ns.Wrap closures)", function()
        local src = L.readFile(L.path("Core.lua"))
        assertNotNil(src:find("function ns.SecureHook", 1, true)); assertNotNil(src:find("function ns.SecureSetScript", 1, true))
    end)
    it("source scan: secure frames' HookScript/SetScript calls go through ns.SecureHook / ns.SecureSetScript (or ns.Wrap)", function()
        local bad = {}
        for _, rel in ipairs(toc.files) do
            if rel:lower():match("%.lua$") then
                local n = 0
                for line in L.readFile(L.path(rel)):gmatch("[^\n]*") do
                    n = n + 1
                    local code = line:gsub("%-%-.*$", "")
                    -- raw button:HookScript / button:SetScript on the unit buttons or buff/smart/tank buttons
                    if code:match("[%s%(]button:HookScript%(") or code:match("[%s%(]button:SetScript%(") or code:match("[%s%(]smart:HookScript%(")
                        or code:match("[%s%(]smart:SetScript%(") or code:match("[%s%(]tank:HookScript%(") or code:match("[%s%(]tank:SetScript%(")
                        or code:match("[%s%(]b:HookScript%(") then
                        if not code:find("ns.Wrap", 1, true) then bad[#bad + 1] = rel .. ":" .. n .. ": " .. line:gsub("^%s+", "") end
                    end
                end
            end
        end
        assertEquals(#bad, 0, "unwrapped handlers on secure frames:\n" .. table.concat(bad, "\n"))
    end)
end)
