-- tools/patch.lua
-- Exact text replacements that work whatever the file's line endings (the working tree is CRLF).
-- Dev tool, not packaged. Usage from a script run with LuaJIT in the repo folder:
--   dofile("tools/patch.lua"); patch("AskBot.lua", { { [==[old text]==], [==[new text]==] }, ... })
-- Each old text must occur; only the first occurrence is replaced. Use [==[ ]==] strings.
function patch(file, list)
    local f = assert(io.open(file, "rb")); local s = f:read("*a"); f:close()
    local crlf = s:find("\r\n", 1, true) ~= nil
    s = s:gsub("\r\n", "\n")
    for _, p in ipairs(list) do
        local old, new = p[1]:gsub("\r\n", "\n"), p[2]:gsub("\r\n", "\n")
        local a, b = s:find(old, 1, true); assert(a, file .. " missing: " .. old:sub(1, 80))
        s = s:sub(1, a - 1) .. new .. s:sub(b + 1)
    end
    if crlf then s = s:gsub("\n", "\r\n") end
    f = io.open(file, "wb"); f:write(s); f:close()
end
