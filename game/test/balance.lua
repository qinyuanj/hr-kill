-- balance.lua — measure win rates and diagnostics across player counts.
--   lua test/balance.lua [gamesPerCount] [seed]
-- Prints a table of win rates by player count plus boss-team win rate, average
-- turns, and average boss lifespan. Used to tune AI/HP balance empirically.
package.path = "./?.lua;" .. package.path

local Engine = require("src.engine")
local AI     = require("src.ai")
local Chars  = require("src.characters")

local gamesPer = tonumber(arg and arg[1]) or 400
local baseSeed = tonumber(arg and arg[2]) or 1

local function playOne(seed, players)
    local game = Engine.new({
        numPlayers = players, humanSeat = nil, seed = seed, characters = Chars.list,
    })
    game:start()
    local answer = nil
    local steps = 0
    while true do
        steps = steps + 1
        if steps > 200000 then return { winner = "TIMEOUT", turns = game.turnCount } end
        local req = game:resume(answer)
        if req == nil then break end
        answer = AI.answer(game, req)
    end
    -- boss-team win = boss faction victory
    local bossTeam = (game.winner == "boss")
    return { winner = game.winner, turns = game.turnCount, bossTeam = bossTeam }
end

print(string.format("balance: %d games per count, baseSeed=%d", gamesPer, baseSeed))
print(string.format("%-4s | %6s %6s %6s %6s | %8s | %6s",
    "N", "boss", "rebel", "spy", "draw", "bossTeam", "avgT"))
print(string.rep("-", 62))

local grand = { boss = 0, rebel = 0, spy = 0 }
local grandN = 0
for _, n in ipairs({ 4, 5, 6, 7, 8 }) do
    local tally = { boss = 0, rebel = 0, spy = 0, draw = 0, TIMEOUT = 0 }
    local turns = 0
    for i = 1, gamesPer do
        local seed = baseSeed + i * 7919 + n * 131
        local res = playOne(seed, n)
        tally[res.winner] = (tally[res.winner] or 0) + 1
        turns = turns + res.turns
    end
    local pc = function(k) return 100 * tally[k] / gamesPer end
    print(string.format("%-4d | %5.1f%% %5.1f%% %5.1f%% %5.1f%% | %7.1f%% | %6.1f",
        n, pc("boss"), pc("rebel"), pc("spy"), pc("draw"), pc("boss"), turns / gamesPer))
    grand.boss = grand.boss + tally.boss
    grand.rebel = grand.rebel + tally.rebel
    grand.spy = grand.spy + tally.spy
    grandN = grandN + gamesPer
end
print(string.rep("-", 62))
print(string.format("ALL  | boss %.1f%%  rebel %.1f%%  spy %.1f%%  (n=%d)",
    100 * grand.boss / grandN, 100 * grand.rebel / grandN, 100 * grand.spy / grandN, grandN))
