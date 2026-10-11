----------
--ESTRAL--
----------

require "zBay_Core"
require "zBay_Net"
require "zBay_Money"

-- what this client has been told, and the one place it asks for more. the window draws from
-- here and never from a packet: a reply lands in this table, the revision moves, and the
-- window notices on its next update.

zBay_ClientState = zBay_ClientState or {}

local S = zBay_ClientState

-- the owner's settings, as far as a client is told them. nil until the server has answered.
S.config = S.config or nil
S.balance = S.balance or 0
-- n waiting, and x y z of the mailbox this player has claimed, if they have one.
S.mail = S.mail or { n = 0 }
S.admin = S.admin or false
S.linked = S.linked or false

-- the market's own counter, as last announced. a page stamped with an older one is stale.
S.rev = S.rev or -1

-- view -> the last reply for it, with the moment it arrived.
S.pages = S.pages or {}

-- the last thing the server said about something this player did.
S.status = S.status or nil

-- moves whenever anything the window draws has changed. the window compares, it is not called.
S.revision = S.revision or 0

-- moves once per answer to an action, so the window knows a press has landed.
S.results = S.results or 0

local function zBay_touch()
    S.revision = S.revision + 1
end

function S.money(amount)
    return zBay_Money.format(amount or 0, S.config and S.config.currency or nil)
end

-- a1 goes in as it came. a2 is money by the server's convention, so it is printed in whatever
-- the currency is now rather than whatever it was when the thing happened.
local function zBay_phrase(prefix, args)
    local a2 = args.a2
    if type(a2) == "number" then a2 = S.money(a2) end

    return getText(prefix .. tostring(args.code), tostring(args.a1 or ""), tostring(a2 or ""))
end

local function zBay_say(text, good)
    S.status = { text = text, good = good, at = getTimestampMs() }

    local player = getPlayer()
    if player and HaloTextHelper then
        if good then
            HaloTextHelper.addGoodText(player, text)
        else
            HaloTextHelper.addBadText(player, text)
        end
    end

    zBay_touch()
end

-- the mailbox sprites as a set, built once per copy of the settings. the right-click menu
-- asks this on every right-click of every tile.
function S.sprites()
    if not S.config then return nil end

    if not S.spriteSet then
        S.spriteSet = {}
        for _, name in ipairs(S.config.mailbox.sprites or {}) do S.spriteSet[name] = true end
    end

    return S.spriteSet
end

local handlers = {}

function handlers.config(args)
    if not args or type(args.config) ~= "table" then return end

    S.config = args.config
    S.spriteSet = nil
    S.balance = args.balance or 0
    S.mail = args.mail or { n = 0 }
    S.admin = args.admin == true
    S.linked = args.linked == true
    S.rev = args.rev or S.rev

    zBay_touch()
end

-- a page is as fresh as the market was when it was cut, so being handed one newer than the
-- last announcement is an announcement.
function handlers.page(args)
    if not args or not args.view then return end

    args.rows = args.rows or {}
    args.at = getTimestampMs()
    S.pages[args.view] = args

    if args.rev and args.rev > S.rev then S.rev = args.rev end

    zBay_touch()
end

function handlers.balance(args)
    S.balance = args and args.n or 0
    zBay_touch()
end

function handlers.mail(args)
    S.mail = args or { n = 0 }
    zBay_touch()
end

function handlers.rev(args)
    if not args or not args.n then return end
    S.rev = args.n
    zBay_touch()
end

function handlers.result(args)
    if not args then return end

    S.results = S.results + 1
    if args.code == "Linked" then S.linked = true end

    zBay_say(zBay_phrase("IGUI_zBay_Res_", args), args.ok == true)
end

function handlers.toast(args)
    if not args then return end
    zBay_say(zBay_phrase("IGUI_zBay_Note_", args), args.good ~= false)
end

function S.onCommand(module, command, args)
    if module ~= zBay.MODULE then return end

    local handler = handlers[command]
    if not handler then return end

    local ok, err = pcall(handler, args)
    if not ok then zBay.warn("client command " .. tostring(command) .. " failed: " .. tostring(err)) end
end

-- matches the server's floor on page, with a little over. a request sent inside it is
-- dropped there without an answer, so it is held here instead and the newest one wins.
local PAGE_MS = 200
local lastPage = 0
local waiting = nil

-- above the server's floor on hello, for the same reason: one sent inside it earns nothing.
local HELLO_MS = 1200
local lastHello = 0

function S.hello()
    local now = getTimestampMs()
    if now - lastHello < HELLO_MS then return end
    lastHello = now

    zBay_Net.toServer("hello", {})
end

function S.close()
    waiting = nil
    zBay_Net.toServer("close", {})
end

function S.requestPage(params)
    waiting = params
    S.tick()
end

-- called from the window's update, so a held request goes out as soon as it is allowed to.
function S.tick()
    if not waiting then return end

    local now = getTimestampMs()
    if now - lastPage < PAGE_MS then return end

    lastPage = now

    local params = waiting
    waiting = nil

    zBay_Net.toServer("page", params)
end

function S.send(command, args)
    zBay_Net.toServer(command, args or {})
end

function S.page(view)
    return S.pages[view]
end

-- how long a row has left, counted down from when its page arrived. measured against this
-- machine's own stopwatch, never its calendar, so a wrong clock here changes nothing.
function S.left(view, row)
    local page = S.pages[view]
    if not page or not row or not row.left then return nil end

    return row.left - (getTimestampMs() - page.at)
end

Events.OnServerCommand.Add(S.onCommand)
