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

----------------------------------------------------------------------
print("[9] 人体工学椅 armor follows the damage substitute (背锅 redirect), not original")
do
    local g = newGame(4, 13)
    for _, p in ipairs(g.players) do
        p.char = { id = 0, title = "测试", name = "桩", maxHp = 5, skills = {} }
        p.maxHp = 5; p.hp = 5; p.hand = {}
    end
    local atk, orig, sub = g.players[1], g.players[2], g.players[3]
    orig.isHuman = true                      -- 背锅 redirect path is human-only
    orig.hand = { mkCard("背锅") }
    sub.equip.armor = mkCard("人体工学椅")    -- only the SUBSTITUTE wears armor
    g.current = atk
    g:resetReactiveBudgets(atk)
    -- force the 背锅 decision: yes, transfer the hit to `sub`
    local realYes, realTgt = g.askYesNo, g.askTarget
    g.askYesNo = function() return true end
    g.askTarget = function() return sub end
    g:performAttack(atk, orig, { card = mkCard("加班"), amount = 1, dodgeable = false })
    g.askYesNo, g.askTarget = realYes, realTgt
    check("redirected-away original takes no damage", orig.hp == 5, "hp=" .. orig.hp)
    -- under the old (pre-fix) ordering the substitute took the full 1 (its armor was skipped)
    check("substitute's OWN armor reduces the redirected 加班 to 0", sub.hp == 5, "hp=" .. sub.hp)
    check("substitute's armor flag consumed (it took the hit)", sub.armorUsedThisTurn == true)
    check("original's armor flag NOT consumed (it never took the hit)", orig.armorUsedThisTurn == false)
end

----------------------------------------------------------------------
print("[10] 刘重启 服务挂了: AI triggers for out-numbered boss-team, declines for rebel")
do
    local AI = require("src.ai")
    local function run(identity)
        local g = newGame(5, 17)
        local liu = withChar(g, 6, 1)           -- 刘重启
        liu.identity = identity
        for _, p in ipairs(g.players) do p.hand = { mkCard("加班"), mkCard("摸鱼") } end
        -- onDying ask()s via coroutine.yield; drive it with the AI answerer (which
        -- returns req.aiChoice, i.e. the aiWant default our fix passes to askYesNo).
        local co = coroutine.create(function() liu.char.skills.onDying(g, liu, nil) end)
        local ans = nil
        while true do
            local ok, req = coroutine.resume(co, ans)
            assert(ok, tostring(req))
            if coroutine.status(co) == "dead" then break end
            ans = AI.answer(g, req)
        end
        local others = 0
        for i = 2, 5 do if #g.players[i].hand == 1 then others = others + 1 end end
        return others                            -- how many non-casters lost a card
    end
    check("loyal 刘重启 triggers it (all 4 others each discard 1)", run("loyal") == 4)
    check("rebel 刘重启 declines it (no one discards)", run("rebel") == 0)
end

----------------------------------------------------------------------
print("[11] 新媒体 十万加 fires on a 摸鱼 dodge and a rescue 画饼 (red cards)")
do
    local g = newGame(4, 23)
    local mei = withChar(g, 14, 2)              -- 新媒体 何爆款
    local atk = g.players[1]
    -- dodge path: 何爆款 dodges an 加班 with a RED 摸鱼 -> 十万加 展示红牌摸1.
    -- (counter lives in `used` so it resets every turn, not just 何爆款's own.)
    mei.used = {}
    mei.hand = { mkCard("摸鱼", "heart", 5) }
    g.current = atk
    local realAsk = g.askCard
    g.askCard = function(self, p, cands) return cands[1] end   -- force the dodge
    g:performAttack(atk, mei, { card = mkCard("加班"), amount = 1, dodgeable = true })
    g.askCard = realAsk
    check("十万加 fired on a red 摸鱼 dodge", mei.used.viralCount == 1,
        "viral=" .. tostring(mei.used.viralCount))

    -- rescue-peach path: using a RED 画饼 to heal also triggers 十万加
    mei.used = {}
    local ally = g.players[3]; ally.maxHp = 4; ally.hp = 1
    g:usePeachCard(mei, mkCard("画饼", "heart", 3), ally)
    check("十万加 fired on a red rescue 画饼", mei.used.viralCount == 1,
        "viral=" .. tostring(mei.used.viralCount))
end

----------------------------------------------------------------------
print("[12] AI 背锅: an AI victim redirects a (near-)lethal hit, conserving cards")
do
    local AI = require("src.ai")
    local g = newGame(4, 31)
    for _, p in ipairs(g.players) do
        p.char = { id = 0, title = "测试", name = "桩", maxHp = 5, skills = {} }
        p.maxHp = 5; p.hp = 5; p.hand = {}; p.isHuman = false
    end
    local atk, victim = g.players[1], g.players[2]
    victim.hp = 1                          -- a 1-damage hit is lethal → AI should 背锅
    victim.hand = { mkCard("背锅") }
    g.current = atk
    g:resetReactiveBudgets(atk)
    local before = totalCards(g)
    local co = coroutine.create(function()
        g:performAttack(atk, victim, { card = mkCard("加班"), amount = 1, dodgeable = false })
    end)
    local ans = nil
    while true do
        local ok, req = coroutine.resume(co, ans)
        assert(ok, tostring(req))
        if coroutine.status(co) == "dead" then break end
        ans = AI.answer(g, req)
    end
    check("AI victim survived the lethal hit by redirecting", victim.alive and victim.hp == 1,
        "alive=" .. tostring(victim.alive) .. " hp=" .. victim.hp)
    local elsewhere = false
    for _, i in ipairs({ 1, 3, 4 }) do if g.players[i].hp < 5 then elsewhere = true end end
    check("the redirected hit landed on another player", elsewhere)
    check("背锅 left the victim's hand", #victim.hand == 0)
    check("cards conserved (背锅 → discard)", totalCards(g) == before,
        "before=" .. before .. " after=" .. totalCards(g))
end

----------------------------------------------------------------------
print("[13] 反骨仔 recovers 1 精神值 on a kill (GDD §8.4); boss/rebel do not")
do
    local function killerHpAfter(identity)
        local g = newGame(4, 41)
        for _, p in ipairs(g.players) do
            p.char = { id = 0, title = "测试", name = "桩", maxHp = 5, skills = {} }
            p.maxHp = 5; p.hp = 5
        end
        local killer, victim = g.players[1], g.players[2]
        killer.identity = identity
        killer.hp = 2                       -- below max so a heal is observable
        victim.identity = "rebel"           -- avoids the boss-kills-loyal penalty path
        victim.hp = 1
        g:killPlayer(victim, killer)
        return killer.hp
    end
    check("spy heals 1 on a kill (2 → 3)", killerHpAfter("spy") == 3, "hp=" .. killerHpAfter("spy"))
    check("boss does NOT heal on a kill (stays 2)", killerHpAfter("boss") == 2)
    check("rebel does NOT heal on a kill (stays 2)", killerHpAfter("rebel") == 2)
end

----------------------------------------------------------------------
print("[14] 加班-scoped on-attack skills (面议) fire ONLY for a real 加班, not PUA/毕业优化")
do
    local g = newGame(4, 19)
    for _, p in ipairs(g.players) do p.maxHp = 4; p.hp = 4; p.hand = {} end
    local atk = g.players[1]
    local seeker = withChar(g, 15, 2)   -- 林简历 求职者; 面议 cancels a 加班 if no 摸鱼 in hand
    seeker.hp = 4; seeker.hand = {}; seeker.isHuman = false
    g.current = atk
    g:resetReactiveBudgets(atk)
    local realYes = g.askYesNo
    -- only answer the 面议 prompt 'yes'; other reactive yes/no (e.g. a random 背锅侠 at
    -- another seat, which correctly fires on ANY damage) keep their AI default.
    g.askYesNo = function(self, p, prompt, aiDefault)
        if prompt and prompt:find("面议") then return true end
        return aiDefault and true or false
    end
    -- (a) skill-induced hit with NO card (like PUA option-2 / 毕业优化): must NOT be cancelled
    g:performAttack(atk, seeker, { amount = 1, dodgeable = false, fromSkill = true })
    check("PUA/毕业优化-style hit (no card) is NOT cancelled by 面议", seeker.hp == 3, "hp=" .. seeker.hp)
    -- (b) a real 加班: 面议 still cancels it (remains 加班-scoped)
    g:resetReactiveBudgets(atk)
    seeker.hp = 4
    g:performAttack(atk, seeker, { card = mkCard("加班"), amount = 1, dodgeable = true })
    g.askYesNo = realYes
    check("a real 加班 IS still cancelled by 面议", seeker.hp == 4, "hp=" .. seeker.hp)
end

----------------------------------------------------------------------
print("[15] tryDodge tags the chooseCard request hint='dodge' (AI dodge logic is live, not dead)")
do
    local g = newGame(4, 7)
    local atk, tgt = g.players[1], g.players[2]
    tgt.hand = { mkCard("摸鱼", "heart", 5) }
    local seenHint = "<unset>"
    local realAsk = g.askCard
    g.askCard = function(self, p, cands, prompt, optional, hint) seenHint = hint; return nil end
    g:tryDodge(tgt, { dodgeable = true, source = atk, card = mkCard("加班") })
    g.askCard = realAsk
    -- without this hint the request defaulted to "discard" and ai.decideCard's probabilistic
    -- dodge branch was unreachable -> the AI dodged 100% of every non-lethal hit.
    check("tryDodge passes hint='dodge'", seenHint == "dodge", "hint=" .. tostring(seenHint))
end

----------------------------------------------------------------------
print("[16] 4p boss opens with 1 fewer card (un-outnumbered table); 6p boss keeps 4")
do
    local g4 = newGame(4, 11)
    local boss4
    for _, p in ipairs(g4.players) do if p.identity == "boss" then boss4 = p end end
    check("4p boss opens with 3 cards", #boss4.hand == 3, "hand=" .. #boss4.hand)
    check("4p deck still conserves (108)", totalCards(g4) == 108, "tot=" .. totalCards(g4))
    local g6 = newGame(6, 11)
    local boss6
    for _, p in ipairs(g6.players) do if p.identity == "boss" then boss6 = p end end
    check("6p (out-numbered) boss opens with 4 cards", #boss6.hand == 4, "hand=" .. #boss6.hand)
end

----------------------------------------------------------------------
print("[17] 复现不了 (赵bug) can negate a harmful AOE trick (拉会对齐), once per turn")
do
    local g = newGame(4, 21)
    local user = g.players[1]
    local zhao = withChar(g, 4, 2)        -- 赵bug 复现不了
    zhao.used = {}
    local realYes = g.askYesNo
    g.askYesNo = function(self, p, prompt, aiDefault)
        if prompt and prompt:find("复现不了") then return true end
        return aiDefault and true or false
    end
    local la = mkCard("拉会对齐")
    -- first AOE this turn: 赵bug negates it (the card no longer affects it)
    local hit1 = g:trickAffects(user, la, zhao)
    check("复现不了 negates the AOE (trickAffects=false)", hit1 == false, "hit1=" .. tostring(hit1))
    -- 每回合一次: a second AOE the same turn is NOT negated
    local hit2 = g:trickAffects(user, la, zhao)
    check("复现不了 is once-per-turn (2nd AOE lands)", hit2 == true, "hit2=" .. tostring(hit2))
    g.askYesNo = realYes
end

print(string.format("\n==== test_fixes: %d passed, %d failed ====", pass, fail))
os.exit(fail == 0 and 0 or 1)
