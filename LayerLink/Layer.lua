-- Layer detection. Creature GUIDs look like
--   Creature-0-<serverID>-<instanceID>-<zoneUID>-<npcID>-<spawnUID>
-- and on layered realms <zoneUID> differs per layer, so any open-world NPC you
-- target, mouse over or see a nameplate for tells us which layer we are on.
local _, ns = ...
local L = { current = nil }
ns.Layer = L

function L:Sample(unit)
  if IsInInstance() then return end
  local guid = UnitGUID(unit)
  if not guid then return end
  local unitType, _, _, _, zoneUID = strsplit("-", guid)
  if unitType ~= "Creature" and unitType ~= "Vehicle" then return end
  local id = tonumber(zoneUID)
  if id and id > 0 and id ~= self.current then
    self.current = id
    if ns.OnLayerChanged then ns.OnLayerChanged() end
  end
end

-- Loading screens and group changes can move us to another layer.
function L:Invalidate() self.current = nil end

function L:Get() return self.current and tostring(self.current) or "" end
