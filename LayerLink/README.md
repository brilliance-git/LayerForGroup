# LayerLink

A WoW Classic Era addon that combines the in-game **LFG tool** from every layer into one
board for the whole realm. You see groups and solo players from other layers, not just yours.

## How it works

```
 Layer 1: LFG tool ─┐                          ┌─> board (Layer 1 user)
 Layer 2: LFG tool ─┼─> hidden realm channel ──┼─> board (Layer 2 user)
 Layer 3: LFG tool ─┘   "LayerLinkNet"         └─> board (Layer 3 user)
```

Every LayerLink user is a scout for their own layer. Listings reach the network three ways:

| Source | When | Freshness |
|---|---|---|
| **Your own listing** | Automatically, whenever you're listed in the tool (solo, or as group leader) | re-sent every 60s, removed **instantly** when you delist |
| **Scans** | Opening the board (`/ll`), the Scan button, `/ll scan`, or simply browsing Blizzard's LFG panel | every listing found is shared with the network |
| **Catch-up sync** | When you log in, one existing user sends you everything confirmed in the last 5 min | instant board on login |

`C_LFGList.Search` only works from a real click or key press, so LayerLink never searches in the
background. Scans happen whenever someone opens the board or the LFG panel, and with enough users
that keeps every layer fresh.

### Keeping it accurate
- **Snapshot removal:** a complete scan is a full picture of that layer. Any listing previously
  reported from that layer for the searched dungeons that's missing now has been delisted. It gets
  removed for everyone (`G` message).
- **Leader trumps scouts:** if the leader runs LayerLink, their own reports outrank "it's gone"
  scans for 2.5 minutes, and their delist is instant.
- **Expiry:** anything nobody has re-confirmed for 10 minutes disappears.
- **"any" layer:** if scouts on different layers all see the same listing, the tool wasn't
  layer-limited for it, so it's tagged `any`. No single layer can declare it gone.
- **Bandwidth:** relays are delayed randomly by 0–3s and skipped if someone on your layer already
  sent the same listing. Each listing is re-announced at most every 45s, sending is paced at 1
  message per second, and anyone sending more than 90 messages a minute is ignored.

Layer detection reads the `zoneUID` in open-world creature GUIDs (target, mouseover, nameplates).
Layers are labelled `L1, L2…` in zone-id order.

## Board

- **Radar:** groups and solo players per layer. Your own layer is starred.
- **Tabs:** All, Groups, or Solo (people listed alone in the tool).
- **Columns:** layer, activity, size, roles still needed (groups) or roles they can fill (solo),
  leader, level and class, when it was listed, and when it was last confirmed.
- **Tooltip:** shows the layer and warns *"joining will move you to L2"*, plus which scouts confirmed
  it and whether the leader runs LayerLink.
- **Click a row** to open a pre-filled whisper. You press Enter yourself, so nothing is automated.

## Commands

```
/ll                                  toggle the board (and scan your layer)
/ll scan                             search the LFG tool on your layer and share it
/ll watch <dungeon> [tank|heal|dps]  alert when a group with room for you appears on any layer
/ll recruit <dungeon> [tank|heal|dps] alert when a matching solo player lists on any layer
/ll watch list | clear
/ll layer                            show your detected layer
/ll share on|off                     relay what you see (default on)
/ll alerts on|off                    watchlist alerts (default on)
/ll autoscan on|off                  scan when opening the board (default on)
```

## Install

Copy this `LayerLink` folder into `World of Warcraft/_classic_era_/Interface/AddOns/`.
`## Interface: 11509` matches client 1.15.9. If the game says the addon is out of date, run
`/dump select(4, GetBuildInfo())` in game and put that number in `LayerLink.toc`.

## Development

```
lua5.1 tests/run.lua
```

`Dungeons.lua` holds the dungeon list and maps activity names to dungeons. `Board.lua` merges and
expires listings and handles layers, snapshots and role needs. `Comm.lua` has the network format and
the hidden channel. `Layer.lua` detects your layer, `UI.lua` draws the window, and `Core.lua` covers
tool harvesting, publishing your own listing, sync, the watchlist and slash commands. The API usage
is based on Blizzard's Classic Era 1.15.9 UI source (`Blizzard_GroupFinder_VanillaStyle`).

### Wire format (v2), `^`-separated

```
2^L^leader^BRD,LBRS^G|S^size^tanks^healers^dps^soloRoles(THD)^level^CLASS^layer^age^listedAge
2^X^leader          delist (only accepted from the leader)
2^G^leader^layer    gone from a complete scan of that layer
2^S                 sync request        2^R   sync reply starting (others stand down)
```

## Known limits / verify in game

- Listing **titles and comments are protected strings** in the LFG API. Other clients can't read them,
  so LayerLink shares structure (activity, roles, size, level, class) but never the text.
- Same realm and same faction only. Addon messages can't cross either.
- Confirm in game that the custom channel spans every layer, and that the tool's results really are
  limited to your layer. If scouts on different layers keep seeing the same listings, the board will
  tag them `any`.
- Running a scan replaces the results shown in Blizzard's own LFG panel, the same as searching there.
- Role counts for groups depend on members having an assigned role. Otherwise the board just shows open slots.
