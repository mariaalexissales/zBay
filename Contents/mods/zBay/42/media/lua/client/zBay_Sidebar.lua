----------
--ESTRAL--
----------

require "zBay_Core"
require "zBay_Theme"
require "zBay_Panel"

-- one more cell on the map button's flyout: hover the map icon on the left sidebar and zBay
-- is there to click, beside the map and the minimap.

-- ISEquippedItem keeps TEXTURE_WIDTH file-local, so the scale is derived again here.
-- size 6 means "match the font size" and resolves through a different option.
local function zBay_textureWidth()
    local size = getCore():getOptionSidebarSize()
    if size == 6 then
        size = getCore():getOptionFontSizeReal() - 1
    end

    if size == 2 then return 64 end
    if size == 3 then return 80 end
    if size == 4 then return 96 end
    if size == 5 then return 128 end
    return 48
end

-- the sidebar is rebuilt wholesale when the size option changes, leaving the old panel
-- alive for a frame or two. touching a stale one corrupts the live panel's geometry.
local function zBay_isCurrentPanel(panel)
    if not panel or not panel.playerNum then return false end

    local playerData = getPlayerData(panel.playerNum)
    if playerData and playerData.equipped and playerData.equipped ~= panel then
        return false
    end

    return true
end

-- where the cell goes, and whether what it hangs off is out. it is one more cell on the end
-- of the map button's flyout, or beside the map button itself in a sandbox without the
-- minimap, where that button has no flyout.
local function zBay_host(panel, textureWidth)
    local x, y, out
    local flyout = panel.mapPopup

    if flyout then
        x, y, out = flyout:getX() + flyout:getWidth(), flyout:getY(), flyout:isVisible()
    else
        local button = panel.mapBtn
        x = panel:getAbsoluteX() + button:getX() + textureWidth
        y = panel:getAbsoluteY() + button:getY()
        out = button:isMouseOver()
    end

    -- Quest System Framework puts a cell of its own in that same place. ours goes after it,
    -- whichever of the two loaded first, and stays out while the cursor is on theirs: that
    -- is the way across to ours.
    local quests = panel.QSF_popup
    if quests then
        x = x + quests:getWidth()
        out = out or quests:isMouseOver()
    end

    return x, y, out
end

zBay_Popup = ISPanel:derive("zBay_Popup")

function zBay_Popup:new(x, y, width, height, player)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.player = player
    o.playerNum = player:getPlayerNum()
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }

    return o
end

function zBay_Popup:setTextures(textureWidth)
    if self.textureWidth == textureWidth then return end

    self.textureWidth = textureWidth
    local stem = "media/ui/Sidebar/" .. textureWidth .. "/zBay_"
    self.iconOff = getTexture(stem .. "Off_" .. textureWidth .. ".png")
    self.iconOn = getTexture(stem .. "On_" .. textureWidth .. ".png")
end

-- stands in until there is art at the paths in setTextures: a pile of coins, one on two on
-- three, in the colour money is everywhere else in the window. rects, so it scales to any
-- sidebar size for free.
function zBay_Popup:drawCoins(lit)
    local colour = zBay_Theme.COL_MONEY
    local alpha = lit and 1 or 0.55
    local coin = math.max(4, math.floor(self.width * 0.2))
    local thick = math.max(2, math.floor(self.height * 0.16))
    local gap = math.max(1, math.floor(thick * 0.4))
    local top = math.floor((self.height - thick * 3 - gap * 2) / 2)

    for row = 1, 3 do
        local width = coin * row + gap * (row - 1)
        local y = top + (row - 1) * (thick + gap)

        for n = 0, row - 1 do
            local x = math.floor((self.width - width) / 2) + n * (coin + gap)
            self:drawRect(x, y, coin, thick, alpha, colour.r, colour.g, colour.b)
        end
    end
end

function zBay_Popup:render()
    local open = zBay.isWindowOpen(self.playerNum)
    local texture = open and (self.iconOn or self.iconOff) or self.iconOff

    -- a missing texture should cost us the art, not the whole sidebar render pass.
    if texture then
        self:drawTexture(texture, 0, 0, 1, 1, 1, 1)
        return
    end

    self:drawCoins(open or self:isMouseOver())
end

function zBay_Popup:onMouseMove(dx, dy)
    self:showTooltip(getText("IGUI_zBay_Open"))
    return true
end

function zBay_Popup:onMouseMoveOutside(dx, dy)
    self:hideTooltip()
    return true
end

function zBay_Popup:onMouseDown(x, y)
    self:hideTooltip()

    zBay.togglePanel(self.player)

    return true
end

function zBay_Popup:showTooltip(text)
    if not text then return end

    if not self.tooltip then
        self.tooltip = ISToolTip:new()
        self.tooltip:initialise()
        self.tooltip:instantiate()
        self.tooltip:setOwner(self)
    end

    self.tooltip:setName(text)
    self.tooltip:setVisible(true)
    self.tooltip:addToUIManager()
    self.tooltip:bringToTop()
end

function zBay_Popup:hideTooltip()
    if self.tooltip and self.tooltip:isVisible() then
        self.tooltip:removeFromUIManager()
        self.tooltip:setVisible(false)
    end
end

-- makes the cell if there is none and puts it in its place. true when it should be out.
local function zBay_ensureIcon(panel)
    if not panel or not panel.chr or panel.chr:getPlayerNum() ~= 0 then return false end
    if not zBay_isCurrentPanel(panel) then return false end

    -- a sandbox with the map switched off has no map button to hang off. nothing is put in
    -- its place: the right-click on the floor is still there, and a sidebar button of our own
    -- would fight any other mod's for the bottom of the column.
    if not panel.mapBtn then return false end

    local textureWidth = zBay_textureWidth()
    local textureHeight = textureWidth * 0.75

    if not panel.zBay_popup then
        panel.zBay_popup = zBay_Popup:new(0, 0, textureWidth, textureHeight, panel.chr)
        panel.zBay_popup.owner = panel
        panel.zBay_popup:addToUIManager()
        panel.zBay_popup:setVisible(false)
    end

    local x, y, hostOut = zBay_host(panel, textureWidth)
    panel.zBay_popup:setX(x)
    panel.zBay_popup:setY(y)
    panel.zBay_popup:setWidth(textureWidth)
    panel.zBay_popup:setHeight(textureHeight)
    panel.zBay_popup:setTextures(textureWidth)

    return hostOut
end

local function zBay_updateVisibility(panel, hostOut)
    if not panel or not panel.zBay_popup then return end

    local show = hostOut or panel.zBay_popup:isMouseOver()

    -- the tutorial's sidebar is not the player's to poke at.
    if "Tutorial" == getCore():getGameMode() then
        show = false
    end

    panel.zBay_popup:setVisible(show)

    if show then
        panel.zBay_popup:bringToTop()
    else
        panel.zBay_popup:hideTooltip()
    end
end

local function zBay_patchSidebar()
    if not ISEquippedItem then
        require "ISUI/ISEquippedItem"
    end
    if not ISEquippedItem or ISEquippedItem.zBay_PatchApplied then return end

    ISEquippedItem.zBay_PatchApplied = true
    local originalInitialise = ISEquippedItem.initialise
    local originalPrerender = ISEquippedItem.prerender
    local originalRemove = ISEquippedItem.removeFromUIManager
    local originalCheckSize = ISEquippedItem.checkSidebarSizeOption

    function ISEquippedItem:initialise()
        if originalInitialise then originalInitialise(self) end
        zBay_ensureIcon(self)
    end

    -- vanilla runs first, so a fault in here costs us our cell rather than the player's whole
    -- sidebar.
    function ISEquippedItem:prerender()
        if originalPrerender then originalPrerender(self) end
        if not zBay_isCurrentPanel(self) then return end

        zBay_updateVisibility(self, zBay_ensureIcon(self))
    end

    function ISEquippedItem:removeFromUIManager()
        if self.zBay_popup then
            self.zBay_popup:hideTooltip()
            self.zBay_popup:removeFromUIManager()
            self.zBay_popup = nil
        end

        if originalRemove then
            originalRemove(self)
        else
            ISPanel.removeFromUIManager(self)
        end
    end

    function ISEquippedItem:checkSidebarSizeOption()
        if originalCheckSize then originalCheckSize(self) end
        if zBay_isCurrentPanel(self) then zBay_ensureIcon(self) end
    end
end

-- wrapping the sidebar while the UI is still booting can leave it half-built.
Events.OnGameStart.Add(zBay_patchSidebar)
