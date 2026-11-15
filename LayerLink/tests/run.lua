-- Run from the LayerLink folder:  lua5.1 tests/run.lua
local ns = {}
for _, file in ipairs({ "Dungeons.lua", "Board.lua", "Comm.lua" }) do
  assert(loadfile(file))("LayerLink", ns)
end

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local B, C = ns.Board, ns.Comm

-- Activity names from the LFG tool -----------------------------------------
for name, key in pairs({
  ["Scarlet Monastery - Library"] = "SMLIB", ["Dire Maul - East"] = "DME", ["Dire Maul - North"] = "DMN",
  ["Blackrock Depths"] = "BRD", ["Stratholme - Undead District"] = "STRATUD", ["Stratholme - Live"] = "STRATLIVE",
  ["The Deadmines"] = "VC", ["Upper Blackrock Spire"] = "UBRS", ["Molten Core"] = "MC", ["Zul'Gurub"] = "ZG",
  ["Onyxia's Lair"] = "ONY", ["Strat UD"] = "STRATUD", ["brd"] = "BRD",
  ["Scarlet Armory"] = "SMARM", ["Scarlet Graveyard"] = "SMGY", ["Scarlet Library"] = "SMLIB",
  ["Scarlet Cathedral"] = "SMCATH", ["Scarlet Monastery"] = "SM", ["Dire Maul - Warpwood Quarter"] = "DME",
  ["Dire Maul - Capital Gardens"] = "DMW", ["Dire Maul - Gordok Commons"] = "DMN", ["Dire Maul"] = "DIREMAUL",
  ["Stratholme - Service Entrance"] = "STRATUD", ["Stratholme - Main Gate"] = "STRATLIVE", ["Stratholme"] = "STRAT",
  ["Blackrock Spire - Lower"] = "LBRS", ["The Temple of Atal'Hakkar"] = "ST", ["Ruins of Ahn'Qiraj"] = "AQ20",
  ["Ahn'Qiraj Temple"] = "AQ40",
}) do
  test("activity " .. name, function() eq(ns.MatchDungeon(name), key) end)
end
test("unknown activity", function() eq(ns.MatchDungeon("Questing in Feralas"), nil) end)

-- Board ---------------------------------------------------------------------
local function group(leader, layer, extra)
  local o = { leader = leader, dungeons = { "BRD" }, type = "G", size = 3, t = 1, h = 0, d = 2, layer = layer, scout = "S1" }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

test("merges reports and tracks scouts", function()
  local b = B.New()
  local _, new1 = b:Upsert(group("Thrall", "101"), 100)
  local e, new2 = b:Upsert(group("thrall", "101", { scout = "S2", size = 4, d = 3, age = 5 }), 110)
  eq(new1, true); eq(new2, false); eq(e.scoutCount, 2); eq(e.size, 4); eq(B.LayerOf(e), "101")
end)

test("older report does not overwrite newer fields", function()
  local b = B.New()
  b:Upsert(group("Jaina", "1", { size = 4 }), 100)
  local e = b:Upsert(group("Jaina", "1", { size = 2, age = 30 }), 100)
  eq(e.size, 4); eq(e.lastSeen, 100)
end)

test("listed time survives relays", function()
  local b = B.New()
  local e = b:Upsert(group("A", "1", { listedAge = 120, age = 10 }), 1000)
  eq(e.listedAt, 1000 - 10 - 120)
end)

test("seen from two layers resolves to any", function()
  local b = B.New()
  b:Upsert(group("X", "101"), 0)
  local e = b:Upsert(group("X", "202", { scout = "S2" }), 0)
  eq(B.LayerOf(e), "?"); eq(B.Label("?", {}), "any")
end)

test("needs: 5-man with full role info", function()
  local n = B.Needs({ dungeons = { "BRD" }, size = 3, t = 1, h = 0, d = 2 })
  eq(n.known, true); eq(n.T, false); eq(n.H, true); eq(n.D, 1); eq(n.open, 2)
end)
test("needs: unassigned roles only give open slots", function()
  local n = B.Needs({ dungeons = { "BRD" }, size = 3, t = 0, h = 0, d = 0 })
  eq(n.known, false); eq(n.open, 2)
  eq(B.Wants({ type = "G", dungeons = { "BRD" }, size = 3, t = 0, h = 0, d = 0 }, "H"), true)
end)
test("needs: raid size", function()
  eq(B.Needs({ dungeons = { "ZG" }, size = 12 }).open, 8)
  eq(B.Needs({ dungeons = { "MC" }, size = 40 }).open, 0)
end)
test("wants: solo roles and full groups", function()
  eq(B.Wants({ type = "S", roles = "TH" }, "H"), true)
  eq(B.Wants({ type = "S", roles = "TH" }, "D"), false)
  eq(B.Wants({ type = "G", dungeons = { "BRD" }, size = 5, t = 1, h = 1, d = 3 }, "D"), false)
end)

test("snapshot removes only missing listings from the same layer and dungeons", function()
  local b = B.New()
  b:Upsert(group("Gone", "7"), 0)                                        -- same layer, covered: removed
  b:Upsert(group("Still", "7"), 0)                                       -- seen in scan: kept
  b:Upsert(group("Other", "8"), 0)                                       -- other layer: kept
  b:Upsert(group("Raid", "7", { dungeons = { "MC" } }), 0)               -- not covered: kept
  b:Upsert(group("Own", "7", { source = "A" }), 0)                       -- leader vouched recently: kept
  local removed = b:ApplySnapshot("7", { BRD = true }, { still = true }, 30)
  eq(#removed, 1); eq(removed[1], "Gone")
  eq(#b:List(30), 4)
  eq(#b:ApplySnapshot("7", { BRD = true }, {}, 30 + B.OWN_GRACE + 1), 2) -- grace over: Still + Own go
end)

test("gone report needs matching layer", function()
  local b = B.New()
  b:Upsert(group("A", "7"), 0)
  eq(b:RemoveGone("A", "8", 0), false); eq(b:RemoveGone("A", "7", 0), true)
  b:Upsert(group("M", "7"), 0); b:Upsert(group("M", "8", { scout = "S2" }), 0)
  eq(b:RemoveGone("M", "7", 0), false) -- multi-layer listing: one layer can't vouch it's gone
end)

test("labels, summary, list, prune, freshest", function()
  local b = B.New()
  b:Upsert(group("A", "500"), 0)
  b:Upsert(group("C", "90", { dungeons = { "LBRS" } }), 10)
  b:Upsert(group("D", "500", { type = "S", size = 1, roles = "H" }), 20)
  local ids = b:LayerIds("777")
  eq(#ids, 3); eq(B.Label("90", ids), "L1"); eq(B.Label("500", ids), "L2"); eq(B.Label("777", ids), "L3")
  eq(b:Summary(20)["500"].groups, 1); eq(b:Summary(20)["500"].solo, 1)
  eq(b:List(20)[1].leader, "D"); eq(#b:List(20, "lower blackrock"), 1); eq(#b:List(20, nil, "S"), 1)
  eq(#b:Freshest(20, 15, 10), 2); eq(#b:Freshest(20, 100, 1), 1)
  b:Prune(605); eq(#b:List(605), 2)
end)

-- Wire format ----------------------------------------------------------------
test("listing roundtrip", function()
  local b = B.New()
  local e = b:Upsert(group("Sylvanas", "4242", { dungeons = { "STRATUD", "STRATLIVE" }, level = 60,
                                                 class = "PRIEST", listedAge = 300 }), 100)
  local msg = C.Encode(e, 112)
  assert(#msg <= 255)
  local o = assert(C.Decode(msg), "decode failed: " .. msg)
  eq(o.leader, "Sylvanas"); eq(o.dungeons[2], "STRATLIVE"); eq(o.type, "G"); eq(o.size, 3)
  eq(o.t, 1); eq(o.h, 0); eq(o.d, 2); eq(o.level, 60); eq(o.class, "PRIEST")
  eq(o.layer, "4242"); eq(o.age, 12); eq(o.listedAge, 312)
end)

test("solo roundtrip with unknowns", function()
  local b = B.New()
  local e = b:Upsert({ leader = "Bob", dungeons = { "ZF" }, type = "S", size = 1, roles = "TD" }, 0)
  local o = assert(C.Decode(C.Encode(e, 0)))
  eq(o.roles, "TD"); eq(o.layer, ""); eq(o.level, nil); eq(o.listedAge, nil)
end)

test("control messages", function()
  eq(C.Decode(C.EncodeDelist("Arthas")).kind, "X")
  local g = C.Decode(C.EncodeGone("Arthas", "55")); eq(g.kind, "G"); eq(g.layer, "55")
  eq(C.Decode(C.EncodeSync()).kind, "S"); eq(C.Decode(C.EncodeSyncReply()).kind, "R")
end)

test("decode rejects garbage", function()
  local good = "2^L^A^BRD^G^3^1^0^2^^60^PRIEST^7^5^"
  assert(C.Decode(good), "baseline should decode")
  for _, m in ipairs({ "", "hello", (good:gsub("^2", "1")), (good:gsub("BRD", "NOPE")),
      (good:gsub("%^G%^", "^Q^")), (good:gsub("%^60%^", "^999^")), (good:gsub("PRIEST", "priest")),
      (good:gsub("%^7%^", "^x7^")), (good:gsub("%^5%^$", "^-5^")), (good:gsub("%^A%^", "^^")),
      "2^L^A^BRD,LBRS,UBRS,MC,ZG^G^3^1^0^2^^60^PRIEST^7^5^", "2^G^A^", "2^G^A^abc",
      good .. "^extra", string.rep("a", 300) }) do
    eq(C.Decode(m), nil, "accepted " .. m)
  end
end)

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
