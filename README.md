# LayerForGroup

Two WoW Classic Era addons:

- **[LayerProbe](LayerProbe/README.md)**: run this first. It's a fact-finding addon that checks
  in-game whether the idea works: is the LFG tool per-layer, does a hidden channel cross layers,
  and what can addons read and send.
- **[LayerLink](LayerLink/README.md)**: the actual addon. It combines every layer's LFG tool into one
  board for the whole realm.

Install: copy a folder into `World of Warcraft/_classic_era_/Interface/AddOns/`.

Tests: `cd LayerLink && lua5.1 tests/run.lua`
