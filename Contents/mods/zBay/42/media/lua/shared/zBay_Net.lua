----------
--ESTRAL--
----------

require "zBay_Core"

zBay_Net = zBay_Net or {}

-- looked up at call time: shared/ loads before client/ and server/, so neither dispatcher
-- exists yet when this file runs.
local function zBay_serverHandler(command)
    return zBay_Commands and zBay_Commands.handlers and zBay_Commands.handlers[command]
end

local function zBay_clientHandler()
    return zBay_ClientState and zBay_ClientState.onCommand
end

-- the no-remote-server tail of both toClient and toAll: with nobody to send to, one client and
-- every client are the same client.
local function zBay_dispatchLocal(command, args)
    local handler = zBay_clientHandler()
    if not handler then return end

    local ok, err = pcall(handler, zBay.MODULE, command, args)
    if not ok then zBay.warn("client handler " .. tostring(command) .. " failed: " .. tostring(err)) end
end

-- with no remote server the send is a direct call into the handler that would have received
-- it, so singleplayer runs the same market code the server does. on a multiplayer client the
-- player is nil this early, and handing nil to sendClientCommand loses the packet without a
-- word: it is said, and the caller retries.
function zBay_Net.toServer(command, args)
    args = args or {}

    if zBay.hasRemoteServer() then
        local player = getPlayer()
        if not player then
            zBay.warn("no local player yet, dropped " .. tostring(command))
            return
        end

        sendClientCommand(player, zBay.MODULE, command, args)
        return
    end

    local handler = zBay_serverHandler(command)
    if not handler then
        zBay.warn("no server handler for " .. tostring(command))
        return
    end

    local ok, err = pcall(handler, getPlayer(), args)
    if not ok then zBay.warn("server handler " .. tostring(command) .. " failed: " .. tostring(err)) end
end

function zBay_Net.toClient(player, command, args)
    args = args or {}

    if isServer() then
        sendServerCommand(player, zBay.MODULE, command, args)
        return
    end

    zBay_dispatchLocal(command, args)
end

function zBay_Net.toAll(command, args)
    args = args or {}

    if isServer() then
        sendServerCommand(zBay.MODULE, command, args)
        return
    end

    zBay_dispatchLocal(command, args)
end
