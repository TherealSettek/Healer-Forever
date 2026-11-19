-- Fake WoW (retail, Lua 5.1) environment for headless smoke tests.
local M = {}
local realXpcall = xpcall

M.state = {}
M.frames = {}       -- every frame created
M.calls = {}        -- tracked calls: {frame=, method=, args=, combat=}
M.errors = {}       -- errors caught inside event/script dispatch
M.undefined = {}    -- set of undefined global names accessed
M.violations = {}   -- SetAttribute etc. on secure frames during combat lockdown
M.softViolations = {}
M.blocked = {}     -- ADDON_ACTION_BLOCKED calls (mouse setters on aura buttons in combat)
M.printed = {}
M.timers = {}
M.tickers = {}
M.missingMethods = {}
M.createdInCombat = {}
M.xdepth = 0
M.restricted = setmetatable({}, { __mode = "k" })

local installed = {}   -- names of globals we set
local realG = {}       -- original values to restore
local origMeta

-- ------------------------------------------------------------------ secret
local function secretErr() error("attempt to perform arithmetic on a secret value", 2) end
local SECRET_MT = {
    __lt = secretErr, __le = secretErr, __add = secretErr, __sub = secretErr,
    __mul = secretErr, __div = secretErr, __mod = secretErr, __pow = secretErr,
    __unm = secretErr, __eq = function() error("attempt to compare a secret value", 2) end,
    __concat = function() error("attempt to concatenate a secret value", 2) end,
    __index = function() error("attempt to index a secret value", 2) end,
    __tostring = function() error("attempt to convert a secret value to a string", 2) end,
}
function M.newSecret() return setmetatable({}, SECRET_MT) end

-- Plain number curve (C_CurveUtil.CreateCurve): records type and points ({ {x, y} }); Evaluate(x) like the client for
-- Step (the point with the largest x <= input; below the first point -> the first point) and Linear (interpolated).
-- isFloat marks it so UnitHealthPercent(unit, p, curve) can tell it from a colour curve (secret mode: a secret number).
M.floatCurves = {}
function M.newFloatCurve(obj)
    local curve = obj or {}
    curve.points = curve.points or {}
    curve.isFloat = true
    curve.SetType = function(self, t) self.curveType = t; if self.config then self.config.SetType = { t } end end
    curve.AddPoint = function(self, x, y) self.points[#self.points + 1] = { x, y } end
    curve.Evaluate = function(self, x)
        local pts = self.points
        if #pts == 0 or type(x) ~= "number" then return 0 end
        if self.curveType == 2 then
            local best
            for _, p in ipairs(pts) do if p[1] <= x + 1e-9 and (not best or p[1] >= best[1]) then best = p end end
            return (best or pts[1])[2]
        end
        local sorted = {}
        for i, p in ipairs(pts) do sorted[i] = p end
        table.sort(sorted, function(a, b) return a[1] < b[1] end)
        if x <= sorted[1][1] then return sorted[1][2] end
        for i = 2, #sorted do
            local a, b = sorted[i - 1], sorted[i]
            if x <= b[1] then return a[2] + (b[2] - a[2]) * (x - a[1]) / (b[1] - a[1]) end
        end
        return sorted[#sorted][2]
    end
    M.floatCurves[#M.floatCurves + 1] = curve
    return curve
end
function M.isSecret(v) return (type(v) == "table" and getmetatable(v) == SECRET_MT) or (type(v) == "userdata" and M.secretTables[v] == true) end
M.secretTables = setmetatable({}, { __mode = "k" })
-- a "secret table": userdata whose length and indexing raise (a real table cannot raise on # under Lua 5.1)
function M.newSecretTable()
    local p = newproxy(true)
    local mt = getmetatable(p)
    mt.__len = function() error("attempt to get length of a secret table", 2) end
    mt.__index = function() error("attempt to index a secret table", 2) end
    mt.__newindex = function() error("attempt to modify a secret table", 2) end
    mt.__tostring = function() error("attempt to convert a secret table to a string", 2) end
    M.secretTables[p] = true
    return p
end

-- ------------------------------------------------------------------ frames
local METHOD_PREFIX = { "Set", "Get", "Is", "Has", "Create", "Register", "Unregister", "Enable", "Disable",
    "Show", "Hide", "Clear", "Add", "Hook", "Raise", "Lower", "Stop", "Play", "Can", "Start", "Update",
    "Apply", "Toggle", "Lock", "Unlock", "Insert", "Remove", "Select", "Fade", "Freeze", "Click",
    "Disable", "Highlight", "Rotate", "Pause", "Finish", "Reset", "Run", "Make", "Move", "Notify", "Send" }
local EXTRA_METHODS = { SetPoint = 1, ClearAllPoints = 1, Show = 1, Hide = 1, Click = 1, SetText = 1,
    GetName = 1, SetAllPoints = 1, SetFocus = 1, ClearFocus = 1, EnableMouse = 1, EnableKeyboard = 1,
    RegisterForClicks = 1, RegisterForDrag = 1, SetMovable = 1, StartMoving = 1, StopMovingOrSizing = 1,
    SetBackdrop = 1, SetBackdropColor = 1, SetBackdropBorderColor = 1, SetStatusBarColor = 1,
    SetMinMaxValues = 1, SetValue = 1, SetCooldown = 1, SetVertexColor = 1, SetTexCoord = 1, SetColorTexture = 1,
    SetCursor = 1, SetOwner = 1, AddLine = 1, AddDoubleLine = 1, AddMessage = 1, SetCheckedTexture = 1,
    SetChecked = 1, GetChecked = 1, HookScript = 1, Raise = 1, Play = 1, Stop = 1, SetLooping = 1,
    SetDuration = 1, SetFromAlpha = 1, SetToAlpha = 1, SetJustifyH = 1, SetJustifyV = 1, SetFont = 1,
    SetClampedToScreen = 1, SetFrameStrata = 1, SetFrameLevel = 1, SetToplevel = 1, SetSize = 1, SetScale = 1,
    SetAlpha = 1, SetWidth = 1, SetHeight = 1, SetParent = 1, SetShown = 1, SetID = 1, ClearAllPoints2 = 1,
    SetNormalFontObject = 1, SetHighlightFontObject = 1, SetMaxLetters = 1, SetAutoFocus = 1, SetNumeric = 1,
    HighlightText = 1, SetScrollChild = 1, UpdateScrollChildRect = 1, SetMinResize = 1, SetResizable = 1,
    SetTexture = 1, SetAtlas = 1, SetDrawLayer = 1, SetBlendMode = 1, SetDesaturated = 1, SetMask = 1,
    SetSwipeColor = 1, SetDrawEdge = 1, SetDrawSwipe = 1, SetReverse = 1, SetHideCountdownNumbers = 1,
    SetTextColor = 1, SetShadowColor = 1, SetShadowOffset = 1, SetWordWrap = 1, SetNonSpaceWrap = 1,
    SetMaxLines = 1, SetOrientation = 1, SetRotatesTexture = 1, SetFillStyle = 1, SetStatusBarTexture = 1,
    GetStatusBarTexture = 1 }
local isMethodName
do
    isMethodName = function(k)
        if type(k) ~= "string" then return false end
        if EXTRA_METHODS[k] then return true end
        for _, p in ipairs(METHOD_PREFIX) do
            if k == p or k:sub(1, #p) == p and k:sub(#p + 1, #p + 1):match("^%u") then return true end
        end
        return false
    end
end

local DEFAULT_NUM = { GetWidth = 100, GetHeight = 20, GetScale = 1, GetEffectiveScale = 1, GetAlpha = 1,
    GetFrameLevel = 1, GetLeft = 100, GetRight = 200, GetTop = 200, GetBottom = 180, GetStringWidth = 50,
    GetStringHeight = 10, GetNumPoints = 1, GetID = 0, GetNumChildren = 0, GetNumRegions = 0,
    GetEffectiveAlpha = 1, GetValue = 0, GetCooldownDuration = 0, GetStringWidth2 = 50, GetTextWidth = 50,
    GetFontHeight = 10, GetNumLines = 0 }
local RETURN_MOCK = { GetStatusBarTexture = 1, GetThumbTexture = 1, GetNormalTexture = 1, GetHighlightTexture = 1,
    GetPushedTexture = 1, GetCheckedTexture = 1, GetDisabledTexture = 1, GetFontString = 1, GetScrollChild = 1,
    GetNormalFontObject = 1 }
local TRACKED = { SetAttribute = 1, SetScript = 1, HookScript = 1, RegisterEvent = 1, RegisterUnitEvent = 1,
    SetPoint = 1, UnregisterEvent = 1, RegisterForClicks = 1 }
-- operations on a protected frame that are blocked in combat lockdown
local PROTECTED_OPS = { SetAttribute = true, SetPoint = true, ClearAllPoints = true, Show = true, Hide = true,
    SetSize = true, SetWidth = true, SetHeight = true, SetScale = true, SetParent = true, SetShown = true,
    EnableMouse = true, SetPropagateMouseClicks = true, SetPropagateMouseMotion = true, SetMouseClickEnabled = true, SetMouseMotionEnabled = true }

local FRAME = {}
local function mock_isSecretValue(v) return M.isSecret(v) end
local frameMT = {}

-- Like the client: a frame that holds a secure (protected) frame anywhere below it becomes protected itself, so
-- Show / Hide / SetPoint / SetScale ... on it in combat are blocked too (s.protectedParent; IsProtected() says true).
function M.markProtectedParents(f)
    local p = rawget(f, "__s").parent
    local guard = 0
    while type(p) == "table" and rawget(p, "__s") and guard < 50 do
        guard = guard + 1
        local ps = rawget(p, "__s")
        if ps.protectedParent then break end
        ps.protectedParent = true
        p = ps.parent
    end
end

local function newFrame(kind, name, parent, template)
    local f = setmetatable({}, frameMT)
    rawset(f, "__s", { kind = kind or "Frame", name = name, parent = parent, template = template,
        attrs = {}, scripts = {}, hooks = {}, events = {}, shown = true, text = "", points = {},
        secure = type(template) == "string" and template:find("Secure") ~= nil, value = 0, checked = false })
    M.frames[#M.frames + 1] = f
    if name then M.setGlobal(name, f) end
    if rawget(f, "__s").secure then M.markProtectedParents(f) end
    if kind == "AuraContainer" and M.AnchorFlowAxis and M.setupContainer then M.setupContainer(f) end
    -- the real BasicFrameTemplateWithInset (and friends) create a close button child: f.CloseButton plus the global
    -- <name>CloseButton. Its default click mimics the template: onCloseCallback if set, else HideUIPanel(frame).
    -- UIPanelCloseButton: its default click hides the parent
    if type(template) == "string" and template:find("UIPanelCloseButton") then
        rawget(f, "__s").scripts.OnClick = function(btn)
            local p = rawget(btn, "__s").parent
            if p and p.Hide then p:Hide() end
        end
    end
    if type(template) == "string" and (template:find("BasicFrameTemplate") or template:find("UIPanelDialogTemplate")) then
        local cb = newFrame("Button", name and (name .. "CloseButton") or nil, f)
        rawget(cb, "__s").scripts.OnClick = function(btn)
            local parentFrame = rawget(btn, "__s").parent
            if parentFrame.onCloseCallback then parentFrame.onCloseCallback(parentFrame)
            elseif rawget(_G, "HideUIPanel") then _G.HideUIPanel(parentFrame) end
        end
        rawset(f, "CloseButton", cb)
    end
    return f
end
M.newFrame = newFrame

function frameMT.__index(t, k)
    if M.missingMethods[k] then return nil end
    local m = FRAME[k]
    if m then return m end
    if isMethodName(k) then
        local fn = function(self, ...)
            local s = rawget(self, "__s")
            if k:sub(1, 6) == "Create" then return newFrame(k:sub(7), nil, self) end
            if RETURN_MOCK[k] then
                s.sub = s.sub or {}
                s.sub[k] = s.sub[k] or newFrame("Texture", nil, self)
                return s.sub[k]
            end
            if DEFAULT_NUM[k] then return DEFAULT_NUM[k] end
            if k:sub(1, 2) == "Is" or k:sub(1, 3) == "Has" or k:sub(1, 3) == "Can" then return false end
            return nil
        end
        FRAME[k] = fn
        return fn
    end
    return nil
end

local function track(self, method, ...)
    local s = rawget(self, "__s")
    local combat = M.state.combat and true or false
    local rec = { frame = s.name or tostring(self), obj = self, method = method, args = { ... },
        combat = combat, secure = s.secure, n = select("#", ...) }
    M.calls[#M.calls + 1] = rec
    if combat and (s.secure or s.protectedParent) and PROTECTED_OPS[method] then
        local v = { frame = rec.frame, method = method, args = rec.args, trace = (#M.violations + #M.softViolations < 3) and debug.traceback("", 3) or nil }
        if method == "SetAttribute" then
            M.violations[#M.violations + 1] = v
        else
            M.softViolations[#M.softViolations + 1] = v
        end
    end
    return rec
end

-- Colour setters validate their arguments like the real client: r, g, b must be numbers (a secret number is fine) and an
-- optional 4th argument (alpha) must be a number too. A colour object { r=, g=, b= } may stand in for r, g, b. Real error
-- (frames.colorMode ~= "class"): "bad argument #4 to 'SetTextColor' (Usage: self:SetTextColor(color [, a]))" when a
-- class token string ended up as alpha.
local COLOR_SETTERS = { SetTextColor = true, SetVertexColor = true, SetStatusBarColor = true, SetColorTexture = true,
    SetBackdropColor = true, SetBackdropBorderColor = true }
local function isNum(v) return type(v) == "number" or M.isSecret(v) end
local function checkColor(method, ...)
    local n = select("#", ...)
    local first = (...)
    local usage = "(Usage: self:" .. method .. "(color [, a]))"
    if type(first) == "table" and not M.isSecret(first) and first.r ~= nil then
        if not (isNum(first.r) and isNum(first.g) and isNum(first.b)) then error("bad argument #1 to '" .. method .. "' " .. usage, 3) end
        local a = select(2, ...)
        if n >= 2 and a ~= nil and not isNum(a) then error("bad argument #2 to '" .. method .. "' " .. usage, 3) end
        return
    end
    for i = 1, 3 do
        if not isNum((select(i, ...))) then error("bad argument #" .. i .. " to '" .. method .. "' " .. usage, 3) end
    end
    if n >= 4 then
        local a = select(4, ...)
        if a ~= nil and not isNum(a) then error("bad argument #4 to '" .. method .. "' " .. usage, 3) end
    end
end
M.checkColor = checkColor

function FRAME.SetAttribute(self, k, v) track(self, "SetAttribute", k, v); rawget(self, "__s").attrs[k] = v end
function FRAME.GetAttribute(self, k) return rawget(self, "__s").attrs[k] end
for _, m in ipairs({ "SetVertexColor", "SetTexture", "SetAtlas", "SetColorTexture", "SetDesaturated", "SetTextColor", "SetTexCoord" }) do
    FRAME[m] = function(self, ...)
        if COLOR_SETTERS[m] then checkColor(m, ...) end
        track(self, m, ...)
        local s = rawget(self, "__s")
        if m == "SetDesaturated" then s.desat = (...) and true or false end
        if m == "SetTexture" then s.texture = (...) end
        if m == "SetTexCoord" then s.texCoord = { ... } end
        if m == "SetVertexColor" or m == "SetTextColor" then
            local r, g, b, a = ...
            s[m == "SetVertexColor" and "vertex" or "textColor"] = { r = r, g = g, b = b, a = a }
        end
    end
end
function FRAME.EnableMouse(self, b) track(self, "EnableMouse", b); rawget(self, "__s").mouse = b and true or false end
function FRAME.SetPropagateMouseClicks(self, b) track(self, "SetPropagateMouseClicks", b); rawget(self, "__s").propClicks = b and true or false end
function FRAME.SetPropagateMouseMotion(self, b) track(self, "SetPropagateMouseMotion", b); rawget(self, "__s").propMotion = b and true or false end
function FRAME.IsMouseEnabled(self) return rawget(self, "__s").mouse == true end
function FRAME.SetFrameLevel(self, l) rawget(self, "__s").level = l end
-- clipping (raid text frame): recorded so tests can check which frame clips its children
function FRAME.SetClipsChildren(self, b) rawget(self, "__s").clipsChildren = b and true or false end
function FRAME.DoesClipChildren(self) return rawget(self, "__s").clipsChildren == true end
function FRAME.GetFrameLevel(self)
    local s = rawget(self, "__s")
    if s.level then return s.level end
    -- like the game: a frame created without an explicit level sits one above its parent
    local p = s.parent
    if type(p) == "table" and rawget(p, "__s") then return FRAME.GetFrameLevel(p) + 1 end
    return 1
end
function FRAME.SetAlpha(self, a) rawget(self, "__s").alpha = a end
function FRAME.GetAlpha(self) local a = rawget(self, "__s").alpha; if a == nil then return 1 end return a end
function FRAME.Play(self) track(self, "Play"); rawget(self, "__s").playing = true end
function FRAME.Stop(self) track(self, "Stop"); rawget(self, "__s").playing = false end
function FRAME.IsPlaying(self) return rawget(self, "__s").playing == true end
function FRAME.SetScript(self, ev, fn) track(self, "SetScript", ev, fn); rawget(self, "__s").scripts[ev] = fn end
function FRAME.GetScript(self, ev) return rawget(self, "__s").scripts[ev] end
function FRAME.HasScript() return true end
function FRAME.HookScript(self, ev, fn)
    track(self, "HookScript", ev, fn)
    local h = rawget(self, "__s").hooks
    h[ev] = h[ev] or {}
    table.insert(h[ev], fn)
end
function FRAME.RegisterEvent(self, ev) track(self, "RegisterEvent", ev); rawget(self, "__s").events[ev] = true end
function FRAME.RegisterUnitEvent(self, ev, ...) track(self, "RegisterUnitEvent", ev, ...); rawget(self, "__s").events[ev] = true end
function FRAME.UnregisterEvent(self, ev) track(self, "UnregisterEvent", ev); rawget(self, "__s").events[ev] = nil end
function FRAME.UnregisterAllEvents(self) rawget(self, "__s").events = {} end
function FRAME.IsEventRegistered(self, ev) return rawget(self, "__s").events[ev] == true end
function FRAME.SetPoint(self, ...)
    track(self, "SetPoint", ...)
    local pts = rawget(self, "__s").points
    pts[#pts + 1] = { ... }
end
function FRAME.ClearAllPoints(self) track(self, "ClearAllPoints"); rawget(self, "__s").points = {} end
function FRAME.GetPoint(self, i)
    local p = rawget(self, "__s").points[i or 1]
    if p then return p[1], p[2], p[3], p[4] or 0, p[5] or 0 end
    return "CENTER", rawget(_G, "UIParent"), "CENTER", 0, 0
end
function FRAME.GetCenter() return 150, 190 end
function FRAME.GetName(self) return rawget(self, "__s").name end
function FRAME.GetParent(self) return rawget(self, "__s").parent end
function FRAME.SetParent(self, p)
    track(self, "SetParent", p)
    local s = rawget(self, "__s")
    s.parent = p
    if s.secure or s.protectedParent then M.markProtectedParents(self) end
end
function FRAME.GetObjectType(self) return rawget(self, "__s").kind end
function FRAME.IsObjectType(self, t) return rawget(self, "__s").kind == t end
function FRAME.Show(self) track(self, "Show"); rawget(self, "__s").shown = true end
function FRAME.Hide(self) track(self, "Hide"); rawget(self, "__s").shown = false end
function FRAME.SetShown(self, b) track(self, "SetShown", b); rawget(self, "__s").shown = b and true or false end
function FRAME.IsShown(self) return rawget(self, "__s").shown end
function FRAME.IsVisible(self) return rawget(self, "__s").shown end
function FRAME.GetTexture(self) return rawget(self, "__s").texture end
function FRAME.SetTitle(self, t) rawget(self, "__s").title = t end
function FRAME.SetText(self, t) local s = rawget(self, "__s"); s.text = t; s.highlighted = nil end
-- EditBox selection / focus state (setting new text clears the selection, like the game)
function FRAME.SetScrollChild(self, child) track(self, "SetScrollChild", child); rawget(self, "__s").scrollChild = child end
function FRAME.GetScrollChild(self) return rawget(self, "__s").scrollChild end
function FRAME.SetFrameStrata(self, strata) rawget(self, "__s").strata = strata end
function FRAME.GetFrameStrata(self) return rawget(self, "__s").strata or "MEDIUM" end
function FRAME.HighlightText(self, from, to) rawget(self, "__s").highlighted = { from = from or 0, to = to } end
function FRAME.SetFocus(self) rawget(self, "__s").focused = true end
function FRAME.ClearFocus(self) rawget(self, "__s").focused = false end
function FRAME.SetFont(self, path, size, flags) rawget(self, "__s").font = { path, size, flags } end
function FRAME.GetFont(self) local f = rawget(self, "__s").font; if f then return f[1], f[2], f[3] end return "Fonts\\FRIZQT__.TTF", 12, "" end
function FRAME.GetText(self) return rawget(self, "__s").text end
function FRAME.SetMinMaxValues(self, lo, hi) local s = rawget(self, "__s"); s.min, s.max = lo, hi end
function FRAME.GetMinMaxValues(self) local s = rawget(self, "__s"); return s.min or 0, s.max or 1 end
function FRAME.SetValue(self, v) rawget(self, "__s").value = v end
function FRAME.GetValue(self) return rawget(self, "__s").value end
function FRAME.SetChecked(self, b) rawget(self, "__s").checked = b end
function FRAME.GetChecked(self) return rawget(self, "__s").checked end
function FRAME.IsProtected(self) local s = rawget(self, "__s"); return (s.secure or s.protectedParent) and true or false end
-- child FRAMES (not textures / font strings), in creation order, like the game
function FRAME.GetChildren(self)
    local out = {}
    for _, f in ipairs(M.frames) do
        local s = rawget(f, "__s")
        if s.parent == self and s.kind ~= "Texture" and s.kind ~= "FontString" and s.kind ~= "MaskTexture" then out[#out + 1] = f end
    end
    return unpack(out)
end
function FRAME.GetRegions() return end
function FRAME.SetSize(self, w, h) track(self, "SetSize", w, h); local s = rawget(self, "__s"); s.w, s.h = w, h end
function FRAME.SetWidth(self, w) track(self, "SetWidth", w); rawget(self, "__s").w = w end
function FRAME.SetHeight(self, h) track(self, "SetHeight", h); rawget(self, "__s").h = h end
-- FontString word wrap: recorded so layout tests can tell a wrapping label from a one-line one (real default: wrap on).
function FRAME.SetWordWrap(self, on) track(self, "SetWordWrap", on); rawget(self, "__s").wordWrap = on and true or false end
function FRAME.GetWordWrap(self) local w = rawget(self, "__s").wordWrap; if w == nil then return true end return w end
function FRAME.GetWidth(self) return rawget(self, "__s").w or 100 end
function FRAME.GetHeight(self) return rawget(self, "__s").h or 20 end
function FRAME.SetAlphaFromBoolean(self, cond, a, b)
    track(self, "SetAlphaFromBoolean", cond, a, b)
    if mock_isSecretValue(cond) then rawget(self, "__s").alpha = a else rawget(self, "__s").alpha = cond and a or b end
end
function FRAME.SetFormattedText(self, fmt, ...)
    local s = rawget(self, "__s")
    local secret = false
    for i = 1, select("#", ...) do if mock_isSecretValue((select(i, ...))) then secret = true end end
    if secret then s.text = "<secret formatted>" else s.text = string.format(fmt, ...) end
end
function FRAME.SetAllPoints(self, rel) track(self, "SetAllPoints", rel); rawget(self, "__s").allPoints = rel or rawget(self, "__s").parent or true end
function FRAME.SetBackdrop(self, bd) track(self, "SetBackdrop", bd); rawget(self, "__s").backdrop = bd or false end
function FRAME.SetBackdropBorderColor(self, ...) checkColor("SetBackdropBorderColor", ...); local r, g, b, a = ...; track(self, "SetBackdropBorderColor", r, g, b, a); rawget(self, "__s").borderColor = { r = r, g = g, b = b, a = a } end
function FRAME.SetBackdropColor(self, ...) checkColor("SetBackdropColor", ...); local r, g, b, a = ...; track(self, "SetBackdropColor", r, g, b, a); rawget(self, "__s").bgColor = { r = r, g = g, b = b, a = a } end
function FRAME.SetStatusBarColor(self, ...) checkColor("SetStatusBarColor", ...); local r, g, b, a = ...; track(self, "SetStatusBarColor", r, g, b, a); rawget(self, "__s").sbColor = { r = r, g = g, b = b, a = a } end
function FRAME.SetScale(self, ...) track(self, "SetScale", ...); rawget(self, "__s").scale = (...) end
function FRAME.GetScale(self) local sc = rawget(self, "__s").scale; if sc == nil then return 1 end return sc end
function FRAME.RegisterForClicks(self, ...) track(self, "RegisterForClicks", ...) end
function FRAME.Click(self, ...) local f = rawget(self, "__s").scripts.OnClick; if f then f(self, ...) end end
function FRAME.CreateAnimationGroup(self) return newFrame("AnimationGroup", nil, self) end
function FRAME.CreateAnimation(self) return newFrame("Animation", nil, self) end
function FRAME.GetTextureFileID() return 134400 end
function FRAME.IsMouseOver(self) return rawget(self, "__s").mouseOver == true end   -- tests set st(frame).mouseOver = true
function FRAME.GetAnchorType() return "ANCHOR_RIGHT" end
function FRAME.GetUnit(self) return rawget(self, "__s").attrs.unit end

frameMT.__tostring = function(self) return "MockFrame<" .. tostring(rawget(self, "__s").name or rawget(self, "__s").kind) .. ">" end

-- Run a frame script, catching errors into M.errors.
local function callProtected(label, fn, ...)
    local ok, err = realXpcall(fn, function(e) return debug.traceback(tostring(e), 2) end, ...)
    if not ok then
        local lines, n = {}, 0
        for line in tostring(err):gmatch("[^\n]+") do
            n = n + 1
            if n <= 5 then lines[#lines + 1] = line end
        end
        M.errors[#M.errors + 1] = label .. ": " .. table.concat(lines, "\n")
    end
    return ok
end

function M.fire(event, ...)
    if event == "UNIT_AURA" and M.refreshContainers then M.refreshContainers() end
    for _, f in ipairs(M.frames) do
        local s = rawget(f, "__s")
        if s.events[event] then
            local fn = s.scripts.OnEvent
            if fn then callProtected(event .. " -> " .. tostring(s.name or s.kind), fn, f, event, ...) end
            for _, h in ipairs(s.hooks.OnEvent or {}) do
                callProtected(event .. " (hook) -> " .. tostring(s.name or s.kind), h, f, event, ...)
            end
        end
    end
end

function M.runScript(script, ...)
    local n = 0
    local list = {}
    for _, f in ipairs(M.frames) do list[#list + 1] = f end
    for _, f in ipairs(list) do
        local s = rawget(f, "__s")
        local fn = s.scripts[script]
        if fn and s.shown then
            n = n + 1
            callProtected(script .. " -> " .. tostring(s.name or s.kind), fn, f, ...)
        end
    end
    return n
end

function M.runOnUpdate(times, dt)
    for _ = 1, times or 3 do
        M.state.now = M.state.now + (dt or 0.1)
        if M.refreshContainers then M.refreshContainers() end
        M.runScript("OnUpdate", dt or 0.1)
    end
end

function M.tick()
    for _, t in ipairs(M.tickers) do
        if not t.cancelled then callProtected("C_Timer ticker", t.fn) end
    end
end

-- Install a fake spellbook. spec = { lines = { {name=, ids={...}} ...}, names = {[id]=name}, passives = {[id]=true},
--   offspec = {[id]=true}, talents = {ids}, legacy = bool (use the pre-11.0 tab API instead of C_SpellBook skill lines) }
function M.setSpellbook(spec)
    local S = M.state
    for id, name in pairs(spec.names or {}) do S.spells[id] = name; S.spellByName[name] = id end
    S.passives = spec.passives or {}
    local flat, lines, off = {}, {}, 0
    for i, line in ipairs(spec.lines or {}) do
        lines[i] = { name = line.name, itemIndexOffset = off, numSpellBookItems = #line.ids }
        for _, id in ipairs(line.ids) do flat[#flat + 1] = id end
        off = off + #line.ids
    end
    M.scanCalls = 0
    local book = {
        IsSpellKnown = function() return true end, IsSpellInSpellBook = function() return true end,
        IsSpellKnownOrInSpellBook = function() return true end, FindSpellBookSlotForSpell = function() return nil end,
    }
    if not spec.legacy then
        book.GetNumSpellBookSkillLines = function() M.scanCalls = M.scanCalls + 1; return #lines end
        book.GetSpellBookSkillLineInfo = function(i) return lines[i] end
        book.GetSpellBookItemInfo = function(j)
            local id = flat[j]
            if not id then return nil end
            return { spellID = id, itemType = 1, isPassive = (S.passives[id] or false), isOffSpec = (spec.offspec and spec.offspec[id]) or false }
        end
    end
    M.setGlobal("C_SpellBook", book)
    if spec.legacy then
        M.setGlobal("C_SpellBook", nil)
        M.setGlobal("GetNumSpellTabs", function() M.scanCalls = M.scanCalls + 1; return #lines end)
        M.setGlobal("GetSpellTabInfo", function(i) local l = lines[i]; return l.name, nil, l.itemIndexOffset, l.numSpellBookItems end)
        M.setGlobal("GetSpellBookItemName", function(j) return S.spells[flat[j]] end)
        M.setGlobal("IsPassiveSpell", function(j) return S.passives[flat[j]] or false end)
    end
    local talents = spec.talents or {}
    if #talents > 0 then
        M.setGlobal("C_ClassTalents", { GetActiveConfigID = function() return 1 end })
        M.setGlobal("C_Traits", {
            GetConfigInfo = function() return { treeIDs = { 1 } } end,
            GetTreeNodes = function() local t = {}; for i = 1, #talents do t[i] = i end return t end,
            GetNodeInfo = function(_, nodeID) return { currentRank = 1, activeEntry = { entryID = nodeID } } end,
            GetEntryInfo = function(_, entryID) return { definitionID = entryID } end,
            GetDefinitionInfo = function(defID) return { spellID = talents[defID] } end,
        })
    end
end

-- Runs a frame's script (and its hooks) the way the engine does, outside any addon xpcall.
function M.runFrameScript(frame, script, ...)
    local s = rawget(frame, "__s")
    local fn = s.scripts[script]
    if fn then callProtected(script .. " -> " .. tostring(s.name or s.kind), fn, frame, ...) end
    for _, h in ipairs(s.hooks[script] or {}) do callProtected(script .. " (hook) -> " .. tostring(s.name or s.kind), h, frame, ...) end
end

-- Moves the clock forward in `step` increments: OnUpdate scripts run each step and C_Timer.After callbacks fire once their
-- delay has elapsed (callbacks scheduled meanwhile are honoured too). flushTimers() still runs everything at once.
function M.advance(seconds, step)
    step = step or 0.1
    local elapsed = 0
    while elapsed < seconds - 1e-9 do
        local dt = math.min(step, seconds - elapsed)
        elapsed = elapsed + dt
        M.state.now = M.state.now + dt
        if M.refreshContainers then M.refreshContainers() end
        M.runScript("OnUpdate", dt)
        local i = 1
        while i <= #M.timers do
            local t = M.timers[i]
            if t.cancelled then table.remove(M.timers, i)
            elseif (t.due or 0) <= M.state.now + 1e-9 then
                table.remove(M.timers, i)
                callProtected("C_Timer", t.fn)
                i = 1
            else i = i + 1 end
        end
    end
end

-- Installs C_UnitAuras.GetAuraSlots / GetAuraDataBySlot (Blizzard's own enumeration path). opts.page = slots per call (default 2, so a
-- continuation token is needed). Slots are the aura instance ids. S.failEnumerate / S.failSlots make them raise; S.failSlotData makes
-- GetAuraDataBySlot raise. Every call is recorded in M.slotCalls.
function M.enableSlots(opts)
    opts = opts or {}
    local S = M.state
    M.slotCalls = {}
    local function matches(unit, filter)
        local out = {}
        local harmful = tostring(filter):find("HARMFUL", 1, true) ~= nil
        for _, a in ipairs(S.auras[unit] or {}) do
            local isHarm = a.isHarmful
            if isHarm == nil then isHarm = not a.isHelpful end
            local ok = (harmful == (isHarm and true or false))
            if ok and tostring(filter):find("|PLAYER", 1, true) then ok = a.sourceUnit == "player" end
            if ok and tostring(filter):find("RAID_PLAYER_DISPELLABLE", 1, true) then ok = a.dispelName ~= nil end
            if ok then out[#out + 1] = a end
        end
        return out
    end
    C_UnitAuras.GetAuraSlots = M.countAuraFn("C_UnitAuras.GetAuraSlots", function(unit, filter, max, token)
        M.slotCalls[#M.slotCalls + 1] = { "slots", unit, filter, max, token }
        if S.failEnumerate or S.failSlots or S.failAll then error("slots unavailable") end
        local list = matches(unit, filter)
        local page = opts.page or 2
        local from = token or 1
        local out = {}
        local last = math.min(#list, from + page - 1)
        for i = from, last do out[#out + 1] = list[i].auraInstanceID or list[i].spellId end
        local nextToken = last < #list and (last + 1) or nil
        return nextToken, unpack(out)
    end)
    C_UnitAuras.GetAuraDataBySlot = M.countAuraFn("C_UnitAuras.GetAuraDataBySlot", function(unit, slot)
        M.slotCalls[#M.slotCalls + 1] = { "data", unit, slot }
        if S.failEnumerate or S.failSlotData or S.failAll then error("slot data unavailable") end
        for _, a in ipairs(S.auras[unit] or {}) do
            if (a.auraInstanceID or a.spellId) == slot then return M.wrapAura(a) end
        end
        return nil
    end)
end

-- Does an aura (a table of S.auras) pass a filter string? (HELPFUL / HARMFUL, |PLAYER, RAID_PLAYER_DISPELLABLE)
function M.auraPassesFilter(a, filter)
    filter = tostring(filter)
    local harmful = a.isHarmful
    if harmful == nil then harmful = not a.isHelpful end
    harmful = harmful and true or false
    if filter:find("HARMFUL", 1, true) and not harmful then return false end
    if filter:find("HELPFUL", 1, true) and harmful then return false end
    if filter:find("|PLAYER", 1, true) and a.sourceUnit ~= "player" then return false end
    if filter:find("RAID_PLAYER_DISPELLABLE", 1, true) and a.dispelName == nil then return false end
    return true
end

-- ---------------------------------------------------------------- native AuraContainer (Blizzard draws the icons, combat included)
-- M.enableContainers() defines the enums the addon checks and makes CreateFrame("AuraContainer", ...) return a working container:
-- SetUnit/GetUnit, AddAuraGroup(key, filter, opts), SetFlowLayout*, SetAuraGroupFilterString/MaxFrameCount/Layout, GetAuraGroupFrame/Count,
-- and group buttons with SetIcon / SetDurationCooldown / SetDurationText / SetApplicationCount / Add/RemoveDispelTypeTexture. The buttons
-- are drawn from the mock's aura state (S.auras) whatever S.combat / S.secret / S.failEnumerate say. Failure injection:
--   S.containerFailAt = { [n] = true }   the n-th AddAuraGroup call raises (per-button fallback)
--   S.containerFail = { SetUnit = true, ... }   the named method raises
-- Every container call is recorded in M.containerCalls = { { container, method, args, combat } ... }.
M.containers = {}
M.containerCalls = {}
local function containerCall(c, method, ...)
    M.containerCalls[#M.containerCalls + 1] = { container = c, method = method, args = { ... }, combat = M.state.combat and true or false }
    local fail = M.state.containerFail
    if fail and fail[method] then error("container " .. method .. " unavailable") end
end

local function flowPositions(c)
    -- Generic flow layout from the numbers the addon gave: returns for slot index i (0-based) the corner offset (x, y) of the icon,
    -- measured from the container's anchor corner, and the overall content size.
    local fl, grp = c.flow, c.layout
    local w, h = grp.elementWidth or 16, grp.elementHeight or 16
    local sp, lsp = grp.elementSpacing or 0, grp.lineSpacing or 0
    local pad = fl.padding or { 0, 0, 0, 0 }                       -- left, right, top, bottom
    local vertical = fl.axis == M.AnchorFlowAxis.Vertical
    local along = vertical and h or w
    local across = vertical and w or h
    local perLine = math.max(1, math.floor(((fl.maxLine or 1e9) + sp) / (along + sp)))
    return function(i)
        local a, line = i % perLine, math.floor(i / perLine)
        local ax, ay = a * (along + sp), line * (across + lsp)
        local dx, dy = vertical and ay or ax, vertical and ax or ay     -- dx: horizontal travel, dy: vertical travel
        local anchor = fl.anchor or "TOPLEFT"
        local x = anchor:find("RIGHT") and -(pad[2] + dx) or (pad[1] + dx)
        local y = anchor:find("BOTTOM") and (pad[4] + dy) or -(pad[3] + dy)
        return x, y
    end, perLine
end

local function drawContainer(c)
    local S = M.state
    local unit = c.unit
    for key, grp in pairs(c.groups) do
        local matches = {}
        if unit and unit ~= "none" then
            for _, a in ipairs(S.auras[unit] or {}) do
                if M.auraPassesFilter(a, grp.filter) then matches[#matches + 1] = a end
            end
        end
        if S.auraPoolLazy and M.growAuraGroup then M.growAuraGroup(c, grp, math.min(#matches, grp.maxFrameCount or 0)) end
        local pos = flowPositions(c)
        local anchor = c.flow.anchor or "TOPLEFT"
        for i, btn in ipairs(grp.frames) do
            local a = matches[i]
            local s = rawget(btn, "__s")
            if a and i <= (grp.maxFrameCount or 0) then
                s.shown = true
                btn.drawnAura = a
                local x, y = pos(i - 1)
                btn:ClearAllPoints()
                btn:SetPoint(anchor, c.frame, anchor, x, y)
                if btn.Icon then btn.Icon:SetTexture(a.icon) end
                if btn.Count then btn.Count:SetText((a.applications or 0) > 1 and tostring(a.applications) or "") end
                if btn.Time then
                    local rem = (a.expirationTime or 0) > 0 and (a.expirationTime - S.now) or nil
                    btn.Time:SetText(rem and rem > 0 and string.format("%d", rem) or "")
                end
                if btn.DispelBorder then
                    local want = btn.dispelTextures and btn.dispelTextures[btn.DispelBorder]
                    local show = want and a.dispelName ~= nil and true or false
                    rawget(btn.DispelBorder, "__s").shown = show
                end
            else
                s.shown = false
                btn.drawnAura = nil
            end
        end
    end
    -- content size
    local fl, any = c.flow, 0
    for _, grp in pairs(c.groups) do
        local shown = 0
        for _, btn in ipairs(grp.frames) do if rawget(btn, "__s").shown then shown = shown + 1 end end
        any = math.max(any, shown)
    end
end

function M.refreshContainers()
    for _, c in ipairs(M.containers) do if c.frame and c.groups then drawContainer(c) end end
end

local function makeGroupButton(c, grp)
    local tmpl = grp.templateNames and grp.templateNames[1] or "CustomAuraButtonTemplate"
    local btn = newFrame("AuraButton", nil, c.frame, tmpl)
    local function sub(kind, fkind) local r = newFrame(kind, nil, btn); rawget(r, "__s").kind = fkind or kind; return r end
    rawset(btn, "Backdrop", sub("Texture")); rawset(btn, "Icon", sub("Texture")); rawset(btn, "DispelBorder", sub("Texture"))
    rawset(btn, "Count", sub("FontString")); rawset(btn, "Time", sub("FontString"))
    local cd = newFrame("Cooldown", nil, btn, "CooldownFrameTemplate"); rawset(btn, "Cooldown", cd)
    btn.dispelTextures = {}
    rawset(btn, "SetIcon", function(self, tex) containerCall(c, "button:SetIcon", tex); self.wiredIcon = tex end)
    rawset(btn, "SetDurationCooldown", function(self, cooldown) containerCall(c, "button:SetDurationCooldown", cooldown); self.wiredCooldown = cooldown end)
    rawset(btn, "SetDurationText", function(self, fs, opts) containerCall(c, "button:SetDurationText", fs, opts); self.wiredTime = fs; self.durationTextOpts = opts end)
    rawset(btn, "SetApplicationCount", function(self, fs, opts) containerCall(c, "button:SetApplicationCount", fs, opts); self.wiredCount = fs end)
    rawset(btn, "AddDispelTypeTexture", function(self, tex, opts) containerCall(c, "button:AddDispelTypeTexture", tex, opts); self.dispelTextures[tex] = opts end)
    rawset(btn, "RemoveDispelTypeTexture", function(self, tex) containerCall(c, "button:RemoveDispelTypeTexture", tex); self.dispelTextures[tex] = nil end)
    -- mouse state is recorded (the generic setters would be no-ops). These buttons come from a forbidden-object-table template:
    -- in combat the game BLOCKS every mouse setter on them (real log, count 80: "ADDON_ACTION_BLOCKED: Button:SetPropagateMouseMotion()").
    -- A blocked call changes nothing, is listed in M.blocked and lands in M.errors (the game blames the addon).
    local function mouseSetter(method, field)
        return function(self, v)
            track(self, method, v)
            local s = rawget(self, "__s")
            s.mouseCalls = (s.mouseCalls or 0) + 1
            if M.state.combat then
                M.blocked[#M.blocked + 1] = { frame = self, method = method }
                M.errors[#M.errors + 1] = "ADDON_ACTION_BLOCKED: Button:" .. method .. "()"
                return
            end
            s[field] = v and true or false
        end
    end
    rawset(btn, "SetMouseClickEnabled", mouseSetter("SetMouseClickEnabled", "mouseClick"))
    rawset(btn, "SetMouseMotionEnabled", mouseSetter("SetMouseMotionEnabled", "mouseMotion"))
    rawset(btn, "SetPropagateMouseMotion", mouseSetter("SetPropagateMouseMotion", "propagateMotion"))
    rawset(btn, "SetPropagateMouseClicks", mouseSetter("SetPropagateMouseClicks", "propagateClicks"))
    rawset(btn, "EnableMouse", mouseSetter("EnableMouse", "mouse"))
    rawget(btn, "__s").shown = false
    return btn
end

-- The real container makes buttons when it needs them, also mid-fight (initializeFrame then runs in combat). By default the mock
-- pre-creates the whole pool; S.auraPoolLazy = true makes it grow only when more auras match than buttons exist (see drawContainer).
local function growGroup(c, grp, n)
    while #grp.frames < n do
        local btn = makeGroupButton(c, grp)
        grp.frames[#grp.frames + 1] = btn
        if grp.initializeFrame then grp.initializeFrame(btn) end
    end
end
local function ensureGroupFrames(c, grp)
    if M.state.auraPoolLazy then return end
    growGroup(c, grp, grp.maxFrameCount or 0)
end
M.growAuraGroup = growGroup

function M.setupContainer(frame)
    local c = { frame = frame, unit = nil, groups = {}, flow = { padding = { 0, 0, 0, 0 } }, layout = {} }
    M.containers[#M.containers + 1] = c
    rawset(frame, "__container", c)
    local function def(name, fn) rawset(frame, name, function(self, ...) containerCall(c, name, ...); return fn(self, ...) end) end
    def("SetUnit", function(_, unit) c.unit = unit; drawContainer(c) end)
    def("GetUnit", function() return c.unit end)
    def("AddAuraGroup", function(_, key, filter, opts)
        local S = M.state
        c.addCalls = (M.containerAddCalls or 0)
        M.containerAddCalls = (M.containerAddCalls or 0) + 1
        if S.containerFailAt and S.containerFailAt[M.containerAddCalls] then error("AddAuraGroup failed (injected)") end
        opts = opts or {}
        local grp = { key = key, filter = filter, maxFrameCount = opts.maxFrameCount, templateNames = opts.templateNames,
            initializeFrame = opts.initializeFrame, sortMethod = opts.sortMethod, sortDirection = opts.sortDirection, frames = {} }
        if opts.layout then for k, v in pairs(opts.layout) do c.layout[k] = v end end
        c.groups[key] = grp
        ensureGroupFrames(c, grp)
        drawContainer(c)
    end)
    def("SetAuraGroupFilterString", function(_, key, filter) c.groups[key].filter = filter; drawContainer(c) end)
    def("SetAuraGroupMaxFrameCount", function(_, key, n) local g = c.groups[key]; g.maxFrameCount = n; ensureGroupFrames(c, g); drawContainer(c) end)
    def("SetAuraGroupLayout", function(_, key, layout) for k, v in pairs(layout or {}) do c.layout[k] = v end; drawContainer(c) end)
    def("GetAuraGroupFrameCount", function(_, key) local g = c.groups[key]; return g and #g.frames or 0 end)
    def("GetAuraGroupFrame", function(_, key, i) local g = c.groups[key]; return g and g.frames[i] end)
    def("SetFlowLayoutAxis", function(_, axis) c.flow.axis = axis; drawContainer(c) end)
    def("SetFlowLayoutAnchorPoint", function(_, p) c.flow.anchor = p; drawContainer(c) end)
    def("SetFlowLayoutGrowthDirection", function(_, h, v) c.flow.growth = { h, v }; drawContainer(c) end)
    def("SetFlowLayoutPadding", function(_, l, r, t, b) c.flow.padding = { l, r, t, b }; drawContainer(c) end)
    def("SetFlowLayoutMaximumLineSize", function(_, n) c.flow.maxLine = n; drawContainer(c) end)
end

-- opts.noFormatter = true: no SecondsFormatter API at all; opts.missingEnums = { SecondsFormatterRounding = true, ... }: leave single enums out.
-- Formatter objects record every configuration call in obj.config (and curves their points in obj.points).
M.formatters = {}
function M.enableContainers(opts)
    opts = opts or {}
    M.containers, M.containerCalls, M.containerAddCalls, M.formatters = {}, {}, 0, {}
    M.AnchorFlowAxis = { Horizontal = 1, Vertical = 2 }
    local enumExtra = { CustomAuraButtonDispelTypeTextureStyle = { Border = 1, Icon = 2, Overlay = 3 } }
    if not opts.noFormatter then
        enumExtra.SecondsFormatterInterval = { Seconds = 1, Minutes = 2, Hours = 3, Days = 4 }
        enumExtra.SecondsFormatterAbbreviation = { OneLetter = 1, Truncate = 2 }
        enumExtra.SecondsFormatterRounding = { Truncate = 1, Round = 2 }
        enumExtra.SecondsFormatterIntervalWhitespace = { StripIgnoreLocale = 1, Keep = 2 }
    end
    for name in pairs(opts.missingEnums or {}) do enumExtra[name] = nil end
    M.setGlobal("Enum", setmetatable(enumExtra, { __index = rawget(_G, "Enum") }))
    M.setGlobal("AuraContainerSortMethod", { Default = 0, Time = 1, Name = 2 })
    M.setGlobal("AuraContainerSortDirection", { Normal = 0, Reverse = 1 })
    M.setGlobal("AnchorUtil", { FlowDirection = { Left = "Left", Right = "Right", Up = "Up", Down = "Down" }, FlowLayoutAxis = M.AnchorFlowAxis })
    if not opts.noFormatter then
        local function recorder(kind)
            local obj = { kind = kind, config = {}, points = {} }
            return setmetatable(obj, { __index = function(_, k)
                if type(k) == "string" and k:match("^Set") then return function(self, ...) self.config[k] = { ... } end end
                if k == "AddPoint" then return function(self, x, y) self.points[#self.points + 1] = { x, y } end end
            end })
        end
        M.setGlobal("C_StringUtil", { CreateSecondsFormatter = function() local f = recorder("formatter"); M.formatters[#M.formatters + 1] = f; return f end })
        local curveUtil = rawget(_G, "C_CurveUtil") or {}
        local merged = {}
        for k, v in pairs(curveUtil) do merged[k] = v end
        merged.CreateCurve = function() local c = recorder("curve"); M.newFloatCurve(c); return c end
        M.setGlobal("C_CurveUtil", merged)
    end
end

-- UNIT_AURA with an updateInfo table. info = { full = bool, added = {auras}, updated = {ids}, removed = {ids} }
function M.auraEvent(unit, info)
    info = info or {}
    local ui = { isFullUpdate = info.full and true or false, addedAuras = info.added, updatedAuraInstanceIDs = info.updated,
        removedAuraInstanceIDs = info.removed }
    M.fire("UNIT_AURA", unit, ui)
end

function M.flushTimers()
    local guard = 0
    while #M.timers > 0 and guard < 1000 do
        guard = guard + 1
        local t = table.remove(M.timers, 1)
        if not t.cancelled then callProtected("C_Timer", t.fn) end
    end
end

function M.callsTo(method, filterFn)
    local out = {}
    for _, c in ipairs(M.calls) do
        if c.method == method and (not filterFn or filterFn(c)) then out[#out + 1] = c end
    end
    return out
end

-- ------------------------------------------------------------------ globals
function M.setGlobal(k, v)
    if not installed[k] then
        installed[k] = true
        realG[k] = rawget(_G, k)
    end
    rawset(_G, k, v)
end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID",
    "DEATHKNIGHT", "MONK", "DEMONHUNTER", "EVOKER" }
local CLASS_LOC = { WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
    SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid", DEATHKNIGHT = "Death Knight",
    MONK = "Monk", DEMONHUNTER = "Demon Hunter", EVOKER = "Evoker" }

function M.resetState()
    M.state = {
        combat = false, secret = false, now = 1000, macClient = false,
        shift = false, ctrl = false, alt = false, meta = false,
        cursor = nil, inGroup = false, inRaid = false,
        units = {
            player = { name = "Healer", class = "PALADIN", health = 800, maxHealth = 1000, power = 500, maxPower = 1000, powerType = 0, role = "HEALER" },
            party1 = { name = "Tank", class = "WARRIOR", health = 900, maxHealth = 1000, power = 50, maxPower = 100, powerType = 1, role = "TANK" },
            party2 = { name = "Wizard", class = "MAGE", health = 400, maxHealth = 700, power = 300, maxPower = 700, powerType = 0, role = "DAMAGER" },
            party3 = { name = "Priestess", class = "PRIEST", health = 700, maxHealth = 700, power = 300, maxPower = 700, powerType = 0, role = "HEALER" },
        },
        auras = {},   -- unit -> array of aura tables (spellId,name,icon,duration,expirationTime,applications,...)
        dead = {}, offline = {}, outOfRange = {},
    }
    M.calls, M.errors, M.undefined, M.violations, M.softViolations, M.printed, M.timers, M.tickers = {}, {}, {}, {}, {}, {}, {}, {}
    M.blocked = {}
    M.missingMethods, M.createdInCombat = {}, {}
    M.xdepth = 0
    M.frames = {}
end

-- The game's unit watch (runs in combat too: it is secure code): every watched frame is shown when its "unit" attribute
-- exists (a secret answer counts as existing) and hidden otherwise; OnShow / OnHide run on a change, like the engine.
-- Secure macro conditions for state drivers: "[group:raid] hide; show". Supports group, group:party, group:raid,
-- combat, nocombat and an empty / bare clause (the default). Returns the action of the first matching clause or nil.
function M.evalMacroCondition(cond)
    local S = M.state
    local function test(c)
        c = c:gsub("^%s+", ""):gsub("%s+$", "")
        if c == "" then return true end
        if c == "group:raid" then return S.inRaid and true or false end
        if c == "group:party" or c == "group" then return (S.inGroup or S.inRaid) and true or false end
        if c == "combat" then return S.combat and true or false end
        if c == "nocombat" then return not S.combat end
        error("mock: unsupported macro condition '" .. c .. "'")
    end
    for clause in tostring(cond):gmatch("[^;]+") do
        local blocks, action = {}, clause
        action = clause:gsub("%b[]", function(b) blocks[#blocks + 1] = b:sub(2, -2); return "" end)
        action = action:gsub("^%s+", ""):gsub("%s+$", "")
        local match = #blocks == 0
        for _, b in ipairs(blocks) do
            local all = true
            for c in (b .. ","):gmatch("([^,]*),") do if not test(c) then all = false end end
            if all then match = true end
        end
        if match then return action end
    end
    return nil
end

-- The game runs "visibility" state drivers itself, also in combat (no addon code, so never a violation).
function M.applyStateDrivers()
    local list = {}
    for _, f in ipairs(M.frames) do list[#list + 1] = f end
    for _, f in ipairs(list) do
        local s = rawget(f, "__s")
        local cond = s.stateDrivers and s.stateDrivers.visibility
        if cond then
            local action = M.evalMacroCondition(cond)
            local want = action == "show"
            if (action == "show" or action == "hide") and want ~= s.shown then
                s.shown = want
                M.runFrameScript(f, want and "OnShow" or "OnHide")
            end
        end
    end
end

-- Effective visibility like the client: shown and every parent shown.
function M.isVisible(f)
    local guard = 0
    while type(f) == "table" and rawget(f, "__s") and guard < 50 do
        guard = guard + 1
        local s = rawget(f, "__s")
        if not s.shown then return false end
        f = s.parent
    end
    return true
end

function M.applyUnitWatch()
    M.applyStateDrivers()
    local exists = rawget(_G, "UnitExists")
    local list = {}
    for _, f in ipairs(M.frames) do list[#list + 1] = f end
    for _, f in ipairs(list) do
        local s = rawget(f, "__s")
        if s.unitWatch then
            local unit = s.attrs.unit
            local ok, e = pcall(exists, unit)
            local want = ok and (M.isSecret(e) or (e and true)) and true or false
            if type(unit) ~= "string" then want = false end
            if want ~= s.shown then
                s.shown = want
                M.runFrameScript(f, want and "OnShow" or "OnHide")
            end
        end
    end
end

-- A raid of n players (0 = leave the raid). Units raid1..raidN get made-up names, classes, roles and health; the player
-- is raid<playerIndex> (the SAME table as S.units.player, so changes to the player show on both tokens and UnitIsUnit
-- says they are the same). Subgroups default to ceil(i / 5).
-- opts = { playerIndex = 1, subgroups = { [i] = g }, members = { [i] = { name, class, role, health, maxHealth } },
--          party = true (party1..4 become the other members of the player's subgroup, like the real client) }
local RAID_ROLES = { "TANK", "HEALER", "DAMAGER", "DAMAGER", "DAMAGER" }
function M.setRaid(n, opts)
    opts = opts or {}
    local S = M.state
    for k in pairs(S.units) do if type(k) == "string" and k:match("^raid%d+$") then S.units[k] = nil end end
    S.raid, S.unitAlias = {}, {}
    S.inRaid = n > 0
    S.raidSize = n
    local pi = opts.playerIndex or 1
    for i = 1, n do
        local spec = opts.members and opts.members[i] or {}
        local token = "raid" .. i
        local u
        if i == pi then
            u = S.units.player
            S.unitAlias[token] = "player"
        else
            local classes = { "WARRIOR", "PRIEST", "MAGE", "ROGUE", "DRUID", "PALADIN", "SHAMAN", "HUNTER", "WARLOCK", "MONK" }
            u = { name = spec.name or ("Raider" .. i), class = spec.class or classes[(i - 1) % #classes + 1],
                health = spec.health or 1000, maxHealth = spec.maxHealth or 1000, power = 100, maxPower = 100, powerType = 0,
                role = spec.role or RAID_ROLES[(i - 1) % #RAID_ROLES + 1] }
        end
        S.units[token] = u
        local g = spec.subgroup or (opts.subgroups and opts.subgroups[i]) or math.ceil(i / 5)
        S.raid[i] = { unit = token, subgroup = g, rank = i == 1 and 2 or 0 }
    end
    if opts.party and n > 0 then
        for k = 1, 4 do S.units["party" .. k] = nil end
        local mine, k = S.raid[pi] and S.raid[pi].subgroup, 0
        for i = 1, n do
            if i ~= pi and S.raid[i].subgroup == mine and k < 4 then
                k = k + 1
                S.units["party" .. k] = S.units["raid" .. i]
                S.unitAlias["party" .. k] = "raid" .. i
            end
        end
        S.groupSize = k
    end
    if n > 0 then S.inGroup = true else S.inGroup = (S.groupSize or 0) > 0 end
end

-- Loaded addons with CPU / memory numbers for /hf perf. list = { { name, loaded = true, mem = KB, cpu = ms (session avg or
-- total), recent = ms, peak = ms } }. opts:
--   profiler = true (C_AddOnProfiler + Enum.AddOnProfilerMetric), profilerEnabled = true (IsEnabled answer; nil = no IsEnabled),
--   scriptProfile = "0" | "1" (GetCVar), cpuUsage = true (GetAddOnCPUUsage / UpdateAddOnCPUUsage exist), memory = true,
--   secret = true (every metric / memory value is secret), raise = true (every API raises).
-- Counts: M.perfCalls = { memUpdate, memUpdateCombat, cpuUpdate }.
function M.setAddons(list, opts)
    opts = opts or {}
    local S = M.state
    M.perfCalls = { memUpdate = 0, memUpdateCombat = 0, cpuUpdate = 0 }
    local byName = {}
    for _, a in ipairs(list) do byName[a.name] = a end
    local function boom() if opts.raise then error("addon API unavailable") end end
    local function val(v) if opts.secret then return M.newSecret() end return v end
    local addons = rawget(_G, "C_AddOns") or {}
    addons.GetNumAddOns = function() boom(); return #list end
    addons.GetAddOnInfo = function(i) boom(); local a = list[i]; if a then return a.name, a.name, "", true, "INSECURE" end end
    addons.IsAddOnLoaded = function(name) boom(); local a = byName[name]; return a ~= nil and a.loaded ~= false end
    M.setGlobal("C_AddOns", addons)
    M.setGlobal("GetNumAddOns", nil)
    if opts.memory ~= false then
        M.setGlobal("UpdateAddOnMemoryUsage", function()
            boom()
            M.perfCalls.memUpdate = M.perfCalls.memUpdate + 1
            if S.combat then M.perfCalls.memUpdateCombat = M.perfCalls.memUpdateCombat + 1 end
        end)
        M.setGlobal("GetAddOnMemoryUsage", function(name) boom(); local a = byName[name]; return val(a and a.mem or 0) end)
    else
        M.setGlobal("UpdateAddOnMemoryUsage", nil); M.setGlobal("GetAddOnMemoryUsage", nil)
    end
    local metrics = { SessionAverageTime = 1, RecentAverageTime = 2, PeakTime = 3 }
    if opts.profiler ~= false then
        local P = { GetAddOnMetric = function(name, id)
            boom()
            local a = byName[name]
            if not a then return 0 end
            if id == metrics.SessionAverageTime then return val(a.cpu or 0) end
            if id == metrics.RecentAverageTime then return val(a.recent or a.cpu or 0) end
            if id == metrics.PeakTime then return val(a.peak or 0) end
            return 0
        end }
        if opts.profilerEnabled ~= nil then P.IsEnabled = function() boom(); return opts.profilerEnabled end end
        M.setGlobal("C_AddOnProfiler", P)
        rawget(_G, "Enum").AddOnProfilerMetric = metrics
    else
        M.setGlobal("C_AddOnProfiler", nil)
        rawget(_G, "Enum").AddOnProfilerMetric = nil
    end
    local cvar = opts.scriptProfile or "0"
    M.setGlobal("GetCVar", function(name) boom(); if name == "scriptProfile" then return cvar end return "0" end)
    if opts.cpuUsage then
        M.setGlobal("GetAddOnCPUUsage", function(name) boom(); local a = byName[name]; return val(a and a.cpu or 0) end)
        M.setGlobal("UpdateAddOnCPUUsage", function() boom(); M.perfCalls.cpuUpdate = M.perfCalls.cpuUpdate + 1 end)
    else
        M.setGlobal("GetAddOnCPUUsage", nil); M.setGlobal("UpdateAddOnCPUUsage", nil)
    end
end

function M.setGroup(n)
    -- n = number of party members besides player (0-3)
    M.state.inGroup = n > 0
    M.state.groupSize = n
end

local function unitState(u) return M.state.units[u] end
local function numOrSecret(v) if M.state.secret or M.state.secretAll then return M.newSecret() end return v end

local function buildGlobals()
    local S = M.state
    local g = M.setGlobal

    -- Lua / Blizzard string+table helpers
    g("strtrim", function(s, chars)
        chars = chars or "%s"
        return (tostring(s):gsub("^[" .. chars .. "]+", ""):gsub("[" .. chars .. "]+$", ""))
    end)
    g("strsplit", function(delim, s, pieces)
        local out, pos = {}, 1
        s = tostring(s)
        while true do
            if pieces and #out >= pieces - 1 then break end
            local a, b = s:find(delim, pos, true)
            if not a then break end
            out[#out + 1] = s:sub(pos, a - 1)
            pos = b + 1
        end
        out[#out + 1] = s:sub(pos)
        return unpack(out)
    end)
    g("strjoin", function(d, ...) local t = { ... }; for i = 1, select("#", ...) do t[i] = tostring(t[i]) end return table.concat(t, d) end)
    g("wipe", function(t) for k in pairs(t) do t[k] = nil end return t end)
    g("tinsert", table.insert); g("tremove", table.remove); g("sort", table.sort)
    g("format", string.format); g("gsub", string.gsub); g("strfind", string.find); g("strmatch", string.match)
    g("strsub", string.sub); g("strlen", string.len); g("strlower", string.lower); g("strupper", string.upper)
    g("strrep", string.rep); g("gmatch", string.gmatch); g("strbyte", string.byte); g("strchar", string.char)
    g("max", math.max); g("min", math.min); g("floor", math.floor); g("ceil", math.ceil); g("abs", math.abs)
    g("sqrt", math.sqrt); g("mod", math.fmod); g("random", math.random); g("sin", math.sin); g("cos", math.cos)
    g("CopyTable", deepcopy)
    g("tContains", function(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end)
    g("tIndexOf", function(t, v) for i, x in ipairs(t) do if x == v then return i end end end)
    g("Round", function(v) return math.floor(v + 0.5) end)
    g("Clamp", function(v, a, b) return math.max(a, math.min(b, v)) end)
    g("Mixin", function(o, ...) for i = 1, select("#", ...) do for k, v in pairs((select(i, ...))) do o[k] = v end end return o end)
    g("CreateFromMixins", function(...) local o = {}; for i = 1, select("#", ...) do for k, v in pairs((select(i, ...))) do o[k] = v end end return o end)
    g("CreateColor", function(r, gg, b, a) return { r = r, g = gg, b = b, a = a, GetRGB = function(s) return s.r, s.g, s.b end,
        GetRGBA = function(s) return s.r, s.g, s.b, s.a == nil and 1 or s.a end, GenerateHexColor = function() return "ffffffff" end } end)
    g("date", os.date); g("time", os.time)
    g("GetTime", function() return S.now end)
    g("GetServerTime", function() return os.time() end)
    g("debugprofilestop", function() return S.now * 1000 end)
    g("geterrorhandler", function() return function(e) M.errors[#M.errors + 1] = tostring(e) end end)
    g("seterrorhandler", function() end)
    g("issecurevariable", function() return false end)
    g("securecall", function(f, ...) if type(f) == "string" then f = _G[f] end return f(...) end)
    g("securecallfunction", function(f, ...) return f(...) end)
    g("hooksecurefunc", function(a, b, c)
        local tbl, name, hook
        if type(a) == "table" then tbl, name, hook = a, b, c else tbl, name, hook = _G, a, b end
        local orig = tbl[name]
        tbl[name] = function(...)
            local r = { orig and orig(...) }
            hook(...)
            return unpack(r)
        end
    end)

    -- game/client info
    g("IsMacClient", function() return S.macClient end)
    g("GetBuildInfo", function() return "12.0.0", "60000", "Jan 1 2026", 120000 end)
    g("GetLocale", function() return "enUS" end)
    g("UnitFactionGroup", function() return "Alliance", "Alliance" end)
    g("GetAddOnMetadata", function(_, k) if k == "Version" then return S.addonVersion or nil end end)
    S.addonVersion = "0.0.0-test"
    g("C_AddOns", {
        GetAddOnMetadata = function(_, k) if k == "Version" then return S.addonVersion or nil end end,
        IsAddOnLoaded = function() return true end, GetAddOnInfo = function() return "HealerForever" end,
        LoadAddOn = function() return true end,
    })
    g("InCombatLockdown", function() return S.combat end)
    g("issecretvalue", function(v) if S.secret then return true end return M.isSecret(v) end)
    g("canaccessvalue", function(v) return not (S.secret or M.isSecret(v)) end)
    g("issecrettable", function() return S.secret end)
    g("canaccesstable", function() return not S.secret end)
    g("GetCursorInfo", function() if S.cursor then return unpack(S.cursor) end end)
    g("ClearCursor", function() S.cursor = nil end)
    g("IsShiftKeyDown", function() return S.shift end)
    g("IsControlKeyDown", function() return S.ctrl end)
    g("IsAltKeyDown", function() return S.alt end)
    g("IsMetaKeyDown", function() return S.meta end)
    g("IsModifierKeyDown", function() return S.shift or S.ctrl or S.alt or S.meta end)
    g("IsLeftShiftKeyDown", function() return S.shift end)
    g("IsRightShiftKeyDown", function() return false end)
    g("GetCursorPosition", function() return 500, 400 end)
    g("PlaySound", function() end)
    g("PlaySoundFile", function() end)
    g("SOUNDKIT", setmetatable({}, { __index = function() return 1 end }))
    g("GetBindingKey", function() return nil end)
    g("SetBinding", function() end)
    g("SaveBindings", function() end)
    g("SetOverrideBindingClick", function(...) M.calls[#M.calls + 1] = { frame = "_G", method = "SetOverrideBindingClick", args = { ... }, combat = S.combat } end)
    g("ClearOverrideBindings", function(...) M.calls[#M.calls + 1] = { frame = "_G", method = "ClearOverrideBindings", args = { ... }, combat = S.combat } end)
    -- the addon's own xpcall depth: restricted closures must never be called from inside it
    g("xpcall", function(f, handler)
        M.xdepth = M.xdepth + 1
        local r = { realXpcall(f, handler) }
        M.xdepth = M.xdepth - 1
        return unpack(r)
    end)
    g("SecureHandlerWrapScript", function(frame, script, header, pre, post)
        M.calls[#M.calls + 1] = { frame = "_G", method = "SecureHandlerWrapScript", args = { frame, script, header, pre, post }, combat = S.combat }
        -- Blizzard installs a restricted closure through the frame's own SetScript (instance override included)
        local closure
        closure = function(...)
            if M.xdepth > 0 then error("Cannot call restricted closure from insecure code") end
        end
        M.restricted[closure] = true
        frame:SetScript(script, closure)
        local fs = rawget(frame, "__s")
        if fs then fs.wraps = fs.wraps or {}; fs.wraps[script] = { pre = pre, post = post } end
    end)
    -- state drivers are recorded per frame (st(frame).stateDrivers[name] = condition) so snapshots can see them
    -- (Un)RegisterStateDriver on a secure frame is protected: in combat it is a violation, like SetAttribute.
    g("RegisterStateDriver", function(frame, name, cond)
        local s = type(frame) == "table" and rawget(frame, "__s")
        if s then
            if S.combat and (s.secure or s.protectedParent) then M.violations[#M.violations + 1] = { frame = s.name or tostring(frame), method = "RegisterStateDriver", args = { name, cond }, trace = debug.traceback("", 2) } end
            s.stateDrivers = s.stateDrivers or {}; s.stateDrivers[name] = cond
        end
    end)
    g("UnregisterStateDriver", function(frame, name)
        local s = type(frame) == "table" and rawget(frame, "__s")
        if s then
            if S.combat and (s.secure or s.protectedParent) then M.violations[#M.violations + 1] = { frame = s.name or tostring(frame), method = "UnregisterStateDriver", args = { name }, trace = debug.traceback("", 2) } end
            if s.stateDrivers then s.stateDrivers[name] = nil end
        end
    end)
    g("RegisterAttributeDriver", function() end); g("UnregisterAttributeDriver", function() end)
    g("SecureHandlerSetFrameRef", function() end)
    g("SecureButton_GetModifierPrefix", function()
        local p = ""
        if S.alt then p = p .. "alt-" end
        if S.ctrl then p = p .. "ctrl-" end
        if S.meta then p = p .. "meta-" end
        if S.shift then p = p .. "shift-" end
        return p
    end)

    -- units
    local function u(unit) return unitState(unit) end
    g("UnitExists", function(unit) if unit == "target" or unit == "mouseover" then return false end
        if unit:match("^party(%d)$") then return (tonumber(unit:match("%d")) <= (S.groupSize or 0)) and u(unit) ~= nil end
        return u(unit) ~= nil end)
    g("UnitName", function(unit) local x = u(unit); return x and x.name or nil, nil end)
    g("UnitNameUnmodified", function(unit) local x = u(unit); return x and x.name or nil, nil end)
    g("UnitFullName", function(unit) local x = u(unit); if x and S.secretNames then return M.newSecret(), nil end return x and x.name or nil, nil end)
    g("GetUnitName", function(unit) local x = u(unit); return x and x.name or nil end)
    g("UnitClass", function(unit) local x = u(unit); if not x then return nil end return CLASS_LOC[x.class], x.class, 1 end)
    g("UnitClassBase", function(unit) local x = u(unit); return x and x.class end)
    g("UnitHealth", function(unit) local x = u(unit); if not x then return 0 end return numOrSecret(S.dead[unit] and 0 or x.health) end)
    g("UnitHealthMax", function(unit) local x = u(unit); if not x then return 0 end return numOrSecret(x.maxHealth) end)
    g("UnitPower", function(unit) local x = u(unit); if not x then return 0 end return numOrSecret(x.power) end)
    g("UnitPowerMax", function(unit) local x = u(unit); if not x then return 0 end return numOrSecret(x.maxPower) end)
    g("UnitPowerType", function(unit) local x = u(unit); local t = x and x.powerType or 0
        return t, ({ [0] = "MANA", [1] = "RAGE", [2] = "FOCUS", [3] = "ENERGY" })[t] or "MANA" end)
    g("UnitGetIncomingHeals", function() return numOrSecret(0) end)
    g("UnitGetTotalAbsorbs", function() return numOrSecret(0) end)
    g("UnitGetTotalHealAbsorbs", function() return numOrSecret(0) end)
    g("UnitIsDeadOrGhost", function(unit) if S.secretAll then return M.newSecret() end return S.dead[unit] == true or (S.ghost and S.ghost[unit] == true) end)
    g("UnitIsDead", function(unit) if S.secretAll then return M.newSecret() end return S.dead[unit] == true end)
    g("UnitIsGhost", function(unit) if S.secretAll then return M.newSecret() end return S.ghost and S.ghost[unit] == true or false end)
    g("UnitIsConnected", function(unit) if S.secretAll then return M.newSecret() end return not S.offline[unit] end)
    g("UnitInRange", function(unit)
        if S.secretRange or S.secretAll then return M.newSecret(), true end
        return not S.outOfRange[unit], true
    end)
    g("UnitIsVisible", function(unit)
        if S.rangeError then error("UnitIsVisible unavailable") end
        if S.secretRange or S.secretAll then return M.newSecret() end
        return not (S.invisible and S.invisible[unit])
    end)
    -- S.unitAlias (set by M.setRaid) maps tokens that point at the same person: raidN -> "player", partyK -> raidN.
    -- S.secretUnitIsUnit makes every answer secret.
    local function canon(x)
        local alias = S.unitAlias
        if not alias then return x end
        for _ = 1, 3 do if alias[x] then x = alias[x] else break end end
        return x
    end
    g("UnitIsUnit", function(a, b)
        if (S.secretTarget or S.secretAll) and (a == "target" or b == "target") then return M.newSecret() end
        if S.secretUnitIsUnit then return M.newSecret() end
        if b == "target" then return S.target ~= nil and canon(a) == canon(S.target) end
        if a == "target" then return S.target ~= nil and canon(b) == canon(S.target) end
        return canon(a) == canon(b)
    end)
    g("UnitIsPlayer", function() return true end)
    g("UnitIsFriend", function() return true end)
    g("UnitIsEnemy", function() return false end)
    g("UnitCanAssist", function() return true end)
    g("UnitCanAttack", function() return false end)
    g("UnitIsCharmed", function() return false end)
    g("UnitIsGroupLeader", function(unit) return unit == "player" end)
    g("UnitIsGroupAssistant", function() return false end)
    g("UnitHasIncomingResurrection", function() return false end)
    -- S.guids = { [unit] = guid } overrides (a different player behind the same token); everything-secret returns secret GUIDs
    g("UnitGUID", function(unit)
        if S.secretAll then return M.newSecret() end
        if S.guids and S.guids[unit] ~= nil then return S.guids[unit] or nil end
        return u(unit) and ("Player-1-" .. unit) or nil
    end)
    g("UnitGroupRolesAssigned", function(unit) local x = u(unit); if S.secret or S.secretAll then return M.newSecret() end return x and x.role or "NONE" end)
    g("UnitThreatSituation", function(unit) if S.secretThreat or S.secretAll then return M.newSecret() end return (S.threat and S.threat[unit]) or 0 end)
    g("UnitIsAFK", function() return false end)
    g("UnitAffectingCombat", function(unit) if S.secret or S.secretAll then return M.newSecret() end return S.unitCombat and S.unitCombat[unit] == true or false end)
    g("UnitLevel", function() return 80 end)
    g("UnitRace", function() return "Human", "Human" end)
    g("UnitInParty", function(unit) return u(unit) ~= nil end)
    g("UnitInRaid", function() return nil end)
    g("UnitPhaseReason", function() return nil end)
    g("UnitInPhase", function() return true end)
    g("GetRaidTargetIndex", function() return nil end)
    g("GetNumGroupMembers", function()
        if S.secretGroup then return M.newSecret() end
        if S.inRaid then return S.raidSize or 0 end
        return S.inGroup and ((S.groupSize or 0) + 1) or 0
    end)
    g("GetNumSubgroupMembers", function() return S.groupSize or 0 end)
    g("IsInGroup", function() return S.inGroup end)
    g("IsInRaid", function() if S.secretGroup then return M.newSecret() end return S.inRaid end)
    -- S.instanceType ("none", "party", "raid", "pvp", "arena", "scenario") wins over the older S.inInstance flag;
    -- S.secretInstance makes both returns secret.
    g("IsInInstance", function()
        if S.secretInstance then return M.newSecret(), M.newSecret() end
        if S.instanceType then return S.instanceType ~= "none", S.instanceType end
        return S.inInstance and true or false, S.inInstance and "party" or "none"
    end)
    -- 12 returns like the real API: name, rank, subgroup, level, class, fileName, zone, online, isDead, role, isML, combatRole.
    -- S.secretRoster: subgroup and combatRole are secret; S.secretAll: name, subgroup, class, fileName and combatRole are secret;
    -- S.rosterError: the call raises. Out of a raid (or an unknown index) it returns nothing.
    g("GetRaidRosterInfo", function(i)
        if S.rosterError then error("GetRaidRosterInfo unavailable") end
        M.rosterCalls = (M.rosterCalls or 0) + 1
        if not S.inRaid or not S.raid then return nil end
        local r = S.raid[i]
        local x = r and S.units[r.unit]
        if not x then return nil end
        local name, subgroup, cls, file, role = x.name, r.subgroup, CLASS_LOC[x.class], x.class, x.role or "NONE"
        if S.secretRoster or S.secretAll then subgroup, role = M.newSecret(), M.newSecret() end
        if S.secretAll then name, cls, file = M.newSecret(), M.newSecret(), M.newSecret() end
        return name, r.rank or 0, subgroup, 80, cls, file, "Test Zone", not S.offline[r.unit], S.dead[r.unit] == true,
            nil, false, role
    end)
    g("GetSpecialization", function() return 1 end)
    g("GetSpecializationRole", function() return "HEALER" end)

    -- spells & auras
    S.spells, S.spellByName = {}, {}
    local function spellInfo(spell)
        local name = type(spell) == "string" and spell or ("Spell" .. tostring(spell))
        local id = type(spell) == "number" and spell or 1
        if type(spell) == "number" and S.spells[spell] then name = S.spells[spell] end
        if type(spell) == "string" then
            if not S.spellByName[spell] then
                S.nextSpellId = (S.nextSpellId or 100000) + 1
                S.spellByName[spell] = S.nextSpellId; S.spells[S.nextSpellId] = spell
            end
            id = S.spellByName[spell]
        end
        return { name = name, iconID = 134400, spellID = id, originalIconID = 134400,
            castTime = 0, minRange = 0, maxRange = 40 }
    end
    g("C_Spell", {
        GetSpellInfo = spellInfo,
        GetSpellTexture = function() return 134400 end,
        IsSpellPassive = function(id) return S.passives and S.passives[id] or false end,
        GetOverrideSpell = function(id) return id end,
        GetSpellName = function(s) return type(s) == "string" and s or ("Spell" .. tostring(s)) end,
        IsSpellInRange = function(spell, unit)
            if S.rangeError then error("IsSpellInRange unavailable") end
            if S.secretRange or S.secretAll then return M.newSecret() end
            if S.spellNil then return nil end
            if S.spellOut and unit and S.spellOut[unit] then return false end
            return true
        end,
        IsSpellUsable = function() return true, false end,
        GetSpellCooldown = function() return { startTime = 0, duration = 0, isEnabled = true, modRate = 1 } end,
        DoesSpellExist = function() return true end,
        IsSpellKnown = function() return true end,
        GetSpellLink = function(s) return "|cff71d5ff|Hspell:1|h[" .. tostring(s) .. "]|h|r" end,
    })
    g("C_SpellBook", {
        IsSpellKnown = function() return true end, IsSpellInSpellBook = function() return true end,
        IsSpellKnownOrInSpellBook = function() return true end, GetSpellBookItemName = function() return "Spell" end,
        FindSpellBookSlotForSpell = function() return nil end,
    })
    g("GetSpellInfo", function(s) local i = spellInfo(s); return i.name, nil, i.iconID, 0, 0, 40, i.spellID end)
    g("GetSpellTexture", function() return 134400 end)
    g("GetSpellLink", function(s) return tostring(s) end)
    g("IsPlayerSpell", function() return true end)
    g("IsSpellKnown", function() return true end)
    g("IsUsableSpell", function() return true, false end)
    g("IsSpellInRange", function() return 1 end)
    g("GetMacroInfo", function() return nil end)
    g("GetMacroBody", function() return nil end)
    local function auraMatches(a, filter)
        filter = filter or ""
        local harmful = a.isHarmful == true
        local ok = true
        if filter:find("HARMFUL", 1, true) then ok = harmful
        elseif filter:find("HELPFUL", 1, true) then ok = not harmful end
        if ok and filter:find("RAID_PLAYER_DISPELLABLE", 1, true) then ok = a.dispelName ~= nil end
        if ok and filter:find("|PLAYER", 1, true) then ok = a.sourceUnit == "player" end
        return ok
    end
    local function checkFilter(filter)
        if S.failAll or S.failEnumerate then error("auras unavailable") end
        if S.rejectFilters and tostring(filter):find("|", 1, true) then error("Usage: invalid aura filter " .. tostring(filter)) end
    end
    g("C_UnitAuras", {
        GetAuraDataByIndex = function(unit, index, filter)
            if S.failAll or S.failEnumerate then error("auras unavailable") end
            local n = 0
            for _, a in ipairs(S.auras[unit] or {}) do
                if auraMatches(a, filter) then
                    n = n + 1
                    if n == index then return M.wrapAura(a) end
                end
            end
            return nil
        end,
        GetUnitAuras = function(unit, filter)
            checkFilter(filter)
            if S.secretTable then return M.newSecretTable() end
            local out = {}
            for _, a in ipairs(S.auras[unit] or {}) do
                if auraMatches(a, filter) then out[#out + 1] = M.wrapAura(a) end
            end
            return out
        end,
        GetUnitAuraInstanceIDs = function(unit, filter)
            checkFilter(filter)
            if S.noInstanceIDs then error("not supported") end
            local out = {}
            for _, a in ipairs(S.auras[unit] or {}) do
                if auraMatches(a, filter) then out[#out + 1] = a.auraInstanceID or a.spellId end
            end
            return out
        end,
        GetAuraDataByAuraInstanceID = function(unit, id)
            if S.failAll then error("auras unavailable") end
            -- S.goneIDs = { [id] = true }: these auras no longer resolve by ID even if an enumeration still lists them (stale list)
            if S.goneIDs and S.goneIDs[id] then return nil end
            for _, a in ipairs(S.auras[unit] or {}) do
                if (a.auraInstanceID or a.spellId) == id then return M.wrapAura(a) end
            end
            return nil
        end,
        GetAuraDataBySpellName = function(unit, name)
            for _, a in ipairs(S.auras[unit] or {}) do if a.name == name then return M.wrapAura(a) end end
        end,
        GetPlayerAuraBySpellID = function() return nil end,
        GetAuraDuration = function(unit, id) if S.durationObjects then return { duration = true } end return nil end,
        GetAuraApplicationDisplayCount = function() if S.secret or S.secretAll then return M.newSecret() end return "" end,
        GetAuraDispelTypeColor = function() return nil end,
        -- true when the aura does NOT pass the filter; "HARMFUL" / "HELPFUL" are answered from the aura data. S.failClassify makes it raise.
        IsAuraFilteredOutByInstanceID = function(unit, id, filter)
            if S.failClassify or S.failAll then error("classification unavailable") end
            for _, a in ipairs(S.auras[unit] or {}) do
                if (a.auraInstanceID or a.spellId) == id then
                    local harmful = a.isHarmful
                    if harmful == nil then harmful = not a.isHelpful end
                    if tostring(filter):find("HARMFUL", 1, true) then return not harmful end
                    if tostring(filter):find("HELPFUL", 1, true) then return harmful and true or false end
                    return false
                end
            end
            return false
        end,
        ForEachAura = function(unit, filter, max, cb)
            for _, a in ipairs(S.auras[unit] or {}) do if auraMatches(a, filter) and cb(M.wrapAura(a)) then break end end
        end,
    })
    g("UnitAura", function(unit, i) local a = (S.auras[unit] or {})[i]; if not a then return nil end
        return a.name, a.icon, a.applications, a.dispelName, a.duration, a.expirationTime, nil, nil, nil, a.spellId end)
    g("AuraUtil", { ForEachAura = function(unit, filter, max, cb)
        for _, a in ipairs(S.auras[unit] or {}) do if cb(a.name, a.icon, a.applications, a.dispelName, a.duration, a.expirationTime, nil, nil, nil, a.spellId) then break end end
    end, FindAuraByName = function() return nil end })
    g("C_Timer", {
        After = function(delay, fn) M.timers[#M.timers + 1] = { fn = fn, delay = delay, due = M.state.now + (tonumber(delay) or 0) } end,
        NewTimer = function(_, fn) local t = { fn = fn, Cancel = function(self) self.cancelled = true end }; M.timers[#M.timers + 1] = t; return t end,
        NewTicker = function(_, fn) local t = { fn = fn, Cancel = function(self) self.cancelled = true end }; M.tickers[#M.tickers + 1] = t; return t end,
    })

    -- UI constants / tables
    local colors = {}
    for i, c in ipairs(CLASSES) do
        colors[c] = { r = 0.1 * (i % 10), g = 0.5, b = 0.9, colorStr = "ff80ff80",
            GetRGB = function(s) return s.r, s.g, s.b end, WrapTextInColorCode = function(_, t) return t end }
    end
    g("RAID_CLASS_COLORS", colors)
    g("CUSTOM_CLASS_COLORS", nil)
    g("CLASS_ICON_TCOORDS", setmetatable({}, { __index = function() return { 0, 0.25, 0, 0.25 } end }))
    g("LOCALIZED_CLASS_NAMES_MALE", CLASS_LOC); g("LOCALIZED_CLASS_NAMES_FEMALE", CLASS_LOC)
    local pbc = { MANA = { r = 0, g = 0, b = 1 }, RAGE = { r = 1, g = 0, b = 0 }, FOCUS = { r = 1, g = 0.5, b = 0.25 },
        ENERGY = { r = 1, g = 1, b = 0 } }
    pbc[0], pbc[1], pbc[2], pbc[3] = pbc.MANA, pbc.RAGE, pbc.FOCUS, pbc.ENERGY
    g("PowerBarColor", setmetatable(pbc, { __index = function() return { r = 0.5, g = 0.5, b = 0.5 } end }))
    g("STANDARD_TEXT_FONT", "Fonts\\FRIZQT__.TTF"); g("UNKNOWN", "Unknown")
    g("NORMAL_FONT_COLOR", { r = 1, g = 0.82, b = 0, GetRGB = function() return 1, 0.82, 0 end })
    g("HIGHLIGHT_FONT_COLOR", { r = 1, g = 1, b = 1, GetRGB = function() return 1, 1, 1 end })
    g("RED_FONT_COLOR", { r = 1, g = 0.1, b = 0.1, GetRGB = function() return 1, 0.1, 0.1 end })
    g("GREEN_FONT_COLOR", { r = 0.1, g = 1, b = 0.1, GetRGB = function() return 0.1, 1, 0.1 end })
    g("DEBUFF_TYPE_MAGIC_COLOR", { r = 0.2, g = 0.6, b = 1 })
    g("DebuffTypeColor", setmetatable({}, { __index = function() return { r = 0.8, g = 0, b = 0 } end }))
    g("UISpecialFrames", {})
    g("UIParent", newFrame("Frame", "UIParent"))
    g("WorldFrame", newFrame("Frame", "WorldFrame"))
    g("Minimap", newFrame("Frame", "Minimap"))
    g("MinimapCluster", newFrame("Frame", "MinimapCluster"))
    g("GameTooltip", newFrame("GameTooltip", "GameTooltip"))
    g("DEFAULT_CHAT_FRAME", newFrame("Frame", "DEFAULT_CHAT_FRAME"))
    _G.DEFAULT_CHAT_FRAME.AddMessage = function(_, msg) M.printed[#M.printed + 1] = tostring(msg) end
    g("ChatFrame1", _G.DEFAULT_CHAT_FRAME)
    g("PartyFrame", newFrame("Frame", "PartyFrame"))
    g("CompactPartyFrame", newFrame("Frame", "CompactPartyFrame"))
    g("CompactRaidFrameContainer", newFrame("Frame", "CompactRaidFrameContainer"))
    g("CompactRaidFrameManager", newFrame("Frame", "CompactRaidFrameManager"))
    g("PlayerFrame", newFrame("Frame", "PlayerFrame"))
    g("TargetFrame", newFrame("Frame", "TargetFrame"))
    g("FocusFrame", newFrame("Frame", "FocusFrame"))
    g("GameFontNormal", newFrame("Font", "GameFontNormal"))
    g("GameFontHighlight", newFrame("Font", "GameFontHighlight"))
    g("GameFontNormalSmall", newFrame("Font", "GameFontNormalSmall"))
    g("GameFontHighlightSmall", newFrame("Font", "GameFontHighlightSmall"))
    g("SystemFont_Shadow_Small", newFrame("Font", "SystemFont_Shadow_Small"))
    g("CreateFrame", function(kind, name, parent, template)
        local f = newFrame(kind, name, parent, template)
        if S.combat then M.createdInCombat[#M.createdInCombat + 1] = { kind = kind, name = name } end
        if S.combat and rawget(f, "__s").secure then
            M.secureCreatedInCombat = (M.secureCreatedInCombat or 0) + 1
        end
        return f
    end)
    g("CreateFont", function(name) return newFrame("Font", name) end)
    g("Settings", {
        RegisterCanvasLayoutCategory = function(panel, name) return { ID = name, name = name, panel = panel } end,
        RegisterCanvasLayoutSubcategory = function(cat, panel, name) return { ID = name, name = name } end,
        RegisterAddOnCategory = function() end, OpenToCategory = function() end,
        RegisterVerticalLayoutCategory = function(name) return { ID = name, name = name } end,
    })
    g("SettingsPanel", newFrame("Frame", "SettingsPanel"))
    g("InterfaceOptionsFrame_OpenToCategory", function() end)
    g("InterfaceOptions_AddCategory", function() end)
    g("MenuUtil", { CreateContextMenu = function(anchor, generator)
        local menu = { anchor = anchor, entries = {} }
        local root
        root = setmetatable({}, { __index = function(_, k)
            if k == "CreateButton" or k == "CreateCheckbox" or k == "CreateRadio" then
                return function(_, text, cb) menu.entries[#menu.entries + 1] = { text = text, cb = cb }; return root end
            end
            return function() return root end
        end })
        M.menu = menu
        generator(anchor, root)
    end })
    g("ToggleDropDownMenu", function() end); g("UIDropDownMenu_Initialize", function() end)
    g("UIDropDownMenu_AddButton", function() end); g("UIDropDownMenu_SetText", function() end)
    g("UIDropDownMenu_SetWidth", function() end); g("UIDropDownMenu_SetSelectedValue", function() end)
    g("UIDropDownMenu_CreateInfo", function() return {} end); g("CloseDropDownMenus", function() end)
    g("ToggleDropDownMenu", function() end)
    g("StaticPopupDialogs", {}); g("StaticPopup_Show", function() end)
    g("SlashCmdList", {})
    g("HideUIPanel", function() end); g("ShowUIPanel", function() end)
    g("C_PartyInfo", { LeaveParty = function() end })
    g("C_CVar", { GetCVar = function() return "0" end, SetCVar = function() end })
    g("GetCVar", function() return "0" end); g("SetCVar", function() end)
    g("C_ChatInfo", {}); g("C_Item", {})
    g("C_Texture", { GetAtlasInfo = function(name) if S.atlasKnown then return { width = 16, height = 16, file = 1 } end return nil end })
    g("GetNormalizedRealmName", function() return "TestRealm" end)
    g("GetRealmName", function() return "TestRealm" end)
    g("GetRealZoneText", function() if S.zoneError then error("zone unavailable") end return S.zoneText or "Test Zone" end)
    S.positions = {
        player = { 0.5, 0.5 }, party1 = { 0.51, 0.5 }, party2 = { 0.5, 0.52 }, party3 = { 0.7, 0.7 },
    }
    g("C_Map", {
        GetBestMapForUnit = function(unit) if S.noPositions then return nil end return S.mapID or 1 end,
        GetPlayerMapPosition = function(mapID, unit)
            local p = S.positions[unit]
            if S.noPositions or not p then return nil end
            local x, y = p[1], p[2]
            if S.secret then x, y = M.newSecret(), M.newSecret() end
            return { x = x, y = y, GetXY = function() return x, y end }
        end,
        GetMapWorldSize = function() return 1000, 1000 end,
        GetMapInfo = function() return { name = "Test Zone", mapID = 1 } end,
        GetWorldPosFromMapPos = function(_, pos) return 1, { x = pos.x * 1000, y = pos.y * 1000 } end,
    })
    g("UnitPosition", function(unit)
        local p = S.positions[unit]
        if S.noPositions or not p then return nil end
        local y, x = p[2] * 1000, p[1] * 1000
        if S.secret or S.secretPos then return M.newSecret(), M.newSecret(), 0, 1 end
        return y, x, 0, (S.otherInstance and S.otherInstance[unit]) and 2 or 1
    end)
    g("GetPlayerFacing", function() return S.facing or 0 end)
    g("ShowUIPanel", function() end)
    g("EventRegistry", { RegisterCallback = function() end, TriggerEvent = function() end })
    g("TooltipDataProcessor", { AddTooltipPostCall = function() end })
    g("FONT_COLOR_CODE_CLOSE", "|r")
    -- unit watch is recorded per frame (st(frame).unitWatch = true / false); visibility itself is not simulated
    -- (Un)RegisterUnitWatch is protected: on a secure frame in combat it is a violation (the real client blocks it).
    -- M.applyUnitWatch() plays the game's unit watch: watched frames are shown when their unit exists.
    local function unitWatch(method, on)
        return function(frame)
            local s = type(frame) == "table" and rawget(frame, "__s")
            if not s then return end
            M.unitWatchCalls = (M.unitWatchCalls or 0) + 1
            if S.combat and s.secure then M.violations[#M.violations + 1] = { frame = s.name or tostring(frame), method = method, args = {}, trace = debug.traceback("", 2) } end
            s.unitWatch = on
        end
    end
    g("RegisterUnitWatch", unitWatch("RegisterUnitWatch", true))
    g("UnregisterUnitWatch", unitWatch("UnregisterUnitWatch", false))
    g("SecureCmdOptionParse", function(s) return s end)
    g("GetMouseFoci", function() return {} end); g("GetMouseFocus", function() return nil end)
    g("C_ClassColor", { GetClassColor = function() return colors.PALADIN end })
    g("GetClassColor", function(c) local x = colors[c] or colors.PALADIN; return x.r, x.g, x.b, "ff80ff80" end)
    g("InterfaceOptionsFrame", newFrame("Frame", "InterfaceOptionsFrame"))
    g("LibStub", nil)
    g("Enum", { SpellDispelType = { None = 0, Magic = 1, Curse = 2, Disease = 3, Poison = 4, Bleed = 11 },
        LuaCurveType = { Linear = 0, Cosine = 1, Step = 2 }, UnitAuraSortRule = { Default = 0, Expiration = 1 },
        PowerType = { Mana = 0, Rage = 1 }, SpellBookSpellBank = { Player = 0, Pet = 1 }, SpellBookItemType = { None = 0, Spell = 1, FutureSpell = 2, PetAction = 3, Flyout = 4 } })
    g("CurveConstants", { ScaleTo100 = { scale100 = true }, Reverse = {}, ScaleTo100Reverse = {} })
    -- Colour curves record their type and points (curve.points = { {x, colour} }). A Step curve evaluates like the
    -- client: the point with the largest x <= the input (x = 1 full health -> the point at 1). Other types keep the
    -- old mock answer (the first point). M.curves lists every colour curve created.
    M.curves, M.floatCurves = {}, {}
    g("C_CurveUtil", { CreateColorCurve = function()
        local pts = {}
        local curve = { points = pts }
        curve.SetType = function(_, t) curve.curveType = t end
        curve.AddPoint = function(_, x, c) pts[#pts + 1] = { x, c } end
        curve.Evaluate = function(_, x)
            if curve.curveType == 2 and type(x) == "number" then   -- Enum.LuaCurveType.Step
                local best
                for _, p in ipairs(pts) do if p[1] <= x + 1e-9 and (not best or p[1] >= best[1]) then best = p end end
                best = best or pts[1]
                return best and best[2] or colors.PALADIN
            end
            return pts[1] and pts[1][2] or colors.PALADIN
        end
        M.curves[#M.curves + 1] = curve
        return curve
    end, CreateCurve = function() return M.newFloatCurve() end })
    g("UnitHealthPercent", function(unit, usePredicted, curve)
        if S.secret or S.secretAll then
            if type(curve) == "table" and curve.isFloat then return M.newSecret() end
            if type(curve) == "table" and curve.Evaluate then
                return { GetRGB = function() return M.newSecret(), M.newSecret(), M.newSecret() end,
                    GetRGBA = function() return M.newSecret(), M.newSecret(), M.newSecret(), M.newSecret() end }
            end
            return M.newSecret()
        end
        local x = unitState(unit)
        local hp = x and (S.dead[unit] and 0 or x.health) or 0
        local frac = (x and x.maxHealth > 0) and hp / x.maxHealth or 0
        if type(curve) == "table" and curve.Evaluate then return curve:Evaluate(frac) end
        return frac * 100
    end)
    g("AbbreviateNumbers", function(v) if M.isSecret(v) then return M.newSecret() end return string.format("%.1fk", (tonumber(v) or 0) / 1000) end)
    -- like the client: max - current (0 at full health; the whole max when dead)
    g("UnitHealthMissing", function(unit)
        local x = unitState(unit)
        if not x then return numOrSecret(0) end
        return numOrSecret(x.maxHealth - (S.dead[unit] and 0 or x.health))
    end)
    -- The calculator remembers the unit of the last UnitGetDetailedHealPrediction(unit, nil, calc): GetMissingHealth is
    -- max - hp of that unit (whole max when dead), every other Get* (incoming heals, absorbs) answers 0.
    g("CreateUnitHealPredictionCalculator", function()
        local c = {}
        local fn = function() return numOrSecret(0) end
        c.GetMissingHealth = function(self)
            local x = unitState(rawget(self, "__unit"))
            if not x then return numOrSecret(0) end
            return numOrSecret(x.maxHealth - (S.dead[rawget(self, "__unit")] and 0 or x.health))
        end
        return setmetatable(c, { __index = function(_, k) if k:sub(1, 3) == "Get" then return fn end return function() end end })
    end)
    g("UnitGetDetailedHealPrediction", function(unit, _, calc) if type(calc) == "table" then rawset(calc, "__unit", unit) end end)
    g("PickupSpell", function() end); g("ToggleFrame", function() end); g("IsIndoors", function() return false end)
    g("PlayerSpellsUtil", { OpenToSpellBookTab = function() end, ToggleSpellBookFrame = function() end })
    g("ToggleSpellBook", function() end)
    g("SpellBookFrame", newFrame("Frame", "SpellBookFrame"))
    local cp = newFrame("Frame", "ColorPickerFrame")
    cp.GetColorRGB = function() local c = M.pickColor or { 1, 1, 1 }; return c[1], c[2], c[3] end
    cp.SetupColorPickerAndShow = function(_, info) M.colorPicker = info end
    g("ColorPickerFrame", cp)
    for i = 1, 4 do g("PartyMemberFrame" .. i, newFrame("Frame", "PartyMemberFrame" .. i)) end
    g("print", function(...)
        local t = {}
        for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
        M.printed[#M.printed + 1] = table.concat(t, " ")
    end)
end

function M.wrapAura(a)
    local out = {}
    for k, v in pairs(a) do
        if (M.state.secret or M.state.secretAll) and type(v) ~= "boolean" and k ~= "auraInstanceID" then out[k] = M.newSecret() else out[k] = v end
    end
    if a.__badIcon then
        out.icon = nil
        setmetatable(out, { __index = function(_, k) if k == "icon" then error("simulated render failure (icon)") end end })
    end
    out.isHelpful = (a.isHelpful ~= false) and not a.isHarmful
    out.auraInstanceID = a.auraInstanceID or (a.spellId or 1)
    return out
end

local IGNORE_UNDEFINED = { HealerForeverDB = true, HealerForeverCharDB = true, HealerForever = true }

-- Every aura read API call is counted (M.auraCalls: total, in combat, by name) so tests can prove "the addon reads nothing in combat".
function M.resetAuraCalls() M.auraCalls = { total = 0, combat = 0, byName = {}, combatByName = {} } end
local function countAuraFn(label, fn)
    return function(...)
        local c = M.auraCalls
        c.total = c.total + 1
        c.byName[label] = (c.byName[label] or 0) + 1
        if M.state.combat then c.combat = c.combat + 1; c.combatByName[label] = (c.combatByName[label] or 0) + 1 end
        return fn(...)
    end
end
M.countAuraFn = countAuraFn
local function instrumentAuraApis()
    M.resetAuraCalls()
    local api = rawget(_G, "C_UnitAuras")
    if type(api) == "table" then for k, fn in pairs(api) do if type(fn) == "function" then api[k] = countAuraFn("C_UnitAuras." .. k, fn) end end end
    for _, name in ipairs({ "UnitAura", "UnitBuff", "UnitDebuff", "GetAuraDataByIndex" }) do
        local fn = rawget(_G, name)
        if type(fn) == "function" then M.setGlobal(name, countAuraFn(name, fn)) end
    end
    local au = rawget(_G, "AuraUtil")
    if type(au) == "table" then for k, fn in pairs(au) do if type(fn) == "function" then au[k] = countAuraFn("AuraUtil." .. k, fn) end end end
end

function M.install()
    M.uninstall()
    M.resetState()
    origMeta = getmetatable(_G)
    buildGlobals()
    instrumentAuraApis()
    setmetatable(_G, { __index = function(_, k)
        if type(k) == "string" and not IGNORE_UNDEFINED[k] and not k:match("^SLASH_") then
            M.undefined[k] = (M.undefined[k] or 0) + 1
        end
        return nil
    end })
    return M
end

function M.uninstall()
    setmetatable(_G, origMeta)
    origMeta = nil
    for k in pairs(installed) do rawset(_G, k, realG[k]) end
    installed, realG = {}, {}
    -- globals the addon itself created
    rawset(_G, "HealerForeverDB", nil)
    for k in pairs(_G) do
        if type(k) == "string" and (k:match("^SLASH_") or k:match("^HealerForever") or k:match("^HF_[A-Z]") and k ~= "HF_ROOT" and k ~= "HF_TESTS") then
            rawset(_G, k, nil)
        end
    end
end

function M.pickMenu(text)
    for _, e in ipairs(M.menu and M.menu.entries or {}) do
        if e.text == text then e.cb(); return true end
    end
    return false
end

function M.undefinedList()
    local t = {}
    for k in pairs(M.undefined) do t[#t + 1] = k end
    table.sort(t)
    return t
end

return M
