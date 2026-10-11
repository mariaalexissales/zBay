----------
--ESTRAL--
----------

-- project zomboid ships no lua json parser. strict about structure, forgiving about the
-- three things a hand-written file always has wrong: a notepad bom, // comments, and a
-- trailing comma.

zBay = zBay or {}
zBay_Json = zBay_Json or {}

local ESCAPES = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
    f = "\f", n = "\n", r = "\r", t = "\t",
}

-- kahlua's string.char takes one byte at a time. above the basic plane folds to a ?.
local function zBay_utf8(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000),
                           0x80 + (math.floor(code / 0x40) % 0x40),
                           0x80 + (code % 0x40))
    end
    return "?"
end

-- the next character from i on that is neither whitespace nor inside a comment. only ever
-- called from outside a string, so a slash here can only be starting a comment.
local function zBay_nextMeaningful(text, i)
    local n = #text

    while i <= n do
        local c = text:sub(i, i)

        if c:find("%s") then
            i = i + 1
        elseif c == "/" and text:sub(i + 1, i + 1) == "/" then
            local stop = text:find("\n", i, true)
            if not stop then return nil end
            i = stop + 1
        elseif c == "/" and text:sub(i + 1, i + 1) == "*" then
            local stop = text:find("*/", i + 2, true)
            if not stop then return nil end
            i = stop + 2
        else
            return c
        end
    end

    return nil
end

-- takes out a notepad bom, comments and trailing commas before the parser sees them. a
-- character scan, not a gsub: a naive comment strip eats the slashes in any url in a
-- description, and a naive comma strip eats commas in prose. only the in-string state tells
-- code from content. newlines inside what is removed are kept, so a reported line number still
-- matches the file. a comma is trailing when the next meaningful character closes the
-- container, and a comment is not meaningful: "x": 1, // the last one  is how people write it.
local function zBay_prepass(text)
    if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end

    local out, i, n = {}, 1, #text
    local inString, escaped = false, false

    while i <= n do
        local c = text:sub(i, i)

        if inString then
            out[#out + 1] = c
            if escaped then
                escaped = false
            elseif c == "\\" then
                escaped = true
            elseif c == '"' then
                inString = false
            end
            i = i + 1
        elseif c == '"' then
            inString = true
            out[#out + 1] = c
            i = i + 1
        elseif c == "/" and text:sub(i + 1, i + 1) == "/" then
            local stop = text:find("\n", i, true)
            if not stop then break end
            i = stop
        elseif c == "/" and text:sub(i + 1, i + 1) == "*" then
            local stop = text:find("*/", i + 2, true)
            if not stop then break end
            for _ in text:sub(i, stop + 1):gmatch("\n") do out[#out + 1] = "\n" end
            i = stop + 2
        elseif c == "," then
            local nextChar = zBay_nextMeaningful(text, i + 1)
            if nextChar == "}" or nextChar == "]" then
                i = i + 1
            else
                out[#out + 1] = c
                i = i + 1
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end

    return table.concat(out)
end

local Parser = {}
Parser.__index = Parser

function Parser.new(text)
    return setmetatable({ text = text, pos = 1, len = #text }, Parser)
end

function Parser:lineAt(pos)
    local line = 1
    for _ in self.text:sub(1, pos):gmatch("\n") do line = line + 1 end
    return line
end

-- nothing in the parser raises. the game logs every error() with a full java stack trace,
-- caught or not, and stops on it under Break On Error, so one mistyped settings file would
-- look like a crash. a failure is written down instead and every caller backs out.
--
-- null is a legal value and decodes to nil, so nil cannot be what says a parse failed:
-- self.err is. the first one is kept, since that is the one at the mistake.
function Parser:fail(message)
    if not self.err then
        self.err = "line " .. self:lineAt(self.pos) .. ": " .. message
    end
    return nil
end

function Parser:skip()
    local at = self.text:find("[^ \t\r\n]", self.pos)
    self.pos = at or (self.len + 1)
end

function Parser:peek()
    return self.text:sub(self.pos, self.pos)
end

function Parser:parseString()
    self.pos = self.pos + 1
    local out = {}

    while true do
        if self.pos > self.len then return self:fail("unterminated string") end
        local c = self.text:sub(self.pos, self.pos)

        if c == '"' then
            self.pos = self.pos + 1
            return table.concat(out)
        elseif c == "\\" then
            local esc = self.text:sub(self.pos + 1, self.pos + 1)
            if esc == "u" then
                local hex = self.text:sub(self.pos + 2, self.pos + 5)
                local code = tonumber(hex, 16)
                if not code then return self:fail("bad unicode escape") end
                out[#out + 1] = zBay_utf8(code)
                self.pos = self.pos + 6
            elseif ESCAPES[esc] then
                out[#out + 1] = ESCAPES[esc]
                self.pos = self.pos + 2
            else
                return self:fail("unknown escape character")
            end
        else
            out[#out + 1] = c
            self.pos = self.pos + 1
        end
    end
end

function Parser:parseNumber()
    local span = self.text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", self.pos)
    local value = span and tonumber(span)
    if not value then return self:fail("bad number") end
    self.pos = self.pos + #span
    return value
end

-- a null element is dropped: compacting beats a hole that breaks every ipairs and # downstream.
function Parser:parseArray()
    self.pos = self.pos + 1
    local out = {}

    self:skip()
    if self:peek() == "]" then self.pos = self.pos + 1 return out end

    while true do
        local value = self:parseValue()
        if self.err then return nil end

        if value ~= nil then out[#out + 1] = value end

        self:skip()
        local c = self:peek()
        if c == "," then
            self.pos = self.pos + 1
        elseif c == "]" then
            self.pos = self.pos + 1
            return out
        else
            return self:fail("expected a comma or a closing bracket in array")
        end
    end
end

-- a null value leaves its key absent, so the default applies.
function Parser:parseObject()
    self.pos = self.pos + 1
    local out = {}

    self:skip()
    if self:peek() == "}" then self.pos = self.pos + 1 return out end

    while true do
        self:skip()
        if self:peek() ~= '"' then return self:fail("expected a quoted key") end
        local key = self:parseString()
        if self.err then return nil end

        self:skip()
        if self:peek() ~= ":" then return self:fail("expected a colon after key " .. key) end
        self.pos = self.pos + 1

        local value = self:parseValue()
        if self.err then return nil end
        out[key] = value

        self:skip()
        local c = self:peek()
        if c == "," then
            self.pos = self.pos + 1
        elseif c == "}" then
            self.pos = self.pos + 1
            return out
        else
            return self:fail("expected a comma or a closing brace in object")
        end
    end
end

function Parser:parseValue()
    self:skip()
    local c = self:peek()

    if c == "" then return self:fail("unexpected end of file") end
    if c == "{" then return self:parseObject() end
    if c == "[" then return self:parseArray() end
    if c == '"' then return self:parseString() end

    if self.text:sub(self.pos, self.pos + 3) == "true" then
        self.pos = self.pos + 4
        return true
    end
    if self.text:sub(self.pos, self.pos + 4) == "false" then
        self.pos = self.pos + 5
        return false
    end
    if self.text:sub(self.pos, self.pos + 3) == "null" then
        self.pos = self.pos + 4
        return nil
    end
    if c:match("[%-%d]") then return self:parseNumber() end

    return self:fail("unexpected character " .. c)
end

-- returns the value, or nil plus a message. never raises. a mistake in the file comes back
-- through parser.err; the pcall is only for a mistake in the parser, which should cost a file,
-- not a server.
function zBay_Json.decode(text)
    if type(text) ~= "string" or text:match("^%s*$") then
        return nil, "file is empty"
    end

    local parser = Parser.new(zBay_prepass(text))

    local ok, result = pcall(function()
        local value = parser:parseValue()
        if parser.err then return nil end

        parser:skip()
        if parser.pos <= parser.len then
            parser:fail("trailing content after the top-level value")
        end
        return value
    end)

    if not ok then return nil, tostring(result) end
    if parser.err then return nil, parser.err end
    if result == nil then return nil, "top-level value is null" end
    return result
end

local ESCAPES_OUT = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b",
    ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local HEX = "0123456789abcdef"

-- only what json requires is escaped. the game reads and writes these files as utf-8, so
-- an accented name goes out and comes back as itself.
local function zBay_quote(text)
    local out = {}

    for i = 1, #text do
        local c = text:sub(i, i)
        local code = string.byte(c)

        if ESCAPES_OUT[c] then
            out[#out + 1] = ESCAPES_OUT[c]
        elseif code < 32 then
            local high, low = math.floor(code / 16) + 1, (code % 16) + 1
            out[#out + 1] = "\\u00" .. HEX:sub(high, high) .. HEX:sub(low, low)
        else
            out[#out + 1] = c
        end
    end

    return '"' .. table.concat(out) .. '"'
end

-- anything but a table with something in it, as json, or nil for one of those. a whole number
-- goes out with %.0f: every number is a double here, a tile coordinate written as 10629.0 reads
-- like somebody made a mistake, and a time in epoch milliseconds is past what %d is promised to
-- hold. an empty table is written as a list: lua cannot tell an empty list from an empty object,
-- and everything written here that can be empty is a list.
local function zBay_plain(value)
    local kind = type(value)

    if kind == "string" then return zBay_quote(value) end
    if kind == "number" then
        if value == math.floor(value) then return string.format("%.0f", value) end
        return tostring(value)
    end
    if kind == "boolean" then return value and "true" or "false" end
    if kind ~= "table" then return "null" end
    if table.isempty(value) then return "[]" end

    return nil
end

-- the indented writer. keys are sorted, because pairs() has no order and a file that reshuffles
-- itself on every write cannot be diffed or read.
local function zBay_write(value, depth, rank, out)
    local plain = zBay_plain(value)
    if plain then
        out[#out + 1] = plain
        return
    end

    local inner = string.rep("  ", depth + 1)
    local outer = string.rep("  ", depth)

    if #value > 0 then
        out[#out + 1] = "[\n"
        for i, item in ipairs(value) do
            out[#out + 1] = inner
            zBay_write(item, depth + 1, rank, out)
            out[#out + 1] = i < #value and ",\n" or "\n"
        end
        out[#out + 1] = outer .. "]"
        return
    end

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end

    table.sort(keys, function(a, b)
        local ra, rb = rank[a], rank[b]
        if ra and rb then return ra < rb end
        if ra or rb then return ra ~= nil end
        return a < b
    end)

    out[#out + 1] = "{\n"
    for i, key in ipairs(keys) do
        out[#out + 1] = inner .. zBay_quote(key) .. ": "
        zBay_write(value[key], depth + 1, rank, out)
        out[#out + 1] = i < #keys and ",\n" or "\n"
    end
    out[#out + 1] = outer .. "}"
end

-- written to be opened and edited by hand: indented, one key to a line. order names the
-- keys to put first, in that order; anything else follows alphabetically.
function zBay_Json.encode(value, order)
    local rank = {}
    for index, key in ipairs(order or {}) do rank[key] = index end

    local out = {}
    zBay_write(value, 0, rank, out)
    return table.concat(out)
end

-- the one-line writer. keys are sorted, so the same event is the same bytes every time it is
-- written.
local function zBay_writeLine(value, out)
    local plain = zBay_plain(value)
    if plain then
        out[#out + 1] = plain
        return
    end

    if #value > 0 then
        out[#out + 1] = "["
        for i, item in ipairs(value) do
            if i > 1 then out[#out + 1] = "," end
            zBay_writeLine(item, out)
        end
        out[#out + 1] = "]"
        return
    end

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)

    out[#out + 1] = "{"
    for i, key in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = zBay_quote(key) .. ":"
        zBay_writeLine(value[key], out)
    end
    out[#out + 1] = "}"
end

-- the same value with no whitespace and no newline in it, for a file that is one record to
-- a line. a reader can then take a line at a time, and a line cut short by a crash or a
-- half-finished write is one bad record and not a broken file.
function zBay_Json.line(value)
    local out = {}
    zBay_writeLine(value, out)
    return table.concat(out)
end
