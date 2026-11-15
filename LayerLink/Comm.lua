-- Network layer: a hidden realm-wide custom channel carrying compact addon messages.
-- Encode/Decode are pure and unit-tested; the rest uses the WoW API.
local _, ns = ...
local C = {}
ns.Comm = C

C.PREFIX = "LayerLink"
C.CHANNEL = "LayerLinkNet"
C.VERSION = "2"
C.SEND_INTERVAL = 1.0    -- seconds between our outgoing messages
C.MAX_QUEUE = 80         -- one full scan of a busy layer fits
C.INBOUND_PER_MIN = 90   -- per-sender cap before we start ignoring them
C.SEP = "^"

-- Messages (fields joined by "^", always starting with the version):
--   L  listing   leader, dungeons(k1,k2), type(G|S), size, tanks, healers, dps,
--                solo roles(THD), level, class, layer, age, listedAge
--   X  delist    leader                 (only accepted from the leader)
--   G  gone      leader, layer          (a complete scan on that layer no longer shows it)
--   S  sync request                     (someone just joined the network)
--   R  sync reply start                 (someone is answering; others stand down)
-- Listing titles/comments are protected strings in the LFG API, so they are never sent.

local function num(v) return v and tostring(math.floor(v)) or "" end

function C.Encode(e, now)
  return table.concat({
    C.VERSION, "L", e.leader, table.concat(e.dungeons, ","), e.type or "G",
    num(e.size), num(e.t), num(e.h), num(e.d), e.roles or "", num(e.level), e.class or "",
    ns.Board.LayerOf(e), num(math.max(0, now - e.lastSeen)),
    e.listedAt and num(math.max(0, now - e.listedAt)) or "",
  }, C.SEP)
end

function C.EncodeDelist(leader) return table.concat({ C.VERSION, "X", leader }, C.SEP) end
function C.EncodeGone(leader, layer) return table.concat({ C.VERSION, "G", leader, layer }, C.SEP) end
function C.EncodeSync() return C.VERSION .. C.SEP .. "S" end
function C.EncodeSyncReply() return C.VERSION .. C.SEP .. "R" end

local function validName(n) return n and #n <= 24 and n:match("^[^%s%d%p][^%s%^,]*$") ~= nil end
local function optNum(v, max)
  if v == "" then return true, nil end
  local n = tonumber(v)
  if not v:match("^%d+$") or n > max then return false end
  return true, n
end

-- Returns a validated message table, or nil for anything malformed.
function C.Decode(msg)
  if type(msg) ~= "string" or #msg > 255 then return nil end
  local f = {}
  for field in (msg .. C.SEP):gmatch("([^%^]*)%^") do f[#f + 1] = field end
  if f[1] ~= C.VERSION then return nil end
  local kind = f[2]
  if kind == "S" or kind == "R" then return { kind = kind } end
  if not validName(f[3]) then return nil end
  if kind == "X" then return { kind = "X", leader = f[3] } end
  if kind == "G" then
    if not (f[4] and f[4]:match("^%d+$")) then return nil end
    return { kind = "G", leader = f[3], layer = f[4] }
  end
  if kind ~= "L" or #f ~= 15 then return nil end
  local o = { kind = "L", leader = f[3], dungeons = {} }
  for k in f[4]:gmatch("[^,]+") do
    if not ns.DungeonByKey[k] or #o.dungeons >= 4 then return nil end
    o.dungeons[#o.dungeons + 1] = k
  end
  if #o.dungeons == 0 then return nil end
  if f[5] ~= "G" and f[5] ~= "S" then return nil end
  o.type = f[5]
  local ok
  for i, k in ipairs({ "size", "t", "h", "d" }) do
    ok, o[k] = optNum(f[5 + i], 40); if not ok then return nil end
  end
  if not f[10]:match("^T?H?D?$") then return nil end
  o.roles = f[10]
  ok, o.level = optNum(f[11], 100); if not ok then return nil end
  if f[12] ~= "" and not f[12]:match("^[A-Z]+$") then return nil end
  o.class = f[12] ~= "" and f[12] or nil
  o.layer = f[13]
  if o.layer ~= "" and o.layer ~= "?" and not o.layer:match("^%d+$") then return nil end
  ok, o.age = optNum(f[14], 86400); if not ok or not o.age then return nil end
  ok, o.listedAge = optNum(f[15], 864000); if not ok then return nil end
  return o
end

---------------------------------------------------------------------------
-- WoW plumbing
---------------------------------------------------------------------------
C.queue, C.lastSend, C.inbound = {}, 0, {}

function C:Init()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(C.PREFIX)
  end
end

function C:ChannelIndex()
  local id = GetChannelName(C.CHANNEL)
  if id and id > 0 then return id end
end

function C:JoinChannel()
  if not self:ChannelIndex() then JoinTemporaryChannel(C.CHANNEL) end
  -- keep the plumbing out of every chat window
  for i = 1, (NUM_CHAT_WINDOWS or 10) do
    local cf = _G["ChatFrame" .. i]
    if cf then ChatFrame_RemoveChannel(cf, C.CHANNEL) end
  end
end

-- item = { entry = e } for listings (encoded at send time so the age is fresh)
--      or { raw = "..." } for pre-encoded messages. `delay` adds jitter so the
-- many scouts who saw the same chat line don't all transmit at once.
function C:Queue(item, now, delay)
  item.queuedAt = now
  item.notBefore = now + (delay or 0)
  if #self.queue >= C.MAX_QUEUE then table.remove(self.queue, 1) end
  self.queue[#self.queue + 1] = item
end

-- Someone else already reported this listing from our layer while ours sat in the queue.
local function redundant(item, myLayer)
  local e = item.entry
  if not e or item.force then return false end
  local heard = e.netLayers[myLayer ~= "" and myLayer or "-"] or e.netLayers["?"]
  return heard and heard >= item.queuedAt
end

function C:Pump(now, myLayer)
  if now - self.lastSend < C.SEND_INTERVAL then return end
  local idx = self:ChannelIndex()
  if not idx then return end
  for i, item in ipairs(self.queue) do
    if now >= item.notBefore then
      table.remove(self.queue, i)
      if not redundant(item, myLayer) then
        local msg = item.raw or C.Encode(item.entry, now)
        C_ChatInfo.SendAddonMessage(C.PREFIX, msg, "CHANNEL", idx)
        self.lastSend = now
      end
      return
    end
  end
end

function C:Allow(sender, now)
  local b = self.inbound[sender]
  if not b or now - b.start > 60 then b = { start = now, n = 0 }; self.inbound[sender] = b end
  b.n = b.n + 1
  return b.n <= C.INBOUND_PER_MIN
end
