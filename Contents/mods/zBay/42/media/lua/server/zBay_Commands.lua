----------
--ESTRAL--
----------

require "zBay_Core"
require "zBay_Net"
require "zBay_Money"
require "zBay_Config"
require "zBay_State"
require "zBay_Bank"
require "zBay_Mailbox"
require "zBay_Notify"
require "zBay_Market"
require "zBay_Auction"
require "zBay_Bridge"
require "zBay_Backup"

if not zBay.isAuthority() then return end

-- what a client can ask for, and the clock everything else on the server runs from.
--
-- a handler is handed the player the engine says sent the packet, and takes every name from
-- that, never from the packet. args is whatever the client typed: each field is checked where
-- it is used.

zBay_Commands = zBay_Commands or {}

zBay_Commands.handlers = {}

-- milliseconds between two of the same command from one player. reads are on a scroll wheel
-- and a search box, so they are floored tighter than anything that moves an item.
local FLOOR = { page = 150, hello = 1000 }
local FLOOR_DEFAULT = 300

-- b42 has no server-side disconnect event, so these are swept against who answers to their
-- name instead.
local lastAt = {}
local SWEEP_MS = 60000
local lastSweep = 0

-- username -> the market rev they were last told about. only people with the window open are
-- in here, and they are the only ones a change is announced to.
local watchers = {}

local function zBay_allowed(username, command, now)
    local times = lastAt[username]

    if not times then
        times = {}
        lastAt[username] = times
    end

    if now - (times[command] or 0) < (FLOOR[command] or FLOOR_DEFAULT) then return false end

    times[command] = now
    return true
end

local function zBay_reply(player, ok, code, a1, a2)
    zBay_Net.toClient(player, "result", { ok = ok == true, code = code, a1 = a1, a2 = a2 })
end

local function zBay_sendConfig(player, username)
    zBay_Net.toClient(player, "config", {
        config = zBay_Config.public(),
        balance = zBay_Bank.balance(username),
        mail = zBay_Mailbox.summary(username),
        admin = zBay.isAdmin(player),
        linked = zBay_State.ensure().links[username] ~= nil,
        rev = zBay_State.ensure().rev,
    })
end

-- ----------------------------------------------------------------------------
-- reading
-- ----------------------------------------------------------------------------

-- sent on the way into the world and again whenever the window opens. it does not make a
-- player a watcher: asking for a page of listings does that, and closing the window ends it,
-- so somebody who never opens the market is never sent a word about it.
function zBay_Commands.handlers.hello(player, args)
    local username = zBay.nameOf(player)
    if not username then return end

    zBay_sendConfig(player, username)
    zBay_Notify.flush(player, username)
end

function zBay_Commands.handlers.close(player, args)
    local username = zBay.nameOf(player)
    if username then watchers[username] = nil end
end

function zBay_Commands.handlers.page(player, args)
    local username = zBay.nameOf(player)
    if not username then return end

    args = type(args) == "table" and args or {}

    if args.view == "mail" then
        zBay_Net.toClient(player, "page", { view = "mail", rows = zBay_Mailbox.rows(username) })
        return
    end

    if args.view == "bank" then
        zBay_Net.toClient(player, "page", { view = "bank", rows = zBay_Bank.statement(username) })
        return
    end

    local reply = zBay_Market.query(username, args)
    watchers[username] = reply.rev

    zBay_Net.toClient(player, "page", reply)
end

-- ----------------------------------------------------------------------------
-- the market
-- ----------------------------------------------------------------------------

function zBay_Commands.handlers.sell(player, args)
    zBay_reply(player, zBay_Market.sell(player, args))
end

function zBay_Commands.handlers.buy(player, args)
    zBay_reply(player, zBay_Market.buy(zBay.nameOf(player), args))
end

function zBay_Commands.handlers.bid(player, args)
    zBay_reply(player, zBay_Auction.bid(zBay.nameOf(player), args))
end

function zBay_Commands.handlers.buyout(player, args)
    zBay_reply(player, zBay_Auction.buyout(zBay.nameOf(player), args))
end

function zBay_Commands.handlers.cancel(player, args)
    zBay_reply(player, zBay_Market.cancel(zBay.nameOf(player), args, false))
end

-- ----------------------------------------------------------------------------
-- the bank and the mailbox
-- ----------------------------------------------------------------------------

function zBay_Commands.handlers.deposit(player, args)
    -- no amount is "everything on me".
    local amount = type(args) == "table" and args.amount ~= nil and zBay_Money.amount(args.amount) or nil
    if type(args) == "table" and args.amount ~= nil and not amount then
        zBay_reply(player, false, "Invalid")
        return
    end

    local banked = zBay_Bank.deposit(player, amount)

    if banked > 0 then
        zBay_reply(player, true, "Deposited", nil, banked)
    else
        zBay_reply(player, false, "NoCurrency")
    end
end

function zBay_Commands.handlers.withdraw(player, args)
    local amount = type(args) == "table" and zBay_Money.amount(args.amount) or nil
    if not amount then
        zBay_reply(player, false, "Invalid")
        return
    end

    local paid = zBay_Bank.withdraw(player, amount)

    if paid >= amount then
        zBay_reply(player, true, "Withdrew", nil, paid)
    elseif paid > 0 then
        -- the cap, the weight or the smallest note stopped it short. the rest never left.
        zBay_reply(player, true, "WithdrewSome", nil, paid)
    else
        zBay_reply(player, false, "NoWithdraw")
    end
end

function zBay_Commands.handlers.mailSet(player, args)
    args = type(args) == "table" and args or {}
    zBay_reply(player, zBay_Mailbox.set(player, args.x, args.y, args.z))
end

function zBay_Commands.handlers.mailCollect(player, args)
    local atBox = type(args) == "table" and args.atBox == true
    zBay_reply(player, zBay_Mailbox.collect(player, atBox))
end

function zBay_Commands.handlers.link(player, args)
    local code = type(args) == "table" and args.code or nil
    zBay_reply(player, zBay_Bridge.link(zBay.nameOf(player), code))
end

-- ----------------------------------------------------------------------------
-- admins
-- ----------------------------------------------------------------------------

-- every one of these is a button only admins are drawn, and the client draws the button.
local function zBay_adminOnly(player, what)
    if zBay.isAdmin(player) then return true end

    zBay.warn(tostring(zBay.nameOf(player)) .. " asked to " .. what .. " without permission")
    zBay_reply(player, false, "NotAdmin")
    return false
end

function zBay_Commands.handlers.adminReload(player, args)
    if not zBay_adminOnly(player, "reload the settings") then return end

    local ok, notes = zBay_Config.load()

    -- discord prints prices too, and has to hear the currency changed.
    if ok then zBay_Bridge.announceConfig() end

    -- everybody with the window open gets the new settings, not just whoever pressed it:
    -- a price shown in the old currency is a wrong price.
    for username in pairs(watchers) do
        local watcher = zBay_State.playerOf(username)
        if watcher then zBay_sendConfig(watcher, username) end
    end

    zBay_reply(player, ok, ok and (#notes > 0 and "ReloadedNotes" or "Reloaded") or "ReloadFailed", #notes)
end

function zBay_Commands.handlers.adminRemove(player, args)
    if not zBay_adminOnly(player, "remove a listing") then return end
    zBay_reply(player, zBay_Market.cancel(zBay.nameOf(player), args, true))
end

function zBay_Commands.handlers.adminBackup(player, args)
    if not zBay_adminOnly(player, "write a backup") then return end

    local ok = zBay_Backup.save()
    zBay_reply(player, ok, ok and "BackedUp" or "BackupFailed")
end

function zBay_Commands.handlers.adminRestore(player, args)
    if not zBay_adminOnly(player, "restore a backup") then return end

    local ok = zBay_Backup.load()
    zBay_reply(player, ok, ok and "Restored" or "RestoreFailed")
end

-- the client only draws this one in debug mode, which the server cannot see. it does not
-- need to: an admin can spawn anything this puts in the mail.
function zBay_Commands.handlers.adminTestMail(player, args)
    if not zBay_adminOnly(player, "send test mail") then return end

    local queued = zBay_Mailbox.sendTest(zBay.nameOf(player))
    zBay_reply(player, queued > 0, queued > 0 and "TestMail" or "Failed", queued)
end

-- ----------------------------------------------------------------------------
-- the wire and the clock
-- ----------------------------------------------------------------------------

local function zBay_sweep(now)
    if now - lastSweep < SWEEP_MS then return end
    lastSweep = now

    for username in pairs(lastAt) do
        if not zBay_State.playerOf(username) then lastAt[username] = nil end
    end
    for username in pairs(watchers) do
        if not zBay_State.playerOf(username) then watchers[username] = nil end
    end
end

-- watchers whose page is older than the market get one small packet saying so, and ask for
-- the page again themselves. however much happens in a second, that is one packet each.
local function zBay_announce()
    local rev = zBay_State.ensure().rev

    for username, seen in pairs(watchers) do
        if seen ~= rev then
            local player = zBay_State.playerOf(username)

            if player then
                watchers[username] = rev
                zBay_Net.toClient(player, "rev", { n = rev })
            end
        end
    end
end

local PUMP_MS = 1000
local lastPump = 0

-- the server's one clock. OnTick, not a game-time event: those run on the world's clock,
-- which a real-time server stretches to a minute and a sleeping player sprints.
local function zBay_pump()
    local now = getTimestampMs()
    if now - lastPump < PUMP_MS then return end
    lastPump = now

    zBay_Auction.tick()
    zBay_announce()
    zBay_Bridge.pump()
    zBay_Backup.tick()
    zBay_sweep(now)
end

local function zBay_onClientCommand(module, command, player, args)
    if module ~= zBay.MODULE then return end

    local handler = zBay_Commands.handlers[command]
    if not handler or not player then return end

    local username = zBay.nameOf(player)
    if not username then return end

    -- dropped without a word. the client paces itself to the same floors, so a packet that
    -- lands inside one is a double-click or somebody who is not using the window.
    if not zBay_allowed(username, command, getTimestampMs()) then return end

    local ok, err = pcall(handler, player, args)
    if not ok then
        zBay.warn("command " .. tostring(command) .. " failed: " .. tostring(err))
        zBay_reply(player, false, "Failed")
    end
end

Events.OnClientCommand.Add(zBay_onClientCommand)
zBay.guard("market clock", Events.OnTick, zBay_pump)
