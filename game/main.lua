-- main.lua — LÖVE front-end for 《职海杀》.
-- Drives the engine coroutine, renders the table, and turns the engine's decision
-- requests into clickable UI for the human (seat 1) while the AI plays the rest.

package.path = "./?.lua;" .. package.path

local Engine = require("src.engine")
local AI     = require("src.ai")
local Chars  = require("src.characters")
local cards  = require("src.cards")
local theme  = require("src.theme")
local sound  = require("src.sound")

-- Surface runtime crashes to stderr (the default LÖVE error screen is graphical and
-- prints nothing, which makes headless screenshot/debug runs impossible to diagnose).
function love.errorhandler(msg)
    io.stderr:write("\n=== LÖVE runtime error ===\n" .. tostring(msg) .. "\n"
        .. debug.traceback("", 2) .. "\n")
    if os.getenv("ZHS_SHOT") or os.getenv("ZHS_SHOT_KIND") then os.exit(1) end
    -- interactive: fall back to LÖVE's built-in error screen
    return love.errhand and love.errhand(msg)
end

local G = {
    game = nil,
    req = nil,            -- current pending request from the engine
    aiTimer = 0,
    aiDelay = 0.55,
    numPlayers = 6,
    selecting = nil,      -- { cardId, targetIds } during play-phase target selection
    flash = nil,          -- { text, t }
    help = false,
    anims = {},           -- transient visual effects (floating numbers, attack lines)
    -- layout caches (rebuilt each frame)
    handRects = {},
    playerRects = {},
    buttons = {},
    logScroll = 0,
}

----------------------------------------------------------------------
-- setup / driver
----------------------------------------------------------------------
local function humanPlayer()
    if not G.game then return nil end
    -- resolve by the isHuman flag (object identity survives 空降高管 seat rotation)
    for _, p in ipairs(G.game.players) do
        if p.isHuman then return p end
    end
    return G.game.players[1]
end

-- forward declarations (defined in the input section, referenced by layout/drawHand)
local commitPlay, tryPlayCard, cardActionable

-- screenshot mode: `love . --shot` renders a representative frame to the save
-- dir then quits. Used to verify real rendering without manual interaction.
local SHOT = false
for _, a in ipairs(_G.arg or {}) do if a == "--shot" then SHOT = true end end
if os.getenv("ZHS_SHOT") then SHOT = true end

local function newGame(n)
    G.numPlayers = n or G.numPlayers
    -- SHOT mode uses a fixed seed so screenshots are reproducible frame-to-frame.
    local seed = os.time() % 2000000000
    if SHOT then seed = tonumber(os.getenv("ZHS_SHOT_SEED")) or 42 end
    G.game = Engine.new({
        numPlayers = G.numPlayers,
        humanSeat = 1,
        seed = seed,
        characters = Chars.list,
    })
    -- spawn visual effects from engine events (no-op data the engine pushes via emit)
    G.game.onEvent = function(ev)
        if ev.type == "attack" then
            G.anims[#G.anims + 1] = { kind = "attack", from = ev.source, to = ev.target, t = 0.5, maxT = 0.5 }
            sound.play("attack", 0.5)
        elseif ev.type == "damage" then
            G.anims[#G.anims + 1] = { kind = "float", target = ev.target,
                text = "-" .. ev.amount, color = theme.colors.hpLow, t = 1.1, maxT = 1.1 }
            sound.play("damage", 0.45)
        elseif ev.type == "heal" then
            G.anims[#G.anims + 1] = { kind = "float", target = ev.target,
                text = "+" .. ev.amount, color = theme.colors.good, t = 1.1, maxT = 1.1 }
            sound.play("heal", 0.45)
        elseif ev.type == "death" then
            sound.play("death", 0.55)
        elseif ev.type == "cardPlayed" then
            local col = (ev.cardType == "trick" and theme.colors.cardTrick)
                or (ev.cardType == "equip" and theme.colors.cardEquip)
                or theme.colors.cardBasic
            G.anims[#G.anims + 1] = { kind = "label", source = ev.source,
                text = ev.name, color = col, t = 0.95, maxT = 0.95 }
            if ev.target then
                G.anims[#G.anims + 1] = { kind = "cardline", from = ev.source, to = ev.target,
                    color = col, t = 0.45, maxT = 0.45 }
            end
            sound.play("card", 0.3)
        end
        if #G.anims > 48 then table.remove(G.anims, 1) end
    end
    G.anims = {}
    G._endSoundPlayed = false
    G.game:start()
    G.selecting = nil
    G.cardMenu = nil
    G.help = nil
    G.logScroll = 0
    G.flash = nil
    G.req = G.game:resume(nil)
    G.aiTimer = 0
    -- show the role-reveal overlay at the start of every game (pauses AI until
    -- dismissed). Auto-skip when a harness is driving (autoplay / screenshots),
    -- unless a screenshot explicitly wants the intro.
    G.intro = not (_G.AUTOPLAY or SHOT)
    if SHOT and os.getenv("ZHS_SHOT_KIND") == "intro" then G.intro = true end
end

-- resume the engine with an answer; capture the next request
local function step(answer)
    G.selecting = nil
    G.cardMenu = nil   -- never let a half-open conversion menu survive a coroutine resume
    G.req = G.game:resume(answer)
    G.aiTimer = 0
end

local function isHumanDecision()
    return G.req ~= nil and G.req.player and G.req.player.isHuman
end

local shotFrame, shotDone = 0, false

function love.load()
    theme.loadFonts()
    love.graphics.setBackgroundColor(theme.colors.bg)
    love.keyboard.setKeyRepeat(true)
    sound.load()
    if SHOT then sound.enabled = false end   -- no audio during headless capture
    -- ZHS_SHOT_N lets a capture pick the table size; ignore anything outside 4–8 so a typo
    -- falls back to the default instead of tripping setup()'s "unsupported player count" assert.
    local shotN = tonumber(os.getenv("ZHS_SHOT_N"))
    newGame((shotN and shotN >= 4 and shotN <= 8) and shotN or 6)
    -- screenshot helper: pin the cursor so hover-driven UI (tooltips) renders for capture
    if SHOT then
        local fx, fy = tonumber(os.getenv("ZHS_SHOT_MX")), tonumber(os.getenv("ZHS_SHOT_MY"))
        if fx and fy then love.mouse.getPosition = function() return fx, fy end end
    end
end

function love.update(dt)
    if not G.game then return end

    if SHOT then
        shotFrame = shotFrame + 1
        if shotDone then
            if G._quitAt and shotFrame >= G._quitAt then love.event.quit() end
            return
        end
        -- Fast-forward the whole game in one update: step every decision (the AI even
        -- answers the human seat) until we reach the wanted human request, or the game
        -- ends. This reaches any capture state in a couple of frames regardless of how
        -- long the game runs, so screenshots are quick and reliable.
        local want = os.getenv("ZHS_SHOT_KIND")   -- e.g. "playAction" to show the play UI
        local guard = 0
        while want ~= "intro" and G.req ~= nil and guard < 50000 do
            local atTarget = isHumanDecision() and (not want or G.req.kind == want)
            if atTarget then break end
            step(AI.answer(G.game, G.req))
            guard = guard + 1
        end
        if shotFrame > 2 then
            shotDone = true
            -- demo: inject full-strength effects so screenshots can verify their rendering
            if os.getenv("ZHS_SHOT_DEMO") then
                local n = G.numPlayers
                G.anims[#G.anims + 1] = { kind = "attack", from = (n >= 2 and 2 or 1), to = 1, t = 0.5, maxT = 0.5 }
                G.anims[#G.anims + 1] = { kind = "float", target = 1, text = "-1", color = theme.colors.hpLow, t = 1.1, maxT = 1.1 }
                if n >= 3 then
                    G.anims[#G.anims + 1] = { kind = "float", target = 3, text = "+1", color = theme.colors.good, t = 1.1, maxT = 1.1 }
                    G.anims[#G.anims + 1] = { kind = "label", source = 3, text = "PUA", color = theme.colors.cardTrick, t = 0.95, maxT = 0.95 }
                    G.anims[#G.anims + 1] = { kind = "cardline", from = 3, to = 1, color = theme.colors.cardTrick, t = 0.45, maxT = 0.45 }
                end
                if n >= 2 then
                    G.anims[#G.anims + 1] = { kind = "label", source = 2, text = "卷一下", color = theme.colors.cardBasic, t = 0.95, maxT = 0.95 }
                end
            end
            love.graphics.captureScreenshot("shot.png")
            G._quitAt = shotFrame + 3
        end
        return
    end

    if G.flash then
        G.flash.t = G.flash.t - dt
        if G.flash.t <= 0 then G.flash = nil end
    end
    -- advance transient animations (keep ticking even after game over)
    for i = #G.anims, 1, -1 do
        G.anims[i].t = G.anims[i].t - dt
        if G.anims[i].t <= 0 then table.remove(G.anims, i) end
    end
    -- win/lose sting, once, when the game resolves
    if G.game.winner and not G._endSoundPlayed then
        G._endSoundPlayed = true
        local me = humanPlayer()
        local meWin = G.game:identityWon(me.identity)
        sound.play(meWin and "win" or "lose", 0.6)
    end
    if G.req == nil then return end             -- game over
    if G.intro then return end                  -- waiting on the role-reveal overlay
    -- _G.AUTOPLAY lets a test harness drive the human seat with the AI too.
    if not isHumanDecision() or _G.AUTOPLAY then
        G.aiTimer = G.aiTimer + dt
        if G.aiTimer >= G.aiDelay or _G.AUTOPLAY then
            local ans = AI.answer(G.game, G.req)
            step(ans)
        end
    end
end

local function flash(text)
    G.flash = { text = text, t = 1.6 }
end

----------------------------------------------------------------------
-- knowledge: what identity the human is allowed to see for player p
----------------------------------------------------------------------
local function knownIdentity(p)
    local me = humanPlayer()
    if G.game and G.game.winner then return p.identity end   -- game over: everyone is revealed
    if p.identity == "boss" then return p.identity end
    if p.revealed then return p.identity end
    if p.id == me.id then return p.identity end
    if p._revealedTo and p._revealedTo[me.id] then return p.identity end
    return nil
end

----------------------------------------------------------------------
-- which cards need an explicit target click
----------------------------------------------------------------------
local TARGETED = {
    ["加班"] = true, ["画饼"] = true, ["PUA"] = true, ["OKR对齐"] = true,
    ["日报周报"] = true, ["毕业优化"] = true, ["试用期考核"] = true,
}

----------------------------------------------------------------------
-- layout (rebuilt every frame; also used for hit-testing)
----------------------------------------------------------------------
local function addButton(label, x, y, w, h, color, action, danger)
    G.buttons[#G.buttons + 1] = { label = label, x = x, y = y, w = w, h = h,
        color = color, action = action, danger = danger }
end

local function layout()
    local w, h = love.graphics.getDimensions()
    G.handRects = {}
    G.playerRects = {}
    G.buttons = {}
    local logW = 330
    local playW = w - logW
    G.L = { w = w, h = h, logW = logW, playW = playW }

    -- table ellipse
    local cx, cy = playW / 2, h * 0.43
    local rx, ry = playW * 0.40, h * 0.285
    G.L.cx, G.L.cy, G.L.rx, G.L.ry = cx, cy, rx, ry

    local n = G.numPlayers
    local pw, ph = 156, 96
    -- always seat the human at the bottom, others clockwise in seat order
    local me = humanPlayer()
    local hSeat = me and me.seat or 1
    for seat = 1, n do
        local p = G.game.players[seat]
        local k = (seat - hSeat) % n
        local ang = math.rad(90 + k * (360 / n))
        local px = cx + rx * math.cos(ang)
        local py = cy + ry * math.sin(ang)
        G.playerRects[p.id] = { x = px - pw / 2, y = py - ph / 2, w = pw, h = ph, cx = px, cy = py }
    end

    -- human hand row
    local me = humanPlayer()
    local handY = h - 132
    local cw, ch, gap = 86, 116, 8
    local total = #me.hand * (cw + gap) - gap
    local startX = math.max(16, (playW - total) / 2)
    for i, c in ipairs(me.hand) do
        local x = startX + (i - 1) * (cw + gap)
        G.handRects[c.id] = { x = x, y = handY, w = cw, h = ch, card = c }
    end

    -- action buttons / decision controls
    local req = G.req
    local by = handY - 46
    if req and req.player and req.player.isHuman then
        -- while a conversion menu is open or a target is being picked, hide the play-phase
        -- action buttons: otherwise they sit under the menu (stealing its clicks) or let a
        -- stray click end the turn / fire a skill and abandon the in-progress card play.
        if req.kind == "playAction" and not G.cardMenu and not G.selecting then
            -- end turn
            addButton("结束回合", playW - 116, by, 104, 36, theme.colors.btnDanger, function()
                step({ type = "end" })
            end, true)
            -- active skills
            local bx = 16
            for _, sk in ipairs(G.game:listActiveSkills(me)) do
                local label = "技·" .. sk.name
                local bw = math.max(96, theme.fonts.small:getWidth(label) + 22)
                addButton(label, bx, by, bw, 36, theme.colors.btn, function()
                    step({ type = "skill", skillId = sk.id })
                end)
                bx = bx + bw + 8
            end
        elseif req.kind == "chooseOption" then
            local bx = 16
            for i, opt in ipairs(req.options) do
                local bw = math.max(90, theme.fonts.normal:getWidth(opt) + 28)
                addButton(opt, bx, by, bw, 38, theme.colors.btn, function() step(i) end)
                bx = bx + bw + 10
            end
        elseif req.kind == "chooseCard" or req.kind == "chooseTarget" then
            if req.optional then
                addButton("取消 / 跳过", playW - 140, by, 128, 38, theme.colors.btnDanger,
                    function() step(nil) end, true)
            end
        end
    end

    -- card conversion menu (老板/楚抓手/面试官 view-as plays)
    if G.cardMenu then
        local cr = G.handRects[G.cardMenu.cardId]
        if cr then
            local mw, mh = 156, 30
            for i, opt in ipairs(G.cardMenu.options) do
                local bx = math.min(playW - mw - 4, math.max(4, cr.x + cr.w / 2 - mw / 2))
                local byy = cr.y - 8 - (#G.cardMenu.options - i + 1) * (mh + 4)
                addButton(opt.label, bx, byy, mw, mh, theme.colors.btnHover, function()
                    local card = G.game:findCard(humanPlayer(), G.cardMenu.cardId)
                    local asName = opt.asName
                    G.cardMenu = nil
                    if card then commitPlay(card, asName) end
                end)
            end
        else
            G.cardMenu = nil
        end
    end

    -- restart button (always available, top-left of log area)
    addButton("重开", w - logW + 12, 12, 60, 26, theme.colors.btn, function() newGame(G.numPlayers) end)
    -- player count cycler
    addButton("人数:" .. G.numPlayers, w - logW + 80, 12, 92, 26, theme.colors.btn, function()
        local order = { 4, 5, 6, 7, 8 }
        local idx = 1
        for i, v in ipairs(order) do if v == G.numPlayers then idx = i end end
        newGame(order[(idx % #order) + 1])
    end)
end

----------------------------------------------------------------------
-- drawing
----------------------------------------------------------------------
local function drawCardFace(c, x, y, w, h, opts)
    opts = opts or {}
    local col = theme.colors.cardBasic
    if c.type == "trick" then col = theme.colors.cardTrick
    elseif c.type == "equip" then col = theme.colors.cardEquip end
    local small = w < 78

    -- body
    theme.setColor({ col[1] * 0.28, col[2] * 0.28, col[3] * 0.33 })
    theme.rrect("fill", x, y, w, h, 7)
    -- type-colored header accent strip
    theme.setColor({ col[1] * 0.55, col[2] * 0.55, col[3] * 0.58 })
    theme.rrect("fill", x + 3, y + 3, w - 6, 4, 2)

    if opts.dim then theme.setColor({ 0, 0, 0 }, 0.5); theme.rrect("fill", x, y, w, h, 7) end

    -- border (selection / candidate states win over the type color)
    if opts.selected then
        theme.setColor(theme.colors.highlight); love.graphics.setLineWidth(3)
    elseif opts.candidate then
        theme.setColor(theme.colors.targetable); love.graphics.setLineWidth(3)
    else
        theme.setColor(col); love.graphics.setLineWidth(1.5)
    end
    theme.rrect("line", x, y, w, h, 7)
    love.graphics.setLineWidth(1)

    -- suit/rank in the top-left and bottom-right corners (like a real card)
    local suitCol = cards.isRed(c) and theme.colors.cardRed or theme.colors.text
    local sr = cards.SUIT_CN[c.suit] .. cards.rankStr(c)
    theme.print(sr, theme.fonts.small, suitCol, x + 6, y + 10)
    if not small then
        local fnt = theme.fonts.tiny
        love.graphics.setFont(fnt)
        theme.setColor(suitCol)
        love.graphics.print(sr, x + w - 8 - fnt:getWidth(sr), y + h - 16)
    end
    -- name centered
    local nameFont = small and theme.fonts.small or theme.fonts.normal
    theme.printf(c.name, nameFont, opts.dim and theme.colors.textDim or theme.colors.text,
        x + 2, y + h / 2 - (small and 16 or 22), w - 4, "center")
    -- type tag footer
    local tag = c.type == "basic" and "基本" or (c.type == "trick" and "锦囊" or "装备")
    theme.printf(tag, theme.fonts.tiny, { col[1] * 0.9, col[2] * 0.9, col[3] * 0.95 },
        x, y + h - 17, w, "center")
end

local function drawHpPips(p, x, y)
    local r = 6
    for i = 1, p.maxHp do
        local on = i <= p.hp
        if on then
            theme.setColor(p.hp <= 1 and theme.colors.hpLow or theme.colors.hpFull)
        else
            theme.setColor(theme.colors.hpEmpty)
        end
        love.graphics.circle("fill", x + (i - 1) * (r * 2 + 4) + r, y + r, r)
        theme.setColor(theme.colors.line)
        love.graphics.circle("line", x + (i - 1) * (r * 2 + 4) + r, y + r, r)
    end
end

local function drawPlayer(p)
    local r = G.playerRects[p.id]
    if not r then return end
    local isCurrent = G.game.current and G.game.current.id == p.id
    local panel = theme.colors.panel
    if isCurrent then panel = theme.colors.panelTurn end
    if not p.alive then panel = theme.colors.bg2 end

    theme.setColor(panel)
    theme.rrect("fill", r.x, r.y, r.w, r.h, 8)
    -- targetable highlight when this player is a candidate
    local req = G.req
    local candidate = false
    if req and req.player and req.player.isHuman then
        if req.kind == "chooseTarget" then
            for _, id in ipairs(req.candidates) do if id == p.id then candidate = true end end
        elseif G.selecting then
            for _, id in ipairs(G.selecting.targetIds) do if id == p.id then candidate = true end end
        end
    end
    if candidate then
        theme.setColor(theme.colors.targetable); love.graphics.setLineWidth(3)
    elseif isCurrent then
        theme.setColor(theme.colors.accent); love.graphics.setLineWidth(2)
    else
        theme.setColor(theme.colors.line); love.graphics.setLineWidth(1)
    end
    theme.rrect("line", r.x, r.y, r.w, r.h, 8)
    love.graphics.setLineWidth(1)

    -- name + identity badge. The active seat gets a non-color cue (a ▶ marker + accent
    -- name) so it reads without relying on the panel tint / border colour alone.
    local nameCol = p.alive and theme.colors.text or theme.colors.textDim
    local nameX = r.x + 8
    if isCurrent and p.alive then
        local ty = r.y + 10
        theme.setColor(theme.colors.accent)
        love.graphics.polygon("fill", r.x + 8, ty, r.x + 8, ty + 9, r.x + 16, ty + 4.5)
        nameX = r.x + 22
        nameCol = theme.colors.accent
    end
    theme.print(p.name, theme.fonts.small, nameCol, nameX, r.y + 6)
    local idk = knownIdentity(p)
    local badge = idk and theme.identityCN[idk] or "身份?"
    local badgeCol = idk and theme.identityColor(idk) or theme.colors.hidden
    local bw = theme.fonts.tiny:getWidth(badge) + 12
    theme.setColor({ badgeCol[1] * 0.3, badgeCol[2] * 0.3, badgeCol[3] * 0.3 })
    theme.rrect("fill", r.x + r.w - bw - 6, r.y + 6, bw, 18, 4)
    theme.print(badge, theme.fonts.tiny, badgeCol, r.x + r.w - bw - 1, r.y + 7)

    -- char title·name
    theme.print(p.char.title .. "·" .. p.char.name, theme.fonts.tiny, theme.colors.textDim, r.x + 8, r.y + 26)

    -- hp pips
    drawHpPips(p, r.x + 8, r.y + 44)

    -- hand count + equip
    theme.print("手牌 " .. #p.hand, theme.fonts.tiny, theme.colors.textDim, r.x + 8, r.y + 60)
    local ex = r.x + 8
    local ey = r.y + 76
    local eqs = {}
    if p.equip.weapon then eqs[#eqs + 1] = "武:" .. (p.equip.weapon.range or 1) end
    if p.equip.armor then eqs[#eqs + 1] = "防" end
    if p.equip.minusHorse then eqs[#eqs + 1] = "-1" end
    if p.equip.plusHorse then eqs[#eqs + 1] = "+1" end
    if p.equip.treasure then eqs[#eqs + 1] = "宝" end
    if #p.delayed > 0 then eqs[#eqs + 1] = "判×" .. #p.delayed end
    if #eqs > 0 then
        theme.print(table.concat(eqs, " "), theme.fonts.tiny, theme.colors.cardEquip, ex, ey)
    end

    if not p.alive then
        theme.printf("已阵亡", theme.fonts.small, theme.colors.bad, r.x, r.y + r.h / 2 - 8, r.w, "center")
    end
end

local function drawLog()
    local w, h = G.L.w, G.L.h
    local x = w - G.L.logW
    theme.setColor(theme.colors.bg2)
    love.graphics.rectangle("fill", x, 0, G.L.logW, h)
    theme.setColor(theme.colors.line)
    love.graphics.line(x, 0, x, h)

    theme.print("战报", theme.fonts.mid, theme.colors.accent, x + 12, 44)

    local font = theme.fonts.small
    love.graphics.setFont(font)
    local pad = 12
    local lineH = font:getHeight() + 4
    local areaY = 76
    local areaH = h - areaY - 12
    if areaH <= 0 then G.logMaxScroll = 0; return end   -- tiny/headless surface: nothing to draw
    local wrapW = G.L.logW - pad * 2
    local maxRows = math.max(1, math.floor(areaH / lineH))
    local log = G.game.log
    local total = #log

    -- Budget by RENDERED rows, not entries: long CJK report lines wrap to 2+ rows, so an
    -- entry-counted window overflows the panel and clips the newest lines. Measure each
    -- entry's wrapped row count, then show a bottom-anchored window (scroll 0 = newest).
    local rows, totalRows = {}, 0
    for i = 1, total do
        local _, wrapped = font:getWrap(log[i], wrapW)
        rows[i] = math.max(1, #wrapped)
        totalRows = totalRows + rows[i]
    end
    -- G.logScroll counts rows scrolled UP from the newest; clamp to the real overflow.
    local maxScroll = math.max(0, totalRows - maxRows)
    G.logMaxScroll = maxScroll
    local scroll = math.max(0, math.min(G.logScroll or 0, maxScroll))
    G.logScroll = scroll   -- write the clamped value back so a shrink can't strand it stale-high

    -- Top visible global row; locate its entry and how many of that entry's rows sit above
    -- the viewport (rendered at a negative offset and clipped by the scissor).
    local topRow = math.max(1, totalRows - scroll - maxRows + 1)
    local acc, startI, skipRows = 0, total + 1, 0
    for i = 1, total do
        if acc + rows[i] >= topRow then startI = i; skipRows = topRow - acc - 1; break end
        acc = acc + rows[i]
    end

    love.graphics.setScissor(x, areaY, G.L.logW, areaH)
    local yy = areaY - skipRows * lineH
    for i = startI, total do
        local line = log[i]
        local col = theme.colors.text
        if line:find("阵亡") or line:find("濒死") then col = theme.colors.bad
        elseif line:find("回合 ────") or line:find("回合：") then col = theme.colors.accent
        elseif line:find("游戏结束") then col = theme.colors.good
        elseif line:find("回复") then col = theme.colors.good end
        theme.printf(line, font, col, x + pad, yy, wrapW, "left")
        yy = yy + rows[i] * lineH
        if yy >= areaY + areaH then break end   -- viewport filled
    end
    love.graphics.setScissor()
end

local function drawPromptBar()
    local req = G.req
    local w = G.L.w
    theme.setColor(theme.colors.bg2)
    love.graphics.rectangle("fill", 0, 0, G.L.playW, 38)
    theme.setColor(theme.colors.line)
    love.graphics.line(0, 38, G.L.playW, 38)

    -- turn / actor / phase, with the active actor's name emphasised in accent.
    local f = theme.fonts.normal
    local phaseCN = ({ judge = "判定", draw = "摸牌", play = "出牌", discard = "弃牌", ["end"] = "结束",
        setup = "准备", ready = "准备", over = "结束" })[G.game.phase] or G.game.phase
    local pre = string.format("第%d回合 · ", G.game.turnCount)
    local nm = G.game.current and G.game.current.name or "—"
    theme.print(pre, f, theme.colors.textDim, 12, 9)
    local x2 = 12 + f:getWidth(pre)
    theme.print(nm, f, theme.colors.accent, x2, 9)
    theme.print(" · " .. phaseCN .. "阶段", f, theme.colors.textDim, x2 + f:getWidth(nm), 9)

    if isHumanDecision() and req.prompt then
        theme.printf("➤ " .. req.prompt, theme.fonts.normal, theme.colors.accent,
            260, 9, G.L.playW - 270, "left")
    elseif G.selecting then
        theme.printf("➤ 选择目标（再次点击该牌取消）", theme.fonts.normal, theme.colors.accent,
            260, 9, G.L.playW - 270, "left")
    elseif not isHumanDecision() and G.req then
        theme.printf("AI 行动中…", theme.fonts.normal, theme.colors.textDim, 260, 9, 200, "left")
    end
end

local function drawButtons()
    local mx, my = love.mouse.getPosition()
    for _, b in ipairs(G.buttons) do
        local hover = theme.pointIn(mx, my, b)
        local col = b.color
        if hover then col = b.danger and { 0.66, 0.34, 0.36 } or theme.colors.btnHover end
        theme.setColor(col)
        theme.rrect("fill", b.x, b.y, b.w, b.h, 6)
        theme.setColor(theme.colors.line)
        theme.rrect("line", b.x, b.y, b.w, b.h, 6)
        local fnt = b.h >= 34 and theme.fonts.normal or theme.fonts.small
        love.graphics.setFont(fnt)
        theme.setColor(theme.colors.text)
        love.graphics.printf(b.label, b.x, b.y + (b.h - fnt:getHeight()) / 2, b.w, "center")
    end
end

local function cardIsCandidate(cardId)
    local req = G.req
    if req and req.kind == "chooseCard" and req.player.isHuman then
        for _, id in ipairs(req.candidates) do if id == cardId then return true end end
    end
    return false
end

local function drawHand()
    local me = humanPlayer()
    local req = G.req
    local restrict = (req and req.kind == "chooseCard" and req.player.isHuman)
    for _, c in ipairs(me.hand) do
        local r = G.handRects[c.id]
        if r then
            local selected = G.selecting and G.selecting.cardId == c.id
            local candidate = cardIsCandidate(c.id)
            local dim = false
            if restrict then
                dim = not candidate
            elseif req and req.kind == "playAction" and req.player.isHuman then
                dim = not cardActionable(me, c)
            end
            drawCardFace(c, r.x, r.y, r.w, r.h, { selected = selected, candidate = candidate, dim = dim })
        end
    end
    -- my identity + win-condition reminder
    theme.print("你的身份：" .. theme.identityCN[me.identity], theme.fonts.small,
        theme.identityColor(me.identity), 16, G.L.h - 168)
    local goal = theme.identityGoal[me.identity]
    if goal then theme.print(goal, theme.fonts.tiny, theme.colors.textDim, 16, G.L.h - 150) end
end

-- a tongue-in-cheek one-line verdict (GDD §8.4 flavor), keyed off identity + outcome,
-- with an extreme play-stat able to steal the headline as a memorable "achievement".
local function reportVerdict(me, meWin)
    local s = me.stats
    -- a truly standout stat is too funny not to lead with, win or lose
    if s.kills >= 3 then return "优化大师：手起刀落，全场最佳 HR 🔪" end
    if s.pua >= 4 then return "PUA 重灾区：建议保留证据走劳动仲裁 ⚖️" end
    if s.blame >= 3 then return "金牌背锅侠：这锅我背得心甘情愿 🎒" end
    -- otherwise: identity + win/loss flavor
    if meWin then
        local won = ({
            boss  = "老板赢麻了：团队稳了，年终奖稳了 💰",
            loyal = "嫡系标兵：跟对了人，吃得开 🤝",
            rebel = "摸鱼党大获全胜：组织起来力量大 🐟🎉",
            spy   = "螳螂捕蝉黄雀在后：最后笑的是你 🪤",
        })[me.identity]
        return won or "赢了：今天的班没白加 🎉"
    end
    if not me.alive then
        local dead = ({
            boss  = "老板被毕业：公司没了，梦也碎了 💼💥",
            loyal = "为老板尽忠到最后一刻，奈何大势已去 🥀",
            rebel = "摸鱼一时爽，被优化火葬场 🔥",
            spy   = "反骨仔的算盘，终究落了空 🧮",
        })[me.identity]
        return dead or "已被「优化」离场，江湖再见 🫡"
    end
    if s.overtimeOut >= 5 then return "加班标兵：把加班打在别人身上 🏆" end
    if s.pie >= 3 then return "画饼充饥：饼是真的香，活是真的多 🥧" end
    if s.dmgTaken == 0 then return "佛系摸鱼：全程毫发无伤，闷声发财 🐟" end
    return "这局没赢：当代打工人的常态，明天接着上 ☕"
end

-- Role-reveal overlay shown at the start of each game.
local function drawIntro()
    if not G.intro then return end
    local w, h = G.L.w, G.L.h
    local me = humanPlayer()
    theme.setColor({ 0, 0, 0 }, 0.8)
    love.graphics.rectangle("fill", 0, 0, w, h)

    local idCol = theme.identityColor(me.identity)
    theme.printf("本局你的身份", theme.fonts.normal, theme.colors.textDim, 0, h * 0.18, w, "center")
    theme.printf("【" .. theme.identityCN[me.identity] .. "】", theme.fonts.huge, idCol, 0, h * 0.18 + 30, w, "center")
    local goal = theme.identityGoal[me.identity]
    theme.printf(goal or "", theme.fonts.normal, theme.colors.text, 0, h * 0.18 + 92, w, "center")

    -- character card
    local bw, bh = 460, 150
    local bx, by = (w - bw) / 2, h * 0.42
    theme.setColor({ 0.10, 0.11, 0.15 }, 0.96)
    theme.rrect("fill", bx, by, bw, bh, 10)
    theme.setColor(idCol, 0.6)
    love.graphics.setLineWidth(1.5)
    theme.rrect("line", bx, by, bw, bh, 10)
    love.graphics.setLineWidth(1)
    theme.printf(string.format("你的角色：%s · %s    精神值 %d", me.char.title, me.char.name, me.maxHp),
        theme.fonts.mid, theme.colors.accent, bx, by + 14, bw, "center")
    theme.printf(me.char.s1 or "", theme.fonts.small, theme.colors.text, bx + 18, by + 52, bw - 36, "left")
    theme.printf(me.char.s2 or "", theme.fonts.small, theme.colors.text, bx + 18, by + 96, bw - 36, "left")

    theme.printf("点击任意处 / 按任意键 开始", theme.fonts.normal, theme.colors.good,
        0, by + bh + 24, w, "center")
end

local function drawGameOver()
    if G.req ~= nil or not G.game.winner then return end
    local w, h = G.L.w, G.L.h
    theme.setColor({ 0, 0, 0 }, 0.78)
    love.graphics.rectangle("fill", 0, 0, w, h)
    local win = G.game.winner
    local txt = ({ boss = "老板阵营胜利", rebel = "摸鱼党胜利", spy = "反骨仔（内奸）胜利",
                   draw = "平局" })[win] or win
    local me = humanPlayer()
    local meWin = G.game:identityWon(me.identity)
    theme.printf(meWin and "🎉 你赢了！" or "你输了", theme.fonts.huge,
        meWin and theme.colors.good or theme.colors.bad, 0, h * 0.14, w, "center")
    theme.printf(txt .. "  ·  你是【" .. theme.identityCN[me.identity] .. "】",
        theme.fonts.big, theme.colors.text, 0, h * 0.14 + 54, w, "center")

    -- 职场报告 stat card
    local s = me.stats
    local rows = {
        { "加班（出）", s.overtimeOut .. " 次" },
        { "被加班", s.overtimeIn .. " 次" },
        { "被 PUA", s.pua .. " 次" },
        { "画饼", s.pie .. " 口" },
        { "甩锅", s.blame .. " 次" },
        { "造成精神打击", s.dmgDealt .. " 点" },
        { "承受精神打击", s.dmgTaken .. " 点" },
        { "「优化」他人", s.kills .. " 人" },
    }
    local bw, rowH = 420, 30
    local bx = (w - bw) / 2
    local by = h * 0.14 + 104
    local bh = 44 + math.ceil(#rows / 2) * rowH + 44
    theme.setColor({ 0.10, 0.11, 0.15 }, 0.96)
    theme.rrect("fill", bx, by, bw, bh, 10)
    theme.setColor(theme.colors.accent, 0.6)
    love.graphics.setLineWidth(1.5)
    theme.rrect("line", bx, by, bw, bh, 10)
    love.graphics.setLineWidth(1)
    theme.printf("📋 你的职场报告 · " .. me.char.title .. "·" .. me.char.name,
        theme.fonts.normal, theme.colors.accent, bx, by + 12, bw, "center")
    -- two-column rows
    local colW = bw / 2
    for i, row in ipairs(rows) do
        local col = (i - 1) % 2
        local rrow = math.floor((i - 1) / 2)
        local rx = bx + 20 + col * colW
        local ry = by + 44 + rrow * rowH
        theme.print(row[1], theme.fonts.small, theme.colors.textDim, rx, ry)
        theme.print(row[2], theme.fonts.small, theme.colors.text, rx + colW - 92, ry)
    end
    theme.printf(reportVerdict(me, meWin), theme.fonts.normal,
        meWin and theme.colors.good or theme.colors.textDim, bx, by + bh - 34, bw, "center")

    -- 全员身份揭晓: the hidden-identity payoff — who everyone actually was, who survived, who won.
    local ps = G.game.players
    local rTop = by + bh + 14
    local rRows = math.ceil(#ps / 2)
    local rRowH = 25
    local rh2 = 30 + rRows * rRowH + 8
    theme.setColor({ 0.10, 0.11, 0.15 }, 0.96)
    theme.rrect("fill", bx, rTop, bw, rh2, 10)
    theme.setColor(theme.colors.accent, 0.45)
    love.graphics.setLineWidth(1.5)
    theme.rrect("line", bx, rTop, bw, rh2, 10)
    love.graphics.setLineWidth(1)
    theme.printf("🎭 全员身份揭晓", theme.fonts.small, theme.colors.accent, bx, rTop + 8, bw, "center")
    local rColW = bw / 2
    for i, p in ipairs(ps) do
        local col = (i - 1) % 2
        local cx = bx + 14 + col * rColW
        local cy = rTop + 32 + math.floor((i - 1) / 2) * rRowH
        local nm = string.format("%d.%s", p.seat, p.char.name)
        if p.id == me.id then nm = nm .. "(你)" end
        theme.print(nm, theme.fonts.small, p.alive and theme.colors.text or theme.colors.textDim, cx, cy)
        theme.print(theme.identityCN[p.identity], theme.fonts.small,
            theme.identityColor(p.identity), cx + rColW - 112, cy)
        theme.print(p.alive and "存活" or "出局", theme.fonts.tiny,
            p.alive and theme.colors.good or theme.colors.bad, cx + rColW - 70, cy + 1)
        if G.game:identityWon(p.identity) then
            theme.print("🏆", theme.fonts.tiny, theme.colors.accent, cx + rColW - 34, cy)
        end
    end

    theme.printf("按 R 或点击「重开」再来一局", theme.fonts.normal, theme.colors.textDim,
        0, rTop + rh2 + 14, w, "center")
end

local function drawHelp()
    if not G.help then return end
    local w, h = G.L.w, G.L.h
    theme.setColor({ 0, 0, 0 }, 0.85)
    love.graphics.rectangle("fill", 0, 0, w, h)
    local lines = {
        "《职海杀》— 职场版三国杀（H 关闭帮助）",
        "",
        "身份：老板(公开) / 嫡系 / 摸鱼党 / 反骨仔",
        "  · 老板+嫡系：消灭所有摸鱼党与反骨仔",
        "  · 摸鱼党：让老板毕业(精神值归零)",
        "  · 反骨仔：先除掉其他所有人，最后单挑老板",
        "  · 老板享主公技：体力补偿，且劣势人数局每回合多摸1张牌",
        "",
        "基本牌：加班(杀) / 摸鱼(闪) / 画饼(桃) / 卷一下(酒)",
        "回合：判定 → 摸2张 → 出牌 → 弃牌(至精神值) → 结束",
        "攻击范围默认1(相邻)，装备武器可扩大；马改变距离。",
        "",
        "操作：点手牌出牌；需要目标时点亮的玩家；",
        "      「技·」按钮发动主动技；「结束回合」结束出牌。",
        "      被加班时点【摸鱼】响应，或点取消承受伤害。",
        "      悬停手牌/玩家可查看牌效果与角色技能。",
        "顶部：人数 可切换 4–8 人重开。局终生成「职场报告」。M 键静音。",
    }
    local y = h * 0.10
    for _, ln in ipairs(lines) do
        theme.printf(ln, theme.fonts.normal, theme.colors.text, w * 0.18, y, w * 0.64, "left")
        y = y + 28
    end
end

-- Draw a multi-line tooltip box near (mx,my), clamped to the play area.
-- lines: list of { text, color, font }.
local function drawTooltip(lines, mx, my)
    local boxW = 286
    local pad = 10
    local innerW = boxW - pad * 2
    -- measure
    local totalH = pad * 2
    local heights = {}
    for _, ln in ipairs(lines) do
        local font = ln.font or theme.fonts.small
        local _, wrapped = font:getWrap(ln.text, innerW)
        local h = math.max(1, #wrapped) * (font:getHeight() + 2)
        heights[#heights + 1] = h
        totalH = totalH + h
    end
    -- position: prefer to the right of the cursor, flip/clamp to stay on-screen
    local x = mx + 18
    if x + boxW > G.L.playW - 6 then x = mx - boxW - 18 end
    if x < 6 then x = 6 end
    local y = my + 8
    if y + totalH > G.L.h - 6 then y = G.L.h - totalH - 6 end
    if y < 6 then y = 6 end

    theme.setColor({ 0.05, 0.06, 0.09 }, 0.96)
    theme.rrect("fill", x, y, boxW, totalH, 8)
    theme.setColor(theme.colors.accent, 0.7)
    love.graphics.setLineWidth(1.5)
    theme.rrect("line", x, y, boxW, totalH, 8)
    love.graphics.setLineWidth(1)

    local yy = y + pad
    for i, ln in ipairs(lines) do
        theme.printf(ln.text, ln.font or theme.fonts.small, ln.color or theme.colors.text,
            x + pad, yy, innerW, "left")
        yy = yy + heights[i]
    end
end

-- Draw transient effects: attack lines (with a traveling spark) and floating
-- ±N spirit-value numbers above the affected player's panel.
local function drawAnims()
    -- suppress lingering effects under the game-over report, but keep ZHS_SHOT_DEMO's
    -- injected effects visible (the game may have ended during the screenshot fast-forward).
    if G.req == nil and not os.getenv("ZHS_SHOT_DEMO") then return end
    for _, a in ipairs(G.anims) do
        local prog = 1 - a.t / a.maxT     -- 0 → 1 over the animation's life
        if a.kind == "attack" then
            local rf, rt = G.playerRects[a.from], G.playerRects[a.to]
            if rf and rt then
                local alpha = a.t / a.maxT
                theme.setColor(theme.colors.bad, alpha * 0.8)
                love.graphics.setLineWidth(3)
                love.graphics.line(rf.cx, rf.cy, rt.cx, rt.cy)
                love.graphics.setLineWidth(1)
                local px = rf.cx + (rt.cx - rf.cx) * prog
                local py = rf.cy + (rt.cy - rf.cy) * prog
                theme.setColor(theme.colors.accent, alpha)
                love.graphics.circle("fill", px, py, 6)
            end
        elseif a.kind == "float" then
            local r = G.playerRects[a.target]
            if r then
                local alpha = math.min(1, a.t / a.maxT * 1.5)
                local y = r.y - 4 - prog * 36
                theme.setColor(a.color, alpha)
                love.graphics.setFont(theme.fonts.big)
                love.graphics.printf(a.text, r.x, y, r.w, "center")
            end
        elseif a.kind == "cardline" then
            local rf, rt = G.playerRects[a.from], G.playerRects[a.to]
            if rf and rt then
                local alpha = a.t / a.maxT * 0.65
                theme.setColor(a.color, alpha)
                love.graphics.setLineWidth(2)
                love.graphics.line(rf.cx, rf.cy, rt.cx, rt.cy)
                love.graphics.setLineWidth(1)
            end
        elseif a.kind == "label" then
            local r = G.playerRects[a.source]
            if r then
                local alpha = math.min(1, a.t / a.maxT * 1.4)
                local y = r.y - 8 - prog * 26
                theme.setColor({ 0, 0, 0 }, alpha * 0.5)
                love.graphics.setFont(theme.fonts.small)
                love.graphics.printf(a.text, r.x - 9, y + 1, r.w + 20, "center")
                theme.setColor(a.color, alpha)
                love.graphics.printf(a.text, r.x - 10, y, r.w + 20, "center")
            end
        end
    end
end

-- Build + draw the hover tooltip for whatever the cursor is over (card or player).
local function drawHoverTooltip()
    if G.help or G.req == nil then return end
    local mx, my = love.mouse.getPosition()
    if mx >= G.L.playW then return end   -- over the log panel

    -- 1) a hand card → show what it does
    local me = humanPlayer()
    for _, c in ipairs(me.hand) do
        local r = G.handRects[c.id]
        if r and theme.pointIn(mx, my, r) then
            local proto = cards.PROTO[c.name]
            local typeCN = c.type == "basic" and "基本牌" or (c.type == "trick" and "锦囊牌" or "装备牌")
            local head = string.format("%s  %s%s · %s", c.name,
                cards.SUIT_CN[c.suit], cards.rankStr(c), typeCN)
            local lines = { { text = head, color = theme.colors.accent, font = theme.fonts.normal } }
            if proto and proto.desc then
                lines[#lines + 1] = { text = proto.desc, color = theme.colors.text }
            end
            if proto and proto.range then
                lines[#lines + 1] = { text = "攻击范围 " .. proto.range, color = theme.colors.textDim }
            end
            -- conversions available to this character
            local convs = G.game:convertOptions(me, c)
            if #convs > 0 then
                lines[#lines + 1] = { text = "可当作：" .. table.concat(convs, "、"),
                    color = theme.colors.cardEquip, font = theme.fonts.small }
            end
            drawTooltip(lines, mx, my)
            return
        end
    end

    -- 2) a player panel → show their character & skills
    for _, p in ipairs(G.game.players) do
        local r = G.playerRects[p.id]
        if r and theme.pointIn(mx, my, r) then
            local lines = {
                { text = string.format("%s · %s    精神值 %d", p.char.title, p.char.name, p.maxHp),
                  color = theme.colors.accent, font = theme.fonts.normal },
            }
            local idk = knownIdentity(p)
            if idk then
                lines[#lines + 1] = { text = "身份：" .. theme.identityCN[idk],
                    color = theme.identityColor(idk), font = theme.fonts.small }
            end
            if p.char.s1 then lines[#lines + 1] = { text = p.char.s1, color = theme.colors.text } end
            if p.char.s2 then lines[#lines + 1] = { text = p.char.s2, color = theme.colors.text } end
            drawTooltip(lines, mx, my)
            return
        end
    end
end

function love.draw()
    if not G.game then return end
    layout()
    -- table felt
    theme.setColor(theme.colors.bg2)
    love.graphics.ellipse("fill", G.L.cx, G.L.cy, G.L.rx + 40, G.L.ry + 40)
    theme.setColor(theme.colors.panel)
    love.graphics.ellipse("line", G.L.cx, G.L.cy, G.L.rx + 40, G.L.ry + 40)
    -- center: the most recent card to hit the discard pile (what was just played),
    -- with deck/discard counts underneath.
    local top = G.game.discard[#G.game.discard]
    if top then
        local cw, ch = 66, 90
        drawCardFace(top, G.L.cx - cw / 2, G.L.cy - ch - 6, cw, ch, {})
    end
    theme.printf(string.format("牌堆 %d   弃牌 %d", #G.game.deck, #G.game.discard),
        theme.fonts.small, theme.colors.textDim, G.L.cx - 100, G.L.cy + 6, 200, "center")

    for _, p in ipairs(G.game.players) do drawPlayer(p) end
    drawAnims()
    drawHand()
    drawLog()
    drawPromptBar()
    drawButtons()

    if G.flash then
        theme.setColor({ 0, 0, 0 }, 0.6 * math.min(1, G.flash.t))
        theme.rrect("fill", G.L.playW / 2 - 160, G.L.h * 0.5, 320, 40, 8)
        theme.printf(G.flash.text, theme.fonts.normal, theme.colors.text,
            G.L.playW / 2 - 160, G.L.h * 0.5 + 10, 320, "center")
    end

    drawHoverTooltip()
    drawGameOver()
    drawIntro()
    drawHelp()

    -- hint bottom-left
    theme.print("H 帮助 · M 静音 · 悬停查看牌/角色", theme.fonts.tiny, theme.colors.textDim, 8, G.L.h - 16)
end

----------------------------------------------------------------------
-- input
----------------------------------------------------------------------
-- can this hand card be played in some way right now (natively or via a conversion)?
function cardActionable(me, c)
    if G.game:canPlayInPhase(me, c) then return true end
    for _, asName in ipairs(G.game:convertOptions(me, c)) do
        if G.game:canPlayConverted(me, c, asName) then return true end
    end
    return false
end

-- commit a play: asName=nil plays natively, otherwise plays the card as the converted trick/加班.
function commitPlay(c, asName)
    local me = humanPlayer()
    local effName = asName or c.name
    local effCard = asName and G.game:effectiveCard(c, asName) or c
    local targeted = TARGETED[effName] == true
    if not targeted then
        step({ type = "playCard", cardId = c.id, targetIds = {}, as = asName })
        return
    end
    local targets = G.game:validTargets(me, effCard)
    if #targets == 0 then
        flash("没有合法目标")
    elseif #targets == 1 and not (effName == "画饼" and targets[1].id ~= me.id) then
        -- 画饼 onto someone else always asks first (so you can't mis-click a heal to an enemy)
        step({ type = "playCard", cardId = c.id, targetIds = { targets[1].id }, as = asName })
    else
        G.selecting = { cardId = c.id, asName = asName, targetIds = {} }
        for _, t in ipairs(targets) do G.selecting.targetIds[#G.selecting.targetIds + 1] = t.id end
    end
end

function tryPlayCard(c)
    local me = humanPlayer()
    local opts = {}
    if G.game:canPlayInPhase(me, c) then
        opts[#opts + 1] = { label = (c.type == "equip" and "装备" or "使用") .. c.name, asName = nil }
    end
    for _, asName in ipairs(G.game:convertOptions(me, c)) do
        if G.game:canPlayConverted(me, c, asName) then
            opts[#opts + 1] = { label = "当作【" .. asName .. "】使用", asName = asName }
        end
    end
    if #opts == 0 then
        flash("该牌现在无法使用")
    elseif #opts == 1 then
        commitPlay(c, opts[1].asName)
    else
        G.cardMenu = { cardId = c.id, options = opts }
    end
end

function love.mousepressed(mx, my, button)
    if button ~= 1 or not G.game then return end
    if G.intro then G.intro = false; return end   -- dismiss role-reveal overlay
    if G.help then G.help = false; return end      -- a click anywhere closes help (and is swallowed)
    layout()

    -- buttons first (includes the card-conversion menu options)
    for _, b in ipairs(G.buttons) do
        if theme.pointIn(mx, my, b) then b.action() return end
    end

    -- a click that missed the open conversion menu closes it
    if G.cardMenu then G.cardMenu = nil; return end

    local req = G.req

    -- target selection during play phase
    if G.selecting then
        for _, id in ipairs(G.selecting.targetIds) do
            local r = G.playerRects[id]
            if r and theme.pointIn(mx, my, r) then
                step({ type = "playCard", cardId = G.selecting.cardId,
                    targetIds = { id }, as = G.selecting.asName })
                return
            end
        end
        -- click the selected card again to cancel
        local hr = G.handRects[G.selecting.cardId]
        if hr and theme.pointIn(mx, my, hr) then G.selecting = nil return end
        return
    end

    if not (req and req.player and req.player.isHuman) then return end

    if req.kind == "playAction" then
        for _, c in ipairs(humanPlayer().hand) do
            local r = G.handRects[c.id]
            if r and theme.pointIn(mx, my, r) then tryPlayCard(c) return end
        end
    elseif req.kind == "chooseCard" then
        for _, id in ipairs(req.candidates) do
            local r = G.handRects[id]
            if r and theme.pointIn(mx, my, r) then step(id) return end
        end
    elseif req.kind == "chooseTarget" then
        for _, id in ipairs(req.candidates) do
            local r = G.playerRects[id]
            if r and theme.pointIn(mx, my, r) then step(id) return end
        end
    end
end

function love.wheelmoved(_, dy)
    -- clamp to the real scrollback so over-scrolling can't pin the view away from new lines
    G.logScroll = math.max(0, math.min(G.logMaxScroll or 0, G.logScroll + dy * 3))
end

function love.keypressed(key)
    if G.intro then
        if key == "escape" then love.event.quit() else G.intro = false end
        return
    end
    if key == "h" then G.help = not G.help
    elseif key == "r" then newGame(G.numPlayers)
    elseif key == "m" then
        local on = sound.toggle()
        flash(on and "音效已开启" or "音效已静音")
    elseif key == "escape" then
        if G.help then G.help = false else love.event.quit() end
    end
end

function love.resize() end
