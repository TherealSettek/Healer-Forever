-- Helpers to locate the addon and load its files the way WoW does:
-- every file is a chunk called with (ADDON_NAME, ns) varargs.
local L = {}

L.root = rawget(_G, "HF_ROOT") or "."
L.addonName = "HealerForever"
L.addonDir = (os.getenv and os.getenv("HF_ADDON_DIR")) or (L.root .. "/" .. L.addonName)
L.tocPath = L.addonDir .. "/" .. L.addonName .. ".toc"

function L.exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

function L.readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

-- Returns { meta = {Key=value,...}, files = {"Util/Util.lua", ...}, raw = {...} } or nil
function L.parseToc()
    if not L.exists(L.tocPath) then return nil end
    local toc = { meta = {}, files = {} }
    for line in (L.readFile(L.tocPath) .. "\n"):gmatch("(.-)\r?\n") do
        line = line:match("^%s*(.-)%s*$")
        if line:sub(1, 2) == "##" then
            local k, v = line:match("^##%s*([%w%-_]+)%s*:%s*(.-)%s*$")
            if k then toc.meta[k] = v end
        elseif line ~= "" and line:sub(1, 1) ~= "#" then
            toc.files[#toc.files + 1] = line
        end
    end
    return toc
end

function L.path(rel) return L.addonDir .. "/" .. rel:gsub("\\", "/") end

function L.loadFile(rel, ns)
    local chunk, err = loadfile(L.path(rel))
    if not chunk then error("failed to compile " .. rel .. ": " .. tostring(err), 0) end
    return chunk(L.addonName, ns)
end

-- Load the given relative files (skipping non-.lua), in order, sharing ns.
function L.loadFiles(ns, files)
    for _, rel in ipairs(files) do
        if rel:lower():match("%.lua$") then L.loadFile(rel, ns) end
    end
    return ns
end

-- Files of the pure-module contract, in dependency order.
L.CONTRACT_FILES = {
    "Util/Util.lua", "Data/Classes.lua", "Buffs/Presets.lua",
    "ClickCast/Bindings.lua", "Core.lua",
}

-- Load the contract files that exist. Returns ns, missingList, errorsByFile
function L.loadContract(ns)
    ns = ns or {}
    local missing, errs = {}, {}
    for _, rel in ipairs(L.CONTRACT_FILES) do
        if not L.exists(L.path(rel)) then
            missing[#missing + 1] = rel
        else
            local ok, err = pcall(L.loadFile, rel, ns)
            if not ok then errs[rel] = tostring(err) end
        end
    end
    return ns, missing, errs
end

-- Recursively list .lua/.xml files under the addon dir (relative paths)
function L.listAddonFiles()
    local out = {}
    local p = io.popen('cd "' .. L.addonDir .. '" 2>/dev/null && find . -type f \\( -name "*.lua" -o -name "*.xml" \\) | sed "s|^\\./||" | sort')
    if p then
        for line in p:lines() do out[#out + 1] = line end
        p:close()
    end
    return out
end

return L
