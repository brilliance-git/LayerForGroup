-- Dungeon / raid catalogue for Classic Era plus the chat aliases people actually type.
local _, ns = ...

ns.Dungeons = {
  { key = "RFC",    name = "Ragefire Chasm",       min = 13, max = 18, aliases = { "rfc", "ragefire", "ragefire chasm" } },
  { key = "WC",     name = "Wailing Caverns",      min = 17, max = 24, aliases = { "wc", "wailing caverns", "wailing" } },
  { key = "VC",     name = "Deadmines",            min = 17, max = 26, aliases = { "dm", "vc", "deadmines", "the deadmines" } },
  { key = "SFK",    name = "Shadowfang Keep",      min = 22, max = 30, aliases = { "sfk", "shadowfang", "shadowfang keep" } },
  { key = "BFD",    name = "Blackfathom Deeps",    min = 24, max = 32, aliases = { "bfd", "blackfathom", "blackfathom deeps" } },
  { key = "STOCKS", name = "Stormwind Stockade",   min = 24, max = 32, aliases = { "stocks", "stockade", "stockades", "the stockade" } },
  { key = "GNOMER", name = "Gnomeregan",           min = 29, max = 38, aliases = { "gnomer", "gnomeregan", "gnome" } },
  { key = "RFK",    name = "Razorfen Kraul",       min = 29, max = 38, aliases = { "rfk", "razorfen kraul", "kraul" } },
  { key = "SMGY", parent = "SM",   name = "SM Graveyard",         min = 28, max = 38, aliases = { "sm gy", "smgy", "gy", "graveyard", "sm graveyard", "scarlet monastery graveyard", "scarlet graveyard" } },
  { key = "SMLIB", parent = "SM",  name = "SM Library",           min = 31, max = 40, aliases = { "sm lib", "smlib", "lib", "library", "sm library", "scarlet monastery library", "scarlet library" } },
  { key = "SMARM", parent = "SM",  name = "SM Armory",            min = 33, max = 42, aliases = { "sm arm", "smarm", "arm", "armory", "armoury", "sm armory", "scarlet monastery armory", "scarlet armory", "scarlet armoury" } },
  { key = "SMCATH", parent = "SM", name = "SM Cathedral",         min = 35, max = 44, aliases = { "sm cath", "smcath", "cath", "cathedral", "sm cathedral", "scarlet monastery cathedral", "scarlet cathedral" } },
  { key = "SM",     name = "Scarlet Monastery",    min = 28, max = 44, aliases = { "sm", "scarlet", "scarlet monastery" } },
  { key = "RFD",    name = "Razorfen Downs",       min = 36, max = 46, aliases = { "rfd", "razorfen downs", "downs" } },
  { key = "ULDA",   name = "Uldaman",              min = 40, max = 51, aliases = { "ulda", "uld", "uldaman" } },
  { key = "ZF",     name = "Zul'Farrak",           min = 42, max = 51, aliases = { "zf", "zul farrak", "zulfarrak" } },
  { key = "MARA",   name = "Maraudon",             min = 46, max = 55, aliases = { "mara", "maraudon", "princess run" } },
  { key = "ST",     name = "Sunken Temple",        min = 50, max = 58, aliases = { "st", "sunken temple", "sunken", "temple of atal hakkar", "temple of atalhakkar", "atalhakkar" } },
  { key = "BRD",    name = "Blackrock Depths",     min = 52, max = 60, aliases = { "brd", "blackrock depths", "emp run", "emperor run", "arena run", "lava run" } },
  { key = "LBRS",   name = "Lower Blackrock Spire", min = 55, max = 60, aliases = { "lbrs", "lower blackrock", "lower blackrock spire", "blackrock spire lower" } },
  { key = "UBRS",   name = "Upper Blackrock Spire", min = 58, max = 60, size = 10, aliases = { "ubrs", "upper blackrock", "upper blackrock spire", "blackrock spire upper", "rend run" } },
  { key = "DME", parent = "DIREMAUL",    name = "Dire Maul East",       min = 55, max = 60, aliases = { "dme", "dm e", "dm east", "dire maul east", "jump run", "lashers", "warpwood quarter", "warpwood" } },
  { key = "DMW", parent = "DIREMAUL",    name = "Dire Maul West",       min = 57, max = 60, aliases = { "dmw", "dm w", "dm west", "dire maul west", "capital gardens" } },
  { key = "DMN", parent = "DIREMAUL",    name = "Dire Maul North",      min = 57, max = 60, aliases = { "dmn", "dm n", "dm north", "dire maul north", "dm trib", "dmt", "tribute", "tribute run", "dire maul tribute", "gordok commons", "gordok" } },
  { key = "DIREMAUL", name = "Dire Maul",          min = 55, max = 60, aliases = { "dire maul", "diremaul" } },
  { key = "STRATUD", parent = "STRAT",  name = "Strat Undead",       min = 58, max = 60, aliases = { "strat ud", "stratud", "ud strat", "strat dead", "strat undead", "stratholme undead", "service entrance", "baron run", "baron" } },
  { key = "STRATLIVE", parent = "STRAT", name = "Strat Live",        min = 58, max = 60, aliases = { "strat live", "stratlive", "live strat", "strat living", "stratholme live", "stratholme living", "main gate" } },
  { key = "STRAT",  name = "Stratholme",           min = 58, max = 60, aliases = { "strat", "stratholme" } },
  { key = "SCHOLO", name = "Scholomance",          min = 58, max = 60, aliases = { "scholo", "scholomance", "sholo", "scholo run" } },
  -- raids
  { key = "ONY",  name = "Onyxia's Lair",   raid = true, size = 40, aliases = { "ony", "onyxia", "onyxias lair", "onyxia s lair" } },
  { key = "MC",   name = "Molten Core",     raid = true, size = 40, aliases = { "mc", "molten core" } },
  { key = "BWL",  name = "Blackwing Lair",  raid = true, size = 40, aliases = { "bwl", "blackwing", "blackwing lair" } },
  { key = "ZG",   name = "Zul'Gurub",       raid = true, size = 20, aliases = { "zg", "zul gurub", "zulgurub" } },
  { key = "AQ20", name = "Ruins of Ahn'Qiraj",  raid = true, size = 20, aliases = { "aq20", "aq 20", "ruins of ahn qiraj", "ruins of ahnqiraj", "ruins" } },
  { key = "AQ40", name = "Temple of Ahn'Qiraj", raid = true, size = 40, aliases = { "aq40", "aq 40", "temple of ahn qiraj", "temple of ahnqiraj", "ahnqiraj temple", "ahn qiraj temple" } },
  { key = "NAXX", name = "Naxxramas",       raid = true, size = 40, aliases = { "naxx", "naxxramas" } },
}

ns.DungeonByKey = {}
for _, d in ipairs(ns.Dungeons) do
  d.size = d.size or 5
  ns.DungeonByKey[d.key] = d
end

-- Map an LFG-tool activity name ("Scarlet Armory", "Dire Maul - East") or a user's
-- shorthand ("strat ud") to a dungeon key. A wing beats its parent dungeon
-- ("scarlet armory" -> SMARM, not SM); otherwise the longest alias wins.
local ALIASES = {}
for _, d in ipairs(ns.Dungeons) do
  for _, a in ipairs(d.aliases) do ALIASES[#ALIASES + 1] = { pat = " " .. a .. " ", key = d.key, len = #a } end
end
table.sort(ALIASES, function(a, b) if a.len ~= b.len then return a.len > b.len end return a.key < b.key end)

function ns.Normalize(text)
  local s = (text or ""):lower():gsub("'", ""):gsub("[^%w]", " "):gsub("%s+", " ")
  return (s:gsub("^ ", ""):gsub(" $", ""))
end

function ns.MatchDungeon(text)
  if ns.DungeonByKey[(text or ""):upper()] then return text:upper() end
  local padded = " " .. ns.Normalize(text) .. " "
  local hits, first = {}, nil
  for _, a in ipairs(ALIASES) do -- longest first
    if padded:find(a.pat, 1, true) and not hits[a.key] then
      hits[a.key] = true
      first = first or a.key
    end
  end
  if not first then return nil end
  local parent = ns.DungeonByKey[first].parent and first or nil
  if not parent then
    for _, a in ipairs(ALIASES) do -- longest wing whose parent also matched
      local d = ns.DungeonByKey[a.key]
      if hits[a.key] and d.parent and hits[d.parent] then return a.key end
    end
  end
  return first
end
