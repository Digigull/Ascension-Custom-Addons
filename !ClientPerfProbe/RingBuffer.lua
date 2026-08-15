--[[ RingBuffer.lua — capped ring buffer (PURE LOGIC, self-tested offline)

    No WoW APIs. Loadable under bare Lua 5.1 for `make test`.
    Stores plain records so the whole buffer can live in SavedVariables
    (WoW serializes plain tables only) and be restored across sessions.

    Semantics: push() overwrites the oldest slot once capacity is reached.
    toArray() returns oldest -> newest.
]]

local ADDON, ns = ...
ns = ns or {}

local RingBuffer = {}
RingBuffer.__index = RingBuffer

-- new(capacity) -> ring buffer holding at most `capacity` items.
function RingBuffer.new(capacity)
    assert(type(capacity) == "number" and capacity >= 1,
        "RingBuffer.new: capacity must be a number >= 1")
    return setmetatable({
        capacity = math.floor(capacity),
        items = {},   -- slot (1..capacity) -> value
        w = 0,        -- total pushes ever (monotonic)
    }, RingBuffer)
end

-- restore(saved) -> rebuild a buffer from a SavedVariables blob produced by
-- serialize(). Defensive: any malformed field falls back to an empty buffer.
function RingBuffer.restore(saved)
    if type(saved) ~= "table" or type(saved.capacity) ~= "number" then
        return RingBuffer.new(1)
    end
    local rb = RingBuffer.new(saved.capacity)
    if type(saved.items) == "table" and type(saved.w) == "number" then
        rb.items = saved.items
        rb.w = math.floor(saved.w)
    end
    return rb
end

local function slotOf(w, capacity)
    return ((w - 1) % capacity) + 1
end

function RingBuffer:push(v)
    self.w = self.w + 1
    self.items[slotOf(self.w, self.capacity)] = v
    return v
end

-- how many live items (<= capacity).
function RingBuffer:count()
    local w = self.w
    return (w < self.capacity) and w or self.capacity
end

-- oldest -> newest as a dense array.
function RingBuffer:toArray()
    local n = self:count()
    local out = {}
    local first = self.w - n + 1  -- push index of the oldest live item
    for i = 0, n - 1 do
        out[i + 1] = self.items[slotOf(first + i, self.capacity)]
    end
    return out
end

-- newest -> oldest, capped at `limit` (nil = all). Cheap for "recent N".
function RingBuffer:recent(limit)
    local n = self:count()
    if limit and limit < n then n = limit end
    local out = {}
    for i = 0, n - 1 do
        out[i + 1] = self.items[slotOf(self.w - i, self.capacity)]
    end
    return out
end

function RingBuffer:clear()
    self.items = {}
    self.w = 0
end

-- keepIf(pred): rebuild the buffer keeping only items where pred(item) is truthy,
-- preserving oldest -> newest order. Returns how many items were removed. Used for
-- time-scoped clears (drop spikes newer than a cutoff, keep the rest).
function RingBuffer:keepIf(pred)
    local arr = self:toArray()
    local before = #arr
    self.items = {}
    self.w = 0
    for i = 1, before do
        if pred(arr[i]) then self:push(arr[i]) end
    end
    return before - self:count()
end

-- plain-table form for SavedVariables.
function RingBuffer:serialize()
    return { capacity = self.capacity, items = self.items, w = self.w }
end

ns.RingBuffer = RingBuffer

--============================================================================--
if _SELFTEST then
    local function eq(a, b, msg)
        assert(a == b, (msg or "eq") .. ": expected " .. tostring(b) .. " got " .. tostring(a))
    end
    local function arrEq(got, want, msg)
        assert(#got == #want, (msg or "arrEq") .. ": length " .. #got .. " vs " .. #want)
        for i = 1, #want do eq(got[i], want[i], (msg or "arrEq") .. "[" .. i .. "]") end
    end

    -- under capacity
    local rb = RingBuffer.new(3)
    eq(rb:count(), 0, "empty count")
    arrEq(rb:toArray(), {}, "empty toArray")
    rb:push(1); rb:push(2)
    eq(rb:count(), 2, "partial count")
    arrEq(rb:toArray(), {1, 2}, "partial order")

    -- exactly full
    rb:push(3)
    eq(rb:count(), 3, "full count")
    arrEq(rb:toArray(), {1, 2, 3}, "full order")

    -- overflow: oldest dropped
    rb:push(4); rb:push(5)
    eq(rb:count(), 3, "overflow count stays capped")
    arrEq(rb:toArray(), {3, 4, 5}, "overflow drops oldest")

    -- recent newest-first + limit
    arrEq(rb:recent(2), {5, 4}, "recent(2)")
    arrEq(rb:recent(), {5, 4, 3}, "recent(all)")

    -- serialize / restore round-trips including wrap state
    local rb2 = RingBuffer.restore(rb:serialize())
    arrEq(rb2:toArray(), {3, 4, 5}, "restore preserves order")
    rb2:push(6)
    arrEq(rb2:toArray(), {4, 5, 6}, "restored buffer keeps wrapping correctly")

    -- restore is defensive
    local rb3 = RingBuffer.restore(nil)
    eq(rb3:count(), 0, "restore(nil) -> empty")
    local rb4 = RingBuffer.restore("garbage")
    eq(rb4:count(), 0, "restore(garbage) -> empty")

    -- clear
    rb:clear()
    eq(rb:count(), 0, "clear count")
    arrEq(rb:toArray(), {}, "clear toArray")

    -- keepIf: time-scoped trim — keep items with t < cutoff (drop the recent ones),
    -- order preserved, count returned. Mirrors "clear last N min".
    local tb = RingBuffer.new(5)
    for _, t in ipairs({ 10, 20, 30, 40, 50 }) do tb:push({ t = t }) end
    local removed = tb:keepIf(function(sp) return sp.t < 35 end)  -- drop 40, 50
    eq(removed, 2, "keepIf removed count")
    eq(tb:count(), 3, "keepIf kept count")
    arrEq((function() local o = {} for _, v in ipairs(tb:toArray()) do o[#o+1] = v.t end return o end)(),
          { 10, 20, 30 }, "keepIf kept the older items in order")
    tb:push({ t = 60 })  -- buffer still works after a keepIf rebuild
    eq(tb:count(), 4, "keepIf-rebuilt buffer keeps accepting pushes")
    -- keepIf that keeps nothing empties the buffer
    eq(tb:keepIf(function() return false end), 4, "keepIf(false) removes all")
    eq(tb:count(), 0, "keepIf(false) empties")

    -- capacity 1 degenerate case
    local one = RingBuffer.new(1)
    one:push("a"); one:push("b")
    eq(one:count(), 1, "cap1 count")
    arrEq(one:toArray(), {"b"}, "cap1 keeps newest")

    print("RingBuffer: OK")
end

return ns.RingBuffer
