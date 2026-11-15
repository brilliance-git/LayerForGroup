-- LayerProbe (WoW: Forever edition): answers the questions LayerLink depends on, with data.
--   Q0  Which LFG API does this client have at all?      (C_LFGList inventory, Blizzard LFG addons loaded)
--   Q1  Is the LFG tool limited to your layer?            (compare scans from different layers)
--   Q2  Which message routes reach a player on another layer? (custom channel, guild, whisper)
--   Q3  What can an addon read from a listing?            (full result dumps + activity names)
--   Q4  When may an addon search?                         (button / slash / timer)
--   Q5  How many addon messages get through?              (burst test per route, send results logged)
--   Q6  How do layers behave?                             (zone id per map, every change logged)
-- Forever specifics handled here: names are "First Surname", some values arrive as secret values,
-- layers are per zone, and custom-channel addon messages reportedly don't deliver (Q2 checks it).
-- Data: WTF/Account/<acct>/SavedVariables/LayerProbe.lua. Type /probe for commands.
local ADDON = ...
local PREFIX, CHANNEL = "LProbe", "LayerProbeNet"
local db
local myName, layer, layerMap = nil, nil, nil
local pendingSearch -- { how }

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

-- What a listing string looks like to us: readable, a protected token, secret, or nothing.
local function describeString(s)
  if isSecret(s) then return "secret" end
  if s == nil then return "nil" end
  if type(s) ~= "string" then return type(s) end
  if s == "" then return "empty" end
  if s:find("|K", 1, true) then return "kstring-token(" .. #s .. ")" end
  return "readable(" .. #s .. "): " .. s:sub(1, 60)
end

-- Forever names: "First Surname" (UnitName alone gives only the first name).
local function getMyName()
  local first, second = UnitFullName("player")
  if not isSecret(first, second) and first and C_PlayerInfo and C_PlayerInfo.ShouldDisplaySurname
     and C_PlayerInfo.ShouldDisplaySurname() and second and second ~= "" then
    return first .. " " .. second
  end
  local n = UnitName("player")
  return (not isSecret(n) and n) or "?"
end

-- "First Surname-Realm" -> "First Surname"; plain names lose a realm suffix only if it's ours.
local function normName(name)
  if isSecret(name) or type(name) ~= "string" or name == "" then return nil end
  return name:match("^(%S+ %S+)%-%S+$") or Ambiguate(name, "none")
end

---------------------------------------------------------------------------
-- Q0: API inventory
---------------------------------------------------------------------------
local WANTED = { "Search", "GetSearchResults", "GetSearchResultInfo", "GetSearchResultPlayerInfo",
  "GetSearchResultLeaderInfo", "GetActivityInfoTable", "GetAvailableCategories", "GetAvailableActivities",
  "GetLfgCategoryInfo", "HasActiveEntryInfo", "GetActiveEntryInfo", "CreateListing", "RemoveListing", "GetRoles" }

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
  db.inventory = inv
  return inv
end

---------------------------------------------------------------------------
-- Q6: layers (per zone on Forever)
---------------------------------------------------------------------------
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
    layer, layerMap = id, map
    local key = tostring(map)
    s.byMap[key] = s.byMap[key] or {}
    s.byMap[key][tostring(id)] = (s.byMap[key][tostring(id)] or 0) + 1
  end
end

---------------------------------------------------------------------------
-- Q2 + Q5: message routes. Every message goes out on every route we have;
-- the receiver records which route (CHANNEL / GUILD / WHISPER) it arrived on.
---------------------------------------------------------------------------
local function sendOne(msg, dist, target)
  local ok, r = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, dist, target)
  local key = dist .. ":" .. (ok and tostring(r) or ("error " .. tostring(r)))
  db.sendResults[key] = (db.sendResults[key] or 0) + 1
end

local function sendAll(msg)
  local idx = GetChannelName(CHANNEL)
  if idx and idx > 0 then sendOne(msg, "CHANNEL", idx) end
  if IsInGuild() then sendOne(msg, "GUILD") end
  for name in pairs(db.peerTargets) do sendOne(msg, "WHISPER", name) end
end

local function sendChunks(head, items)
  local buf = {}
  local function flush()
    if #buf > 0 then sendAll(head .. "^" .. table.concat(buf, ",")); buf = {} end
  end
  for _, s in ipairs(items) do
    if #head + #table.concat(buf, ",") + #s + 2 > 240 then flush() end
    buf[#buf + 1] = s
  end
  flush()
end

local seq = 0
local function ping(tag)
  seq = seq + 1
  sendAll(("P^%s^%s^%d^%d^%s"):format(layer or "", layerMap or "", seq, now(), tag or ""))
end

local function burst(n)
  out("sending " .. n .. " messages on every route as fast as possible...")
  for i = 1, n do ping("burst" .. i) end
  log("burst", { n = n })
end

local function onAddonMessage(prefix, msg, dist, sender)
  if isSecret(prefix, msg, dist, sender) then
    db.secretMessages = (db.secretMessages or 0) + 1
    return
  end
  if prefix ~= PREFIX then return end
  sender = normName(sender)
  if not sender or sender:lower() == (myName or ""):lower() then return end
  local f = { strsplit("^", msg) }
  local theirLayer = f[2] or ""
  local cross = theirLayer ~= "" and layer and tonumber(theirLayer) ~= layer

  local route = db.routes[dist] or { received = 0, crossLayer = 0, from = {} }
  route.received = route.received + 1
  if cross then route.crossLayer = route.crossLayer + 1 end
  route.from[sender] = theirLayer
  db.routes[dist] = route

  -- answer anyone we hear from by whisper too, so the WHISPER route gets tested both ways
  if not db.peerTargets[sender] and dist ~= "WHISPER" then
    local n = 0 for _ in pairs(db.peerTargets) do n = n + 1 end
    if n < 10 then db.peerTargets[sender] = true end
  end

  if f[1] == "P" then
    if cross and not db.crossLayer[dist] then
      db.crossLayer[dist] = { from = sender, theirLayer = theirLayer, ourLayer = layer, t = now() }
      out(("|cff33ff99%s reaches another layer|r: ping from %s (layer %s, you %s)"):format(dist, sender, theirLayer, layer))
    end
    if (f[6] or ""):find("^burst") then
      local k = sender .. " via " .. dist
      db.burstReceived[k] = (db.burstReceived[k] or 0) + 1
    end
  elseif f[1] == "S" then
    local key = sender .. "@" .. (f[3] or "")
    local ps = db.peerScans[key] or { by = sender, layer = theirLayer, t = tonumber(f[3]), n = tonumber(f[4]), leaders = {}, seen = {} }
    for name in (f[5] or ""):gmatch("[^,]+") do
      if not ps.seen[name] then ps.seen[name] = true; ps.leaders[#ps.leaders + 1] = name end
    end
    db.peerScans[key] = ps -- the same chunk may arrive on several routes; `seen` dedups
  end
end

---------------------------------------------------------------------------
-- Q1 + Q3: harvesting search results
---------------------------------------------------------------------------
local function dumpActivity(id)
  if db.activities[id] or not C_LFGList.GetActivityInfoTable then return end
  local ok, info = pcall(C_LFGList.GetActivityInfoTable, id)
  db.activities[id] = ok and (copy(info) or "nil") or ("error: " .. tostring(info))
end

local function onResults()
  local ok, total, results = pcall(C_LFGList.GetSearchResults)
  if not ok or type(results) ~= "table" then
    log("results-unreadable", { err = tostring(total) })
    return out("search results arrived but couldn't be read: " .. tostring(total))
  end
  local scan = { t = now(), layer = layer, map = layerMap, total = total, n = #results, leaders = {},
                 how = pendingSearch and pendingSearch.how or "blizzard-ui", results = {} }
  pendingSearch = nil
  for i, id in ipairs(results) do
    local gotInfo, info = pcall(C_LFGList.GetSearchResultInfo, id)
    if gotInfo and type(info) == "table" then
      for _, a in ipairs(type(info.activityIDs) == "table" and info.activityIDs or { info.activityID }) do dumpActivity(a) end
      local r = {
        leader = describeString(info.leaderName), numMembers = copy(info.numMembers), age = copy(info.age),
        isDelisted = copy(info.isDelisted), activityIDs = copy(info.activityIDs), activityID = copy(info.activityID),
        hasSelf = copy(info.hasSelf), playstyle = copy(info.playstyle), generalPlaystyle = copy(info.generalPlaystyle),
        name = describeString(info.name), comment = describeString(info.comment), members = {},
      }
      local n = tonumber(not isSecret(info.numMembers) and info.numMembers) or 0
      for m = 1, math.min(n, 40) do
        local gotP, p = pcall(C_LFGList.GetSearchResultPlayerInfo, id, m)
        r.members[m] = (gotP and type(p) == "table") and { name = describeString(p.name), level = copy(p.level),
          class = copy(p.classFilename), role = copy(p.assignedRole), lfgRoles = copy(p.lfgRoles),
          isLeader = copy(p.isLeader), area = describeString(p.areaName) } or (gotP and "nil" or "error")
      end
      if i <= 60 then scan.results[#scan.results + 1] = r end -- keeps the file a sane size
      local leader = normName(info.leaderName)
      if leader then scan.leaders[#scan.leaders + 1] = leader end
      if #db.rawSamples < 5 then db.rawSamples[#db.rawSamples + 1] = copy(info) end
    end
  end
  table.insert(db.scans, scan)
  if #db.scans > 200 then table.remove(db.scans, 1) end
  out(("scan: %d results (total %s) on layer %s, map %s, via %s"):format(#results, tostring(total), tostring(layer),
    tostring(layerMap), scan.how))
  sendChunks(("S^%s^%d^%d"):format(layer or "", scan.t, #scan.leaders), scan.leaders)
end

---------------------------------------------------------------------------
-- Q4: search permission tests
---------------------------------------------------------------------------
local function doSearch(how)
  if not (C_LFGList and C_LFGList.Search) then return out("C_LFGList.Search does not exist on this client") end
  local cats = C_LFGList.GetAvailableCategories and C_LFGList.GetAvailableCategories() or {}
  local cat = cats[1]
  if not cat then return out("no LFG categories available - open the LFG tool once, then retry") end
  local acts = C_LFGList.GetAvailableActivities and C_LFGList.GetAvailableActivities(cat) or nil
  pendingSearch = { how = how }
  local ok, err = pcall(C_LFGList.Search, cat, 0, 0, nil, false, nil, acts)
  log("search-call", { how = how, ok = ok, err = err and tostring(err), category = cat, nActivities = acts and #acts })
  db.searchTests[how] = db.searchTests[how] or { calls = 0, results = 0, blocked = 0, failed = 0, errors = 0 }
  local t = db.searchTests[how]
  t.calls = t.calls + 1
  if not ok then t.errors = t.errors + 1; out("search error via " .. how .. ": " .. tostring(err)) end
end

---------------------------------------------------------------------------
-- Report
---------------------------------------------------------------------------
local function overlap()
  local n, shared, union = 0, 0, 0
  for _, mine in ipairs(db.scans) do
    local set = {}
    for _, l in ipairs(mine.leaders) do set[l:lower()] = true end
    for _, theirs in pairs(db.peerScans) do
      if mine.layer and theirs.layer ~= "" and tonumber(theirs.layer) ~= mine.layer
         and math.abs((theirs.t or 0) - mine.t) <= 180 and #theirs.leaders > 0 and #mine.leaders > 0 then
        n = n + 1
        local u = {}
        for l in pairs(set) do u[l] = true end
        for _, l in ipairs(theirs.leaders) do if set[l:lower()] then shared = shared + 1 end u[l:lower()] = true end
        for _ in pairs(u) do union = union + 1 end
      end
    end
  end
  return n, shared, union
end

local function report()
  out("---- report (" .. myName .. ", build " .. tostring(db.client.build) .. ") ----")
  local inv = inventory()
  out(("Q0 api: %d C_LFGList functions; missing: %s"):format(#inv.lfglist, #inv.missing > 0 and table.concat(inv.missing, ", ") or "none"))
  local addons = {}
  for name, state in pairs(inv.addons) do addons[#addons + 1] = name .. "=" .. state end
  out("Q0 lfg addons: " .. (#addons > 0 and table.concat(addons, " ") or "none found"))

  local maps, ids = 0, 0
  for _, byId in pairs(db.layerStats.byMap) do maps = maps + 1 for _ in pairs(byId) do ids = ids + 1 end end
  out(("Q6 layer: current %s on map %s; %d samples; %d zone ids across %d maps"):format(tostring(layer),
    tostring(layerMap), db.layerStats.samples, ids, maps))

  for _, dist in ipairs({ "CHANNEL", "GUILD", "WHISPER", "PARTY", "RAID" }) do
    local r = db.routes[dist]
    if r then
      local from = 0 for _ in pairs(r.from) do from = from + 1 end
      out(("Q2 %s: %d msgs from %d players, %d from another layer %s"):format(dist, r.received, from, r.crossLayer,
        db.crossLayer[dist] and "|cff33ff99(crosses layers)|r" or ""))
    end
  end
  if not next(db.routes) then out("Q2 routes: nothing received yet - add a friend with /probe peer First Surname") end

  local pairsN, shared, union = overlap()
  if pairsN == 0 then
    out("Q1 tool: no scan pairs from different layers within 3 min yet (scan at the same time as a friend on another layer)")
  else
    local pct = union > 0 and math.floor(100 * shared / union) or 0
    out(("Q1 tool: %d cross-layer scan pairs, %d%% leaders shared -> %s"):format(pairsN, pct,
      pct < 15 and "|cff33ff99tool looks layer-limited (LayerLink is useful)|r"
      or pct > 70 and "|cffff5555tool looks realm-wide (layers already see each other)|r" or "mixed - collect more"))
  end

  local last = db.scans[#db.scans]
  if last and last.results[1] then
    local r, m = last.results[1], last.results[1].members[1]
    out(("Q3 read: leader=%s members=%s name=%s comment=%s"):format(r.leader, tostring(r.numMembers), r.name, r.comment))
    if type(m) == "table" then
      out(("Q3 member: level=%s class=%s role=%s"):format(tostring(m.level), tostring(m.class), tostring(m.role)))
    end
  else
    out("Q3 read: no scans yet - open the LFG tool and hit refresh, or /probe scan")
  end

  for how, t in pairs(db.searchTests) do
    out(("Q4 search via %s: %d calls, %d result sets, %d blocked, %d failed, %d errors"):format(how, t.calls,
      t.results, t.blocked, t.failed, t.errors))
  end

  local sends, bursts = {}, {}
  for k, c in pairs(db.sendResults) do sends[#sends + 1] = k .. " x" .. c end
  for k, c in pairs(db.burstReceived) do bursts[#bursts + 1] = k .. "=" .. c end
  table.sort(sends)
  out("Q5 send results: " .. (#sends > 0 and table.concat(sends, ", ") or "none"))
  out("Q5 burst received: " .. (#bursts > 0 and table.concat(bursts, ", ") or "none"))
  if (db.secretMessages or 0) > 0 then out("note: " .. db.secretMessages .. " addon messages arrived as secret values") end
  out("Full data: WTF/Account/<account>/SavedVariables/LayerProbe.lua (written on /reload or logout)")
end

---------------------------------------------------------------------------
-- UI: one button, because a click is the cleanest "hardware event" test
---------------------------------------------------------------------------
local button
local function makeButton()
  button = CreateFrame("Button", "LayerProbeScanButton", UIParent, "UIPanelButtonTemplate")
  button:SetSize(120, 24)
  button:SetPoint("TOP", 0, -120)
  button:SetText("Probe: scan")
  button:SetMovable(true)
  button:RegisterForDrag("LeftButton")
  button:SetScript("OnDragStart", button.StartMoving)
  button:SetScript("OnDragStop", button.StopMovingOrSizing)
  button:SetScript("OnClick", function() doSearch("button") end)
  button:Hide()
end

local HELP = {
  "/probe peer First Surname - add a friend to whisper-test with (/probe peer clear)",
  "/probe scan - search the LFG tool now (tests slash-command permission)",
  "/probe button - show/hide a Scan button (tests click permission)",
  "/probe timerscan - search from a timer (expected to be blocked - that's the test)",
  "/probe ping - send a ping on every route",
  "/probe burst [n] - send n messages per route fast (default 20)",
  "/probe api - list the LFG functions this client has",
  "/probe report - summarize findings     /probe reset - wipe collected data",
}

local function slash(input)
  local cmd, arg = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  if cmd == "scan" then doSearch("slash")
  elseif cmd == "button" then button:SetShown(not button:IsShown())
  elseif cmd == "timerscan" then out("searching from a timer in 1s..."); C_Timer.After(1, function() doSearch("timer") end)
  elseif cmd == "ping" then ping("manual"); out("ping sent")
  elseif cmd == "burst" then burst(tonumber(arg) or 20)
  elseif cmd == "peer" then
    if arg == "clear" then wipe(db.peerTargets); out("peers cleared")
    elseif arg ~= "" then db.peerTargets[arg] = true; out("will whisper-test with " .. arg); ping("hello")
    else local p = {} for n in pairs(db.peerTargets) do p[#p + 1] = n end out("peers: " .. (#p > 0 and table.concat(p, ", ") or "none")) end
  elseif cmd == "api" then
    local inv = inventory()
    out("C_LFGList: " .. (#inv.lfglist > 0 and table.concat(inv.lfglist, ", ") or "MISSING ENTIRELY"))
    local frames = {}
    for fr, present in pairs(inv.frames) do if present then frames[#frames + 1] = fr end end
    out("LFG frames present: " .. (#frames > 0 and table.concat(frames, ", ") or "none"))
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
  LayerProbeDB = LayerProbeDB or {}
  db = LayerProbeDB
  for _, k in ipairs({ "log", "scans", "activities", "rawSamples", "routes", "crossLayer", "peerScans",
                       "searchTests", "sendResults", "burstReceived", "peerTargets" }) do db[k] = db[k] or {} end
  db.layerStats = db.layerStats or { samples = 0, byMap = {} }
  db.layerStats.byMap = db.layerStats.byMap or {}
  local version, build, _, iface = GetBuildInfo()
  db.client = { version = version, build = build, interface = iface, realm = GetRealmName() }
  C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
  if C_LFGList and C_LFGList.Search then
    hooksecurefunc(C_LFGList, "Search", function(cat, _, _, _, _, _, acts)
      log("search-hook", { category = cat, nActivities = type(acts) == "table" and #acts or 0, ours = pendingSearch ~= nil })
    end)
  end
  makeButton()
  SLASH_LAYERPROBE1 = "/probe"
  SlashCmdList.LAYERPROBE = slash
end

function H.PLAYER_LOGIN()
  myName = getMyName()
  inventory()
  C_Timer.NewTicker(60, function() ping("auto") end)
  out("loaded as " .. myName .. " - /probe for commands. Target an NPC so your layer is known.")
  if #db.inventory.missing > 0 then out("|cffff5555missing LFG functions:|r " .. table.concat(db.inventory.missing, ", ")) end
end

function H.PLAYER_ENTERING_WORLD()
  layer, layerMap = nil, nil
  C_Timer.After(5, function()
    if GetChannelName(CHANNEL) == 0 then
      local ok, err = pcall(JoinTemporaryChannel, CHANNEL)
      log("channel-join", { ok = ok, err = err and tostring(err) })
    end
    for i = 1, NUM_CHAT_WINDOWS do local cf = _G["ChatFrame" .. i]; if cf then ChatFrame_RemoveChannel(cf, CHANNEL) end end
    C_Timer.After(2, function() ping("login") end)
  end)
end

function H.CHAT_MSG_CHANNEL_NOTICE(notice, _, _, _, _, _, _, _, channelName)
  if not isSecret(notice, channelName) and channelName == CHANNEL then log("channel-notice", { notice = notice }) end
end

function H.PLAYER_TARGET_CHANGED() sample("target") end
function H.UPDATE_MOUSEOVER_UNIT() sample("mouseover") end
function H.NAME_PLATE_UNIT_ADDED(unit) sample(unit) end
function H.ZONE_CHANGED_NEW_AREA() layer = nil; log("zone-change", { newMap = C_Map.GetBestMapForUnit("player") }) end
function H.GROUP_ROSTER_UPDATE() log("group", { size = GetNumGroupMembers() }) end
function H.CHAT_MSG_ADDON(...) onAddonMessage(...) end

function H.LFG_LIST_SEARCH_RESULTS_RECEIVED()
  local how = pendingSearch and pendingSearch.how
  if how and db.searchTests[how] then db.searchTests[how].results = db.searchTests[how].results + 1 end
  onResults()
end

function H.LFG_LIST_SEARCH_FAILED(reason)
  local how = pendingSearch and pendingSearch.how or "blizzard-ui"
  if db.searchTests[how] then db.searchTests[how].failed = db.searchTests[how].failed + 1 end
  log("search-failed", { how = how, reason = tostring(reason) })
  out("search failed (" .. how .. "): " .. tostring(reason))
  pendingSearch = nil
end

local function blocked(event, addon, func)
  if addon ~= ADDON then return end
  local how = pendingSearch and pendingSearch.how or "?"
  if db.searchTests[how] then db.searchTests[how].blocked = db.searchTests[how].blocked + 1 end
  log("blocked", { event = event, func = tostring(func), how = how })
  out(("|cffff5555%s|r: %s (via %s)"):format(event, tostring(func), how))
  pendingSearch = nil
end
function H.ADDON_ACTION_BLOCKED(addon, func) blocked("ADDON_ACTION_BLOCKED", addon, func) end
function H.ADDON_ACTION_FORBIDDEN(addon, func) blocked("ADDON_ACTION_FORBIDDEN", addon, func) end

function H.LFG_LIST_SEARCH_RESULT_UPDATED(id)
  local ok, info = pcall(C_LFGList.GetSearchResultInfo, id)
  if ok and type(info) == "table" and info.isDelisted == true then
    log("delisted", { leader = describeString(info.leaderName), age = copy(info.age) })
  end
end

f:SetScript("OnEvent", function(_, event, ...) H[event](...) end)
for event in pairs(H) do pcall(f.RegisterEvent, f, event) end -- some events may not exist on this client
