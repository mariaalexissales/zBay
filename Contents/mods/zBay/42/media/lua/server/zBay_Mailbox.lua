----------
--ESTRAL--
----------

require "zBay_Core"
require "zBay_Net"
require "zBay_Rules"
require "zBay_ItemSnap"
require "zBay_Config"
require "zBay_State"
require "zBay_Notify"

if not zBay.isAuthority() then return end

-- every item the market hands to a player comes through here: a purchase, an auction won,
-- stock coming back from a listing that was cancelled or ran out.
--
-- an item is put straight into the inventory only while the engine says it fits. whatever
-- does not, and everything for somebody who is not online, becomes mail. mail is a list on
-- the server, not items in the mailbox tile's own container: that container holds five,
-- anybody walking past can empty it, and the server cannot put an item into a chunk that
-- is not loaded. the tile is where the mail is asked for, not where it is kept, which is
-- why picking a mailbox up or flattening it loses nothing.

zBay_Mailbox = zBay_Mailbox or {}

-- how many items one collection hands over. the rest is still there for the next press.
zBay_Mailbox.GIVE_CAP = 60

local function zBay_mailOf(username, create)
    local data = zBay_State.ensure()
    local list = data.mail[username]

    if not list and create then
        list = {}
        data.mail[username] = list
    end

    return list
end

function zBay_Mailbox.count(username)
    local total = 0
    for _, entry in ipairs(zBay_mailOf(username) or {}) do total = total + entry.q end
    return total
end

function zBay_Mailbox.summary(username)
    local box = zBay_State.ensure().mailboxes[username]

    return {
        n = zBay_Mailbox.count(username),
        x = box and box.x or nil,
        y = box and box.y or nil,
        z = box and box.z or nil,
    }
end

function zBay_Mailbox.sync(username)
    local player = zBay_State.playerOf(username)
    if not player then return end

    zBay_Net.toClient(player, "mail", zBay_Mailbox.summary(username))
end

-- what the mailbox tab lists.
function zBay_Mailbox.rows(username)
    local rows = {}

    for index, entry in ipairs(zBay_mailOf(username) or {}) do
        rows[#rows + 1] = { id = "M" .. index, k = "m", t = entry.t, n = entry.n, q = entry.q, c = entry.cp }
    end

    return rows
end

-- into the queue. identical items stack onto the entry already waiting, so fifty nails
-- bought five at a time are one line and not ten.
function zBay_Mailbox.push(username, fullType, snap, qty, name, cond)
    if not username or not qty or qty <= 0 then return end

    local list = zBay_mailOf(username, true)

    zBay_State.mark()

    for _, entry in ipairs(list) do
        if entry.t == fullType and zBay_ItemSnap.same(entry.snap, snap) then
            entry.q = entry.q + qty
            return
        end
    end

    list[#list + 1] = { t = fullType, snap = snap, q = qty, n = name or fullType, cp = cond, at = zBay.now() }
end

-- builds and hands over up to qty of one thing, stopping at the first that will not fit or
-- cannot be built. returns how many made it.
function zBay_Mailbox.give(player, fullType, snap, qty)
    local inventory = player:getInventory()
    local given = 0

    for _ = 1, qty do
        local item = zBay_ItemSnap.create(fullType, snap)
        if not item then break end
        if not inventory:hasRoomFor(player, item) then break end

        inventory:AddItem(item)
        if isServer() then sendAddItemToContainer(inventory, item) end

        given = given + 1
    end

    return given
end

-- the one way an item reaches a player. returns how many went into the inventory and how
-- many went to mail; the two always add up to qty, so nothing is ever dropped between them.
function zBay_Mailbox.deliver(username, fullType, snap, qty, name, cond)
    local given = 0
    -- a fresh look at who is online: this is about to put an item in their hands.
    local player = zBay_State.playerOf(username, true)

    if player and zBay_Config.data.mailbox.deliverToInventory then
        given = zBay_Mailbox.give(player, fullType, snap, math.min(qty, zBay_Mailbox.GIVE_CAP))
    end

    local queued = qty - given

    if queued > 0 then
        zBay_Mailbox.push(username, fullType, snap, queued, name, cond)
        zBay_Notify.tell(username, "Mail", name or fullType, nil)
        zBay_Mailbox.sync(username)
    end

    return given, queued
end

-- what the debug menu's test mail is made of: a stack on one line, something with a
-- condition, and enough weight that one collection cannot carry all of it.
zBay_Mailbox.TEST_MAIL = {
    { "Base.Nails", 50 },
    { "Base.Axe", 1 },
    { "Base.Log", 6 },
}

-- dummy mail, for trying the mailbox out without a second player to buy from. queued and
-- never handed straight over: collecting is the thing being tried. each line is announced
-- the way real mail is, so the toast and the discord message are tried with it. returns how
-- many items.
function zBay_Mailbox.sendTest(username)
    if not username then return 0 end

    local queued = 0

    for _, entry in ipairs(zBay_Mailbox.TEST_MAIL) do
        local fullType, count = entry[1], entry[2]
        local item = instanceItem(fullType)
        local snap = item and zBay_ItemSnap.capture(item) or nil

        -- a type this version of the game has dropped is left out, not an error.
        if snap then
            local name = item:getDisplayName() or fullType

            zBay_Mailbox.push(username, fullType, snap, count, name, zBay_ItemSnap.condition(item))
            zBay_Notify.tell(username, "Mail", name, nil)
            queued = queued + count
        end
    end

    if queued > 0 then zBay_Mailbox.sync(username) end

    return queued
end

-- ----------------------------------------------------------------------------
-- the tile
-- ----------------------------------------------------------------------------

local function zBay_release(data, username)
    local box = data.mailboxes[username]
    if not box then return end

    local key = zBay_Rules.boxKey(box.x, box.y, box.z)
    local owners = data.boxOwners[key]

    if owners then
        for i = #owners, 1, -1 do
            if owners[i] == username then table.remove(owners, i) end
        end
        if #owners == 0 then data.boxOwners[key] = nil end
    end

    data.mailboxes[username] = nil
end

-- is there still a mailbox where this player said theirs was. nil square is a chunk that is
-- not loaded, which for somebody standing next to it means it is not there.
local function zBay_boxStands(box)
    local square = getCell():getGridSquare(box.x, box.y, box.z)
    return zBay_Rules.mailboxOn(square, zBay_Config.data.mailbox.sprites) ~= nil
end

-- claims the mailbox on a tile. the client drew the menu entry, so none of what it says about
-- the tile is believed: the sprite, the distance and the owner are all looked up again here.
function zBay_Mailbox.set(player, x, y, z)
    local username = zBay.nameOf(player)
    x, y, z = zBay.int(x), zBay.int(y), zBay.int(z, -32, 32)
    if not username or not x or not y or not z then return false, "Invalid" end

    local config = zBay_Config.data.mailbox
    if not zBay_Rules.near(player, x, y, z, config.reach) then return false, "TooFar" end

    local box = { x = x, y = y, z = z }
    if not zBay_boxStands(box) then return false, "NotMailbox" end

    local data = zBay_State.ensure()
    local key = zBay_Rules.boxKey(x, y, z)
    local owners = data.boxOwners[key] or {}

    for _, owner in ipairs(owners) do
        if owner == username then return true, "MailboxSet" end
    end

    -- one owner to a home mailbox. a po box is this same test against a bigger number.
    if #owners >= 1 then return false, "Taken" end

    zBay_release(data, username)

    owners = data.boxOwners[key] or {}
    owners[#owners + 1] = username
    data.boxOwners[key] = owners
    data.mailboxes[username] = box
    zBay_State.mark()

    zBay_Mailbox.sync(username)

    return true, "MailboxSet"
end

-- hands over what fits. atBox is true when this came from right-clicking the mailbox, false
-- from the window, which only counts when the owner has said a mailbox is not required.
function zBay_Mailbox.collect(player, atBox)
    local username = zBay.nameOf(player)
    if not username then return false, "Invalid" end

    local config = zBay_Config.data.mailbox

    if config.required or atBox then
        local box = zBay_State.ensure().mailboxes[username]

        if not box then return false, "NoMailbox" end
        if not zBay_Rules.near(player, box.x, box.y, box.z, config.reach) then return false, "TooFar" end
        if not zBay_boxStands(box) then return false, "MailboxGone" end
    end

    local list = zBay_mailOf(username)
    if not list or #list == 0 then return false, "NoMail" end

    local given = 0

    for _, entry in ipairs(list) do
        if given >= zBay_Mailbox.GIVE_CAP then break end

        local got = zBay_Mailbox.give(player, entry.t, entry.snap,
            math.min(entry.q, zBay_Mailbox.GIVE_CAP - given))

        entry.q = entry.q - got
        given = given + got
        -- no break on a short one: a rifle that will not fit says nothing about the box of
        -- nails queued behind it.
    end

    -- rebuilt rather than removed from mid-loop, so the list never has a hole in it.
    local kept = {}
    for _, entry in ipairs(list) do
        if entry.q > 0 then kept[#kept + 1] = entry end
    end
    zBay_State.ensure().mail[username] = #kept > 0 and kept or nil
    if given > 0 then zBay_State.mark() end

    zBay_Mailbox.sync(username)

    local left = zBay_Mailbox.count(username)
    if given == 0 then return false, "NoRoom", left end

    -- how many are still waiting travels in the mail packet sent just above.
    return true, left > 0 and "CollectedSome" or "Collected", given
end
