-- The board window: layer radar, scan button, group/solo tabs, search box, and a
-- scrolling list of LFG-tool listings from every layer.
local _, ns = ...
local UI = {}
ns.UI = UI

local ROWS, ROW_H = 14, 20
local frame, radar, search, status, scanBtn
local rows, list, offset, tab = {}, {}, 0, nil -- tab: nil = all, "G" = groups, "S" = solo players

local COLS = { -- x offset, width
  layer = { 0, 34 }, dungeon = { 36, 130 }, size = { 168, 44 }, roles = { 214, 70 },
  leader = { 286, 100 }, level = { 388, 70 }, listed = { 460, 40 }, upd = { 502, 44 },
}

local ROLE_TEXT = { T = "|cff6fa8dcT|r", H = "|cff6aa84fH|r", D = "|cffe06666D|r" }

local function rolesText(e)
  if e.type == "S" then
    local r = ""
    for c in (e.roles or ""):gmatch(".") do r = r .. ROLE_TEXT[c] end
    return r ~= "" and r or "|cffbbbbbb?|r"
  end
  local n = ns.Board.Needs(e)
  if n.open == 0 then return "|cffbbbbbbfull|r" end
  if not n.known then return "|cffbbbbbb" .. n.open .. " open|r" end
  local r = (n.T and ROLE_TEXT.T or "") .. (n.H and ROLE_TEXT.H or "")
  if n.D > 0 then r = r .. ROLE_TEXT.D .. (n.D > 1 and ("x" .. n.D) or "") end
  return r
end

local function ageText(sec)
  if not sec then return "" end
  sec = math.max(0, math.floor(sec))
  if sec < 60 then return sec .. "s" end
  if sec < 3600 then return math.floor(sec / 60) .. "m" end
  return math.floor(sec / 3600) .. "h"
end

local function classText(e)
  local color = e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
  local name = e.class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[e.class] or ""
  local s = (e.level and (e.level .. " ") or "") .. name
  if color then s = ("|c%s%s|r"):format(color.colorStr or "ffffffff", s) end
  return s
end

local function cell(parent, col, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("LEFT", parent, "LEFT", COLS[col][1], 0)
  fs:SetWidth(COLS[col][2])
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

local function showTooltip(row)
  local e = row.entry
  if not e then return end
  local ids = ns.board:LayerIds(ns.Layer:Get())
  local layer = ns.Board.LayerOf(e)
  local now = ns.Now()
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(table.concat(ns.Board.DungeonNames(e), ", "))
  GameTooltip:AddLine(e.type == "S" and (e.leader .. " - solo, can fill: " .. (e.roles ~= "" and e.roles or "?"))
    or ("%s's group - %d/%d, tanks %d, healers %d, dps %d"):format(e.leader, e.size or 0,
         ns.Board.Needs(e).max, e.t or 0, e.h or 0, e.d or 0), 1, 1, 1, true)
  GameTooltip:AddLine(" ")
  if layer == "?" then
    GameTooltip:AddLine("Seen in the tool from several layers.", .7, .7, .7)
  elseif layer ~= "" then
    local label = ns.Board.Label(layer, ids)
    GameTooltip:AddLine("Layer " .. label .. " (zone id " .. layer .. ")", .7, .7, .7)
    local mine = ns.Layer:Get()
    if mine ~= "" and mine ~= layer then
      GameTooltip:AddLine("Joining will likely move you to " .. label .. ".", 1, .82, 0, true)
    end
  end
  GameTooltip:AddLine(("Last confirmed %s ago by %d scout%s%s"):format(ageText(now - e.lastSeen), e.scoutCount,
    e.scoutCount == 1 and "" or "s", e.sources:find("A") and " (leader runs LayerLink)" or ""), .7, .7, .7, true)
  if e.leader ~= ns.me then GameTooltip:AddLine("Click to whisper " .. e.leader, .4, .8, 1) end
  GameTooltip:Show()
end

local function tabButton(label, value, x)
  local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  b:SetSize(62, 20)
  b:SetPoint("TOPLEFT", x, -54)
  b:SetText(label)
  b:SetScript("OnClick", function() tab = value; offset = 0; UI:Refresh() end)
  b.value = value
  return b
end

function UI:Build()
  frame = CreateFrame("Frame", "LayerLinkFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(580, 146 + ROWS * ROW_H)
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:Hide()
  tinsert(UISpecialFrames, "LayerLinkFrame") -- Esc closes it

  local title = frame.TitleText or frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if not frame.TitleText then title:SetPoint("TOP", 0, -5) end
  title:SetText("LayerLink - every layer's LFG tool")

  radar = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  radar:SetPoint("TOPLEFT", 14, -32)
  radar:SetJustifyH("LEFT")
  radar:SetWidth(400)

  scanBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  scanBtn:SetSize(140, 22)
  scanBtn:SetPoint("TOPRIGHT", -12, -28)
  scanBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  scanBtn:SetScript("OnClick", function(_, button)
    if button == "RightButton" then ns.CycleScanCategory() else ns.Scan() end
    UI:Refresh()
  end)
  scanBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Scan my layer")
    GameTooltip:AddLine("Searches the LFG tool on your layer and shares the results with every LayerLink user. Right-click to change category.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  scanBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local tabs = { tabButton("All", nil, 12), tabButton("Groups", "G", 76), tabButton("Solo", "S", 140) }
  frame.tabs = tabs

  search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  search:SetSize(140, 20)
  search:SetPoint("TOPRIGHT", -16, -54)
  search:SetAutoFocus(false)
  search:SetScript("OnTextChanged", function() offset = 0; UI:Refresh() end)
  search:SetScript("OnEscapePressed", search.ClearFocus)
  local hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("RIGHT", search, "LEFT", -8, 0)
  hint:SetText("Filter")

  local header = CreateFrame("Frame", nil, frame)
  header:SetSize(556, ROW_H)
  header:SetPoint("TOPLEFT", 14, -80)
  for col, label in pairs({ layer = "Layer", dungeon = "Activity", size = "Size", roles = "Needs/Can",
                            leader = "Leader", level = "Lvl Class", listed = "Listed", upd = "Updated" }) do
    local fs = cell(header, col)
    fs:SetFontObject("GameFontNormalSmall")
    fs:SetText(label)
  end

  for i = 1, ROWS do
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(556, ROW_H)
    row:SetPoint("TOPLEFT", 14, -80 - i * ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.cols = {}
    for col in pairs(COLS) do row.cols[col] = cell(row, col, (col == "listed" or col == "upd") and "RIGHT" or "LEFT") end
    row:SetScript("OnClick", function(self) ns.WhisperLeader(self.entry) end)
    row:SetScript("OnEnter", showTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rows[i] = row
  end

  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_, delta)
    offset = math.max(0, math.min(offset - delta * 3, math.max(0, #list - ROWS)))
    UI:Refresh()
  end)

  status = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  status:SetPoint("BOTTOMLEFT", 14, 12)
  status:SetPoint("BOTTOMRIGHT", -14, 12)
  status:SetJustifyH("LEFT")
end

function UI:Toggle()
  if not frame then self:Build() end
  frame:SetShown(not frame:IsShown())
  self:Refresh()
end

function UI:IsShown() return frame and frame:IsShown() end

function UI:Refresh()
  if not (frame and frame:IsShown()) then return end
  local now = ns.Now()
  local mine = ns.Layer:Get()
  local ids = ns.board:LayerIds(mine)
  list = ns.board:List(now, search:GetText(), tab)
  offset = math.min(offset, math.max(0, #list - ROWS))

  for _, b in ipairs(frame.tabs) do b:SetEnabled(b.value ~= tab) end
  local cooling = ns.lastScan and now - ns.lastScan < 15
  scanBtn:SetEnabled(not cooling)
  scanBtn:SetText(cooling and "Scanned" or ("Scan " .. ns.ScanCategoryName()))

  -- radar strip: groups/solo players per layer
  local counts, parts = ns.board:Summary(now), {}
  local function part(label, c) return ("%s |cffffffff%d|r|cffbbbbbb/%d|r"):format(label, c.groups, c.solo) end
  for _, l in ipairs(ids) do
    local label = ns.Board.Label(l, ids)
    if l == mine then label = "|cff33ff99" .. label .. "*|r" end
    parts[#parts + 1] = part(label, counts[l] or { groups = 0, solo = 0 })
  end
  if counts["?"] then parts[#parts + 1] = part("any", counts["?"]) end
  radar:SetText("Radar |cffbbbbbb(groups/solo)|r: " .. (#parts > 0 and table.concat(parts, "   ") or "|cffbbbbbbnothing yet - scan!|r"))

  for i, row in ipairs(rows) do
    local e = list[i + offset]
    row.entry = e
    if e then
      local layer = ns.Board.LayerOf(e)
      local label = ns.Board.Label(layer, ids)
      if layer ~= "" and layer == mine then label = "|cff33ff99" .. label .. "|r" end
      local names = ns.Board.DungeonNames(e)
      row.cols.layer:SetText(label)
      row.cols.dungeon:SetText(names[1] .. (#names > 1 and (" |cffbbbbbb+" .. (#names - 1) .. "|r") or ""))
      row.cols.size:SetText(e.type == "S" and "|cffbbbbbbsolo|r" or ((e.size or "?") .. "/" .. ns.Board.Needs(e).max))
      row.cols.roles:SetText(rolesText(e))
      row.cols.leader:SetText(e.leader == ns.me and ("|cff33ff99" .. e.leader .. "|r") or e.leader)
      row.cols.level:SetText(classText(e))
      row.cols.listed:SetText(ageText(e.listedAt and now - e.listedAt))
      row.cols.upd:SetText(ageText(now - e.lastSeen))
      row:Show()
    else
      row:Hide()
    end
  end

  status:SetText(("You: %s  |  %d listings  |  %s  |  click a row to whisper"):format(
    mine ~= "" and ns.Board.Label(mine, ids) or "layer unknown (target any NPC)",
    #list, ns.Comm:ChannelIndex() and "network connected" or "network connecting..."))
end
