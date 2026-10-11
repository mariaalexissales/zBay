----------
--ESTRAL--
----------

require "zBay_Core"

-- an item on the market is not an item. the engine has no way for lua to keep a java object
-- across a save, or to serialise one, so a listing holds the type and this: a plain table of
-- everything about that one item worth keeping, enough to build it again for the buyer.
--
-- what makes that safe is verify(), run before the seller's item is touched: capture it,
-- build a second one from the capture, capture that, and compare. an item that does not come
-- back the same is refused at the counter, so nothing can fail later with the money already
-- moved.

zBay_ItemSnap = zBay_ItemSnap or {}

-- read with get<Name> or is<Name>, written with set<Name>. a name the item's class does not
-- have is skipped, so this one list covers weapons, food, clothing and drainables without
-- asking what anything is. order matters once: a condition is clamped to its max, so the max
-- goes on first.
local FIELDS = {
    "ConditionMax", "Condition", "HaveBeenRepaired", "TimesRepaired", "TimesHeadRepaired",
    "HeadCondition", "Sharpness", "CurrentUses", "KeyId",
    "CurrentAmmoCount", "ContainsClip", "RoundChambered", "SpentRoundChambered",
    "SpentRoundCount", "Jammed", "FireMode",
    "Age", "Cooked", "Burnt", "HungChange", "ThirstChange", "UnhappyChange", "BoredomChange",
    "Calories", "Carbohydrates", "Lipids", "Proteins", "BaseHunger", "PoisonPower",
    "Wetness", "BloodLevel",
}

local VISUAL_FIELDS = { "TextureChoice", "BaseTexture", "Hue" }

-- mod data is somebody else's table. these stop a mod that keeps a whole world in there from
-- becoming part of a listing.
local COPY_DEPTH = 8
local COPY_NODES = 2000

local function zBay_getter(object, name)
    return object["get" .. name] or object["is" .. name]
end

-- every named field the object can both read and write. both halves or neither: a value that
-- can be read and not put back is one verify() would hold against the item for ever.
local function zBay_readFields(object, names)
    local out = {}

    for _, name in ipairs(names) do
        local get = zBay_getter(object, name)

        if get and object["set" .. name] then
            local value = get(object)
            local kind = type(value)

            if kind == "boolean" or kind == "string" then
                out[name] = value
            elseif kind == "number" and value == value then
                out[name] = value
            end
        end
    end

    return out
end

-- puts back only what differs. several setters do more than set, and one called with the
-- value already there is a side effect for nothing.
local function zBay_writeFields(object, values, names)
    if not values then return end

    for _, name in ipairs(names) do
        local value = values[name]

        if value ~= nil then
            local get = zBay_getter(object, name)
            local set = object["set" .. name]

            if set and (not get or get(object) ~= value) then set(object, value) end
        end
    end
end

local function zBay_copy(value, depth, budget)
    local kind = type(value)

    if kind == "string" or kind == "boolean" then return value end
    if kind == "number" then
        if value ~= value then return nil end
        return value
    end
    if kind ~= "table" or depth > COPY_DEPTH then return nil end

    local out = {}

    for key, inner in pairs(value) do
        budget.n = budget.n + 1
        if budget.n > COPY_NODES then
            budget.over = true
            return out
        end

        local keyKind = type(key)
        if keyKind == "string" or keyKind == "number" then
            out[key] = zBay_copy(inner, depth + 1, budget)
        end
    end

    return out
end

-- every fluid the game knows is asked about, because a container only offers its primary one
-- and a bottle of two things would come back as a bottle of one.
local function zBay_captureFluids(item, snap)
    local container = item.getFluidContainer and item:getFluidContainer()
    if not container then return true end

    local fluids = {
        cap = container:getCapacity(),
        locked = container:isInputLocked(),
        canEmpty = container:canPlayerEmpty(),
        mix = {},
    }

    local amount = container:getAmount()

    if amount > 0 then
        local all = Fluid.getAllFluids()
        local total = 0

        for i = 0, all:size() - 1 do
            local fluid = all:get(i)
            local quantity = container:getSpecificFluidAmount(fluid)

            if quantity > 0 then
                fluids.mix[fluid:getFluidTypeString()] = quantity
                total = total + quantity
            end
        end

        if math.abs(total - amount) > 0.0001 then return false, "Fluid" end
    end

    snap.fl = fluids
    return true
end

-- a fresh bottle arrives full of whatever its script says, so it is emptied first. addFluid
-- respects a sealed container, and this is putting back what was there rather than a player
-- pouring: unlocked for the fill, then set to what it was.
local function zBay_restoreFluids(item, fluids)
    local container = item.getFluidContainer and item:getFluidContainer()
    if not container then return false end

    container:Empty()
    container:setCapacity(fluids.cap)

    container:setInputLocked(false)
    container:setCanPlayerEmpty(true)

    for name, amount in pairs(fluids.mix or {}) do
        if not Fluid.Get(name) then return false end
        container:addFluid(name, amount)
    end

    container:setInputLocked(fluids.locked)
    container:setCanPlayerEmpty(fluids.canEmpty)

    return true
end

-- clothing keeps its look in a visual rather than on the item: which texture it rolled, its
-- tint, and blood, dirt and holes per body part. without this a red shirt sells as a blue one.
-- a sewn-on patch is refused, not flattened: it carries the tailoring level it was made at and
-- the engine gives lua no way to put one back. body parts are kept under a name, and only the
-- ones with something on them, because a list with gaps does not survive being saved.
local function zBay_captureVisual(item, snap)
    local visual = item.getVisual and item:getVisual()
    if not visual then return true end

    local out = { f = zBay_readFields(visual, VISUAL_FIELDS), body = {} }

    local tint = visual:getTint()
    if tint then
        out.tint = { tint:getRedFloat(), tint:getGreenFloat(), tint:getBlueFloat(), tint:getAlphaFloat() }
    end

    local clothing = visual:getClothingItem()
    if clothing then out.decal = visual:getDecal(clothing) end

    for i = 0, BloodBodyPartType.MAX:index() - 1 do
        local part = BloodBodyPartType.FromIndex(i)

        if item.getPatchType and item:getPatchType(part) then return false, "Patched" end

        local blood, dirt = visual:getBlood(part), visual:getDirt(part)
        local hole = visual:getHole(part)

        if blood > 0 or dirt > 0 or hole > 0 then
            out.body["p" .. i] = { blood, dirt, hole }
        end
    end

    snap.vis = out
    return true
end

-- the decal is set even when there was none: a fresh shirt can roll a print of its own, and
-- "no print" is as much a thing to put back as any other.
local function zBay_restoreVisual(item, saved)
    local visual = item.getVisual and item:getVisual()
    if not visual then return false end

    zBay_writeFields(visual, saved.f, VISUAL_FIELDS)

    if saved.tint then
        visual:setTint(ImmutableColor.new(saved.tint[1], saved.tint[2], saved.tint[3], saved.tint[4]))
    end
    visual:setDecal(saved.decal)

    for i = 0, BloodBodyPartType.MAX:index() - 1 do
        local part = BloodBodyPartType.FromIndex(i)
        local body = saved.body and saved.body["p" .. i]

        visual:setBlood(part, body and body[1] or 0)
        visual:setDirt(part, body and body[2] or 0)
        if body and body[3] > 0 then visual:setHole(part) end
    end

    return true
end

-- one item as a table, weapon parts and all, or nil and why. a recorded media index of -1 is a
-- blank tape and is left out. mod data past the copy budget refuses the item: half of
-- somebody's mod data is worse than none of it.
local function zBay_capture(item, depth)
    if depth > 3 then return nil, "Unsupported" end

    local snap = { f = zBay_readFields(item, FIELDS) }

    if item.isCustomName and item:isCustomName() then snap.name = item:getName() end
    if item.isCustomWeight and item:isCustomWeight() then snap.weight = item:getActualWeight() end

    if item.getRecordedMediaIndex then
        local media = item:getRecordedMediaIndex()
        if type(media) == "number" and media >= 0 then snap.media = media end
    end

    if item.getAllWeaponParts then
        local parts = item:getAllWeaponParts()

        if parts and parts:size() > 0 then
            snap.parts = {}

            for i = 0, parts:size() - 1 do
                local part = parts:get(i)
                local inner, reason = zBay_capture(part, depth + 1)
                if not inner then return nil, reason end

                snap.parts[#snap.parts + 1] = { t = part:getFullType(), s = inner }
            end
        end
    end

    local ok, reason = zBay_captureFluids(item, snap)
    if not ok then return nil, reason end

    ok, reason = zBay_captureVisual(item, snap)
    if not ok then return nil, reason end

    if item.hasModData and item:hasModData() then
        local budget = { n = 0 }
        local data = zBay_copy(item:getModData(), 0, budget)

        if budget.over then return nil, "Unsupported" end
        if data and not table.isempty(data) then snap.md = data end
    end

    return snap
end

-- makes item match snap. false when a part or a fluid it names no longer exists. the condition
-- is put back again after the visual, because a hole takes condition with it.
local function zBay_restore(item, snap)
    if snap.parts then
        if item.clearAllWeaponParts then item:clearAllWeaponParts() end

        for _, entry in ipairs(snap.parts) do
            local part = instanceItem(entry.t)
            if not part then return false end
            if not zBay_restore(part, entry.s) then return false end

            item:attachWeaponPart(part, false)
        end
    end

    if snap.md then
        local data = item:getModData()
        local budget = { n = 0 }

        for key, value in pairs(zBay_copy(snap.md, 0, budget)) do data[key] = value end
    end

    zBay_writeFields(item, snap.f, FIELDS)

    if snap.weight then
        item:setActualWeight(snap.weight)
        item:setCustomWeight(true)
    end

    if snap.media and item:getRecordedMediaIndex() ~= snap.media then
        item:setRecordedMediaIndexInteger(snap.media)
    end

    if snap.fl and not zBay_restoreFluids(item, snap.fl) then return false end

    if snap.vis then
        if not zBay_restoreVisual(item, snap.vis) then return false end

        local condition = snap.f and snap.f.Condition
        if condition and item:getCondition() ~= condition then item:setCondition(condition) end
    end

    if snap.name then
        item:setName(snap.name)
        item:setCustomName(true)
    end

    return true
end

-- the item as a table, or nil and why. never raises: the engine logs a stack trace for every
-- error whether it was caught or not, and this runs on whatever a player happens to be holding.
function zBay_ItemSnap.capture(item)
    if not item then return nil, "Unknown" end

    local ok, snap, reason = pcall(zBay_capture, item, 0)
    if not ok then
        zBay.trace("capture of " .. tostring(item:getFullType()) .. " failed: " .. tostring(snap))
        return nil, "State"
    end

    if not snap then return nil, reason or "State" end
    return snap
end

-- a new item of this type, made to match the snapshot, or nil. it is not in any container.
function zBay_ItemSnap.create(fullType, snap)
    local ok, item = pcall(function()
        local made = instanceItem(fullType)
        if not made then return nil end
        if snap and not zBay_restore(made, snap) then return nil end
        return made
    end)

    if not ok then
        zBay.warn("could not rebuild " .. tostring(fullType) .. ": " .. tostring(item))
        return nil
    end

    return item
end

-- a float that went into java and came back is the same float, but not always the same
-- double it was compared against, so numbers get a hair of room.
function zBay_ItemSnap.same(a, b)
    local kind = type(a)
    if kind ~= type(b) then return false end

    if kind == "number" then
        return math.abs(a - b) <= 0.00001 * math.max(1, math.abs(a))
    end

    if kind ~= "table" then return a == b end

    for key, value in pairs(a) do
        if not zBay_ItemSnap.same(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end

    return true
end

-- why this item cannot go on the market, as the tail of a translation key, or nil when it
-- can. cheap, and asked by the client too, to keep such things out of the sell list. on a belt
-- or a back counts as equipped: selling it would leave the slot holding something that is gone.
function zBay_ItemSnap.refusal(item)
    if not item then return "Unknown" end

    if item:isEquipped() then return "Equipped" end
    if item.getAttachedSlot and item:getAttachedSlot() > -1 then return "Equipped" end
    if item:isFavorite() then return "Favourite" end

    if instanceof(item, "InventoryContainer") then
        local inner = item:getInventory()
        if inner and inner:getItems():size() > 0 then return "NotEmpty" end
    end

    if instanceof(item, "AnimalInventoryItem") then return "Unsupported" end

    return nil
end

-- where two snapshots first part company, as a path: "f.Sharpness", "vis.tint.2". for the
-- log, when an item is refused and somebody has to work out which setter did not stick.
function zBay_ItemSnap.differs(a, b, path)
    path = path or "snap"

    if type(a) ~= "table" or type(b) ~= "table" then
        if zBay_ItemSnap.same(a, b) then return nil end
        return path .. " (" .. tostring(a) .. " became " .. tostring(b) .. ")"
    end

    for key, value in pairs(a) do
        local found = zBay_ItemSnap.differs(value, b[key], path .. "." .. tostring(key))
        if found then return found end
    end
    for key, value in pairs(b) do
        if a[key] == nil then return path .. "." .. tostring(key) .. " (appeared as " .. tostring(value) .. ")" end
    end

    return nil
end

-- one line a type, however many of it a player tries to list. the refusal is ordinary; the
-- reason is what an owner or a mod author needs, once.
local reported = {}

local function zBay_report(fullType, why)
    if reported[fullType] then return end
    reported[fullType] = true

    zBay.warn(tostring(fullType) .. " cannot be listed: " .. tostring(why))
end

-- the snapshot, but only if a second item built from it captures the same. this is the gate:
-- past it, rebuilding this item for a buyer is something that has already worked once.
function zBay_ItemSnap.verify(item)
    local fullType = item:getFullType()

    local snap, reason = zBay_ItemSnap.capture(item)
    if not snap then
        if reason == "State" then zBay_report(fullType, "its state could not be read") end
        return nil, reason
    end

    local probe = zBay_ItemSnap.create(fullType, snap)
    if not probe then
        zBay_report(fullType, "a copy could not be built from its snapshot")
        return nil, "State"
    end

    local again = zBay_ItemSnap.capture(probe)
    if not again then
        zBay_report(fullType, "the copy's state could not be read")
        return nil, "State"
    end

    if not zBay_ItemSnap.same(snap, again) then
        zBay_report(fullType, "the copy differs at " .. tostring(zBay_ItemSnap.differs(snap, again)))
        return nil, "State"
    end

    return snap
end

-- condition as a percentage, for the things a buyer judges by it. nil for a can of beans,
-- which has a condition as far as the engine is concerned and is not worth a column.
function zBay_ItemSnap.condition(item)
    local max = item:getConditionMax()
    if not max or max <= 0 then return nil end

    local now = item:getCondition()
    local judged = instanceof(item, "HandWeapon") or instanceof(item, "Clothing")
    if not judged and now >= max then return nil end

    return math.max(0, math.min(100, math.floor(now * 100 / max + 0.5)))
end

-- what the sell list groups by. not the snapshot: that is thirty engine calls an item, and
-- the list is rebuilt on a client every time a pocket changes. good enough to stack what
-- looks alike; the server decides what really is with same().
function zBay_ItemSnap.lightKey(item)
    local uses = item.getCurrentUses and item:getCurrentUses() or 0
    local fluid = 0

    local container = item.getFluidContainer and item:getFluidContainer()
    if container then fluid = math.floor(container:getAmount() * 100 + 0.5) end

    return table.concat({
        item:getFullType(), tostring(item:getCondition()), tostring(uses),
        tostring(fluid), item:getName() or "",
    }, "|")
end
