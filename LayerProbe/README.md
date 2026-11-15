# LayerProbe

A fact-finding addon. Before building LayerLink for real, it collects in-game data to confirm or
rule out each assumption LayerLink relies on. It shows no board and changes nothing. It just
records data and reports.

| # | Question | How the probe answers it |
|---|---|---|
| Q1 | Does the LFG tool only show **your** layer? | Every scan shares its list of leaders with other probes. Scans from different layers taken within 3 minutes of each other are compared. Under 15% overlap means the tool is layer-limited and LayerLink is worth building. Over 70% means the tool already shows the whole realm. |
| Q2 | Does a hidden custom channel reach **other layers**? | Probes ping every 60s with their layer id. One ping from another layer proves it does. |
| Q3 | What can an addon **read** from a listing? | Saves full result tables, member info (role, level, class), every activity's info (exact names!), and whether the title/comment are readable or protected tokens. |
| Q4 | When can an addon **search**? | Tests a button click, a slash command and a timer, and logs `ADDON_ACTION_BLOCKED` / search failures for each. |
| Q5 | How many **messages** can we send? | `/probe burst 20` and the other probe counts how many arrive. The send result codes are logged too. |
| Q6 | How reliable is **layer detection**? | Every NPC zone-id sample and layer change, with map id. |

## How to run a test session (~15 minutes)

You need **two players on different layers**, both running the probe, on the same realm and faction.
Use a friend, or an alt on a second account.

1. Both: install `LayerProbe` into `Interface/AddOns`, log in, and **target any NPC** so the probe knows your layer.
   Confirm with `/probe report`. The Q6 line should show a zone id, and the two of you should have different ones.
2. Wait about a minute. The pings should print **"cross-layer ping received"** (answers Q2).
3. At the same time, both open the LFG tool, pick Dungeons, and hit refresh. Do this a few times over
   10 minutes, and once in a busy period if you can (answers Q1 and Q3).
4. One player: `/probe scan`, then `/probe button` and click the button, then `/probe timerscan`. The
   timer one is expected to be blocked, and that's the finding (answers Q4).
5. One player: `/probe burst 20`, then the other runs `/probe report` and checks how many arrived (answers Q5).
6. Both: `/probe report`, then `/reload` to write the data to
   `WTF/Account/<ACCOUNT>/SavedVariables/LayerProbe.lua`. Send those two files over and they can be
   analysed in detail.

`/probe reset` wipes the collected data.
