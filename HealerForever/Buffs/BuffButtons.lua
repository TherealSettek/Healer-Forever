local ADDON_NAME, ns = ...

-- Missing-buff action buttons. Evaluated out of combat only: in combat the buttons are hidden by
-- a secure visibility state driver ("[combat] hide; show"), and attributes are frozen.
local BB = { buttons = {}, extraButtons = {} }
ns.BuffButtons = BB

local Presets, Classes = ns.Presets, ns.Classes
local issecret = ns.issecret
local WHITE = "Interface\\Buttons\\WHITE8X8"
local SIZE = 24

local function createButton(member, index, kind)
    local isExtra = kind == "extra"
    local b = ns.NewFrame("Button", (isExtra and "HealerForeverExtra" or "HealerForeverBuff") .. index, member,
        "SecureActionButtonTemplate")
    b.kind = kind or "blessing"
    b:SetSize(SIZE, SIZE)
    -- sits fully ABOVE the bar's top-right corner (never over the bar), so it can never cover part of a unit
    -- frame that is being clicked (e.g. the player's own bar at the start of a fight)
    b:SetPoint("BOTTOMRIGHT", member, "TOPRIGHT", isExtra and -(SIZE + 2) or 0, 2)
    b:SetFrameLevel(member:GetFrameLevel() + 20)
    b:RegisterForClicks("AnyDown", "AnyUp")
    b:SetAttribute("unit", member.unit)
    b.unit = member.unit

    b.border = b:CreateTexture(nil, "BACKGROUND")
    b.border:SetAllPoints()
    b.border:SetTexture(WHITE)
    if isExtra then b.border:SetVertexColor(0.4, 0.8, 1, 1) else b.border:SetVertexColor(1, 0.82, 0, 1) end
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 2, -2)
    b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- "+N" style badge: how many buffs are missing on this member (shown when more than one)
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    b.count:SetPoint("BOTTOMRIGHT", 3, -2)
    b.count:SetText("")

    b.pulse = b.border:CreateAnimationGroup()
    b.pulse:SetLooping("BOUNCE")
    local anim = b.pulse:CreateAnimation("Alpha")
    anim:SetFromAlpha(1)
    anim:SetToAlpha(0.35)
    anim:SetDuration(0.6)

    ns.SecureHook(b, "OnEnter", function(self)
        if self.kind == "extra" then
            if not self.extraSpell or not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.unknownSpell then
                GameTooltip:AddLine("You don't know " .. self.unknownSpell .. " yet", 1, 0.3, 0.3)
            end
            if self.unreachable then GameTooltip:AddLine("Out of range", 1, 0.3, 0.3) end
            GameTooltip:AddLine("Missing: " .. self.extraSpell .. " (" .. (self.reason or "Role buff") .. ")", 1, 0.82, 0)
            GameTooltip:Show()
            return
        end
        local def = self.buffKey and Classes.BUFFS[self.buffKey]
        if not def or not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.unknownSpell then
            GameTooltip:AddLine("Not in your spellbook: " .. self.unknownSpell, 1, 0.3, 0.3)
        end
        if self.unreachable then GameTooltip:AddLine("Out of range", 1, 0.3, 0.3) end
        GameTooltip:AddLine("Missing: " .. def.name .. (self.reason and (" (" .. self.reason .. ")") or ""), 1, 0.82, 0)
        if (self.missingCount or 1) > 1 and self.missingNames then
            GameTooltip:AddLine("Also missing: " .. table.concat(self.missingNames, ", "), 1, 0.6, 0.3)
        end
        if not self.unknownSpell then
            GameTooltip:AddLine("Left-click: " .. def.name, 1, 1, 1)
            if def.groupSpell then GameTooltip:AddLine("Right-click: " .. def.groupSpell, 1, 1, 1) end
        end
        GameTooltip:Show()
    end)
    ns.SecureHook(b, "OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    RegisterStateDriver(b, "visibility", "[combat] hide; show")
    b:SetAlpha(0)
    b:EnableMouse(false)
    return b
end

local function reasonText(class, role, isSelf)
    if isSelf then return "Self" end
    local name = Classes.NAMES[class] or class
    if role and Classes.ROLE_LABELS[role] then
        return name .. " \194\183 " .. Classes.ROLE_LABELS[role]
    end
    return name
end

-- Is the unit visible and in range for the spell? Out of combat only; every call is pcall'd and secret-guarded.
-- If a check cannot be made the unit counts as reachable: the strict macros below still never self-cast.
local function reachable(unit, spell)
    if unit == "player" then return true end
    local ok, result = pcall(function()
        if UnitIsVisible then
            local visible = UnitIsVisible(unit)
            if not issecret(visible) and not visible then return false end
        end
        if UnitInRange then
            local inRange = UnitInRange(unit)
            if not issecret(inRange) and inRange == false then return false end
        end
        if spell and C_Spell and C_Spell.IsSpellInRange then
            local r = C_Spell.IsSpellInRange(spell, unit)
            if not issecret(r) and r == false then return false end
        end
        return true
    end)
    if not ok then return true end
    return result
end
BB.Reachable = reachable

local function castMacro(unit, spell)
    return ns.Bindings.BuildMacroText(unit, spell, nil)
end

local function disarm(b)
    b:SetAttribute("type1", nil)
    b:SetAttribute("macrotext1", nil)
    b:SetAttribute("type2", nil)
    b:SetAttribute("macrotext2", nil)
    b.castSpell = nil
end

-- Spell texture from the spellbook, or the catalog's fallback icon when the spell is unknown.
function BB.IconFor(spell, def)
    local tex = C_Spell and C_Spell.GetSpellTexture and spell and C_Spell.GetSpellTexture(spell)
    return tex or (def and def.icon) or "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- One missing buff of a member, resolved against the spellbook and range.
-- Returns { key, def, single, greater, state = "ready" | "unreachable" | "unknown" }.
local function armEntry(unit, key)
    local def = Classes.BUFFS[key]
    if not def then return nil end
    local single = ns.SpellKnown(def.name) and def.name or nil
    local group = def.groupSpell and ns.SpellKnown(def.groupSpell) and def.groupSpell or nil
    local entry = { key = key, def = def, single = single, greater = group }
    if not single and not group then
        entry.state = "unknown"
    elseif not reachable(unit, single or group) then
        entry.state = "unreachable"
    else
        entry.state = "ready"
    end
    return entry
end
BB.ArmEntry = armEntry

-- Shows the member's next missing buff (entry) with a count badge when several are missing.
-- state: nil (hidden), "ready" (castable), "unreachable" (dimmed, disarmed), "unknown" (greyed: not in the spellbook)
local function setActive(b, entry, count, reason, missingNames)
    b.reason = reason
    b.unknownSpell = nil
    b.unreachable = nil
    b.missingCount = count or 0
    b.missingNames = missingNames
    if not entry then
        b.buffKey = nil
        disarm(b)
        b.pulse:Stop()
        b.count:SetText("")
        b:SetAlpha(0)
        b:EnableMouse(false)
        return nil
    end
    local def = entry.def
    b.buffKey = entry.key
    b:SetFrameLevel(b:GetParent():GetFrameLevel() + 20)
    b.count:SetText((count or 0) > 1 and tostring(count) or "")
    if entry.state == "unknown" then
        -- never hide silently: show it greyed out, clicking does nothing
        b.unknownSpell = def.name
        disarm(b)
        b.icon:SetTexture(BB.IconFor(def.name, def))
        b.icon:SetDesaturated(true)
        b.pulse:Stop()
        b:SetAlpha(0.8)
        b:EnableMouse(true)
        return "unknown"
    end
    local spell = entry.single or entry.greater
    b.icon:SetTexture(BB.IconFor(spell, def))
    if entry.state == "unreachable" then
        -- not visible / out of range: dimmed and DISARMED, a click or keybind does nothing
        b.unreachable = true
        disarm(b)
        b.icon:SetDesaturated(true)
        b.pulse:Stop()
        b:SetAlpha(0.7)
        b:EnableMouse(true)
        return "unreachable"
    end
    b.icon:SetDesaturated(false)
    b.castSpell = spell
    b:SetAttribute("type1", "macro")
    b:SetAttribute("macrotext1", castMacro(b.unit, spell))
    b:SetAttribute("type2", "macro")
    b:SetAttribute("macrotext2", castMacro(b.unit, entry.greater or spell))
    b:SetAlpha(1)
    b:EnableMouse(true)
    if not b.pulse:IsPlaying() then b.pulse:Play() end
    return "ready"
end

local ROLE_TAG = { TANK = "Tank buff", HEALER = "Healer buff", DAMAGER = "DPS buff" }

-- Reads everything needed about a unit; returns info or nil plus the reason it is skipped.
local function gather(unit, cache)
    if cache and cache[unit] ~= nil then
        local c = cache[unit]
        if c == false then return nil, "skipped" end
        return c
    end
    local function fail(why)
        if cache then cache[unit] = false end
        return nil, why
    end
    if not ns.Exists(unit) then return fail("unit does not exist") end
    if not ns.InGroup() and not ns.db.buffs.showSolo then return fail("solo and 'show while solo' is off") end
    local dead, connected = UnitIsDeadOrGhost(unit), UnitIsConnected(unit)
    if issecret(dead) or issecret(connected) then return fail("dead/connected state is secret") end
    if dead or not connected then return fail(dead and "unit is dead" or "unit is offline") end
    local _, token = UnitClass(unit)
    if issecret(token) or not token then return fail("class unreadable") end
    local auras, ok = ns.Auras.Snapshot(unit)
    if not ok then return fail("auras unreadable (combat or secret values): not treated as buffed") end
    local override = ns.Roles.GetOverride(unit)
    local role = override or ns.Roles.GetDetected(unit)
    local info = {
        unit = unit, name = UnitName(unit), class = token, auras = auras, role = role,
        roleSource = override and "override" or (role and "detected" or "none"), isSelf = unit == "player",
    }
    if cache then cache[unit] = info end
    return info
end
BB.Gather = gather

-- Missing party buffs for one unit, in catalog order. Only buffs the player's class can cast are considered.
-- Returns missing (array of keys), reason and a diagnostics table. percentOverride (raid markers) replaces the
-- rebuff % from the buff settings; the party buttons pass nil.
local function evaluate(unit, cache, percentOverride)
    local diag = { unit = unit }
    local class = ns.PlayerClass()
    local castable = {}
    for _, key in ipairs(class and Classes.CatalogBuffs(class) or {}) do castable[key] = true end
    if next(castable) == nil then
        diag.hidden = "your class has no party buffs to assign"
        return {}, nil, diag
    end
    local info, why = gather(unit, cache)
    if not info then
        diag.hidden = why
        return {}, nil, diag
    end
    diag.name, diag.class, diag.role, diag.roleSource, diag.isSelf = info.name, info.class, info.role,
        info.roleSource, info.isSelf
    diag.auraCount = #info.auras
    local preset = ns.db.presets[ns.db.activePreset]
    local threshold = ns.db.buffs.warn and ns.db.buffs.threshold or 0
    -- class buffs: rebuff when less than rebuffPercent% of the buff's duration is left (0 = only when gone)
    local percent = ns.db.buffs.warn and ns.db.buffs.rebuffPercent or 0
    if percentOverride ~= nil then percent = percentOverride end
    local assigned = {}
    for _, key in ipairs(Presets.CellBuffs(preset, info.class, info.role, info.isSelf)) do
        if castable[key] then assigned[#assigned + 1] = key end
    end
    diag.resolved = assigned
    diag.percent = percent
    if #assigned == 0 then
        diag.hidden = "preset assigns none of your buffs to this class/role"
        return {}, nil, diag
    end
    local now = GetTime()
    local missing = {}
    local wanted = {}
    for _, key in ipairs(assigned) do wanted[key] = true end
    diag.report = {}
    for _, item in ipairs(Presets.BuffReport(info.class, info.auras, preset, now, Classes.BUFFS, threshold,
        info.role, info.isSelf, percent)) do
        if wanted[item.key] then
            diag.report[#diag.report + 1] = item
            if item.missing then missing[#missing + 1] = item.key end
        end
    end
    if #missing == 0 then
        diag.hidden = "has all assigned buffs"
        return {}, nil, diag
    end
    return missing, reasonText(info.class, info.role, info.isSelf), diag
end
BB.EvaluateUnit = evaluate

local function extraMatches(entry, aura)
    return (entry.spellId and aura.spellId == entry.spellId) or (entry.spell and aura.name == entry.spell)
end

-- Role buffs: returns result[unit] = { entry =, role =, reason = } (one extra per unit button; a "single"
-- entry is only offered on the first unit missing it, and not at all while our aura sits on another unit).
local function evaluateExtras(cache)
    local result = {}
    local preset = ns.db.presets[ns.db.activePreset]
    local threshold = ns.db.buffs.warn and ns.db.buffs.threshold or 0
    local now = GetTime()
    for _, entry in ipairs(preset and preset.extras or {}) do
        local mineOn = {}
        for unit, info in pairs(cache) do
            if info then
                for _, aura in ipairs(info.auras) do
                    if aura.isMine and extraMatches(entry, aura) then mineOn[unit] = true end
                end
            end
        end
        local claimed = false
        for _, unit in ipairs(ns.UnitFrames.MEMBER_UNITS) do
            local info = cache[unit]
            if info and not result[unit] and not (entry.single and claimed) then
                for _, e in ipairs(Presets.ResolveExtras(preset, info.role, info.isSelf)) do
                    if e == entry then
                        local elsewhere = false
                        for other in pairs(mineOn) do
                            if other ~= unit then elsewhere = true end
                        end
                        if Presets.GetMissingExtra(entry, info.auras, now, threshold, elsewhere) then
                            local tag = info.isSelf and "Self buff" or (ROLE_TAG[info.role] or "Role buff")
                            result[unit] = { entry = entry, role = info.role, reason = tag, isSelf = info.isSelf }
                            claimed = true
                        end
                    end
                end
            end
        end
    end
    return result
end

local function setExtra(b, res)
    if not res then
        b.extraSpell, b.unknownSpell, b.reason, b.unreachable = nil, nil, nil, nil
        disarm(b)
        b.pulse:Stop()
        b:SetAlpha(0)
        b:EnableMouse(false)
        return nil
    end
    local spell = res.entry.spell
    b.extraSpell, b.reason, b.unknownSpell, b.unreachable = spell, res.reason, nil, nil
    b:SetFrameLevel(b:GetParent():GetFrameLevel() + 20)
    b.icon:SetTexture(ns.SpellTexture(spell))
    if not ns.SpellKnown(spell) then
        b.unknownSpell = spell
        disarm(b)
        b.icon:SetDesaturated(true)
        b.pulse:Stop()
        b:SetAlpha(0.8)
        b:EnableMouse(true)
        return "unknown"
    end
    if not reachable(b.unit, spell) then
        b.unreachable = true
        disarm(b)
        b.icon:SetDesaturated(true)
        b.pulse:Stop()
        b:SetAlpha(0.7)
        b:EnableMouse(true)
        return "unreachable"
    end
    b.icon:SetDesaturated(false)
    b.castSpell = spell
    b:SetAttribute("type1", "macro")
    b:SetAttribute("macrotext1", castMacro(b.unit, spell))
    b:SetAlpha(1)
    b:EnableMouse(true)
    if not b.pulse:IsPlaying() then b.pulse:Play() end
    return "ready"
end

-- Smart buff buttons ----------------------------------------------------------------------------------------
-- Casting needs a hardware event, so "automatic" is a one-key button: a secure button whose unit/spell
-- attributes are set out of combat to the NEXT pending buff (see Presets.PickNext). Bind it in
-- Esc > Options > Keybindings > AddOns > Healer Forever, or use the macro /click HealerForeverSmartBuff.
local function createSmartButtons()
    local smart = ns.NewFrame("Button", "HealerForeverSmartBuff", UIParent, "SecureActionButtonTemplate,BackdropTemplate")
    smart:SetSize(44, 44)
    smart:SetFrameStrata("MEDIUM")
    smart:RegisterForClicks("AnyDown", "AnyUp")
    smart:SetMovable(true)
    smart:SetClampedToScreen(true)
    smart:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    smart:SetBackdropBorderColor(1, 0.82, 0, 1)
    smart.icon = smart:CreateTexture(nil, "ARTWORK")
    smart.icon:SetPoint("TOPLEFT", 2, -2)
    smart.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    smart.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    smart.label = smart:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    smart.label:SetPoint("TOP", smart, "BOTTOM", 0, -2)
    smart.label:SetShadowOffset(1, -1)
    smart:RegisterForDrag("LeftButton")
    ns.SecureSetScript(smart, "OnDragStart", function(self)
        if not ns.InCombat() and not ns.db.frames.locked then self:StartMoving() end
    end)
    ns.SecureSetScript(smart, "OnDragStop", function(self)
        if ns.InCombat() then return end
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint()
        local p = ns.db.smartButton.point
        p.point, p.relativePoint, p.x, p.y = point, relativePoint, x, y
    end)
    ns.SecureHook(smart, "OnEnter", function(self)
        if GameTooltip and self.pendingText then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Buff next", 1, 0.82, 0)
            GameTooltip:AddLine(self.pendingText, 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    ns.SecureHook(smart, "OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    BB.smart = smart

    local tank = ns.NewFrame("Button", "HealerForeverTankBuff", UIParent, "SecureActionButtonTemplate")
    tank:SetSize(1, 1)
    tank:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    tank:RegisterForClicks("AnyDown", "AnyUp")
    tank:SetAlpha(0)
    tank:EnableMouse(false)
    BB.tank = tank
end

local function clearSecure(b)
    b:SetAttribute("type", nil)
    b:SetAttribute("macrotext", nil)
    b:SetAttribute("unit", nil)
    b.castSpell, b.castUnit = nil, nil
end

-- Armed only while the first TANK role buff is MISSING on a tank (same rules as the frame buttons).
-- Returns entry, unit (nil unit = idle) and a reason string for debugging.
function BB.tankTarget(cache)
    local preset = ns.db.presets[ns.db.activePreset]
    local entry
    for _, e in ipairs(preset and preset.extras or {}) do
        if type(e.roles) == "table" and e.roles.TANK then entry = e; break end
    end
    if not entry then return nil, nil, "no tank role buff configured" end
    local tanks, mineOn = {}, {}
    for _, unit in ipairs(ns.UnitFrames.MEMBER_UNITS) do
        local info = cache[unit]
        if info then
            if info.role == "TANK" then tanks[#tanks + 1] = unit end
            for _, aura in ipairs(info.auras) do
                if aura.isMine and extraMatches(entry, aura) then mineOn[unit] = true end
            end
        end
    end
    if #tanks == 0 then return entry, nil, "no tank in the group" end
    if not ns.SpellKnown(entry.spell) then return entry, nil, "you don't know " .. entry.spell .. " yet" end
    local threshold = ns.db.buffs.warn and ns.db.buffs.threshold or 0
    local now = GetTime()
    local unreachableTank = false
    for _, unit in ipairs(tanks) do
        local elsewhere = false
        for other in pairs(mineOn) do
            if other ~= unit then elsewhere = true end
        end
        if Presets.GetMissingExtra(entry, cache[unit].auras, now, threshold, elsewhere) then
            if reachable(unit, entry.spell) then
                return entry, unit, "armed"
            end
            unreachableTank = true
        end
    end
    if unreachableTank then return entry, nil, "tank is out of range / not visible" end
    return entry, nil, "tank already has " .. entry.spell
end

local function applySmart(pendingList, cache)
    local smart = BB.smart
    if not smart then return end
    local pick = Presets.PickNext(pendingList)
    local cfg = ns.db.smartButton
    if pick then
        smart:SetAttribute("type", "macro")
        smart:SetAttribute("macrotext", castMacro(pick.unit, pick.spell))
        smart:SetAttribute("unit", pick.unit)
        smart.castSpell, smart.castUnit = pick.spell, pick.unit
        smart.icon:SetTexture(ns.SpellTexture(pick.spell))
        local name = UnitName(pick.unit)
        if issecret(name) then
            -- a secret name goes straight into the widget; the debug text uses the unit token instead
            smart.label:SetText(name)
            smart.pendingText = pick.spell .. " on " .. pick.unit
        else
            smart.label:SetText(name or pick.unit)
            smart.pendingText = pick.spell .. " on " .. tostring(name or pick.unit)
        end
    else
        clearSecure(smart)
        smart.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        smart.label:SetText("")
        smart.pendingText = nil
    end
    -- the bound key works regardless; the on-screen button is only visible when enabled AND something is pending
    local visible = cfg.show and pick and true or false
    smart:SetAlpha(visible and 1 or 0)
    smart:EnableMouse(visible)

    local entry, unit = BB.tankTarget(cache)
    if entry and unit then
        BB.tank:SetAttribute("type", "macro")
        BB.tank:SetAttribute("macrotext", castMacro(unit, entry.spell))
        BB.tank:SetAttribute("unit", unit)
        BB.tank.castSpell, BB.tank.castUnit = entry.spell, unit
    else
        clearSecure(BB.tank)
    end
end

-- Number of missing buffs across all members (blessing-type buffs and role buffs); used by the minimap button.
-- While the raid layout is active the class buffs are counted on the raid bars instead (party1..4 are raid members
-- too, so adding both would count them twice).
function BB:MissingCount()
    local n = 0
    local RF = ns.RaidFrames
    if RF and RF.IsActive and RF:IsActive() and RF.MissingCount then
        n = n + RF:MissingCount()
    else
        for _, b in ipairs(BB.buttons) do
            if b.buffKey then n = n + (b.missingCount or 1) end
        end
    end
    for _, b in ipairs(BB.extraButtons) do
        if b.extraSpell then n = n + 1 end
    end
    return n
end

function BB:RefreshNow()
    if ns.InCombat() or not ns.db then return end
    local cache = {}
    local pending = {}
    for _, b in ipairs(BB.buttons) do
        local missing, reason = evaluate(b.unit, cache)
        local entries, primary = {}, nil
        for _, key in ipairs(missing) do
            local entry = armEntry(b.unit, key)
            if entry then entries[#entries + 1] = entry end
        end
        -- next buff to show: the first castable one, else the first unreachable one, else the first unknown one
        for _, wanted in ipairs({ "ready", "unreachable", "unknown" }) do
            for _, entry in ipairs(entries) do
                if not primary and entry.state == wanted then primary = entry end
            end
        end
        local names = {}
        for _, entry in ipairs(entries) do
            if entry ~= primary then names[#names + 1] = entry.def.name end
        end
        setActive(b, primary, #entries, reason, names)
        local info = cache[b.unit]
        for _, entry in ipairs(entries) do
            if entry.state == "ready" then
                pending[#pending + 1] = { unit = b.unit, role = info and info.role, kind = "blessing",
                    spell = entry.single or entry.greater, isSelf = b.unit == "player" }
            end
        end
    end
    for _, unit in ipairs(ns.UnitFrames.MEMBER_UNITS) do gather(unit, cache) end
    local extras = evaluateExtras(cache)
    for _, b in ipairs(BB.extraButtons) do
        local state = setExtra(b, extras[b.unit])
        if state == "ready" then
            local info = cache[b.unit]
            pending[#pending + 1] = { unit = b.unit, role = info and info.role, kind = "extra",
                spell = extras[b.unit].entry.spell, isSelf = b.unit == "player" }
        end
    end
    local RF = ns.RaidFrames
    if RF and RF.IsActive and RF:IsActive() and RF.PendingList then
        -- raid layout: the class buffs pending on the raid bars replace the party ones (same people, other tokens);
        -- role buffs stay as they are
        local merged = {}
        for _, e in ipairs(pending) do
            if e.kind ~= "blessing" then merged[#merged + 1] = e end
        end
        for _, e in ipairs(RF:PendingList()) do merged[#merged + 1] = e end
        pending = merged
    end
    applySmart(pending, cache)
end

function BB:Debug()
    if not ns.db then return end
    ns:Print("buff debug (combat: " .. tostring(ns.InCombat()) .. ", grouped: " .. tostring(ns.InGroup())
        .. ", preset: " .. tostring(ns.db.presets[ns.db.activePreset] and ns.db.presets[ns.db.activePreset].name)
        .. ", you: " .. tostring(ns.PlayerClass()) .. ")")
    local cache = {}
    for _, b in ipairs(BB.buttons) do
        local missing, _, d = evaluate(b.unit, cache)
        local parts = { b.unit, tostring(d.name), tostring(d.class), "role=" .. tostring(d.role) .. "/" .. tostring(d.roleSource),
            "self=" .. tostring(d.isSelf), "assigned=" .. (d.resolved and table.concat(d.resolved, "+") or "-") }
        for _, key in ipairs(missing) do
            local entry = armEntry(b.unit, key)
            parts[#parts + 1] = "MISSING " .. key .. "(" .. (entry and entry.state or "?") .. ", "
                .. tostring(entry and entry.def.name) .. "=" .. (entry and entry.single and "known" or "unknown")
                .. (entry and entry.def.groupSpell and (", " .. entry.def.groupSpell .. "=" .. (entry.greater and "known" or "unknown")) or "")
                .. ")"
        end
        parts[#parts + 1] = string.format("button shown=%s alpha=%.1f level=%d count=%s", tostring(b:IsShown()),
            b:GetAlpha(), b:GetFrameLevel(), tostring(b.missingCount))
        parts[#parts + 1] = #missing > 0 and "WOULD SHOW" or ("hidden: " .. tostring(d.hidden))
        ns:Print(table.concat(parts, " | "))
        -- every assigned buff: present or missing, the matching aura, time left, % left and the rule that applied
        for _, item in ipairs(d.report or {}) do
            local def = Classes.BUFFS[item.key]
            ns:Print(string.format("    %s: %s | aura=%s | left=%s | %s | rebuff below %s", def and def.name or item.key,
                item.missing and (item.auraName and "RUNNING OUT" or "MISSING") or "present",
                tostring(item.auraName or "-"),
                item.remaining and string.format("%.0fs", item.remaining) or (item.auraName and "no expiry" or "-"),
                item.pct and string.format("%.1f%%", item.pct) or "-%", tostring(item.rule)))
        end
    end
    for _, unit in ipairs(ns.UnitFrames.MEMBER_UNITS) do gather(unit, cache) end
    local extras = evaluateExtras(cache)
    local preset = ns.db.presets[ns.db.activePreset]
    for _, entry in ipairs(preset and preset.extras or {}) do
        local roles = {}
        for role in pairs(entry.roles) do roles[#roles + 1] = role end
        table.sort(roles)
        local targets = {}
        for unit, res in pairs(extras) do
            if res.entry == entry then targets[#targets + 1] = unit end
        end
        table.sort(targets)
        ns:Print("extra: " .. entry.spell .. " roles=" .. table.concat(roles, ",") .. " single=" .. tostring(entry.single)
            .. " known=" .. tostring(ns.SpellKnown(entry.spell)) .. " pending on: "
            .. (#targets > 0 and table.concat(targets, ",") or "nobody"))
    end
    local tEntry, tUnit, tWhy = BB.tankTarget(cache)
    if tEntry and tUnit then
        ns:Print("tank button: armed: " .. tEntry.spell .. " -> " .. tostring(UnitName(tUnit) or tUnit))
    else
        ns:Print("tank button: idle: " .. tWhy)
    end
    ns:Print("smart buff: " .. tostring(BB.smart and BB.smart.castSpell) .. " on " .. tostring(BB.smart and BB.smart.castUnit))
end

function BB:ApplySmartPosition()
    if not BB.smart then return end
    local p = ns.db.smartButton.point
    BB.smart:ClearAllPoints()
    BB.smart:SetPoint(p.point, UIParent, p.relativePoint, p.x, p.y)
end

local pending = false
function BB:Refresh()
    if pending then return end
    pending = true
    local function run()
        pending = false
        BB:RefreshNow()
    end
    if C_Timer and C_Timer.After then C_Timer.After(0.3, run) else run() end
end

ns:On("FRAMES_CREATED", function()
    for i, unit in ipairs(ns.UnitFrames.MEMBER_UNITS) do
        BB.buttons[#BB.buttons + 1] = createButton(ns.UnitFrames.byUnit[unit], i)
        BB.extraButtons[#BB.extraButtons + 1] = createButton(ns.UnitFrames.byUnit[unit], i, "extra")
    end
    createSmartButtons()
    BB:ApplySmartPosition()
    BB:Refresh()
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(0.5, function()
            local t0 = ns.perfOn and debugprofilestop()
            BB:RefreshNow()
            if t0 then ns.Perf.Add("bb", t0) end
        end)
    end
end)
ns:RegisterEvent("UNIT_AURA", function(_, unit)
    if unit and ns.UnitFrames.byUnit[unit] and not ns.InCombat() then BB:Refresh() end
end)
ns:RegisterEvent("GROUP_ROSTER_UPDATE", function() BB:Refresh() end)
ns:RegisterEvent("PLAYER_ROLES_ASSIGNED", function() BB:Refresh() end)
ns:RegisterEvent("UNIT_IN_RANGE_UPDATE", function(_, unit)
    if unit and ns.UnitFrames.byUnit[unit] and not ns.InCombat() then BB:Refresh() end
end)
ns:RegisterEvent("SPELLS_CHANGED", function() BB:Refresh() end)
ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() BB:Refresh() end)
ns:On("CONFIG_CHANGED", function() BB:Refresh() end)

-- Key binding names (Bindings.xml uses the CLICK actions below)
BINDING_HEADER_HEALERFOREVER = "Healer Forever"
_G["BINDING_NAME_CLICK HealerForeverSmartBuff:LeftButton"] = "Healer Forever: Cast next missing buff"
_G["BINDING_NAME_CLICK HealerForeverTankBuff:LeftButton"] = "Healer Forever: Cast tank buff on tank"
