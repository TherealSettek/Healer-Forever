-- Helpers for the Buff Presets pane (cells, popup, Self row). The pane builds: one Self cell, then one cell per class/role row
-- (Classes.ORDER x { DEFAULT, roles... }), and a shared popup (HealerForeverBuffPopup) with a row per option.
local mock = require("wow_mock")
local M = {}
local function st(f) return rawget(f, "__s") end

-- Returns { self = cell, rows = { {class=, role=, cell=} ... }, byKey = { ["PALADIN:TANK"] = cell } } for the open pane.
function M.cells(ns)
    local cells = {}
    for _, f in ipairs(mock.frames) do
        if st(f).kind == "Button" and type(rawget(f, "icons")) == "table" and rawget(f, "dash") then cells[#cells + 1] = f end
    end
    local out = { self = cells[1], rows = {}, byKey = {}, all = cells }
    local idx = 1
    for _, class in ipairs(ns.Classes.ORDER) do
        local roles = { "DEFAULT" }
        for _, r in ipairs(ns.Classes.ROLES[class]) do roles[#roles + 1] = r end
        for _, role in ipairs(roles) do
            idx = idx + 1
            local c = cells[idx]
            if c then
                out.rows[#out.rows + 1] = { class = class, role = role, cell = c }
                out.byKey[class .. ":" .. role] = c
            end
        end
    end
    return out
end

-- Visible icon textures of a cell (array of texture paths, in order).
function M.cellIcons(cell)
    local out = {}
    for _, t in ipairs(cell.icons) do if st(t).shown then out[#out + 1] = st(t).texture end end
    return out
end
function M.cellDash(cell) return st(cell.dash).text end

function M.popup() return _G.HealerForeverBuffPopup end
function M.popupShown() local p = _G.HealerForeverBuffPopup; return p ~= nil and st(p).shown end
function M.click(f) st(f).scripts.OnClick(f, "LeftButton"); mock.flushTimers() end
function M.openCell(cell) M.click(cell) end

-- Visible popup rows: { { frame=, label=, checked=, unknown=, icon=, desat= } ... } and headers (texts) in order
function M.rows()
    local p = _G.HealerForeverBuffPopup
    local out = {}
    if not p then return out, {} end
    for _, row in ipairs(p.rows or {}) do
        if st(row).shown then
            local text = tostring(st(row.text).text or "")
            out[#out + 1] = { frame = row, label = (text:gsub("%s*|cff%x+.-|r", "")), raw = text, checked = st(row.check).shown and true or false,
                unknown = text:find("Not in your spellbook", 1, true) ~= nil, iconShown = st(row.icon).shown, desat = st(row.icon).desat }
        end
    end
    local headers = {}
    for _, h in ipairs(p.headers or {}) do if st(h).shown then headers[#headers + 1] = st(h).text end end
    return out, headers
end
function M.pick(label)
    for _, r in ipairs((M.rows())) do
        if r.label == label then M.click(r.frame); return true end
    end
    return false
end
function M.checked()
    local out = {}
    for _, r in ipairs((M.rows())) do if r.checked then out[#out + 1] = r.label end end
    return out
end
function M.close()
    local p = _G.HealerForeverBuffPopup
    if p then p:Hide() end
end

return M
