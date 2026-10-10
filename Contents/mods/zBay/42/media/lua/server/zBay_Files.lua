----------
--ESTRAL--
----------

require "zBay_Core"

if not zBay.isAuthority() then return end

-- everything zBay reads or writes outside the save goes through here. the lua file api only
-- reaches Zomboid/Lua, takes a relative path, and can neither delete nor rename, which shapes
-- every file format in this mod.
--
-- it also only writes five kinds of file: ini, cfg, txt, log and json
-- (LuaManager.ALLOWED_FILE_EXTENSIONS, 42.21). anything else and getFileWriter hands back
-- nothing, without a word in the log. so a file of one json record to a line is a .log here
-- and not a .jsonl, and a spare copy is a second .json and not a .bak.

zBay_Files = zBay_Files or {}

-- where a relative path resolves to, for telling a human about it. never passed to the file
-- api, which would then create a Lua/Lua folder.
zBay_Files.FOLDER = "Zomboid/Lua/"

function zBay_Files.path(name)
    return zBay.DIR .. "/" .. name
end

function zBay_Files.shown(name)
    return zBay_Files.FOLDER .. zBay_Files.path(name)
end

-- the text, or nil and why. a missing file is either a nil reader or one whose first line is
-- nil, build depending, so both come back the same way.
function zBay_Files.read(name)
    -- false, so a missing file comes back nil instead of being created empty.
    local ok, reader = pcall(function() return getFileReader(zBay_Files.path(name), false) end)
    if not ok or not reader then return nil, "could not open" end

    local lines = {}
    local okRead, err = pcall(function()
        local line = reader:readLine()
        while line do
            lines[#lines + 1] = line
            line = reader:readLine()
        end
    end)

    pcall(function() reader:close() end)

    if not okRead then return nil, "read failed: " .. tostring(err) end
    if #lines == 0 then return nil, "empty or missing" end

    return table.concat(lines, "\n"), nil, lines
end

local function zBay_put(name, text, append)
    local ok, writer = pcall(function() return getFileWriter(zBay_Files.path(name), true, append) end)
    if not ok or not writer then return false end

    local wrote = pcall(function() writer:write(text) end)
    pcall(function() writer:close() end)

    return wrote
end

function zBay_Files.write(name, text)
    return zBay_put(name, text, false)
end

function zBay_Files.append(name, text)
    return zBay_put(name, text, true)
end

-- the save's name, made safe to be part of a filename, so two worlds on one host keep their
-- own files.
function zBay_Files.world()
    local ok, name = pcall(function() return getWorld():getWorld() end)
    if not ok or type(name) ~= "string" or name == "" then name = "world" end

    return (string.gsub(name, "[^%w%-_]", "_"))
end
