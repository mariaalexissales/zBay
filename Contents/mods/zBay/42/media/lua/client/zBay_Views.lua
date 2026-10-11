----------
--ESTRAL--
----------

require "zBay_Core"
require "zBay_Money"
require "zBay_Rules"
require "zBay_ItemSnap"
require "zBay_ClientState"
require "zBay_Theme"

-- the tabs, as data. the window is one shell: a row of tabs, a list in the middle, a strip
-- of controls under it. everything that makes Browse different from Bank is in the entry
-- for it here, so a new tab is a new entry and not a new window.
--
-- an entry has:
--   title     translation key for the tab
--   market    true when its rows are listings, and go stale when the market moves
--   filters   true to show search, category and sort above the list
--   sorts     what the sort box offers
--   head      translation keys for the column headers
--   rows      for a tab whose rows are worked out here rather than asked for
--   watch     a value that, when it changes, means the page should be asked for again
--   cells     a row as the five things a line draws
--   strip     builds the controls under the list
--   picked    called when a row is clicked
--   hint      the line shown over the controls when nothing is selected

zBay_Views = zBay_Views or {}

local S = zBay_ClientState

zBay_Views.order = { "browse", "auctions", "sell", "mine", "mail", "bank" }
zBay_Views.defs = {}

local defs = zBay_Views.defs

local function zBay_number(panel, key)
    return zBay.int(panel:value(key), 1)
end

local function zBay_name(row)
    local name = row.n or row.t or "?"
    if row.c then name = name .. "  (" .. row.c .. "%)" end
    return name
end

local function zBay_ends(view, row)
    local left = S.left(view, row)
    if not left then return nil end

    return zBay_Rules.timeLeft(left) or getText("IGUI_zBay_Ended")
end

local function zBay_selectedLine(row)
    local line = (row.n or "?")
    if row.q and row.q > 1 then line = line .. " x" .. row.q end
    if row.c then line = line .. "  (" .. row.c .. "%)" end
    return line
end

defs.browse = {
    title = "IGUI_zBay_Tab_Browse",
    market = true,
    filters = true,
    sorts = { "new", "low", "high", "name" },
    head = { name = "IGUI_zBay_Col_Item", qty = "IGUI_zBay_Col_Qty", price = "IGUI_zBay_Col_Each",
             who = "IGUI_zBay_Col_Seller" },

    cells = function(row)
        return {
            name = zBay_name(row), qty = row.q, price = S.money(row.p), who = row.s,
            tint = row.mine and zBay_Theme.COL_ME or nil,
        }
    end,

    strip = function(panel)
        panel:addEntry("qty", "IGUI_zBay_Qty", 50, "1", true)
        panel:addButton("buy", "IGUI_zBay_Buy", function(p)
            local row = p.selected
            if not row then return end
            S.send("buy", { id = row.id, qty = zBay_number(p, "qty") or 1 })
        end, true)

        if S.admin then
            panel:addButton("remove", "IGUI_zBay_Remove", function(p)
                if p.selected then S.send("adminRemove", { id = p.selected.id }) end
            end, true)
        end
    end,

    info = function(panel, row)
        local qty = math.min(zBay_number(panel, "qty") or 1, row.q or 1)
        return zBay_selectedLine(row) .. "   " .. getText("IGUI_zBay_Total", S.money((row.p or 0) * qty))
    end,
}

defs.auctions = {
    title = "IGUI_zBay_Tab_Auctions",
    market = true,
    filters = true,
    sorts = { "ending", "new", "low", "high", "name" },
    head = { name = "IGUI_zBay_Col_Item", qty = "IGUI_zBay_Col_Qty", price = "IGUI_zBay_Col_Bid",
             ends = "IGUI_zBay_Col_Ends", who = "IGUI_zBay_Col_Seller" },

    enabled = function()
        return not S.config or S.config.auction.enabled
    end,

    -- the tint: blue is yours to sell, green is yours to lose.
    cells = function(row)
        local price = S.money(row.b or row.sb)
        if (row.nb or 0) > 0 then price = price .. " (" .. row.nb .. ")" end

        return {
            name = zBay_name(row), qty = row.q, price = price, ends = zBay_ends("auctions", row),
            who = row.s,
            tint = (row.top and zBay_Theme.COL_GOOD) or (row.mine and zBay_Theme.COL_ME) or nil,
        }
    end,

    strip = function(panel)
        panel:addEntry("amount", "IGUI_zBay_YourBid", 90, "", true)
        panel:addButton("bid", "IGUI_zBay_Bid", function(p)
            local row = p.selected
            local amount = zBay_number(p, "amount")
            if row and amount then S.send("bid", { id = row.id, amount = amount }) end
        end, true)

        if not S.config or S.config.auction.allowBuyout then
            panel:addButton("buyout", "IGUI_zBay_Buyout", function(p)
                if p.selected and p.selected.bo then S.send("buyout", { id = p.selected.id }) end
            end, true)
        end

        if S.admin then
            panel:addButton("remove", "IGUI_zBay_Remove", function(p)
                if p.selected then S.send("adminRemove", { id = p.selected.id }) end
            end, true)
        end
    end,

    -- the least that would be accepted goes into the box, so one press is a valid bid.
    picked = function(panel, row)
        local least = zBay_Rules.minBid(row, S.config and S.config.auction or nil)
        if least then panel:setValue("amount", string.format("%.0f", least)) end
    end,

    info = function(panel, row)
        local line = zBay_selectedLine(row)
        if row.bo then line = line .. "   " .. getText("IGUI_zBay_BuyoutAt", S.money(row.bo)) end
        if row.top then line = line .. "   " .. getText("IGUI_zBay_YouLead") end
        return line
    end,
}

-- everything the player is carrying that could go on the market, stacked by what looks the
-- same. the stacking is a guess for the list's sake; the server does the real comparison
-- when one is put up. a bag is looked into before the bag itself is judged: a full bag
-- cannot be sold, but everything in it can.
function zBay_Views.scan(player)
    local groups, order = {}, {}

    local currency = {}
    for _, denom in ipairs(S.config and S.config.currency.items or {}) do currency[denom.item] = true end

    local function walk(container, depth)
        local items = container:getItems()

        for i = 0, items:size() - 1 do
            local item = items:get(i)

            if depth < 3 and instanceof(item, "InventoryContainer") then
                local inner = item:getInventory()
                if inner and inner:getItems():size() > 0 then walk(inner, depth + 1) end
            end

            if not currency[item:getFullType()] and not zBay_ItemSnap.refusal(item) then
                local key = zBay_ItemSnap.lightKey(item)
                local group = groups[key]

                if not group then
                    group = {
                        id = "S" .. string.format("%.0f", item:getID()), k = "s",
                        itemId = item:getID(), t = item:getFullType(),
                        n = item:getDisplayName(), q = 0, c = zBay_ItemSnap.condition(item),
                        ids = {},
                    }
                    groups[key] = group
                    order[#order + 1] = group
                end

                group.q = group.q + 1
                group.ids[item:getID()] = true
            end
        end
    end

    walk(player:getInventory(), 0)

    table.sort(order, function(a, b)
        if a.n ~= b.n then return a.n < b.n end
        return a.id < b.id
    end)

    return order
end

defs.sell = {
    title = "IGUI_zBay_Tab_Sell",
    head = { name = "IGUI_zBay_Col_Item", qty = "IGUI_zBay_Col_Have" },

    rows = function(panel)
        return zBay_Views.scan(panel.player)
    end,

    cells = function(row)
        return { name = zBay_name(row), qty = row.q }
    end,

    strip = function(panel)
        local auction = S.config and S.config.auction or nil
        local auctions = auction and auction.enabled

        panel:addEntry("qty", "IGUI_zBay_Qty", 44, "1", true)
        panel:addEntry("price", "IGUI_zBay_Price", 80, "", true)

        if auctions then
            panel:addCombo("kind", nil, 90, {
                { getText("IGUI_zBay_Kind_Fixed"), "f" },
                { getText("IGUI_zBay_Kind_Auction"), "a" },
            })

            local hours = {}
            for _, value in ipairs(auction.durationsHours) do
                hours[#hours + 1] = { getText("IGUI_zBay_Hours", value), value }
            end
            panel:addCombo("hours", nil, 70, hours)

            if auction.allowBuyout then panel:addEntry("buyout", "IGUI_zBay_Buyout", 80, "", true) end
        end

        panel:addButton("list", "IGUI_zBay_List", function(p)
            local row = p.selected
            local price = zBay_number(p, "price")
            if not row or not price then return end

            local kind = p:value("kind") or "f"

            S.send("sell", {
                itemId = row.itemId,
                qty = zBay_number(p, "qty") or 1,
                kind = kind,
                price = price,
                hours = kind == "a" and p:value("hours") or nil,
                buyout = kind == "a" and zBay_number(p, "buyout") or nil,
            })
        end, true)
    end,

    info = function(panel, row)
        local fee = S.config and S.config.fee or 0
        return zBay_selectedLine(row) .. "   " .. getText("IGUI_zBay_FeeNote", fee)
    end,

    hint = function()
        return getText("IGUI_zBay_Hint_Sell")
    end,
}

defs.mine = {
    title = "IGUI_zBay_Tab_Mine",
    market = true,
    sorts = { "new" },
    head = { name = "IGUI_zBay_Col_Item", qty = "IGUI_zBay_Col_Qty", price = "IGUI_zBay_Col_Price",
             ends = "IGUI_zBay_Col_Ends", who = "IGUI_zBay_Col_Kind" },

    cells = function(row)
        local auction = row.k == "a"
        local price = S.money(auction and (row.b or row.sb) or row.p)
        if auction and (row.nb or 0) > 0 then price = price .. " (" .. row.nb .. ")" end

        return {
            name = zBay_name(row), qty = row.q, price = price, ends = zBay_ends("mine", row),
            who = getText(auction and "IGUI_zBay_Kind_Auction" or "IGUI_zBay_Kind_Fixed"),
        }
    end,

    strip = function(panel)
        panel:addButton("cancel", "IGUI_zBay_Cancel", function(p)
            if p.selected then S.send("cancel", { id = p.selected.id }) end
        end, true)
    end,

    hint = function()
        local page = S.page("mine")
        local max = S.config and S.config.maxListings or 0
        return getText("IGUI_zBay_Hint_Mine", page and page.total or 0, max)
    end,
}

defs.mail = {
    title = "IGUI_zBay_Tab_Mail",
    head = { name = "IGUI_zBay_Col_Item", qty = "IGUI_zBay_Col_Qty" },

    watch = function() return S.mail.n end,

    cells = function(row)
        return { name = zBay_name(row), qty = row.q }
    end,

    -- a collect button only where the owner has said a mailbox is not needed. otherwise the
    -- mail is collected at the mailbox, from its right-click menu.
    strip = function(panel)
        if S.config and not S.config.mailbox.required then
            panel:addButton("collect", "IGUI_zBay_Collect", function()
                S.send("mailCollect", { atBox = false })
            end, false)
        end
    end,

    hint = function()
        if S.config and not S.config.mailbox.required then return getText("IGUI_zBay_Hint_MailFree") end
        if S.mail.x then return getText("IGUI_zBay_Hint_MailAt", S.mail.x, S.mail.y) end
        return getText("IGUI_zBay_Hint_MailNone")
    end,
}

-- "2026-10-10 14:03:22 UTC" down to "10-10 14:03". the year and the seconds are not what
-- anybody reads a statement for.
local function zBay_shortStamp(ms)
    return zBay.stampText(ms):sub(6, 16)
end

defs.bank = {
    title = "IGUI_zBay_Tab_Bank",
    head = { name = "IGUI_zBay_Col_Entry", price = "IGUI_zBay_Col_Amount", who = "IGUI_zBay_Col_When" },

    watch = function() return S.balance end,

    cells = function(row)
        local name = getText("IGUI_zBay_Led_" .. tostring(row.code))
        if row.info then name = name .. " - " .. tostring(row.info) end

        local amount = row.n or 0

        return {
            name = name,
            price = (amount > 0 and "+" or "") .. S.money(amount),
            priceTint = amount < 0 and zBay_Theme.COL_BAD or zBay_Theme.COL_GOOD,
            who = zBay_shortStamp(row.at or 0),
        }
    end,

    strip = function(panel)
        panel:addEntry("amount", "IGUI_zBay_Amount", 80, "", true)

        panel:addButton("deposit", "IGUI_zBay_Deposit", function(p)
            local amount = zBay_number(p, "amount")
            if amount then S.send("deposit", { amount = amount }) end
        end, false)

        panel:addButton("depositAll", "IGUI_zBay_DepositAll", function()
            S.send("deposit", {})
        end, false)

        panel:addButton("withdraw", "IGUI_zBay_Withdraw", function(p)
            local amount = zBay_number(p, "amount")
            if amount then S.send("withdraw", { amount = amount }) end
        end, false)

        if S.config and S.config.discord and not S.linked then
            panel:addEntry("code", "IGUI_zBay_LinkCode", 80, "", false)
            panel:addButton("link", "IGUI_zBay_Link", function(p)
                S.send("link", { code = p:value("code") })
            end, false)
        end
    end,

    hint = function()
        local line = getText("IGUI_zBay_Hint_Bank", S.money(S.balance))
        if S.linked then line = line .. "   " .. getText("IGUI_zBay_DiscordLinked") end
        return line
    end,
}

-- a ledger line has no id of its own, and the list selects by id.
function zBay_Views.keyed(view, rows)
    if view ~= "bank" then return rows end

    for index, row in ipairs(rows) do row.id = row.id or ("B" .. index) end
    return rows
end
