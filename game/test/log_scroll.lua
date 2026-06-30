-- log_scroll.lua — regression test for the battle-log panel's ROW-based budgeting.
-- The bug: drawLog budgeted by entry count but rendered by wrapped-row height, so long
-- (wrapping) CJK log lines overflowed the panel and the NEWEST lines were clipped below
-- the scissor and unreachable by scrolling. This test drives a font stub that wraps long
-- lines to multiple rows and asserts the newest rendered log line stays within the panel.
--   lua test/log_scroll.lua
package.path = "./?.lua;" .. package.path

-- ---- love stub whose font WRAPS long strings to multiple rows --------------
local function noop() end
local fontMt = {}
fontMt.__index = fontMt
function fontMt:getWidth(s) return (#tostring(s)) * 8 end
function fontMt:getHeight() return 18 end
function fontMt:getWrap(text, _)
    -- ~40 bytes per visual row → real CJK report lines (30–90 bytes) wrap to 1–3 rows.
    local n = math.max(1, math.ceil(#tostring(text) / 40))
    local segs = {}
    for i = 1, n do segs[i] = "row" .. i end
    return 0, segs
end
local function newFont() return setmetatable({}, fontMt) end

local W, H = 1280, 800
_G.love = {
    graphics = {
        getDimensions = function() return W, H end,
        getWidth = function() return W end, getHeight = function() return H end,
        setBackgroundColor = noop, setColor = noop, setFont = noop, setLineWidth = noop,
        rectangle = noop, line = noop, circle = noop, ellipse = noop, print = noop,
        polygon = noop, arc = noop, points = noop, printf = noop,
        setScissor = noop, newFont = newFont,
    },
    filesystem = { newFileData = function() return {} end },
    keyboard = { setKeyRepeat = noop },
    mouse = { getPosition = function() return 0, 0 end },
    event = { quit = noop },
    timer = { getTime = function() return 0 end },
}
local realOpen = io.open
io.open = function(path, mode)
    if path and path:find("Font") then return nil end
    return realOpen(path, mode)
end

_G.AUTOPLAY = true
dofile("main.lua")
local theme = require("src.theme")   -- same cached instance main.lua uses
local love = _G.love

love.load()

-- Run frames so AUTOPLAY builds up a long battle log (well past one panel-height).
for _ = 1, 600 do pcall(function() love.update(0.016); love.draw() end) end

-- The log panel sits on the right; capture printf calls there for one draw.
local function captureLogDraw()
    local cap = {}
    local real = theme.printf
    theme.printf = function(text, font, col, x, y, ww, align)
        if x and x > W * 0.74 and y and y > 70 then cap[#cap + 1] = y end   -- log-panel rows
        return real(text, font, col, x, y, ww, align)
    end
    pcall(love.draw)
    theme.printf = real
    return cap
end

local areaY, areaH = 76, H - 76 - 12     -- mirrors drawLog
local lineH = 18 + 4
local fails = 0
local function check(name, cond, detail)
    if cond then print("  ok   " .. name)
    else fails = fails + 1; print("  FAIL " .. name .. "  (" .. tostring(detail) .. ")") end
end

print("[log_scroll] battle-log row budgeting (newest line stays in the panel)")

local cap = captureLogDraw()
local maxY, minY = -1, 1e9
for _, y in ipairs(cap) do if y > maxY then maxY = y end; if y < minY then minY = y end end

check("log panel renders lines", #cap > 0, "#cap=" .. #cap)
-- the log is long enough that it fills well past half the panel (so clipping WOULD bite)
check("log fills the panel (long log exercised)", maxY > areaY + areaH * 0.5,
    "maxY=" .. maxY .. " areaY+areaH/2=" .. (areaY + areaH * 0.5))
-- the newest (bottom-most) line starts inside the panel, not clipped below the scissor
check("newest line is within the panel (not clipped below)", maxY < areaY + areaH,
    "maxY=" .. maxY .. " panelBottom=" .. (areaY + areaH))
-- nothing renders above the panel top
check("no line above the panel top", minY >= areaY - lineH,
    "minY=" .. minY .. " areaY=" .. areaY)

-- scrolling up reveals older content and must not crash or escape the panel
pcall(love.wheelmoved, 0, 8)
local cap2 = captureLogDraw()
local maxY2 = -1
for _, y in ipairs(cap2) do if y > maxY2 then maxY2 = y end end
check("after scroll-up, lines still within the panel", #cap2 > 0 and maxY2 < areaY + areaH,
    "#cap2=" .. #cap2 .. " maxY2=" .. maxY2)

-- scrolling back down to the bottom restores the newest-line-at-bottom view
pcall(love.wheelmoved, 0, -100)
local cap3 = captureLogDraw()
local maxY3 = -1
for _, y in ipairs(cap3) do if y > maxY3 then maxY3 = y end end
check("after scroll back down, newest line near the bottom again", maxY3 > areaY + areaH * 0.5,
    "maxY3=" .. maxY3)

print(string.format("\n==== log_scroll: %s ====", fails == 0 and "PASS" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
