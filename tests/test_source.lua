-- Static scan: global assignments (GSET in LuaJIT bytecode) outside an allow-list.
local L = require("loader")
local toc = L.parseToc()

local ALLOWED = {
    "^HealerForeverDB$", "^HealerForeverCharDB$", "^SLASH_[%u_]+%d*$", "^BINDING_HEADER_", "^BINDING_NAME_",
    "^HealerForever%u?%w*$", "^HF_%u[%u_]*$",
}
local function allowed(name)
    for _, p in ipairs(ALLOWED) do if name:match(p) then return true end end
    return false
end

describe("source: accidental globals", function()
    if not toc then it("TOC present", function() error("no TOC") end) return end
    local jitOk = os.execute("luajit -v >/dev/null 2>&1")
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") and L.exists(L.path(rel)) then
            it(rel .. " assigns no unexpected globals", function()
                local p = io.popen('luajit -bl "' .. L.path(rel) .. '" 2>&1')
                local out = p:read("*a"); p:close()
                local bad, seen = {}, {}
                for line in out:gmatch("[^\n]+") do
                    local name = line:match("%sGSET%s.-;%s*\"(.-)\"")
                    if name and not allowed(name) and not seen[name] then
                        seen[name] = true
                        bad[#bad + 1] = name .. "   (" .. line:gsub("%s+", " ") .. ")"
                    end
                end
                assertEquals(#bad, 0, "unexpected global assignment(s): " .. table.concat(bad, "; "))
            end)
        end
    end
end)
