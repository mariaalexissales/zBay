----------
--ESTRAL--
----------

require "zBay_Core"
require "zBay_Money"
require "zBay_Rules"
require "zBay_ItemSnap"
require "zBay_Config"
require "zBay_State"
require "zBay_Bank"
require "zBay_Mailbox"
require "zBay_Notify"

if not zBay.isAuthority() then return end

-- listings: putting one up, buying from one, taking one down, and answering "what is for
-- sale" a page at a time.
--
-- every function that changes anything returns ok, code, a1, a2. code is the tail of a
-- translation key and the same word whether the caller is a player's window or, later, a
-- discord command, so there is one set of reasons a thing can fail and one place they are
-- decided. a1 is a count or a name and a2 is always money, which is what lets the client
-- print the second in whatever the currency is.

zBay_Market = zBay_Market or {}

local HOUR_MS = 3600000

-- looked up when called: the bridge requires this file's neighbours and loads after it.
local function zBay_emit(kind, payload)
    if zBay_Bridge and zBay_Bridge.emit then zBay_Bridge.emit(kind, payload) end
end

-- ----------------------------------------------------------------------------
-- selling
-- ----------------------------------------------------------------------------

local function zBay_isCurrency(fullType)
    for _, denom in ipairs(zBay_Config.data.currency.items) do
        if denom.item == fullType then return true end
    end
    return false
end

local function zBay_category(item)
    local category = item:getDisplayCategory()
    if not category or category == "" then category = item:getCategory() end
    if not category or category == "" then category = "Item" end
    return category
end

-- the item the player picked, then every other one they hold that is the same in every way
-- that is kept, up to qty. the client grouped its list by a rough key; this is the real test.
local function zBay_matching(inventory, base, snap, qty)
    local out = { base }
    if qty <= 1 then return out end

    local found = inventory:getAllTypeRecurse(base:getFullType())

    for i = 0, found:size() - 1 do
        if #out >= qty then break end

        local item = found:get(i)

        if item ~= base and not zBay_ItemSnap.refusal(item) then
            local other = zBay_ItemSnap.capture(item)
            if other and zBay_ItemSnap.same(snap, other) then out[#out + 1] = item end
        end
    end

    return out
end

-- args: itemId, qty, kind ("f" fixed or "a" auction), price (each, or the opening bid),
-- buyout and hours for an auction.
function zBay_Market.sell(player, args)
    local username = zBay.nameOf(player)
    if not username or type(args) ~= "table" then return false, "Invalid" end

    local config = zBay_Config.data
    local kind = args.kind == "a" and "a" or "f"

    local itemId = zBay.int(args.itemId)
    local qty = zBay_Rules.qty(args.qty)
    local price = zBay_Rules.price(args.price)
    if not itemId or not qty or not price then return false, "Invalid" end

    if kind == "a" and not config.auction.enabled then return false, "NoAuctions" end

    local buyout = nil
    if kind == "a" and config.auction.allowBuyout and args.buyout ~= nil then
        buyout = zBay_Rules.price(args.buyout)
        -- a buyout at or under the opening bid is a fixed price wearing a hat.
        if not buyout or buyout <= price then return false, "BuyoutLow" end
    end

    if (zBay_State.count[username] or 0) >= config.market.maxListingsPerPlayer then
        return false, "TooMany", config.market.maxListingsPerPlayer
    end

    local inventory = player:getInventory()
    local base = inventory:getItemWithIDRecursiv(itemId)
    if not base then return false, "ItemGone" end

    local refused = zBay_ItemSnap.refusal(base)
    if refused then return false, refused end

    local fullType = base:getFullType()
    local category = zBay_category(base)

    if zBay_isCurrency(fullType) then return false, "Currency" end
    if config.blacklist.items[fullType] or config.blacklist.categories[category] then
        return false, "Blacklisted"
    end

    -- the gate. past this line, rebuilding the item for a buyer has already worked once.
    local snap, reason = zBay_ItemSnap.verify(base)
    if not snap then return false, reason or "State" end

    -- read while it is still in a container. some of these answer differently once it is not.
    local name = base:getDisplayName() or fullType
    local cond = zBay_ItemSnap.condition(base)

    local items = zBay_matching(inventory, base, snap, qty)
    local taken = 0

    for _, item in ipairs(items) do
        local container = item:getContainer()

        if container then
            container:Remove(item)
            if isServer() then sendRemoveItemFromContainer(container, item) end
            taken = taken + 1
        end
    end

    if taken == 0 then return false, "ItemGone" end

    local now = zBay.now()
    local hours = kind == "a" and zBay_Rules.hours(args.hours, config.auction) or config.market.listingHours

    local listing = {
        id = zBay_State.newId(),
        k = kind,
        s = username,
        t = fullType,
        n = name,
        -- lowered once here rather than on every search.
        ln = string.lower(name),
        c = category,
        cp = cond,
        q = taken,
        snap = snap,
        at = now,
        e = now + hours * HOUR_MS,
    }

    if kind == "a" then
        listing.sb = price
        listing.bo = buyout
        listing.nb = 0
    else
        listing.p = price
    end

    zBay_State.add(listing)

    zBay_emit(kind == "a" and "auctionStart" or "listing", {
        id = listing.id, item = name, type = fullType, qty = taken, price = price,
        buyout = buyout, seller = username, ends = listing.e,
    })

    zBay.trace(username .. " listed " .. taken .. " " .. fullType .. " as " .. listing.id)

    -- fewer than asked is not a failure: the client's stack was a guess at what matched.
    return true, taken < qty and "ListedSome" or "Listed", taken
end

-- ----------------------------------------------------------------------------
-- buying and taking down
-- ----------------------------------------------------------------------------

-- player is optional. only the buyer's name is needed to move money and queue mail, which is
-- what lets this be called for somebody who is not standing in the world.
function zBay_Market.buy(username, args)
    if not username or type(args) ~= "table" then return false, "Invalid" end

    local listing = zBay_State.listing(args.id)
    if not listing or listing.k ~= "f" then return false, "Gone" end
    if listing.s == username then return false, "OwnListing" end
    if listing.e <= zBay.now() then return false, "Gone" end

    local qty = zBay_Rules.qty(args.qty or 1)
    if not qty then return false, "Invalid" end
    if qty > listing.q then return false, "NotEnough", listing.q end

    local total = listing.p * qty

    if not zBay_Bank.debit(username, total, "Buy", listing.n) then return false, "NoFunds", nil, total end

    local net = total - zBay_Money.fee(total, zBay_Config.data.market.feePercent)
    if net > 0 then zBay_Bank.credit(listing.s, net, "Sale", listing.n) end

    listing.q = listing.q - qty

    if listing.q <= 0 then
        zBay_State.remove(listing.id)
    else
        zBay_State.touch()
    end

    zBay_Mailbox.deliver(username, listing.t, listing.snap, qty, listing.n, listing.cp)
    zBay_Notify.tell(listing.s, "Sold", listing.n, net)

    zBay_emit("sale", {
        id = listing.id, item = listing.n, type = listing.t, qty = qty, price = total,
        seller = listing.s, buyer = username,
    })

    return true, "Bought", qty, total
end

-- what is left of a listing goes back to whoever put it up, through the same door as a
-- purchase, so stock coming home obeys the same weight rule.
local function zBay_returnStock(listing, code)
    zBay_State.remove(listing.id)
    zBay_Mailbox.deliver(listing.s, listing.t, listing.snap, listing.q, listing.n, listing.cp)

    if code then zBay_Notify.tell(listing.s, code, listing.n, nil) end
end

function zBay_Market.cancel(username, args, asAdmin)
    if not username or type(args) ~= "table" then return false, "Invalid" end

    local listing = zBay_State.listing(args.id)
    if not listing then return false, "Gone" end
    if listing.s ~= username and not asAdmin then return false, "NotYours" end

    if listing.k == "a" and listing.bd then
        -- a seller who could pull a lot once the bidding went badly would do exactly that.
        if not asAdmin then return false, "HasBids" end

        zBay_Bank.credit(listing.bd, listing.b, "BidRefund", listing.n)
        zBay_Notify.tell(listing.bd, "BidReturned", listing.n, listing.b)
    end

    zBay_returnStock(listing, listing.s ~= username and "Removed" or nil)

    return true, "Cancelled"
end

-- a fixed listing that ran its time. called by the tick, never by a player.
function zBay_Market.expire(listing)
    zBay_returnStock(listing, "Expired")
end

-- ----------------------------------------------------------------------------
-- asking what is for sale
-- ----------------------------------------------------------------------------

local function zBay_shownPrice(listing)
    if listing.k == "a" then return listing.b or listing.sb end
    return listing.p
end

-- every comparison ends on the id, so two listings never compare equal: the engine's sort
-- throws on a comparator that cannot make its mind up.
local SORTS = {
    new = function(a, b)
        if a.at ~= b.at then return a.at > b.at end
        return a.id > b.id
    end,
    low = function(a, b)
        local pa, pb = zBay_shownPrice(a), zBay_shownPrice(b)
        if pa ~= pb then return pa < pb end
        return a.id < b.id
    end,
    high = function(a, b)
        local pa, pb = zBay_shownPrice(a), zBay_shownPrice(b)
        if pa ~= pb then return pa > pb end
        return a.id < b.id
    end,
    ending = function(a, b)
        if a.e ~= b.e then return a.e < b.e end
        return a.id < b.id
    end,
    name = function(a, b)
        if a.ln ~= b.ln then return a.ln < b.ln end
        return a.id < b.id
    end,
}

-- sorted lists of listings, kept until the market next moves. a page turn, a second player
-- on the same tab and a search inside a category all reuse one sort.
local cache = { rev = -1, lists = {} }

local VIEW_KIND = { browse = "f", auctions = "a" }

local function zBay_sorted(view, category, sort)
    local data = zBay_State.ensure()

    if cache.rev ~= data.rev then cache = { rev = data.rev, lists = {} } end

    local key = view .. "|" .. (category or "") .. "|" .. sort
    local list = cache.lists[key]
    if list then return list end

    local kind = VIEW_KIND[view]
    list = {}

    for _, listing in pairs(data.listings) do
        if listing.k == kind and (not category or listing.c == category) then
            list[#list + 1] = listing
        end
    end

    table.sort(list, SORTS[sort])
    cache.lists[key] = list

    return list
end

local function zBay_mine(username, sort)
    local list = {}

    for _, listing in pairs(zBay_State.ensure().listings) do
        if listing.s == username then list[#list + 1] = listing end
    end

    table.sort(list, SORTS[sort])
    return list
end

-- the listing as a client sees it. no snapshot, no lowered name: a row is what fits on a row.
-- time is sent as how long is left, not when it ends, so the client's own clock being wrong
-- does not move an auction's end.
function zBay_Market.row(listing, viewer, now)
    return {
        id = listing.id,
        k = listing.k,
        t = listing.t,
        n = listing.n,
        q = listing.q,
        c = listing.cp,
        s = listing.s,
        p = listing.p,
        sb = listing.sb,
        b = listing.b,
        bo = listing.bo,
        nb = listing.nb,
        left = listing.e - now,
        mine = listing.s == viewer or nil,
        top = (listing.bd ~= nil and listing.bd == viewer) or nil,
    }
end

local function zBay_categories()
    local out = {}
    for category in pairs(zBay_State.cats) do out[#out + 1] = category end
    table.sort(out)
    return out
end

-- args: view, cat, q, sort, page. returns the reply to send as it stands.
function zBay_Market.query(viewer, args)
    args = type(args) == "table" and args or {}

    local view = args.view
    if view ~= "auctions" and view ~= "mine" then view = "browse" end

    local sort = SORTS[args.sort] and args.sort or "new"
    local category = type(args.cat) == "string" and args.cat ~= "" and args.cat or nil

    local list
    if view == "mine" then
        list = zBay_mine(viewer, sort)
    else
        list = zBay_sorted(view, category, sort)
    end

    -- plain find, so a search for "(" or "%" is a search and not a broken pattern.
    local search = type(args.q) == "string" and string.lower(args.q:sub(1, zBay_Rules.MAX_SEARCH)) or ""
    if search ~= "" then
        local matched = {}
        for _, listing in ipairs(list) do
            if listing.ln:find(search, 1, true) then matched[#matched + 1] = listing end
        end
        list = matched
    end

    local size = zBay_Config.data.market.pageSize
    local pages = math.max(1, math.floor((#list + size - 1) / size))
    local page = math.min(zBay.int(args.page, 1) or 1, pages)

    local now = zBay.now()
    local rows = {}

    for i = (page - 1) * size + 1, math.min(page * size, #list) do
        rows[#rows + 1] = zBay_Market.row(list[i], viewer, now)
    end

    return {
        view = view,
        rows = rows,
        total = #list,
        page = page,
        pages = pages,
        rev = zBay_State.ensure().rev,
        cats = view ~= "mine" and zBay_categories() or nil,
    }
end
