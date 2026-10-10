----------
--ESTRAL--
----------

require "zBay_Core"
require "zBay_Net"
require "zBay_State"

if not zBay.isAuthority() then return end

-- telling one player that something happened to them: an item sold, a bid beaten, mail
-- waiting. most of these land while the player is somewhere else or logged out, so there are
-- three ways out and this picks: a toast if they are here, a stored notice if they are not,
-- and a line for discord either way when they have linked an account.

zBay_Notify = zBay_Notify or {}

-- good news is green over the player's head and bad news red. anything not named is good.
local BAD = { Outbid = true, NoBids = true, Expired = true, Removed = true, BidReturned = true }

-- code is the tail of a translation key. by convention a1 is an item's name and a2 an amount
-- of money, which is what lets the client format the second in whatever the currency is now.
function zBay_Notify.tell(username, code, a1, a2)
    if not username then return end

    local player = zBay_State.playerOf(username)

    if player then
        zBay_Net.toClient(player, "toast", { code = code, a1 = a1, a2 = a2, good = not BAD[code] })
    else
        zBay_State.note(username, code, a1, a2)
    end

    -- looked up when called: the bridge loads after this file and is allowed not to exist.
    if zBay_Bridge and zBay_Bridge.notice then
        zBay_Bridge.notice(username, code, a1, a2)
    end
end

-- everything that piled up while they were away, sent as they arrive. returns how many.
function zBay_Notify.flush(player, username)
    local notices = zBay_State.takeNotices(username)

    for _, notice in ipairs(notices) do
        zBay_Net.toClient(player, "toast", {
            code = notice.code, a1 = notice.a1, a2 = notice.a2, good = not BAD[notice.code],
        })
    end

    return #notices
end
