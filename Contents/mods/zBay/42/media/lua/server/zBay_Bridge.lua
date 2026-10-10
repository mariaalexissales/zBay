----------
--ESTRAL--
----------

require "zBay_Core"
require "zBay_Json"
require "zBay_Files"
require "zBay_Config"
require "zBay_State"
require "zBay_Bank"

if not zBay.isAuthority() then return end

-- the game's half of the discord bridge.
--
-- lua here can open no socket and make no web request, so the game and the outside world
-- meet in a folder, Zomboid/Lua/zBay/bridge/, and a small relay program beside the server
-- carries what is in it to the bot and back:
--
--   out_<boot>.log   written here, one json record to a line. the game cannot delete or
--                    rename, so it starts a new file each boot and only ever appends; the
--                    relay removes the ones it has finished with.
--   snapshot.json    what is for sale right now, rewritten when the market has moved.
--   in.log           written by the relay, one command to a line.
--   in_ack.json      written here: the last command acted on, so the relay knows what it
--                    can clear out of in.log.
--
-- the names are what the file api will write: see zBay_Files.

zBay_Bridge = zBay_Bridge or {}

zBay_Bridge.ready = false

local DIR = "bridge/"
local IN_FILE = DIR .. "in.log"
local ACK_FILE = DIR .. "in_ack.json"
local SNAPSHOT_FILE = DIR .. "snapshot.json"

-- the snapshot is for searching from discord, not a second copy of the market. the newest
-- few hundred is what a search there is ever after.
local SNAPSHOT_CAP = 400

local PENDING_CAP = 200

-- the ones an owner can switch off. everything else the bridge writes is plumbing the bot
-- needs to work at all, and goes out whenever the bridge is on.
local OPTIONAL = { listing = true, sale = true, auctionStart = true, bid = true, auctionEnd = true }

local outFile = nil
local queue = {}
local lastPoll = 0
local lastSnapshot = 0
local snapshotRev = -1
local warnedUnreadable = false

-- when this boot started, and whether its out file has been opened with a hello yet.
local boot = 0
local saidHello = false

local function zBay_enabled()
    return zBay_Bridge.ready and zBay_Config.discord.enabled
end

-- ----------------------------------------------------------------------------
-- out
-- ----------------------------------------------------------------------------

local function zBay_currency()
    local currency = zBay_Config.data.currency
    return { name = currency.name, symbol = currency.symbol }
end

-- held in memory until the next pump, so a burst of bids is one write and not one each.
-- what is lost if the server dies in that second is a few announcements, never money.
local function zBay_queue(kind, payload)
    -- the first record of every boot, whatever was about to be first. it says which world
    -- this is and what the money is called, so nothing after it is announced as a bare
    -- number. sent here and not at boot: a bridge switched on by a reload an hour in still
    -- has to open with it.
    if not saidHello then
        saidHello = true
        zBay_queue("hello", { boot = boot, world = zBay_Files.world(), v = zBay.SCHEMA_V, currency = zBay_currency() })
    end

    local data = zBay_State.ensure()
    data.bridge.outSeq = data.bridge.outSeq + 1

    payload = payload or {}
    payload.type = kind
    payload.seq = data.bridge.outSeq
    payload.t = zBay.now()

    queue[#queue + 1] = payload
end

function zBay_Bridge.emit(kind, payload)
    if not zBay_enabled() then return end
    if OPTIONAL[kind] and zBay_Config.discord.events[kind] == false then return end

    zBay_queue(kind, payload)
end

-- the owner reloaded the settings. the one thing in them the bot prints is the currency.
function zBay_Bridge.announceConfig()
    if not zBay_enabled() then return end

    zBay_queue("config", { currency = zBay_currency() })
end

-- something that happened to one player, for a direct message. only for the linked: without
-- a discord account to send it to there is nothing for the bot to do with it.
function zBay_Bridge.notice(username, code, item, amount)
    if not zBay_enabled() then return end

    local discordId = zBay_State.ensure().links[username]
    if not discordId then return end

    zBay_queue("notice", { user = username, discordId = discordId, code = code, item = item, amount = amount })
end

local function zBay_flush()
    if #queue == 0 or not outFile then return end

    local lines = {}
    for _, record in ipairs(queue) do lines[#lines + 1] = zBay_Json.line(record) end

    -- emptied either way. a folder that cannot be written is not going to be writable in a
    -- second, and a queue that only grows is a leak with a reason.
    queue = {}

    if not zBay_Files.append(outFile, table.concat(lines, "\n") .. "\n") then
        zBay.warn("could not write " .. zBay_Files.shown(outFile))
    end
end

local function zBay_snapshot()
    local data = zBay_State.ensure()
    local listings = {}

    for _, listing in pairs(data.listings) do listings[#listings + 1] = listing end

    table.sort(listings, function(a, b)
        if a.at ~= b.at then return a.at > b.at end
        return a.id > b.id
    end)

    local rows = {}
    for i = 1, math.min(#listings, SNAPSHOT_CAP) do
        local listing = listings[i]

        rows[#rows + 1] = {
            id = listing.id, kind = listing.k == "a" and "auction" or "fixed",
            item = listing.n, type = listing.t, category = listing.c, qty = listing.q,
            price = listing.p or listing.b or listing.sb, buyout = listing.bo,
            bids = listing.nb, seller = listing.s, ends = listing.e,
        }
    end

    local currency = zBay_Config.data.currency

    local text = zBay_Json.line({
        t = zBay.now(), rev = data.rev, total = #listings,
        currency = { name = currency.name, symbol = currency.symbol },
        listings = rows,
    })

    if zBay_Files.write(SNAPSHOT_FILE, text) then snapshotRev = data.rev end
end

-- ----------------------------------------------------------------------------
-- in
-- ----------------------------------------------------------------------------

local inbound = {}

-- discord: "/zbay link". the bot made up a code and told the player; this is the game being
-- told the same code, so it can recognise it when the player types it into the bank tab.
function inbound.link_offer(command)
    if type(command.code) ~= "string" or type(command.discordId) ~= "string" then return end

    local data = zBay_State.ensure()
    local now = zBay.now()
    local count = 0

    -- swept here, where they are made, rather than on a clock of their own.
    for code, pending in pairs(data.pendingLinks) do
        if (pending.e or 0) <= now then
            data.pendingLinks[code] = nil
        else
            count = count + 1
        end
    end

    if count >= PENDING_CAP then return end

    data.pendingLinks[string.upper(command.code)] = {
        d = command.discordId,
        e = zBay.int(command.expires, 1) or (now + 600000),
    }
end

function inbound.unlink(command)
    local username = zBay_State.discordOf[command.discordId]
    if not username then return end

    zBay_State.ensure().links[username] = nil
    zBay_State.discordOf[command.discordId] = nil

    zBay_queue("unlinked", { user = username, discordId = command.discordId })
end

-- discord: "/zbay balance". answered through the out file, with the id the bot gave the
-- question so it can match the two up.
function inbound.balance_query(command)
    local username = zBay_State.discordOf[command.discordId]

    zBay_queue("reply", {
        replyTo = command.replyTo,
        ok = username ~= nil,
        user = username,
        balance = username and zBay_Bank.balance(username) or nil,
    })
end

-- reads in.log from the top and acts on every command newer than the last one acted on.
-- the file is somebody else's and may be mid-write: a last line that will not parse is
-- left for next time, and nothing after a bad line is skipped past.
function zBay_Bridge.poll()
    local _, _, lines = zBay_Files.read(IN_FILE)
    if not lines then return end

    local bridge = zBay_State.ensure().bridge
    local before = bridge.inSeq

    for index, line in ipairs(lines) do
        if line:find("%S") then
            local command = zBay_Json.decode(line)
            local seq = type(command) == "table" and zBay.int(command.seq, 1) or nil

            if not seq then
                -- the last line unreadable is a write in progress. stop, and meet it whole
                -- on the next poll.
                if index == #lines then break end

                -- anywhere else it is a bad record, and it will still be there on every
                -- poll until the relay clears the file. said once, not every five seconds.
                if not warnedUnreadable then
                    warnedUnreadable = true
                    zBay.warn("skipping an unreadable line in " .. zBay_Files.shown(IN_FILE))
                end
            else
                -- a relay that was reinstalled starts counting again from one. it says so
                -- with a new epoch, and the game starts listening from the top with it.
                if command.epoch ~= nil and command.epoch ~= bridge.inEpoch then
                    bridge.inEpoch = command.epoch
                    bridge.inSeq = 0
                end

                if seq > bridge.inSeq then
                    local handler = inbound[command.type]

                    if handler then
                        local ok, err = pcall(handler, command)
                        if not ok then zBay.warn("bridge command " .. tostring(command.type) .. " failed: " .. tostring(err)) end
                    end

                    bridge.inSeq = seq
                end
            end
        end
    end

    if bridge.inSeq ~= before then
        zBay_Files.write(ACK_FILE, zBay_Json.line({ seq = bridge.inSeq, epoch = bridge.inEpoch, t = zBay.now() }))
    end
end

-- ----------------------------------------------------------------------------
-- linking
-- ----------------------------------------------------------------------------

-- the player typing the code discord gave them. that the code exists proves somebody ran
-- the command there; that it arrived in this packet proves who is typing here.
function zBay_Bridge.link(username, code)
    if not username then return false, "Invalid" end
    if not zBay_enabled() then return false, "NoDiscord" end
    if type(code) ~= "string" or code == "" then return false, "BadCode" end

    local data = zBay_State.ensure()
    local key = string.upper(code:gsub("%s", ""))
    local pending = data.pendingLinks[key]

    if not pending or (pending.e or 0) <= zBay.now() then
        data.pendingLinks[key] = nil
        return false, "BadCode"
    end

    data.pendingLinks[key] = nil

    -- one each way: a discord account moving to a new character lets go of the old one.
    local previous = zBay_State.discordOf[pending.d]
    if previous then data.links[previous] = nil end

    local old = data.links[username]
    if old then zBay_State.discordOf[old] = nil end

    data.links[username] = pending.d
    zBay_State.discordOf[pending.d] = username

    zBay_queue("linked", { user = username, discordId = pending.d })

    return true, "Linked"
end

-- ----------------------------------------------------------------------------
-- the pump
-- ----------------------------------------------------------------------------

-- called once a second by the server's clock. now is true when something outside asked for
-- the inbox to be read straight away: see zBay_BridgePoke.
function zBay_Bridge.pump(now)
    if not zBay_Bridge.ready then return end

    local config = zBay_Config.discord

    if not config.enabled then
        -- switched off mid-session. nothing queued before that is owed to anybody.
        if #queue > 0 then queue = {} end
        return
    end

    -- a server nobody is trading on still says which world it is.
    if not saidHello then
        saidHello = true
        zBay_queue("hello", { boot = boot, world = zBay_Files.world(), v = zBay.SCHEMA_V, currency = zBay_currency() })
    end

    zBay_flush()

    local stamp = getTimestampMs()

    if now == true or stamp - lastPoll >= config.pollSeconds * 1000 then
        lastPoll = stamp
        zBay_Bridge.poll()
    end

    if snapshotRev ~= zBay_State.ensure().rev and stamp - lastSnapshot >= config.snapshotSeconds * 1000 then
        lastSnapshot = stamp
        zBay_snapshot()
    end
end

Events.OnInitGlobalModData.Add(function()
    zBay_State.ensure()

    -- seconds are plenty: two boots in one second is not a server.
    boot = math.floor(zBay.now() / 1000)
    outFile = DIR .. "out_" .. string.format("%.0f", boot) .. ".log"

    -- a new file, so a new hello, the first time there is anything to write.
    saidHello = false
    zBay_Bridge.ready = true
end)
