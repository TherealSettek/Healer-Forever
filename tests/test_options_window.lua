-- Options window: the X (close) button, ESC (UISpecialFrames) and reopening with /hf.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end

local function boot()
    mock.install(); S = mock.state
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    return ns
end
local function slash(msg) assert(pcall(_G.SlashCmdList.HEALERFOREVER, msg or "")); mock.flushTimers() end
local function frameOf(ns) ns.Options:Create(); return ns.Options.frame end

describe("options window: the mock's BasicFrameTemplateWithInset has a close button", function()
    local ns = boot()
    it("f.CloseButton and the global HealerForeverOptionsCloseButton exist and are the same frame", function()
        local f = frameOf(ns)
        assertNotNil(f.CloseButton); assertTrue(_G.HealerForeverOptionsCloseButton == f.CloseButton)
        assertEquals(st(f.CloseButton).kind, "Button"); assertTrue(st(f.CloseButton).parent == f)
    end)
    it("the default template click mimics the real one: onCloseCallback, else HideUIPanel", function()
        local f = mock.newFrame("Frame", "HFTemplateProbe", _G.UIParent, "BasicFrameTemplateWithInset")
        local cb = f.CloseButton
        local hidden
        local real = _G.HideUIPanel
        _G.HideUIPanel = function(fr) hidden = fr end
        st(cb).scripts.OnClick(cb, "LeftButton")
        assertTrue(hidden == f, "falls back to HideUIPanel(frame)")
        local called
        f.onCloseCallback = function(fr) called = fr end
        hidden = nil
        st(cb).scripts.OnClick(cb, "LeftButton")
        assertTrue(called == f); assertNil(hidden)
        _G.HideUIPanel = real
    end)
    it("a plain frame has no CloseButton", function()
        local f = mock.newFrame("Frame", "HFPlain", _G.UIParent)
        assertNil(f.CloseButton)
    end)
    it("the mock no longer lacks HealerForeverOptionsCloseButton (not reported as an undefined global)", function()
        frameOf(ns)
        local u = mock.undefinedList()
        for _, k in ipairs(u) do assertTrue(k ~= "HealerForeverOptionsCloseButton", k) end
    end)
end)

describe("options window: closing", function()
    local ns = boot()
    it("opens with /hf", function()
        slash("")
        assertTrue(st(frameOf(ns)).shown)
    end)
    it("clicking the X hides the window", function()
        local f = frameOf(ns)
        assertTrue(st(f).shown)
        local cb = f.CloseButton
        st(cb).scripts.OnClick(cb, "LeftButton")
        assertFalse(st(f).shown)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the default template path (onCloseCallback) also hides it", function()
        slash("")
        local f = frameOf(ns); assertTrue(st(f).shown)
        f.onCloseCallback(f)
        assertFalse(st(f).shown)
    end)
    it("the X works with the mock's original HideUIPanel no-op (a non-UI-panel window must not rely on it)", function()
        slash("")
        local f = frameOf(ns)
        local real = _G.HideUIPanel
        local calls = 0
        _G.HideUIPanel = function() calls = calls + 1 end
        st(f.CloseButton).scripts.OnClick(f.CloseButton, "LeftButton")
        _G.HideUIPanel = real
        assertFalse(st(f).shown)
    end)
    it("reopening with /hf works after closing, repeatedly, on the same frame", function()
        local f = frameOf(ns)
        for i = 1, 4 do
            if not st(f).shown then slash("") end
            assertTrue(st(f).shown, "open #" .. i)
            st(f.CloseButton).scripts.OnClick(f.CloseButton, "LeftButton")
            assertFalse(st(f).shown, "closed #" .. i)
        end
        slash("")
        assertTrue(st(f).shown); assertTrue(frameOf(ns) == f, "no second window")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("closing keeps the selected pane's content intact (reopen shows panes, no error)", function()
        ns.Options:Show("auras"); mock.flushTimers()
        local f = frameOf(ns)
        st(f.CloseButton).scripts.OnClick(f.CloseButton, "LeftButton")
        slash("")
        assertTrue(st(f).shown)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("works in combat (the window is not secure and nothing protected is touched)", function()
        local f = frameOf(ns)
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0, s0 = #mock.violations, #mock.softViolations
        if not st(f).shown then slash("") end
        st(f.CloseButton).scripts.OnClick(f.CloseButton, "LeftButton")
        assertFalse(st(f).shown)
        slash("")
        assertTrue(st(f).shown)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0); assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("options window: ESC and frame order", function()
    local ns = boot()
    it("the window is registered in UISpecialFrames exactly once (ESC closes it)", function()
        local f = frameOf(ns)
        local n = 0
        for _, name in ipairs(_G.UISpecialFrames) do if name == "HealerForeverOptions" then n = n + 1 end end
        assertEquals(n, 1)
        assertTrue(_G.HealerForeverOptions == f, "the global the ESC handler looks up")
        ns.Options:Show("general"); ns.Options:Show("auras")
        n = 0
        for _, name in ipairs(_G.UISpecialFrames) do if name == "HealerForeverOptions" then n = n + 1 end end
        assertEquals(n, 1, "still once after showing panes")
    end)
    it("ESC behaves like the game: every UISpecialFrames entry that is shown is hidden", function()
        ns.Options:Show("general")
        local f = frameOf(ns); assertTrue(st(f).shown)
        for _, name in ipairs(_G.UISpecialFrames) do
            local fr = _G[name]
            if fr and st(fr).shown then fr:Hide() end
        end
        assertFalse(st(f).shown)
        ns.Options:Show("general")
        assertTrue(st(f).shown)
    end)
    it("the X is above every other child frame of the window (its level is the highest)", function()
        local f = frameOf(ns)
        local cb = f.CloseButton
        local cbLevel = cb:GetFrameLevel()
        local others = 0
        for _, fr in ipairs(mock.frames) do
            if fr ~= cb and st(fr).parent == f then
                others = others + 1
                assertTrue(cbLevel > fr:GetFrameLevel(), "X level " .. cbLevel .. " must be above " .. tostring(st(fr).name or st(fr).kind) .. " level " .. fr:GetFrameLevel())
            end
        end
        assertTrue(others >= 2, "nav and content exist as children")
        assertTrue(cbLevel > f:GetFrameLevel())
    end)
    it("the X stays above the window's content after panes are built (deep children included)", function()
        ns.Options:Show("auras"); ns.Options:Show("binds"); mock.flushTimers()
        local f = frameOf(ns)
        local cbLevel = f.CloseButton:GetFrameLevel()
        local function depthParent(fr) local p = st(fr).parent; while p and p ~= f do p = st(p).parent end return p == f end
        local checked = 0
        for _, fr in ipairs(mock.frames) do
            local k = st(fr).kind
            if fr ~= f.CloseButton and k ~= "FontString" and k ~= "Texture" and st(fr).parent and depthParent(fr) then
                checked = checked + 1
                assertTrue(fr:GetFrameLevel() < cbLevel, "descendant " .. tostring(st(fr).name or k) .. " level " .. fr:GetFrameLevel() .. " is not below the X (" .. cbLevel .. ")")
            end
        end
        assertTrue(checked > 0)
    end)
    it("the X is still above after the window is re-created lazily (second Create is a no-op)", function()
        local f = frameOf(ns)
        local lvl = f.CloseButton:GetFrameLevel()
        ns.Options:Create()
        assertTrue(frameOf(ns) == f); assertEquals(f.CloseButton:GetFrameLevel(), lvl)
    end)
    it("the click works with the window's strata and level changes (SetFrameLevel on the X is honoured)", function()
        local f = frameOf(ns)
        assertTrue(st(f.CloseButton).level ~= nil, "the addon raised the X explicitly")
        assertEquals(st(f.CloseButton).level, f:GetFrameLevel() + 20)
    end)
end)
