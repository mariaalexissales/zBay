----------
--ESTRAL--
----------

require "zBay_Core"
require "zBay_Json"
require "zBay_Files"
require "zBay_Config"
require "zBay_State"

if not zBay.isAuthority() then return end

zBay_Backup = zBay_Backup or {}

-- everything zBay owns lives in global mod data, which the engine writes into the world save.
-- that is the whole problem this file exists for:
--
--   a process killed rather than shut down never writes it, so a session's trading is lost
--   a rollback restores the save, and takes every balance back with it
--
-- neither is fixable from inside the save, so this keeps a second copy outside it. reading
-- it back is an admin asking for exactly that, never automatic: a server that quietly chose
-- a file over its own save would be undoing whatever the rollback was for.

local FILE_V = 1

-- what is saved. everything else in the state table is counters the bridge keeps for itself.
local FIELDS = {
    "nextId", "balances", "listings", "mail", "mailboxes", "boxOwners",
    "notices", "ledger", "links",
}

-- the text of the file as it stands on disk, carried since boot so the rotation does not
-- have to read it back before overwriting.
local lastText = nil

-- what zBay_State.changes was when the file was last written, and when that was.
local savedAt = nil
local savedChanges = nil

function zBay_Backup.enabled()
    return zBay_Config.data.backup.enabled == true
end

-- named by world so two of them on one host cannot overwrite each other. the spare is a
-- second .json, because the file api will not write a .bak.
function zBay_Backup.name()
    return "backup_" .. zBay_Files.world() .. ".json"
end

function zBay_Backup.spareName()
    return "backup_" .. zBay_Files.world() .. "_prev.json"
end

-- writes the file. savedAtText is for whoever opens it and is never read back. the previous
-- payload goes to the spare before the main file is touched: a process killed between the two
-- writes, the exact failure this file exists for, leaves the spare whole and only the main
-- file torn, which is what read() is prepared for.
function zBay_Backup.save()
    local data = zBay_State.ensure()
    local now = zBay.now()

    local out = {
        v = FILE_V,
        world = zBay_Files.world(),
        savedAt = now,
        savedAtText = zBay.stampText(now),
    }

    for _, field in ipairs(FIELDS) do out[field] = data[field] end

    local ok, text = pcall(zBay_Json.line, out)
    if not ok or type(text) ~= "string" then
        zBay.warn("could not encode the backup: " .. tostring(text))
        return false
    end

    if lastText then zBay_Files.write(zBay_Backup.spareName(), lastText) end

    if not zBay_Files.write(zBay_Backup.name(), text) then
        zBay.warn("could not write the backup to " .. zBay_Files.shown(zBay_Backup.name()))
        return false
    end

    lastText = text
    savedAt = getTimestampMs()
    savedChanges = zBay_State.changes

    return true
end

-- called once a second by the server's clock. a dedicated server has no save event to hang
-- this on: OnSave is fired by the client's save and nothing in the server's, which writes the
-- world through ServerMap without a word to lua. so the file is kept current by the clock,
-- every backup.minutes, and only when something has changed since it was last written.
function zBay_Backup.tick()
    if not zBay_Backup.enabled() then return end
    if savedChanges == zBay_State.changes then return end

    local every = zBay_Config.data.backup.minutes * 60000
    if savedAt and getTimestampMs() - savedAt < every then return end

    zBay_Backup.save()
end

-- the file, or the spare if the file is gone or unreadable. returns the parsed table, which
-- of the two it came from, and the text it was parsed from.
function zBay_Backup.read()
    for _, name in ipairs({ zBay_Backup.name(), zBay_Backup.spareName() }) do
        local text = zBay_Files.read(name)

        if text then
            local parsed, err = zBay_Json.decode(text)
            if type(parsed) == "table" then return parsed, name, text end

            zBay.warn("the backup at " .. zBay_Files.shown(name) .. " could not be read: " .. tostring(err))
        end
    end

    return nil
end

-- unconditional. nothing calls this on its own: whoever did has decided the file is the truth.
-- a file of the right syntax but the wrong shape is not a backup, and what the world save had
-- is kept rather than replaced with nothing. nextId never goes backwards: an id handed out
-- since the file was written must not be handed out again.
function zBay_Backup.load()
    local parsed, from, text = zBay_Backup.read()
    if not parsed then return false end

    if type(parsed.balances) ~= "table" or type(parsed.listings) ~= "table" then
        zBay.warn("the backup at " .. zBay_Files.shown(from) .. " has no balances or listings, ignoring it")
        return false
    end

    lastText = text

    local data = zBay_State.ensure()

    for _, field in ipairs(FIELDS) do
        if field == "nextId" then
            data.nextId = math.max(data.nextId or 0, zBay.int(parsed.nextId, 0) or 0)
        else
            data[field] = type(parsed[field]) == "table" and parsed[field] or {}
        end
    end

    zBay_State.rebuild()
    zBay_State.touch()

    zBay.warn("restored the market from " .. zBay_Files.shown(from) .. ", written "
        .. zBay.stampText(parsed.savedAt))

    return true
end

-- the old file is read before the first write, so the rotation has its payload rather than
-- throwing it away; nothing is restored from it. then one save at boot: it creates the file
-- on a server that has never had one, and surfaces a permissions problem now rather than at
-- the shutdown it was supposed to cover.
Events.OnInitGlobalModData.Add(function()
    zBay_State.ensure()

    if not zBay_Backup.enabled() then return end

    local _, _, text = zBay_Backup.read()
    lastText = text

    zBay_Backup.save()
end)

-- singleplayer and a hosted game do get a save event, and there it is the best moment there
-- is: the file is written alongside the save it is backing up. a dedicated server never
-- fires it, which is what the tick above is for.
if Events.OnSave then
    zBay.guard("market backup on save", Events.OnSave, function()
        if zBay_Backup.enabled() then zBay_Backup.save() end
    end)
end
