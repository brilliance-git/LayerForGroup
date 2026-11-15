-- LayerProbe: answers the questions LayerLink depends on, with data.
--   Q1  Is the LFG tool limited to your layer?        (compare scans from different layers)
--   Q2  Does a custom chat channel reach other layers? (pings carry the sender's layer)
--   Q3  What can an addon read from a listing?         (full dumps of results + activity names)
--   Q4  When may an addon call C_LFGList.Search?       (button / slash / timer tests)
--   Q5  How many addon messages can we push?           (burst test, send results logged)
--   Q6  How reliable is layer detection?               (every zoneUID sample logged)
-- Everything is stored in WTF/Account/<acct>/SavedVariables/LayerProbe.lua.
-- Type /probe for commands. Best run by 2+ players on different layers at the same time.
local ADDON = ...
local PREFIX, CHANNEL = "LProbe", "LayerProbeNet"
local db
local me, layer, layerMap = nil, nil, nil
local pendingSearch -- { how, at }

local function now() return GetServerTime() end
local function out(...) DEFAULT_CHAT_FRAME:AddMessage("|cffff9933LayerProbe|r: " .. strjoin(" ", tostringall(...))) end
local function log(kind, data)
  data = data or {}
  data.kind, data.t, data.layer = kind, now(), layer
  table.insert(db.log, data)
  if #db.log > 3000 then table.remove(db.log, 1) end
end

local function copy(v, depth)
  if type(v) ~= "table" then return v end
  if (depth or 0) > 2 then return "<table>" end
  local c = {}
  for k, x in pairs(v) do c[k] = copy(x, (depth or 0) + 1) end
  return c
end

-- What a protected "kstring" looks like to us: readable text, an escape token, or nothing.
local function describeString(s)
  if s == nil then return "nil" end
  if type(s) ~= "string" then return type(s) end
  if s == "" then return "empty" end
  if s:find("|K", 1, true) then return "kstring-token(" .. #s .. ")" end
  return "readable(" .. #s .. "): " .. s:sub(1, 60)
end

---------------------------------------------------------------------------
-- Q6: layer detection
---------------------------------------------------------------------------
local function sample(unit)
  if IsInInstance() then return end
  local guid = UnitGUID(unit)
  if not guid then return end
  local unitType, _, serverID, instanceID, zoneUID, npcID = strsplit("-", guid)
  if unitType ~= "Creature" and unitType ~= "Vehicle" then return end
  local id = tonumber(zoneUID)
  if not id or id == 0 then return end
  local map = C_Map.GetBestMapForUnit("player")
  local s = db.layerStats
  s.samples = s.samples + 1
  if id ~= layer then
    log("layer", { from = layer, to = id, serverID = serverID, instanceID = instanceID, npcID = npcID, map = map, unit = unit })
    if layer then out("layer changed", layer, "->", id) end
    layer, layerMap = id, map
    s.distinct[id] = (s.distinct[id] or 0) + 1
  end
end

---------------------------------------------------------------------------
-- Q3 + Q1: harvesting search results
---------------------------------------------------------------------------
local function dumpActivity(id)
  if db.activities[id] then return end
  local info = C_LFGList.GetActivityInfoTable and C_LFGList.GetActivityInfoTable(id)
  db.activities[id] = copy(info) or "nil"
end

local function sendChunks(head, items)
  local idx = GetChannelName(CHANNEL)
  if not idx or idx == 0 then return end
  local buf = {}
  local function flush()
    if #buf > 0 then
      C_ChatInfo.SendAddonMessage(PREFIX, head .. "^" .. table.concat(buf, ","), "CHANNEL", idx)
      buf = {}
    end
  end
  for _, s in ipairs(items) do
    if #head + #table.concat(buf, ",") + #s + 2 > 240 then flush() end
    buf[#buf + 1] = s
  end
  flush()
end

local function onResults()
  local total, results = C_LFGList.GetSearchResults()
  local scan = { t = now(), layer = layer, total = total, n = #results, leaders = {},
                 how = pendingSearch and pendingSearch.how or "blizzard-ui", results = {} }
  pendingSearch = nil
  for i, id in ipairs(results) do
    local info = C_LFGList.GetSearchResultInfo(id)
    if info then
      for _, a in ipairs(info.activityIDs or {}) do dumpActivity(a) end
      local r = {
        leader = info.leaderName, numMembers = info.numMembers, age = info.age,
        isDelisted = info.isDelisted, activityIDs = copy(info.activityIDs), hasSelf = info.hasSelf,
        playstyle = info.playstyle, generalPlaystyle = info.generalPlaystyle, autoAccept = info.autoAccept,
        name = describeString(info.name), comment = describeString(info.comment),
        voiceChat = describeString(info.voiceChat), partyGUID = info.partyGUID,
        members = {},
      }
      for m = 1, math.min(info.numMembers or 0, 40) do
        local p = C_LFGList.GetSearchResultPlayerInfo and C_LFGList.GetSearchResultPlayerInfo(id, m)
        r.members[m] = p and { name = p.name, level = p.level, class = p.classFilename, role = p.assignedRole,
                               lfgRoles = copy(p.lfgRoles), isLeader = p.isLeader, area = p.areaName } or "nil"
      end
      if i <= 60 then scan.results[#scan.results + 1] = r end -- keep the file a sane size
      if info.leaderName then scan.leaders[#scan.leaders + 1] = Ambiguate(info.leaderName, "none") end
      -- remember a few raw result tables untouched, to see every field the client exposes
      if #db.rawSamples < 5 then db.rawSamples[#db.rawSamples + 1] = copy(info) end
    end
  end
  table.insert(db.scans, scan)
  if #db.scans > 200 then table.remove(db.scans, 1) end
  out(("scan: %d results (total %d) on layer %s via %s"):format(#results, total or -1, tostring(layer), scan.how))
  -- tell other probes what this layer's tool shows (Q1)
  sendChunks(("S^%s^%d^%d"):format(layer or "", scan.t, #scan.leaders), scan.leaders)
end

---------------------------------------------------------------------------
-- Q4: search permission tests
---------------------------------------------------------------------------
local function doSearch(how)
  local cats = C_LFGList.GetAvailableCategories and C_LFGList.GetAvailableCategories() or {}
  local cat = db.category or cats[1]
  if not cat then return out("no LFG categories available") end
  local acts = C_LFGList.GetAvailableActivities(cat)
  pendingSearch = { how = how, at = GetTime() }
  local ok, err = pcall(C_LFGList.Search, cat, 0, 0, nil, false, nil, acts)
  log("search-call", { how = how, ok = ok, err = err and tostring(err), category = cat, nActivities = #acts })
  db.searchTests[how] = db.searchTests[how] or { calls = 0, results = 0, blocked = 0, failed = 0 }
  db.searchTests[how].calls = db.searchTests[how].calls + 1
  if not ok then out("search error via " .. how .. ": " .. tostring(err)) end
end

---------------------------------------------------------------------------
-- Q2 + Q5: the hidden channel
---------------------------------------------------------------------------
local seq = 0
local function ping(tag)
  local idx = GetChannelName(CHANNEL)
  if not idx or idx == 0 then return out("not in channel yet") end
  seq = seq + 1
  local r = C_ChatInfo.SendAddonMessage(PREFIX, ("P^%s^%s^%d^%d^%s"):format(layer or "", layerMap or "", seq, now(), tag or ""), "CHANNEL", idx)
  db.sendResults[tostring(r)] = (db.sendResults[tostring(r)] or 0) + 1
end

local function burst(n)
  out("sending " .. n .. " messages as fast as possible...")
  for i = 1, n do ping("burst" .. i) end
  log("burst", { n = n })
end

local function onAddonMessage(prefix, msg, channel, sender)
  if prefix ~= PREFIX then return end
  sender = Ambiguate(sender, "none")
  if sender == me then return end
  local f = { strsplit("^", msg) }
  if f[1] == "P" then
    local p = db.peers[sender] or { pings = 0, layers = {} }
    p.pings = p.pings + 1
    p.lastLayer, p.lastSeen, p.channel = f[2], now(), channel
    if f[2] ~= "" then p.layers[f[2]] = true end
    db.peers[sender] = p
    local cross = f[2] ~= "" and layer and tonumber(f[2]) ~= layer
    if cross and not db.crossLayerPing then
      db.crossLayerPing = { from = sender, theirLayer = f[2], ourLayer = layer, t = now() }
      out("|cff33ff99cross-layer ping received|r from " .. sender .. " (layer " .. f[2] .. ", you " .. layer .. ") - the channel crosses layers!")
    end
    if (f[6] or ""):find("^burst") then db.burstReceived[sender] = (db.burstReceived[sender] or 0) + 1 end
  elseif f[1] == "S" then
    local key = sender .. "@" .. f[3]
    local ps = db.peerScans[key] or { by = sender, layer = f[2], t = tonumber(f[3]), n = tonumber(f[4]), leaders = {} }
    for name in (f[5] or ""):gmatch("[^,]+") do ps.leaders[#ps.leaders + 1] = name end
    db.peerScans[key] = ps
  end
end

---------------------------------------------------------------------------
-- Report
---------------------------------------------------------------------------
local function overlap()
  -- pair our scans with peer scans from a different layer taken within 3 minutes
  local pairs_, shared, union = 0, 0, 0
  for _, mine in ipairs(db.scans) do
    local set = {}
    for _, l in ipairs(mine.leaders) do set[l] = true end
    for _, theirs in pairs(db.peerScans) do
      if mine.layer and theirs.layer ~= "" and tonumber(theirs.layer) ~= mine.layer
         and math.abs((theirs.t or 0) - mine.t) <= 180 and #theirs.leaders > 0 and #mine.leaders > 0 then
        pairs_ = pairs_ + 1
        local u = {}
        for l in pairs(set) do u[l] = true end
        for _, l in ipairs(theirs.leaders) do if set[l] then shared = shared + 1 end u[l] = true end
        for _ in pairs(u) do union = union + 1 end
      end
    end
  end
  return pairs_, shared, union
end

local function report()
  out("---- report ----")
  local s = db.layerStats
  local n = 0 for _ in pairs(s.distinct) do n = n + 1 end
  out(("Q6 layer: current %s, %d samples, %d distinct zone ids seen"):format(tostring(layer), s.samples, n))
  local peers, crossPeers = 0, 0
  for _, p in pairs(db.peers) do
    peers = peers + 1
    if p.lastLayer ~= "" and layer and tonumber(p.lastLayer) ~= layer then crossPeers = crossPeers + 1 end
  end
  out(("Q2 channel: %d probe users heard, %d on another layer -> %s"):format(peers, crossPeers,
    db.crossLayerPing and "|cff33ff99crosses layers|r" or (peers == 0 and "need a second probe user" or "no cross-layer proof yet")))
  local p, shared, union = overlap()
  if p == 0 then
    out("Q1 tool: no scan pairs from different layers within 3 min yet (scan at the same time as a friend on another layer)")
  else
    local pct = union > 0 and math.floor(100 * shared / union) or 0
    out(("Q1 tool: %d cross-layer scan pairs, %d%% leaders shared -> %s"):format(p, pct,
      pct < 15 and "|cff33ff99tool looks layer-limited (LayerLink is useful)|r"
      or pct > 70 and "|cffff5555tool looks realm-wide (layers already see each other)|r" or "mixed - collect more"))
  end
  local last = db.scans[#db.scans]
  if last and last.results[1] then
    local r = last.results[1]
    out(("Q3 read: leader=%s members=%s name=%s comment=%s"):format(tostring(r.leader), tostring(r.numMembers), r.name, r.comment))
  else
    out("Q3 read: no scans yet - open the LFG tool and hit refresh, or /probe scan")
  end
  for how, t in pairs(db.searchTests) do
    out(("Q4 search via %s: %d calls, %d result sets, %d blocked, %d failed"):format(how, t.calls, t.results, t.blocked, t.failed))
  end
  local bursts = {}
  for who, c in pairs(db.burstReceived) do bursts[#bursts + 1] = who .. "=" .. c end
  local sends = {}
  for r, c in pairs(db.sendResults) do sends[#sends + 1] = r .. "x" .. c end
  out("Q5 send results: " .. (#sends > 0 and table.concat(sends, " ") or "none") ..
      " | burst msgs received from peers: " .. (#bursts > 0 and table.concat(bursts, " ") or "none"))
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
  "/probe scan - search the LFG tool now (tests slash-command permission)",
  "/probe button - show/hide a Scan button (tests click permission)",
  "/probe timerscan - try a search from a timer (expect 'blocked' - this is the test)",
  "/probe ping - announce yourself on the hidden channel",
  "/probe burst [n] - send n messages fast to measure throttling (default 20)",
  "/probe report - summarize findings     /probe reset - wipe collected data",
}

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local f = CreateFrame("Frame")
local H = {}

function H.ADDON_LOADED(name)
  if name ~= ADDON then return end
  LayerProbeDB = LayerProbeDB or {}
  db = LayerProbeDB
  for _, k in ipairs({ "log", "scans", "activities", "rawSamples", "peers", "peerScans", "searchTests",
                       "sendResults", "burstReceived" }) do db[k] = db[k] or {} end
  db.layerStats = db.layerStats or { samples = 0, distinct = {} }
  db.client = { build = select(4, GetBuildInfo()), version = GetBuildInfo(), realm = GetRealmName() }
  C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
  hooksecurefunc(C_LFGList, "Search", function(cat, _, _, _, _, _, acts)
    log("search-hook", { category = cat, nActivities = acts and #acts or 0, ours = pendingSearch ~= nil })
  end)
  makeButton()
  SLASH_LAYERPROBE1 = "/probe"
  SlashCmdList.LAYERPROBE = function(input)
    local cmd, arg = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "scan" then doSearch("slash")
    elseif cmd == "button" then button:SetShown(not button:IsShown())
    elseif cmd == "timerscan" then out("searching from a timer in 1s..."); C_Timer.After(1, function() doSearch("timer") end)
    elseif cmd == "ping" then ping("manual"); out("ping sent")
    elseif cmd == "burst" then burst(tonumber(arg) or 20)
    elseif cmd == "report" then report()
    elseif cmd == "reset" then LayerProbeDB = nil; ReloadUI()
    else for _, l in ipairs(HELP) do out(l) end end
  end
end

function H.PLAYER_LOGIN()
  me = UnitName("player")
  C_Timer.NewTicker(60, function() ping("auto") end)
  out("loaded - /probe for commands. Target an NPC so your layer is known.")
end

function H.PLAYER_ENTERING_WORLD()
  layer = nil
  C_Timer.After(5, function()
    if GetChannelName(CHANNEL) == 0 then JoinTemporaryChannel(CHANNEL) end
    for i = 1, NUM_CHAT_WINDOWS do local cf = _G["ChatFrame" .. i]; if cf then ChatFrame_RemoveChannel(cf, CHANNEL) end end
    C_Timer.After(2, function() ping("login") end)
  end)
end

function H.PLAYER_TARGET_CHANGED() sample("target") end
function H.UPDATE_MOUSEOVER_UNIT() sample("mouseover") end
function H.NAME_PLATE_UNIT_ADDED(unit) sample(unit) end
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
  local info = C_LFGList.GetSearchResultInfo(id)
  if info and info.isDelisted then log("delisted", { leader = info.leaderName, age = info.age }) end
end

f:SetScript("OnEvent", function(_, event, ...) H[event](...) end)
for event in pairs(H) do pcall(f.RegisterEvent, f, event) end
