-- Layer 1: static checks of HealerForever.toc and the Lua sources.
local L = require("loader")

describe("TOC", function()
    local toc = L.parseToc()

    it("HealerForever.toc exists", function()
        assertNotNil(toc, "missing " .. L.tocPath)
    end)
    if not toc then return end

    it("has ## Interface (numeric, retail 1xxxxx)", function()
        local i = toc.meta.Interface
        assertNotNil(i, "no ## Interface")
        for v in i:gmatch("[^,%s]+") do assertTrue(v:match("^%d+$") ~= nil, "bad Interface value " .. v) end
    end)
    it("has ## Title", function()
        assertTrue((toc.meta.Title or "") ~= "", "no ## Title")
    end)
    it("declares ## SavedVariables: HealerForeverDB", function()
        assertNotNil((toc.meta.SavedVariables or ""):find("HealerForeverDB", 1, true), "SavedVariables = " .. tostring(toc.meta.SavedVariables))
    end)
    it("declares ## SavedVariablesPerCharacter: HealerForeverCharDB", function()
        assertNotNil((toc.meta.SavedVariablesPerCharacter or ""):find("HealerForeverCharDB", 1, true), "SavedVariablesPerCharacter = " .. tostring(toc.meta.SavedVariablesPerCharacter))
    end)
    it("lists at least one file", function() assertTrue(#toc.files > 0) end)

    it("every listed file exists", function()
        local missing = {}
        for _, f in ipairs(toc.files) do
            if not L.exists(L.path(f)) then missing[#missing + 1] = f end
        end
        assertEquals(#missing, 0, "missing files: " .. table.concat(missing, ", "))
    end)

    it("no file is listed twice", function()
        local seen, dup = {}, {}
        for _, f in ipairs(toc.files) do
            local k = f:lower():gsub("\\", "/")
            if seen[k] then dup[#dup + 1] = f end
            seen[k] = true
        end
        assertEquals(#dup, 0, "duplicates: " .. table.concat(dup, ", "))
    end)

    it("every .lua/.xml under HealerForever/ is listed in the TOC", function()
        local listed = {}
        for _, f in ipairs(toc.files) do listed[f:gsub("\\", "/"):lower()] = true end
        local unlisted = {}
        for _, f in ipairs(L.listAddonFiles()) do
            -- Bindings.xml is loaded automatically by WoW and must NOT be listed (checked separately)
            if not listed[f:lower()] and f:lower() ~= "bindings.xml" then unlisted[#unlisted + 1] = f end
        end
        assertEquals(#unlisted, 0, "files not in TOC (would never load in game): " .. table.concat(unlisted, ", "))
    end)

    it("Bindings.xml (auto-loaded by WoW) is not listed in the TOC", function()
        for _, f in ipairs(toc.files) do assertTrue(f:lower() ~= "bindings.xml", "Bindings.xml must not be in the TOC") end
    end)

    it("every listed .lua file compiles (syntax check)", function()
        local bad = {}
        for _, f in ipairs(toc.files) do
            if f:lower():match("%.lua$") and L.exists(L.path(f)) then
                local chunk, err = loadfile(L.path(f))
                if not chunk then bad[#bad + 1] = err end
            end
        end
        assertEquals(#bad, 0, table.concat(bad, "\n"))
    end)

    it("no LuaJIT-only / Lua 5.2+ syntax (goto, ::label::, bit ops) that WoW's Lua 5.1 rejects", function()
        local bad = {}
        for _, f in ipairs(toc.files) do
            if f:lower():match("%.lua$") and L.exists(L.path(f)) then
                local n = 0
                for line in L.readFile(L.path(f)):gmatch("[^\n]*") do
                    n = n + 1
                    local code = line:gsub("%-%-.*$", "")
                    if code:match("%f[%w_]goto%f[^%w_]") or code:match("::[%a_][%w_]*::") or code:match("%d[uU]?[lL][lL]%f[^%w_]") then
                        bad[#bad + 1] = f .. ":" .. n .. ": " .. line
                    end
                end
            end
        end
        assertEquals(#bad, 0, table.concat(bad, "\n"))
    end)

    it("every .lua file begins with `local ADDON_NAME, ns = ...`", function()
        local bad = {}
        for _, f in ipairs(toc.files) do
            if f:lower():match("%.lua$") and L.exists(L.path(f)) then
                local src = L.readFile(L.path(f))
                if not src:find("local%s+ADDON_NAME%s*,%s*ns%s*=%s*%.%.%.") then bad[#bad + 1] = f end
            end
        end
        if #bad > 0 then warn("files without `local ADDON_NAME, ns = ...`: " .. table.concat(bad, ", ")) end
    end)

    it("contract files are present and in dependency order in the TOC", function()
        local idx = {}
        for i, f in ipairs(toc.files) do idx[f:gsub("\\", "/")] = i end
        local last = 0
        for _, f in ipairs(L.CONTRACT_FILES) do
            assertNotNil(idx[f], f .. " not listed in TOC")
            assertTrue(idx[f] > last, f .. " listed out of dependency order")
            last = idx[f]
        end
    end)
end)

-- Minimal XML well-formedness check (balanced tags, quoted attributes) for Bindings.xml
local function parseXml(src)
    src = src:gsub("<!%-%-.-%-%->", ""):gsub("<%?.-%?>", "")
    local stack, root, count = {}, nil, 0
    local pos = 1
    local nodes = {}
    while true do
        local s, e, closing, name, attrs, selfclose = src:find("<(/?)([%w_:%-]+)([^>]-)(/?)>", pos)
        if not s then break end
        local between = src:sub(pos, s - 1)
        if between:find("[^%s]") and #stack == 0 then return nil, "text outside root" end
        if closing == "/" then
            if stack[#stack] ~= name then return nil, "mismatched </" .. name .. ">" end
            stack[#stack] = nil
        else
            local a = {}
            for k, q, v in attrs:gmatch("([%w_:%-]+)%s*=%s*([\"'])(.-)%2") do a[k] = v end
            local leftover = attrs:gsub("([%w_:%-]+)%s*=%s*([\"'])(.-)%2", ""):gsub("%s", "")
            if leftover ~= "" then return nil, "bad attributes in <" .. name .. ">: " .. attrs end
            nodes[#nodes + 1] = { name = name, attrs = a }
            if selfclose ~= "/" then stack[#stack + 1] = name end
            if #stack == 1 and not root then root = name end
        end
        pos = e + 1
        count = count + 1
    end
    if #stack ~= 0 then return nil, "unclosed <" .. stack[#stack] .. ">" end
    return nodes
end

describe("Bindings.xml", function()
    local path = L.addonDir .. "/Bindings.xml"
    if not L.exists(path) then
        it("Bindings.xml present (optional)", function() warn("no Bindings.xml") end)
        return
    end
    local nodes, err = parseXml(L.readFile(path))
    it("is well-formed XML with a <Bindings> root", function()
        assertNotNil(nodes, tostring(err))
        assertEquals(nodes[1].name, "Bindings")
    end)
    it("every <Binding> has a name; CLICK bindings use the Frame:Button form", function()
        local n = 0
        for _, node in ipairs(nodes or {}) do
            if node.name == "Binding" then
                n = n + 1
                local nm = node.attrs.name
                assertNotNil(nm, "Binding without name")
                if nm:find("^CLICK ") then assertNotNil(nm:match("^CLICK [%w_]+:%w+$"), "bad CLICK name: " .. nm) end
            end
        end
        assertTrue(n >= 1)
    end)
    it("only one binding carries the header and the header has a BINDING_HEADER_ global (checked in smoke)", function()
        local headers = 0
        for _, node in ipairs(nodes or {}) do if node.name == "Binding" and node.attrs.header then headers = headers + 1 end end
        assertEquals(headers, 1)
    end)
    it("binding names are unique", function()
        local seen = {}
        for _, node in ipairs(nodes or {}) do
            if node.name == "Binding" then assertNil(seen[node.attrs.name], "dup " .. node.attrs.name); seen[node.attrs.name] = true end
        end
    end)
end)
