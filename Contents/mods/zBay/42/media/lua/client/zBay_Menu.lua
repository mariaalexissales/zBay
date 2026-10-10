----------
--ESTRAL--
----------

require "zBay_Core"
require "zBay_Rules"
require "zBay_ItemSnap"
require "zBay_ClientState"
require "zBay_Panel"

-- the three right-clicks: the floor opens the market, a mailbox is claimed or emptied, and an
-- item in the inventory can be put up for sale.

zBay_Menu = zBay_Menu or {}

local S = zBay_ClientState

local function zBay_clickedSquare(worldobjects)
    local fetch = ISWorldObjectContextMenu.fetchVars
    if fetch and fetch.clickedSquare then return fetch.clickedSquare end

    local first = worldobjects and worldobjects[1] or nil
    return first and first:getSquare() or nil
end

-- the square with a mailbox on it, out of whatever the click landed on. a mailbox is drawn
-- up the screen from its tile, so the click is as likely to name the tile behind it: every
-- object handed over is looked at, not just the first.
local function zBay_clickedMailbox(worldobjects)
    local sprites = S.sprites()
    if not sprites then return nil end

    for _, object in ipairs(worldobjects or {}) do
        local sprite = object and object.getSprite and object:getSprite()
        local name = sprite and sprite:getName()

        if name and sprites[name] then return object:getSquare() end
    end

    return nil
end

function zBay_Menu.onOpen(playerNum)
    zBay.openPanel(getSpecificPlayer(playerNum))
end

-- the server only believes somebody standing at the mailbox, so a click from across the
-- street walks there first. reach is tested again on arrival: the walk can be cut short.
local function zBay_atBox(playerNum, x, y, z, command, args)
    local player = getSpecificPlayer(playerNum)
    if not player then return end

    local reach = S.config and S.config.mailbox.reach or 2

    if zBay_Rules.near(player, x, y, z, reach) then
        S.send(command, args)
        return
    end

    local square = getCell():getGridSquare(x, y, z)
    local adjacent = square and AdjacentFreeTileFinder.Find(square, player) or nil
    if not adjacent then return end

    ISTimedActionQueue.clear(player)

    local walk = ISWalkToTimedAction:new(player, adjacent)
    walk:setOnComplete(function()
        if zBay_Rules.near(player, x, y, z, reach) then S.send(command, args) end
    end)
    ISTimedActionQueue.add(walk)
end

function zBay_Menu.onSetMailbox(playerNum, x, y, z)
    zBay_atBox(playerNum, x, y, z, "mailSet", { x = x, y = y, z = z })
end

function zBay_Menu.onCollect(playerNum, x, y, z)
    zBay_atBox(playerNum, x, y, z, "mailCollect", { atBox = true })
end

-- the Pre event, because the plain one is skipped inside a safehouse the player has no
-- rights in, and a market that closes at somebody's front door is not much of one.
local function zBay_onPreFill(playerNum, context, worldobjects, test)
    if playerNum ~= 0 then return end

    -- a controller probing for whether there is anything to do here. there always is.
    if test then return ISWorldObjectContextMenu.setTest() end

    context:addOption(getText("IGUI_zBay_Open"), playerNum, zBay_Menu.onOpen)

    -- the hello on the way in can be lost: on a multiplayer client OnCreatePlayer may fire
    -- before there is a player to send it as. without the settings a mailbox is just a tile,
    -- so a right-click is taken as a reason to ask again.
    if not S.config then S.hello() end

    local square = zBay_clickedMailbox(worldobjects)
    if not square then return end

    local x, y, z = square:getX(), square:getY(), square:getZ()

    if S.mail.x == x and S.mail.y == y and S.mail.z == z then
        local option = context:addOption(getText("IGUI_zBay_CollectMail", S.mail.n or 0), playerNum,
            zBay_Menu.onCollect, x, y, z)
        -- greyed, not hidden: an entry that vanishes when the box is empty reads as the
        -- mailbox having stopped being theirs.
        if (S.mail.n or 0) <= 0 then option.notAvailable = true end
    else
        context:addOption(getText("IGUI_zBay_SetMailbox"), playerNum, zBay_Menu.onSetMailbox, x, y, z)
    end
end

function zBay_Menu.onSell(playerNum, itemId)
    zBay.openPanel(getSpecificPlayer(playerNum), "sell", itemId)
end

-- items is whatever was right-clicked: single items, or stacks holding a list of them.
local function zBay_onFillInventory(playerNum, context, items)
    if playerNum ~= 0 then return end

    local actual = ISInventoryPane.getActualItems(items)
    local item = actual and actual[1] or nil
    if not item or not item:isInPlayerInventory() then return end

    -- nothing offered for what would only be refused. the server asks again regardless.
    if zBay_ItemSnap.refusal(item) then return end

    context:addOption(getText("IGUI_zBay_SellThis"), playerNum, zBay_Menu.onSell, item:getID())
end

Events.OnPreFillWorldObjectContextMenu.Add(zBay_onPreFill)
Events.OnFillInventoryObjectContextMenu.Add(zBay_onFillInventory)

-- asked once on the way in, so the mailbox menu knows which sprites count and whose box is
-- whose before the window has ever been opened. OnCreatePlayer, not OnGameStart: the server
-- needs a player to answer.
Events.OnCreatePlayer.Add(function(playerNum)
    if playerNum ~= 0 then return end
    S.hello()
end)
