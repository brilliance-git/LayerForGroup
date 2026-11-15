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

## Realm test with friends who DON'T have the addon (recommended)

You run the probe. Your friends only paste two chat lines, nothing installed.

1. You: `/probe macros <dungeon>` (e.g. `/probe macros armory`). A window opens with instructions and
   two `/run` lines, already filled in with the dungeon and your name. Copy it (Cmd+C) and send it to
   friends on other realms (same faction), e.g. on Discord.
2. Friends: paste line 1 in the chat box, Enter (searches the LFG tool). Wait 3 s, paste line 2,
   Enter (sends the results to you as invisible addon messages, so nothing shows in chat).
3. You: click **Take snapshot** at about the same time. As each friend's results arrive, your chat
   prints e.g. `Thrall Doom-Realm2 (Realm2): 22 listings, 0 shared with your 14 -> merged list 36 (2.6x yours)`.
   A friend on your own realm is the control and should share almost everything.
4. `/probe report` lists every friend's result again under REMOTE.

Notes: a friend whose search finds nothing sends nothing, so pick a busy dungeon. WoW may ask a friend
to confirm running a script the first time. Only party IDs are sent, so no names or chat.

## Realm snapshot (one command, anyone with the addon)

Tests whether each realm's LFG tool shows only its own players. Players on **different realms** each:

```
/probe snapshot <dungeon>      e.g. /probe snapshot armory - shows a "Take snapshot" button
```

Target an NPC, then click **Take snapshot** (searching needs a click). A window opens with the text
already selected. Press Cmd+C (Mac) or Ctrl+C and paste it anywhere: Discord, a file, a chat. If
the last line says some names weren't loaded, click again ~5 s later.

Take the snapshots within a few minutes of each other, for the same dungeon. Then compare:

```
python3 tools/compare_snapshots.py realm5.txt realm2.txt ...
```

It reports the shared % per pair (same realm = control, other realm = the question) and how much
bigger a merged list would be. Each listing carries its party ID, so listings match even without names.

## Quick two-player test (~10 minutes)

Both players, with your layers on different zone copies (or in different zones):

```
/probe dungeon <name>          both pick the SAME dungeon, ideally a busy one
/probe duo First Surname       the other player's full name; prints these steps
```

Then target any NPC, click the **Scan** button together 5 times about 30 s apart, have one player
invite the other (the invited one keeps mousing over NPCs), and finish with `/probe report` and
`/reload`. Only complete searches (under 100 results) are compared, because a capped search returns
a different 100 each time. That's why a single dungeon is needed.

## Full test plan (~30 minutes, two players)

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
