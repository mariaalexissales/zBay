# zBay

A marketplace for Project Zomboid multiplayer servers (Build 42.20+): fixed-price listings, auctions, a bank, mail for what you can't carry, and a Discord bridge. Requires [NeatUI Framework](https://steamcommunity.com/sharedfiles/filedetails/?id=3508537032).

Players right-click the ground and choose **Open zBay**.

## Settings

The first time a world starts, the mod writes two files into `Zomboid/Lua/zBay/` on the machine running the server. On a host that gives the server its own data folder they are in there instead, for example `server-data/Lua/zBay/`.

Edit, save, then press **Reload Settings** in the zBay window (admins only). A file that won't parse leaves the old settings in force and the console names the line. `//` comments, trailing commas and Notepad's byte-order mark are all fine.

### config.json

```json
{
  "currency": {
    "name": "Dollars",
    "symbol": "$",
    "items": [
      { "item": "Base.Money", "value": 1 },
      { "item": "Base.MoneyBundle", "value": 100 }
    ]
  },
  "market":  { "feePercent": 5, "maxListingsPerPlayer": 20, "listingHours": 72, "pageSize": 50 },
  "auction": { "enabled": true, "durationsHours": [1, 6, 24, 72], "minIncrementPercent": 5,
               "antiSnipeMinutes": 2, "allowBuyout": true },
  "blacklist": { "items": ["Base.KeyRing", "Base.IDcard"], "categories": [] },
  "mailbox": { "required": true, "reach": 2, "deliverToInventory": true,
               "sprites": ["street_decoration_01_18", "street_decoration_01_19",
                           "street_decoration_01_20", "street_decoration_01_21"] },
  "backup": { "enabled": true, "minutes": 10 }
}
```

| Key | What it does | Range |
|---|---|---|
| `currency.items` | What players pay with. Each entry is an item and what one is worth. Any item works, modded ones included. | value 1 to 1,000,000 |
| `currency.symbol` | Printed before amounts. Leave empty to print `name` after them instead. | |
| `market.feePercent` | The market's cut of every sale, rounded down. It leaves the economy. | 0 to 50 |
| `market.maxListingsPerPlayer` | Listings and auctions one player can have up at once. | 1 to 200 |
| `market.listingHours` | Real hours before a fixed-price listing comes down and its stock goes home. | 1 to 720 |
| `market.pageSize` | Listings per page. | 10 to 100 |
| `auction.durationsHours` | The lengths a seller can pick, in real hours. Up to six. | 1 to 168 each |
| `auction.minIncrementPercent` | How much a bid has to beat the last one by. Always at least 1 unit. | 1 to 100 |
| `auction.antiSnipeMinutes` | A bid this close to the end pushes the end out to this long from now. 0 turns it off. | 0 to 30 |
| `blacklist.items` / `.categories` | Full item types and display categories that can't be listed. | |
| `mailbox.required` | `true`: mail is collected at a mailbox the player has claimed. `false`: there's a Collect button in the window. | |
| `mailbox.reach` | How many tiles from the mailbox counts as standing at it. | 1 to 5 |
| `mailbox.deliverToInventory` | `false` sends every purchase to mail, even when it would fit. | |
| `mailbox.sprites` | Which tiles are mailboxes. Add your map's own. | |
| `backup.enabled` | Keep `backup_<world>.json` beside this file. | |
| `backup.minutes` | How often it's rewritten, in real minutes, while anything has changed. | 1 to 120 |

Balances are plain numbers, so changing the currency never wipes the bank. What a player is owed stays the same; only what it's paid out in changes.

If nothing in `currency.items` is worth 1, amounts that aren't a multiple of the smallest note can't be withdrawn. The remainder stays in the bank.

### Things worth knowing

- **Time is real time.** Auctions and listings end on the wall clock, whether the server was up or not. One that ended while it was down settles on the first tick after boot.
- **Bids are held.** A bid leaves the bidder's bank when it's placed and comes back the moment they're outbid.
- **Mail is kept by the server**, not in the mailbox's own container. Nobody can loot it, and it survives the mailbox being picked up or destroyed. The player claims another.
- **Vanilla mailboxes** are `street_decoration_01_18` to `_21`, and players can pick them up and carry them home. The blue public mail box, `street_decoration_01_8` to `_11`, is left out on purpose and reserved for PO boxes later.
- **What can't be listed:** equipped or favourited items, bags with something in them, the currency itself, patched clothing, and anything the mod can't rebuild exactly. Map annotations and handwritten pages aren't carried over.
- **One press moves at most 200 currency items** in or out of the bank, and one collection hands over at most 60 items. Press again for the rest.

### Backup

With `backup.enabled`, every balance, listing and mailbox is also written to `Zomboid/Lua/zBay/backup_<world>.json` every `backup.minutes` while anything has changed, with the one before it kept as `backup_<world>_prev.json`. It runs off the server's own clock: a dedicated server never fires the game's save event, so there's nothing else to hang it on. Singleplayer and hosted games write it on each save as well. Nothing reads it back on its own. An admin presses **Restore Backup** on the Bank tab when they've decided the file is the one to keep, which is after a server was killed instead of shut down, or after a rollback.

## Discord bridge

The game can't open a network connection from Lua, so it talks to Discord through files in `Zomboid/Lua/zBay/bridge/` and a small relay program run beside the server. `discord.json` holds the switches:

```json
{
  "enabled": false,
  "endpoint": "",
  "serverKey": "",
  "pollSeconds": 5,
  "snapshotSeconds": 60,
  "events": { "listing": true, "sale": true, "auctionStart": true, "bid": false, "auctionEnd": true }
}
```

The game reads `enabled`, the two intervals and `events`. `endpoint` and `serverKey` are for the relay; the game never keeps them.

| File | Written by | What it is |
|---|---|---|
| `out_<boot>.log` | game | One JSON record per line. A new file each boot, only ever appended to. The relay deletes the ones it's finished with. |
| `snapshot.json` | game | What's for sale now, newest 400. Rewritten when the market has moved, at most every `snapshotSeconds`. |
| `in.log` | relay | One JSON command per line: `{"seq": 1, "epoch": "<relay id>", "type": "...", ...}`. |
| `in_ack.json` | game | `{"seq": n, "epoch": "..."}`: the last command acted on, so the relay knows what it can clear. |

The names are what the game will write. Its file API only allows `.ini`, `.cfg`, `.txt`, `.log` and `.json`, and returns nothing for anything else without logging it.

Records the game writes: `hello` (first record of each boot, with the world's name and the currency's `name` and `symbol`), `config` (the currency again, when the settings are reloaded), `listing`, `sale`, `auctionStart`, `bid`, `auctionEnd`, `notice` (something for one linked player: `Sold`, `Outbid`, `Won`, `AuctionSold`, `NoBids`, `Expired`, `Mail`, `Removed`, `BidReturned`), `linked`, `unlinked`, `reply`. Every record has `seq`, counting up with no gaps across boots, and `t` in epoch milliseconds.

Commands the game reads: `link_offer` (`code`, `discordId`, optional `expires`), `unlink` (`discordId`), `balance_query` (`discordId`, `replyTo`). A relay that restarts its `seq` from 1 says so by changing `epoch`.

To have the inbox read at once rather than at the next poll, send `reloadlua zBay_BridgePoke.lua` over RCON after writing to it.

## Working on it

Checks and tests are in `estral-tools/zbay/` and run from this folder:

```bash
python ../estral-tools/zbay/check_lua.py
python ../estral-tools/zbay/check_runtime.py
python ../estral-tools/zbay/check_translations.py
python ../estral-tools/zbay/harness/run_tests.py
```

### Translation strings

A string in `Translate/<LANG>/IG_UI.json` is a Java format string, not plain text. The game turns `%1` to `%9` into `%1$s` to `%9$s` when it loads the file and runs `String.format` on every `getText`.

- `%1` to `%9` are the only placeholders.
- A literal percent sign is `%%`, even in a string that takes no arguments. `"keeps %1% of a sale"` is read as `% o`, an octal conversion.
- Give `getText` at least as many arguments as the highest `%N`.

Getting it wrong doesn't crash. The game logs `Translator.reportMissingArgumentsFromPastAbuse ... Formatting "<KEY>"` on every call, which is every frame for text drawn in `render`, and shows a mangled string with a stray `$s`. `check_translations.py` catches it, along with missing keys, unused keys and codes the server can answer with that have no string.

A local test server and two clients:

```bash
python ../estral-tools/servers/serve.py --server zbaytest
python ../estral-tools/servers/client.py
python ../estral-tools/servers/client.py --second
```
