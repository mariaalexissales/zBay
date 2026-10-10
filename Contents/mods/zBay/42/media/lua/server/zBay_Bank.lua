----------
--ESTRAL--
----------

require "zBay_Core"
require "zBay_Net"
require "zBay_Money"
require "zBay_Config"
require "zBay_State"

if not zBay.isAuthority() then return end

-- balances, and the only two ways currency crosses between a pocket and one. everything the
-- market does with money goes through credit and debit here, so the ledger cannot miss a move.

zBay_Bank = zBay_Bank or {}

-- how many items one deposit or withdrawal may move. a player emptying a truck of loose bills
-- does it in a few presses rather than one frame of the server's time.
zBay_Bank.MAX_ITEMS = 200

function zBay_Bank.balance(username)
    if not username then return 0 end
    return zBay_State.ensure().balances[username] or 0
end

-- tell them, if they are here to be told. a balance only ever travels to its owner.
function zBay_Bank.push(username)
    local player = zBay_State.playerOf(username)
    if not player then return end

    zBay_Net.toClient(player, "balance", { n = zBay_Bank.balance(username) })
end

function zBay_Bank.credit(username, amount, code, info)
    amount = zBay.int(amount, 1)
    if not username or not amount then return false end

    local data = zBay_State.ensure()
    data.balances[username] = (data.balances[username] or 0) + amount

    zBay_State.mark()
    zBay_State.record(username, code or "Credit", amount, info)
    zBay_Bank.push(username)

    return true
end

-- false, with nothing moved, when they do not have it. the one place a balance goes down.
function zBay_Bank.debit(username, amount, code, info)
    amount = zBay.int(amount, 1)
    if not username or not amount then return false end

    local data = zBay_State.ensure()
    local have = data.balances[username] or 0
    if have < amount then return false end

    data.balances[username] = have - amount

    zBay_State.mark()
    zBay_State.record(username, code or "Debit", -amount, info)
    zBay_Bank.push(username)

    return true
end

-- ----------------------------------------------------------------------------
-- pockets
-- ----------------------------------------------------------------------------

-- taken from wherever it sits, bag or pocket, and told to the client from the container it
-- actually left: the removal packet names a container, and naming the wrong one leaves a
-- ghost in the bag on the client.
local function zBay_take(inventory, fullType, count)
    local taken = 0
    local found = inventory:getAllTypeRecurse(fullType)

    for i = 0, found:size() - 1 do
        if taken >= count then break end

        local item = found:get(i)
        local container = item and item:getContainer()

        if container then
            container:Remove(item)
            if isServer() then sendRemoveItemFromContainer(container, item) end
            taken = taken + 1
        end
    end

    return taken
end

-- one at a time, and only while it fits. returns how many went in.
local function zBay_give(player, fullType, count)
    local inventory = player:getInventory()
    local given = 0

    for _ = 1, count do
        local item = instanceItem(fullType)
        if not item then break end
        if not inventory:hasRoomFor(player, item) then break end

        inventory:AddItem(item)
        if isServer() then sendAddItemToContainer(inventory, item) end

        given = given + 1
    end

    return given
end

-- amount is how much to put in, or nil for everything they are carrying. returns what was
-- actually banked, which is the only figure credited: the count comes from the items that
-- left the inventory, never from what the client said it had.
function zBay_Bank.deposit(player, amount)
    local username = zBay.nameOf(player)
    if not username then return 0 end

    local denoms = zBay_Config.data.currency.items
    local inventory = player:getInventory()

    local have = {}
    local total = 0
    for _, denom in ipairs(denoms) do
        have[denom.item] = inventory:getItemCountRecurse(denom.item)
        total = total + have[denom.item] * denom.value
    end

    if total <= 0 then return 0 end

    local parts = zBay_Money.breakdown(amount or total, denoms, zBay_Bank.MAX_ITEMS, have)
    local banked = 0

    for _, part in ipairs(parts) do
        banked = banked + zBay_take(inventory, part.item, part.count) * part.value
    end

    if banked > 0 then zBay_Bank.credit(username, banked, "Deposit") end

    return banked
end

-- returns what was paid out. short of what was asked when it would not all fit, when the item
-- cap ran out, or when no note is small enough for the tail; the rest never left the bank.
function zBay_Bank.withdraw(player, amount)
    local username = zBay.nameOf(player)
    amount = zBay.int(amount, 1)
    if not username or not amount then return 0 end

    amount = math.min(amount, zBay_Bank.balance(username))
    if amount <= 0 then return 0 end

    local parts = zBay_Money.breakdown(amount, zBay_Config.data.currency.items, zBay_Bank.MAX_ITEMS)
    local paid = 0

    for _, part in ipairs(parts) do
        local given = zBay_give(player, part.item, part.count)
        paid = paid + given * part.value

        -- a note that would not fit means nothing lighter is worth trying after it in the
        -- same press: the inventory is full.
        if given < part.count then break end
    end

    if paid > 0 then zBay_Bank.debit(username, paid, "Withdraw") end

    return paid
end

-- the last few lines of the statement, newest first, for the bank tab.
function zBay_Bank.statement(username)
    local list = zBay_State.ensure().ledger[username] or {}
    local out = {}

    for i = #list, 1, -1 do out[#out + 1] = list[i] end

    return out
end
