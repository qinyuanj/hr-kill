-- cards.lua — card definitions and deck construction for 《职海杀》.
-- Pure data + a deck builder. No love dependency.
local cards = {}

-- Suits. spade/club are black; heart/diamond are red.
cards.SUITS = { "spade", "heart", "club", "diamond" }
cards.SUIT_CN = { spade = "♠", heart = "♥", club = "♣", diamond = "♦" }
cards.RANK_CN = { [1] = "A", [11] = "J", [12] = "Q", [13] = "K" }

function cards.isRed(card)
    return card.suit == "heart" or card.suit == "diamond"
end
function cards.isBlack(card)
    return card.suit == "spade" or card.suit == "club"
end
function cards.rankStr(card)
    return cards.RANK_CN[card.rank] or tostring(card.rank)
end
function cards.label(card)
    return string.format("%s%s%s", card.name, cards.SUIT_CN[card.suit], cards.rankStr(card))
end

-- Card prototype table keyed by name. Each entry describes static properties.
-- type: basic | trick | equip
-- subtype gives finer behavior.
cards.PROTO = {
    -- ===== 基本牌 =====
    ["加班"]   = { type = "basic", subtype = "attack", desc = "对攻击范围内一名角色造成1点伤害" },
    ["摸鱼"]   = { type = "basic", subtype = "dodge",  desc = "抵消一次【加班】" },
    ["画饼"]   = { type = "basic", subtype = "peach",  desc = "回复1点精神值" },
    ["卷一下"] = { type = "basic", subtype = "wine",   desc = "本回合下一张【加班】伤害+1" },

    -- ===== 锦囊牌 =====
    ["PUA"]        = { type = "trick", subtype = "single", target = "one",  desc = "弃2张牌或受到1点伤害" },
    ["拉会对齐"]   = { type = "trick", subtype = "aoe",    target = "others", desc = "所有人弃1张牌，否则下回合不摸牌" },
    ["背锅"]       = { type = "trick", subtype = "instant", desc = "受到伤害时转移给另一名角色" },
    ["升职加薪"]   = { type = "trick", subtype = "self",   target = "self",  desc = "摸3张牌，本回合手牌上限+2" },
    ["毕业优化"]   = { type = "trick", subtype = "single", target = "weak",  desc = "对精神值≤1的角色造成2点伤害" },
    ["团建"]       = { type = "trick", subtype = "aoe",    target = "all",   desc = "所有人各摸1张，然后你指定一人交你1张牌" },
    ["OKR对齐"]    = { type = "trick", subtype = "single", target = "one",   desc = "与一名角色互看手牌，各摸1张" },
    ["日报周报"]   = { type = "trick", subtype = "single", target = "one",   desc = "看目标1张手牌，获得或弃置之" },
    ["空降高管"]   = { type = "trick", subtype = "aoe",    target = "all",   desc = "所有人顺移1个座位" },
    ["融资到账"]   = { type = "trick", subtype = "aoe",    target = "all",   desc = "所有人回复1点精神值" },
    ["试用期考核"] = { type = "trick", subtype = "delayed", desc = "判定，黑桃2-9则失去2点精神值" },

    -- ===== 装备牌 =====
    ["+1职级"]      = { type = "equip", subtype = "plusHorse",  desc = "其他角色与你的距离+1" },
    ["-1职级"]      = { type = "equip", subtype = "minusHorse", desc = "你与其他角色的距离-1" },
    ["MacBook Pro"] = { type = "equip", subtype = "weapon", range = 2, desc = "【加班】命中后可弃对方1张牌" },
    ["人体工学椅"]  = { type = "equip", subtype = "armor",  desc = "每回合一次，【加班】伤害-1" },
    ["独立办公室"]  = { type = "equip", subtype = "armor",  desc = "手牌上限+2" },
    ["工牌"]        = { type = "equip", subtype = "weapon", range = 1, desc = "【加班】命中后可看对方1张手牌" },
    ["双屏显示器"]  = { type = "equip", subtype = "weapon", range = 3, desc = "每回合可多使用1张【加班】" },
    ["猎头联系方式"] = { type = "equip", subtype = "treasure", desc = "每回合一次，1张手牌当【画饼】" },
    ["股权激励书"]  = { type = "equip", subtype = "treasure", desc = "老板：手牌上限+2；非老板：手牌上限-1" },
}

-- Standard 108-card distribution from 01_完整卡牌数值表.md
cards.DISTRIBUTION = {
    -- basic (48)
    { name = "加班", count = 24, suits = { "spade", "club", "spade", "club" } },
    { name = "摸鱼", count = 18, suits = { "heart", "diamond" } },
    { name = "画饼", count = 4,  suits = { "heart" } },
    { name = "卷一下", count = 2, suits = { "diamond" } },
    -- tricks (38)
    { name = "PUA", count = 5 },
    { name = "拉会对齐", count = 4 },
    { name = "背锅", count = 3 },
    { name = "升职加薪", count = 4 },
    { name = "毕业优化", count = 2 },
    { name = "团建", count = 3 },
    { name = "OKR对齐", count = 4 },
    { name = "日报周报", count = 5 },
    { name = "空降高管", count = 3 },
    { name = "融资到账", count = 3 },
    { name = "试用期考核", count = 2 },
    -- equip (22)
    { name = "+1职级", count = 3 },
    { name = "-1职级", count = 3 },
    { name = "MacBook Pro", count = 3 },
    { name = "人体工学椅", count = 3 },
    { name = "独立办公室", count = 2 },
    { name = "工牌", count = 3 },
    { name = "双屏显示器", count = 2 },
    { name = "猎头联系方式", count = 2 },
    { name = "股权激励书", count = 1 },
}

-- Build a deck (list of card instances). Each card gets a unique id, suit, rank.
function cards.buildDeck(rng)
    local deck = {}
    local nextId = 1
    for _, entry in ipairs(cards.DISTRIBUTION) do
        local proto = cards.PROTO[entry.name]
        assert(proto, "unknown card proto: " .. entry.name)
        for i = 1, entry.count do
            local suit
            if entry.suits then
                suit = entry.suits[((i - 1) % #entry.suits) + 1]
            else
                suit = cards.SUITS[rng:int(1, 4)]
            end
            local card = {
                id = nextId,
                name = entry.name,
                suit = suit,
                rank = rng:int(1, 13),
                type = proto.type,
                subtype = proto.subtype,
                range = proto.range,
                target = proto.target,
            }
            deck[#deck + 1] = card
            nextId = nextId + 1
        end
    end
    rng:shuffle(deck)
    return deck
end

return cards
