-- headless.lua — run all-AI games to completion to validate the engine without love2d.
--   lua headless.lua [numGames] [numPlayers] [seed] [--verbose]
package.path = "./?.lua;" .. package.path

local Engine = require("src.engine")
local AI     = require("src.ai")
local Chars  = require("src.characters")

local numGames   = tonumber(arg and arg[1]) or 50
local numPlayers = tonumber(arg and arg[2]) or 6
local baseSeed   = tonumber(arg and arg[3]) or 1
local verbose    = false
for _, a in ipairs(arg or {}) do if a == "--verbose" or a == "-v" then verbose = true end end

local function playOne(seed, players)
    local game = Engine.new({
        numPlayers = players,
        humanSeat = nil,           -- all AI
        seed = seed,
        characters = Chars.list,
    })
    game:start()

    -- card-conservation invariant: every physical card must always be somewhere.
    local function totalCards(g)
        local n = #g.deck + #g.discard
        for _, p in ipairs(g.players) do
            n = n + #p.hand + #p.delayed
            for _, slot in ipairs({ "weapon", "armor", "plusHorse", "minusHorse", "treasure" }) do
                if p.equip[slot] then n = n + 1 end
            end
        end
        return n
    end
    local EXPECTED = totalCards(game)   -- 108 for the standard deck

    local answer = nil
    local steps = 0
    while true do
        steps = steps + 1
        if steps > 200000 then
            return { winner = "TIMEOUT", turns = game.turnCount, steps = steps, log = game.log }
        end
        local req = game:resume(answer)
        -- Only assert at clean boundaries: a top-level play action, or game end.
        -- Mid-skill asks may legitimately hold cards "in flight" in local variables,
        -- and a player can be transiently alive-with-hp<=0 mid dying-cascade — neither
        -- state coincides with a playAction yield or game end.
        if req == nil or req.kind == "playAction" then
            local tot = totalCards(game)
            if tot ~= EXPECTED then
                error(string.format("card conservation broken: %d != %d (step %d, turn %d)",
                    tot, EXPECTED, steps, game.turnCount))
            end
            -- HP-bounds invariant: the heal-cap + settled dying-cascade guarantee that at any
            -- clean boundary every ALIVE player has 1<=hp<=maxHp and every DEAD player has hp<=0.
            for _, p in ipairs(game.players) do
                if p.alive and not (p.hp >= 1 and p.hp <= p.maxHp) then
                    error(string.format("hp bounds broken: %s alive hp=%d maxHp=%d (step %d, turn %d)",
                        p.name, p.hp, p.maxHp, steps, game.turnCount))
                elseif (not p.alive) and p.hp > 0 then
                    error(string.format("hp bounds broken: %s dead but hp=%d (step %d, turn %d)",
                        p.name, p.hp, steps, game.turnCount))
                end
            end
        end
        if req == nil then break end
        answer = AI.answer(game, req)
    end
    return { winner = game.winner, turns = game.turnCount, steps = steps, log = game.log }
end

local tally = {}
local timeouts, errors = 0, 0
local maxTurns = 0
for i = 1, numGames do
    local seed = baseSeed + i * 7919
    local players = numPlayers
    local ok, res = pcall(playOne, seed, players)
    if not ok then
        errors = errors + 1
        print(string.format("GAME %d (seed=%d) ERROR: %s", i, seed, tostring(res)))
    else
        tally[res.winner] = (tally[res.winner] or 0) + 1
        if res.winner == "TIMEOUT" then timeouts = timeouts + 1 end
        if res.turns > maxTurns then maxTurns = res.turns end
        if verbose or res.winner == nil or res.winner == "TIMEOUT" then
            print(string.format("GAME %d seed=%d winner=%s turns=%d steps=%d",
                i, seed, tostring(res.winner), res.turns, res.steps))
            if verbose then
                local n = #res.log
                for k = math.max(1, n - 25), n do print("   " .. res.log[k]) end
            end
        end
    end
end

print("================ RESULTS ================")
print(string.format("games=%d players=%d  errors=%d timeouts=%d maxTurns=%d",
    numGames, numPlayers, errors, timeouts, maxTurns))
for k, v in pairs(tally) do
    print(string.format("  %-8s : %d (%.1f%%)", tostring(k), v, 100 * v / numGames))
end
os.exit((errors == 0 and timeouts == 0) and 0 or 1)
