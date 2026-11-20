local ADDON_NAME, ns = ...

SLASH_HEALERFOREVER1 = "/hf"
SLASH_HEALERFOREVER2 = "/healerforever"

-- Single source for /hf help and the Help & Contact tab.
ns.SLASH_COMMANDS = {
    { cmd = "/hf", help = "/hf - options", desc = "Open or close the options window" },
    { cmd = "/hf lock", desc = "Lock the bars so they can't be moved" },
    { cmd = "/hf unlock", desc = "Unlock the bars so you can drag them" },
    { cmd = "/hf preset <n>", desc = "Activate buff preset n (no number lists the presets)" },
    { cmd = "/hf reset", desc = "Reset this character's settings to the defaults" },
    { cmd = "/hf version", desc = "Show the addon version and settings schema" },
    { cmd = "/hf errors [clear|copy]", help = "/hf errors [clear]", desc = "List logged errors, clear them, or copy them" },
    { cmd = "/hf profile", desc = "Show which settings profile is in use" },
    { cmd = "/hf copyaccount", desc = "Copy the account-wide settings into this character (asks to confirm)" },
    { cmd = "/hf raid [auto|party|raid]", help = "/hf raid", desc = "Show which layout is active and why, or set the layout switching (auto / always party / always raid)" },
    { cmd = "/hf raid preview [10|20|25|40|off]", help = "/hf raid preview", desc = "Show a fake full raid at your raid position to try the raid options (not clickable, turns off in combat)" },
    { cmd = "/hf debug buffs", help = "/hf debug buffs | auras | click [raidN] | click watch | raid | threat | clear", desc = "Explain why each buff button is shown or hidden" },
    { cmd = "/hf debug auras", hidden = true, desc = "Show the aura path and what the game returned per unit" },
    { cmd = "/hf debug click", hidden = true, desc = "Show the click-casting state of your bar (add raidN for a raid bar, e.g. raid5)" },
    { cmd = "/hf debug click watch", hidden = true, desc = "Print the click state on every modifier change" },
    { cmd = "/hf debug threat", hidden = true, desc = "Show what the game returns for threat per member and whether each strip is shown" },
    { cmd = "/hf debug raid", hidden = true, desc = "Show the raid layout state: active layout and reason, buttons, cells and aliases" },
    { cmd = "/hf debug clear", hidden = true, desc = "Clear the stored debug output" },
    { cmd = "/hf copy", desc = "Open a window with the last debug output and errors to copy" },
    { cmd = "/hf mark [note|clear]", help = "/hf mark [note] | /hf mark clear", desc = "Save a snapshot of this moment for the report (last 5), or clear them" },
    { cmd = "/hf perf [start [seconds]|stop]", help = "/hf perf", desc = "Show CPU and memory per addon (ours vs the others); start/stop times our own code over a window (default 60 s)" },
    { cmd = "/hf report", desc = "Open the ready-to-email problem report" },
    { cmd = "/hf contact", desc = "Show the support email and open Help & Contact" },
}

local function help()
    local parts = {}
    for _, c in ipairs(ns.SLASH_COMMANDS) do
        if not c.hidden then parts[#parts + 1] = c.help or c.cmd end
    end
    ns:Print(table.concat(parts, " | "))
end

SlashCmdList["HEALERFOREVER"] = function(msg)
    local cmd, arg = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "options" or cmd == "config" then
        ns.Options:Toggle()
    elseif cmd == "lock" then
        ns.UnitFrames:SetLocked(true)
        ns:Print("Frames locked.")
    elseif cmd == "unlock" then
        ns.UnitFrames:SetLocked(false)
        ns:Print("Frames unlocked.")
    elseif cmd == "preset" then
        local n = tonumber(arg)
        if n and ns.db.presets[n] then
            ns:SetActivePreset(n)
            ns:Print("Active buff preset: " .. ns.db.presets[n].name)
        else
            for i, p in ipairs(ns.db.presets) do
                ns:Print(i .. ". " .. p.name .. (i == ns.db.activePreset and " (active)" or ""))
            end
        end
    elseif cmd == "version" then
        ns:Print("HealerForever " .. ns.AddonVersion() .. " (settings schema " .. ns.SchemaVersion() .. ") by trtg")
    elseif cmd == "errors" then
        local log = ns.db.errorLog
        local sub = arg:lower()
        if sub == "clear" then
            for i = #log, 1, -1 do log[i] = nil end
            ns.errorMemory = {}
            ns:Print("Error log cleared.")
        elseif sub == "copy" then
            ns.CopyWindow:Show()
        elseif #log == 0 then
            ns:Print("No errors logged.")
        else
            ns:Print(#log .. " logged (showing the last 10; /hf copy opens a copyable window):")
            for _, line in ipairs(ns.FormatErrors(10)) do ns:Print(line) end
        end
    elseif cmd == "profile" then
        ns:Print("Profile: " .. ns:ProfileName() .. " (per-character settings"
            .. (ns.db.migratedFrom and ", seeded from account-wide settings" or "") .. ")")
    elseif cmd == "copyaccount" then
        if arg:lower() == "confirm" then
            ns:AfterCombat("copyaccount", function()
                if ns:ImportAccount() then
                    ns:Print("Copied account-wide settings into " .. ns:ProfileName() .. ".")
                else
                    ns:Print("No account-wide settings found.")
                end
            end)
        else
            ns:Print("This replaces " .. ns:ProfileName() .. "'s settings with the account-wide ones. Type /hf copyaccount confirm to proceed.")
        end
    elseif cmd == "copy" then
        ns.CopyWindow:Show()
    elseif cmd == "mark" then
        if arg:lower() == "clear" then
            ns.Report.ClearMarks()
            ns:Print("Marks cleared.")
        else
            ns.Report.Mark(arg)
            ns:Print("Marked. Use /hf report or Help & Contact > Report a problem.")
        end
    elseif cmd == "raid" then
        local RF = ns.RaidFrames
        local want = arg:lower()
        local MODES = { auto = "Auto", party = "Always party", raid = "Always raid" }
        local pv = want:match("^preview%s*(.-)$")
        if pv then
            local RP = ns.RaidPreview
            local ok, why
            if pv == "off" then
                ok, why = RP:SetOn(false)
            elseif pv == "" then
                ok, why = RP:Toggle()
            elseif pv == "on" or RP.ValidSize(pv) then
                ok, why = RP:SetOn(true, RP.ValidSize(pv))
            else
                ns:Print("/hf raid preview [10|20|25|40|off]")
                return
            end
            if not ok then
                ns:Print(why or "Preview not available.")
            elseif RP.on then
                ns:Print("Raid preview ON (" .. RP.size .. " fake players). Not clickable; turns off in combat. /hf raid preview off")
            else
                ns:Print("Raid preview off.")
            end
            return
        end
        if MODES[want] then
            ns.db.raid.layoutMode = want
            ns:Changed("raid")
            -- option changes are coalesced (RF:RequestEvaluate); an explicit command applies now so the status is current
            if RF and RF.anchor then RF:Evaluate() end
            ns:Print("Layout switching: " .. MODES[want] .. ".")
        elseif want ~= "" then
            ns:Print("/hf raid [auto|party|raid]")
        end
        ns:Print(RF and RF:StatusLine() or "raid frames not loaded")
    elseif cmd == "perf" then
        ns.Perf.Slash(arg)
    elseif cmd == "report" then
        ns.Report.Show()
    elseif cmd == "contact" then
        ns:Print("Problems or ideas? Write to " .. ns.Report.EMAIL)
        ns.Options:Show("help")
    elseif cmd == "debug" then
        local sub = arg:lower()
        local wantCopy = false
        if sub:match(" copy$") then
            wantCopy = true
            sub = sub:gsub(" copy$", "")
        end
        local ran = true
        if sub == "clear" then
            ns.ClearDebug()
            ns:Print("Debug log cleared.")
            ran = false
        elseif sub == "auras" then
            ns.RunDebug("auras", function()
                local units = {}
                local hovered = ns.UnitFrames.hovered
                if hovered then units[1] = hovered.unit else units = ns.UnitFrames.MEMBER_UNITS end
                ns:Print("aura debug (combat: " .. tostring(ns.InCombat()) .. ")")
                for _, unit in ipairs(units) do
                    if ns.Exists(unit) then
                        local ok, lines = pcall(ns.Auras.Debug, unit)
                        if ok then
                            for _, line in ipairs(lines) do ns:Print(line) end
                        else
                            ns:Print(unit .. ": debug failed: " .. tostring(lines))
                        end
                    end
                end
            end)
        elseif sub == "click watch" then
            ns.UnitFrames.debugClickWatch = not ns.UnitFrames.debugClickWatch
            ns:Print("click watch " .. (ns.UnitFrames.debugClickWatch and "ON: the click state is printed (and stored) on every modifier change (hold Cmd over your bar)" or "off"))
            ran = false
        elseif sub:match("^click raid%d+$") then
            local token = sub:match("^click (raid%d+)$")
            ns.RunDebug("click " .. token, function() ns.UnitFrames:DebugClick(token) end)
        elseif sub == "raid" then
            ns.RunDebug("raid", function() ns.RaidFrames:Debug() end)
        elseif sub == "threat" then
            ns.RunDebug("threat", function() ns.UnitFrames:DebugThreat() end)
        elseif sub == "click" then
            ns.RunDebug("click", function() ns.UnitFrames:DebugClick("player") end)
        elseif sub == "buffs" then
            ns.RunDebug("buffs", function() ns.BuffButtons:Debug() end)
        else
            ns:Print("/hf debug buffs | auras | click [raidN] | click watch | raid | threat | clear   (add 'copy' to open the copy window)")
            ran = false
        end
        if ran then
            if wantCopy then
                ns.CopyWindow:Show()
            else
                ns:Print("Output stored. /hf copy opens a window you can copy it from.")
            end
        end
    elseif cmd == "reset" then
        ns:AfterCombat("reset", function()
            ns:ResetDB()
            ns:Print("Settings reset to defaults.")
        end)
    else
        help()
    end
end
