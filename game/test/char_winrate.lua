-- char_winrate.lua — per-CHARACTER win-rate analysis (kit power, isolated from identity).
--
-- All balance tuning so far targets per-IDENTITY rates (boss/rebel/spy ~47%). This asks a
-- different question: are individual character KITS balanced? Characters and identities are
-- assigned independently, so over many games every character sees the same identity mix —
-- therefore a character whose win rate deviates from the cohort mean has an over/under-powered
-- kit, not just a lucky identity draw. We also break flagged outliers down by identity.
--
--   lua test/char_winrate.lua [gamesPerCount] [baseSeed]
package.path = "./?.lua;" .. package.path

local Engine = require("src.engine")
local AI     = require("src.ai")
local Chars  = require("src.characters")

local gamesPer = tonumber(arg and arg[1]) or 1500
local baseSeed = tonumber(arg and arg[2]) or 1
local COUNTS   = { 4, 5, 6, 7, 8 }

-- per-character tally: name -> { g = totalGames, w = totalWins, byId = { id -> {g,w} } }
local C = {}
local function rec(name, identity, won)
    local c = C[name]
    if not c then c = { g = 0, w = 0, byId = {} }; C[name] = c end
    c.g = c.g + 1; if won then c.w = c.w + 1 end
    local b = c.byId[identity]
    if not b then b = { g = 0, w = 0 }; c.byId[identity] = b end
    b.g = b.g + 1; if won then b.w = b.w + 1 end
end

local function playOne(seed, players)
    local game = Engine.new({ numPlayers = players, humanSeat = nil, seed = seed, characters = Chars.list })
    game:start()
    local answer, steps = nil, 0
    while true do
        steps = steps + 1
        if steps > 200000 then return nil end          -- timeout, discard
        local req = game:resume(answer)
        if req == nil then break end
        answer = AI.answer(game, req)
    end
    return game
end

local decided, skipped = 0, 0
for _, players in ipairs(COUNTS) do
    for i = 1, gamesPer do
        local seed = baseSeed + i * 7919 + players * 104729
        local ok, game = pcall(playOne, seed, players)
        if ok and game and game.winner and game.winner ~= "draw" and game.winner ~= "TIMEOUT" then
            decided = decided + 1
            for _, p in ipairs(game.players) do
                if p.char and p.char.name then
                    rec(p.char.name, p.identity, game:identityWon(p.identity))
                end
            end
        else
            skipped = skipped + 1
        end
    end
end

-- cohort stats
local names = {}
for n in pairs(C) do names[#names + 1] = n end
table.sort(names, function(a, b) return (C[a].w / C[a].g) > (C[b].w / C[b].g) end)

local sum, sumsq, k = 0, 0, 0
for _, n in ipairs(names) do
    local r = C[n].w / C[n].g
    sum = sum + r; sumsq = sumsq + r * r; k = k + 1
end
local mean = sum / k
local sd = math.sqrt(math.max(0, sumsq / k - mean * mean))

print(string.format("==== per-character win rate (%d decided games, %d chars) ====", decided, k))
print(string.format("cohort mean=%.1f%%  sd=%.1f%%   (flag = |z|>=2.0)\n", 100 * mean, 100 * sd))
print(string.format("%-22s %6s %7s %6s   %s", "character", "games", "win%", "z", "flag"))
for _, n in ipairs(names) do
    local c = C[n]
    local r = c.w / c.g
    local z = sd > 0 and (r - mean) / sd or 0
    local flag = (math.abs(z) >= 2.0) and (z > 0 and "<< STRONG" or "<< WEAK") or ""
    print(string.format("%-20s %7d %6.1f%% %+6.2f   %s", n, c.g, 100 * r, z, flag))
end

-- identity breakdown for flagged outliers
print("\n---- identity breakdown for flagged characters ----")
local order = { "boss", "loyal", "rebel", "spy" }
local anyFlag = false
for _, n in ipairs(names) do
    local c = C[n]
    local z = sd > 0 and ((c.w / c.g) - mean) / sd or 0
    if math.abs(z) >= 2.0 then
        anyFlag = true
        local parts = {}
        for _, id in ipairs(order) do
            local b = c.byId[id]
            if b and b.g > 0 then parts[#parts + 1] = string.format("%s %.0f%%(n=%d)", id, 100 * b.w / b.g, b.g) end
        end
        print(string.format("  %-18s  %s", n, table.concat(parts, "  ")))
    end
end
if not anyFlag then print("  (none — all characters within 2 sd of the cohort mean)") end
print(string.format("\nskipped (draw/timeout): %d", skipped))
