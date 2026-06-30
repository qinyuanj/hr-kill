-- 《职海杀》LÖVE configuration
function love.conf(t)
    t.identity = "zhihaisha"
    t.version = "11.4"
    t.window.title = "职海杀 · HR Kill"
    t.window.width = 1280
    t.window.height = 800
    t.window.minwidth = 1024
    t.window.minheight = 680
    t.window.resizable = true
    t.window.highdpi = true
    -- vsync blocks frame present when the display is asleep/headless, which stalls
    -- screenshot captures. Disable it for --shot runs (set ZHS_SHOT=1).
    t.window.vsync = os.getenv("ZHS_SHOT") and 0 or 1
    t.modules.joystick = false
    t.modules.physics = false
end
