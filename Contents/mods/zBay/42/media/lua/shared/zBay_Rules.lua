----------
--ESTRAL--
----------

require "zBay_Core"
require "zBay_Money"

-- the rules both ends agree on. the client reads them to grey a button out before a press it
-- would lose; the server reads the same ones and is the only one whose answer counts.

zBay_Rules = zBay_Rules or {}

-- one listing, however it was stacked. past this a single sale is a server stall waiting for
-- somebody to buy it all at once.
zBay_Rules.MAX_QTY = 500

zBay_Rules.MAX_SEARCH = 40

function zBay_Rules.qty(value)
    return zBay.int(value, 1, zBay_Rules.MAX_QTY)
end

function zBay_Rules.price(value)
    return zBay_Money.amount(value)
end

-- only a length the owner offers. a client that types its own gets the first one, not an
-- auction that runs for a year.
function zBay_Rules.hours(value, auction)
    local wanted = zBay.int(value, 1)
    local choices = auction and auction.durationsHours or {}

    for _, hours in ipairs(choices) do
        if hours == wanted then return hours end
    end

    return choices[1]
end

-- the least the next bid can be. the opening bid is the start price itself; after that each
-- one has to clear the last by the owner's percentage, and by at least one unit whatever the
-- percentage rounds to.
function zBay_Rules.minBid(listing, auction)
    if not listing then return nil end
    if not listing.b then return listing.sb end

    local percent = auction and auction.minIncrementPercent or 5
    local step = math.max(1, math.floor(listing.b * percent / 100 + 0.999999))

    return listing.b + step
end

-- "2d 4h", "3h 12m", "45m", "under 1m". two units at most: a row has no room for more and
-- nobody bids differently over the seconds.
function zBay_Rules.timeLeft(ms)
    local secs = math.floor((tonumber(ms) or 0) / 1000)
    if secs <= 0 then return nil end

    local days = math.floor(secs / 86400)
    local hours = math.floor(secs / 3600) % 24
    local mins = math.floor(secs / 60) % 60

    if days > 0 then return days .. "d " .. hours .. "h" end
    if hours > 0 then return hours .. "h " .. mins .. "m" end
    if mins > 0 then return mins .. "m" end
    return "<1m"
end

function zBay_Rules.boxKey(x, y, z)
    return string.format("%d,%d,%d", math.floor(x), math.floor(y), math.floor(z))
end

-- the mailbox on a square, if there is one. sprites is the owner's list turned into a set.
-- asked by the client to decide what the right-click menu offers and by the server before it
-- believes any of it.
function zBay_Rules.mailboxOn(square, sprites)
    if not square or not sprites then return nil end

    local objects = square:getObjects()
    if not objects then return nil end

    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local sprite = object and object:getSprite()
        local name = sprite and sprite:getName()

        if name and sprites[name] then return object end
    end

    return nil
end

-- chebyshev, the way a player standing diagonally next to something expects it to count.
-- a different floor is never near.
function zBay_Rules.near(player, x, y, z, reach)
    if not player then return false end
    if math.floor(player:getZ()) ~= math.floor(z) then return false end

    local dx = math.abs(math.floor(player:getX()) - math.floor(x))
    local dy = math.abs(math.floor(player:getY()) - math.floor(y))

    return math.max(dx, dy) <= (reach or 2)
end
