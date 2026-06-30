-- sound_test.lua — exercise procedural sound generation with a functional stub of
-- love.sound / love.audio, verifying the generator logic (sample loops, envelopes,
-- source creation) runs without error and produces in-range samples.
--   lua test/sound_test.lua
package.path = "./?.lua;" .. package.path

local samplesSeen = 0
local srcMt = { __index = {} }
function srcMt.__index:stop() end
function srcMt.__index:play() end
function srcMt.__index:setVolume() end

local sdMt = { __index = {} }
function sdMt.__index:setSample(i, v)
    assert(type(i) == "number" and i >= 0, "bad sample index " .. tostring(i))
    assert(type(v) == "number" and v >= -1 and v <= 1, "sample out of range: " .. tostring(v))
    samplesSeen = samplesSeen + 1
end

_G.love = {
    sound = {
        newSoundData = function(n, rate, bits, ch)
            assert(n >= 1 and rate == 44100 and bits == 16 and ch == 1)
            return setmetatable({ n = n }, sdMt)
        end,
    },
    audio = {
        newSource = function(_sd, mode) assert(mode == "static"); return setmetatable({}, srcMt) end,
    },
}

local sound = require("src.sound")

local failed = 0
local function check(cond, msg)
    if cond then print("  ok   " .. msg) else failed = failed + 1; print("  FAIL " .. msg) end
end

sound.load()
check(sound.enabled, "sound.load enabled with functional audio stub")
local n = 0; for _ in pairs(sound.sources) do n = n + 1 end
check(n == 7, "generated 7 sources (got " .. n .. ")")
check(samplesSeen > 1000, "wrote many samples (" .. samplesSeen .. ")")
for _, name in ipairs({ "attack", "damage", "heal", "card", "death", "win", "lose" }) do
    check(sound.sources[name] ~= nil, "source exists: " .. name)
end
-- play / toggle should never error
sound.play("attack", 0.5)
sound.play("nonexistent")
local off = sound.toggle()
check(off == false, "toggle disables")
sound.play("attack")   -- muted: no-op, must not error

-- self-degrades when audio is unavailable
package.loaded["src.sound"] = nil
_G.love = nil
local sound2 = require("src.sound")
sound2.load()
check(not sound2.enabled, "self-disables without love.sound/audio")
sound2.play("attack")  -- must be a safe no-op

print(string.format("==== sound_test: %s ====", failed == 0 and "all passed" or (failed .. " failed")))
os.exit(failed == 0 and 0 or 1)
