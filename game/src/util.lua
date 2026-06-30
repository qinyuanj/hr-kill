-- util.lua — helpers shared by engine, AI and UI. Pure Lua, no love dependency.
local util = {}

util.unpack = table.unpack or unpack

-- A small deterministic-seedable RNG wrapper so headless tests are reproducible
-- and so we never depend on love.math. Uses a xorshift-ish LCG.
local RNG = {}
RNG.__index = RNG
function util.newRng(seed)
    local r = setmetatable({}, RNG)
    r.state = (seed or 0x2545F491) % 2147483647
    if r.state <= 0 then r.state = r.state + 2147483646 end
    return r
end
function RNG:next()
    -- Park-Miller minimal standard
    self.state = (self.state * 16807) % 2147483647
    return self.state
end
-- random integer in [a, b]
function RNG:int(a, b)
    if b == nil then a, b = 1, a end
    if b < a then return a end
    return a + (self:next() % (b - a + 1))
end
-- random float in [0,1)
function RNG:float()
    return (self:next() - 1) / 2147483646
end
function RNG:shuffle(t)
    for i = #t, 2, -1 do
        local j = self:int(1, i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end
function RNG:pick(t)
    if #t == 0 then return nil end
    return t[self:int(1, #t)]
end

function util.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

function util.contains(t, v)
    for i = 1, #t do if t[i] == v then return true end end
    return false
end

function util.removeValue(t, v)
    for i = 1, #t do
        if t[i] == v then
            table.remove(t, i)
            return true
        end
    end
    return false
end

function util.count(t, pred)
    local n = 0
    for i = 1, #t do if pred(t[i]) then n = n + 1 end end
    return n
end

function util.filter(t, pred)
    local out = {}
    for i = 1, #t do if pred(t[i]) then out[#out + 1] = t[i] end end
    return out
end

function util.map(t, fn)
    local out = {}
    for i = 1, #t do out[i] = fn(t[i]) end
    return out
end

function util.keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    return out
end

function util.copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

return util
