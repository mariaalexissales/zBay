----------
--ESTRAL--
----------

zBay = zBay or {}

zBay.MODULE = "zBay"
zBay.SCHEMA_V = 1

-- under Zomboid/Lua/, not the mod folder: Steam overwrites that on every workshop update.
zBay.DIR = "zBay"

zBay.Config = zBay.Config or {
    -- per-command tracing. off in anything shipped -- a busy market is a line per click.
    verbose = false,
}

-- server/ lua loads on multiplayer clients too, and isServer() is false in singleplayer.
function zBay.isAuthority()
    return not (isClient() and not isServer())
end

function zBay.hasRemoteServer()
    return isClient() and not isServer()
end

-- the engine ships both spellings -- Role.class has Admin/GM/Moderator, Roles.class has
-- lowercase, and vanilla compares the lowercase one. normalising stops a case-sensitive test
-- being a coin flip.
function zBay.accessLevel(player)
    if not player then return "none" end

    local level = player:getAccessLevel()
    if not level or level == "" then return "none" end

    return string.lower(level)
end

-- both flags off is "no multiplayer at all". asking for a remote server instead is false in
-- the server process too, which would hand the admin tools to everybody on a dedicated one.
function zBay.isAdmin(player)
    if not isClient() and not isServer() then return true end
    if not player then return false end

    local level = zBay.accessLevel(player)
    return level == "admin" or level == "gm" or level == "moderator"
end

function zBay.log(message)
    print("[zBay] " .. tostring(message))
end

function zBay.warn(message)
    print("[zBay] WARN: " .. tostring(message))
end

function zBay.trace(message)
    if not zBay.Config.verbose then return end
    print("[zBay] " .. tostring(message))
end

-- a handler that throws is just called again next event, so one on a timer can write a stack
-- trace per call into console.txt all night. every repeating handler registers through here:
-- the first few failures are logged with the reason, then the handler takes itself off.
local GUARD_LIMIT = 3

-- registers fn on event behind a pcall, and takes it off after GUARD_LIMIT failures in a row.
-- in a row, not in total: a hiccup should not retire a working handler. four parameters rather
-- than varargs: no vanilla lua forwards ... into pcall, and kahlua is not a lua to assume
-- things about.
function zBay.guard(name, event, fn)
    local failures = 0
    local wrapped

    wrapped = function(a, b, c, d)
        local ok, err = pcall(fn, a, b, c, d)

        if ok then
            failures = 0
            return
        end

        failures = failures + 1
        zBay.warn(name .. " failed: " .. tostring(err))

        if failures >= GUARD_LIMIT then
            zBay.warn(name .. " has failed " .. GUARD_LIMIT
                .. " times in a row and is stopped for the rest of this session")
            event.Remove(wrapped)
        end
    end

    event.Add(wrapped)
    return wrapped
end

-- wall clock, in epoch milliseconds. an auction has to end at the same moment whether the
-- server was up, restarted or asleep, and only a real calendar time means the same thing in
-- two processes. falls back rather than failing.
function zBay.now()
    local ok, ms = pcall(function() return Calendar.getInstance():getTimeInMillis() end)
    if ok and type(ms) == "number" and ms > 0 then return ms end

    return getTimestampMs()
end

-- epoch milliseconds to "YYYY-MM-DD HH:MM:SS UTC". only ever read by a human, so the
-- arithmetic is done here rather than leaning on Calendar's field constants: days-to-civil in
-- its shift-to-March form, where leap years land at the end of the cycle and stop being a
-- special case.
function zBay.stampText(ms)
    local secs = math.floor((tonumber(ms) or 0) / 1000)
    local days = math.floor(secs / 86400)
    local rest = secs - days * 86400

    local z = days + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524)
        - math.floor(doe / 146096)) / 365)
    local year = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local day = doy - math.floor((153 * mp + 2) / 5) + 1
    local month = mp + (mp < 10 and 3 or -9)

    if month <= 2 then year = year + 1 end

    return string.format("%04d-%02d-%02d %02d:%02d:%02d UTC", year, month, day,
        math.floor(rest / 3600), math.floor(rest / 60) % 60, rest % 60)
end

local function zBay_characterName(player)
    local descriptor = player:getDescriptor()
    if not descriptor then return nil end

    local forename = descriptor:getForename() or ""
    local surname = descriptor:getSurname() or ""
    local full = (forename .. " " .. surname):gsub("^%s+", ""):gsub("%s+$", "")

    if full == "" then return nil end
    return full
end

-- every balance, listing and mailbox is keyed by this. the account name on a server, which
-- survives a death; the character's name in singleplayer, where b42 runs the two names
-- together into something that is nobody's.
function zBay.nameOf(player)
    if not player then return nil end

    if not isClient() and not isServer() then
        local character = zBay_characterName(player)
        if character then return character end
    end

    local username = player:getUsername()
    if username and username ~= "" then return username end

    return zBay_characterName(player)
end

-- everything a client sends is a claim. this is the one way a number out of a packet or a
-- file becomes one the mod will do arithmetic on: whole, finite and inside the bounds, or nil.
function zBay.int(value, min, max)
    local n = tonumber(value)
    if not n or n ~= n then return nil end
    if n ~= math.floor(n) then return nil end
    if min and n < min then return nil end
    if max and n > max then return nil end
    return n
end

-- getText on a missing key returns the key, which would print IGUI_zBay_Something in the ui.
function zBay.text(key, fallback)
    local value = getTextOrNull(key)
    if value and value ~= "" then return value end
    return fallback or key
end
