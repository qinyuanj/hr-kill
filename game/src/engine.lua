-- engine.lua — the 《职海杀》 rules engine.
--
-- Design: the whole game runs inside a Lua coroutine (Engine:start / Engine:run).
-- Whenever a decision is needed from *any* player the engine calls self:ask(req)
-- which yields a request object out to the driver (UI for humans, AI for bots).
-- The driver resolves it and resumes the coroutine with an answer. This keeps the
-- rules code linear and identical for human and AI players, and lets us run fully
-- headless (see headless.lua) for testing without love2d.
--
-- No `love` dependency lives in this file.

local util  = require("src.util")
local cards = require("src.cards")

local Engine = {}
Engine.__index = Engine

----------------------------------------------------------------------
-- Identity configuration by player count (from 主策划案 §4.1)
----------------------------------------------------------------------
-- boss=老板, loyal=嫡系, rebel=摸鱼党, spy=反骨仔
local IDENTITY_CONFIG = {
    [4] = { boss = 1, loyal = 1, rebel = 1, spy = 1 },
    [5] = { boss = 1, loyal = 1, rebel = 2, spy = 1 },
    [6] = { boss = 1, loyal = 1, rebel = 3, spy = 1 },
    [7] = { boss = 1, loyal = 2, rebel = 3, spy = 1 },
    [8] = { boss = 1, loyal = 2, rebel = 4, spy = 1 },
}

Engine.IDENTITY_CN = { boss = "老板", loyal = "嫡系", rebel = "摸鱼党", spy = "反骨仔" }

-- Fixed equipment-slot order. Iterating a player's `equip` map with pairs() would
-- visit slots in hash order, which Lua randomizes per process — that changes the
-- order cards hit the discard pile (and thus the post-reshuffle draw order), making
-- a seeded game non-reproducible. Always iterate slots through this list instead.
Engine.EQUIP_SLOTS = { "weapon", "armor", "plusHorse", "minusHorse", "treasure" }

----------------------------------------------------------------------
-- Construction / setup
----------------------------------------------------------------------
function Engine.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Engine)
    self.rng = util.newRng(opts.seed or 12345)
    self.numPlayers = opts.numPlayers or 6
    self.humanSeat = opts.humanSeat or 1   -- 1-based seat that is the human, or nil for all-AI
    self.log = {}
    self.maxLog = 400
    self.winner = nil          -- "boss" | "rebel" | "spy"
    self.phase = "setup"
    self.turnCount = 0
    self.deck = {}
    self.discard = {}
    self.players = {}
    self.allCharacters = opts.characters  -- list of character tables (required)
    self._co = nil
    self:setup(opts)
    return self
end

function Engine:logmsg(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    self.log[#self.log + 1] = msg
    if #self.log > self.maxLog then table.remove(self.log, 1) end
end

function Engine:setup(opts)
    local n = self.numPlayers
    local cfg = IDENTITY_CONFIG[n]
    assert(cfg, "unsupported player count: " .. tostring(n))

    -- Build identity bag, but boss is always seat 1's? No — boss公开 and can be any seat.
    local ids = {}
    for _ = 1, cfg.boss do ids[#ids + 1] = "boss" end
    for _ = 1, cfg.loyal do ids[#ids + 1] = "loyal" end
    for _ = 1, cfg.rebel do ids[#ids + 1] = "rebel" end
    for _ = 1, cfg.spy do ids[#ids + 1] = "spy" end
    self.rng:shuffle(ids)

    -- How out-numbered the boss is: (rebels+spies) − (boss-team). Drives both the
    -- survivability bonus below and the opening-hand size. Per table: 4p=0, 5p=1,
    -- 6p=2, 7p=1, 8p=2 — only the 4p table is NOT out-numbered.
    local bossDeficit = (cfg.rebel + cfg.spy) - (1 + cfg.loyal)
    -- At 4p the boss gets no survivability bonus yet its coordination + first-move edge
    -- over-performs (~55% boss-team), so it opens with one fewer card to pull it to ~50%.
    local bossStartCards = (bossDeficit <= 0) and 3 or 4

    -- Character pool: shuffle a copy, deal one to each player.
    local pool = {}
    for i = 1, #self.allCharacters do pool[i] = self.allCharacters[i] end
    self.rng:shuffle(pool)

    for seat = 1, n do
        local char = pool[seat]
        -- 主公技: the lone boss is out-numbered, so grant bonuses that scale with the
        -- table size, keeping a random-character boss survivable without touching skills.
        -- Two levers, tuned empirically (see test/balance.lua):
        --   • HP cushion = max(0, rebel-2)  ── boss-team AI is competent (it no longer
        --     own-goals), so the cushion is one less than it once needed.
        --   • a per-turn extra draw for the most lop-sided tables (deficit ≥ 2);
        --     HP alone just makes those grind, card advantage is what wins them.
        -- The deficit-1 tables (5p, 7p) would be over-buffed by a per-turn draw, so they
        -- instead get +1 HP — empirically the lowest-winning tables otherwise.
        -- At 4p the boss is NOT out-numbered (deficit 0): it gets no cushion and opens a
        -- card short, while the lone 摸鱼党 — the role the boss-team's coordination crushes
        -- there — gets +1 HP to push back toward ~50%.
        -- NET per table ─ 4p: boss +0HP/−1 card, rebel +1HP · 5p: +1HP · 6p: +1HP & +1 draw ·
        --                 7p: +2HP · 8p: +2HP & +1 draw.
        local hpBonus, bossDrawBonus = 0, 0
        if ids[seat] == "boss" then
            hpBonus = math.max(0, cfg.rebel - 2)
            bossDrawBonus = (bossDeficit >= 2) and 1 or 0
            if bossDeficit == 1 then hpBonus = hpBonus + 1 end
            local override = tonumber(os.getenv("ZHS_BOSS_BONUS"))
            if override then hpBonus = override end
        elseif ids[seat] == "rebel" and bossDeficit <= 0 then
            hpBonus = 1
        end
        local p = {
            id = seat,
            seat = seat,
            name = (seat == self.humanSeat) and "你" or ("玩家" .. seat),
            isHuman = (seat == self.humanSeat),
            char = char,
            identity = ids[seat],
            maxHp = char.maxHp + hpBonus,
            hp = char.maxHp + hpBonus,
            bossDrawBonus = bossDrawBonus,
            hand = {},
            equip = { weapon = nil, armor = nil, plusHorse = nil, minusHorse = nil, treasure = nil },
            delayed = {},          -- delayed trick cards placed in front (e.g. 试用期考核)
            alive = true,
            revealed = false,      -- whether identity is shown (boss always shown)
            used = {},             -- per-turn skill / equip usage flags
            flags = {},            -- per-turn flags (wine, skipDraw, ...)
            armorUsedThisTurn = false,
            -- end-of-game「职场报告」counters (GDD §8.4)
            stats = { overtimeOut = 0, overtimeIn = 0, pua = 0, pie = 0,
                      blame = 0, dmgDealt = 0, dmgTaken = 0, kills = 0 },
        }
        if p.identity == "boss" then
            p.revealed = true
            p.name = p.isHuman and "你(老板)" or ("老板" .. seat)
        end
        self.players[seat] = p
    end

    -- Build & deal deck.
    self.deck = cards.buildDeck(self.rng)
    for _, p in ipairs(self.players) do
        self:drawRaw(p, p.identity == "boss" and bossStartCards or 4)
    end

    -- First turn starts with the boss player.
    self.startSeat = self:findBossSeat()
    self.phase = "ready"
    self:logmsg("=== 《职海杀》开局 · %d 人局 ===", n)
    for _, p in ipairs(self.players) do
        if p.identity == "boss" then
            self:logmsg("%s 是【老板】（%s·%s），精神值 %d", p.name, p.char.title, p.char.name, p.maxHp)
        end
    end
end

function Engine:findBossSeat()
    for _, p in ipairs(self.players) do
        if p.identity == "boss" then return p.seat end
    end
    return 1
end

function Engine:bossPlayer()
    return self.players[self:findBossSeat()]
end

-- Resolve a player by their STABLE id. After 空降高管 rotates seats, self.players is
-- re-keyed by seat while ids stay fixed, so id != seat — never index self.players by an
-- id. All request answers / targetIds / dyingId are ids, so they MUST go through here.
function Engine:playerById(id)
    for _, p in ipairs(self.players) do
        if p.id == id then return p end
    end
    return nil
end

----------------------------------------------------------------------
-- Coroutine driver interface
----------------------------------------------------------------------
function Engine:start()
    self._co = coroutine.create(function() self:run() end)
end

-- Resume the game with an answer to the last request. Returns the next request,
-- or nil when the coroutine finished (game over).
function Engine:resume(answer)
    if not self._co then return nil end
    local ok, req = coroutine.resume(self._co, answer)
    if not ok then
        error("engine coroutine error: " .. tostring(req))
    end
    if coroutine.status(self._co) == "dead" then
        self._co = nil
        return nil
    end
    return req
end

-- Yield a decision request out to the driver and return the resolved answer.
function Engine:ask(req)
    return coroutine.yield(req)
end

----------------------------------------------------------------------
-- Skill hook dispatch.
-- A character defines `skills` (a table) with optional hook functions.
-- We call them as fn(game, player, ...). Triggered hooks may themselves ask().
----------------------------------------------------------------------
function Engine:trig(player, hook, ...)
    if not player or not player.char or not player.char.skills then return nil end
    local fn = player.char.skills[hook]
    if fn then return fn(self, player, ...) end
    return nil
end

-- Trigger a hook on every alive player (used for global passives if needed).
function Engine:trigAll(hook, ...)
    for _, p in ipairs(self:aliveInTurnOrderFrom(self.current)) do
        self:trig(p, hook, ...)
    end
end

----------------------------------------------------------------------
-- Deck / hand operations
----------------------------------------------------------------------
function Engine:reshuffleIfNeeded(n)
    if #self.deck >= n then return end
    -- recycle discard pile
    if #self.discard == 0 then return end
    for i = 1, #self.discard do self.deck[#self.deck + 1] = self.discard[i] end
    self.discard = {}
    self.rng:shuffle(self.deck)
    self:logmsg("（牌堆已洗牌）")
end

-- low-level draw with no skill triggers
function Engine:drawRaw(player, n)
    local drawn = {}
    for _ = 1, n do
        self:reshuffleIfNeeded(1)
        local card = table.remove(self.deck)
        if not card then break end
        player.hand[#player.hand + 1] = card
        drawn[#drawn + 1] = card
    end
    return drawn
end

function Engine:draw(player, n, reason)
    local drawn = self:drawRaw(player, n)
    if #drawn > 0 then
        self:logmsg("%s 摸 %d 张牌%s", player.name, #drawn, reason and ("（" .. reason .. "）") or "")
    end
    return drawn
end

function Engine:findCard(player, cardId)
    for i, c in ipairs(player.hand) do
        if c.id == cardId then return c, i end
    end
    return nil
end

function Engine:removeFromHand(player, card)
    for i, c in ipairs(player.hand) do
        if c.id == card.id then
            table.remove(player.hand, i)
            return true
        end
    end
    return false
end

function Engine:toDiscard(card)
    self.discard[#self.discard + 1] = card
end

-- Discard specific cards from hand to the discard pile.
function Engine:discardCards(player, cardList, reason)
    local names = {}
    for _, c in ipairs(cardList) do
        self:removeFromHand(player, c)
        self:toDiscard(c)
        names[#names + 1] = cards.label(c)
    end
    if #names > 0 then
        self:logmsg("%s 弃置 %s%s", player.name, table.concat(names, "、"),
            reason and ("（" .. reason .. "）") or "")
    end
end

----------------------------------------------------------------------
-- Distance & range
----------------------------------------------------------------------
function Engine:aliveSeatsInOrder()
    local out = {}
    for seat = 1, self.numPlayers do
        if self.players[seat].alive then out[#out + 1] = self.players[seat] end
    end
    return out
end

-- alive players starting from `from` (a player) going clockwise (increasing seat, wrapping)
function Engine:aliveInTurnOrderFrom(from)
    local alive = self:aliveSeatsInOrder()
    if #alive == 0 then return {} end
    local startIdx = 1
    for i, p in ipairs(alive) do
        if from and p.id == from.id then startIdx = i break end
    end
    local out = {}
    for k = 0, #alive - 1 do
        out[#out + 1] = alive[((startIdx - 1 + k) % #alive) + 1]
    end
    return out
end

function Engine:ringDistance(a, b)
    if a.id == b.id then return 0 end
    local alive = self:aliveSeatsInOrder()
    local n = #alive
    local ia, ib
    for i, p in ipairs(alive) do
        if p.id == a.id then ia = i end
        if p.id == b.id then ib = i end
    end
    if not ia or not ib then return 99 end
    local d = math.abs(ia - ib)
    return math.min(d, n - d)
end

function Engine:distance(a, b)
    local d = self:ringDistance(a, b)
    if b.equip.plusHorse then d = d + 1 end   -- harder to reach b
    if a.equip.minusHorse then d = d - 1 end  -- a reaches further
    if d < 1 then d = 1 end
    return d
end

function Engine:attackRange(player)
    if player.equip.weapon and player.equip.weapon.range then
        return player.equip.weapon.range
    end
    return 1
end

function Engine:canReach(a, b)
    return self:distance(a, b) <= self:attackRange(a)
end

----------------------------------------------------------------------
-- Hand limit
----------------------------------------------------------------------
function Engine:handLimit(player)
    local limit = player.hp
    if player.equip.armor and player.equip.armor.name == "独立办公室" then limit = limit + 2 end
    if player.equip.treasure and player.equip.treasure.name == "股权激励书" then
        limit = limit + (player.identity == "boss" and 2 or -1)
    end
    local mod = self:trig(player, "handLimitMod") or 0
    limit = limit + mod
    if player.flags.handLimitBonus then limit = limit + player.flags.handLimitBonus end
    if limit < 0 then limit = 0 end
    return limit
end

----------------------------------------------------------------------
-- View-as: which extra "roles" a card can be used as, via skills/equipment.
-- Returns a set-like table { dodge=true, peach=true, attack=true, ... }
----------------------------------------------------------------------
function Engine:viewAs(player, card)
    local set = {}
    local fn = player.char.skills and player.char.skills.viewAs
    if fn then
        local list = fn(self, player, card)
        if list then for _, s in ipairs(list) do set[s] = true end end
    end
    return set
end

-- Can `card` (from player's hand) act as the given subtype right now?
function Engine:cardActsAs(player, card, subtype)
    if card.subtype == subtype then return true end
    local va = self:viewAs(player, card)
    return va[subtype] == true
end

-- All hand cards usable as the given subtype.
function Engine:handCardsAs(player, subtype)
    return util.filter(player.hand, function(c) return self:cardActsAs(player, c, subtype) end)
end

----------------------------------------------------------------------
-- Asking helpers (thin wrappers around :ask)
----------------------------------------------------------------------
-- Ask a player to optionally provide a card (by id) from a candidate list.
-- candidates: list of cards. Returns the chosen card or nil.
-- hint guides the AI: "discard" (give up worst), "use"/"gain" (use best).
function Engine:askCard(player, candidates, prompt, optional, hint, extra)
    if #candidates == 0 then return nil end
    local ids = util.map(candidates, function(c) return c.id end)
    local req = {
        kind = "chooseCard", player = player, candidates = ids,
        prompt = prompt, optional = optional ~= false, hint = hint or "discard",
    }
    if extra then for k, v in pairs(extra) do req[k] = v end end
    local ans = self:ask(req)
    if ans == nil then return nil end
    for _, c in ipairs(candidates) do if c.id == ans then return c end end
    return nil
end

-- Ask a player to choose a target player from candidates (list of players).
-- hint guides the AI: "enemy" | "ally" | "self" | "any".
function Engine:askTarget(player, candidates, prompt, optional, hint)
    if #candidates == 0 then return nil end
    local ids = util.map(candidates, function(p) return p.id end)
    local ans = self:ask({
        kind = "chooseTarget", player = player, candidates = ids,
        prompt = prompt, optional = optional == true, hint = hint or "enemy",
    })
    if ans == nil then return nil end
    return self:playerById(ans)
end

-- Ask a player to choose among string options. Returns 1-based index.
-- aiChoice: index the AI should default to.
function Engine:askOption(player, options, prompt, aiChoice)
    local ans = self:ask({ kind = "chooseOption", player = player, options = options,
        prompt = prompt, aiChoice = aiChoice or 1 })
    return ans or 1
end

-- aiYes: what an AI should answer (defaults to true — most "may" skills are beneficial).
function Engine:askYesNo(player, prompt, aiYes)
    if aiYes == nil then aiYes = true end
    local idx = self:askOption(player, { "是", "否" }, prompt, aiYes and 1 or 2)
    return idx == 1
end

----------------------------------------------------------------------
-- Judgement (判定): flip the top card. Some skills can change it.
----------------------------------------------------------------------
function Engine:judge(player, reason)
    self:reshuffleIfNeeded(1)
    local card = table.remove(self.deck)
    if not card then return nil end
    self:logmsg("%s 判定%s → %s", player.name, reason and ("（" .. reason .. "）") or "", cards.label(card))
    self:toDiscard(card)
    return card
end

----------------------------------------------------------------------
-- Visual-effect events. The UI registers `game.onEvent`; headless leaves it nil
-- so this is a no-op outside love2d. Used to drive floating numbers / attack lines.
----------------------------------------------------------------------
function Engine:emit(ev)
    if self.onEvent then self.onEvent(ev) end
end

-- Visual hook for a (non-attack) card being played: drives a floating card-name label
-- over the source and, for a single targeted trick, a tinted source→target line. Attacks
-- already have their own "attack" animation, so they don't call this. No-op headless.
function Engine:emitPlay(source, card, target)
    self:emit({ type = "cardPlayed", source = source.id, name = card.name,
        cardType = card.type, subtype = card.subtype,
        target = (target and target.id ~= source.id) and target.id or nil })
end

----------------------------------------------------------------------
-- Damage / healing / dying / death
----------------------------------------------------------------------
-- ctx: { source, target, amount, nature, card, dodgeable, cleave }
function Engine:dealDamage(ctx)
    -- damage redirection happens before the hit lands (背锅 card / 实习生 背锅侠)
    self:maybeSubstituteDamage(ctx)

    local target = ctx.target
    -- armor: 人体工学椅 once per turn -1, only against real 加班 card damage (ctx.card is
    -- nil for PUA/毕业优化/skill hits). Applied here, after redirection, against the
    -- player who takes the hit — and only that player's per-turn flag is consumed.
    if ctx.card and not ctx.ignoreArmor and target.equip.armor and target.equip.armor.name == "人体工学椅"
        and not target.armorUsedThisTurn and (ctx.amount or 0) > 0 then
        target.armorUsedThisTurn = true
        ctx.amount = ctx.amount - 1
        self:logmsg("%s 的【人体工学椅】减免 1 点伤害", target.name)
    end
    local amount = math.max(0, ctx.amount or 1)
    if amount == 0 or not target.alive then return end
    target.hp = target.hp - amount
    self:logmsg("%s 受到 %d 点伤害%s（精神值 %d/%d）", target.name, amount,
        ctx.source and ("，来源 " .. ctx.source.name) or "", math.max(target.hp, 0), target.maxHp)
    self:emit({ type = "damage", target = target.id, amount = amount })
    target.stats.dmgTaken = target.stats.dmgTaken + amount
    if ctx.source and ctx.source.id ~= target.id then
        ctx.source.stats.dmgDealt = ctx.source.stats.dmgDealt + amount
    end

    -- triggers: dealer then taker
    if ctx.source and ctx.source.alive then self:trig(ctx.source, "onDealDamage", target, ctx) end
    if target.alive then self:trig(target, "onTakeDamage", ctx) end

    -- threat tracking: remember who hurt the boss (used by boss/loyal AI focus-fire)
    if target.identity == "boss" and ctx.source and ctx.source.id ~= target.id then
        self.threat = self.threat or {}
        self.threat[ctx.source.id] = (self.threat[ctx.source.id] or 0) + 1
    end

    -- 精神股东 与公司共成长: boss-damage compensation
    if target.identity == "boss" and target.alive then
        for _, p in ipairs(self:aliveSeatsInOrder()) do
            self:trig(p, "onBossDamaged", target, ctx)
        end
    end

    if target.hp <= 0 then
        self:enterDying(target, ctx.source)
    end
end

-- 背锅 card (victim transfers damage) + 实习生 背锅侠 (substitute). One pass each.
function Engine:maybeSubstituteDamage(ctx)
    local victim = ctx.target
    -- 背锅 card: the victim may transfer this hit to someone else. Humans are always
    -- offered the choice; an AI victim only spends 背锅 on a (near-)lethal hit — one that
    -- would otherwise drop it into the dying zone — and picks the redirect target with the
    -- same identity-honest enemy heuristic it uses for attacks (boss-team never onto the
    -- boss, spy keeps the boss alive while it still wants to).
    if victim.alive then
        local backpan = nil
        for _, c in ipairs(victim.hand) do if c.name == "背锅" then backpan = c break end end
        if backpan then
            local others = {}
            for _, p in ipairs(self:aliveSeatsInOrder()) do
                if p.id ~= victim.id then others[#others + 1] = p end
            end
            local aiUse = (ctx.amount or 1) >= victim.hp
            if #others > 0 and self:askYesNo(victim, "使用【背锅】将伤害转移给他人？", aiUse) then
                local t = self:askTarget(victim, others, "【背锅】转移伤害给？", true, "enemy")
                if t then
                    self:removeFromHand(victim, backpan)
                    self:toDiscard(backpan)
                    self:logmsg("%s 使用【背锅】，伤害转移给 %s", victim.name, t.name)
                    victim.stats.blame = victim.stats.blame + 1
                    ctx.target = t
                end
            end
        end
    end
    -- 实习生 背锅侠: another player may take the hit instead.
    for _, p in ipairs(self:aliveSeatsInOrder()) do
        if p.char.skills and p.char.skills.onOthersDamage then
            if self:trig(p, "onOthersDamage", ctx) then break end
        end
    end
end

function Engine:loseHp(player, amount, reason)
    if not player.alive then return end
    player.hp = player.hp - amount
    self:logmsg("%s 失去 %d 点精神值%s（%d/%d）", player.name, amount,
        reason and ("（" .. reason .. "）") or "", math.max(player.hp, 0), player.maxHp)
    self:emit({ type = "damage", target = player.id, amount = amount })
    if player.hp <= 0 then self:enterDying(player, nil) end
end

function Engine:heal(player, amount, reason)
    if not player.alive then return end
    local before = player.hp
    player.hp = math.min(player.maxHp, player.hp + amount)
    if player.hp ~= before then
        self:logmsg("%s 回复 %d 点精神值%s（%d/%d）", player.name, player.hp - before,
            reason and ("（" .. reason .. "）") or "", player.hp, player.maxHp)
        self:emit({ type = "heal", target = player.id, amount = player.hp - before })
    end
end

function Engine:enterDying(target, source)
    self:trig(target, "onDying", source)
    if target.hp > 0 or not target.alive then return end
    self:logmsg("⚠ %s 进入濒死（burnout 边缘）！", target.name)
    -- ask players, starting from the dying player, in turn order, for 画饼 (peach)
    while target.hp <= 0 and target.alive do
        local rescued = false
        for _, rescuer in ipairs(self:aliveInTurnOrderFrom(target)) do
            while target.hp <= 0 do
                local peaches = self:peachOptions(rescuer)
                if #peaches == 0 then break end
                local needSelf = (rescuer.id == target.id)
                local prompt = needSelf and "你濒死，使用【画饼】自救？" or
                    string.format("%s 濒死，使用【画饼】施救？", target.name)
                local c = self:askCard(rescuer, peaches, prompt, true,
                    needSelf and "selfSave" or "allySave", { dyingId = target.id })
                if not c then break end
                self:usePeachCard(rescuer, c, target)
                rescued = true
            end
            if target.hp > 0 then break end
        end
        if not rescued then break end
    end
    if target.hp <= 0 then
        self:killPlayer(target, source)
    end
end

-- Cards a player can use as 画饼 right now (hand peaches + skill view-as +, once per
-- turn, ANY hand card via the 猎头联系方式 treasure).
function Engine:peachOptions(player)
    local opts = self:handCardsAs(player, "peach")
    if player.equip.treasure and player.equip.treasure.name == "猎头联系方式"
        and not player.used.headhunter then
        local seen = {}
        for _, c in ipairs(opts) do seen[c.id] = true end
        for _, c in ipairs(player.hand) do
            if not seen[c.id] then opts[#opts + 1] = c end   -- treasure: any card → 画饼
        end
    end
    return opts
end

function Engine:usePeachCard(player, card, target)
    -- if the card isn't already a 画饼 (native or skill view-as) it's the 猎头联系方式
    -- once-per-turn conversion — spend that budget.
    local viaTreasure = not self:cardActsAs(player, card, "peach")
    self:removeFromHand(player, card)
    self:toDiscard(card)
    player.stats.pie = player.stats.pie + 1
    if viaTreasure then
        player.used.headhunter = true
        self:logmsg("%s 用【猎头联系方式】将 %s 当作【画饼】", player.name, cards.label(card))
    end
    local asName = (card.subtype == "peach") and "画饼" or (card.name .. "→画饼")
    self:logmsg("%s 使用 %s 为 %s 回复精神值", player.name, asName, target.name)
    -- 救援/濒死时使用【画饼】也是「使用牌」：触发 onPlayCard（如 新媒体 十万加）。
    self:trig(player, "onPlayCard", card)
    self:heal(target, 1, "画饼")
end

-- Discard every equipped card a player holds, clearing all slots. Fixed-order
-- (EQUIP_SLOTS) iteration keeps reshuffle/draw order reproducible across runs.
function Engine:discardAllEquip(player)
    for _, slot in ipairs(Engine.EQUIP_SLOTS) do
        local c = player.equip[slot]
        if c then self:toDiscard(c); player.equip[slot] = nil end
    end
end

function Engine:killPlayer(target, source)
    target.alive = false
    target.revealed = true
    self:logmsg("☠ %s【%s · %s·%s】阵亡！", target.name, self.IDENTITY_CN[target.identity],
        target.char.title, target.char.name)
    local pool = ({
        boss  = {
            "公司就此关张，大厦倾颓 🏚",
            "资金链断裂，黯然退场 💸",
            "曾经呼风唤雨，如今人去楼空 🌫",
        },
        loyal = {
            "尽忠到最后一刻，奈何大势已去 🥀",
            "陪老板走到终点，无怨无悔 🤝",
            "鞠躬尽瘁，工牌还热着呢 🕯",
        },
        rebel = {
            "摸鱼一时爽，被优化火葬场 🔥",
            "带薪划水的日子，到此为止 🏊",
            "终究没能熬到下班 🌙",
        },
        spy   = {
            "反骨仔的算盘，终究落了空 🧮",
            "两头下注，结果两头落空 🎲",
            "想当渔翁，却成了那条鱼 🐟",
        },
    })[target.identity]
    if pool then
        -- vary the line per game/seat WITHOUT consuming the game rng (keeps headless
        -- outcomes byte-identical): index off deterministic, already-advanced state.
        local idx = ((self.turnCount or 0) + (target.seat or 1)) % #pool + 1
        self:logmsg("　%s", pool[idx])
    end
    self:emit({ type = "death", target = target.id })

    self:trig(target, "onDeath", source)

    -- move all cards to discard
    for _, c in ipairs(target.hand) do self:toDiscard(c) end
    target.hand = {}
    self:discardAllEquip(target)
    for _, c in ipairs(target.delayed) do self:toDiscard(c) end
    target.delayed = {}

    -- rewards / punishment
    if source and source.alive and source.id ~= target.id then
        source.stats.kills = source.stats.kills + 1
        if target.identity == "rebel" then
            self:logmsg("%s 击杀【摸鱼党】，摸 3 张牌", source.name)
            self:draw(source, 3, "击杀奖励")
        elseif target.identity == "loyal" and source.identity == "boss" then
            self:logmsg("老板错杀【嫡系】，弃置全部手牌与装备！")
            local all = {}
            for _, c in ipairs(source.hand) do all[#all + 1] = c end
            self:discardCards(source, all, "错杀嫡系")
            self:discardAllEquip(source)
        end
        -- GDD §8.4: the 反骨仔 (spy) wins only by outlasting everyone and then soloing the
        -- boss, so it recovers 1 精神值 on any kill — identity-gated, never helps boss/rebel.
        if source.identity == "spy" and source.hp < source.maxHp then
            self:heal(source, 1, "反骨仔·赢家通吃")
        end
    end

    self:checkWin()
end

function Engine:checkWin()
    if self.winner then return end
    local boss = self:bossPlayer()
    if not boss.alive then
        local others = self:aliveSeatsInOrder()
        if #others == 1 and others[1].identity == "spy" then
            self.winner = "spy"
        else
            self.winner = "rebel"
        end
        self:logmsg("=== 游戏结束：%s 阵营胜利！===", self.IDENTITY_CN[self.winner == "spy" and "spy" or "rebel"])
        return
    end
    -- boss alive: boss/loyal win if no rebel or spy remains alive
    local threat = false
    for _, p in ipairs(self.players) do
        if p.alive and (p.identity == "rebel" or p.identity == "spy") then threat = true break end
    end
    if not threat then
        self.winner = "boss"
        self:logmsg("=== 游戏结束：老板阵营（老板+嫡系）胜利！===")
    end
end

-- Did the faction of `identity` win the resolved game? Canonical team-membership
-- rule (boss & loyal share the "boss" victory); callers must not re-derive it.
function Engine:identityWon(identity)
    local w = self.winner
    if not w then return false end
    if w == "boss" then return identity == "boss" or identity == "loyal" end
    return w == identity
end

----------------------------------------------------------------------
-- Dodge resolution (response to 加班 / dodgeable damage)
----------------------------------------------------------------------
-- Returns true if `target` produced a 摸鱼 (dodge succeeds).
function Engine:tryDodge(target, ctx)
    if not ctx.dodgeable then return false end
    -- skill: 求职者 面议 may force reveal; handled via onTargeted earlier setting flags.
    local dodges = self:handCardsAs(target, "dodge")
    if #dodges == 0 then return false end
    local prompt = string.format("%s 对你使用【%s】，打出【摸鱼】抵消？",
        ctx.source and ctx.source.name or "某人", ctx.card and ctx.card.name or "加班")
    local c = self:askCard(target, dodges, prompt, true, "dodge")
    if not c then return false end
    self:removeFromHand(target, c)
    self:toDiscard(c)
    local asName = (c.subtype == "dodge") and "摸鱼" or (c.name .. "→摸鱼")
    self:logmsg("%s 打出 %s 抵消", target.name, asName)
    -- 打出【摸鱼】也是「打出牌」：触发 onPlayCard（如 新媒体 十万加 展示红牌摸1）。
    self:trig(target, "onPlayCard", c)
    return true
end

----------------------------------------------------------------------
-- Attack (加班) and attack-like effects
----------------------------------------------------------------------
-- opts: { card, amount=1, dodgeable=true, fromSkill, ignoreArmor }
function Engine:performAttack(source, target, opts)
    opts = opts or {}
    local ctx = {
        source = source, target = target,
        amount = opts.amount or 1,
        nature = "normal", card = opts.card,
        dodgeable = opts.dodgeable ~= false,
        ignoreArmor = opts.ignoreArmor,
    }

    -- 加班-scoped on-attack skills fire ONLY for a real/converted 加班 card. PUA's forced
    -- hit and 毕业优化 route through performAttack with no card (ctx.card == nil) and must
    -- NOT trigger 数据驱动/这个很简单 (onUseAttack) or 面议/这是前端问题/老板来了 (onTargetedByAttack).
    -- (These hooks are all GDD-scoped to '使用/成为【加班】目标时'.)
    if ctx.card and ctx.card.subtype == "attack" then
        -- attacker pre-hit skills (数据驱动 extra discard, 这个很简单 no-dodge)
        self:trig(source, "onUseAttack", ctx)
        -- target on-targeted skills (这是前端问题 transfer; 面议 cancel; 老板来了 reduce)
        local r = self:trig(target, "onTargetedByAttack", ctx)
        if r == "cancel" or ctx.cancelled then
            self:logmsg("（本次【加班】被无效化）")
            return false
        end
        target = ctx.target   -- a transfer (这是前端问题) may have changed the target
    end
    self:emit({ type = "attack", source = source.id, target = target.id })
    if opts.card and opts.card.subtype == "attack" then
        target.stats.overtimeIn = target.stats.overtimeIn + 1
    end

    -- wine bonus
    if opts.card and source.flags.wine then
        ctx.amount = ctx.amount + 1
        source.flags.wine = nil
        self:logmsg("（卷一下：本次【加班】伤害+1）")
    end

    -- dodge
    if not ctx.noDodge and self:tryDodge(target, ctx) then
        self:trig(source, "onAttackDodged", ctx)
        return false
    end

    -- 人体工学椅 armor (-1) is applied inside dealDamage, AFTER 背锅/背锅侠 redirection,
    -- so the reduction follows whoever actually takes the hit (not the original target).
    self:dealDamage(ctx)

    -- weapon on-hit effects (only for a real 加班 card and if target still alive)
    if opts.card and target.alive and source.alive and source.equip.weapon then
        self:weaponOnHit(source, target)
    end
    return true
end

function Engine:weaponOnHit(source, target)
    local w = source.equip.weapon
    if not w then return end
    if w.name == "MacBook Pro" and #target.hand > 0 then
        if self:askYesNo(source, string.format("【MacBook Pro】命中，弃置 %s 1 张手牌？", target.name)) then
            local c = target.hand[self.rng:int(1, #target.hand)]
            self:removeFromHand(target, c)
            self:toDiscard(c)
            self:logmsg("%s 的【MacBook Pro】弃置了 %s 的 1 张手牌", source.name, target.name)
        end
    elseif w.name == "工牌" and #target.hand > 0 then
        self:logmsg("%s 的【工牌】查看了 %s 的手牌", source.name, target.name)
    end
end

----------------------------------------------------------------------
-- Per-turn attack budget
----------------------------------------------------------------------
function Engine:attackBudget(player)
    if player.flags.unlimitedAttack then return math.huge end
    local n = 1
    if player.equip.weapon and player.equip.weapon.name == "双屏显示器" then n = n + 1 end
    if player.flags.extraAttack then n = n + player.flags.extraAttack end
    return n
end

----------------------------------------------------------------------
-- Trick card effects
----------------------------------------------------------------------
local Tricks = {}

function Tricks.PUA(game, user, card, targets)
    local t = targets[1]
    t.stats.pua = t.stats.pua + 1
    local idx
    if #t.hand >= 2 then
        idx = game:askOption(t, { "弃2张手牌", "受到1点伤害" },
            string.format("%s 对你使用【PUA】", user.name))
    else
        idx = 2
    end
    if idx == 1 then
        game:promptDiscardN(t, 2, "PUA")
    else
        game:performAttack(user, t, { amount = 1, dodgeable = false, fromSkill = true })
    end
end

Tricks["升职加薪"] = function(game, user, card, targets)
    game:draw(user, 3, "升职加薪")
    user.flags.handLimitBonus = (user.flags.handLimitBonus or 0) + 2
end

Tricks["拉会对齐"] = function(game, user, card, targets)
    for _, p in ipairs(game:aliveInTurnOrderFrom(user)) do
        if p.id ~= user.id and game:trickAffects(user, card, p) then
            if #p.hand == 0 then
                p.skipDrawNext = true
                game:logmsg("%s 无牌可弃，下回合跳过摸牌", p.name)
            else
                local c = game:askCard(p, p.hand, "【拉会对齐】：弃1张手牌，否则下回合跳过摸牌", true)
                if c then
                    game:discardCards(p, { c }, "拉会对齐")
                else
                    p.skipDrawNext = true
                    game:logmsg("%s 选择跳过下回合摸牌", p.name)
                end
            end
        end
    end
end

Tricks["毕业优化"] = function(game, user, card, targets)
    local t = targets[1]
    local dmg = 2
    -- HR 毕业通知: +1 when user is HR
    if user.char.skills and user.char.skills.graduationBonus then dmg = dmg + 1 end
    game:performAttack(user, t, { amount = dmg, dodgeable = true, fromSkill = true })
end

Tricks["团建"] = function(game, user, card, targets)
    for _, p in ipairs(game:aliveInTurnOrderFrom(user)) do
        game:draw(p, 1, "团建")
    end
    -- user takes 1 card from a chosen player
    local cands = util.filter(game:aliveSeatsInOrder(), function(p) return p.id ~= user.id and #p.hand > 0 end)
    if #cands > 0 then
        local t = game:askTarget(user, cands, "【团建】：指定一人交给你1张牌", true)
        if t then
            local c = t.hand[game.rng:int(1, #t.hand)]
            game:removeFromHand(t, c)
            user.hand[#user.hand + 1] = c
            game:logmsg("%s 从 %s 处获得1张牌", user.name, t.name)
        end
    end
end

Tricks["OKR对齐"] = function(game, user, card, targets)
    local t = targets[1]
    game:logmsg("%s 与 %s 互看手牌", user.name, t.name)
    game:draw(user, 1, "OKR对齐")
    game:draw(t, 1, "OKR对齐")
end

Tricks["日报周报"] = function(game, user, card, targets)
    local t = targets[1]
    if #t.hand == 0 then game:logmsg("%s 没有手牌", t.name) return end
    local c = t.hand[game.rng:int(1, #t.hand)]
    game:logmsg("%s 查看了 %s 的1张手牌", user.name, t.name)
    local idx = game:askOption(user, { "获得此牌", "弃置此牌" }, "【日报周报】：处理该牌")
    game:removeFromHand(t, c)
    if idx == 1 then
        user.hand[#user.hand + 1] = c
        game:logmsg("%s 获得了 %s 的1张手牌", user.name, t.name)
    else
        game:toDiscard(c)
        game:logmsg("%s 弃置了 %s 的1张手牌", user.name, t.name)
    end
end

Tricks["融资到账"] = function(game, user, card, targets)
    for _, p in ipairs(game:aliveSeatsInOrder()) do
        game:heal(p, 1, "融资到账")
    end
end

Tricks["空降高管"] = function(game, user, card, targets)
    -- rotate seating: shift each alive player's seat one position clockwise.
    -- Implemented as a circular relabel of seats among alive players' characters/state.
    game:logmsg("%s 发动【空降高管】，全场顺移1个座位", user.name)
    local alive = game:aliveSeatsInOrder()
    if #alive < 2 then return end
    -- rotate the per-seat *contents* is complex; instead rotate seat indices by swapping
    -- players' seat order via reindexing. We rotate the players array among alive seats.
    local seats = {}
    for _, p in ipairs(alive) do seats[#seats + 1] = p.seat end
    -- new occupant of seats[i] becomes alive[i-1] (clockwise shift)
    local newAt = {}
    for i = 1, #alive do
        local src = alive[((i - 2) % #alive) + 1]
        newAt[seats[i]] = src
    end
    for seat, p in pairs(newAt) do
        p.seat = seat
        game.players[seat] = p
    end
end

Tricks["试用期考核"] = function(game, user, card, targets)
    -- delayed trick: place in front of target
    local t = targets[1]
    game:removeFromHand(user, card)
    t.delayed[#t.delayed + 1] = card
    game:logmsg("%s 将【试用期考核】置于 %s 面前", user.name, t.name)
    return "placed"
end

-- resolve a delayed trick at a player's judgement phase
function Engine:resolveDelayed(player, card)
    util.removeValue(player.delayed, card)
    self:toDiscard(card)   -- the delayed card itself returns to the discard pile
    if card.name == "试用期考核" then
        -- 可在判定前弃【画饼】取消
        local peaches = self:handCardsAs(player, "peach")
        if #peaches > 0 and self:askYesNo(player, "【试用期考核】判定前，弃1张【画饼】取消？") then
            local c = peaches[1]
            self:discardCards(player, { c }, "取消试用期考核")
            return
        end
        local j = self:judge(player, "试用期考核")
        if j and j.suit == "spade" and j.rank >= 2 and j.rank <= 9 then
            self:loseHp(player, 2, "试用期考核")
        else
            self:logmsg("%s 通过了试用期考核", player.name)
        end
    end
end

Engine.Tricks = Tricks

-- discard N cards from a player's hand via prompts (used by PUA, discard phase, etc.)
function Engine:promptDiscardN(player, n, reason)
    for _ = 1, n do
        if #player.hand == 0 then break end
        local c = self:askCard(player, player.hand, string.format("请弃置 1 张牌（%s）", reason or ""), false)
        if not c then c = player.hand[1] end
        self:discardCards(player, { c }, reason)
    end
end

----------------------------------------------------------------------
-- Equipment
----------------------------------------------------------------------
function Engine:equipCard(player, card)
    local slot = card.subtype  -- weapon/armor/plusHorse/minusHorse/treasure
    self:removeFromHand(player, card)
    local old = player.equip[slot]
    if old then self:toDiscard(old) end
    player.equip[slot] = card
    self:logmsg("%s 装备 %s", player.name, cards.label(card))
end

----------------------------------------------------------------------
-- Playing a card during the play phase
----------------------------------------------------------------------
-- Determine valid target players for a card the user wants to play.
function Engine:validTargets(user, card, asSubtype)
    local sub = asSubtype or card.subtype
    local out = {}
    if card.type == "basic" then
        if sub == "attack" then
            for _, p in ipairs(self:aliveSeatsInOrder()) do
                if p.id ~= user.id and self:canReach(user, p) then out[#out + 1] = p end
            end
        elseif sub == "peach" then
            for _, p in ipairs(self:aliveSeatsInOrder()) do
                if p.hp < p.maxHp then out[#out + 1] = p end
            end
        elseif sub == "wine" then
            out[#out + 1] = user
        end
    elseif card.type == "trick" then
        local name = card.name
        if name == "PUA" or name == "OKR对齐" or name == "日报周报" then
            for _, p in ipairs(self:aliveSeatsInOrder()) do
                if p.id ~= user.id then out[#out + 1] = p end
            end
        elseif name == "毕业优化" then
            for _, p in ipairs(self:aliveSeatsInOrder()) do
                if p.id ~= user.id and p.hp <= 1 then out[#out + 1] = p end
            end
        elseif name == "试用期考核" then
            for _, p in ipairs(self:aliveSeatsInOrder()) do
                if p.id ~= user.id then out[#out + 1] = p end
            end
        end
        -- aoe / self tricks have no explicit single target
    end
    return out
end

-- Is this card playable right now in the play phase (ignoring targets)?
function Engine:canPlayInPhase(user, card)
    local sub = card.subtype
    if card.type == "basic" then
        if sub == "attack" then
            return self:attacksLeft(user) > 0 and #self:validTargets(user, card, "attack") > 0
        elseif sub == "peach" then
            -- in play phase, only to heal someone below max
            return #self:validTargets(user, card, "peach") > 0
        elseif sub == "wine" then
            return not user.flags.wine
        elseif sub == "dodge" then
            return false  -- response only
        end
    elseif card.type == "equip" then
        return true
    elseif card.type == "trick" then
        if card.name == "背锅" then return false end  -- instant response trick
        local name = card.name
        if name == "PUA" or name == "OKR对齐" or name == "日报周报" or name == "毕业优化" or name == "试用期考核" then
            return #self:validTargets(user, card) > 0
        end
        return true  -- aoe / self tricks
    end
    return false
end

function Engine:attacksLeft(user)
    return self:attackBudget(user) - (user.flags.attacksUsed or 0)
end

----------------------------------------------------------------------
-- Offensive "view-as" conversions (char.skills.convert):
--   老板 狼性文化  : 装备 → 加班
--   楚抓手 赋能业务: OKR对齐 → 升职加薪
--   面试官 回去等通知: 黑色手牌 → PUA
----------------------------------------------------------------------
-- Build a virtual card that borrows `card`'s suit/rank/id but plays as `asName`.
function Engine:effectiveCard(card, asName)
    local proto = cards.PROTO[asName]
    if not proto then return nil end
    return {
        id = card.id, name = asName, type = proto.type, subtype = proto.subtype,
        range = proto.range, target = proto.target, suit = card.suit, rank = card.rank,
        _convertedFrom = card,
    }
end

-- Names this hand card can be played AS via the user's convert skill.
function Engine:convertOptions(user, card)
    local out = {}
    local conv = user.char.skills and user.char.skills.convert
    if not conv then return out end
    for _, rule in ipairs(conv) do
        local match = false
        if rule.from == "equip" then match = (card.type == "equip")
        elseif rule.from == "blackBasic" then match = cards.isBlack(card)        -- 黑色手牌
        elseif rule.from == card.name then match = true end
        if match and cards.PROTO[rule.to] then out[#out + 1] = rule.to end
    end
    return out
end

function Engine:canPlayConverted(user, card, asName)
    local ok = false
    for _, n in ipairs(self:convertOptions(user, card)) do if n == asName then ok = true end end
    if not ok then return false end
    local virt = self:effectiveCard(card, asName)
    return virt ~= nil and self:canPlayInPhase(user, virt)
end

-- Play `realCard` as the converted `asName`. The real card is consumed.
function Engine:playConverted(user, realCard, asName, targetIds)
    local virt = self:effectiveCard(realCard, asName)
    if not virt then return end
    local targets = util.map(targetIds or {}, function(id) return self:playerById(id) end)
    self:removeFromHand(user, realCard)
    self:toDiscard(realCard)
    self:logmsg("%s 将 %s 当作【%s】使用", user.name, cards.label(realCard), asName)
    self:trig(user, "onPlayCard", virt)

    if virt.type == "basic" and virt.subtype == "attack" then
        user.flags.attacksUsed = (user.flags.attacksUsed or 0) + 1
        user.stats.overtimeOut = user.stats.overtimeOut + 1
        self:performAttack(user, targets[1], { card = virt, amount = 1, dodgeable = true })
    elseif virt.type == "trick" then
        local fn = Tricks[asName]
        if not fn then return end
        local negated = self:maybeCounterTrick(user, virt, targets)
        if not negated and #targets == 1 then
            if self:trig(targets[1], "onTargetedByTrick", virt, user) then
                self:logmsg("%s 令【%s】对其无效", targets[1].name, asName)
                negated = true
            end
        end
        if not negated then
            self:emitPlay(user, virt, #targets == 1 and targets[1] or nil)
            fn(self, user, virt, targets)
        end
    end
end

-- Per-victim negation for multi-victim (AOE) tricks. Single-target tricks fire
-- onTargetedByTrick at their call sites (playCard/playConverted); AOE tricks compute
-- their own victim lists, so a harmful AOE must ask each victim here. Returns true if
-- the card still affects `victim` (i.e. they did NOT cancel it, e.g. 测试 复现不了).
function Engine:trickAffects(user, card, victim)
    if victim.id == user.id then return true end
    if self:trig(victim, "onTargetedByTrick", card, user) then
        self:logmsg("%s 令【%s】对其无效", victim.name, card.name)
        return false
    end
    return true
end

-- 财务 吴报销 流程不对: another player may discard a card to negate an opponent's trick.
-- Returns true if the trick was negated.
function Engine:maybeCounterTrick(user, card, targets)
    for _, p in ipairs(self:aliveInTurnOrderFrom(user)) do
        if p.id ~= user.id and p.char.skills and p.char.skills.trickCounter then
            if p.char.skills.trickCounter(self, p, user, card, targets) then
                return true
            end
        end
    end
    return false
end

-- Execute a play action. Returns true if turn should continue.
-- action: { cardId, targetIds }
function Engine:playCard(user, card, targetIds)
    targetIds = targetIds or {}
    local targets = util.map(targetIds, function(id) return self:playerById(id) end)

    if card.type == "equip" then
        self:equipCard(user, card)
        self:trig(user, "onEquip", card)
        self:emitPlay(user, card, nil)
        return true
    end

    if card.type == "basic" then
        if card.subtype == "attack" then
            self:removeFromHand(user, card)
            self:toDiscard(card)
            user.flags.attacksUsed = (user.flags.attacksUsed or 0) + 1
            user.stats.overtimeOut = user.stats.overtimeOut + 1
            local t = targets[1]
            self:logmsg("%s 对 %s 使用【加班】（%s）", user.name, t.name, cards.label(card))
            self:trig(user, "onPlayCard", card)
            self:performAttack(user, t, { card = card, amount = 1, dodgeable = true })
            return true
        elseif card.subtype == "peach" then
            self:removeFromHand(user, card)
            self:toDiscard(card)
            user.stats.pie = user.stats.pie + 1
            local t = targets[1] or user
            self:logmsg("%s 使用【画饼】", user.name)
            self:trig(user, "onPlayCard", card)
            self:emitPlay(user, card, t)
            self:heal(t, 1, "画饼")
            return true
        elseif card.subtype == "wine" then
            self:removeFromHand(user, card)
            self:toDiscard(card)
            user.flags.wine = true
            self:logmsg("%s 使用【卷一下】，下张【加班】伤害+1", user.name)
            self:trig(user, "onPlayCard", card)
            self:emitPlay(user, card, nil)
            return true
        end
    end

    if card.type == "trick" then
        local fn = Tricks[card.name]
        if not fn then
            self:logmsg("（%s 尚未实现，跳过）", card.name)
            self:removeFromHand(user, card)
            self:toDiscard(card)
            return true
        end
        self:logmsg("%s 使用【%s】", user.name, card.name)
        self:trig(user, "onPlayCard", card)
        -- trick negation: 财务 流程不对 (others counter) and 测试 复现不了 (target cancel)
        local negated = self:maybeCounterTrick(user, card, targets)
        if not negated and #targets == 1 then
            local cancel = self:trig(targets[1], "onTargetedByTrick", card, user)
            if cancel then
                self:logmsg("%s 令【%s】对其无效", targets[1].name, card.name)
                negated = true
            end
        end
        if negated then
            self:removeFromHand(user, card)
            self:toDiscard(card)
            return true
        end
        self:emitPlay(user, card, #targets == 1 and targets[1] or nil)
        -- Remove the card from hand BEFORE resolving the effect, so a side effect that
        -- discards the user's hand (e.g. 老板 errantly killing a 嫡系) can't double-handle
        -- the still-in-hand card. Delayed tricks (试用期考核) are placed by fn itself.
        if card.subtype == "delayed" then
            fn(self, user, card, targets)   -- fn moves the card into the target's delayed zone
        else
            self:removeFromHand(user, card)
            self:toDiscard(card)
            fn(self, user, card, targets)
        end
        return true
    end
    return true
end

----------------------------------------------------------------------
-- Turn structure
----------------------------------------------------------------------
function Engine:resetTurnFlags(player)
    player.flags = {}
    player.used = {}
    player.armorUsedThisTurn = false
end

-- "每回合一次" reactive effects (armor 人体工学椅, 后端/测试/财务 counters) fire on OTHER
-- players' turns, so their per-turn budget must reset at the start of every turn — not only
-- on the owner's own turn — to be available once per turn cycle.
function Engine:resetReactiveBudgets(activePlayer)
    for _, q in ipairs(self.players) do
        q.armorUsedThisTurn = false
        if q.id ~= activePlayer.id then q.used = {} end
    end
end

function Engine:runTurn(player)
    if not player.alive then return end
    self.current = player
    self.turnCount = self.turnCount + 1
    self:resetTurnFlags(player)
    self:resetReactiveBudgets(player)
    self:logmsg("──── 第%d回合：%s 的回合 ────", self.turnCount, player.name)

    self.phase = "judge"
    -- judgement phase: resolve delayed tricks (copy list, they may self-remove)
    local delayedCopy = {}
    for _, c in ipairs(player.delayed) do delayedCopy[#delayedCopy + 1] = c end
    for _, c in ipairs(delayedCopy) do
        self:resolveDelayed(player, c)
        if self.winner or not player.alive then return end
    end

    self:trig(player, "onTurnStart")
    if self.winner or not player.alive then return end

    -- draw phase
    self.phase = "draw"
    if player.skipDrawNext then
        player.skipDrawNext = nil
        self:logmsg("%s 跳过摸牌阶段", player.name)
    else
        local base = 2
        local mod = self:trig(player, "drawNumMod", base)
        local n = mod or base
        -- 主公技「老板光环」: in the most out-numbered configs the boss draws extra
        -- cards each turn (see setup). More cards = more dodges, attacks and peaches.
        if type(n) == "number" and (player.bossDrawBonus or 0) > 0
            and not os.getenv("ZHS_NO_BOSS_DRAW") then
            n = n + player.bossDrawBonus
        end
        if n == "skip" then
            self:logmsg("%s 跳过摸牌阶段（技能）", player.name)
        else
            self:draw(player, n)
            self:trig(player, "afterDraw")
        end
    end
    if self.winner or not player.alive then return end

    -- play phase
    self.phase = "play"
    self:playPhase(player)
    if self.winner or not player.alive then return end

    -- discard phase
    self.phase = "discard"
    local limit = self:handLimit(player)
    while #player.hand > limit do
        local excess = #player.hand - limit
        self:logmsg("%s 手牌 %d 张，超出上限 %d，需弃 %d 张", player.name, #player.hand, limit, excess)
        self:promptDiscardN(player, excess, "弃牌阶段")
        limit = self:handLimit(player)
    end

    -- end phase
    self.phase = "end"
    self:trig(player, "onTurnEnd")
end

function Engine:playPhase(player)
    local guard = 0
    while true do
        if self.winner or not player.alive then return end
        guard = guard + 1
        if guard > 80 then
            self:logmsg("（出牌阶段操作过多，自动结束）")
            return
        end
        local action = self:ask({ kind = "playAction", player = player, phase = "play" })
        if not action or action.type == "end" then
            return
        elseif action.type == "playCard" then
            local card = self:findCard(player, action.cardId)
            if card and action.as then
                if self:canPlayConverted(player, card, action.as) then
                    self:playConverted(player, card, action.as, action.targetIds)
                else
                    self:logmsg("（无效操作）")
                end
            elseif card and self:canPlayInPhase(player, card) then
                self:playCard(player, card, action.targetIds)
            else
                self:logmsg("（无效操作）")
            end
        elseif action.type == "skill" then
            self:activateSkill(player, action.skillId, action)
        end
    end
end

-- Active skills: char.skills.actives = { {id,name,desc,canUse(game,p), run(game,p)} }
function Engine:listActiveSkills(player)
    local out = {}
    local actives = player.char.skills and player.char.skills.actives
    if actives then
        for _, sk in ipairs(actives) do
            local ok = true
            if sk.canUse then ok = sk.canUse(self, player) end
            if ok then out[#out + 1] = sk end
        end
    end
    return out
end

function Engine:activateSkill(player, skillId, action)
    local actives = player.char.skills and player.char.skills.actives
    if not actives then return end
    for _, sk in ipairs(actives) do
        if sk.id == skillId then
            if sk.canUse and not sk.canUse(self, player) then return end
            self:logmsg("%s 发动技能【%s】", player.name, sk.name)
            sk.run(self, player, action)
            return
        end
    end
end

----------------------------------------------------------------------
-- Main game loop (coroutine body)
----------------------------------------------------------------------
function Engine:run()
    local seat = self.startSeat
    local safety = 0
    while not self.winner do
        safety = safety + 1
        if safety > 1000 then
            self:logmsg("（达到回合上限，判定为平局）")
            self.winner = self.winner or "draw"
            break
        end
        local player = self.players[seat]
        if player.alive then
            self:runTurn(player)
            -- a seat-mutating effect (空降高管) during the turn may have moved the
            -- actor; advance clockwise from where the actor actually ended up.
            seat = self.current.seat
        end
        if self.winner then break end
        -- advance to next alive seat
        local nextSeat = seat
        for _ = 1, self.numPlayers do
            nextSeat = (nextSeat % self.numPlayers) + 1
            if self.players[nextSeat].alive then break end
        end
        seat = nextSeat
        -- safety: if only one alive, win check
        if #self:aliveSeatsInOrder() <= 1 then
            self:checkWin()
            break
        end
    end
    self.phase = "over"
end

return Engine
