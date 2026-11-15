-- The shared board: one row per LFG-tool listing (a group, or a solo player),
-- merged from local scans, auto-published own listings and network reports.
-- Pure Lua (time is passed in), unit-tested in tests/run.lua.
local _, ns = ...
local Board = {}
Board.__index = Board
ns.Board = Board

Board.TTL = 600       -- a listing nobody has re-confirmed for 10 min is dropped
Board.OWN_GRACE = 150 -- a leader's own report outranks "it's gone" scans for this long

function Board.New() return setmetatable({ entries = {} }, Board) end

function Board.MakeId(leader) return leader:lower() end

local FIELDS = { "dungeons", "type", "size", "t", "h", "d", "roles", "level", "class" }

-- o = { leader, dungeons = {keys}, type = "G"|"S", size, t, h, d, roles, level, class,
--       layer, scout, source = "A"(own) | "T"(tool scan) | "N"(network), age, listedAge }
function Board:Upsert(o, now)
  local id = Board.MakeId(o.leader)
  local seenAt = now - math.max(0, math.min(o.age or 0, Board.TTL))
  local e, isNew = self.entries[id], false
  if not e then
    e = { id = id, leader = o.leader, firstSeen = seenAt, lastSeen = seenAt,
          layers = {}, scouts = {}, scoutCount = 0, sources = "", netLayers = {} }
    self.entries[id] = e
    isNew = true
  end
  if isNew or seenAt >= e.lastSeen then -- freshest report wins the descriptive fields
    for _, k in ipairs(FIELDS) do if o[k] ~= nil then e[k] = o[k] end end
    if o.listedAge then e.listedAt = seenAt - o.listedAge end
    e.lastSeen = seenAt
  end
  if o.source == "A" then e.ownAt = seenAt end
  if o.layer and o.layer ~= "" then e.layers[o.layer] = true end
  if o.scout and not e.scouts[o.scout] then e.scouts[o.scout] = true; e.scoutCount = e.scoutCount + 1 end
  if o.source and not e.sources:find(o.source, 1, true) then e.sources = e.sources .. o.source end
  return e, isNew
end

function Board:Remove(id) self.entries[id] = nil end

-- A scout on `layer` reports the listing is no longer in the tool. Ignored if the
-- listing was seen on another layer too, or its leader vouched for it recently.
function Board:RemoveGone(leader, layer, now)
  local e = self.entries[Board.MakeId(leader)]
  if not e or Board.LayerOf(e) ~= layer then return false end
  if e.ownAt and now - e.ownAt < Board.OWN_GRACE then return false end
  self.entries[e.id] = nil
  return true
end

-- A complete scan by a scout on `layer` covering dungeon keys `covered` saw
-- exactly the leaders in `seen` (set of ids). Everything else from that layer
-- for those dungeons is gone. Returns the removed leaders.
function Board:ApplySnapshot(layer, covered, seen, now)
  local removed = {}
  if not layer or layer == "" then return removed end
  for id, e in pairs(self.entries) do
    if not seen[id] and Board.LayerOf(e) == layer and not (e.ownAt and now - e.ownAt < Board.OWN_GRACE) then
      for _, k in ipairs(e.dungeons or {}) do
        if covered[k] then self.entries[id] = nil; removed[#removed + 1] = e.leader; break end
      end
    end
  end
  table.sort(removed)
  return removed
end

function Board:Prune(now)
  for id, e in pairs(self.entries) do
    if now - e.lastSeen > Board.TTL then self.entries[id] = nil end
  end
end

-- "" = unknown, "?" = seen from several layers (so the tool showed it everywhere), else a zone UID.
function Board.LayerOf(e)
  local only, n = nil, 0
  for l in pairs(e.layers) do only, n = l, n + 1 end
  if n == 0 then return "" end
  if n > 1 then return "?" end
  return only
end

-- What a group still needs. Roles are only trusted when every member has one assigned.
function Board.Needs(e)
  local d = ns.DungeonByKey[(e.dungeons or {})[1] or ""]
  local max = d and d.size or 5
  local size = e.size or 1
  local n = { open = math.max(0, max - size), max = max, known = false }
  if max == 5 and (e.t or 0) + (e.h or 0) + (e.d or 0) == size then
    n.known = true
    n.T = (e.t or 0) == 0
    n.H = (e.h or 0) == 0
    n.D = math.max(0, 3 - (e.d or 0))
  end
  return n
end

-- Does this listing want/offer `role` ("T"/"H"/"D")?
function Board.Wants(e, role)
  if e.type == "S" then return (e.roles or ""):find(role, 1, true) ~= nil end
  local n = Board.Needs(e)
  if n.open == 0 then return false end
  if not n.known then return true end
  if role == "D" then return n.D > 0 end
  return n[role] == true
end

function Board.DungeonNames(e)
  local names = {}
  for _, k in ipairs(e.dungeons or {}) do
    local d = ns.DungeonByKey[k]
    names[#names + 1] = d and d.name or k
  end
  return names
end

local function matches(e, q)
  if not q or q == "" then return true end
  local hay = (table.concat(e.dungeons or {}, " ") .. " " .. table.concat(Board.DungeonNames(e), " ")
               .. " " .. e.leader .. " " .. (e.class or "")):lower()
  return hay:find(q:lower(), 1, true) ~= nil
end

function Board:List(now, query, typeFilter)
  local out = {}
  for _, e in pairs(self.entries) do
    if now - e.lastSeen <= Board.TTL and matches(e, query) and (not typeFilter or e.type == typeFilter) then
      out[#out + 1] = e
    end
  end
  table.sort(out, function(a, b)
    local ka, kb = a.listedAt or a.firstSeen, b.listedAt or b.firstSeen
    if ka ~= kb then return ka > kb end -- newest listings first
    return a.id < b.id
  end)
  return out
end

-- Freshest entries, for answering a sync request from someone who just logged in.
function Board:Freshest(now, maxAge, limit)
  local out = {}
  for _, e in pairs(self.entries) do
    if now - e.lastSeen <= maxAge then out[#out + 1] = e end
  end
  table.sort(out, function(a, b) return a.lastSeen > b.lastSeen end)
  while #out > limit do out[#out] = nil end
  return out
end

-- Sorted distinct numeric layer ids on the board (plus `extra`, e.g. your own layer).
-- Labels are positional ("L1", "L2", ...) so users with the same board agree on them.
function Board:LayerIds(extra)
  local set, ids = {}, {}
  for _, e in pairs(self.entries) do
    local l = Board.LayerOf(e)
    if tonumber(l) then set[l] = true end
  end
  if extra and tonumber(extra) then set[extra] = true end
  for l in pairs(set) do ids[#ids + 1] = l end
  table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
  return ids
end

function Board.Label(layer, ids)
  if layer == "?" then return "any" end
  if not layer or layer == "" then return "-" end
  for i, l in ipairs(ids) do if l == layer then return "L" .. i end end
  return "L?"
end

-- { [layer] = { groups = n, solo = n } } for the radar strip.
function Board:Summary(now)
  local counts = {}
  for _, e in pairs(self.entries) do
    if now - e.lastSeen <= Board.TTL then
      local l = Board.LayerOf(e)
      local c = counts[l] or { groups = 0, solo = 0 }
      if e.type == "S" then c.solo = c.solo + 1 else c.groups = c.groups + 1 end
      counts[l] = c
    end
  end
  return counts
end
