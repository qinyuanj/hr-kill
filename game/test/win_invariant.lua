-- win_invariant.lua — soak test for the win-condition invariant across real all-AI games.
-- Complements test_fixes.lua (which pins specific death-cascade scenarios) by asserting, over
-- many full games at every table size, that the committed winner is always consistent with the
-- SETTLED board — the property the deferred checkWin guarantees. Any future change that lets a
-- winner be committed on a transient/incorrect state (like the cascade bugs of rounds 9–10) trips
-- this. Pure lua, no love.
--   lua test/win_invariant.lua [gamesPerCount] [baseSeed]
package.path = "./?.lua;" .. package.path
local Engine = require("src.engine")
local AI     = require("src.ai")
local Chars  = require("src.characters")

local perCount = tonumber(arg and arg[1]) or 400
local baseSeed = tonumber(arg and arg[2]) or 1

local function bossOf(g) for _, p in ipairs(g.players) do if p.identity == "boss" then return p end end end

local function playOne(seed, players)
    local g = Engine.new({ numPlayers = players, humanSeat = nil, seed = seed, characters = Chars.list })
    g:start()
    local answer, steps = nil, 0
    while true do
        steps = steps + 1
        if steps > 200000 then return "TIMEOUT", g end
        local req = g:resume(answer)
        if req == nil then break end
        answer = AI.answer(g, req)
    end
    return g.winner, g
end

local games, violations, timeouts = 0, 0, 0
local tally = {}
for _, players in ipairs({ 4, 5, 6, 7, 8 }) do
    for i = 1, perCount do
        local seed = baseSeed + players * 100000 + i * 7919
        local ok, w, g = pcall(playOne, seed, players)
        if not ok then
            violations = violations + 1
            print(string.format("  ERROR p=%d seed=%d: %s", players, seed, tostring(w)))
        elseif w == "TIMEOUT" then
            timeouts = timeouts + 1
            print(string.format("  TIMEOUT p=%d seed=%d", players, seed))
        elseif w then
            games = games + 1
            tally[w] = (tally[w] or 0) + 1
            local boss = bossOf(g)
            local survivors = {}
            for _, p in ipairs(g.players) do if p.alive then survivors[#survivors + 1] = p end end
            local bad = nil
            if w == "boss" and not boss.alive then
                bad = "winner=boss but boss is DEAD"
            elseif (w == "rebel" or w == "spy") and boss.alive then
                bad = "winner=" .. w .. " but boss is ALIVE"
            elseif w == "spy" and not (#survivors == 1 and survivors[1].identity == "spy") then
                bad = "winner=spy but the spy is not the sole survivor (survivors=" .. #survivors .. ")"
            end
            if bad then
                violations = violations + 1
                print(string.format("  VIOLATION p=%d seed=%d: %s", players, seed, bad))
            end
        else
            -- w == nil: a finished game must always have a winner
            violations = violations + 1
            print(string.format("  VIOLATION p=%d seed=%d: game ended with NO winner", players, seed))
        end
    end
end

print(string.format("\n==== win_invariant: %d games, %d violations, %d timeouts ====",
    games, violations, timeouts))
local order = { "boss", "rebel", "spy" }
local parts = {}
for _, k in ipairs(order) do parts[#parts + 1] = string.format("%s %d", k, tally[k] or 0) end
print("   winners: " .. table.concat(parts, " / "))
os.exit((violations == 0 and timeouts == 0) and 0 or 1)
