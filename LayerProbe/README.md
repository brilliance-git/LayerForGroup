# LayerProbe (WoW: Forever)

A fact-finding addon. Before building LayerLink for real, it collects in-game data to confirm or
rule out each assumption LayerLink relies on. It shows no board and changes nothing. It just
records data and reports. Built for **WoW: Forever** (interface 16001).

| # | Question | How the probe answers it |
|---|---|---|
| Q0 | Does this client have the **LFG API** at all? | Lists every `C_LFGList` function, flags missing ones, and shows which Blizzard LFG addons and frames are loaded. (Another add-on's author reports some classic functions are missing on Forever.) |
| Q1 | Does the LFG tool only show **your** layer? | Every scan is shared with your peers. Scans from different layers taken within 3 minutes of each other are compared. Under 15% shared leaders means layer-limited (LayerLink is worth it). Over 70% means the tool already shows the whole realm. |
| Q2 | Which **message routes** reach another layer? | Every message goes out on a custom channel, guild, and whisper to your peers. The receiver logs which route it arrived on and whether the sender's layer differed. (Custom channels are reported **not** to deliver on Forever. This checks it.) |
| Q3 | What can an addon **read** from a listing? | Saves results, members (level, class, role), activity names, and whether the title/comment are readable, protected tokens or secret values. |
| Q4 | When can an addon **search**? | Tests a button click, a slash command and a timer, and logs blocked actions and failures. |
| Q5 | How many **messages** get through? | `/probe burst 20` sends on every route. The send result code per route is logged, and the other player counts what arrived. |
| Q6 | How do **layers** behave? | Every layer reading and change, by map. Forever's layers are reported to be per zone. |

Forever specifics: names are "First Surname" (the probe uses your full name), and any value the
client marks secret is recorded as `<secret>` rather than crashing.

## Test session (~15 minutes, two players)

You need **two players on different layers**, same realm and faction, both running the probe.
Being in the same guild helps because it tests the guild route too.

1. Both: install `LayerProbe` into `Interface/AddOns` and log in. On login the probe prints your full
   name and any **missing LFG functions**. Run `/probe api` and screenshot the output.
2. Both: **target any NPC** so the probe knows your layer. Stand in different zones, or use different
   layers of the same zone.
3. Each adds the other: `/probe peer First Surname` (your friend's full name).
4. Wait about a minute. Look for **"WHISPER reaches another layer"**, "GUILD …" or "CHANNEL …" (answers Q2).
5. At the same time, both open the LFG tool, pick a category, and hit refresh. Repeat a few times over
   ~10 minutes (answers Q1 and Q3).
6. One player: `/probe scan`, then `/probe button` and click it, then `/probe timerscan`. The timer
   is expected to be blocked (answers Q4).
7. One player: `/probe burst 20`. The other runs `/probe report` and checks "burst received" (answers Q5).
8. Both: `/probe report`, then `/reload` to write
   `WTF/Account/<ACCOUNT>/SavedVariables/LayerProbe.lua`. Send both files for analysis.

`/probe reset` wipes the collected data.
