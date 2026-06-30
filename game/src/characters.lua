-- characters.lua — the 24 首发角色 with skills implemented against the engine.
--
-- Each character: { id, name, title, faction, maxHp, s1, s2 (skill names/descs),
--   skills = { <hook fns> } }
--
-- Skill hooks the engine calls (all receive (game, player, ...)):
--   drawNumMod(base) -> number | "skip"   modify draw-phase count
--   handLimitMod() -> delta                modify hand limit
--   afterDraw()                            after the draw phase
--   onTurnStart() / onTurnEnd()
--   onUseAttack(ctx)                       attacker, before dodge
--   onTargetedByAttack(ctx) -> "cancel"?   target of 加班 (may transfer/cancel/reduce)
--   onTakeDamage(ctx)                      victim, after damage
--   onDealDamage(victim, ctx)              dealer, after damage
--   onDying(source) / onDeath(source)
--   onTargetedByTrick(card, user) -> bool  target may cancel a single-target trick
--   trickCounter(user, card, targets) -> bool  any player negates an opponent trick
--   onPlayCard(card)                       after the player uses/plays a card
--   viewAs(card) -> { "dodge"|"peach"|"attack", ... }  card conversions (responses)
--   graduationBonus = true                 HR 毕业通知 (handled in 毕业优化)
--   actives = { {id,name,desc,canUse,run}, ... }  active (manual) skills
--
-- Conversions for *offense* that the human can choose are listed in `convert`
-- (engine/UI reads them); the AI sticks to native plays.

local cards = require("src.cards")

local C = {}

-- helper: choose a target among alive others
local function aliveOthers(game, player)
    local out = {}
    for _, p in ipairs(game:aliveSeatsInOrder()) do
        if p.id ~= player.id then out[#out + 1] = p end
    end
    return out
end

local function once(player, key)
    if player.used[key] then return false end
    player.used[key] = true
    return true
end

C.list = {
    ----------------------------------------------------------------
    -- 互联网篇
    ----------------------------------------------------------------
    {
        id = 1, name = "张需求", title = "产品经理", faction = "互联网", maxHp = 3,
        s1 = "需求变了：出牌阶段限一次，令一名角色弃1张手牌，然后你摸1张牌。",
        s2 = "这个很简单：使用【加班】指定目标后，可令其本回合无法【摸鱼】（每回合一次）。",
        skills = {
            onUseAttack = function(game, p, ctx)
                -- only real 加班 (ctx.card), optional, once per turn
                if not ctx.card or p.used.thisIsEasy then return end
                if game:askYesNo(p, "发动【这个很简单】令目标本回合无法【摸鱼】？", true) then
                    p.used.thisIsEasy = true
                    ctx.noDodge = true
                    -- 本回合无法【摸鱼】: lock the target for the whole turn so LATER 加班 (福报/
                    -- weapon) also can't be dodged. The durable tag is applied by performAttack
                    -- AFTER target resolution, so it follows whoever is actually hit (e.g. the
                    -- substitute after a 这是前端问题 transfer), not the original/deflecting target.
                    ctx.lockNoDodge = true
                    game:logmsg("%s【这个很简单】：目标本回合无法【摸鱼】", p.name)
                end
            end,
            actives = {
                {
                    id = "reqChanged", name = "需求变了",
                    canUse = function(game, p) return not p.used.reqChanged end,
                    run = function(game, p)
                        local cands = {}
                        for _, q in ipairs(aliveOthers(game, p)) do
                            if #q.hand > 0 then cands[#cands + 1] = q end
                        end
                        local t = game:askTarget(p, cands, "【需求变了】令谁弃1张手牌？", true)
                        if not t then return end
                        p.used.reqChanged = true
                        local c = t.hand[game.rng:int(1, #t.hand)]
                        game:discardCards(t, { c }, "需求变了")
                        game:draw(p, 1, "需求变了")
                    end,
                },
            },
        },
    },
    {
        id = 2, name = "李接口", title = "后端开发", faction = "互联网", maxHp = 4,
        s1 = "接口未通：受到伤害后，可令伤害来源弃1张牌。",
        s2 = "这是前端问题：成为【加班】目标时，可令攻击范围内另一名角色替你成为目标（每回合一次）。",
        skills = {
            onTakeDamage = function(game, p, ctx)
                local src = ctx.source
                if src and src.alive and #src.hand > 0 then
                    if game:askYesNo(p, string.format("【接口未通】令 %s 弃1张牌？", src.name)) then
                        local c = src.hand[game.rng:int(1, #src.hand)]
                        game:discardCards(src, { c }, "接口未通")
                    end
                end
            end,
            onTargetedByAttack = function(game, p, ctx)
                local src = ctx.source
                if not src or not once(p, "frontendBug") then return end
                local cands = {}
                for _, q in ipairs(game:aliveSeatsInOrder()) do
                    -- 流离: the substitute must be within 李接口's OWN attack range (not the
                    -- attacker's) — diverges once weapons/horses make the two ranges differ.
                    if q.id ~= p.id and q.id ~= src.id and game:canReach(p, q) then cands[#cands + 1] = q end
                end
                if #cands == 0 then p.used.frontendBug = nil return end
                local t = game:askTarget(p, cands, "【这是前端问题】转移【加班】给？", true)
                if t then
                    ctx.target = t
                    game:logmsg("%s【这是前端问题】：%s 替其承受【加班】", p.name, t.name)
                else
                    p.used.frontendBug = nil
                end
            end,
        },
    },
    {
        id = 3, name = "王兼容", title = "前端开发", faction = "互联网", maxHp = 3,
        s1 = "兼容IE：你可将黑色手牌当【摸鱼】使用。",
        s2 = "样式崩了：失去最后1点精神值时，可令一名其他角色失去1点精神值。",
        skills = {
            viewAs = function(game, p, card)
                if cards.isBlack(card) then return { "dodge" } end
            end,
            onDying = function(game, p, source)
                local cands = aliveOthers(game, p)
                if #cands == 0 then return end
                if game:askYesNo(p, "【样式崩了】令一名角色失去1点精神值？") then
                    local t = game:askTarget(p, cands, "【样式崩了】目标？", true)
                    if t then game:loseHp(t, 1, "样式崩了") end
                end
            end,
        },
    },
    {
        id = 4, name = "赵bug", title = "测试工程师", faction = "互联网", maxHp = 3,
        s1 = "提个bug：出牌阶段，弃1张牌查看一名角色手牌，若有【加班】其受1点伤害。",
        s2 = "复现不了：每回合一次，成为锦囊牌目标时可令此牌对你无效。",
        skills = {
            onTargetedByTrick = function(game, p, card, user)
                if card.subtype == "instant" then return false end
                if not once(p, "cantRepro") then return false end
                if game:askYesNo(p, string.format("【复现不了】令【%s】对你无效？", card.name)) then
                    return true
                end
                p.used.cantRepro = nil
                return false
            end,
            actives = {
                {
                    id = "reportBug", name = "提个bug",
                    canUse = function(game, p) return #p.hand > 0 end,
                    run = function(game, p)
                        local c = game:askCard(p, p.hand, "【提个bug】弃1张牌发动", true)
                        if not c then return end
                        local t = game:askTarget(p, aliveOthers(game, p), "查看谁的手牌？", true)
                        if not t then return end
                        game:discardCards(p, { c }, "提个bug")
                        local hasAttack = false
                        for _, hc in ipairs(t.hand) do if hc.subtype == "attack" then hasAttack = true break end end
                        game:logmsg("%s 查看了 %s 的手牌", p.name, t.name)
                        if hasAttack then
                            game:logmsg("发现【加班】！%s 受到1点伤害", t.name)
                            game:dealDamage({ source = p, target = t, amount = 1, nature = "normal" })
                        end
                    end,
                },
            },
        },
    },
    {
        id = 5, name = "陈对齐", title = "UI设计师", faction = "互联网", maxHp = 3,
        s1 = "左右对齐：摸牌阶段可少摸1张，然后令一名角色多摸1张。",
        s2 = "没有高级感：受到伤害后，摸1张牌。",
        skills = {
            drawNumMod = function(game, p, base)
                local cands = aliveOthers(game, p)
                if #cands == 0 then return base end
                if game:askYesNo(p, "【左右对齐】少摸1张，令一名角色多摸1张？", false) then
                    local t = game:askTarget(p, cands, "令谁多摸1张？", true)
                    if t then
                        p.flags._alignTarget = t
                        return base - 1
                    end
                end
                return base
            end,
            afterDraw = function(game, p)
                if p.flags._alignTarget then
                    game:draw(p.flags._alignTarget, 1, "左右对齐")
                    p.flags._alignTarget = nil
                end
            end,
            onTakeDamage = function(game, p, ctx)
                game:draw(p, 1, "没有高级感")
            end,
        },
    },
    {
        id = 6, name = "刘重启", title = "运维工程师", faction = "互联网", maxHp = 4,
        s1 = "重启试试：出牌阶段限一次，弃置所有手牌，回复1点精神值并摸等量牌。",
        s2 = "服务挂了：进入濒死状态时，可令全场各弃1张牌。",
        skills = {
            onDying = function(game, p, source)
                -- 服务挂了 makes EVERYONE discard 1 — a symmetric effect, so it favors the
                -- out-numbered side. The boss team is the minority, so an AI boss/嫡系 wants
                -- it; rebels (the majority) and the spy decline rather than help opponents.
                -- (No identity-peeking: the choice keys only off p's own identity. Humans
                -- decide interactively.)
                local aiWant = (p.identity == "boss" or p.identity == "loyal")
                if game:askYesNo(p, "【服务挂了】令全场各弃1张牌？", aiWant) then
                    for _, q in ipairs(game:aliveSeatsInOrder()) do
                        if #q.hand > 0 then
                            local c = q.isHuman and game:askCard(q, q.hand, "【服务挂了】弃1张", false)
                                or q.hand[game.rng:int(1, #q.hand)]
                            game:discardCards(q, { c }, "服务挂了")
                        end
                    end
                end
            end,
            actives = {
                {
                    id = "reboot", name = "重启试试",
                    canUse = function(game, p) return not p.used.reboot and #p.hand > 0 and p.hp < p.maxHp end,
                    run = function(game, p)
                        p.used.reboot = true
                        local n = #p.hand
                        local all = {}
                        for _, c in ipairs(p.hand) do all[#all + 1] = c end
                        game:discardCards(p, all, "重启试试")
                        game:heal(p, 1, "重启试试")
                        game:draw(p, n, "重启试试")
                    end,
                },
            },
        },
    },
    {
        id = 7, name = "周模型", title = "算法工程师", faction = "互联网", maxHp = 3,
        s1 = "跑个A/B：出牌阶段限一次，展示牌堆顶2张，选1获得。",
        s2 = "数据驱动：使用【加班】时，可令目标额外弃1张牌。",
        skills = {
            onUseAttack = function(game, p, ctx)
                local t = ctx.target
                if t and #t.hand > 0 then
                    if game:askYesNo(p, string.format("【数据驱动】令 %s 额外弃1张牌？", t.name)) then
                        local c = t.hand[game.rng:int(1, #t.hand)]
                        game:discardCards(t, { c }, "数据驱动")
                    end
                end
            end,
            actives = {
                {
                    id = "abtest", name = "跑个A/B",
                    canUse = function(game, p) return not p.used.abtest end,
                    run = function(game, p)
                        p.used.abtest = true
                        game:reshuffleIfNeeded(2)
                        local a = table.remove(game.deck)
                        local b = table.remove(game.deck)
                        if not a then return end
                        local opts, list = {}, {}
                        opts[1] = cards.label(a); list[1] = a
                        if b then opts[2] = cards.label(b); list[2] = b end
                        local idx = game:askOption(p, opts, "【跑个A/B】选择获得一张")
                        local got = list[idx] or a
                        p.hand[#p.hand + 1] = got
                        for _, c in ipairs(list) do if c ~= got then game:toDiscard(c) end end
                        game:logmsg("%s【跑个A/B】获得 %s", p.name, cards.label(got))
                    end,
                },
            },
        },
    },
    ----------------------------------------------------------------
    -- 管理 / 职能篇
    ----------------------------------------------------------------
    {
        id = 8, name = "孙盘点", title = "HR", faction = "管理", maxHp = 3,
        s1 = "人才盘点：出牌阶段限一次，查看一名角色身份牌。",
        s2 = "毕业通知：对精神值≤1的角色使用【毕业优化】时，伤害+1。",
        skills = {
            graduationBonus = true,
            actives = {
                {
                    id = "review", name = "人才盘点",
                    canUse = function(game, p) return not p.used.review end,
                    run = function(game, p)
                        local t = game:askTarget(p, aliveOthers(game, p), "查看谁的身份？", true)
                        if not t then return end
                        p.used.review = true
                        t._revealedTo = t._revealedTo or {}
                        t._revealedTo[p.id] = true
                        game:logmsg("%s 查看了 %s 的身份：【%s】", p.name, t.name, game.IDENTITY_CN[t.identity])
                    end,
                },
            },
        },
    },
    {
        id = 9, name = "吴报销", title = "财务", faction = "管理", maxHp = 3,
        s1 = "流程不对：其他角色使用锦囊牌时，可弃1张手牌令其无效（每回合一次）。",
        s2 = "下月打款：你可将红色手牌当【画饼】使用。",
        skills = {
            viewAs = function(game, p, card)
                if cards.isRed(card) then return { "peach" } end
            end,
            trickCounter = function(game, p, user, card, targets)
                if p.used.wrongProcess then return false end
                if #p.hand == 0 then return false end
                -- AI: only counter offensive single-target tricks on allies / self
                if not p.isHuman then
                    local bad = (card.name == "PUA" or card.name == "毕业优化" or card.name == "试用期考核")
                    local atP = false
                    for _, t in ipairs(targets) do if t.id == p.id then atP = true end end
                    if not (bad and atP) then return false end
                end
                if game:askYesNo(p, string.format("【流程不对】弃1张牌令 %s 的【%s】无效？", user.name, card.name)) then
                    p.used.wrongProcess = true
                    local c = p.isHuman and game:askCard(p, p.hand, "弃1张牌发动【流程不对】", false) or p.hand[1]
                    game:discardCards(p, { c }, "流程不对")
                    return true
                end
                return false
            end,
        },
    },
    {
        id = 10, name = "郑订饭", title = "行政", faction = "管理", maxHp = 3,
        s1 = "下午茶：出牌阶段限一次，令所有角色各回复1点精神值，然后你摸1张牌。",
        s2 = "会议室没了：你可将【拉会对齐】当【摸鱼】使用。",
        skills = {
            viewAs = function(game, p, card)
                if card.name == "拉会对齐" then return { "dodge" } end
            end,
            actives = {
                {
                    id = "teatime", name = "下午茶",
                    canUse = function(game, p) return not p.used.teatime end,
                    run = function(game, p)
                        p.used.teatime = true
                        for _, q in ipairs(game:aliveSeatsInOrder()) do game:heal(q, 1, "下午茶") end
                        game:draw(p, 1, "下午茶")
                    end,
                },
            },
        },
    },
    {
        id = 11, name = "马总", title = "老板", faction = "管理", maxHp = 5,
        s1 = "我简单说两句：摸牌阶段可多摸1张牌。",
        s2 = "狼性文化：你可将1张装备牌当【加班】使用。",
        skills = {
            drawNumMod = function(game, p, base) return base + 1 end,
            viewAs = function(game, p, card)
                if card.type == "equip" then return { "attack" } end
            end,
            convert = { { from = "equip", to = "加班" } },
        },
    },
    ----------------------------------------------------------------
    -- 业务 / 销售篇
    ----------------------------------------------------------------
    {
        id = 12, name = "冯闭环", title = "销售", faction = "业务", maxHp = 3,
        s1 = "资源置换：出牌阶段限一次，与一名角色交换1张手牌。",
        s2 = "签单了：使用【加班】造成伤害后，摸1张牌。",
        skills = {
            onDealDamage = function(game, p, victim, ctx)
                if ctx.card and ctx.card.subtype == "attack" then
                    game:draw(p, 1, "签单了")
                end
            end,
            actives = {
                {
                    id = "swap", name = "资源置换",
                    canUse = function(game, p) return not p.used.swap and #p.hand > 0 end,
                    run = function(game, p)
                        local cands = {}
                        for _, q in ipairs(aliveOthers(game, p)) do if #q.hand > 0 then cands[#cands + 1] = q end end
                        local t = game:askTarget(p, cands, "【资源置换】与谁交换1张手牌？", true)
                        if not t then return end
                        p.used.swap = true
                        local mine = game:askCard(p, p.hand, "交出哪张牌？", false) or p.hand[1]
                        local theirs = t.hand[game.rng:int(1, #t.hand)]
                        game:removeFromHand(p, mine); game:removeFromHand(t, theirs)
                        p.hand[#p.hand + 1] = theirs
                        t.hand[#t.hand + 1] = mine
                        game:logmsg("%s 与 %s 交换了1张手牌", p.name, t.name)
                    end,
                },
            },
        },
    },
    {
        id = 13, name = "楚抓手", title = "市场", faction = "业务", maxHp = 3,
        s1 = "找到抓手：出牌阶段限一次，声明一种基本牌名，亮牌堆顶1张，若一致则获得。",
        s2 = "赋能业务：你可将【OKR对齐】当【升职加薪】使用。",
        skills = {
            convert = { { from = "OKR对齐", to = "升职加薪" } },
            actives = {
                {
                    id = "grip", name = "找到抓手",
                    canUse = function(game, p) return not p.used.grip end,
                    run = function(game, p)
                        p.used.grip = true
                        local names = { "加班", "摸鱼", "画饼", "卷一下" }
                        local idx = game:askOption(p, names, "【找到抓手】声明一种基本牌")
                        local declared = names[idx]
                        game:reshuffleIfNeeded(1)
                        local top = table.remove(game.deck)
                        if not top then return end
                        game:logmsg("%s 声明【%s】，亮出 %s", p.name, declared, cards.label(top))
                        if top.name == declared then
                            p.hand[#p.hand + 1] = top
                            game:logmsg("命中！%s 获得该牌", p.name)
                        else
                            game:toDiscard(top)
                        end
                    end,
                },
            },
        },
    },
    {
        id = 14, name = "何爆款", title = "新媒体运营", faction = "业务", maxHp = 3,
        s1 = "十万加：打出或使用牌时可展示之，若为红色则摸1张牌（每回合两次）。",
        s2 = "追热点：你的回合外失去手牌时，可摸1张牌（简化：受到伤害后摸1张）。",
        skills = {
            onPlayCard = function(game, p, card)
                -- 每回合两次：count in `used` (resets every turn for ALL players) rather than
                -- `flags` (only wiped on the owner's own turn) — 十万加 fires reactively on
                -- others' turns (摸鱼/救援画饼), so a flags counter would span a whole round.
                p.used.viralCount = p.used.viralCount or 0
                if p.used.viralCount < 2 and cards.isRed(card) then
                    p.used.viralCount = p.used.viralCount + 1
                    game:draw(p, 1, "十万加")
                end
            end,
            -- 追热点（简化）：受到伤害后摸1张
            onTakeDamage = function(game, p, ctx)
                game:draw(p, 1, "追热点")
            end,
        },
    },
    ----------------------------------------------------------------
    -- 求职 / 特殊身份篇
    ----------------------------------------------------------------
    {
        id = 15, name = "林简历", title = "求职者", faction = "求职", maxHp = 3,
        s1 = "海投：摸牌阶段可多摸2张牌，然后弃1张。",
        s2 = "面议：成为【加班】目标时，可展示手牌，若无【摸鱼】则此【加班】无效。",
        skills = {
            drawNumMod = function(game, p, base)
                if game:askYesNo(p, "【海投】多摸2张然后弃1张？") then
                    p.flags._seaApply = true
                    return base + 2
                end
                return base
            end,
            afterDraw = function(game, p)
                if p.flags._seaApply then
                    p.flags._seaApply = nil
                    if #p.hand > 0 then
                        local c = game:askCard(p, p.hand, "【海投】弃1张牌", false) or p.hand[1]
                        game:discardCards(p, { c }, "海投")
                    end
                end
            end,
            -- 面议: no per-round limit — fires every time targeted while holding no 摸鱼
            onTargetedByAttack = function(game, p, ctx)
                local hasDodge = false
                for _, c in ipairs(p.hand) do if c.subtype == "dodge" then hasDodge = true break end end
                if not hasDodge then
                    if game:askYesNo(p, "【面议】展示手牌（无摸鱼）令此【加班】无效？") then
                        game:logmsg("%s【面议】：手牌无【摸鱼】，【加班】无效", p.name)
                        return "cancel"
                    end
                end
            end,
        },
    },
    {
        id = 16, name = "钟八股", title = "面试官", faction = "求职", maxHp = 3,
        s1 = "考察一下：出牌阶段限一次，令一名角色展示其1张手牌。",
        s2 = "回去等通知：你可将黑色手牌当【PUA】使用。",
        skills = {
            convert = { { from = "blackBasic", to = "PUA" } },
            actives = {
                {
                    id = "interview", name = "考察一下",
                    canUse = function(game, p) return not p.used.interview end,
                    run = function(game, p)
                        local cands = {}
                        for _, q in ipairs(aliveOthers(game, p)) do if #q.hand > 0 then cands[#cands + 1] = q end end
                        local t = game:askTarget(p, cands, "【考察一下】令谁展示1张手牌？", true)
                        if not t then return end
                        p.used.interview = true
                        local c = t.hand[game.rng:int(1, #t.hand)]
                        game:logmsg("%s 令 %s 展示了 %s", p.name, t.name, cards.label(c))
                    end,
                },
            },
        },
    },
    {
        id = 17, name = "田便宜", title = "实习生", faction = "求职", maxHp = 2,
        s1 = "转正焦虑：你的手牌上限+2。",
        s2 = "背锅侠：其他角色受到伤害时，你可代替其承受，然后摸2张牌。",
        skills = {
            handLimitMod = function(game, p) return 2 end,
            -- 背锅侠 handled by engine substitution hook: onOthersDamage
            onOthersDamage = function(game, p, ctx)
                if ctx.target.id == p.id or not p.alive then return false end
                -- AI: only sacrifice to save an ally that is about to die
                local aiYes = (p.hp > 1 and ctx.target.hp <= 1)
                if game:askYesNo(p, string.format("【背锅侠】替 %s 承受伤害并摸2张？", ctx.target.name), aiYes) then
                    ctx.target = p
                    p.stats.blame = p.stats.blame + 1
                    game:logmsg("%s【背锅侠】替人受过", p.name)
                    game:draw(p, 2, "背锅侠")
                    return true
                end
                return false
            end,
        },
    },
    {
        id = 18, name = "黄派遣", title = "外包人员", faction = "求职", maxHp = 4,
        s1 = "同工不同酬：摸牌阶段少摸1张牌。",
        s2 = "随时退场：受到伤害后，可令伤害来源弃1张牌。",
        skills = {
            drawNumMod = function(game, p, base) return base - 1 end,
            onTakeDamage = function(game, p, ctx)
                local src = ctx.source
                if src and src.alive and #src.hand > 0 then
                    if game:askYesNo(p, string.format("【随时退场】令 %s 弃1张牌？", src.name)) then
                        local c = src.hand[game.rng:int(1, #src.hand)]
                        game:discardCards(src, { c }, "随时退场")
                    end
                end
            end,
        },
    },
    ----------------------------------------------------------------
    -- 进阶 / 名场面篇
    ----------------------------------------------------------------
    {
        id = 19, name = "周996", title = "卷王", faction = "名场面", maxHp = 3,
        s1 = "福报：摸牌阶段可少摸1张，然后本回合使用【加班】无次数限制。",
        s2 = "打卡冠军：回合结束时，若本回合造成过伤害，回复1点精神值。",
        skills = {
            drawNumMod = function(game, p, base)
                if game:askYesNo(p, "【福报】少摸1张，换本回合【加班】无限制？") then
                    p.flags.unlimitedAttack = true
                    return base - 1
                end
                return base
            end,
            onDealDamage = function(game, p, victim, ctx)
                p.flags._dealtDamage = true
            end,
            onTurnEnd = function(game, p)
                if p.flags._dealtDamage then game:heal(p, 1, "打卡冠军") end
            end,
        },
    },
    {
        id = 20, name = "徐带薪", title = "摸鱼大师", faction = "名场面", maxHp = 3,
        s1 = "带薪拉屎：跳过你的摸牌阶段，回复1点精神值。",
        s2 = "老板来了：成为【加班】目标时，可弃1张牌令此伤害-1。",
        skills = {
            drawNumMod = function(game, p, base)
                if p.hp < p.maxHp and game:askYesNo(p, "【带薪拉屎】跳过摸牌，回复1点精神值？") then
                    game:heal(p, 1, "带薪拉屎")
                    return "skip"
                end
                return base
            end,
            onTargetedByAttack = function(game, p, ctx)
                if #p.hand > 0 and game:askYesNo(p, "【老板来了】弃1张牌令伤害-1？") then
                    local c = p.isHuman and game:askCard(p, p.hand, "弃1张牌", false) or p.hand[1]
                    game:discardCards(p, { c }, "老板来了")
                    ctx.amount = math.max(0, (ctx.amount or 1) - 1)
                end
            end,
        },
    },
    {
        id = 21, name = "朱变现", title = "副业博主", faction = "名场面", maxHp = 3,
        s1 = "接私活：弃牌阶段可少弃1张牌（手牌上限+1）。",
        s2 = "流量变现（简化）：摸牌后可交给一名其他角色1张牌，然后你摸1张牌。",
        skills = {
            handLimitMod = function(game, p) return 1 end,
            afterDraw = function(game, p)
                if #p.hand == 0 then return end
                if game:askYesNo(p, "【流量变现】交给一名其他角色1张牌，然后你摸1张？", false) then
                    local t = game:askTarget(p, aliveOthers(game, p), "交给谁？", true, "ally")
                    if not t then return end
                    local c = game:askCard(p, p.hand, "交出哪张牌？", false, "discard") or p.hand[1]
                    game:removeFromHand(p, c)
                    t.hand[#t.hand + 1] = c
                    game:logmsg("%s【流量变现】给 %s 1张牌", p.name, t.name)
                    game:draw(p, 1, "流量变现")
                end
            end,
        },
    },
    {
        id = 22, name = "吴年限", title = "老油条", faction = "名场面", maxHp = 4,
        s1 = "流程熟悉：你可将任意基本牌当【摸鱼】使用。",
        s2 = "年限护身：受到伤害后，可判定，若为红色则伤害来源弃1张牌。",
        skills = {
            viewAs = function(game, p, card)
                if card.type == "basic" then return { "dodge" } end
            end,
            onTakeDamage = function(game, p, ctx)
                local src = ctx.source
                if src and src.alive and game:askYesNo(p, "【年限护身】判定，若红则来源弃1张？") then
                    local j = game:judge(p, "年限护身")
                    if j and cards.isRed(j) and #src.hand > 0 then
                        local c = src.hand[game.rng:int(1, #src.hand)]
                        game:discardCards(src, { c }, "年限护身")
                    end
                end
            end,
        },
    },
    {
        id = 23, name = "郑信仰", title = "精神股东", faction = "名场面", maxHp = 3,
        s1 = "与公司共成长：老板受到伤害后，你可失去1点精神值令该伤害无效（简化：老板受伤后你失1点为其回复1点）。",
        s2 = "期权激励：你阵亡时，可令一名角色摸3张牌。",
        skills = {
            -- engine calls onAllyDamage for boss damage (simplified compensation)
            onBossDamaged = function(game, p, boss, ctx)
                if p.alive and p.id ~= boss.id and p.hp > 1 then
                    if game:askYesNo(p, "【与公司共成长】失去1点精神值，为老板回复1点？", false) then
                        game:loseHp(p, 1, "与公司共成长")
                        game:heal(boss, 1, "与公司共成长")
                    end
                end
            end,
            onDeath = function(game, p, source)
                -- a support skill: reward an ally, so hint "ally" (an AI must not hand the
                -- 3 cards to its worst enemy — the "enemy" default did exactly that).
                local t = game:askTarget(p, game:aliveSeatsInOrder(), "【期权激励】令谁摸3张牌？", true, "ally")
                if t then game:draw(t, 3, "期权激励") end
            end,
        },
    },
    {
        id = 24, name = "罗法援", title = "仲裁侠", faction = "名场面", maxHp = 3,
        s1 = "N+1：对一名角色造成伤害后，可获得其1张手牌。",
        s2 = "劳动仲裁：进入濒死状态时，可令伤害来源失去2点精神值。",
        skills = {
            onDealDamage = function(game, p, victim, ctx)
                if victim.alive and #victim.hand > 0 then
                    if game:askYesNo(p, string.format("【N+1】获得 %s 的1张手牌？", victim.name)) then
                        local c = victim.hand[game.rng:int(1, #victim.hand)]
                        game:removeFromHand(victim, c)
                        p.hand[#p.hand + 1] = c
                        game:logmsg("%s【N+1】获得 %s 的1张手牌", p.name, victim.name)
                    end
                end
            end,
            onDying = function(game, p, source)
                if source and source.alive and source.id ~= p.id then
                    if game:askYesNo(p, string.format("【劳动仲裁】令 %s 失去2点精神值？", source.name)) then
                        game:loseHp(source, 2, "劳动仲裁")
                    end
                end
            end,
        },
    },
}

return C
