-- ui_smoke.lua — exercise the LÖVE UI code paths without a real LÖVE runtime.
-- Stubs `love`, enables AUTOPLAY (AI drives every seat), and runs many full
-- frames calling update()+draw() each tick so layout/draw/button code executes.
--   lua test/ui_smoke.lua [frames]
package.path = "./?.lua;" .. package.path

-- ---- minimal love stub --------------------------------------------------
local function noop() end
local fontMt = {}
fontMt.__index = fontMt
function fontMt:getWidth(s) return (#tostring(s)) * 8 end
function fontMt:getHeight() return 18 end
function fontMt:getWrap(text, w)
    -- pretend each line wraps to 1 segment
    return w, { text }
end
local function newFont() return setmetatable({}, fontMt) end

local W, H = 1280, 800
_G.love = {
    graphics = {
        getDimensions = function() return W, H end,
        getWidth = function() return W end,
        getHeight = function() return H end,
        setBackgroundColor = noop, setColor = noop, setFont = noop, setLineWidth = noop,
        rectangle = noop, line = noop, circle = noop, ellipse = noop, print = noop,
        polygon = noop, arc = noop, points = noop,
        printf = noop, setScissor = noop, newFont = newFont,
    },
    filesystem = {
        newFileData = function() return {} end,
    },
    keyboard = { setKeyRepeat = noop },
    mouse = { getPosition = function() return 0, 0 end },
    event = { quit = noop },
    timer = { getTime = function() return 0 end },
}
-- io.open for fonts: pretend none found so it falls back to newFont()
local realOpen = io.open
io.open = function(path, mode)
    if path and path:find("Font") then return nil end
    return realOpen(path, mode)
end

_G.AUTOPLAY = true

-- ---- load the game ------------------------------------------------------
dofile("main.lua")
local love = _G.love

love.load()

local frames = tonumber(arg and arg[1]) or 6000
local games = 0
local errors = 0
for i = 1, frames do
    local ok, err = pcall(function()
        love.update(0.016)
        love.draw()
    end)
    if not ok then
        errors = errors + 1
        print("FRAME " .. i .. " ERROR: " .. tostring(err))
        if errors > 5 then break end
    end
    -- when a game ends, AUTOPLAY leaves G.req == nil; poke a restart via keypressed("r")
    -- We can't see G directly, so simulate the restart key periodically.
    if i % 800 == 0 then
        pcall(love.keypressed, "r")
        games = games + 1
    end
end

-- also exercise input dispatch + help overlay without crashing
pcall(love.keypressed, "h")
pcall(love.draw)
pcall(love.keypressed, "h")
pcall(love.mousepressed, 10, 10, 1)
pcall(love.wheelmoved, 0, -1)
pcall(love.resize, 1024, 768)

print(string.format("ui_smoke done: frames=%d restarts=%d errors=%d", frames, games, errors))
os.exit(errors == 0 and 0 or 1)
