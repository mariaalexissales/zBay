----------
--ESTRAL--
----------

require "zBay_Core"
require "zBay_Money"
require "zBay_Rules"
require "zBay_Config"
require "zBay_State"
require "zBay_Bank"
require "zBay_Mailbox"
require "zBay_Notify"
require "zBay_Market"

if not zBay.isAuthority() then return end

-- bidding, and everything that ends on a clock.
--
-- a bid is paid when it is placed: the amount leaves the bidder's bank and sits with the lot.
-- being outbid gives it straight back. so nobody can win with money they have since spent,
-- and settling an auction never has to ask whether the winner can afford it.

zBay_Auction = zBay_Auction or {}

local MINUTE_MS = 60000

-- how many listings one pass closes. a server back from a week off has a backlog, and it is
-- worked through over a few seconds rather than in the frame it boots on.
local SETTLE_CAP = 40

local function zBay_emit(kind, payload)
    if zBay_Bridge and zBay_Bridge.emit then zBay_Bridge.emit(kind, payload) end
end

-- the lot changes hands. the price is already out of the winner's bank by the time this runs.
local function zBay_finish(listing, winner, price)
    zBay_State.remove(listing.id)

    local net = price - zBay_Money.fee(price, zBay_Config.data.market.feePercent)
    if net > 0 then zBay_Bank.credit(listing.s, net, "AuctionSale", listing.n) end

    zBay_Mailbox.deliver(winner, listing.t, listing.snap, listing.q, listing.n, listing.cp)

    zBay_Notify.tell(listing.s, "AuctionSold", listing.n, net)
    zBay_Notify.tell(winner, "Won", listing.n, price)

    zBay_emit("auctionEnd", {
        id = listing.id, item = listing.n, type = listing.t, qty = listing.q, price = price,
        seller = listing.s, winner = winner, bids = listing.nb,
    })
end

-- time is up. a lot with a bid on it goes to the bidder; one without goes home.
function zBay_Auction.settle(listing)
    if listing.bd then
        zBay_finish(listing, listing.bd, listing.b)
        return
    end

    zBay_State.remove(listing.id)
    zBay_Mailbox.deliver(listing.s, listing.t, listing.snap, listing.q, listing.n, listing.cp)
    zBay_Notify.tell(listing.s, "NoBids", listing.n, nil)

    zBay_emit("auctionEnd", {
        id = listing.id, item = listing.n, type = listing.t, qty = listing.q,
        seller = listing.s, bids = 0,
    })
end

-- takes amount for the lot from username, giving back whatever the last bidder had in. when
-- the last bidder is the same person only the difference moves, so raising your own bid does
-- not need the whole of the new one free on top of the old.
local function zBay_escrow(listing, username, amount, code)
    local held = listing.bd == username and listing.b or 0
    local need = amount - held

    if need > 0 and not zBay_Bank.debit(username, need, code, listing.n) then return false, need end

    if listing.bd and listing.bd ~= username then
        zBay_Bank.credit(listing.bd, listing.b, "BidRefund", listing.n)
        zBay_Notify.tell(listing.bd, "Outbid", listing.n, listing.b)
    end

    return true
end

-- the auction a bid or a buyout is for, or nil and why. one that has ended but not been swept
-- is gone already: the tick settles it for whoever was ahead at the bell.
local function zBay_open(username, args)
    if not username or type(args) ~= "table" then return nil, "Invalid" end

    local listing = zBay_State.listing(args.id)
    if not listing or listing.k ~= "a" then return nil, "Gone" end
    if listing.s == username then return nil, "OwnListing" end
    if listing.e <= zBay.now() then return nil, "Gone" end

    return listing
end

function zBay_Auction.buyout(username, args)
    local listing, reason = zBay_open(username, args)
    if not listing then return false, reason end
    if not listing.bo then return false, "NoBuyout" end

    local ok, need = zBay_escrow(listing, username, listing.bo, "Buyout")
    if not ok then return false, "NoFunds", nil, need end

    zBay_finish(listing, username, listing.bo)

    return true, "BoughtOut", listing.q, listing.bo
end

-- offering the buyout price or more is buying it out: nobody should pay over the odds for a
-- lot that had a price on it. a bid in the last moments buys everybody else that long to
-- answer it. the end only ever moves later, so the mark the tick waits on is still at or
-- before it.
function zBay_Auction.bid(username, args)
    local listing, reason = zBay_open(username, args)
    if not listing then return false, reason end

    local config = zBay_Config.data.auction
    local amount = zBay_Money.amount(args.amount)
    if not amount then return false, "Invalid" end

    local least = zBay_Rules.minBid(listing, config)
    if amount < least then return false, "BidLow", nil, least end

    if listing.bo and amount >= listing.bo then return zBay_Auction.buyout(username, args) end

    local ok, need = zBay_escrow(listing, username, amount, "Bid")
    if not ok then return false, "NoFunds", nil, need end

    listing.b = amount
    listing.bd = username
    listing.nb = (listing.nb or 0) + 1

    local now = zBay.now()
    local grace = config.antiSnipeMinutes * MINUTE_MS
    if grace > 0 and listing.e - now < grace then listing.e = now + grace end

    zBay_State.touch()

    zBay_emit("bid", {
        id = listing.id, item = listing.n, type = listing.t, price = amount,
        bidder = username, bids = listing.nb, ends = listing.e,
    })

    return true, "BidPlaced", nil, amount
end

-- one number compared against the clock, and nothing else, until something is actually due.
-- then the table is walked once: what has ended is closed, and the earliest of the rest
-- becomes the next mark. the ended are collected first, since closing a listing removes it
-- from the table being walked. past SETTLE_CAP the rest are still owed and due at once, so
-- the next pass picks up where this one stopped. each is closed behind a pcall: one bad
-- listing should cost itself, not every auction queued behind it.
function zBay_Auction.tick()
    local due = zBay_State.nextDue
    if not due then return end

    local now = zBay.now()
    if now < due then return end

    local ended = {}
    local nextDue = nil

    for _, listing in pairs(zBay_State.ensure().listings) do
        if listing.e <= now then
            if #ended < SETTLE_CAP then
                ended[#ended + 1] = listing
            else
                nextDue = now
            end
        elseif not nextDue or listing.e < nextDue then
            nextDue = listing.e
        end
    end

    zBay_State.nextDue = nextDue

    for _, listing in ipairs(ended) do
        local ok, err = pcall(function()
            if listing.k == "a" then
                zBay_Auction.settle(listing)
            else
                zBay_Market.expire(listing)
            end
        end)

        if not ok then zBay.warn("could not close " .. tostring(listing.id) .. ": " .. tostring(err)) end
    end
end
