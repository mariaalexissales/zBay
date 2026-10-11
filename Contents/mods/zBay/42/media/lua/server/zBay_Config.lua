----------
--ESTRAL--
----------

require "zBay_Core"
require "zBay_Json"
require "zBay_Money"
require "zBay_Files"

if not zBay.isAuthority() then return end

-- the owner's settings, out of two json files in Zomboid/Lua/zBay. nothing in here trusts
-- the file: every value is checked and clamped on the way in, a value that is wrong falls
-- back to its default with a line in the log, and a file that will not parse at all leaves
-- the last good settings in force.

zBay_Config = zBay_Config or {}

zBay_Config.FILE = "config.json"
zBay_Config.DISCORD_FILE = "discord.json"

local META_TABLE = "zBay_Meta"

-- ascii only: the file writer's charset is the platform's, so curly quotes can come out mangled.
local STARTER = [[
// zBay settings. edit, save, then press Reload in the zBay window (admins only).
// a mistake in here never takes the server down: the last good settings stay in force
// and the server console names the line.
{
  // what players pay with. each entry is an item and what one of it is worth, so bigger
  // notes are one more line:  { "item": "Base.MoneyBundle", "value": 100 }
  // leave "symbol" empty to show the name after the number instead.
  "currency": {
    "name": "Dollars",
    "symbol": "$",
    "items": [
      { "item": "Base.Money", "value": 1 }
    ]
  },

  "market": {
    "feePercent": 5,
    "maxListingsPerPlayer": 20,
    "listingHours": 72,
    "pageSize": 50
  },

  "auction": {
    "enabled": true,
    "durationsHours": [1, 6, 24, 72],
    "minIncrementPercent": 5,
    "antiSnipeMinutes": 2,
    "allowBuyout": true
  },

  // full item types, and display categories, that cannot be listed.
  "blacklist": {
    "items": ["Base.KeyRing", "Base.IDcard"],
    "categories": []
  },

  // what does not fit in a player's inventory waits in their mail. "required" means it is
  // collected at a mailbox they have claimed; false lets them collect from the window.
  // "sprites" is what counts as a mailbox, so a custom map can add its own.
  "mailbox": {
    "required": true,
    "reach": 2,
    "deliverToInventory": true,
    "sprites": [
      "street_decoration_01_18", "street_decoration_01_19",
      "street_decoration_01_20", "street_decoration_01_21"
    ]
  },

  // a readable copy of every balance and listing, written beside this file every so many
  // minutes while anything has changed.
  "backup": { "enabled": true, "minutes": 10 }
}
]]

local DISCORD_STARTER = [[
// zBay's Discord bridge. the setup page says what goes in "endpoint" and "serverKey".
// the game only reads the switches; the relay program reads the other two.
{
  "enabled": false,
  "endpoint": "",
  "serverKey": "",
  "pollSeconds": 5,
  "snapshotSeconds": 60,
  "events": {
    "listing": true,
    "sale": true,
    "auctionStart": true,
    "bid": false,
    "auctionEnd": true
  }
}
]]

local function zBay_defaults()
    return {
        currency = {
            name = "Dollars",
            symbol = "$",
            items = { { item = "Base.Money", value = 1 } },
        },
        market = { feePercent = 5, maxListingsPerPlayer = 20, listingHours = 72, pageSize = 50 },
        auction = {
            enabled = true, durationsHours = { 1, 6, 24, 72 }, minIncrementPercent = 5,
            antiSnipeMinutes = 2, allowBuyout = true,
        },
        blacklist = { items = {}, categories = {} },
        mailbox = {
            required = true, reach = 2, deliverToInventory = true,
            sprites = {
                street_decoration_01_18 = true, street_decoration_01_19 = true,
                street_decoration_01_20 = true, street_decoration_01_21 = true,
            },
        },
        backup = { enabled = true, minutes = 10 },
    }
end

local function zBay_discordDefaults()
    return {
        enabled = false, pollSeconds = 5, snapshotSeconds = 60,
        events = { listing = true, sale = true, auctionStart = true, bid = false, auctionEnd = true },
    }
end

zBay_Config.data = zBay_Config.data or zBay_defaults()
zBay_Config.discord = zBay_Config.discord or zBay_discordDefaults()

-- bumped on every load that took, so a client holding an older copy can be told.
zBay_Config.rev = zBay_Config.rev or 0

local function zBay_section(raw, key, notes)
    local value = raw[key]
    if value == nil then return {} end

    if type(value) ~= "table" then
        notes[#notes + 1] = '"' .. key .. '" should be an object, using the defaults'
        return {}
    end

    return value
end

local function zBay_number(section, name, raw, fallback, min, max, notes)
    local value = raw[name]
    if value == nil then return fallback end

    local n = zBay.int(value, min, max)
    if not n then
        notes[#notes + 1] = '"' .. section .. "." .. name .. '" should be a whole number from '
            .. min .. " to " .. max .. ", using " .. tostring(fallback)
        return fallback
    end

    return n
end

local function zBay_flag(section, name, raw, fallback, notes)
    local value = raw[name]
    if value == nil then return fallback end

    if type(value) ~= "boolean" then
        notes[#notes + 1] = '"' .. section .. "." .. name .. '" should be true or false, using '
            .. tostring(fallback)
        return fallback
    end

    return value
end

local function zBay_stringSet(section, name, raw, fallback, notes)
    local value = raw[name]
    if value == nil then return fallback end

    if type(value) ~= "table" then
        notes[#notes + 1] = '"' .. section .. "." .. name .. '" should be a list'
        return fallback
    end

    local out = {}
    for _, entry in ipairs(value) do
        if type(entry) == "string" and entry ~= "" then out[entry] = true end
    end

    return out
end

local function zBay_itemExists(fullType)
    local ok, script = pcall(function() return getScriptManager():FindItem(fullType) end)
    return ok and script ~= nil
end

-- an item the game does not have is a typo or a mod that is not loaded, and either way nobody
-- can hold one, so it is skipped. items left out altogether is a file that never mentioned
-- them, which is the default and not a mistake; there and empty is worth a line. so is a list
-- with nothing worth 1: a withdrawal can only pay out multiples of the smallest note.
local function zBay_currency(raw, defaults, notes)
    local out = { name = defaults.name, symbol = defaults.symbol, items = {} }

    if type(raw.name) == "string" then out.name = raw.name end
    if type(raw.symbol) == "string" then out.symbol = raw.symbol end

    local seen = {}

    for index, entry in ipairs(type(raw.items) == "table" and raw.items or {}) do
        local item = type(entry) == "table" and entry.item or nil
        local value = type(entry) == "table" and zBay.int(entry.value, 1, 1000000) or nil

        if type(item) ~= "string" or not value then
            notes[#notes + 1] = "currency.items[" .. index .. "] needs an item and a whole value, skipped"
        elseif seen[item] then
            notes[#notes + 1] = "currency.items lists " .. item .. " twice, the second is skipped"
        elseif not zBay_itemExists(item) then
            notes[#notes + 1] = "currency.items: the game has no item " .. item .. ", skipped"
        else
            seen[item] = true
            out.items[#out.items + 1] = { item = item, value = value }
        end
    end

    if #out.items == 0 then
        if raw.items ~= nil then
            notes[#notes + 1] = "currency.items has nothing usable in it, using Base.Money at 1"
        end
        out.items = { { item = "Base.Money", value = 1 } }
    end

    out.items = zBay_Money.sorted(out.items)

    if out.items[#out.items].value ~= 1 then
        notes[#notes + 1] = "currency.items has nothing worth 1, so amounts that are not a multiple of "
            .. out.items[#out.items].value .. " cannot be withdrawn"
    end

    return out
end

local function zBay_durations(raw, fallback, notes)
    local value = raw.durationsHours
    if value == nil then return fallback end

    local out = {}
    for _, entry in ipairs(type(value) == "table" and value or {}) do
        local hours = zBay.int(entry, 1, 168)
        if hours and #out < 6 then out[#out + 1] = hours end
    end

    if #out == 0 then
        notes[#notes + 1] = '"auction.durationsHours" needs whole hours from 1 to 168, using the defaults'
        return fallback
    end

    table.sort(out)
    return out
end

-- the file as a settings table. total: whatever is in raw, what comes back is usable.
function zBay_Config.normalise(raw, notes)
    local d = zBay_defaults()
    local out = {}

    out.currency = zBay_currency(zBay_section(raw, "currency", notes), d.currency, notes)

    local market = zBay_section(raw, "market", notes)
    out.market = {
        feePercent = zBay_number("market", "feePercent", market, d.market.feePercent, 0, 50, notes),
        maxListingsPerPlayer = zBay_number("market", "maxListingsPerPlayer", market,
            d.market.maxListingsPerPlayer, 1, 200, notes),
        listingHours = zBay_number("market", "listingHours", market, d.market.listingHours, 1, 720, notes),
        pageSize = zBay_number("market", "pageSize", market, d.market.pageSize, 10, 100, notes),
    }

    local auction = zBay_section(raw, "auction", notes)
    out.auction = {
        enabled = zBay_flag("auction", "enabled", auction, d.auction.enabled, notes),
        durationsHours = zBay_durations(auction, d.auction.durationsHours, notes),
        minIncrementPercent = zBay_number("auction", "minIncrementPercent", auction,
            d.auction.minIncrementPercent, 1, 100, notes),
        antiSnipeMinutes = zBay_number("auction", "antiSnipeMinutes", auction,
            d.auction.antiSnipeMinutes, 0, 30, notes),
        allowBuyout = zBay_flag("auction", "allowBuyout", auction, d.auction.allowBuyout, notes),
    }

    local blacklist = zBay_section(raw, "blacklist", notes)
    out.blacklist = {
        items = zBay_stringSet("blacklist", "items", blacklist, d.blacklist.items, notes),
        categories = zBay_stringSet("blacklist", "categories", blacklist, d.blacklist.categories, notes),
    }

    local mailbox = zBay_section(raw, "mailbox", notes)
    out.mailbox = {
        required = zBay_flag("mailbox", "required", mailbox, d.mailbox.required, notes),
        reach = zBay_number("mailbox", "reach", mailbox, d.mailbox.reach, 1, 5, notes),
        deliverToInventory = zBay_flag("mailbox", "deliverToInventory", mailbox,
            d.mailbox.deliverToInventory, notes),
        sprites = zBay_stringSet("mailbox", "sprites", mailbox, d.mailbox.sprites, notes),
    }

    local backup = zBay_section(raw, "backup", notes)
    out.backup = {
        enabled = zBay_flag("backup", "enabled", backup, d.backup.enabled, notes),
        minutes = zBay_number("backup", "minutes", backup, d.backup.minutes, 1, 120, notes),
    }

    return out
end

-- endpoint and serverKey are the relay's to read. the game never opens a connection, so it does
-- not keep them either.
function zBay_Config.normaliseDiscord(raw, notes)
    local d = zBay_discordDefaults()

    local out = {
        enabled = zBay_flag("discord", "enabled", raw, d.enabled, notes),
        pollSeconds = zBay_number("discord", "pollSeconds", raw, d.pollSeconds, 2, 60, notes),
        snapshotSeconds = zBay_number("discord", "snapshotSeconds", raw, d.snapshotSeconds, 15, 3600, notes),
        events = {},
    }

    local events = type(raw.events) == "table" and raw.events or {}
    for name, fallback in pairs(d.events) do
        out.events[name] = zBay_flag("discord.events", name, events, fallback, notes)
    end

    return out
end

-- writes a starter file where there is none. one that is there but unreadable is still
-- somebody's file, and is left alone.
local function zBay_seedOne(name, text)
    local existing, err = zBay_Files.read(name)
    if existing then return end

    if err and err:find("^read failed") then return end

    if zBay_Files.write(name, text) then
        zBay.log("created " .. zBay_Files.shown(name))
    else
        zBay.warn("could not create " .. zBay_Files.shown(name))
    end
end

-- nothing else ever writes to Zomboid/Lua, so without this an owner has no folder to find.
-- once per world, or a file they deleted on purpose would come back every restart.
function zBay_Config.seed()
    local meta = ModData.getOrCreate(META_TABLE)
    if meta.seeded then return end
    meta.seeded = true

    zBay_seedOne(zBay_Config.FILE, STARTER)
    zBay_seedOne(zBay_Config.DISCORD_FILE, DISCORD_STARTER)
end

local function zBay_loadOne(name, notes)
    local text, readErr = zBay_Files.read(name)
    if not text then
        notes[#notes + 1] = name .. ": " .. tostring(readErr)
        return nil
    end

    local decoded, jsonErr = zBay_Json.decode(text)
    if type(decoded) ~= "table" then
        notes[#notes + 1] = name .. ": " .. tostring(jsonErr or "expected an object")
        return nil
    end

    return decoded
end

-- reads both files. returns whether config.json took, and everything worth telling whoever
-- asked. a file that fails leaves what was already in force alone.
function zBay_Config.load()
    local notes = {}

    local raw = zBay_loadOne(zBay_Config.FILE, notes)
    local ok = raw ~= nil

    if raw then
        zBay_Config.data = zBay_Config.normalise(raw, notes)
        zBay_Config.rev = zBay_Config.rev + 1
    end

    local discord = zBay_loadOne(zBay_Config.DISCORD_FILE, notes)
    if discord then zBay_Config.discord = zBay_Config.normaliseDiscord(discord, notes) end

    for _, note in ipairs(notes) do zBay.warn(note) end

    local currency = zBay_Config.data.currency
    zBay.log("settings " .. (ok and "loaded" or "unchanged") .. ": " .. #currency.items
        .. " currency item(s), fee " .. zBay_Config.data.market.feePercent .. "%, discord "
        .. (zBay_Config.discord.enabled and "on" or "off"))

    return ok, notes
end

local function zBay_keys(set)
    local out = {}
    for key in pairs(set) do out[#out + 1] = key end
    table.sort(out)
    return out
end

-- what a client is told. no file paths, nothing about discord beyond whether linking is on.
function zBay_Config.public()
    local data = zBay_Config.data

    return {
        rev = zBay_Config.rev,
        currency = data.currency,
        fee = data.market.feePercent,
        maxListings = data.market.maxListingsPerPlayer,
        pageSize = data.market.pageSize,
        auction = data.auction,
        mailbox = {
            required = data.mailbox.required,
            reach = data.mailbox.reach,
            sprites = zBay_keys(data.mailbox.sprites),
        },
        discord = zBay_Config.discord.enabled,
    }
end

-- OnInitGlobalModData, because seeding asks mod data whether it has been done before.
Events.OnInitGlobalModData.Add(function()
    zBay_Config.seed()
    zBay_Config.load()
end)
