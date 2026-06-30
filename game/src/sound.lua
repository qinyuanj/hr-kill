-- sound.lua — tiny procedural sound effects, generated at load (no asset files).
-- Self-degrading: if love.sound / love.audio are unavailable (e.g. the headless UI
-- smoke test), every call becomes a no-op instead of erroring. Tones are short,
-- sine-based with smooth attack/decay envelopes, and quiet — meant to be subtle.
local sound = {}

sound.enabled = true
sound.sources = {}
local RATE = 44100

-- Generate one Source from a per-sample function f(t) -> amplitude in [-1,1].
local function gen(dur, f)
    local n = math.max(1, math.floor(RATE * dur))
    local sd = love.sound.newSoundData(n, RATE, 16, 1)
    for i = 0, n - 1 do
        local t = i / RATE
        local v = f(t)
        if v < -1 then v = -1 elseif v > 1 then v = 1 end
        sd:setSample(i, v)
    end
    return love.audio.newSource(sd, "static")
end

-- smooth attack/decay envelope
local function env(t, dur, atk)
    atk = atk or 0.01
    if t < atk then return t / atk end
    return math.max(0, 1 - (t - atk) / (dur - atk))
end

local sin = math.sin
local TAU = math.pi * 2

function sound.load()
    if not (love and love.sound and love.audio) then
        sound.enabled = false
        return
    end
    local ok = pcall(function()
        -- 加班/攻击：低沉的双频"咚"
        sound.sources.attack = gen(0.16, function(t)
            return 0.5 * env(t, 0.16, 0.004) * (sin(TAU * 150 * t) + 0.4 * sin(TAU * 90 * t))
        end)
        -- 受伤：短促下滑
        sound.sources.damage = gen(0.18, function(t)
            local f = 320 - 600 * t
            return 0.4 * env(t, 0.18) * sin(TAU * f * t)
        end)
        -- 回复：柔和上行两音
        sound.sources.heal = gen(0.26, function(t)
            local f = (t < 0.13) and 520 or 660
            return 0.32 * env(t, 0.26, 0.02) * sin(TAU * f * t)
        end)
        -- 出牌：轻点击
        sound.sources.card = gen(0.06, function(t)
            return 0.3 * env(t, 0.06, 0.002) * sin(TAU * 440 * t)
        end)
        -- 阵亡：低沉下行
        sound.sources.death = gen(0.45, function(t)
            local f = 240 - 200 * t
            return 0.4 * env(t, 0.45, 0.01) * sin(TAU * f * t)
        end)
        -- 胜利：上行三音琶音
        sound.sources.win = gen(0.5, function(t)
            local f = (t < 0.16 and 523) or (t < 0.32 and 659) or 784
            return 0.34 * env(t, 0.5, 0.01) * sin(TAU * f * t)
        end)
        -- 失败：下行两音
        sound.sources.lose = gen(0.5, function(t)
            local f = (t < 0.25) and 330 or 247
            return 0.34 * env(t, 0.5, 0.01) * sin(TAU * f * t)
        end)
    end)
    if not ok then sound.enabled = false end
end

function sound.play(name, volume)
    if not sound.enabled then return end
    local src = sound.sources[name]
    if not src then return end
    src:stop()
    src:setVolume(volume or 0.6)
    src:play()
end

function sound.toggle()
    sound.enabled = not sound.enabled
    return sound.enabled
end

return sound
