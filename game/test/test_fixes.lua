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

----------------------------------------------------------------------
print("[18] 猎头联系方式 treasure: ANY hand card usable as 画饼, once per turn")
do
    local g = newGame(4, 31)
    local p = withChar(g, 1, 2)               -- 张需求: no peach-conversion skill
    p.used = {}
    p.equip.treasure = mkCard("猎头联系方式")
    p.hand = { mkCard("加班", "spade", 2) }    -- no native 画饼
    local opts = g:peachOptions(p)
    check("treasure exposes a non-peach as 画饼", #opts == 1 and opts[1].name == "加班", "n=" .. #opts)
    p.maxHp = 3; p.hp = 1
    g:usePeachCard(p, p.hand[1], p)
    check("treasure 画饼 heals", p.hp == 2, "hp=" .. p.hp)
    check("treasure budget consumed", p.used.headhunter == true)
    p.hand = { mkCard("摸鱼", "spade", 2) }    -- spade 摸鱼 is not a 画饼
    check("treasure is once-per-turn", #g:peachOptions(p) == 0, "n2=" .. #g:peachOptions(p))
end

----------------------------------------------------------------------
print("[19] 空降高管 seat rotation: ids stay stable; id-resolution targets the right player")
do
    local g = newGame(5, 41)
    for _, p in ipairs(g.players) do p.hand = {} end
    local user = g.players[1]
    user.hand = { mkCard("空降高管") }
    g.current = user
    g:playCard(user, user.hand[1], {})      -- rotate every seat by one (a 5-cycle: all move)
    local diverged
    for _, p in ipairs(g.players) do if p.alive and p.id ~= p.seat then diverged = p break end end
    check("rotation made id != seat for someone", diverged ~= nil)
    if diverged then
        -- playerById resolves by STABLE id (object identity), not by the seat slot
        check("playerById(id) returns the id-holder", g:playerById(diverged.id) == diverged)
        -- the seat-indexed slot at that id is now a DIFFERENT player (the bug this fixes)
        check("players[id] is the WRONG player post-rotation", g.players[diverged.id] ~= diverged)
        -- end-to-end: an 加班 aimed at diverged.id resolves to diverged, not players[diverged.id]
        local wrong = g.players[diverged.id]
        diverged.hp = 4; diverged.maxHp = 4; diverged.equip = diverged.equip or {}
        wrong.hp = 4; wrong.maxHp = 4
        diverged.hand = {}; wrong.hand = {}     -- no 摸鱼 to dodge
        local atk = g:playerById(user.id)
        g.current = atk
        g:performAttack(atk, g:playerById(diverged.id), { card = mkCard("加班"), amount = 1, dodgeable = true })
        check("加班 hit the id-holder, not the seat-occupant", diverged.hp == 3 and wrong.hp == 4,
            "diverged=" .. diverged.hp .. " wrong=" .. wrong.hp)
    end
end

----------------------------------------------------------------------
print("[20] boss-aligned AI never aims an offensive trick (毕业优化) at its own boss")
do
    local AI = require("src.ai")
    local g = newGame(4, 53)
    local boss
    for _, p in ipairs(g.players) do if p.identity == "boss" then boss = p end end
    -- coerce a non-boss seat into a loyalist that we control
    local me
    for _, p in ipairs(g.players) do if p.id ~= boss.id then me = p break end end
    me.identity = "loyal"; me.isHuman = false; me.flags._ai = nil
    for _, p in ipairs(g.players) do p.hp = 3; p.maxHp = 3 end
    boss.hp = 1                              -- the ONLY valid 毕业优化 target (hp<=1)
    me.hand = { mkCard("毕业优化") }
    g.current = me
    local action = AI.answer(g, { kind = "playAction", player = me })
    local hitBoss = action and action.type == "playCard" and action.targetIds and action.targetIds[1] == boss.id
    check("loyal AI does NOT 毕业优化 its own boss", not hitBoss,
        "type=" .. tostring(action and action.type) .. " tgt=" .. tostring(action and action.targetIds and action.targetIds[1]))
end

print("[21] boss AI plays non-damage disruption tricks pre-'first blood', but gates damage tricks")
do
    local AI = require("src.ai")
    local g = newGame(6, 71)
    local boss, victim
    for _, p in ipairs(g.players) do if p.identity == "boss" then boss = p end end
    for _, p in ipairs(g.players) do if p.id ~= boss.id then victim = p break end end
    for _, p in ipairs(g.players) do p.hp = 3; p.maxHp = 3 end
    boss.isHuman = false
    g.current = boss

    -- (a) 日报周报 (steal/discard, NO damage) — boss plays it on a non-boss enemy even
    --     though nobody has damaged it yet (game.threat empty).
    g.threat = {}
    boss.flags._ai = { usedAdvActive = true }
    boss.hand = { mkCard("日报周报") }
    local a = AI.answer(g, { kind = "playAction", player = boss })
    local playedDisrupt = a and a.type == "playCard" and a.targetIds and a.targetIds[1]
        and a.targetIds[1] ~= boss.id
    check("boss plays 日报周报 without first blood (non-damage disruption)", playedDisrupt,
        "type=" .. tostring(a and a.type) .. " tgt=" .. tostring(a and a.targetIds and a.targetIds[1]))

    -- (b) 毕业优化 (certain 2 damage) with NO recorded threat — gated, lest the boss finish
    --     a hidden loyalist.
    g.threat = {}
    boss.flags._ai = { usedAdvActive = true }
    victim.hp = 1                                 -- the only legal 毕业优化 target (hp<=1)
    boss.hand = { mkCard("毕业优化") }
    local b = AI.answer(g, { kind = "playAction", player = boss })
    check("boss does NOT 毕业优化 a non-threat target (damage gated)", not (b and b.type == "playCard"),
        "type=" .. tostring(b and b.type))

    -- (c) same 毕业优化 once the victim HAS threatened the boss — now allowed.
    g.threat = { [victim.id] = 1 }
    boss.flags._ai = { usedAdvActive = true }
    boss.hand = { mkCard("毕业优化") }
    local cc = AI.answer(g, { kind = "playAction", player = boss })
    local hitVictim = cc and cc.type == "playCard" and cc.targetIds and cc.targetIds[1] == victim.id
    check("boss DOES 毕业优化 a victim that threatened it", hitVictim,
        "type=" .. tostring(cc and cc.type) .. " tgt=" .. tostring(cc and cc.targetIds and cc.targetIds[1]))
end

print("[22] 何爆款 十万加 fires on red EQUIPMENT plays (engine onPlayCard on the equip path)")
do
    local g = newGame(6, 31)
    local p = withChar(g, 14, 1)        -- 何爆款
    g.current = p
    p.used = {}
    local eq = mkCard("MacBook Pro", "heart")   -- a RED equip
    p.hand = { eq }
    g:playCard(p, eq, {})
    check("十万加 counted the red equip play", p.used.viralCount == 1,
        "viralCount=" .. tostring(p.used.viralCount))
    -- a BLACK equip must NOT trigger it
    p.used = {}
    local eqB = mkCard("工牌", "spade")
    p.hand = { eqB }
    g:playCard(p, eqB, {})
    check("十万加 does NOT fire on a black equip", (p.used.viralCount or 0) == 0,
        "viralCount=" .. tostring(p.used.viralCount))
end

print("[23] 张需求 这个很简单 locks the target out of 摸鱼 for the WHOLE turn, not just one 加班")
do
    local g = newGame(6, 31)
    local p = withChar(g, 1, 1)         -- 张需求
    local target = g.players[2]
    target.char = { name = "靶子", title = "", faction = "", maxHp = 4, skills = {} }  -- neutralize
    for _, q in ipairs(g.players) do q.hp = 4; q.maxHp = 4 end
    g.current = p
    g.turnCount = 7
    p.used = {}
    g.askYesNo = function(_, _, prompt, aiDefault)
        if prompt and prompt:find("这个很简单") then return true end
        return aiDefault and true or false
    end
    g.askCard = function(_, _, opts, _, _, hint)
        if hint == "dodge" then return opts[1] end   -- the target WOULD dodge if allowed
        return nil
    end
    target.hand = { mkCard("摸鱼") }
    g:performAttack(p, target, { card = mkCard("加班") })   -- attack 1: 这个很简单 fires
    check("这个很简单 tags the target for this turn", target._noDodgeTurn == g.turnCount,
        "tag=" .. tostring(target._noDodgeTurn))
    target.hp = 4
    target.hand = { mkCard("摸鱼") }                        -- fresh dodge available
    g:performAttack(p, target, { card = mkCard("加班") })   -- attack 2: must still be undodgeable
    check("a later 加班 the same turn still can't be 摸鱼'd", target.hp < 4,
        "hp=" .. target.hp)
end

print("[24] 李接口 这是前端问题 deflect range is measured from 李接口, not the attacker")
do
    local g = newGame(6, 31)
    local libk = withChar(g, 2, 2)             -- 李接口 at seat 2
    libk.equip.weapon = mkCard("双屏显示器")   -- range 3
    local attacker = g.players[1]
    attacker.equip.weapon = nil                -- range 1
    libk.used = {}
    local captured
    g.askTarget = function(_, _, cands) captured = cands; return nil end
    libk.char.skills.onTargetedByAttack(g, libk, { source = attacker, target = libk, card = mkCard("加班") })
    local hasSeat4, hasAttacker = false, false
    for _, q in ipairs(captured or {}) do
        if q.id == g.players[4].id then hasSeat4 = true end
        if q.id == attacker.id then hasAttacker = true end
    end
    check("a player in 李接口's range but out of the attacker's (seat 4) is offered", hasSeat4,
        "n=" .. tostring(captured and #captured))
    check("the attacker is never a deflect substitute", not hasAttacker)
end

print("[25] 这个很简单 + 这是前端问题: the no-dodge lock follows the player actually HIT, not the deflector")
do
    local g = newGame(6, 31)
    local zh = withChar(g, 1, 1)       -- 张需求 (attacker, has 这个很简单)
    local libk = withChar(g, 2, 2)     -- 李接口 (original target, will 流离-deflect)
    local B = g.players[3]             -- substitute (adjacent to 李接口, in range 1)
    B.char = { name = "替身", title = "", faction = "", maxHp = 5, skills = {} }
    for _, q in ipairs(g.players) do q.hp = 5; q.maxHp = 5 end
    g.current = zh
    g.turnCount = 9
    zh.used = {}; libk.used = {}
    g.askYesNo = function(_, _, prompt, aiDefault)
        if prompt and prompt:find("这个很简单") then return true end
        return aiDefault and true or false
    end
    g.askTarget = function(_, _, _, prompt)
        if prompt and prompt:find("前端问题") then return B end   -- 李接口 deflects onto B
        return nil
    end
    g:performAttack(zh, libk, { card = mkCard("加班") })
    check("the substitute that was actually hit is locked out of 摸鱼", B._noDodgeTurn == g.turnCount,
        "B.tag=" .. tostring(B._noDodgeTurn) .. " turn=" .. g.turnCount)
    check("the deflector (李接口) that ESCAPED is NOT locked", libk._noDodgeTurn ~= g.turnCount,
        "libk.tag=" .. tostring(libk._noDodgeTurn))
end

-- Helper: a 4-seat game whose bystanders have no skills, so only the character
-- under test can affect the outcome. Returns the game.
local function neutralGame(seed, identities)
    local g = newGame(4, seed)
    for i, p in ipairs(g.players) do
        p.char = { id = 0, title = "测试", name = "桩" .. i, maxHp = 5, skills = {} }
        p.maxHp = 5; p.hp = 5; p.hand = {}
        p.identity = identities[i]
    end
    return g
end

print("[26] 王兼容 样式崩了: entering the dying zone makes a chosen other player lose 1 精神值")
do
    local g = neutralGame(41, { "boss", "loyal", "rebel", "spy" })
    local wang = withChar(g, 3, 1)              -- 王兼容 (maxHp 3)
    wang.identity = "rebel"; wang.hp = 1; wang.hand = {}
    local victim = g.players[2]                 -- hp 5
    g.askYesNo = function(_, _, prompt) return prompt ~= nil and prompt:find("样式崩了") ~= nil end
    g.askTarget = function(_, _, _, prompt) if prompt and prompt:find("样式崩了") then return victim end end
    g:dealDamage({ target = wang, source = g.players[3], amount = 1, card = mkCard("加班") })
    check("the chosen player loses exactly 1 精神值", victim.hp == 4, "victim.hp=" .. victim.hp)
    check("王兼容 did reach the dying zone (skill fired at hp<=0)", wang.hp <= 0)
end

print("[27] 罗法援 劳动仲裁: entering the dying zone makes the damage source lose 2 精神值")
do
    local g = neutralGame(43, { "rebel", "loyal", "boss", "spy" })
    local luo = withChar(g, 24, 1)             -- 罗法援
    luo.identity = "rebel"; luo.hp = 1; luo.hand = {}
    local src = g.players[3]                    -- the attacker, hp 5
    g.askYesNo = function(_, _, prompt) return prompt ~= nil and prompt:find("劳动仲裁") ~= nil end
    g:dealDamage({ target = luo, source = src, amount = 1, card = mkCard("加班") })
    check("the damage source loses exactly 2 精神值", src.hp == 3, "src.hp=" .. src.hp)
end

print("[28] 郑信仰 与公司共成长: boss damage is compensated — 郑信仰 pays 1, boss nets 0")
do
    local g = neutralGame(47, { "boss", "rebel", "rebel", "spy" })
    local boss = g.players[1]; boss.hp = 3      -- maxHp 5, so the +1 heal isn't capped
    local zheng = withChar(g, 23, 2)           -- 郑信仰 (maxHp 3)
    zheng.identity = "rebel"; zheng.hp = 3
    g.askYesNo = function(_, _, prompt) return prompt ~= nil and prompt:find("与公司共成长") ~= nil end
    g:dealDamage({ target = boss, source = g.players[3], amount = 1, card = mkCard("加班") })
    check("boss HP nets zero (took 1, healed 1 back)", boss.hp == 3, "boss.hp=" .. boss.hp)
    check("郑信仰 paid 1 精神值 for the compensation", zheng.hp == 2, "zheng.hp=" .. zheng.hp)
end

print("[29] 兼容IE (王兼容): a BLACK hand card can be played as 摸鱼 to dodge a 加班")
do
    local g = neutralGame(51, { "boss", "loyal", "rebel", "spy" })
    local wang = withChar(g, 3, 1)             -- 王兼容
    wang.identity = "rebel"; wang.hp = 3
    wang.hand = { mkCard("加班", "spade") }     -- a BLACK card, NOT a 摸鱼
    local src = g.players[3]
    g.current = src; g:resetReactiveBudgets(src)
    g.askCard = function(_, _, cands, prompt) if prompt and prompt:find("抵消") then return cands[1] end end
    g:performAttack(src, wang, { card = mkCard("加班"), amount = 1, dodgeable = true })
    check("王兼容 takes no damage (black card dodged the 加班)", wang.hp == 3, "wang.hp=" .. wang.hp)
    check("the black card was spent as 摸鱼", #wang.hand == 0)
end

print("[30] 下月打款 (吴报销): a RED hand card can be played as 画饼 to self-rescue from dying")
do
    local g = neutralGame(53, { "boss", "loyal", "rebel", "spy" })
    local wu = withChar(g, 9, 1)               -- 吴报销 (财务)
    wu.identity = "loyal"; wu.hp = 1
    wu.hand = { mkCard("加班", "heart") }       -- a RED card, NOT a 画饼
    g.askCard = function(_, _, cands, _, _, hint) if hint == "selfSave" then return cands[1] end end
    g:dealDamage({ target = wu, source = g.players[3], amount = 1, card = mkCard("加班") })
    check("吴报销 survives dying by using a red card as 画饼", wu.alive and wu.hp == 1,
        "alive=" .. tostring(wu.alive) .. " hp=" .. wu.hp)
    check("the red card was spent as 画饼", #wu.hand == 0)
end

print("[31] 年限护身 (吴年限): a RED judgment makes the damage source discard 1; a BLACK one does not")
do
    -- RED judge → source loses a card. The judge() pops the deck's last card, so seeding
    -- the deck with a single known card makes the flip deterministic.
    local g = neutralGame(61, { "boss", "loyal", "rebel", "spy" })
    local wu = withChar(g, 22, 1); wu.identity = "loyal"; wu.hp = 4
    local src = g.players[3]; src.hand = { mkCard("加班"), mkCard("摸鱼") }
    g.deck = { mkCard("画饼", "heart") }        -- RED judgment card
    g.askYesNo = function(_, _, prompt) return prompt ~= nil and prompt:find("年限护身") ~= nil end
    g:dealDamage({ target = wu, source = src, amount = 1, card = mkCard("加班") })
    check("RED judgment: the damage source discards 1 card", #src.hand == 1, "src.hand=" .. #src.hand)

    -- BLACK judge → no discard.
    local g2 = neutralGame(62, { "boss", "loyal", "rebel", "spy" })
    local wu2 = withChar(g2, 22, 1); wu2.identity = "loyal"; wu2.hp = 4
    local src2 = g2.players[3]; src2.hand = { mkCard("加班"), mkCard("摸鱼") }
    g2.deck = { mkCard("加班", "spade") }       -- BLACK judgment card
    g2.askYesNo = function(_, _, prompt) return prompt ~= nil and prompt:find("年限护身") ~= nil end
    g2:dealDamage({ target = wu2, source = src2, amount = 1, card = mkCard("加班") })
    check("BLACK judgment: the source keeps both cards", #src2.hand == 2, "src2.hand=" .. #src2.hand)
end

print("[32] 流量变现 (朱变现): hands a card to another player then redraws — moved, not duplicated")
do
    local g = neutralGame(71, { "boss", "loyal", "rebel", "spy" })
    local zhu = withChar(g, 21, 1); zhu.identity = "rebel"
    local give = mkCard("加班", "spade")
    zhu.hand = { give }                        -- the single card it will hand off
    local recip = g.players[2]; recip.hand = {}
    g.deck = { mkCard("摸鱼", "heart") }        -- the deterministic replacement draw
    g.askYesNo = function(_, _, prompt) return prompt ~= nil and prompt:find("流量变现") ~= nil end
    g.askTarget = function(_, _, _, prompt) if prompt and prompt:find("交给谁") then return recip end end
    g.askCard = function(_, _, cands) return cands[1] end
    g:trig(zhu, "afterDraw")
    check("the recipient receives exactly the handed-off card", #recip.hand == 1 and recip.hand[1] == give,
        "recip.hand=" .. #recip.hand)
    check("朱变现 redraws 1 to replace it (net hand size unchanged)", #zhu.hand == 1, "zhu.hand=" .. #zhu.hand)
    check("the card moved (not duplicated): 朱变现 no longer holds it", zhu.hand[1] ~= give)
end

print("[33] win-timing: a boss (罗法援) whose 劳动仲裁 kills the last rebel mid-dying still LOSES")
do
    -- Boss is 罗法援 at 1hp; a lone rebel (2hp) lands the lethal 加班. The boss's onDying
    -- 劳动仲裁 drops the rebel to 0 BEFORE the boss's own alive flag clears. A checkWin fired
    -- from that nested death must not credit the still-"alive" (hp<=0) boss with the win.
    local g = neutralGame(81, { "boss", "rebel", "loyal", "spy" })
    g.players[3].alive = false; g.players[4].alive = false
    local boss = withChar(g, 24, 1); boss.identity = "boss"; boss.hp = 1; boss.hand = {}
    local reb = g.players[2]; reb.hp = 2; reb.hand = {}
    g.askYesNo = function(_, _, prompt) return prompt ~= nil and prompt:find("劳动仲裁") ~= nil end
    g.askCard = function() return nil end
    g:dealDamage({ target = boss, source = reb, amount = 1, card = mkCard("加班") })
    check("boss dead -> winner is the rebel team, never 'boss'", g.winner == "rebel" and not boss.alive,
        "winner=" .. tostring(g.winner))
end

print("[34] win-timing: 劳动仲裁 kills the boss mid-dying; the spy is the true sole survivor -> spy wins")
do
    local g = neutralGame(82, { "boss", "rebel", "spy", "loyal" })
    g.players[4].alive = false
    local boss = g.players[1]; boss.hp = 2; boss.hand = {}
    local luo = withChar(g, 24, 2); luo.identity = "rebel"; luo.hp = 1; luo.hand = {}
    local spy = g.players[3]; spy.hp = 3; spy.hand = {}
    g.askYesNo = function(_, _, prompt) return prompt ~= nil and prompt:find("劳动仲裁") ~= nil end
    g.askCard = function() return nil end
    g:dealDamage({ target = luo, source = boss, amount = 1, card = mkCard("加班") })
    check("the surviving spy wins (not mis-credited to the doomed rebel)",
        g.winner == "spy" and spy.alive and not boss.alive and not luo.alive, "winner=" .. tostring(g.winner))
end

print("[35] no post-win economy: a death resolved AFTER the winner is locked pays no 击杀奖励")
do
    -- 李接口(loyal) kills 王兼容(rebel); 样式崩了 kills the boss first, locking winner=rebel. 王兼容's
    -- own (now post-win) death must NOT pay the loyal killer the 击杀【摸鱼党】 draw-3.
    local g = neutralGame(83, { "boss", "loyal", "rebel", "spy" })
    g.players[4].alive = false
    local boss = g.players[1]; boss.hp = 1; boss.hand = {}
    local li = g.players[2]; li.hp = 5; li.hand = {}
    local wang = withChar(g, 3, 3); wang.identity = "rebel"; wang.hp = 1; wang.hand = {}
    g.askYesNo = function(_, _, prompt) return prompt ~= nil and prompt:find("样式崩了") ~= nil end
    g.askTarget = function(_, _, _, prompt) if prompt and prompt:find("样式崩了") then return boss end end
    g.askCard = function() return nil end
    g:dealDamage({ target = wang, source = li, amount = 1, card = mkCard("加班") })
    check("winner=rebel and the loyal killer drew NO post-win 击杀奖励",
        g.winner == "rebel" and #li.hand == 0, "winner=" .. tostring(g.winner) .. " li.hand=" .. #li.hand)
end

print("[36] weapon on-hit gates on damage dealt: armor reducing 加班 to 0 stops the MacBook Pro discard")
do
    local g = neutralGame(84, { "boss", "rebel", "loyal", "spy" })
    local atk = g.players[1]; atk.equip.weapon = mkCard("MacBook Pro")
    local def = g.players[2]; def.hp = 4; def.armorUsedThisTurn = false
    def.equip.armor = { id = 991, name = "人体工学椅", type = "equip", subtype = "armor" }
    def.hand = { mkCard("摸鱼"), mkCard("画饼") }
    g.askYesNo = function() return true end        -- would discard if the weapon fired
    g.askCard = function() return nil end           -- decline the dodge; take the 0-damage hit
    g:performAttack(atk, def, { card = mkCard("加班") })
    check("0-damage hit -> hand intact, no MacBook Pro discard", def.hp == 4 and #def.hand == 2,
        "def.hp=" .. def.hp .. " hand=" .. #def.hand)
end

print("[37] 试用期考核 never self-judges: with an empty pool the delayed card isn't its own judgment")
do
    local g = neutralGame(85, { "boss", "rebel", "loyal", "spy" })
    local p = g.players[1]; p.hp = 4; p.hand = {}
    g.deck = {}; g.discard = {}
    local exam = mkCard("试用期考核", "spade", 5)    -- a spade-5 WOULD fail the judge if self-flipped
    p.delayed = { exam }
    g.askYesNo = function() return false end        -- don't use 画饼 to cancel
    g:resolveDelayed(p, exam)
    check("empty pool -> judge nil -> passes, no hp loss (no self-judge)", p.hp == 4, "p.hp=" .. p.hp)
    check("the 试用期考核 card lands in discard exactly once", #g.discard == 1 and g.discard[1] == exam,
        "discard=" .. #g.discard)
end

print(string.format("\n==== test_fixes: %d passed, %d failed ====", pass, fail))
os.exit(fail == 0 and 0 or 1)
