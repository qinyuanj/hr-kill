-- determinism.lua — the engine must be a pure function of its seed.
-- Same seed => byte-identical game (full battle log + winner + final board). Determinism
-- underpins replay, debugging, and balance measurement; a prior fix already removed a
-- pairs()-order leak in death settlement. This soak guards against ANY new nondeterminism
-- (os.time / math.random / hash-order dependence) sneaking into GAMEPLAY. Pure lua, no love.
--   lua test/determinism.lua [gamesPerCount] [baseSeed]
package.path = "./?.lua;" .. package.path
local Engine = require("src.engine")
local AI     = require("src.ai")
local Chars  = require("src.characters")

local perCount = tonumber(arg and arg[1]) or 40
local baseSeed = tonumber(arg and arg[2]) or 1

local function playFull(seed, players)
    local g = Engine.new({ numPlayers = players, humanSeat = nil, seed = seed, characters = Chars.list })
    g:start()
    local answer, steps = nil, 0
    while true do
        steps = steps + 1
        if steps > 200000 then break end
        local req = g:resume(answer)
        if req == nil then break end
        answer = AI.answer(g, req)
    end
    local parts = { "winner=" .. tostring(g.winner), "turns=" .. tostring(g.turnCount) }
    for _, p in ipairs(g.players) do
        parts[#parts + 1] = string.format("seat%d:%s hp%d a%s h%d e%d",
            p.seat, p.name, p.hp, tostring(p.alive), #p.hand,
            (p.equip.weapon and 1 or 0) + (p.equip.armor and 1 or 0))
    end
    parts[#parts + 1] = "LOG:" .. table.concat(g.log, "|")
    return table.concat(parts, "\n")
end

local function firstDiff(a, b)
    local la, lb = {}, {}
    for line in a:gmatch("[^\n]+") do la[#la + 1] = line end
    for line in b:gmatch("[^\n]+") do lb[#lb + 1] = line end
    for k = 1, math.max(#la, #lb) do
        if la[k] ~= lb[k] then
            return string.format("line %d: [%s] vs [%s]", k, tostring(la[k]), tostring(lb[k]))
        end
    end
    return "(logs equal but strings differ?)"
end

local mismatches, games = 0, 0
for _, players in ipairs({ 4, 5, 6, 7, 8 }) do
    for i = 1, perCount do
        local seed = baseSeed + players * 100000 + i * 7919
        local a = playFull(seed, players)
        local b = playFull(seed, players)
        games = games + 1
        if a ~= b then
            mismatches = mismatches + 1
            print(string.format("  MISMATCH p=%d seed=%d  %s", players, seed, firstDiff(a, b)))
        end
    end
end

print(string.format("\n==== determinism: %d games x2 (%d table sizes), %d mismatches ====",
    games, 5, mismatches))
os.exit(mismatches == 0 and 0 or 1)
