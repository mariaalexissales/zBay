----------
--ESTRAL--
----------

require "ISUI/ISCollapsableWindow"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"
require "zBay_Core"
require "zBay_ClientState"
require "zBay_Theme"
require "zBay_Button"
require "zBay_Row"
require "zBay_Views"

-- the window. one shell for every tab: tabs across the top, the list in the middle, a strip
-- of controls under it, a footer. what goes in the list and the strip is the tab's business,
-- and lives in zBay_Views.

zBay.players = zBay.players or {}

zBay_Panel = ISCollapsableWindow:derive("zBay_Panel")

local S = zBay_ClientState

local PAD = 8
local GAP = 6
local TAB_H = 22
local FILTER_H = 22
local HEAD_H = 18
local CTL_H = 22
-- a line of text for what is selected, then the controls under it.
local STRIP_H = 20 + CTL_H
local FOOTER_H = 26

-- how long after the last keystroke a search is sent. a request per letter is a request the
-- server throws away.
local SEARCH_MS = 300
-- how often a stale page is asked for again while the market keeps moving under it.
local STALE_MS = 1000
-- how often a tab that builds its own rows rebuilds them. it is the player's own pockets,
-- and there is no event for "an item moved".
local SCAN_MS = 2000

function zBay.getWindow(playerNum)
    local data = zBay.players[playerNum]
    return data and data.instance or nil
end

function zBay.isWindowOpen(playerNum)
    return zBay.getWindow(playerNum) ~= nil
end

-- selectedId is what is kept: the row table behind it is replaced by every page that arrives.
-- the minimum size is where five columns and a strip of controls stop fitting.
function zBay_Panel:new(x, y, width, height, player)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.player = player
    o.playerNum = player:getPlayerNum()
    o.title = getText("IGUI_zBay_Title")
    o.view = "browse"
    o.rows = {}
    o.selected = nil
    o.selectedId = nil
    o.pageNo = 1
    o.revision = -1
    o.results = S.results
    o.strip = {}
    o.stripList = {}
    o.labels = {}
    o.resizable = true
    o.minimumWidth = 660
    o.minimumHeight = 380

    return o
end

-- one place for the vertical bands so createChildren, onResize and both renders cannot drift.
-- a resizable ISCollapsableWindow paints a status bar over its bottom edge with a resize
-- widget that swallows clicks, so the footer sits above that.
function zBay_Panel:bands()
    local tabY = self:titleBarHeight() + PAD
    local filterY = tabY + TAB_H + GAP
    local headY = filterY + FILTER_H + GAP
    local listY = headY + HEAD_H
    local footerY = self.height - self:resizeWidgetHeight() - FOOTER_H
    local stripY = footerY - STRIP_H - GAP

    return { tab = tabY, filter = filterY, head = headY, list = listY, strip = stripY, footer = footerY }
end

-- the well is drawn to the band and the scroll view sits one pixel inside it, so the frame
-- is not painted over.
function zBay_Panel:listBounds()
    local bands = self:bands()
    return PAD + 1, bands.list + 1, self.width - PAD * 2 - 2, bands.strip - bands.list - GAP - 2
end

function zBay_Panel:def()
    return zBay_Views.defs[self.view]
end

-- a combo's chosen value, or nil for one with nothing in it yet. the boxes above the list
-- are empty until the first page says what is on the market.
local function zBay_chosen(combo)
    if not combo or #combo.options == 0 then return nil end
    return combo:getOptionData(combo.selected)
end

-- the search box calls onTextChange on every keystroke, and the request waits for the typing
-- to stop. setOnCreateItem goes on after instantiate: createChildren has already run
-- initializePool once with no callback set and quietly done nothing. the pool calls
-- initialise on a row for us but not instantiate.
--
-- the footer's right-hand buttons hang off the right edge, each to the left of the one
-- before. refresh is outermost, so it keeps a fixed spot whoever is looking. the admin's
-- three are down here and not on a tab's strip: none of them is about the tab that happens
-- to be open.
function zBay_Panel:createChildren()
    ISCollapsableWindow.createChildren(self)

    local bands = self:bands()

    self.tabs = {}
    local x = PAD

    for _, key in ipairs(zBay_Views.order) do
        local def = zBay_Views.defs[key]
        local button = zBay_Button:new(x, bands.tab, 10, TAB_H, getText(def.title), self, zBay_Panel.onTab)
        button:sizeToTitle(24)
        button.view = key
        zBay_Theme.attach(self, button)

        self.tabs[#self.tabs + 1] = button
        x = button:getRight() + 4
    end

    self.search = zBay_Theme.attach(self, ISTextEntryBox:new("", PAD, bands.filter, 200, FILTER_H))
    self.search.onTextChange = function()
        self.searchAt = getTimestampMs() + SEARCH_MS
    end

    self.category = zBay_Theme.attach(self,
        ISComboBox:new(self.search:getRight() + GAP, bands.filter, 170, FILTER_H, self, zBay_Panel.onFilter))
    self.sort = zBay_Theme.attach(self,
        ISComboBox:new(self.category:getRight() + GAP, bands.filter, 150, FILTER_H, self, zBay_Panel.onFilter))

    local listX, listTop, listWidth, listHeight = self:listBounds()

    self.list = NIVirtualScrollView:new(listX, listTop, listWidth, listHeight)
    self.list:initialise()
    self.list:instantiate()
    self.list:setOnCreateItem(function()
        local row = zBay_Row:new(0, 0, self:rowWidth(), zBay_Row.HEIGHT, self)
        row:instantiate()
        return row
    end)
    self.list:setOnUpdateItem(function(widget, data)
        widget:setWidth(self:rowWidth())
        widget:setRow(data)
    end)
    self.list:setConfig(zBay_Row.HEIGHT, 2)
    self.listHeight = listHeight
    self:addChild(self.list)

    local footY = bands.footer + 2

    self.prev = zBay_Theme.attach(self,
        zBay_Button:new(PAD, footY, 30, FOOTER_H - 4, "<", self, zBay_Panel.onPrev))
    self.next = zBay_Theme.attach(self,
        zBay_Button:new(PAD + 34, footY, 30, FOOTER_H - 4, ">", self, zBay_Panel.onNext))

    local function foot(title, onclick, before)
        local button = zBay_Button:new(0, footY, 10, FOOTER_H - 4, getText(title), self, onclick)
        button:sizeToTitle(24)
        button:setX((before and before:getX() - 4 or self.width - PAD) - button:getWidth())
        return zBay_Theme.attach(self, button, { anchorLeft = false, anchorRight = true })
    end

    self.refreshBtn = foot("IGUI_zBay_Refresh", zBay_Panel.onRefresh, nil)

    self.reload = foot("IGUI_zBay_Reload", zBay_Panel.onReload, self.refreshBtn)
    self.restore = foot("IGUI_zBay_Restore", zBay_Panel.onRestore, self.reload)
    self.backup = foot("IGUI_zBay_Backup", zBay_Panel.onBackup, self.restore)
    self.adminButtons = { self.reload, self.restore, self.backup }

    self:setView(self.view)
end

-- a little short of the list, so the scroll bar has somewhere to be that is not on top of
-- the last column.
function zBay_Panel:rowWidth()
    return self.list:getWidth() - 12
end

function zBay_Panel:clearStrip()
    for _, entry in ipairs(self.stripList) do self:removeChild(entry.control) end

    self.strip = {}
    self.stripList = {}
    self.labels = {}
    self.stripX = PAD
end

local function zBay_stripY(panel)
    return panel:bands().strip + (STRIP_H - CTL_H)
end

function zBay_Panel:place(key, control, label)
    if label then
        local text = getText(label)
        self.labels[#self.labels + 1] = { text = text, x = self.stripX }
        self.stripX = self.stripX + getTextManager():MeasureStringX(UIFont.Small, text) + 4
    end

    control:setX(self.stripX)
    control:setY(zBay_stripY(self))
    zBay_Theme.attach(self, control)

    self.strip[key] = control
    self.stripList[#self.stripList + 1] = { control = control }
    self.stripX = control:getRight() + GAP + 2

    return control
end

function zBay_Panel:addEntry(key, label, width, text, numbers)
    local entry = ISTextEntryBox:new(text or "", 0, 0, width, CTL_H)
    self:place(key, entry, label)
    if numbers then entry:setOnlyNumbers(true) end
    return entry
end

-- options is a list of { text, value }.
function zBay_Panel:addCombo(key, label, width, options)
    local combo = ISComboBox:new(0, 0, width, CTL_H, self, nil)
    self:place(key, combo, label)

    for _, option in ipairs(options) do combo:addOptionWithData(option[1], option[2]) end
    combo.kind = "combo"

    return combo
end

-- needsRow greys the button out until something in the list is selected.
function zBay_Panel:addButton(key, title, onclick, needsRow)
    local button = zBay_Button:new(0, 0, 10, CTL_H, getText(title), self, onclick)
    button:sizeToTitle(22)
    button.needsRow = needsRow == true
    self:place(key, button, nil)
    return button
end

-- what a control holds: a box's text, a combo's chosen value. nil for one this tab has not got.
function zBay_Panel:value(key)
    local control = self.strip[key]
    if not control then return nil end

    if control.kind == "combo" then return zBay_chosen(control) end
    return control:getText()
end

function zBay_Panel:setValue(key, text)
    local control = self.strip[key]
    if control and control.kind ~= "combo" then control:setText(text) end
end

-- nothing under a modal stops being clickable, so a second press would stack a second prompt.
function zBay_Panel:confirm(text, onYes)
    if self.modal then return end

    self.onYes = onYes
    self.modal = zBay_Theme.confirm(text, self, zBay_Panel.onConfirm, self.playerNum)
end

function zBay_Panel:onConfirm(button)
    self.modal = nil

    local onYes = self.onYes
    self.onYes = nil

    if button.internal == "YES" and onYes then onYes() end
end

-- before the settings arrive nobody knows what the strip should offer. it is built when they
-- do: see update.
function zBay_Panel:setView(key)
    if not zBay_Views.defs[key] then key = "browse" end

    self.view = key
    self.selected = nil
    self.selectedId = nil
    self.pageNo = 1

    local def = self:def()

    self:clearStrip()
    if S.config and def.strip then def.strip(self) end
    self.builtFor = S.config and S.config.rev or nil
    self.builtAdmin = S.admin

    local filters = def.filters == true
    self.search:setVisible(filters)
    self.category:setVisible(filters)
    self.sort:setVisible(filters)

    self.sort:clear()
    for _, name in ipairs(def.sorts or {}) do
        self.sort:addOptionWithData(getText("IGUI_zBay_Sort_" .. name), name)
    end

    self.catsKey = nil
    self.watched = def.watch and def.watch() or nil
    self.scanAt = 0

    self:request()
    self:refresh()
end

function zBay_Panel:onTab(button)
    if button.view ~= self.view then self:setView(button.view) end
end

function zBay_Panel:onFilter()
    self.pageNo = 1
    self:request()
end

-- the category box is filled from what the page says is on the market, and only rebuilt
-- when that list is a different one: rebuilding it every page would close it under the
-- player's cursor.
function zBay_Panel:syncCategories(cats)
    local key = table.concat(cats or {}, "|")
    if key == self.catsKey then return end
    self.catsKey = key

    local chosen = zBay_chosen(self.category)

    self.category:clear()
    self.category:addOptionWithData(getText("IGUI_zBay_AllCategories"), "")
    self.category.selected = 1

    for index, cat in ipairs(cats or {}) do
        self.category:addOptionWithData(zBay.text("IGUI_ItemCat_" .. cat, cat), cat)
        if cat == chosen then self.category.selected = index + 1 end
    end
end

-- asks the server for this tab's page. a tab that builds its own rows has nothing to ask for.
function zBay_Panel:request()
    local def = self:def()
    if def.rows then return end

    local params = { view = self.view, page = self.pageNo }

    if def.filters then
        params.q = self.search:getText()
        params.cat = zBay_chosen(self.category)
    end
    if def.sorts then params.sort = zBay_chosen(self.sort) end

    self.askedAt = getTimestampMs()
    S.requestPage(params)
end

function zBay_Panel:onPrev()
    if self.pageNo <= 1 then return end
    self.pageNo = self.pageNo - 1
    self:request()
end

function zBay_Panel:onNext()
    local page = S.page(self.view)
    if not page or self.pageNo >= (page.pages or 1) then return end
    self.pageNo = self.pageNo + 1
    self:request()
end

function zBay_Panel:onRefresh()
    self.scanAt = 0
    self:request()
    self:refresh()
end

function zBay_Panel:onReload()
    S.send("adminReload", {})
end

function zBay_Panel:onBackup()
    S.send("adminBackup", {})
end

-- asked first: it puts every balance and listing back to what the file says.
function zBay_Panel:onRestore()
    self:confirm(getText("IGUI_zBay_RestoreConfirm"), function()
        S.send("adminRestore", {})
    end)
end

function zBay_Panel:cellsFor(row)
    local def = self:def()
    return def.cells and def.cells(row) or nil
end

function zBay_Panel:onRowClick(row)
    self.selected = row
    self.selectedId = row.id

    local def = self:def()
    if def.picked then def.picked(self, row) end
end

-- the row table is new even when the listing is the same one, so the selection is found again
-- by id; gone from the page is gone from the selection. opened from "sell on zBay", the
-- stack that item is in is picked, and that very item sold. the scroll view only reassigns
-- data when the visible range moves, so a refresh leaving the row count alone has to be
-- forced through.
function zBay_Panel:refresh()
    local def = self:def()
    local rows

    if def.rows then
        rows = def.rows(self)
    else
        local page = S.page(self.view)
        rows = zBay_Views.keyed(self.view, page and page.rows or {})

        if page then
            if page.page then self.pageNo = page.page end
            if def.filters then self:syncCategories(page.cats) end
        end
    end

    self.rows = rows

    self.selected = nil

    for _, row in ipairs(rows) do
        if self.wantItem and row.ids and row.ids[self.wantItem] then
            row.itemId = self.wantItem
            self.selectedId = row.id
            self.wantItem = nil
        end

        if row.id == self.selectedId then self.selected = row end
    end

    if not self.selected then self.selectedId = nil end

    if self.list then self.list:setDataSource(self.rows, true) end
end

function zBay_Panel:prerender()
    ISCollapsableWindow.prerender(self)

    local bands = self:bands()
    local listW = self.width - PAD * 2
    local listH = bands.strip - bands.list - GAP

    zBay_Theme.fill(self, PAD, bands.list, listW, listH, zBay_Theme.COL_WELL)
    zBay_Theme.frame(self, PAD, bands.list, listW, listH, zBay_Theme.COL_FRAME)

    for _, button in ipairs(self.tabs or {}) do
        local def = zBay_Views.defs[button.view]
        button.selected = button.view == self.view
        button:setVisible(not def.enabled or def.enabled())
    end

    for _, button in ipairs(self.adminButtons or {}) do button:setVisible(S.admin) end
end

-- the balance sits hard right on the tab row: it is the one number every tab needs. column
-- headers are laid out by the same arithmetic the rows use. over the controls is what is
-- selected, or failing that whatever the tab has to say. the footer shows the last thing the
-- server said, for the few seconds it is news, up to the leftmost button showing: an admin
-- at the narrowest window has no room left for it.
function zBay_Panel:render()
    ISCollapsableWindow.render(self)

    local font = UIFont.Small
    local fontH = getTextManager():getFontHeight(font)
    local bands = self:bands()
    local def = self:def()
    local dim = zBay_Theme.COL_DIM

    zBay_Theme.textRight(self, S.money(S.balance), self.width - PAD,
        bands.tab + math.floor((TAB_H - fontH) / 2), zBay_Theme.COL_MONEY, font)

    local cols = zBay_Row.columns(self:rowWidth())
    local left = PAD + 1
    local headY = bands.head + math.floor((HEAD_H - fontH) / 2)
    local head = def.head or {}

    if head.name then zBay_Theme.text(self, getText(head.name), left + cols.nameX, headY, dim, font) end
    if head.qty then zBay_Theme.textRight(self, getText(head.qty), left + cols.qty, headY, dim, font) end
    if head.price then zBay_Theme.textRight(self, getText(head.price), left + cols.price, headY, dim, font) end
    if head.ends then zBay_Theme.textRight(self, getText(head.ends), left + cols.ends, headY, dim, font) end
    if head.who then zBay_Theme.textRight(self, getText(head.who), left + cols.who, headY, dim, font) end

    if #self.rows == 0 then
        local text = getText("IGUI_zBay_Empty")
        if not S.config or (not def.rows and not S.page(self.view)) then text = getText("IGUI_zBay_Connecting") end
        zBay_Theme.text(self, text, PAD + 10, bands.list + 10, dim, font)
    end

    local line = nil
    if self.selected then
        line = def.info and def.info(self, self.selected) or (self.selected.n or "")
    elseif def.hint then
        line = def.hint(self)
    end
    if line then
        zBay_Theme.text(self, zBay_Theme.truncate(line, self.width - PAD * 2, font), PAD, bands.strip,
            self.selected and zBay_Theme.COL_TITLE or dim, font)
    end

    local labelY = zBay_stripY(self) + math.floor((CTL_H - fontH) / 2)
    for _, label in ipairs(self.labels) do
        zBay_Theme.text(self, label.text, label.x, labelY, zBay_Theme.COL_TEXT, font)
    end

    zBay_Theme.fill(self, PAD, bands.footer - GAP / 2, self.width - PAD * 2, 1, zBay_Theme.COL_FRAME)

    local footY = bands.footer + math.floor((FOOTER_H - fontH) / 2)
    local x = PAD + 72

    local page = S.page(self.view)
    if page and page.pages and not def.rows then
        local text = getText("IGUI_zBay_PageOf", page.page or 1, page.pages, page.total or 0)
        zBay_Theme.text(self, text, x, footY, dim, font)
        x = x + getTextManager():MeasureStringX(font, text) + PAD * 2
    end

    local status = S.status
    if status and getTimestampMs() - status.at < 8000 then
        local room = (S.admin and self.backup:getX() or self.refreshBtn:getX()) - x - PAD
        if room > 0 then
            zBay_Theme.text(self, zBay_Theme.truncate(status.text, room, font), x, footY,
                status.good and zBay_Theme.COL_GOOD or zBay_Theme.COL_BAD, font)
        end
    end
end

-- the strip is rebuilt when the settings arrive or change, or this player's rank does: the
-- one on screen was built for something else. an answer to anything this player did means
-- the page is out of date. a page of listings the market has moved under is asked for again,
-- but not more than once a second however fast it is moving.
function zBay_Panel:update()
    ISCollapsableWindow.update(self)

    S.tick()

    local now = getTimestampMs()
    local def = self:def()

    local configRev = S.config and S.config.rev or nil
    if configRev ~= self.builtFor or S.admin ~= self.builtAdmin then
        self:setView(self.view)
        return
    end

    if self.searchAt and now >= self.searchAt then
        self.searchAt = nil
        self.pageNo = 1
        self:request()
    end

    if self.results ~= S.results then
        self.results = S.results
        self.scanAt = 0
        self:request()
    end

    if def.watch then
        local value = def.watch()
        if value ~= self.watched then
            self.watched = value
            self:request()
        end
    end

    if def.market then
        local page = S.page(self.view)
        if page and page.rev and page.rev ~= S.rev and now - (self.askedAt or 0) > STALE_MS then
            self:request()
        end
    end

    if def.rows and now - (self.scanAt or 0) > SCAN_MS then
        self.scanAt = now
        self:refresh()
    end

    if self.revision ~= S.revision then
        self.revision = S.revision
        self:refresh()
    end

    for _, entry in ipairs(self.stripList) do
        local control = entry.control
        if control.needsRow ~= nil then control:setEnable(not control.needsRow or self.selected ~= nil) end
    end

    local page = S.page(self.view)
    local paged = page ~= nil and not def.rows and (page.pages or 1) > 1
    self.prev:setEnable(paged and self.pageNo > 1)
    self.next:setEnable(paged and self.pageNo < (page and page.pages or 1))
end

-- setConfig rebuilds the whole widget pool and onResize fires every frame of a drag, so the
-- list is only reconfigured when its height has actually moved.
function zBay_Panel:onResize()
    ISCollapsableWindow.onResize(self)
    if not self.list then return end

    local bands = self:bands()
    local _, _, listWidth, listHeight = self:listBounds()

    self.list:setWidth(listWidth)
    self.list:setHeight(listHeight)

    if self.listHeight ~= listHeight then
        self.listHeight = listHeight
        self.list:setConfig(zBay_Row.HEIGHT, 2)
    end

    self.list:setDataSource(self.rows, true)

    local stripY = zBay_stripY(self)
    for _, entry in ipairs(self.stripList) do entry.control:setY(stripY) end

    local footY = bands.footer + 2
    self.prev:setY(footY)
    self.next:setY(footY)
    self.refreshBtn:setY(footY)
    for _, button in ipairs(self.adminButtons) do button:setY(footY) end
end

-- tells the server, which stops announcing the market to somebody who is not looking at it.
function zBay_Panel:close()
    local data = zBay.players[self.playerNum]
    if data and data.instance == self then
        data.x = self:getX()
        data.y = self:getY()
        data.instance = nil
    end

    if self.modal then
        self.modal:removeFromUIManager()
        self.modal = nil
    end

    S.close()

    ISCollapsableWindow.close(self)
    self:removeFromUIManager()
end

-- view and itemId are both optional: the floor menu opens it where it was left, and "sell on
-- zBay" opens it on the sell tab with that item picked.
--
-- NeatUI is declared in mod.info, but a client that somehow loaded us without it would index
-- a nil and take the whole ui down, so that is asked first. every open is a hello: it is what
-- puts this player back on the server's list of people to tell, and what brings anything
-- they were owed while away.
function zBay.openPanel(player, view, itemId)
    if not player then return end

    local playerNum = player:getPlayerNum()
    if playerNum ~= 0 then return end

    if not NIVirtualScrollView then
        zBay.warn("NeatUI Framework is not loaded, so the zBay window cannot open")
        return
    end

    local data = zBay.players[playerNum]
    if not data then
        data = {}
        zBay.players[playerNum] = data
    end

    S.hello()

    local window = data.instance

    if not window then
        local width, height = 760, 520
        local x = data.x or (getCore():getScreenWidth() - width) / 2
        local y = data.y or (getCore():getScreenHeight() - height) / 2

        window = zBay_Panel:new(x, y, width, height, player)
        if view then window.view = view end
        window.wantItem = itemId
        window:initialise()
        window:instantiate()
        window:addToUIManager()

        data.instance = window
        return
    end

    window:setVisible(true)
    window:bringToTop()
    window.wantItem = itemId

    if view and view ~= window.view then
        window:setView(view)
    else
        window:onRefresh()
    end
end

-- what the sidebar's cell does: one click to open, the next to close.
function zBay.togglePanel(player)
    local playerNum = player and player:getPlayerNum() or 0

    if zBay.isWindowOpen(playerNum) then
        zBay.getWindow(playerNum):close()
    else
        zBay.openPanel(player)
    end
end

Events.OnPlayerDeath.Add(function(player)
    if not player then return end

    local window = zBay.getWindow(player:getPlayerNum())
    if window then window:close() end
end)
