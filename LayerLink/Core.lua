-- Wiring: LFG-tool harvesting, own-listing publishing, network relay, catch-up sync,
-- watchlist alerts and slash commands.
local ADDON, ns = ...
ns.VERSION = "0.2.0"

local DEFAULTS = { watch = {}, alerts = true, share = true, scanOnOpen = true }
local RELAY_GATE = 45       -- re-announce the same listing at most this often
local OWN_EVERY = 60        -- re-publish our own listing this often while it's up
local SCAN_COOLDOWN = 15    -- the server throttles searches anyway
local SYNC_MAX_AGE = 300    -- only hand out listings confirmed this recently
local SYNC_LIMIT = 40
local db

ns.board = ns.Board.New()
ns.Now = GetTime

function ns.Print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffLayerLink|r: " .. table.concat(parts, " "))
end

local function shortName(name) return name and Ambiguate(name, "none") end

---------------------------------------------------------------------------
-- LFG tool helpers
---------------------------------------------------------------------------
local activityKey = {} -- activityID -> dungeon key | false

local function keyForActivity(id)
  if activityKey[id] == nil then
    local info = C_LFGList.GetActivityInfoTable and C_LFGList.GetActivityInfoTable(id)
    activityKey[id] = info and ns.MatchDungeon(info.fullName) or false
  end
  return activityKey[id] or nil
end

local function keysFor(activityIDs)
  local keys, seen = {}, {}
  for _, id in ipairs(activityIDs or {}) do
    local k = keyForActivity(id)
    if k and not seen[k] and #keys < 4 then seen[k] = true; keys[#keys + 1] = k end
  end
  return keys
end

local ROLE_COUNT = { TANK = "t", HEALER = "h", DAMAGER = "d" }

local function rolesString(r)
  if not r then return "" end
  return (r.tank and "T" or "") .. (r.healer and "H" or "") .. (r.dps and "D" or "")
end

---------------------------------------------------------------------------
-- Watchlist: "/ll watch brd heal" = groups that need a healer,
--            "/ll recruit brd heal" = solo healers looking for BRD.
---------------------------------------------------------------------------
local alerted = {}

local function watchMatches(e)
  if e.leader == ns.me then return false end
  for _, w in ipairs(db.watch) do
    local wantType = w.recruit and "S" or "G"
    if e.type == wantType then
      local dungeonOk = not w.dungeon
      for _, k in ipairs(e.dungeons or {}) do if k == w.dungeon then dungeonOk = true end end
      if dungeonOk and (not w.role or ns.Board.Wants(e, w.role)) then return true end
    end
  end
end

local function maybeAlert(e)
  if not db.alerts or alerted[e.id] or not watchMatches(e) then return end
  alerted[e.id] = true
  local label = ns.Board.Label(ns.Board.LayerOf(e), ns.board:LayerIds(ns.Layer:Get()))
  local what = table.concat(ns.Board.DungeonNames(e), "/")
  local msg = e.type == "S" and ("%s (%s) is looking for %s [%s]"):format(e.leader, e.roles ~= "" and e.roles or "?", what, label)
                             or ("%s's %s group has room [%s]"):format(e.leader, what, label)
  PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
  if RaidNotice_AddMessage and RaidWarningFrame then
    RaidNotice_AddMessage(RaidWarningFrame, "LayerLink: " .. msg, ChatTypeInfo["RAID_WARNING"])
  end
  ns.Print(msg .. " - /ll to open the board")
end

---------------------------------------------------------------------------
-- Observations: listings this client saw with its own eyes
---------------------------------------------------------------------------
function ns.Observe(o, force)
  local now = ns.Now()
  o.scout, o.layer = ns.me, ns.Layer:Get()
  local e = ns.board:Upsert(o, now)
  maybeAlert(e)
  if db.share and (force or not e.lastSent or now - e.lastSent > RELAY_GATE) then
    e.lastSent = now
    ns.Comm:Queue({ entry = e, force = force }, now, force and 0 or math.random() * 3)
  end
  return e
end

local function sendRaw(msg) ns.Comm:Queue({ raw = msg }, ns.Now()) end

local function readResult(id)
  local info = C_LFGList.GetSearchResultInfo(id)
  if not info or info.hasSelf then return nil, info end
  local keys = keysFor(info.activityIDs)
  if #keys == 0 then return nil, info end
  local size = info.numMembers or 1
  local o = { dungeons = keys, type = size == 1 and "S" or "G", size = size, t = 0, h = 0, d = 0,
              roles = "", leader = info.leaderName and shortName(info.leaderName), source = "T", listedAge = info.age }
  for i = 1, math.min(size, 40) do
    local m = C_LFGList.GetSearchResultPlayerInfo and C_LFGList.GetSearchResultPlayerInfo(id, i)
    if m then
      if size == 1 then
        o.roles = rolesString(m.lfgRoles)
        o.leader = o.leader or (m.name and shortName(m.name))
      end
      if m.isLeader or size == 1 then o.level, o.class = m.level, m.classFilename end
      local c = ROLE_COUNT[m.assignedRole or ""]
      if c then o[c] = o[c] + 1 end
    end
  end
  if not o.leader then return nil, info end
  return o, info
end

-- Every search (ours, or the player using Blizzard's own browse panel) lands here.
local lastSearch -- { layer, covered = {key=true}, at }

local function harvest()
  local ok, total, results = pcall(C_LFGList.GetSearchResults)
  if not ok or type(results) ~= "table" then return end
  local seen = {}
  for _, id in ipairs(results) do
    local o, info = readResult(id)
    if o and not info.isDelisted then
      seen[ns.Board.MakeId(o.leader)] = true
      ns.Observe(o)
    end
  end
  -- A complete result set is a snapshot of this layer: whatever we knew from this
  -- layer for the searched dungeons but didn't see has been delisted.
  local s = lastSearch
  lastSearch = nil
  if s and s.layer ~= "" and s.layer == ns.Layer:Get() and total == #results then
    for _, leader in ipairs(ns.board:ApplySnapshot(s.layer, s.covered, seen, ns.Now())) do
      if db.share then sendRaw(ns.Comm.EncodeGone(leader, s.layer)) end
    end
  end
  ns.UI:Refresh()
end

-- A single result changed (e.g. the group filled or delisted) after the search.
local function resultUpdated(id)
  local o, info = readResult(id)
  if not o then return end
  if info.isDelisted then
    local layer = ns.Layer:Get()
    if layer ~= "" and ns.board:RemoveGone(o.leader, layer, ns.Now()) and db.share then
      sendRaw(ns.Comm.EncodeGone(o.leader, layer))
    end
  else
    ns.Observe(o)
  end
end

local function onSearch(categoryID, _, _, _, _, _, activityIDs)
  local acts = activityIDs
  if not acts or #acts == 0 then
    acts = C_LFGList.GetAvailableActivities and C_LFGList.GetAvailableActivities(categoryID) or {}
  end
  local covered = {}
  for _, k in ipairs(keysFor(acts)) do covered[k] = true end
  -- keysFor caps at 4 for the wire; coverage needs all of them
  for _, id in ipairs(acts) do local k = keyForActivity(id); if k then covered[k] = true end end
  lastSearch = { layer = ns.Layer:Get(), covered = covered, at = ns.Now() }
end

-- Must run from a click or key press: C_LFGList.Search is hardware-event restricted.
function ns.Scan()
  if not (C_LFGList and C_LFGList.Search and C_LFGList.GetAvailableCategories) then return end
  local now = ns.Now()
  if ns.lastScan and now - ns.lastScan < SCAN_COOLDOWN then return end
  local cats = C_LFGList.GetAvailableCategories() or {}
  local cat = db.scanCategory
  if not tContains(cats, cat) then cat = cats[1] end
  if not cat then return end
  ns.lastScan = now
  C_LFGList.Search(cat, 0, 0, nil, false, nil, C_LFGList.GetAvailableActivities(cat))
end

function ns.ScanCategoryName()
  local cats = C_LFGList and C_LFGList.GetAvailableCategories and C_LFGList.GetAvailableCategories() or {}
  local cat = tContains(cats, db.scanCategory) and db.scanCategory or cats[1]
  local info = cat and C_LFGList.GetLfgCategoryInfo(cat)
  return info and info.name or "LFG"
end

function ns.CycleScanCategory()
  local cats = C_LFGList.GetAvailableCategories() or {}
  if #cats == 0 then return end
  local i = 0
  for j, c in ipairs(cats) do if c == db.scanCategory then i = j end end
  db.scanCategory = cats[i % #cats + 1]
end

---------------------------------------------------------------------------
-- Our own listing: publish it realm-wide automatically, delist instantly
---------------------------------------------------------------------------
local ownListed, ownSince, ownAt = false, nil, 0

local function publishOwn()
  if not ns.me or not db then return end
  local now = ns.Now()
  local listed = C_LFGList and C_LFGList.HasActiveEntryInfo and C_LFGList.HasActiveEntryInfo()
  local leader = not IsInGroup() or UnitIsGroupLeader("player")
  if not (listed and leader) then
    if ownListed then
      ownListed, ownSince = false, nil
      ns.board:Remove(ns.Board.MakeId(ns.me))
      if db.share then sendRaw(ns.Comm.EncodeDelist(ns.me)) end
    end
    return
  end
  local entry = C_LFGList.GetActiveEntryInfo()
  local keys = keysFor(entry and entry.activityIDs)
  if #keys == 0 then return end
  ownListed, ownSince, ownAt = true, ownSince or now, now
  local size = math.max(1, GetNumGroupMembers())
  local o = { leader = ns.me, dungeons = keys, type = size == 1 and "S" or "G", size = size,
              t = 0, h = 0, d = 0, roles = "", level = UnitLevel("player"),
              class = select(2, UnitClass("player")), source = "A", listedAge = now - ownSince }
  if size == 1 then
    o.roles = rolesString(C_LFGList.GetRoles and C_LFGList.GetRoles())
  elseif UnitGroupRolesAssigned then
    local units = { "player" }
    if IsInRaid() then units = {} for i = 1, size do units[i] = "raid" .. i end
    else for i = 1, size - 1 do units[#units + 1] = "party" .. i end end
    for _, unit in ipairs(units) do
      local c = ROLE_COUNT[UnitGroupRolesAssigned(unit) or ""]
      if c then o[c] = o[c] + 1 end
    end
  end
  ns.Observe(o, true)
end

---------------------------------------------------------------------------
-- Network input
---------------------------------------------------------------------------
local syncAnsweredAt, syncPending = 0, false

local function answerSync(requestedAt)
  if syncAnsweredAt >= requestedAt or not db.share then return end -- someone beat us to it
  local now = ns.Now()
  sendRaw(ns.Comm.EncodeSyncReply())
  for _, e in ipairs(ns.board:Freshest(now, SYNC_MAX_AGE, SYNC_LIMIT)) do
    ns.Comm:Queue({ entry = e, force = true }, now)
  end
end

local function onAddonMessage(prefix, msg, channel, sender)
  if prefix ~= ns.Comm.PREFIX or channel ~= "CHANNEL" then return end
  sender = shortName(sender)
  if sender == ns.me then return end
  local now = ns.Now()
  if not ns.Comm:Allow(sender, now) then return end
  local o = ns.Comm.Decode(msg)
  if not o then return end

  if o.kind == "X" then
    if o.leader == sender then ns.board:Remove(ns.Board.MakeId(o.leader)) end
  elseif o.kind == "G" then
    ns.board:RemoveGone(o.leader, o.layer, now)
  elseif o.kind == "S" then
    if not syncPending then
      syncPending = true
      local requestedAt = now
      C_Timer.After(1 + math.random() * 4, function() syncPending = false; answerSync(requestedAt) end)
    end
  elseif o.kind == "R" then
    syncAnsweredAt = now
  else
    o.scout, o.source = sender, "N"
    if o.leader == sender then o.source = "A" end -- the leader speaking for their own listing
    local e = ns.board:Upsert(o, now)
    e.netLayers[o.layer ~= "" and o.layer or "-"] = now
    maybeAlert(e)
  end
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------
function ns.WhisperLeader(e)
  if not e or e.leader == ns.me then return end
  local what = table.concat(ns.Board.DungeonNames(e), "/")
  local msg
  if e.type == "S" then
    msg = ("Hi! Saw you're looking for %s in the LFG tool - want to join our group? (LayerLink)"):format(what)
  else
    msg = ("Hi! Level %d %s here, saw your %s group in the LFG tool - got room? (LayerLink)"):format(
      UnitLevel("player"), UnitClass("player"), what)
  end
  -- opens the chat box pre-filled; the player presses Enter themselves
  ChatFrame_OpenChat("/w " .. e.leader .. " " .. msg)
end

function ns.OnLayerChanged()
  if ownListed then publishOwn() end -- re-tag our listing with the new layer
end

local ROLE_ARG = { tank = "T", t = "T", heal = "H", healer = "H", h = "H", dps = "D", d = "D" }

local HELP = {
  "/ll - toggle the board (also scans your layer)",
  "/ll scan - search the LFG tool on your layer and share it",
  "/ll watch <dungeon> [tank|heal|dps] - alert when a group with room appears",
  "/ll recruit <dungeon> [tank|heal|dps] - alert when a matching solo player lists",
  "/ll watch list | clear",
  "/ll layer - show your detected layer",
  "/ll share on|off - relay what you see (default on)",
  "/ll alerts on|off - watchlist alerts (default on)",
  "/ll autoscan on|off - scan when opening the board (default on)",
}

local function slash(input)
  local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  if cmd == "" then
    ns.UI:Toggle()
    if db.scanOnOpen and ns.UI:IsShown() then ns.Scan() end
  elseif cmd == "scan" then
    ns.Scan()
  elseif cmd == "watch" or cmd == "recruit" then
    if rest == "" or rest == "list" then
      if #db.watch == 0 then return ns.Print("watchlist empty.") end
      for _, w in ipairs(db.watch) do
        ns.Print(w.recruit and "recruiting" or "watching", w.dungeon or "any", w.role or "any role")
      end
    elseif rest == "clear" then
      wipe(db.watch); wipe(alerted); ns.Print("watchlist cleared.")
    else
      local a, b = rest:match("^(.-)%s*(%a*)$")
      local role = ROLE_ARG[(b or ""):lower()]
      local key = ns.MatchDungeon(role and a or rest)
      if not key then return ns.Print("unknown dungeon: " .. rest) end
      db.watch[#db.watch + 1] = { dungeon = key, role = role, recruit = cmd == "recruit" or nil }
      ns.Print((cmd == "recruit" and "recruiting for " or "watching ") .. ns.DungeonByKey[key].name
        .. (role and (" - " .. b) or ""))
    end
  elseif cmd == "layer" then
    local l = ns.Layer:Get()
    ns.Print(l == "" and "layer unknown - target or mouse over any NPC."
      or ("you are on %s (zone id %s)"):format(ns.Board.Label(l, ns.board:LayerIds(l)), l))
  elseif cmd == "share" or cmd == "alerts" or cmd == "autoscan" then
    local key = cmd == "autoscan" and "scanOnOpen" or cmd
    db[key] = rest:lower() ~= "off"
    ns.Print(cmd .. " " .. (db[key] and "on" or "off"))
  else
    for _, line in ipairs(HELP) do ns.Print(line) end
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local f = CreateFrame("Frame")
local handlers = {}

function handlers.ADDON_LOADED(name)
  if name ~= ADDON then return end
  LayerLinkDB = LayerLinkDB or {}
  db = LayerLinkDB
  for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end
  ns.db = db
  ns.Comm:Init()
  SLASH_LAYERLINK1, SLASH_LAYERLINK2 = "/ll", "/layerlink"
  SlashCmdList.LAYERLINK = slash
  if C_LFGList and C_LFGList.Search then hooksecurefunc(C_LFGList, "Search", onSearch) end
end

function handlers.PLAYER_LOGIN()
  ns.me = UnitName("player")
  C_Timer.NewTicker(0.25, function() ns.Comm:Pump(ns.Now(), ns.Layer:Get()) end)
  C_Timer.NewTicker(1, function()
    local now = ns.Now()
    ns.board:Prune(now)
    if ownListed and now - ownAt > OWN_EVERY then publishOwn() end
    ns.UI:Refresh()
  end)
end

local joined = false
function handlers.PLAYER_ENTERING_WORLD()
  ns.Layer:Invalidate()
  C_Timer.After(5, function()
    ns.Comm:JoinChannel()
    if not joined then -- first login: ask the network for what we missed
      joined = true
      C_Timer.After(3, function() sendRaw(ns.Comm.EncodeSync()) end)
    end
  end)
end

function handlers.GROUP_ROSTER_UPDATE() ns.Layer:Invalidate(); publishOwn() end
function handlers.LFG_LIST_ACTIVE_ENTRY_UPDATE() publishOwn() end
function handlers.LFG_LIST_SEARCH_RESULTS_RECEIVED() harvest() end
function handlers.LFG_LIST_SEARCH_RESULT_UPDATED(id) resultUpdated(id) end
function handlers.PLAYER_TARGET_CHANGED() ns.Layer:Sample("target") end
function handlers.UPDATE_MOUSEOVER_UNIT() ns.Layer:Sample("mouseover") end
function handlers.NAME_PLATE_UNIT_ADDED(unit) ns.Layer:Sample(unit) end
function handlers.CHAT_MSG_ADDON(...) onAddonMessage(...) end

f:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)
for event in pairs(handlers) do pcall(f.RegisterEvent, f, event) end -- pcall: some events don't exist on every client
