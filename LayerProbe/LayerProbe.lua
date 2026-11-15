-- LayerProbe (WoW: Forever): measures everything needed to build one bigger LFG list for a
-- dungeon by combining what LFG-tool users on different layers (and realms) can each see.
--
--  TOOL       Q0 api        which C_LFGList functions exist, Blizzard LFG addons/frames loaded
--             Q1 layers     do players on different layers see different listings?   (peer scan overlap)
--             Q2 realms     does the tool show other backend realms?                  (leader realm suffixes)
--             Q3 zones      does the tool only show your zone?                         (leaders' areaName)
--             Q4 fields     what can be read: names, roles, levels, classes, comments, member counts
--             Q5 search     click / slash / timer permission, minimum gap between searches
--             Q6 lifecycle  how long listings live, churn between scans
--             Q7 dungeon    per-dungeon supply (groups vs solo) and how much the list GROWS when merged
--             Q8 own entry  can an addon read your own listing (to auto-publish it)?
--  NETWORK    Q9 routes     custom channel / guild / party / whisper: delivered? across layers?
--             Q10 discovery can we join a channel, and read its member list to find other users?
--             Q11 rate      sustained messages per second per route, result codes
--  LAYERS     Q12 layers    zone id per map, and how long after joining a group your layer changes
--             Q13 lockdown  when values come back secret (instances, chat-messaging lockdown)
--
-- Data: WTF/Account/<acct>/SavedVariables/LayerProbe.lua. /probe for commands, /probe report for answers.
local ADDON = ...
local PREFIX, CHANNEL = "LProbe", "LayerProbeNet"
local RPREFIX = "LP" -- results whispered by friends WITHOUT the addon (see /probe macros); short to fit a 255-char /run
local db
local myName, myRealm, layer, layerMap = nil, nil, nil, nil
local pending -- the search in flight: { how, at, gap }
local showSnapshot -- defined with the snapshot window below
local onRemote -- defined with the macros below
local lastSearchAt

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function isSecret(...)
  if not issecretvalue then return false end
  for i = 1, select("#", ...) do if issecretvalue((select(i, ...))) then return true end end
  return false
end

local function now() return GetServerTime() end

local function out(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  DEFAULT_CHAT_FRAME:AddMessage("|cffff9933LayerProbe|r: " .. table.concat(parts, " "))
end

local function lockdown()
  local chat = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
  return { instance = IsInInstance() and true or false, chatLockdown = (not isSecret(chat)) and chat or "secret",
           combat = InCombatLockdown() and true or false }
end

local function log(kind, data)
  data = data or {}
  data.kind, data.t, data.layer, data.map = kind, now(), layer, layerMap
  table.insert(db.log, data)
  if #db.log > 3000 then table.remove(db.log, 1) end
end

local function copy(v, depth)
  if isSecret(v) then return "<secret>" end
  if type(v) ~= "table" then return v end
  if (depth or 0) > 2 then return "<table>" end
  local c = {}
  for k, x in pairs(v) do if not isSecret(k) then c[k] = copy(x, (depth or 0) + 1) end end
  return c
end

local function describeString(s)
  if isSecret(s) then return "secret" end
  if s == nil then return "nil" end
  if type(s) ~= "string" then return type(s) end
  if s == "" then return "empty" end
  if s:find("|K", 1, true) then return "kstring-token(" .. #s .. ")" end
  return "readable(" .. #s .. "): " .. s:sub(1, 60)
end

local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
local function median(list)
  if #list == 0 then return nil end
  table.sort(list)
  return list[math.ceil(#list / 2)]
end

-- Forever names are "First Surname"; UnitName alone gives only the first name.
local function getMyName()
  local first, second = UnitFullName("player")
  if not isSecret(first, second) and first and C_PlayerInfo and C_PlayerInfo.ShouldDisplaySurname
     and C_PlayerInfo.ShouldDisplaySurname() and second and second ~= "" then
    return first .. " " .. second
  end
  local n = UnitName("player")
  return (not isSecret(n) and n) or "?"
end

-- For whispering: "First Surname-Realm" -> "First Surname".
local function normName(name)
  if isSecret(name) or type(name) ~= "string" or name == "" then return nil end
  return name:match("^(%S+ %S+)%-%S+$") or Ambiguate(name, "none")
end

-- For identity across clients: always "Name-Realm" (the tool omits the realm for your own realm).
local function fullKey(name)
  if isSecret(name) or type(name) ~= "string" or name == "" then return nil end
  if name:find("-", 1, true) then return name end
  return name .. "-" .. (myRealm or "?")
end

local function realmOf(key) return key and key:match("%-([^%-]+)$") end

local RESULT_NAMES = {}
if Enum and Enum.SendAddonMessageResult then
  for k, v in pairs(Enum.SendAddonMessageResult) do RESULT_NAMES[v] = k end
end
local function resultName(r) return RESULT_NAMES[r] or tostring(r) end

---------------------------------------------------------------------------
-- Q0: API inventory
---------------------------------------------------------------------------
local WANTED = { "Search", "GetSearchResults", "GetFilteredSearchResults", "HasSearchResultInfo", "GetSearchResultInfo",
  "GetSearchResultPlayerInfo", "GetSearchResultLeaderInfo", "GetSearchResultMemberCounts", "GetActivityInfoTable",
  "GetActivityGroupInfo", "GetAvailableCategories", "GetAvailableActivities", "GetLfgCategoryInfo",
  "HasActiveEntryInfo", "GetActiveEntryInfo", "CreateListing", "UpdateListing", "RemoveListing",
  "IsPlayerAuthenticatedForLFG", "GetRoles" }

local function inventory()
  local inv = { lfglist = {}, missing = {}, addons = {}, frames = {} }
  if C_LFGList then
    for k, v in pairs(C_LFGList) do if type(v) == "function" then inv.lfglist[#inv.lfglist + 1] = k end end
    table.sort(inv.lfglist)
  end
  for _, f in ipairs(WANTED) do
    if not (C_LFGList and C_LFGList[f]) then inv.missing[#inv.missing + 1] = f end
  end
  local getNum = C_AddOns and C_AddOns.GetNumAddOns or GetNumAddOns
  local getInfo = C_AddOns and C_AddOns.GetAddOnInfo or GetAddOnInfo
  local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
  if getNum and getInfo then
    for i = 1, getNum() do
      local name = getInfo(i)
      if type(name) == "string" and (name:find("LFG") or name:find("GroupFinder")) then
        inv.addons[name] = loaded and loaded(name) and "loaded" or "not loaded"
      end
    end
  end
  for _, fr in ipairs({ "LFGParentFrame", "LFGBrowseFrame", "LFGListingFrame", "PVEFrame", "LFGListFrame",
                        "GroupFinderFrame", "LFDParentFrame" }) do
    inv.frames[fr] = _G[fr] ~= nil
  end
  inv.authenticated = C_LFGList and C_LFGList.IsPlayerAuthenticatedForLFG and copy(C_LFGList.IsPlayerAuthenticatedForLFG())
  db.inventory = inv
  return inv
end

-- Every category/activity the tool offers, with names (also tells LayerLink how to map dungeons).
local function catalog()
  local list = {}
  if not (C_LFGList and C_LFGList.GetAvailableCategories) then return list end
  for _, cat in ipairs(C_LFGList.GetAvailableCategories() or {}) do
    local catInfo = C_LFGList.GetLfgCategoryInfo and C_LFGList.GetLfgCategoryInfo(cat)
    for _, a in ipairs(C_LFGList.GetAvailableActivities(cat) or {}) do
      local ok, info = pcall(C_LFGList.GetActivityInfoTable, a)
      list[#list + 1] = { id = a, cat = cat, catName = catInfo and copy(catInfo.name),
        name = ok and info and copy(info.fullName) or "?", maxPlayers = ok and info and copy(info.maxNumPlayers),
        minLevel = ok and info and copy(info.minLevelSuggestion or info.minLevel),
        maxLevel = ok and info and copy(info.maxLevelSuggestion) }
    end
  end
  db.catalog = list
  return list
end

local function activityName(id)
  for _, a in ipairs(db.catalog or {}) do if a.id == id then return a.name end end
  local ok, info = pcall(C_LFGList.GetActivityInfoTable, id)
  return ok and info and not isSecret(info.fullName) and info.fullName or tostring(id)
end

---------------------------------------------------------------------------
-- Q12: layers (per zone on Forever) and layer change after joining a group
---------------------------------------------------------------------------
local wasInGroup = false

local function onLayerChanged(old, new, map)
  local j = db.joins[#db.joins]
  if j and not j.changedAt and j.map == map and j.layerBefore and j.layerBefore ~= new then
    j.changedAt, j.delay, j.layerAfter = now(), now() - j.t, new
    out(("layer changed %ds after joining the group"):format(j.delay))
  end
end

local function sample(unit)
  if IsInInstance() then return end
  local guid = UnitGUID(unit)
  if not guid or isSecret(guid) then return end
  local unitType, _, serverID, instanceID, zoneUID, npcID = strsplit("-", guid)
  if unitType ~= "Creature" and unitType ~= "Vehicle" then return end
  local id = tonumber(zoneUID)
  if not id or id == 0 then return end
  local map = C_Map.GetBestMapForUnit("player")
  local s = db.layerStats
  s.samples = s.samples + 1
  if id ~= layer then
    log("layer", { from = layer, to = id, serverID = serverID, instanceID = instanceID, npcID = npcID, newMap = map })
    if layer then out("layer changed", layer, "->", id, "(map " .. tostring(map) .. ")") end
    local old = layer
    layer, layerMap = id, map
    local key = tostring(map)
    s.byMap[key] = s.byMap[key] or {}
    s.byMap[key][tostring(id)] = (s.byMap[key][tostring(id)] or 0) + 1
    onLayerChanged(old, id, map)
  end
end

local function onGroupChanged()
  local inGroup = IsInGroup() and true or false
  if inGroup and not wasInGroup then
    db.joins[#db.joins + 1] = { t = now(), layerBefore = layer, map = layerMap, size = GetNumGroupMembers() }
    if #db.joins > 100 then table.remove(db.joins, 1) end
    out("joined a group on layer " .. tostring(layer) .. " - keep targeting NPCs to time the layer change")
  elseif not inGroup and wasInGroup then
    local j = db.joins[#db.joins]
    if j and not j.leftAt then j.leftAt = now() end
  end
  wasInGroup = inGroup
  log("group", { size = GetNumGroupMembers() })
end

---------------------------------------------------------------------------
-- Q9 + Q11: message routes. Each message goes on every route; receivers record the route.
---------------------------------------------------------------------------
local function sendOne(msg, dist, target, tag)
  local ok, r = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, dist, target)
  local key = dist .. ":" .. (ok and resultName(r) or ("error " .. tostring(r)))
  db.sendResults[key] = (db.sendResults[key] or 0) + 1
  if tag then db.rateSent[tag] = db.rateSent[tag] or {}; db.rateSent[tag][key] = (db.rateSent[tag][key] or 0) + 1 end
end

local function sendAll(msg, tag, whisperOnly)
  if not whisperOnly then
    local idx = GetChannelName(CHANNEL)
    if idx and idx > 0 then sendOne(msg, "CHANNEL", idx, tag) end
    if IsInGuild() then sendOne(msg, "GUILD", nil, tag) end
    if IsInGroup() then sendOne(msg, IsInRaid() and "RAID" or "PARTY", nil, tag) end
  end
  for name in pairs(db.peerTargets) do sendOne(msg, "WHISPER", name, tag) end
end

-- Scan sharing goes only to peers by whisper, paced under the addon-message throttle
-- (the first solo run saw ~70% of unpaced sends come back AddonMessageThrottle).
local outQueue, lastOut = {}, 0
local function pumpQueue()
  if #outQueue == 0 or GetTime() - lastOut < 1.2 then return end
  local m = table.remove(outQueue, 1)
  lastOut = GetTime()
  sendOne(m.msg, "WHISPER", m.target)
end

local function sendChunks(head, items)
  if not next(db.peerTargets) then return end -- nobody to compare with
  local buf = {}
  local function flush()
    if #buf > 0 then
      for name in pairs(db.peerTargets) do
        if #outQueue < 60 then outQueue[#outQueue + 1] = { msg = head .. "^" .. table.concat(buf, ","), target = name } end
      end
      buf = {}
    end
  end
  for _, s in ipairs(items) do
    if #head + #table.concat(buf, ",") + #s + 2 > 240 then flush() end
    buf[#buf + 1] = s
  end
  flush()
end

local seq = 0
local function ping(tag, whisperOnly)
  seq = seq + 1
  sendAll(("P^%s^%s^%d^%d^%s^%s"):format(layer or "", layerMap or "", seq, now(), tag or "", myRealm or ""),
    tag ~= "auto" and tag ~= "login" and tag ~= "manual" and tag or nil, whisperOnly)
end

local function burst(n)
  out("sending " .. n .. " messages on every route as fast as possible...")
  for i = 1, n do ping("burst") end
end

local rateTicker
local function rateTest(perSec, seconds)
  if rateTicker then rateTicker:Cancel() end
  local total, sent = math.floor(perSec * seconds), 0
  local tag = ("rate%gx%d"):format(perSec, seconds)
  out(("whispering %d msgs/s for %ds to your peers (%s)..."):format(perSec, seconds, tag))
  rateTicker = C_Timer.NewTicker(1 / perSec, function()
    sent = sent + 1
    ping(tag, true)
    if sent >= total then rateTicker = nil; out(tag .. " done - ask your peer for /probe report") end
  end, total) -- the ticker stops itself after `total` runs
end

local function onAddonMessage(prefix, msg, dist, sender)
  if isSecret(prefix, msg, dist, sender) then
    db.secret.messages = (db.secret.messages or 0) + 1
    return
  end
  if prefix == RPREFIX and onRemote then return onRemote(msg, sender) end
  if prefix ~= PREFIX then return end
  local whisperName = normName(sender)
  if not whisperName or whisperName:lower() == (myName or ""):lower() then return end
  local f = { strsplit("^", msg) }
  local theirLayer = f[2] or ""
  local cross = theirLayer ~= "" and layer and tonumber(theirLayer) ~= layer

  local route = db.routes[dist] or { received = 0, crossLayer = 0, from = {} }
  route.received = route.received + 1
  if cross then route.crossLayer = route.crossLayer + 1 end
  route.from[whisperName] = theirLayer
  db.routes[dist] = route

  if not db.peerTargets[whisperName] and dist ~= "WHISPER" and count(db.peerTargets) < 10 then
    db.peerTargets[whisperName] = true -- answer by whisper too, so that route gets tested both ways
  end

  if f[1] == "P" then
    db.peers[whisperName] = { layer = theirLayer, map = f[3], realm = f[7], senderRaw = sender, lastSeen = now() }
    if cross and not db.crossLayer[dist] then
      db.crossLayer[dist] = { from = whisperName, theirLayer = theirLayer, ourLayer = layer, t = now() }
      out(("|cff33ff99%s reaches another layer|r: ping from %s (layer %s, you %s)"):format(dist, whisperName, theirLayer, tostring(layer)))
    end
    local tag = f[6] or ""
    if tag ~= "" and tag ~= "auto" and tag ~= "login" and tag ~= "manual" then
      local k = whisperName .. " " .. tag .. " via " .. dist
      local r = db.rateReceived[k] or { n = 0 }
      r.n = r.n + 1
      r.first = r.first or now()
      r.last = now()
      db.rateReceived[k] = r
    end
  elseif f[1] == "S" then
    -- S^layer^time^map^realm^n^complete^searchSig ^ items "partyID@activityID@G|S"
    local key = whisperName .. "@" .. (f[3] or "")
    local ps = db.peerScans[key] or { by = whisperName, layer = theirLayer, t = tonumber(f[3]), map = f[4],
                                      realm = f[5], n = tonumber(f[6]), complete = f[7] == "1", sig = f[8], items = {} }
    for item in (f[9] or ""):gmatch("[^,]+") do
      local who, act, kind = item:match("^(.-)@(%d+)@([GS])$")
      if who then ps.items[who] = { act = tonumber(act), kind = kind } end
    end
    db.peerScans[key] = ps -- the same chunk may arrive on several routes; keyed items dedup
  end
end

---------------------------------------------------------------------------
-- Q10: discovery - channel join outcome and member-list (roster) reading
---------------------------------------------------------------------------
local rosterWanted = {} -- displayIndex -> channel name we asked about

local function requestRoster(channelName)
  if not (GetNumDisplayChannels and GetChannelDisplayInfo and SetSelectedDisplayChannel) then
    db.discovery.rosterApi = "missing"
    return out("roster API missing on this client")
  end
  if InCombatLockdown() then return out("not during combat") end
  local mine, other
  for i = 1, GetNumDisplayChannels() or 0 do
    local ok, name, header = pcall(GetChannelDisplayInfo, i)
    if ok and not header and type(name) == "string" and not isSecret(name) then
      if name == channelName then mine = i elseif not other then other = i end
    end
  end
  if not mine then
    db.discovery.rosters[channelName] = { error = "not in a channel called " .. channelName, t = now() }
    return out("not in channel " .. channelName)
  end
  rosterWanted[mine] = channelName
  -- the server sends a list when a channel becomes selected; selecting another first forces a resend
  if other then pcall(SetSelectedDisplayChannel, other) end
  pcall(SetSelectedDisplayChannel, mine)
  C_Timer.After(10, function()
    if rosterWanted[mine] then
      db.discovery.rosters[channelName] = { error = "no roster update within 10s", t = now() }
      rosterWanted[mine] = nil
    end
  end)
end

local function onRoster(displayIndex, countArg)
  local channelName = rosterWanted[displayIndex]
  if not channelName then return end
  rosterWanted[displayIndex] = nil
  local r = { t = now(), reported = copy(countArg), readable = 0, secret = 0, sample = {} }
  local n = tonumber(not isSecret(countArg) and countArg) or 0
  for i = 1, math.min(n, 500) do
    local ok, name = pcall(C_ChatInfo.GetChannelRosterInfo, displayIndex, i)
    if ok and isSecret(name) then r.secret = r.secret + 1
    elseif ok and type(name) == "string" then
      r.readable = r.readable + 1
      if #r.sample < 5 then r.sample[#r.sample + 1] = name end
    end
  end
  db.discovery.rosters[channelName] = r
  out(("roster of %s: %s members reported, %d names readable, %d secret"):format(channelName, tostring(countArg), r.readable, r.secret))
end

local function joinChannel()
  if GetChannelName(CHANNEL) ~= 0 then
    db.discovery.join = db.discovery.join or { ok = true, already = true, indexAfter = GetChannelName(CHANNEL), t = now() }
    return
  end
  local ok, err = pcall(JoinTemporaryChannel, CHANNEL)
  db.discovery.join = { ok = ok, err = err and tostring(err), t = now() }
  C_Timer.After(3, function()
    local idx = GetChannelName(CHANNEL)
    db.discovery.join.indexAfter = idx
    log("channel-join", db.discovery.join)
  end)
end

---------------------------------------------------------------------------
-- Q1-Q8: search results
---------------------------------------------------------------------------
local function readResult(id, scan)
  local gotInfo, info = pcall(C_LFGList.GetSearchResultInfo, id)
  if not gotInfo or type(info) ~= "table" then return nil end
  local acts = (type(info.activityIDs) == "table" and info.activityIDs) or { info.activityID }
  local n = tonumber(not isSecret(info.numMembers) and info.numMembers) or 0
  local r = {
    leader = describeString(info.leaderName), key = fullKey(info.leaderName), numMembers = copy(info.numMembers),
    -- partyGUID is present even when the leader's name hasn't loaded yet (46% of first sightings)
    id = (not isSecret(info.partyGUID) and type(info.partyGUID) == "string" and info.partyGUID ~= "" and info.partyGUID)
      or fullKey(info.leaderName),
    age = copy(info.age), isDelisted = copy(info.isDelisted), activityIDs = copy(acts), hasSelf = copy(info.hasSelf),
    playstyle = copy(info.playstyle), generalPlaystyle = copy(info.generalPlaystyle), autoAccept = copy(info.autoAccept),
    name = describeString(info.name), comment = describeString(info.comment), members = {},
  }
  if C_LFGList.GetSearchResultMemberCounts then
    local ok, mc = pcall(C_LFGList.GetSearchResultMemberCounts, id)
    r.memberCounts = ok and copy(mc) or "error"
  end
  for m = 1, math.min(n, 40) do
    local gotP, p = pcall(C_LFGList.GetSearchResultPlayerInfo, id, m)
    if gotP and type(p) == "table" then
      local mem = { name = describeString(p.name), level = copy(p.level), class = copy(p.classFilename),
        role = copy(p.assignedRole), lfgRoles = copy(p.lfgRoles), isLeader = copy(p.isLeader), area = copy(p.areaName) }
      r.members[m] = mem
      if (p.isLeader or n == 1) and not isSecret(p.areaName) then r.leaderArea = p.areaName end
    else
      r.members[m] = gotP and "nil" or "error"
    end
  end
  -- count which fields came back secret (Q13)
  for _, field in ipairs({ "leaderName", "numMembers", "activityIDs", "name", "comment", "age" }) do
    if isSecret(info[field]) then scan.secretFields[field] = (scan.secretFields[field] or 0) + 1 end
  end
  return r, acts, n
end

local function onResults()
  while #db.searchLog > 300 do table.remove(db.searchLog, 1) end
  local ok, total, results = pcall(C_LFGList.GetSearchResults)
  local p = pending
  pending = nil
  if p then
    db.searchLog[#db.searchLog + 1] = { how = p.how, gap = p.gap, outcome = ok and "results" or "unreadable", t = now() }
  end
  if not ok or type(results) ~= "table" then
    log("results-unreadable", { err = tostring(total) })
    return out("search results arrived but couldn't be read: " .. tostring(total))
  end
  local zone = GetRealZoneText and GetRealZoneText() or "?"
  local scan = { t = now(), layer = layer, map = layerMap, zone = zone, realm = myRealm, total = copy(total), n = #results,
                 how = p and p.how or "blizzard-ui", searched = db.lastSearchActs, sig = db.lastSearchSig,
                 complete = (tonumber(not isSecret(total) and total) or 0) == #results and #results < 100,
                 lockdown = lockdown(),
                 results = {}, items = {}, secretFields = {}, realms = {}, sameZone = 0, otherZone = 0,
                 unknownZone = 0, groups = 0, solo = 0, byActivity = {} }
  for i, id in ipairs(results) do
    local r, acts, n = readResult(id, scan)
    if r then
      if i <= 100 then scan.results[#scan.results + 1] = r end
      local kind = n == 1 and "S" or "G"
      if kind == "S" then scan.solo = scan.solo + 1 else scan.groups = scan.groups + 1 end
      local act = tonumber(acts[1]) or 0
      local ba = scan.byActivity[act] or { groups = 0, solo = 0 }
      if kind == "S" then ba.solo = ba.solo + 1 else ba.groups = ba.groups + 1 end
      scan.byActivity[act] = ba
      if r.key then
        local realm = realmOf(r.key) or "?"
        scan.realms[realm] = (scan.realms[realm] or 0) + 1
      else
        scan.noName = (scan.noName or 0) + 1
      end
      if r.id then
        scan.items[r.id] = { act = act, kind = kind }
        local life = db.lifecycle[r.id] or { first = scan.t, scans = 0 }
        life.last, life.scans = scan.t, life.scans + 1
        db.lifecycle[r.id] = life
      end
      if not r.leaderArea then scan.unknownZone = scan.unknownZone + 1
      elseif r.leaderArea == zone then scan.sameZone = scan.sameZone + 1
      else scan.otherZone = scan.otherZone + 1 end
      if #db.rawSamples < 5 then
        local _, raw = pcall(C_LFGList.GetSearchResultInfo, id)
        db.rawSamples[#db.rawSamples + 1] = copy(raw)
      end
    end
  end
  -- churn vs the previous own scan of the same search, within 5 minutes (Q6)
  local prev = db.scans[#db.scans]
  if prev and prev.searched == scan.searched and scan.t - prev.t <= 300 and count(prev.items) > 0 then
    local gone = 0
    for k in pairs(prev.items) do if not scan.items[k] then gone = gone + 1 end end
    scan.churn = { gone = gone, of = count(prev.items), seconds = scan.t - prev.t }
  end
  table.insert(db.scans, scan)
  if scan.how == "snapshot" and showSnapshot then showSnapshot(scan) end
  if #db.scans > 150 then table.remove(db.scans, 1) end
  out(("scan: %d results (%d groups, %d solo) on layer %s in %s via %s%s"):format(#results, scan.groups, scan.solo,
    tostring(layer), zone, scan.how, scan.complete and "" or " |cffffff00(capped at 100: narrow it with /probe dungeon)|r"))
  -- only complete scans are comparable: a capped search returns a different 100 each time
  if scan.complete then
    local items = {}
    for k, v in pairs(scan.items) do items[#items + 1] = k .. "@" .. v.act .. "@" .. v.kind end
    sendChunks(("S^%s^%d^%s^%s^%d^1^%s"):format(layer or "", scan.t, layerMap or "", myRealm or "", #items, scan.sig or ""), items)
  end
end

---------------------------------------------------------------------------
-- Q5: searching (permission tests + spacing)
---------------------------------------------------------------------------
local function searchTarget()
  local t = db.target
  if t and t.cat then return t.cat, t.ids end
  local cats = C_LFGList.GetAvailableCategories and C_LFGList.GetAvailableCategories() or {}
  local cat = cats[1]
  return cat, cat and C_LFGList.GetAvailableActivities(cat) or nil
end

local function doSearch(how)
  if not (C_LFGList and C_LFGList.Search) then return out("C_LFGList.Search does not exist on this client") end
  local cat, acts = searchTarget()
  if not cat then return out("no LFG categories available - open the LFG tool once, then retry") end
  local t = GetTime()
  pending = { how = how, at = t, gap = lastSearchAt and (t - lastSearchAt) or nil }
  lastSearchAt = t
  -- create the counter first: a blocked call reports ADDON_ACTION_BLOCKED from inside Search itself
  db.searchTests[how] = db.searchTests[how] or { calls = 0, results = 0, blocked = 0, failed = 0, errors = 0 }
  local s = db.searchTests[how]
  s.calls = s.calls + 1
  local ok, err = pcall(C_LFGList.Search, cat, 0, 0, nil, false, nil, acts)
  log("search-call", { how = how, ok = ok, err = err and tostring(err), category = cat, nActivities = acts and #acts })
  if not ok then
    s.errors = s.errors + 1
    db.searchLog[#db.searchLog + 1] = { how = how, gap = pending.gap, outcome = "error", t = now() }
    pending = nil
    out("search error via " .. how .. ": " .. tostring(err))
  end
end

local function setDungeon(arg)
  local cat = catalog()
  if arg == "" then
    out("activities (" .. #cat .. "), pick one with /probe dungeon <name>:")
    local seen = {}
    for _, a in ipairs(cat) do
      if not seen[a.name] then seen[a.name] = true; out(("  [%s] %s"):format(tostring(a.id), tostring(a.name))) end
    end
    return
  end
  if arg == "all" then db.target = nil; return out("scans now cover the whole first category") end
  local q, hits = arg:lower(), { ids = {}, names = {} }
  for _, a in ipairs(cat) do
    if type(a.name) == "string" and a.name:lower():find(q, 1, true) and (not hits.cat or hits.cat == a.cat) then
      hits.cat = a.cat
      hits.ids[#hits.ids + 1] = a.id
      hits.names[#hits.names + 1] = a.name
    end
  end
  if not hits.cat then return out("no activity matches '" .. arg .. "' - /probe dungeon lists them") end
  hits.query = arg
  db.target = hits
  out("target: " .. table.concat(hits.names, ", ") .. " - scans and the report now focus on it")
end

---------------------------------------------------------------------------
-- Report
---------------------------------------------------------------------------
local function targetSet()
  local set = {}
  for _, id in ipairs(db.target and db.target.ids or {}) do set[id] = true end
  return next(set) and set or nil
end

-- Compare own scans with a peer's scans of the SAME search taken within 3 minutes. Only complete
-- scans count (a search capped at 100 returns a different random 100 each time). Each pair is
-- classed: "control" (same layer and realm: should be ~100% alike), "layer" (other layer or zone,
-- same realm: Q1) or "realm" (other realm: Q2).
local function compare()
  local res = {}
  for _, kind in ipairs({ "control", "layer", "realm" }) do
    res[kind] = { pairs = 0, shared = 0, union = 0, mine = 0, unknownLayer = 0 }
  end
  for _, mine in ipairs(db.scans) do
    for _, theirs in pairs(db.peerScans) do
      if mine.complete and theirs.complete and mine.sig and mine.sig == theirs.sig
         and math.abs((theirs.t or 0) - mine.t) <= 180 and (count(theirs.items) > 0 or count(mine.items) > 0) then
        local kind
        if theirs.realm ~= "" and theirs.realm ~= mine.realm then kind = "realm"
        elseif mine.layer and theirs.layer ~= "" and (tonumber(theirs.layer) ~= mine.layer or theirs.map ~= tostring(mine.map)) then kind = "layer"
        elseif mine.layer and theirs.layer ~= "" then kind = "control"
        end
        if kind then
          local r, u = res[kind], {}
          r.pairs = r.pairs + 1
          for k in pairs(mine.items) do u[k] = true end
          for k in pairs(theirs.items) do
            if mine.items[k] then r.shared = r.shared + 1 end
            u[k] = true
          end
          r.union, r.mine = r.union + count(u), r.mine + count(mine.items)
        else
          res.layer.unknownLayer = res.layer.unknownLayer + 1 -- one side's layer unknown: target an NPC
        end
      end
    end
  end
  return res
end

local function compareLine(label, r, verdictLow, verdictHigh)
  if r.pairs == 0 then return out(label .. ": no matching scan pairs yet") end
  local pct = r.union > 0 and math.floor(100 * r.shared / r.union) or 100
  out(("%s: %d scan pairs, %d%% of listings shared, merged list %.1fx your own -> %s"):format(label, r.pairs, pct,
    r.mine > 0 and r.union / r.mine or 1, pct >= 80 and verdictHigh or pct <= 30 and verdictLow or "mixed - scan more"))
end

local function report()
  out("==== LayerProbe report: " .. tostring(myName) .. "-" .. tostring(myRealm) .. ", build " .. tostring(db.client.build) .. " ====")
  local inv = inventory()
  out(("TOOL Q0 api: %d C_LFGList functions; missing: %s"):format(#inv.lfglist, #inv.missing > 0 and table.concat(inv.missing, ", ") or "none"))
  local addons = {}
  for name, state in pairs(inv.addons) do addons[#addons + 1] = name .. "=" .. state end
  out("     lfg addons: " .. (#addons > 0 and table.concat(addons, " ") or "none found"))

  local c = compare()
  compareLine("TOOL Q1 control (same layer)", c.control, "|cffff5555differs even on one layer: check timing|r", "|cff33ff99method works|r")
  compareLine("TOOL Q1 other layer/zone", c.layer, "|cff33ff99tool is layer-limited: merging helps|r", "|cffff5555tool shows every layer|r")
  if c.layer.unknownLayer > 0 then out(("     %d pairs skipped: a layer was unknown (target an NPC)"):format(c.layer.unknownLayer)) end
  compareLine("TOOL Q2 other realm", c.realm, "|cff33ff99tool is realm-limited: merging realms helps|r", "|cffff5555tool shows other realms too|r")

  local realms, keys, foreign = {}, 0, 0
  for _, s in ipairs(db.scans) do
    for r, n in pairs(s.realms) do realms[r] = (realms[r] or 0) + n; keys = keys + n; if r ~= myRealm then foreign = foreign + n end end
  end
  out(("TOOL Q2 realms: %d listings seen from %d realms, %d%% from other realms than yours"):format(keys, count(realms),
    keys > 0 and math.floor(100 * foreign / keys) or 0))

  local same, other, unknown = 0, 0, 0
  for _, s in ipairs(db.scans) do same, other, unknown = same + s.sameZone, other + s.otherZone, unknown + s.unknownZone end
  out(("TOOL Q3 zones: leaders in your zone %d, elsewhere %d, unknown %d -> %s"):format(same, other, unknown,
    other > 0 and "tool is NOT zone-limited" or (same > 0 and "all in your zone so far (zone-limited?)" or "no data")))

  local last = db.scans[#db.scans]
  if last and last.results[1] then
    local r, m = last.results[1], last.results[1].members[1]
    out(("TOOL Q4 fields: leader=%s name=%s comment=%s memberCounts=%s"):format(r.leader, r.name, r.comment,
      type(r.memberCounts) == "table" and "readable" or tostring(r.memberCounts)))
    if type(m) == "table" then
      out(("     member: level=%s class=%s role=%s area=%s"):format(tostring(m.level), tostring(m.class), tostring(m.role), tostring(m.area)))
    end
  else
    out("TOOL Q4 fields: no scans yet - open the LFG tool and refresh, or /probe scan")
  end
  local noName, seenN = 0, 0
  for _, s in ipairs(db.scans) do noName, seenN = noName + (s.noName or 0), seenN + s.n end
  if seenN > 0 then
    out(("     leader name not loaded yet: %d%% of results (listings still tracked by party id)"):format(math.floor(100 * noName / seenN)))
  end

  for how, t in pairs(db.searchTests) do
    out(("TOOL Q5 search via %s: %d calls, %d result sets, %d blocked, %d failed, %d errors"):format(how, t.calls,
      t.results, t.blocked, t.failed, t.errors))
  end
  local okGap, badGap
  for _, s in ipairs(db.searchLog) do
    if s.gap then
      if s.outcome == "results" then okGap = math.min(okGap or 1e9, s.gap) else badGap = math.max(badGap or 0, s.gap) end
    end
  end
  if okGap or badGap then
    out(("     shortest gap that still got results: %s s; longest gap that failed: %s s"):format(
      okGap and ("%.1f"):format(okGap) or "-", badGap and ("%.1f"):format(badGap) or "-"))
  end

  local lifetimes, churnGone, churnOf = {}, 0, 0
  for _, l in pairs(db.lifecycle) do if l.scans >= 2 then lifetimes[#lifetimes + 1] = l.last - l.first end end
  for _, s in ipairs(db.scans) do if s.churn then churnGone, churnOf = churnGone + s.churn.gone, churnOf + s.churn.of end end
  out(("TOOL Q6 lifecycle: %d listings seen 2+ times, median seen-for %s s; churn between scans %d%%"):format(
    #lifetimes, tostring(median(lifetimes) or "-"), churnOf > 0 and math.floor(100 * churnGone / churnOf) or 0))

  if db.target then
    local tset, g, s, scans = targetSet(), 0, 0, 0
    for _, sc in ipairs(db.scans) do
      local hit = false
      for act, ba in pairs(sc.byActivity) do if tset[act] then g, s, hit = g + ba.groups, s + ba.solo, true end end
      if hit then scans = scans + 1 end
    end
    out(("TOOL Q7 %s: %d scans with it, avg %.1f groups + %.1f solo per scan"):format(db.target.query, scans,
      scans > 0 and g / scans or 0, scans > 0 and s / scans or 0))
    local m = { pairs = 0, mine = 0, union = 0 }
    for _, kind in ipairs({ "layer", "realm" }) do
      m.pairs, m.mine, m.union = m.pairs + c[kind].pairs, m.mine + c[kind].mine, m.union + c[kind].union
    end
    if m.pairs > 0 then
      out(("     merged with your peer: %.1f -> %.1f listings per scan (%.1fx)"):format(m.mine / m.pairs,
        m.union / m.pairs, m.mine > 0 and m.union / m.mine or 1))
    end
  else
    out("TOOL Q7 dungeon: no target - /probe dungeon <name> to focus on one")
  end

  local own = db.ownEntry
  out("TOOL Q8 own listing: " .. (own and (("seen %d times, readable=%s, activities=%s"):format(own.updates, tostring(own.readable),
    tostring(own.activities))) or "list yourself in the tool once to test"))

  for _, dist in ipairs({ "CHANNEL", "GUILD", "PARTY", "RAID", "WHISPER" }) do
    local r = db.routes[dist]
    if r then
      out(("NET Q9 %s: %d msgs from %d players, %d from another layer %s"):format(dist, r.received, count(r.from),
        r.crossLayer, db.crossLayer[dist] and "|cff33ff99(crosses layers)|r" or ""))
    end
  end
  if not next(db.routes) then out("NET Q9 routes: nothing received yet - /probe peer First Surname") end
  local sends = {}
  for k, n in pairs(db.sendResults) do sends[#sends + 1] = k .. " x" .. n end
  table.sort(sends)
  out("     send results: " .. (#sends > 0 and table.concat(sends, ", ") or "none"))

  local d = db.discovery
  out(("NET Q10 discovery: channel join %s (index after: %s)"):format(d.join and (d.join.already and "already in it"
    or d.join.ok and "ok" or ("error " .. tostring(d.join.err))) or "not tried",
    d.join and tostring(d.join.indexAfter) or "-"))
  for ch, r in pairs(d.rosters) do
    out(("     roster %s: %s"):format(ch, r.error or (("%s reported, %d readable, %d secret"):format(tostring(r.reported), r.readable, r.secret))))
  end

  local rec = {}
  for k, r in pairs(db.rateReceived) do
    rec[#rec + 1] = ("%s=%d in %ds"):format(k, r.n, (r.last or 0) - (r.first or 0))
  end
  table.sort(rec)
  out("NET Q11 received: " .. (#rec > 0 and table.concat(rec, "; ") or "none (have a peer run /probe burst or /probe rate)"))
  for tag, res in pairs(db.rateSent) do
    local parts = {}
    for k, n in pairs(res) do parts[#parts + 1] = k .. " x" .. n end
    out("     sent " .. tag .. ": " .. table.concat(parts, ", "))
  end

  local maps, ids = 0, 0
  for _, byId in pairs(db.layerStats.byMap) do maps = maps + 1; ids = ids + count(byId) end
  local delays, noChange = {}, 0
  for _, j in ipairs(db.joins) do
    if j.delay then delays[#delays + 1] = j.delay elseif j.leftAt or now() - j.t > 360 then noChange = noChange + 1 end
  end
  out(("LAYER Q12: now %s on map %s; %d zone ids across %d maps; %d group joins, %d changed layer (median %ss), %d no change"):format(
    tostring(layer), tostring(layerMap), ids, maps, #db.joins, #delays, tostring(median(delays) or "-"), noChange))

  local sec, lockScans = {}, 0
  for _, s in ipairs(db.scans) do
    for f, n in pairs(s.secretFields) do sec[f] = (sec[f] or 0) + n end
    if s.lockdown.instance or s.lockdown.chatLockdown == true then lockScans = lockScans + 1 end
  end
  local secList = {}
  for f, n in pairs(sec) do secList[#secList + 1] = f .. " x" .. n end
  out(("LAYER Q13 lockdown: %d scans in instance/lockdown; secret fields: %s; secret addon messages: %d"):format(lockScans,
    #secList > 0 and table.concat(secList, ", ") or "none", db.secret.messages or 0))
  for who, rs in pairs(db.remote) do
    local r = rs.result
    out(("REMOTE %s (%s, %s): %s"):format(who, rs.realm, tostring(rs.target), type(r) == "table"
      and ("%d shared of theirs %d / yours %d, merged %d"):format(r.shared, r.theirs, r.mine, r.union)
      or tostring(r or ("waiting: " .. count(rs.ids) .. "/" .. tostring(rs.n) .. " ids"))))
  end
  out("Full data: WTF/Account/<account>/SavedVariables/LayerProbe.lua (written on /reload or logout)")
end

---------------------------------------------------------------------------
-- UI: one button, because a click is the cleanest "hardware event" test
---------------------------------------------------------------------------
local button
local function makeButton()
  button = CreateFrame("Button", "LayerProbeScanButton", UIParent, "UIPanelButtonTemplate")
  button:SetSize(130, 24)
  button:SetPoint("TOP", 0, -120)
  button:SetText("Probe: scan")
  button:SetMovable(true)
  button:RegisterForDrag("LeftButton")
  button:SetScript("OnDragStart", button.StartMoving)
  button:SetScript("OnDragStop", button.StopMovingOrSizing)
  button:SetScript("OnClick", function() doSearch("button") end)
  button:Hide()
end

---------------------------------------------------------------------------
-- Snapshot: one search for one dungeon, as plain text anyone can paste. Snapshots taken on
-- different realms are compared with tools/compare_snapshots.py in the repo.
---------------------------------------------------------------------------
local snapButton, snapFrame
local snapshot -- defined below

local function remaining(mc, role)
  if type(mc) ~= "table" then return 0 end
  return tonumber(mc[role .. "_REMAINING"]) or 0
end

local function snapshotText(scan)
  local lines = {}
  local faction = UnitFactionGroup and UnitFactionGroup("player")
  lines[#lines + 1] = ("LFGSNAP v1 | realm=%s | faction=%s | build=%s | utc=%s | t=%d | layer=%s | map=%s | zone=%s"):format(
    tostring(myRealm), tostring(not isSecret(faction) and faction or "?"), tostring(db.client.build),
    date("!%Y-%m-%d %H:%M:%S", scan.t), scan.t, tostring(scan.layer), tostring(scan.map), tostring(scan.zone))
  lines[#lines + 1] = ("activity=%s | total=%s | shown=%d | complete=%s"):format(
    db.target and table.concat(db.target.names, " + ") or "whole category", tostring(scan.total), scan.n,
    scan.complete and "yes" or "NO (capped at 100 - pick a narrower dungeon)")
  lines[#lines + 1] = "party | leader-realm | members | needs (T/H/D) or solo roles | level | class | leader zone | listed"
  local named, unnamed = 0, 0
  for _, r in ipairs(scan.results) do
    local leader
    for _, m in pairs(r.members) do if type(m) == "table" and (m.isLeader or r.numMembers == 1) then leader = m end end
    local needs
    if r.numMembers == 1 then
      local lr = leader and leader.lfgRoles
      needs = "solo:" .. (type(lr) == "table" and ((lr.tank and "T" or "") .. (lr.healer and "H" or "") .. (lr.dps and "D" or "")) or "?")
    else
      needs = ("%d/%d/%d"):format(remaining(r.memberCounts, "TANK"), remaining(r.memberCounts, "HEALER"), remaining(r.memberCounts, "DAMAGER"))
    end
    if r.key then named = named + 1 else unnamed = unnamed + 1 end
    local listed = tonumber(r.age)
    lines[#lines + 1] = ("%s | %s | %s | %s | %s | %s | %s | %s"):format(
      (tostring(r.id or "?"):gsub("^Party%-", "")), r.key or "(name not loaded)", tostring(r.numMembers), needs,
      tostring(leader and leader.level or "?"), tostring(leader and leader.class or "?"), tostring(r.leaderArea or "?"),
      listed and (math.floor(listed / 60) .. "m") or "?")
  end
  lines[#lines + 1] = ("END | %d listings, %d without a loaded name%s"):format(#scan.results, unnamed,
    unnamed > 0 and " (click Take snapshot again in ~5 s to fill them in)" or "")
  return table.concat(lines, "\n")
end

local function makeSnapFrame()
  snapFrame = CreateFrame("Frame", "LayerProbeSnapshotFrame", UIParent, "BasicFrameTemplateWithInset")
  snapFrame:SetSize(640, 380)
  snapFrame:SetPoint("CENTER")
  snapFrame:SetMovable(true)
  snapFrame:EnableMouse(true)
  snapFrame:RegisterForDrag("LeftButton")
  snapFrame:SetScript("OnDragStart", snapFrame.StartMoving)
  snapFrame:SetScript("OnDragStop", snapFrame.StopMovingOrSizing)
  tinsert(UISpecialFrames, "LayerProbeSnapshotFrame")
  local title = snapFrame.TitleText or snapFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if not snapFrame.TitleText then title:SetPoint("TOP", 0, -5) end
  title:SetText("LayerProbe snapshot - press Ctrl+C (Cmd+C on Mac), then paste it anywhere")
  local scroll = CreateFrame("ScrollFrame", nil, snapFrame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 12, -30)
  scroll:SetPoint("BOTTOMRIGHT", -32, 12)
  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetFontObject("ChatFontSmall")
  edit:SetWidth(590)
  edit:SetAutoFocus(false)
  edit:SetScript("OnEscapePressed", function() snapFrame:Hide() end)
  edit:SetScript("OnTextChanged", function(self, user) if user then self:SetText(self.text or "") self:HighlightText() end end)
  scroll:SetScrollChild(edit)
  snapFrame.edit = edit
end

local function showText(text)
  if not snapFrame then makeSnapFrame() end
  snapFrame.edit.text = text
  snapFrame.edit:SetText(text)
  snapFrame:Show()
  snapFrame.edit:SetFocus()
  snapFrame.edit:HighlightText()
end

showSnapshot = function(scan)
  local text = snapshotText(scan)
  db.lastSnapshot = text
  showText(text)
  out(("snapshot ready: %d listings for %s"):format(#scan.results, db.target and db.target.query or "the category"))
end

---------------------------------------------------------------------------
-- Macros: friends WITHOUT the addon run two chat lines; the second sends their tool's party ids
-- to you as hidden addon messages ("LP" prefix: "R<count>^id,id,..."). Your probe compares them
-- with your own snapshot of the same dungeon.
---------------------------------------------------------------------------
local function macroLines()
  local t = db.target
  local ids = {}
  for _, id in ipairs(t.ids) do ids[#ids + 1] = tostring(id) end
  local l1 = ("/run C_LFGList.Search(%d,0,0,nil,false,nil,{%s})"):format(t.cat, table.concat(ids, ","))
  local l2 = ('/run local g,s,_,r=C_LFGList.GetSearchResultInfo,"",C_LFGList.GetSearchResults()for k,i in ipairs(r)do '
    .. 's=s..g(i).partyGUID:sub(7)..","if#s>200 or k==#r then C_ChatInfo.SendAddonMessage("%s","R"..#r.."^"..s,'
    .. '"WHISPER","%s")s=""end end'):format(RPREFIX, myName)
  return l1, l2
end

local function macros(arg)
  if arg ~= "" then setDungeon(arg) end
  if not db.target then return out("pick a dungeon: /probe macros <name>   (/probe dungeon lists them)") end
  local l1, l2 = macroLines()
  local text = table.concat({
    "LFG realm test for " .. table.concat(db.target.names, " + ") .. " - no addon needed, takes 10 seconds:",
    "1) Paste this into your chat box and press Enter (it searches the LFG tool):",
    l1,
    "2) Wait 3 seconds, then paste this and press Enter (it sends the results to " .. myName .. ", invisibly):",
    l2,
    "Must be the same faction as " .. myName .. ". Nothing shows in chat and nothing is installed.",
  }, "\n")
  showText(text)
  if #l1 > 255 or #l2 > 255 then
    out(("|cffff5555warning:|r a line is %d characters; WoW's chat box takes 255. Pick a dungeon with fewer activities."):format(math.max(#l1, #l2)))
  end
  out("copy the text and send it to your friends. Then click |cff33ff99Take snapshot|r yourself at the same time:")
  snapshot("")
end

onRemote = function(msg, sender)
  local n, ids = msg:match("^R(%d+)%^(.*)$")
  local who = not isSecret(sender) and type(sender) == "string" and sender or nil
  if not n or not who then return end
  local realm = who:match("%-([^%-]+)$") or myRealm
  local rs = db.remote[who]
  if not rs or now() - rs.t > 120 then
    rs = { by = who, realm = realm, n = tonumber(n), t = now(), ids = {}, target = db.target and db.target.query }
    db.remote[who] = rs
  end
  for id in ids:gmatch("[^,]+") do rs.ids[id] = true end
  if count(rs.ids) < rs.n then return end -- more chunks to come
  -- compare with my latest complete scan, ideally a snapshot, from the last 10 minutes
  local mine
  for i = #db.scans, 1, -1 do
    local sc = db.scans[i]
    if rs.t - sc.t > 600 then break end
    if sc.complete then mine = sc break end
  end
  if not mine then
    rs.result = "no own snapshot to compare with"
    return out(("%s (%s) sent %d listings - click Take snapshot yourself to compare"):format(who, realm, rs.n))
  end
  local shared, union = 0, {}
  for k in pairs(mine.items) do union[(k:gsub("^Party%-", ""))] = true end
  for k in pairs(rs.ids) do
    if union[k] then shared = shared + 1 end
    union[k] = true
  end
  local u, m = count(union), count(mine.items)
  rs.result = { shared = shared, theirs = rs.n, mine = m, union = u, sameRealm = realm == myRealm, myScanT = mine.t }
  out(("|cff33ff99%s|r (%s): %d listings, %d shared with your %d -> merged list %d (%.1fx yours)%s"):format(who, realm,
    rs.n, shared, m, u, m > 0 and u / m or 0, realm == myRealm and " [same realm: control]" or ""))
end

function snapshot(arg)
  if arg ~= "" then setDungeon(arg) end
  if not db.target then return out("pick a dungeon: /probe snapshot <name>   (/probe dungeon lists them)") end
  if not snapButton then
    snapButton = CreateFrame("Button", "LayerProbeSnapshotButton", UIParent, "UIPanelButtonTemplate")
    snapButton:SetSize(200, 28)
    snapButton:SetPoint("TOP", 0, -150)
    snapButton:SetMovable(true)
    snapButton:RegisterForDrag("LeftButton")
    snapButton:SetScript("OnDragStart", snapButton.StartMoving)
    snapButton:SetScript("OnDragStop", snapButton.StopMovingOrSizing)
    snapButton:SetScript("OnClick", function() doSearch("snapshot") end) -- a click: the game allows the search
  end
  snapButton:SetText("Take snapshot: " .. db.target.query)
  snapButton:Show()
  out("click |cff33ff99Take snapshot|r (searching needs a click). Target an NPC first so your layer is included.")
end

local HELP = {
  "/probe dungeon [name|all] - list activities, or focus scans on one dungeon",
  "/probe snapshot <dungeon> - one search as copyable text, to compare realms",
  "/probe macros <dungeon> - two chat lines for friends WITHOUT the addon; results whisper to you",
  "/probe duo First Surname - quick two-player test with a friend (prints the steps)",
  "/probe peer First Surname - add a friend for whisper tests (/probe peer clear)",
  "/probe scan - search now (slash permission)   /probe button - Scan button (click permission)",
  "/probe timerscan - search from a timer (expected to be blocked: that's the test)",
  "/probe roster - try to read member lists of our channel and General (finding users)",
  "/probe ping | burst [n] | rate <per-second> <seconds> - message route and throughput tests",
  "/probe api - LFG functions on this client   /probe report - answers   /probe reset - wipe data",
}

local function slash(input)
  local cmd, arg = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  if cmd == "scan" then doSearch("slash")
  elseif cmd == "button" then button:SetShown(not button:IsShown())
  elseif cmd == "timerscan" then out("searching from a timer in 1s..."); C_Timer.After(1, function() doSearch("timer") end)
  elseif cmd == "dungeon" then setDungeon(arg)
  elseif cmd == "ping" then ping("manual"); out("ping sent")
  elseif cmd == "burst" then burst(tonumber(arg) or 20)
  elseif cmd == "rate" then
    local perSec, secs = arg:match("^(%S+)%s+(%S+)$")
    perSec, secs = tonumber(perSec) or 1, tonumber(secs) or 60
    if count(db.peerTargets) == 0 then return out("add a peer first: /probe peer First Surname") end
    rateTest(math.max(0.2, math.min(perSec, 10)), math.max(5, math.min(secs, 300)))
  elseif cmd == "roster" then
    requestRoster(CHANNEL)
    C_Timer.After(12, function()
      for i = 1, GetNumDisplayChannels and GetNumDisplayChannels() or 0 do
        local ok, name, header = pcall(GetChannelDisplayInfo, i)
        if ok and not header and type(name) == "string" and not isSecret(name) and name ~= CHANNEL then
          requestRoster(name) -- the first public channel (usually General)
          return
        end
      end
    end)
  elseif cmd == "snapshot" then snapshot(arg)
  elseif cmd == "macros" then macros(arg)
  elseif cmd == "duo" then
    if arg == "" then return out("usage: /probe duo First Surname   (your friend's full name)") end
    wipe(db.peerTargets)
    db.peerTargets[arg] = true
    button:Show()
    ping("manual")
    out("|cff33ff99duo test with " .. arg .. "|r - both players:")
    out("  1. target any NPC (so your layer is known)")
    out("  2. " .. (db.target and ("dungeon is set: " .. db.target.query .. " - your friend must pick the same")
      or "|cffffff00pick the SAME dungeon as your friend: /probe dungeon <name>|r"))
    out("  3. click the Scan button together, 5 times, ~30 s apart")
    out("  4. one invites the other, the invited one keeps mousing over NPCs (layer timing)")
    out("  5. /probe report, then /reload and send LayerProbe.lua")
  elseif cmd == "peer" then
    if arg == "clear" then wipe(db.peerTargets); out("peers cleared")
    elseif arg ~= "" then db.peerTargets[arg] = true; out("will whisper-test with " .. arg); ping("manual")
    else
      local p = {} for n in pairs(db.peerTargets) do p[#p + 1] = n end
      out("peers: " .. (#p > 0 and table.concat(p, ", ") or "none"))
    end
  elseif cmd == "api" then
    local inv = inventory()
    out("C_LFGList: " .. (#inv.lfglist > 0 and table.concat(inv.lfglist, ", ") or "MISSING ENTIRELY"))
    local frames = {}
    for fr, present in pairs(inv.frames) do if present then frames[#frames + 1] = fr end end
    out("LFG frames present: " .. (#frames > 0 and table.concat(frames, ", ") or "none"))
    out("activities in catalog: " .. #catalog())
  elseif cmd == "report" then report()
  elseif cmd == "reset" then LayerProbeDB = nil; ReloadUI()
  else for _, l in ipairs(HELP) do out(l) end end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local f = CreateFrame("Frame")
local H = {}

function H.ADDON_LOADED(name)
  if name ~= ADDON then return end
  if not LayerProbeDB or LayerProbeDB.schema ~= 3 then LayerProbeDB = { schema = 3 } end -- older data has another shape
  db = LayerProbeDB
  for _, k in ipairs({ "remote", "log", "scans", "rawSamples", "routes", "crossLayer", "peerScans", "peers", "searchTests",
                       "searchLog", "sendResults", "rateSent", "rateReceived", "peerTargets", "lifecycle", "joins",
                       "secret" }) do db[k] = db[k] or {} end
  db.layerStats = db.layerStats or { samples = 0, byMap = {} }
  db.layerStats.byMap = db.layerStats.byMap or {}
  db.discovery = db.discovery or {}
  db.discovery.rosters = db.discovery.rosters or {}
  local version, build, _, iface = GetBuildInfo()
  db.client = { version = version, build = build, interface = iface, realm = GetRealmName() }
  C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
  C_ChatInfo.RegisterAddonMessagePrefix(RPREFIX)
  if C_LFGList and C_LFGList.Search then
    hooksecurefunc(C_LFGList, "Search", function(cat, _, _, _, _, _, acts)
      local ids = {}
      if type(acts) == "table" then for _, a in ipairs(acts) do ids[#ids + 1] = tostring(a) end end
      db.lastSearchActs = cat .. ":" .. table.concat(ids, ",")
      table.sort(ids)
      db.lastSearchSig = cat .. "." .. table.concat(ids, "."):sub(1, 60)
      if not pending or GetTime() - pending.at > 15 then -- Blizzard's own panel searched (or ours never answered)
        local t = GetTime()
        pending = { how = "blizzard-ui", at = t, gap = lastSearchAt and (t - lastSearchAt) or nil }
        lastSearchAt = t
      end
    end)
  end
  makeButton()
  SLASH_LAYERPROBE1 = "/probe"
  SlashCmdList.LAYERPROBE = slash
end

function H.PLAYER_LOGIN()
  myName = getMyName()
  myRealm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName() or "?"):gsub("%s", "")
  wasInGroup = IsInGroup() and true or false
  inventory()
  C_Timer.NewTicker(60, function() ping("auto") end)
  C_Timer.NewTicker(0.3, pumpQueue)
  C_Timer.After(30, function() requestRoster(CHANNEL) end)
  out("loaded as " .. myName .. "-" .. myRealm .. " - /probe for commands. Target an NPC so your layer is known.")
  if #db.inventory.missing > 0 then out("|cffff5555missing LFG functions:|r " .. table.concat(db.inventory.missing, ", ")) end
end

function H.PLAYER_ENTERING_WORLD()
  layer, layerMap = nil, nil
  C_Timer.After(5, function()
    joinChannel()
    for i = 1, NUM_CHAT_WINDOWS do local cf = _G["ChatFrame" .. i]; if cf then ChatFrame_RemoveChannel(cf, CHANNEL) end end
    C_Timer.After(2, function() ping("login") end)
    if not db.catalog then catalog() end
  end)
end

function H.CHAT_MSG_CHANNEL_NOTICE(notice, _, _, _, _, _, _, _, channelName)
  if isSecret(notice, channelName) or channelName ~= CHANNEL then return end
  db.discovery.notices = db.discovery.notices or {}
  table.insert(db.discovery.notices, { notice = notice, t = now() })
  log("channel-notice", { notice = notice })
end

function H.CHANNEL_ROSTER_UPDATE(displayIndex, countArg) onRoster(displayIndex, countArg) end
function H.PLAYER_TARGET_CHANGED() sample("target") end
function H.UPDATE_MOUSEOVER_UNIT() sample("mouseover") end
function H.NAME_PLATE_UNIT_ADDED(unit) sample(unit) end
function H.ZONE_CHANGED_NEW_AREA() layer = nil; log("zone-change", { newMap = C_Map.GetBestMapForUnit("player") }) end
function H.GROUP_ROSTER_UPDATE() onGroupChanged() end
function H.CHAT_MSG_ADDON(...) onAddonMessage(...) end

function H.LFG_LIST_SEARCH_RESULTS_RECEIVED()
  local how = pending and pending.how
  if how and db.searchTests[how] then db.searchTests[how].results = db.searchTests[how].results + 1 end
  onResults()
end

function H.LFG_LIST_SEARCH_FAILED(reason)
  local how = pending and pending.how or "blizzard-ui"
  if db.searchTests[how] then db.searchTests[how].failed = db.searchTests[how].failed + 1 end
  db.searchLog[#db.searchLog + 1] = { how = how, gap = pending and pending.gap, outcome = "failed", reason = tostring(reason), t = now() }
  log("search-failed", { how = how, reason = tostring(reason) })
  out("search failed (" .. how .. "): " .. tostring(reason))
  pending = nil
end

local function blocked(event, addon, func)
  if addon ~= ADDON then return end
  local how = pending and pending.how or "?"
  if db.searchTests[how] then db.searchTests[how].blocked = db.searchTests[how].blocked + 1 end
  db.searchLog[#db.searchLog + 1] = { how = how, gap = pending and pending.gap, outcome = "blocked", t = now() }
  log("blocked", { event = event, func = tostring(func), how = how })
  out(("|cffff5555%s|r: %s (via %s)"):format(event, tostring(func), how))
  pending = nil
end
function H.ADDON_ACTION_BLOCKED(addon, func) blocked("ADDON_ACTION_BLOCKED", addon, func) end
function H.ADDON_ACTION_FORBIDDEN(addon, func) blocked("ADDON_ACTION_FORBIDDEN", addon, func) end

function H.LFG_LIST_SEARCH_RESULT_UPDATED(id)
  local ok, info = pcall(C_LFGList.GetSearchResultInfo, id)
  if ok and type(info) == "table" and info.isDelisted == true then
    local key = fullKey(info.leaderName)
    if key and db.lifecycle[key] then db.lifecycle[key].delistedAt = now() end
    log("delisted", { leader = describeString(info.leaderName), age = copy(info.age) })
  end
end

-- Q8: can we read our own listing (needed to auto-publish it)?
function H.LFG_LIST_ACTIVE_ENTRY_UPDATE()
  local own = db.ownEntry or { updates = 0 }
  own.updates = own.updates + 1
  local okHas, has = pcall(C_LFGList.HasActiveEntryInfo)
  if okHas then own.has = copy(has) else own.has = "error: " .. tostring(has) end
  if okHas and has == true then
    local ok, e = pcall(C_LFGList.GetActiveEntryInfo)
    own.readable = ok and type(e) == "table"
    if own.readable then
      own.activities = isSecret(e.activityIDs) and "secret" or (type(e.activityIDs) == "table" and #e.activityIDs or 0)
      own.sample = copy(e)
    end
    own.lockdown = lockdown()
  end
  db.ownEntry = own
end

f:SetScript("OnEvent", function(_, event, ...) H[event](...) end)
for event in pairs(H) do pcall(f.RegisterEvent, f, event) end -- some events may not exist on this client
