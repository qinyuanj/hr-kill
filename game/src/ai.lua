-- ai.lua — heuristic AI driver. Given an engine and a request, returns an answer.
-- The AI only uses information a real player would have: its own identity and the
-- public boss identity. It never peeks at other players' hidden identities.

local util = require("src.util")

local AI = {}

----------------------------------------------------------------------
-- Card valuation (for discarding & keeping)
----------------------------------------------------------------------
local BASE_VALUE = {
    ["升职加薪"] = 6, ["画饼"] = 6, ["毕业优化"] = 5, ["加班"] = 4, ["摸鱼"] = 4,
    ["MacBook Pro"] = 5, ["双屏显示器"] = 5, ["工牌"] = 4, ["人体工学椅"] = 4,
    ["独立办公室"] = 4, ["猎头联系方式"] = 4, ["PUA"] = 4, ["团建"] = 4,
    ["背锅"] = 4, ["卷一下"] = 3, ["OKR对齐"] = 3, ["日报周报"] = 3,
    ["融资到账"] = 3, ["拉会对齐"] = 3, ["试用期考核"] = 3, ["空降高管"] = 2,
    ["+1职级"] = 3, ["-1职级"] = 3, ["股权激励书"] = 2,
}

local function cardValue(game, player, card)
    local v = BASE_VALUE[card.name] or 3
    -- value dodge/peach more when fragile
    if card.subtype == "dodge" and player.hp <= 2 then v = v + 2 end
    if card.subtype == "peach" and player.hp <= 2 then v = v + 3 end
    return v
end

-- worst card to discard (lowest value)
local function worstCard(game, player, candidates)
    local best, bestV
    for _, c in ipairs(candidates) do
        local v = cardValue(game, player, c)
        if not bestV or v < bestV then best, bestV = c, v end
    end
    return best
end

----------------------------------------------------------------------
-- Target preference (no hidden-identity peeking)
----------------------------------------------------------------------
local function aliveCount(game)
    return #game:aliveSeatsInOrder()
end

-- score how much `me` wants to attack/hurt `t` (higher = more)
local function hostility(game, me, t)
    local s = (8 - math.min(t.hp, 8))  -- prefer low-hp (closer to a kill)
    local boss = game:bossPlayer()
    local isBoss = (t.id == boss.id)
    local threat = (game.threat and game.threat[t.id]) or 0
    if me.identity == "rebel" then
        if isBoss then s = s + 25 end
    elseif me.identity == "loyal" or me.identity == "boss" then
        if isBoss then s = s - 1000 end             -- never attack the boss
        s = s + 12 * threat                          -- focus those who hit the boss
    elseif me.identity == "spy" then
        if isBoss then
            if aliveCount(game) <= 2 then s = s + 100 else s = s - 8 end
        end
    end
    return s
end

local function bestTarget(game, me, candidates, hint)
    if #candidates == 0 then return nil end
    if hint == "self" then
        for _, p in ipairs(candidates) do if p.id == me.id then return p end end
    end
    if hint == "ally" then
        -- prefer self, else boss if I'm boss-aligned, else lowest hp
        for _, p in ipairs(candidates) do if p.id == me.id then return p end end
        local boss = game:bossPlayer()
        if me.identity == "loyal" then
            for _, p in ipairs(candidates) do if p.id == boss.id then return p end end
        end
        local best, bestH
        for _, p in ipairs(candidates) do
            if not bestH or p.hp < bestH then best, bestH = p, p.hp end
        end
        return best
    end
    -- enemy / any
    local best, bestS
    for _, p in ipairs(candidates) do
        if p.id ~= me.id then
            local sc = hostility(game, me, p) + game.rng:float()
            if not bestS or sc > bestS then best, bestS = p, sc end
        end
    end
    return best or candidates[1]
end

----------------------------------------------------------------------
-- Play-phase planning: pick the next single action
----------------------------------------------------------------------
local function firstPlayable(game, player, name)
    for _, c in ipairs(player.hand) do
        if c.name == name and game:canPlayInPhase(player, c) then return c end
    end
    return nil
end

-- A hand card this character can play AS `asName` via a convert skill (老板 装备→加班,
-- 楚抓手 OKR对齐→升职加薪), and that is legal right now. Returns the real card or nil.
local function firstConvertible(game, player, asName)
    for _, c in ipairs(player.hand) do
        for _, opt in ipairs(game:convertOptions(player, c)) do
            if opt == asName and game:canPlayConverted(player, c, asName) then return c end
        end
    end
    return nil
end

-- pick an attack target among reachable enemies, respecting identity strategy
local function chooseAttackTarget(game, me)
    local bossId = game:bossPlayer().id
    local cands = {}
    for _, p in ipairs(game:aliveSeatsInOrder()) do
        if p.id ~= me.id and game:canReach(me, p) then
            -- loyal/boss should not waste attacks on the boss
            if not ((me.identity == "loyal" or me.identity == "boss") and p.id == bossId) then
                cands[#cands + 1] = p
            end
        end
    end
    if #cands == 0 then return nil end
    -- The boss must not randomly attack (it might kill a loyalist → discard penalty).
    -- It only strikes players who have already attacked it.
    if me.identity == "boss" then
        local threats = {}
        for _, p in ipairs(cands) do
            if (game.threat and game.threat[p.id] or 0) > 0 then threats[#threats + 1] = p end
        end
        if #threats == 0 then return nil end
        cands = threats
    end
    return bestTarget(game, me, cands, "enemy")
end

local function planAction(game, me)
    me.flags._ai = me.flags._ai or {}
    local ai = me.flags._ai

    -- 1) emergency heal
    if me.hp < me.maxHp and me.hp <= 2 then
        local peaches = game:handCardsAs(me, "peach")
        -- only spend a peach in play phase if it is a real 画饼 (keep view-as for dying)
        for _, c in ipairs(peaches) do
            if c.subtype == "peach" and game:canPlayInPhase(me, c) then
                return { type = "playCard", cardId = c.id, targetIds = { me.id } }
            end
        end
    end

    -- 1b) boss-team field medic: a loyalist (or the boss) spends a spare 画饼 to top up
    -- an endangered boss before it gets focused into the dying zone. Losing the boss
    -- ends the game, so keeping it alive is worth more than holding the card.
    if (me.identity == "loyal" or me.identity == "boss") then
        local boss = game:bossPlayer()
        local healTarget = (me.identity == "loyal" and boss.hp <= 2 and boss.hp < boss.maxHp) and boss
            or (me.identity == "boss" and me.hp <= 3 and me.hp < me.maxHp) and me
        if healTarget then
            for _, c in ipairs(game:handCardsAs(me, "peach")) do
                if c.subtype == "peach" and game:canPlayInPhase(me, c) then
                    return { type = "playCard", cardId = c.id, targetIds = { healTarget.id } }
                end
            end
        end
    end

    -- 2) equip useful gear (one per call), best-first, skip downgrades
    for _, c in ipairs(me.hand) do
        if c.type == "equip" then
            local slot = c.subtype
            local cur = me.equip[slot]
            local worth = true
            if slot == "weapon" and cur and (cur.range or 1) >= (c.range or 1) then worth = false end
            if cur and (slot == "armor" or slot == "treasure") then worth = false end
            if c.name == "股权激励书" and me.identity ~= "boss" then worth = false end
            if worth and not ai["equip_" .. c.id] then
                ai["equip_" .. c.id] = true
                return { type = "playCard", cardId = c.id, targetIds = {} }
            end
        end
    end

    -- 3) card-advantage actives & self tricks
    if not ai.usedAdvActive then
        for _, sk in ipairs(game:listActiveSkills(me)) do
            local useful = true
            -- gate skills that need a valid victim/target
            if sk.id == "reqChanged" or sk.id == "reportBug" or sk.id == "interview" or sk.id == "swap" then
                local any = false
                for _, q in ipairs(game:aliveSeatsInOrder()) do
                    if q.id ~= me.id and #q.hand > 0 then any = true break end
                end
                useful = any and (sk.id ~= "reportBug" or #me.hand > 0) and (sk.id ~= "swap" or #me.hand > 0)
            elseif sk.id == "reboot" then
                useful = (me.hp < me.maxHp and #me.hand > 0)
            elseif sk.id == "teatime" then
                useful = (me.hp < me.maxHp)
            end
            if useful then
                ai.usedAdvActive = true
                return { type = "skill", skillId = sk.id }
            end
        end
        ai.usedAdvActive = true
    end

    -- 4) 升职加薪 (pure card advantage) — natively, or 楚抓手 OKR对齐→升职加薪
    local promo = firstPlayable(game, me, "升职加薪")
    if promo then return { type = "playCard", cardId = promo.id, targetIds = {} } end
    local promoConv = firstConvertible(game, me, "升职加薪")
    if promoConv then return { type = "playCard", cardId = promoConv.id, targetIds = {}, as = "升职加薪" } end

    -- 5) wine + attack burst on a killable target
    local atk = firstPlayable(game, me, "加班")
    if atk and game:attacksLeft(me) > 0 then
        local t = chooseAttackTarget(game, me)
        if t then
            -- use 卷一下 if the target could die from the extra damage
            local wine = firstPlayable(game, me, "卷一下")
            if wine and not me.flags.wine and t.hp <= 2 and not ai.usedWine then
                ai.usedWine = true
                return { type = "playCard", cardId = wine.id, targetIds = { me.id } }
            end
            return { type = "playCard", cardId = atk.id, targetIds = { t.id } }
        end
    end

    -- 5b) 老板 狼性文化: turn a spare equipment card into an extra 加班. Any equipment
    -- still in hand here was already passed over for equipping (a downgrade/duplicate),
    -- so spending it as an attack is free value.
    if game:attacksLeft(me) > 0 then
        local conv = firstConvertible(game, me, "加班")
        if conv then
            local t = chooseAttackTarget(game, me)
            if t then return { type = "playCard", cardId = conv.id, targetIds = { t.id }, as = "加班" } end
        end
    end

    -- 6) offensive / disruptive tricks
    local function useTrickOn(name, hint)
        local c = firstPlayable(game, me, name)
        if not c then return nil end
        local tg = game:validTargets(me, c)
        if #tg == 0 then
            -- aoe/self trick: just use it
            return { type = "playCard", cardId = c.id, targetIds = {} }
        end
        local t = bestTarget(game, me, tg, hint or "enemy")
        if t then return { type = "playCard", cardId = c.id, targetIds = { t.id } } end
        return nil
    end

    if not ai.t_grad then ai.t_grad = true
        local a = useTrickOn("毕业优化"); if a then return a end
    end
    if not ai.t_pua then ai.t_pua = true
        local a = useTrickOn("PUA"); if a then return a end
    end
    if not ai.t_exam then ai.t_exam = true
        local a = useTrickOn("试用期考核"); if a then return a end
    end
    if not ai.t_report then ai.t_report = true
        local a = useTrickOn("日报周报"); if a then return a end
    end
    if not ai.t_team then ai.t_team = true
        local a = useTrickOn("团建"); if a then return a end
    end
    if not ai.t_align then ai.t_align = true
        local a = useTrickOn("拉会对齐"); if a then return a end
    end
    if not ai.t_fund then ai.t_fund = true
        if me.hp <= 1 then local a = useTrickOn("融资到账"); if a then return a end end
    end

    -- 7) any remaining attacks
    if game:attacksLeft(me) > 0 then
        local atk2 = firstPlayable(game, me, "加班")
        if atk2 then
            local t = chooseAttackTarget(game, me)
            if t then return { type = "playCard", cardId = atk2.id, targetIds = { t.id } } end
        end
    end

    return { type = "end" }
end

----------------------------------------------------------------------
-- Response decisions
----------------------------------------------------------------------
local function decideCard(game, req)
    local player = req.player
    local cand = {}
    for _, id in ipairs(req.candidates) do
        local c = game:findCard(player, id)
        if c then cand[#cand + 1] = c end
    end
    if #cand == 0 then return nil end
    local hint = req.hint or "discard"

    if hint == "dodge" then
        -- Always dodge a potentially lethal hit; otherwise dodge only sometimes so
        -- that chip damage actually accumulates and games converge.
        if player.hp <= 1 then return worstCard(game, player, cand).id end
        local pDodge = (player.hp <= 2) and 0.5 or 0.25
        if game.rng:float() < pDodge then return worstCard(game, player, cand).id end
        return nil
    elseif hint == "selfSave" then
        return worstCard(game, player, cand).id      -- always self-rescue
    elseif hint == "allySave" then
        -- Save a confirmed ally. With hidden identities the only player anyone can
        -- reliably read is the (public) boss, so boss-aligned players spend a peach
        -- to keep the boss alive — this is game-critical for the boss team. A loyalist
        -- with spare peaches also covers a teammate it has positively identified.
        local dying = req.dyingId and game.players[req.dyingId]
        if not dying then return nil end
        local saveBoss = (player.identity == "loyal" or player.identity == "boss")
            and dying.identity == "boss"
        if saveBoss then return worstCard(game, player, cand).id end
        return nil
    elseif hint == "use" or hint == "gain" then
        -- pick the most valuable to use/gain
        local best, bestV
        for _, c in ipairs(cand) do
            local v = cardValue(game, player, c)
            if not bestV or v > bestV then best, bestV = c, v end
        end
        return best.id
    else -- discard
        return worstCard(game, player, cand).id
    end
end

----------------------------------------------------------------------
-- Public entry: answer a request
----------------------------------------------------------------------
function AI.answer(game, req)
    if req.kind == "playAction" then
        return planAction(game, req.player)
    elseif req.kind == "chooseCard" then
        return decideCard(game, req)
    elseif req.kind == "chooseTarget" then
        local cands = util.map(req.candidates, function(id) return game.players[id] end)
        local t = bestTarget(game, req.player, cands, req.hint or "enemy")
        if req.optional and not t then return nil end
        return t and t.id or (req.optional and nil or req.candidates[1])
    elseif req.kind == "chooseOption" then
        return req.aiChoice or 1
    end
    return nil
end

return AI
