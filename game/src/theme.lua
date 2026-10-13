-- theme.lua — colors, fonts, and small drawing helpers for the LÖVE UI.
local theme = {}

theme.colors = {
    bg        = { 0.08, 0.09, 0.12 },
    bg2       = { 0.12, 0.13, 0.17 },
    panel     = { 0.16, 0.17, 0.22 },
    panelLite = { 0.22, 0.24, 0.30 },
    panelTurn = { 0.30, 0.26, 0.12 },   -- active player's panel tint
    text      = { 0.92, 0.93, 0.96 },
    textDim   = { 0.62, 0.65, 0.72 },
    line      = { 0.30, 0.32, 0.40 },
    accent    = { 0.95, 0.78, 0.30 },
    good      = { 0.40, 0.80, 0.45 },
    bad       = { 0.90, 0.35, 0.35 },
    hpFull    = { 0.45, 0.85, 0.55 },
    hpEmpty   = { 0.30, 0.20, 0.22 },
    hpLow     = { 0.90, 0.45, 0.35 },

    -- identities
    boss   = { 0.97, 0.80, 0.30 },
    loyal  = { 0.45, 0.70, 0.98 },
    rebel  = { 0.95, 0.45, 0.45 },
    spy    = { 0.78, 0.55, 0.95 },
    hidden = { 0.55, 0.57, 0.64 },

    -- card types
    cardBasic = { 0.86, 0.72, 0.42 },
    cardTrick = { 0.55, 0.72, 0.95 },
    cardEquip = { 0.62, 0.85, 0.70 },
    cardBack  = { 0.30, 0.22, 0.28 },
    cardRed   = { 0.90, 0.36, 0.40 },
    cardBlack = { 0.20, 0.22, 0.28 },

    btn       = { 0.24, 0.34, 0.50 },
    btnHover  = { 0.32, 0.46, 0.66 },
    btnDanger = { 0.50, 0.26, 0.28 },
    highlight = { 0.95, 0.82, 0.35 },
    targetable= { 0.45, 0.90, 0.55 },
}

theme.identityCN = { boss = "老板", loyal = "嫡系", rebel = "摸鱼党", spy = "反骨仔" }
-- Per-identity win-condition reminder (single source of truth; used by the intro
-- overlay and the in-game hand panel — keep wording here, not inlined per call site).
theme.identityGoal = {
    boss  = "目标：清除所有摸鱼党与反骨仔",
    loyal = "目标：辅佐老板，共同获胜",
    rebel = "目标：让老板毕业（精神值归零）",
    spy   = "目标：除你外全员阵亡，最后亲手击杀老板",
}
theme.identityColor = function(id) return theme.colors[id] or theme.colors.hidden end

-- Prefer the bundled release font, then system fonts (read once, build several sizes).
function theme.loadFonts()
    local candidates = {
        "/System/Library/Fonts/STHeiti Medium.ttc",
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
        "C:/Windows/Fonts/msyh.ttc",
        "C:/Windows/Fonts/simhei.ttf",
    }
    local data
    if love.filesystem.getInfo and love.filesystem.getInfo("assets/fonts/NotoSansCJKsc-Regular.otf") then
        local ok, fd = pcall(love.filesystem.newFileData, "assets/fonts/NotoSansCJKsc-Regular.otf")
        if ok then data = fd end
    end
    for _, p in ipairs(candidates) do
        if data then break end
        local f = io.open(p, "rb")
        if f then
            local bytes = f:read("*a"); f:close()
            if bytes and #bytes > 1000 then
                local ok, fd = pcall(love.filesystem.newFileData, bytes, "cjk_font")
                if ok then data = fd break end
            end
        end
    end
    local function mk(size)
        if data then
            local ok, font = pcall(love.graphics.newFont, data, size)
            if ok then return font end
        end
        return love.graphics.newFont(size)
    end
    theme.fonts = {
        tiny   = mk(12),
        small  = mk(14),
        normal = mk(17),
        mid    = mk(20),
        big    = mk(26),
        huge   = mk(40),
    }
    theme.hasCJK = data ~= nil
    return theme.fonts
end

-- helpers ----------------------------------------------------------
function theme.setColor(c, a)
    love.graphics.setColor(c[1], c[2], c[3], a or 1)
end

function theme.rrect(mode, x, y, w, h, r)
    love.graphics.rectangle(mode, x, y, w, h, r or 6, r or 6)
end

function theme.printf(text, font, color, x, y, w, align)
    love.graphics.setFont(font)
    theme.setColor(color)
    love.graphics.printf(text, x, y, w, align or "left")
end

function theme.print(text, font, color, x, y)
    love.graphics.setFont(font)
    theme.setColor(color)
    love.graphics.print(text, x, y)
end

function theme.pointIn(px, py, r)
    return r and px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h
end

return theme
