----------
--ESTRAL--
----------

require "zBay_Core"

zBay_Money = zBay_Money or {}

-- money is whole units, always. a price with a fraction in it drifts the first time a fee is
-- taken off it, and a market that loses a cent a sale is one nobody can audit.
--
-- the ceiling is far inside what a double holds exactly. it is there so no total, however it
-- was multiplied up, comes out as something %d prints with an exponent.
zBay_Money.MAX = 2000000000

function zBay_Money.amount(value)
    return zBay.int(value, 1, zBay_Money.MAX)
end

-- 1250000 -> "1,250,000". built from the right, three at a time. %.0f and not %d: a total can
-- pass what %d is promised to hold.
function zBay_Money.group(value)
    local n = math.floor(tonumber(value) or 0)
    local sign = ""

    if n < 0 then
        sign = "-"
        n = -n
    end

    local digits = string.format("%.0f", n)
    local out = {}

    while #digits > 3 do
        table.insert(out, 1, digits:sub(#digits - 2))
        digits = digits:sub(1, #digits - 3)
    end
    table.insert(out, 1, digits)

    return sign .. table.concat(out, ",")
end

-- "$1,250" with a symbol, "1,250 Dollars" without one. the owner picks which by leaving
-- the symbol out.
function zBay_Money.format(value, currency)
    local text = zBay_Money.group(value)

    if currency and currency.symbol and currency.symbol ~= "" then
        return currency.symbol .. text
    end

    if currency and currency.name and currency.name ~= "" then
        return text .. " " .. currency.name
    end

    return text
end

-- rounded down, so a fee can never be more than the owner asked for and a sale of 1 unit at
-- 5% still pays the seller their unit.
function zBay_Money.fee(amount, percent)
    return math.floor((tonumber(amount) or 0) * (tonumber(percent) or 0) / 100)
end

-- biggest first. config hands these over already sorted; a caller that built its own list
-- can lean on this.
function zBay_Money.sorted(denoms)
    local out = {}
    for _, denom in ipairs(denoms or {}) do out[#out + 1] = denom end

    table.sort(out, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        return a.item < b.item
    end)

    return out
end

-- how to make amount out of the denominations, biggest first, in at most maxItems items.
-- returns the parts, what they add up to, and how many items that is. what they add up to
-- can be short of amount twice over: the item cap ran out, or no denomination is small
-- enough for the remainder. the caller only ever moves the figure this hands back.
--
-- have is optional: item -> how many are to hand, for a deposit, where the player's pockets
-- are the limit. left out, every denomination is unlimited, which is a withdrawal.
function zBay_Money.breakdown(amount, denoms, maxItems, have)
    local parts = {}
    local left = math.floor(tonumber(amount) or 0)
    local items = 0
    local paid = 0

    for _, denom in ipairs(denoms or {}) do
        if left <= 0 then break end
        if maxItems and items >= maxItems then break end

        local count = math.floor(left / denom.value)

        if have then count = math.min(count, have[denom.item] or 0) end
        if maxItems then count = math.min(count, maxItems - items) end

        if count > 0 then
            parts[#parts + 1] = { item = denom.item, value = denom.value, count = count }
            items = items + count
            paid = paid + count * denom.value
            left = left - count * denom.value
        end
    end

    return parts, paid, items
end
