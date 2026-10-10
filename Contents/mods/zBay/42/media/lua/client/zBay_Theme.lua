----------
--ESTRAL--
----------

require "ISUI/ISModalDialog"

zBay_Theme = zBay_Theme or {}

-- NeatUI's end caps take a tint and the body does not, so state is carried by tinting the caps
-- and filling the body behind them.
zBay_Theme.STATES = {
    disabled = { cap = { 0.45, 0.45, 0.45 }, alpha = 0.45, fill = nil,
                 text = { 0.42, 0.42, 0.42 } },
    normal   = { cap = { 0.72, 0.72, 0.72 }, alpha = 0.85, fill = { 1, 1, 1, 0.03 },
                 text = { 0.84, 0.84, 0.84 } },
    hover    = { cap = { 1.00, 1.00, 1.00 }, alpha = 1.00, fill = { 1, 1, 1, 0.10 },
                 text = { 1.00, 1.00, 1.00 } },
    pressed  = { cap = { 0.85, 0.85, 0.85 }, alpha = 1.00, fill = { 0, 0, 0, 0.25 },
                 text = { 0.92, 0.92, 0.92 } },
    selected = { cap = { 0.98, 0.82, 0.45 }, alpha = 1.00, fill = { 0.98, 0.82, 0.45, 0.12 },
                 text = { 1.00, 0.93, 0.74 } },
}

zBay_Theme.COL_FRAME = { r = 1, g = 1, b = 1, a = 0.09 }
zBay_Theme.COL_WELL = { r = 0, g = 0, b = 0, a = 0.25 }

zBay_Theme.COL_TITLE = { r = 0.90, g = 0.91, b = 0.90 }
zBay_Theme.COL_TEXT = { r = 0.68, g = 0.68, b = 0.68 }
zBay_Theme.COL_DIM = { r = 0.50, g = 0.50, b = 0.50 }
zBay_Theme.COL_MONEY = { r = 0.80, g = 0.74, b = 0.50 }
zBay_Theme.COL_GOOD = { r = 0.48, g = 0.76, b = 0.48 }
zBay_Theme.COL_BAD = { r = 0.86, g = 0.42, b = 0.38 }
zBay_Theme.COL_ME = { r = 0.55, g = 0.80, b = 0.95 }

-- drawRect and drawRectBorder take alpha first, channels after -- the opposite order to the
-- tables above. spelling that out at each call site is four chances to get it wrong silently.
function zBay_Theme.fill(ui, x, y, w, h, colour)
    ui:drawRect(x, y, w, h, colour.a, colour.r, colour.g, colour.b)
end

function zBay_Theme.frame(ui, x, y, w, h, colour)
    ui:drawRectBorder(x, y, w, h, colour.a, colour.r, colour.g, colour.b)
end

function zBay_Theme.text(ui, text, x, y, colour, font)
    ui:drawText(text, x, y, colour.r, colour.g, colour.b, 1, font or UIFont.Small)
end

function zBay_Theme.textRight(ui, text, x, y, colour, font)
    ui:drawTextRight(text, x, y, colour.r, colour.g, colour.b, 1, font or UIFont.Small)
end

local TEXTURES = nil

function zBay_Theme.textures()
    if TEXTURES == nil then
        TEXTURES = {
            left = getTexture("media/ui/NeatUI/Button/Button_FULL_L.png"),
            middle = getTexture("media/ui/NeatUI/Button/Button_FULL_M.png"),
            right = getTexture("media/ui/NeatUI/Button/Button_FULL_R.png"),
        }
    end
    return TEXTURES
end

-- every child goes on the same way. anchors are applied by instantiate(), so they have to
-- be on the child before it runs.
function zBay_Theme.attach(parent, child, anchors)
    for key, value in pairs(anchors or {}) do child[key] = value end
    child:initialise()
    child:instantiate()
    parent:addChild(child)
    return child
end

function zBay_Theme.centre(width, height)
    return (getCore():getScreenWidth() - width) / 2, (getCore():getScreenHeight() - height) / 2
end

-- a yes or no prompt, mid-screen. the callback gets the button and then param. nothing
-- under a modal stops being clickable, so the caller holds what this returns if a second
-- press must not stack a second prompt.
function zBay_Theme.confirm(text, target, callback, playerNum, param)
    local x, y = zBay_Theme.centre(350, 150)
    local modal = ISModalDialog:new(x, y, 350, 150, text, true, target, callback, playerNum, param)

    modal:initialise()
    modal:addToUIManager()
    modal:bringToTop()

    return modal
end

-- an item's icon from its type, looked up once. false is remembered as well as a texture:
-- a type the game does not know is asked about every frame otherwise.
local ICONS = {}

function zBay_Theme.icon(fullType)
    if not fullType then return nil end

    local cached = ICONS[fullType]
    if cached ~= nil then return cached or nil end

    local ok, texture = pcall(function()
        local script = getScriptManager():FindItem(fullType)
        return script and script:getNormalTexture() or nil
    end)

    ICONS[fullType] = (ok and texture) or false
    return ICONS[fullType] or nil
end

-- NeatUI fails silently when it has not loaded, so nothing calls truncateText directly.
function zBay_Theme.truncate(text, maxWidth, font)
    if NeatTool and type(NeatTool.truncateText) == "function" then
        return NeatTool.truncateText(text, maxWidth, font or UIFont.Small)
    end
    return text
end
