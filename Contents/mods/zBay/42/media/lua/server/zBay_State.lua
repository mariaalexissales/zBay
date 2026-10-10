----------
--ESTRAL--
----------

require "zBay_Core"

if not zBay.isAuthority() then return end

zBay_State = zBay_State or {}

local TABLE_NAME = "zBay_State"

local NOTICE_CAP = 20
local LEDGER_CAP = 30

zBay_State.data = zBay_State.data or nil

-- everything below is worked out from the saved table at boot and kept in step after. none of
-- it is saved: a count that could disagree with what it counts is a bug with a save file.
zBay_State.count = zBay_State.count or {}       -- seller -> listings they have up
zBay_State.cats = zBay_State.cats or {}         -- category -> listings in it
zBay_State.total = zBay_State.total or 0
zBay_State.discordOf = zBay_State.discordOf or {}   -- discord id -> username

-- the earliest moment anything on the market ends. the tick compares the clock against this
-- one number and does nothing else until it passes.
zBay_State.nextDue = zBay_State.nextDue or nil

-- global mod data, never player:getModData(): a client's own mod data is its copy and is never
-- pushed up, so it cannot be trusted with a balance. and never transmitted: a client is sent
-- its own balance and the page it asked for, nothing more.
function zBay_State.ensure()
    if not zBay_State.data then
        zBay_State.data = ModData.getOrCreate(TABLE_NAME)
    end

    local data = zBay_State.data

    data.v = data.v or zBay.SCHEMA_V
    -- moves whenever the market does. a client holding an older number asks again.
    data.rev = data.rev or 0
    data.nextId = data.nextId or 0

    data.balances = data.balances or {}
    -- id -> listing. ids are strings: a number key comes back from a save as a double, and
    -- "17" and 17.0 are different keys to everything that looks one up.
    data.listings = data.listings or {}
    -- username -> list of { t = type, snap = , q = , why = , at = }
    data.mail = data.mail or {}
    -- username -> { x, y, z }, and the other way round: "x,y,z" -> list of usernames. a
    -- list, so a po box with twenty slots is the same record as a mailbox with one.
    data.mailboxes = data.mailboxes or {}
    data.boxOwners = data.boxOwners or {}
    -- things a player has to be told that happened while they were away.
    data.notices = data.notices or {}
    data.ledger = data.ledger or {}
    data.links = data.links or {}
    data.pendingLinks = data.pendingLinks or {}
    data.bridge = data.bridge or {}
    data.bridge.inSeq = data.bridge.inSeq or 0
    data.bridge.outSeq = data.bridge.outSeq or 0

    return data
end

-- counts every change to anything that is saved: a listing, a balance, a piece of mail. not
-- saved itself. the backup compares it against the count it last wrote at, so a quiet server
-- writes nothing.
zBay_State.changes = zBay_State.changes or 0

function zBay_State.mark()
    zBay_State.changes = zBay_State.changes + 1
end

function zBay_State.touch()
    local data = zBay_State.ensure()
    data.rev = data.rev + 1
    zBay_State.mark()
    return data.rev
end

function zBay_State.newId()
    local data = zBay_State.ensure()
    data.nextId = data.nextId + 1
    return "L" .. string.format("%.0f", data.nextId)
end

-- ----------------------------------------------------------------------------
-- listings
-- ----------------------------------------------------------------------------

local function zBay_index(listing, by)
    zBay_State.count[listing.s] = (zBay_State.count[listing.s] or 0) + by
    if zBay_State.count[listing.s] <= 0 then zBay_State.count[listing.s] = nil end

    local cat = listing.c or "Item"
    zBay_State.cats[cat] = (zBay_State.cats[cat] or 0) + by
    if zBay_State.cats[cat] <= 0 then zBay_State.cats[cat] = nil end

    zBay_State.total = zBay_State.total + by
end

function zBay_State.listing(id)
    if type(id) ~= "string" then return nil end
    return zBay_State.ensure().listings[id]
end

function zBay_State.add(listing)
    zBay_State.ensure().listings[listing.id] = listing
    zBay_index(listing, 1)
    zBay_State.due(listing.e)
    zBay_State.touch()
end

function zBay_State.remove(id)
    local data = zBay_State.ensure()
    local listing = data.listings[id]
    if not listing then return nil end

    data.listings[id] = nil
    zBay_index(listing, -1)
    zBay_State.touch()

    return listing
end

-- only ever pulls the mark earlier. a listing that ends later than the mark is found when the
-- mark passes and the whole table is walked once.
function zBay_State.due(at)
    if not at then return end
    if not zBay_State.nextDue or at < zBay_State.nextDue then zBay_State.nextDue = at end
end

function zBay_State.rebuild()
    local data = zBay_State.ensure()

    zBay_State.count = {}
    zBay_State.cats = {}
    zBay_State.total = 0
    zBay_State.nextDue = nil
    zBay_State.discordOf = {}

    for _, listing in pairs(data.listings) do
        zBay_index(listing, 1)
        zBay_State.due(listing.e)
    end

    for username, discordId in pairs(data.links) do
        zBay_State.discordOf[discordId] = username
    end
end

-- ----------------------------------------------------------------------------
-- people
-- ----------------------------------------------------------------------------

-- who is connected, by name. getPlayerFromUsername is the client's lookup and answers nil in
-- a server process, so the list is walked instead, and kept for a second: an announcement to
-- twenty watchers is then one walk, not twenty.
local ONLINE_MS = 1000
local online = {}
local onlineAt = nil

local function zBay_scan()
    online = {}
    onlineAt = getTimestampMs()

    local players = getOnlinePlayers()
    if not players then return end

    for i = 0, players:size() - 1 do
        local player = players:get(i)
        local name = player and zBay.nameOf(player)
        if name then online[name] = player end
    end
end

-- the player object for an account, or nil when they are not here. with no server there is
-- one player and the question is whether it is them.
--
-- fresh asks for a new walk rather than the kept one. anything about to put an item into
-- somebody's inventory passes it: a second-old answer can name a player who has just left,
-- and an item handed to them is an item gone.
function zBay_State.playerOf(username, fresh)
    if not username then return nil end

    if isServer() then
        if fresh or not onlineAt or getTimestampMs() - onlineAt > ONLINE_MS then zBay_scan() end
        return online[username]
    end

    local player = getPlayer()
    if player and zBay.nameOf(player) == username then return player end
    return nil
end

local function zBay_ring(list, entry, cap)
    list[#list + 1] = entry
    while #list > cap do table.remove(list, 1) end
end

-- something to tell a player the next time they are looking. capped, oldest out first: a
-- seller back from a month away wants the last twenty sales, not a wall of them.
function zBay_State.note(username, code, a1, a2)
    if not username then return end

    local data = zBay_State.ensure()
    local list = data.notices[username]

    if not list then
        list = {}
        data.notices[username] = list
    end

    zBay_ring(list, { code = code, a1 = a1, a2 = a2, at = zBay.now() }, NOTICE_CAP)
end

function zBay_State.takeNotices(username)
    local data = zBay_State.ensure()
    local list = data.notices[username]

    data.notices[username] = nil
    return list or {}
end

-- the bank statement. what moved, by how much, and over what.
function zBay_State.record(username, code, amount, info)
    if not username then return end

    local data = zBay_State.ensure()
    local list = data.ledger[username]

    if not list then
        list = {}
        data.ledger[username] = list
    end

    zBay_ring(list, { code = code, n = amount, info = info, at = zBay.now() }, LEDGER_CAP)
end

Events.OnInitGlobalModData.Add(function()
    zBay_State.ensure()
    zBay_State.rebuild()
end)
