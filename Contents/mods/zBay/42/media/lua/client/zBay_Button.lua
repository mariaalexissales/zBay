----------
--ESTRAL--
----------

require "ISUI/ISButton"
require "zBay_Theme"

zBay_Button = ISButton:derive("zBay_Button")

-- displayBackground is off: the vanilla rect-and-border chrome would sit under the NeatUI art.
function zBay_Button:new(x, y, width, height, title, target, onclick)
    local o = ISButton:new(x, y, width, height, title, target, onclick)
    setmetatable(o, self)
    self.__index = self

    o.font = UIFont.Small
    o.selected = false

    o.displayBackground = false

    return o
end

function zBay_Button:sizeToTitle(padding)
    self:setWidth(getTextManager():MeasureStringX(self.font, self.title) + (padding or 20))
    return self
end

function zBay_Button:state()
    if not self.enable then return zBay_Theme.STATES.disabled end
    if self.pressed then return zBay_Theme.STATES.pressed end
    if self.selected then return zBay_Theme.STATES.selected end
    if self.mouseOver and self:isMouseOver() then return zBay_Theme.STATES.hover end
    return zBay_Theme.STATES.normal
end

function zBay_Button:prerender()
    ISButton.prerender(self)

    local state = self:state()
    self.textColor = self.textColor or {}
    self.textColor.r, self.textColor.g, self.textColor.b = state.text[1], state.text[2], state.text[3]
    self.textColor.a = 1

    if state.fill then
        self:drawRect(0, 0, self.width, self.height, state.fill[4], state.fill[1], state.fill[2], state.fill[3])
    end

    local textures = zBay_Theme.textures()
    if NeatTool and NeatTool.ThreePatch then
        NeatTool.ThreePatch.drawHorizontal(self, 0, 0, self.width, self.height,
            textures.left, textures.middle, textures.right,
            state.alpha, state.cap[1], state.cap[2], state.cap[3])
    end
end
