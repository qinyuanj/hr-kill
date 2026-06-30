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
    t.window.vsync = 1
    t.modules.joystick = false
    t.modules.physics = false
end
