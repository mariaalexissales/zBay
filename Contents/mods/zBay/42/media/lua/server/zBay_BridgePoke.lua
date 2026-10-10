----------
--ESTRAL--
----------

-- rcon has no way to call into lua, but it can run a file again:
--
--     reloadlua zBay_BridgePoke.lua
--
-- so running this file is the command, and what it does is read the bridge's inbox now
-- rather than at the next poll. the relay sends it after writing a command when it has been
-- given the rcon password, which turns a wait of a few seconds into none.
--
-- nothing in here may add an event or keep anything, or every poke would leave another copy
-- behind. when the game first loads it the bridge is not up yet, and it does nothing.

require "zBay_Bridge"

if zBay_Bridge and zBay_Bridge.ready then zBay_Bridge.pump(true) end
