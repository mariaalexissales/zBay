----------
--ESTRAL--
----------

require "ISUI/ISPanel"
require "zBay_Theme"

-- one line of the list. the scroll view keeps a handful of these and hands each a different
-- row as it scrolls, so nothing here belongs to a listing for longer than it is on screen.

zBay_Row = ISPanel:derive("zBay_Row")
zBay_Row.HEIGHT = 28

local PAD = 8
local ICON = 20

-- the time-left column is the only text on a row that changes by itself, and it changes by
-- the minute. cells are rebuilt this often rather than every frame.
local CELLS_MS = 1000

-- every view shares these, read from the right edge inward, so the header above the list
-- and the rows under it are laid out by the same arithmetic.
local WIDTHS = { who = 120, ends = 64, price = 130, qty = 44 }

-- the right edge of each column, and where the name has to stop, for a row this wide.
function zBay_Row.columns(width)
    local whoR = width - PAD
    local endsR = whoR - WIDTHS.who - PAD
    local priceR = endsR - WIDTHS.ends - PAD
    local qtyR = priceR - WIDTHS.price - PAD

    return {
        nameX = PAD + ICON + PAD,
        nameMax = qtyR - WIDTHS.qty - PAD,
        qty = qtyR, price = priceR, ends = endsR, who = whoR,
        whoWidth = WIDTHS.who,
    }
end

function zBay_Row:new(x, y, width, height, panel)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.panel = panel
    o.row = nil
    o.cells = nil
    o.cellsAt = 0
    o.backgroundColor = { r = 1, g = 1, b = 1, a = 0.03 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    -- an ISPanel would otherwise drag the window when the cursor goes down on it.
    o.moveWithMouse = false

    return o
end

function zBay_Row:setRow(row)
    self.row = row
    self.cells = nil
end

function zBay_Row:onMouseDown(x, y)
    if self.row then self.panel:onRowClick(self.row) end
    return true
end

function zBay_Row:prerender()
    local alpha = 0.03

    if self.row and self.panel.selectedId == self.row.id then
        alpha = 0.16
    elseif self:isMouseOver() then
        alpha = 0.08
    end

    self.backgroundColor.a = alpha
    ISPanel.prerender(self)
end

function zBay_Row:render()
    ISPanel.render(self)

    local row = self.row
    if not row then return end

    local now = getTimestampMs()
    if not self.cells or now - self.cellsAt > CELLS_MS then
        self.cells = self.panel:cellsFor(row)
        self.cellsAt = now
    end

    local cells = self.cells
    if not cells then return end

    local font = UIFont.Small
    local textY = math.floor((self.height - getTextManager():getFontHeight(font)) / 2)
    local cols = zBay_Row.columns(self.width)

    local icon = zBay_Theme.icon(row.t)
    if icon then
        self:drawTextureScaledAspect(icon, PAD, math.floor((self.height - ICON) / 2), ICON, ICON, 1, 1, 1, 1)
    end

    local nameColour = cells.tint or zBay_Theme.COL_TITLE
    local name = zBay_Theme.truncate(tostring(cells.name or "?"), cols.nameMax - cols.nameX, font)
    zBay_Theme.text(self, name, cols.nameX, textY, nameColour, font)

    if cells.qty then zBay_Theme.textRight(self, tostring(cells.qty), cols.qty, textY, zBay_Theme.COL_TEXT, font) end
    if cells.price then
        zBay_Theme.textRight(self, tostring(cells.price), cols.price, textY, cells.priceTint or zBay_Theme.COL_MONEY, font)
    end
    if cells.ends then zBay_Theme.textRight(self, tostring(cells.ends), cols.ends, textY, zBay_Theme.COL_TEXT, font) end
    if cells.who then
        local who = zBay_Theme.truncate(tostring(cells.who), cols.whoWidth, font)
        zBay_Theme.textRight(self, who, cols.who, textY, zBay_Theme.COL_DIM, font)
    end
end
