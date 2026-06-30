-- test_fixes.lua — targeted regression tests for the bugs found in the code review.
-- Run with plain lua: lua test/test_fixes.lua
package.path = "./?.lua;" .. package.path

local Engine = require("src.engine")
local Chars  = require("src.characters")
local cards  = require("src.cards")

local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("  ok   " .. name)
    else fail = fail + 1; print("  FAIL " .. name .. (extra and ("  -- " .. extra) or "")) end
end

local function newGame(n, seed)
    return Engine.new({ numPlayers = n or 6, humanSeat = nil, seed = seed or 1, characters = Chars.list })
end

-- find a player whose character has the given id, or assign it to seat 1
local function withChar(game, charId, seat)
    seat = seat or 1
    for _, c in ipairs(Chars.list) do
        if c.id == charId then
            game.players[seat].char = c
            game.players[seat].maxHp = c.maxHp
            game.players[seat].hp = c.maxHp
            return game.players[seat]
        end
    end
end

local function mkCard(name, suit, rank)
    local proto = cards.PROTO[name]
    return { id = 9000 + math.random(1, 100000), name = name, suit = suit or "spade", rank = rank or 7,
        type = proto.type, subtype = proto.subtype, range = proto.range, target = proto.target }
end

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

----------------------------------------------------------------------
print("[1] 空降高管 seat rotation: valid permutation + no immediate double-turn")
do
    local g = newGame(6, 42)
    local caster = g.players[3]
    g.current = caster
    Engine.Tricks["空降高管"](g, caster, mkCard("空降高管"), {})
    -- every player id present exactly once; every seat 1..6 occupied once
    local seenId, seenSeat, okPerm = {}, {}, true
    for seat = 1, 6 do
        local p = g.players[seat]
        if seenId[p.id] then okPerm = false end
        seenId[p.id] = true
        if p.seat ~= seat then okPerm = false end
        seenSeat[seat] = true
    end
    check("rotation is a valid permutation (no dup/missing seats)", okPerm)
    -- simulate the run() advance from the actor's (possibly changed) seat
    local seat = g.current.seat
    local nxt = seat
    for _ = 1, g.numPlayers do
        nxt = (nxt % g.numPlayers) + 1
        if g.players[nxt].alive then break end
    end
    check("caster does not immediately take another turn", g.players[nxt].id ~= caster.id,
        "next occupant id=" .. g.players[nxt].id .. " caster id=" .. caster.id)
end

----------------------------------------------------------------------
print("[2] 拉会对齐: declining/empty-hand sets persistent skipDrawNext")
do
    local g = newGame(5, 7)
    local caster = g.players[1]
    for i = 2, 5 do g.players[i].hand = {} end   -- everyone else empty -> auto skip, no asks
    g.current = caster
    Engine.Tricks["拉会对齐"](g, caster, mkCard("拉会对齐"), {})
    local allSet = true
    for i = 2, 5 do if not g.players[i].skipDrawNext then allSet = false end end
    check("all non-casters got skipDrawNext", allSet)
    check("caster unaffected", not caster.skipDrawNext)
end

----------------------------------------------------------------------
print("[3] 试用期考核: delayed card returns to discard (no leak)")
do
    local g = newGame(4, 3)
    local p = g.players[2]
    p.hp = 3; p.maxHp = 3
    p.hand = {}                                   -- no 画饼 -> no cancel prompt
    local card = mkCard("试用期考核", "heart", 10) -- heart -> judgement won't be 黑桃, passes
    p.delayed = { card }
    local before = totalCards(g)
    g:resolveDelayed(p, card)
    check("card removed from delayed", #p.delayed == 0)
    local inDiscard = false
    for _, c in ipairs(g.discard) do if c.id == card.id then inDiscard = true end end
    check("card now in discard pile", inDiscard)
    check("total cards conserved", totalCards(g) == before, "before=" .. before .. " after=" .. totalCards(g))
end

----------------------------------------------------------------------
print("[4] 人体工学椅: reduces 加班 once/turn, but NOT PUA/毕业优化 (non-card) damage")
do
    local g = newGame(4, 11)
    -- stub all chars so no skill hooks interfere
    for _, p in ipairs(g.players) do
        p.char = { id = 0, title = "测试", name = "桩", maxHp = 5, skills = {} }
        p.maxHp = 5; p.hp = 5; p.hand = {}
    end
    local atk, def = g.players[1], g.players[2]
    def.equip.armor = mkCard("人体工学椅")
    g.current = atk
    g:resetReactiveBudgets(atk)   -- start-of-turn reset

    -- real 加班 (has ctx.card): 1 - 1 armor = 0 damage
    g:performAttack(atk, def, { card = mkCard("加班"), amount = 1, dodgeable = true })
    check("first 加班 reduced by armor (0 dmg)", def.hp == 5, "hp=" .. def.hp)
    -- second 加班 same turn: armor already used -> full 1 dmg
    g:performAttack(atk, def, { card = mkCard("加班"), amount = 1, dodgeable = true })
    check("second 加班 same turn not reduced (armor once/turn)", def.hp == 4, "hp=" .. def.hp)

    -- new turn reset makes armor available again
    g:resetReactiveBudgets(atk)
    g:performAttack(atk, def, { card = mkCard("加班"), amount = 1, dodgeable = true })
    check("armor reduces again after per-turn reset", def.hp == 4, "hp=" .. def.hp)

    -- PUA-style damage (no card) must NOT be reduced by armor
    g:resetReactiveBudgets(atk)
    def.hp = 5
    g:performAttack(atk, def, { amount = 1, dodgeable = false, fromSkill = true })
    check("PUA/毕业优化 (no card) NOT reduced by armor", def.hp == 4, "hp=" .. def.hp)
end

----------------------------------------------------------------------
print("[5] 反应技 每回合一次 budget resets each turn (财务/后端/测试)")
do
    local g = newGame(5, 5)
    local fin = g.players[2]
    fin.used = { wrongProcess = true, frontendBug = true }
    fin.armorUsedThisTurn = true
    g:resetReactiveBudgets(g.players[1])   -- player 1's turn begins
    check("non-active player's reactive used flags cleared", fin.used.wrongProcess == nil and fin.used.frontendBug == nil)
    check("non-active player's armor budget cleared", fin.armorUsedThisTurn == false)
    -- active player's own `used` is handled separately by resetTurnFlags
end

----------------------------------------------------------------------
print("[6] convert offense conversions are wired (老板 装备→加班, 楚抓手 OKR→升职加薪)")
do
    local g = newGame(6, 99)
    local boss = withChar(g, 11, 1)   -- 马总 老板
    boss.hand = { mkCard("MacBook Pro") }
    -- ensure a reachable enemy exists (neighbor at distance 1)
    local opts = g:convertOptions(boss, boss.hand[1])
    check("老板 equip has convert option 加班", opts[1] == "加班", "opts=" .. table.concat(opts, ","))
    check("老板 can play equip as 加班 (reachable neighbor)", g:canPlayConverted(boss, boss.hand[1], "加班"))
    local virt = g:effectiveCard(boss.hand[1], "加班")
    check("effectiveCard builds an attack card", virt and virt.subtype == "attack")

    local mkt = withChar(g, 13, 2)    -- 楚抓手 市场
    mkt.hand = { mkCard("OKR对齐") }
    local opts2 = g:convertOptions(mkt, mkt.hand[1])
    check("楚抓手 OKR对齐 has convert option 升职加薪", opts2[1] == "升职加薪")
    check("楚抓手 can play OKR对齐 as 升职加薪", g:canPlayConverted(mkt, mkt.hand[1], "升职加薪"))
end

----------------------------------------------------------------------
print("[7] 求职者 面议 fires repeatedly (no per-round once limit)")
do
    local g = newGame(4, 8)
    local seeker = withChar(g, 15, 1)  -- 林简历 求职者
    seeker.hand = {}                   -- no 摸鱼 -> 面议 applicable
    seeker.isHuman = false
    -- the skill should be defined and not gated by once(); simulate two consecutive triggers
    local fn = seeker.char.skills.onTargetedByAttack
    -- patch askYesNo to always say yes for this player
    local realAsk = g.askYesNo
    g.askYesNo = function(self, p, prompt, aiYes) return true end
    local ctx1 = { source = g.players[2], target = seeker, amount = 1, card = mkCard("加班") }
    local r1 = fn(g, seeker, ctx1)
    local ctx2 = { source = g.players[3], target = seeker, amount = 1, card = mkCard("加班") }
    local r2 = fn(g, seeker, ctx2)
    g.askYesNo = realAsk
    check("面议 cancels first 加班", r1 == "cancel")
    check("面议 still cancels a later 加班 (not once-per-round)", r2 == "cancel")
end

----------------------------------------------------------------------
----------------------------------------------------------------------
print("[8] playConverted end-to-end (老板 plays equip as 加班) conserves cards & deals damage")
do
    local g = newGame(4, 21)
    for _, p in ipairs(g.players) do
        p.char = { id = 0, title = "测试", name = "桩", maxHp = 5, skills = {} }
        p.maxHp = 5; p.hp = 5; p.hand = {}
    end
    local boss = g.players[1]
    boss.char = { id = 11, title = "老板", name = "马总", maxHp = 5,
        skills = { convert = { { from = "equip", to = "加班" } } } }
    local equip = mkCard("工牌")
    boss.hand = { equip }
    local victim = g.players[2]   -- neighbor, distance 1, reachable
    local before = totalCards(g)
    g.current = boss

    -- run inside a coroutine; auto-answer any asks (victim has no 摸鱼 so none expected)
    local co = coroutine.create(function()
        g:playConverted(boss, equip, "加班", { victim.id })
    end)
    local ans, safe = nil, 0
    while true do
        safe = safe + 1; if safe > 1000 then break end
        local ok, req = coroutine.resume(co, ans)
        check("playConverted runs without error", ok, tostring(req))
        if coroutine.status(co) == "dead" then break end
        ans = nil   -- decline/skip everything
    end
    check("equip card left hand", #boss.hand == 0)
    check("converted 加班 dealt 1 damage", victim.hp == 4, "hp=" .. victim.hp)
    check("attack budget consumed", (boss.flags.attacksUsed or 0) == 1)
    check("total cards conserved through conversion", totalCards(g) == before,
        "before=" .. before .. " after=" .. totalCards(g))
end

print(string.format("\n==== test_fixes: %d passed, %d failed ====", pass, fail))
os.exit(fail == 0 and 0 or 1)
