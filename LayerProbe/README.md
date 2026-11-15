# LayerProbe (WoW: Forever)

A fact-finding addon for one goal: **a bigger LFG list for a dungeon**, built by combining what
LFG-tool users on different layers (and realms) can each see. Before building that, LayerProbe
measures every assumption in game. It shows no board and changes nothing. It records data and
answers each question in `/probe report`.

## What it answers

| Area | # | Question | How |
|---|---|---|---|
| Tool | Q0 | Which LFG functions exist? | Inventory of `C_LFGList`, Blizzard LFG addons and frames |
| | Q1 | Do different layers see different listings? | Your scans vs a peer's scans from another layer within 3 min. Shows % shared and **how many times bigger the merged list is**. |
| | Q2 | Does the tool show other realms? | Realm part of every leader's name |
| | Q3 | Does the tool only show your zone? | Leaders' current zone vs yours |
| | Q4 | What can be read? | Leader, title/comment (readable, protected token, or secret), member counts, level, class, role, zone |
| | Q5 | When can we search, and how often? | Button, slash and timer, plus the shortest gap between searches that still returns results |
| | Q6 | How long do listings live? | How long each leader stays listed, churn between scans |
| | Q7 | **For your dungeon**: how many groups and solo players, and how much the list grows when merged across layers | `/probe dungeon <name>` focuses scans |
| | Q8 | Can an addon read **your own** listing (to share it automatically)? | Logged whenever you list or delist |
| Network | Q9 | Which routes deliver, across layers? | Every message goes on custom channel, guild, party and whisper. The receiver records the route. |
| | Q10 | Can addon users **find each other**? | Joins a channel and reads the member lists of our channel and General |
| | Q11 | Sustained throughput | `/probe rate 2 60` whispers 2 msgs/s for 60 s. The peer counts what arrived. Result codes (e.g. throttled) are logged. |
| Layers | Q12 | How do layers behave? | Zone ids per map, and **seconds from joining a group to changing layer** |
| | Q13 | When does data go secret? | Secret fields per scan with instance and chat-lockdown flags |

## Test plan (~30 minutes, two players)

You need **two players on different layers**: same realm type and faction, ideally the same guild
(it tests the guild route too). A friend or a second account works.

**Setup (both players)**
1. Install `LayerProbe` into `_forever_/Interface/AddOns` and log in. Note any **missing LFG
   functions** it prints, then run `/probe api`.
2. Target or mouse over any NPC so your layer is known. Stay in **different layers** of the same
   zone, or different zones.
3. `/probe peer First Surname`, using the other player's full name.
4. `/probe dungeon` lists every activity. Pick the dungeon you care about, e.g. `/probe dungeon scarlet`.
   Both players pick the same one.

**Tool tests (both, at the same time)**

5. Click `/probe button`'s **Scan** button, or refresh Blizzard's LFG tool. Repeat every minute or
   so for 10 minutes. Busy times give the best numbers (Q1–Q4, Q6, Q7).
6. One player: click Scan twice quickly, then `/probe scan`, then `/probe timerscan`. The timer search
   is expected to be blocked (Q5).
7. One player: list yourself in the tool for a minute, then delist (Q8).

**Network tests**

8. `/probe roster` on both (Q10).
9. One player: `/probe burst 20`, then `/probe rate 1 60`, then `/probe rate 3 30`. The other player
   checks the report afterwards (Q9, Q11).

**Layer test**

10. Player A invites player B. B keeps mousing over NPCs. The probe prints how many seconds the layer
    change took (Q12). Leave the group and repeat once.

**Wrap up**

11. Both: `/probe report`, then `/reload`. Send both
    `WTF/Account/<ACCOUNT>/SavedVariables/LayerProbe.lua` files for analysis.

Other commands: `/probe peer clear`, `/probe dungeon all`, `/probe reset` (wipes data).

## Notes

- Names on Forever are "First Surname". The probe uses full names and tags leaders "Name-Realm".
- Anything the client marks secret is saved as `<secret>` rather than breaking the probe.
- Other Forever addons report that custom channels refuse addon messages (since 11-07) and that
  search needs a click. The probe verifies both rather than assuming.
