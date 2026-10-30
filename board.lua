local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local UndoStack = require("undo_stack")
local Timer     = require("timer")
local Hint      = require("hint")
local Solver    = lrequire("solver")

local floor = math.floor

local DEFAULT_MAX_DIGIT  = 4
local DEFAULT_DIFFICULTY = "medium"

-- Which logical level (see solver.lua) a difficulty asks for: easy needs
-- singles only, medium needs the shared-cell rule, hard needs a one-step
-- trial. The generator aims at that exact level.
local DIFFICULTY_LEVEL = { easy = 1, medium = 2, hard = 3 }

-- ---------------------------------------------------------------------------
-- Generator helpers
-- ---------------------------------------------------------------------------

-- A random domino tiling of a rows x cols grid, as partner[cell] = cell.
-- Starts from straight rows (or columns) and applies random 2x2 flips; flips
-- connect every tiling of a rectangle, so this walks the whole space.
local function randomTiling(rows, cols)
    local part = {}
    local function id(r, c) return (r - 1) * cols + c end
    for r = 1, rows do
        for c = 1, cols do
            if cols % 2 == 0 then
                if c % 2 == 1 then part[id(r, c)] = id(r, c + 1); part[id(r, c + 1)] = id(r, c) end
            elseif r % 2 == 1 then
                part[id(r, c)] = id(r + 1, c); part[id(r + 1, c)] = id(r, c)
            end
        end
    end
    for _ = 1, rows * cols * 30 do
        local r, c = math.random(rows - 1), math.random(cols - 1)
        local a, b, d1, d2 = id(r, c), id(r, c + 1), id(r + 1, c), id(r + 1, c + 1)
        if part[a] == b and part[d1] == d2 then
            part[a], part[d1], part[b], part[d2] = d1, a, d2, b
        elseif part[a] == d1 and part[b] == d2 then
            part[a], part[b], part[d1], part[d2] = b, a, d2, d1
        end
    end
    return part
end

-- How far a numbering is from being solved at `level`: the placements still
-- possible once the logic has run (0 = solved). Lower is better; a
-- contradiction cannot happen for a numbering built from a real tiling.
local function remaining(digits, rows, cols, m, level)
    local model = Solver.buildModel(digits, rows, cols, m)
    local st = Solver.newState(model)
    if not Solver.propagate(model, st, level) then return math.huge end
    local n = 0
    for k = 1, model.nplacements do
        if st.alive[k] then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- DominosaBoard
-- ---------------------------------------------------------------------------

local DominosaBoard = {}
DominosaBoard.__index = DominosaBoard

function DominosaBoard:new(opts)
    opts = opts or {}
    local m = opts.max_digit or DEFAULT_MAX_DIGIT
    local obj = setmetatable({
        m          = m,
        rows       = m + 1,
        cols       = m + 2,
        difficulty = opts.difficulty or DEFAULT_DIFFICULTY,
        digits     = {},
        solution   = {},   -- solution[cell] = partner cell
        partner    = {},   -- player's dominoes, partner[cell] = cell
        barriers   = {},   -- player's "no domino here" marks, edgeKey -> true
        selected   = nil,  -- cell id awaiting its partner
        undo       = UndoStack:new{ max_size = 300 },
        timer      = Timer:new(),
        hints_used = 0,
    }, self)
    return obj
end

-- ---------------------------------------------------------------------------
-- Cell helpers
-- ---------------------------------------------------------------------------

function DominosaBoard:cellId(r, c) return (r - 1) * self.cols + c end

function DominosaBoard:cellRC(id)
    return floor((id - 1) / self.cols) + 1, (id - 1) % self.cols + 1
end

function DominosaBoard:digitAt(id)
    local r, c = self:cellRC(id)
    return self.digits[r][c]
end

function DominosaBoard:isAdjacent(a, b)
    local r1, c1 = self:cellRC(a)
    local r2, c2 = self:cellRC(b)
    return math.abs(r1 - r2) + math.abs(c1 - c2) == 1
end

-- Edge between two adjacent cells, independent of order.
local function edgeKey(a, b)
    if a > b then a, b = b, a end
    return a * 1000 + b
end
DominosaBoard.edgeKey = edgeKey

function DominosaBoard:pairOf(a, b)
    return Solver.pairIndex(self:digitAt(a), self:digitAt(b), self.m)
end

-- ---------------------------------------------------------------------------
-- Generation
-- ---------------------------------------------------------------------------

-- Hill-climbs a numbering until the graded solver (solver.lua) cracks it at
-- the difficulty's level, then keeps it only if the next level down cannot:
-- a random numbering of a tiling is almost never unique (measured: ~1-3% at
-- max digit 3-6), so uniqueness has to be built in, not hoped for. The solver
-- finishing *is* the uniqueness proof -- every step it takes is forced.
function DominosaBoard:_attempt(level, max_iter)
    local rows, cols, m = self.rows, self.cols, self.m
    local part = randomTiling(rows, cols)
    local doms = {}
    for a = 1, rows * cols do
        if a < part[a] then doms[#doms + 1] = { a, part[a] } end
    end
    local pairs_list = {}
    for x = 0, m do
        for y = x, m do pairs_list[#pairs_list + 1] = { x, y } end
    end
    for i = #pairs_list, 2, -1 do
        local j = math.random(i)
        pairs_list[i], pairs_list[j] = pairs_list[j], pairs_list[i]
    end
    local digits = {}
    for r = 1, rows do digits[r] = {} end
    local function write(i)
        local d, p = doms[i], pairs_list[i]
        local r1, c1 = self:cellRC(d[1])
        local r2, c2 = self:cellRC(d[2])
        digits[r1][c1], digits[r2][c2] = p[1], p[2]
    end
    for i = 1, #doms do write(i) end

    local cur = remaining(digits, rows, cols, m, level)
    local iter = 0
    while cur > 0 and iter < max_iter do
        iter = iter + 1
        -- Swap the numbers of two dominoes, maybe turning one round.
        local i, j = math.random(#doms), math.random(#doms)
        local flip = math.random(2) == 1
        pairs_list[i], pairs_list[j] = pairs_list[j], pairs_list[i]
        if flip then pairs_list[i] = { pairs_list[i][2], pairs_list[i][1] } end
        write(i); write(j)
        local s = remaining(digits, rows, cols, m, level)
        if s <= cur then
            cur = s
        else
            if flip then pairs_list[i] = { pairs_list[i][2], pairs_list[i][1] } end
            pairs_list[i], pairs_list[j] = pairs_list[j], pairs_list[i]
            write(i); write(j)
        end
    end
    if cur > 0 then return nil end
    return digits, part
end

function DominosaBoard:generate(difficulty)
    self.difficulty = difficulty or self.difficulty
    local target = DIFFICULTY_LEVEL[self.difficulty] or 2
    local fallback_digits, fallback_part, fallback_gap
    for _ = 1, 60 do
        local digits, part = self:_attempt(target, 400)
        if digits then
            local level = Solver.rate(Solver.buildModel(digits, self.rows, self.cols, self.m))
            if level == target then
                fallback_digits, fallback_part = digits, part
                break
            end
            -- Solved at a lower level than asked: keep the closest as a
            -- fallback (still unique, just gentler than requested).
            local gap = target - (level or 0)
            if level and (not fallback_gap or gap < fallback_gap) then
                fallback_digits, fallback_part, fallback_gap = digits, part, gap
            end
        end
    end
    -- An easy (level 1) climb has never been seen to fail; this is the
    -- belt-and-braces path in case every attempt above did.
    while not fallback_digits do
        fallback_digits, fallback_part = self:_attempt(1, 2000)
    end
    self.digits   = fallback_digits
    self.solution = fallback_part
    self:_resetPlay()
end

function DominosaBoard:_resetPlay()
    self.partner    = {}
    self.barriers   = {}
    self.selected   = nil
    self.hints_used = 0
    self.undo:clear()
    self.timer:reset()
    self.timer:start()
end

-- ---------------------------------------------------------------------------
-- Moves. Every change goes through _apply, which records the inverse.
-- ---------------------------------------------------------------------------

-- ops: list of { kind = "dom"|"bar", a, b, on }. Applied in order.
function DominosaBoard:_applyOps(ops)
    for _, op in ipairs(ops) do
        if op.kind == "dom" then
            if op.on then
                self.partner[op.a], self.partner[op.b] = op.b, op.a
            else
                self.partner[op.a], self.partner[op.b] = nil, nil
            end
        else
            self.barriers[edgeKey(op.a, op.b)] = op.on or nil
        end
    end
end

function DominosaBoard:_commit(ops)
    if #ops == 0 then return false end
    self:_applyOps(ops)
    self.undo:push{ ops = ops }
    if self:checkWin() then self.timer:stop() end
    return true
end

-- Ops that remove whatever domino covers a.
function DominosaBoard:_removeOps(a, ops)
    local p = self.partner[a]
    if p then ops[#ops + 1] = { kind = "dom", a = a, b = p, on = false } end
end

-- Places a domino on a,b (replacing anything covering either cell), or
-- removes it if that exact domino is already there.
function DominosaBoard:toggleDomino(a, b)
    if not self:isAdjacent(a, b) then return false, "not_adjacent" end
    local ops = {}
    if self.partner[a] == b then
        ops[1] = { kind = "dom", a = a, b = b, on = false }
    else
        self:_removeOps(a, ops)
        if self.partner[b] ~= a then self:_removeOps(b, ops) end
        -- A barrier on this edge says "no domino here"; placing one overrides it.
        if self.barriers[edgeKey(a, b)] then
            ops[#ops + 1] = { kind = "bar", a = a, b = b, on = false }
        end
        ops[#ops + 1] = { kind = "dom", a = a, b = b, on = true }
    end
    self.selected = nil
    return self:_commit(ops)
end

-- Toggles the player's "no domino across this edge" mark.
function DominosaBoard:toggleBarrier(a, b)
    if not self:isAdjacent(a, b) then return false, "not_adjacent" end
    local ops = {}
    if self.barriers[edgeKey(a, b)] then
        ops[1] = { kind = "bar", a = a, b = b, on = false }
    else
        if self.partner[a] == b then ops[1] = { kind = "dom", a = a, b = b, on = false } end
        ops[#ops + 1] = { kind = "bar", a = a, b = b, on = true }
    end
    return self:_commit(ops)
end

-- Two-tap placement: a tap on a covered cell lifts its domino; a tap on a
-- free cell selects it, and a tap on a free neighbour then joins the two.
-- Returns "removed", "selected", "deselected", "placed".
function DominosaBoard:tapCell(r, c)
    local a = self:cellId(r, c)
    local s = self.selected
    if s == a then
        self.selected = nil
        return "deselected"
    end
    -- A selected cell's neighbour joins it even if covered: the new domino
    -- replaces whatever was there.
    if s and self:isAdjacent(s, a) then
        self:toggleDomino(s, a)
        return "placed"
    end
    if self.partner[a] then
        self.selected = nil
        self:_commit({ { kind = "dom", a = a, b = self.partner[a], on = false } })
        return "removed"
    end
    self.selected = a
    return "selected"
end

function DominosaBoard:clearAll()
    local ops = {}
    for a, b in pairs(self.partner) do
        if a < b then ops[#ops + 1] = { kind = "dom", a = a, b = b, on = false } end
    end
    for key in pairs(self.barriers) do
        ops[#ops + 1] = { kind = "bar", a = floor(key / 1000), b = key % 1000, on = false }
    end
    self.selected = nil
    return self:_commit(ops)
end

function DominosaBoard:canUndo() return self.undo:canUndo() end

-- Called as DominosaBoard.undo(board): the `undo` field (the stack) shadows
-- this method on instances.
function DominosaBoard:undo()
    local entry = self.undo:pop()
    if not entry then return false, UndoStack.NOTHING_TO_UNDO end
    local inv = {}
    for i = #entry.ops, 1, -1 do
        local op = entry.ops[i]
        inv[#inv + 1] = { kind = op.kind, a = op.a, b = op.b, on = not op.on }
    end
    self:_applyOps(inv)
    self.selected = nil
    if not self:checkWin() then self.timer:start() end
    return true
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- usage[p] = how many of the player's dominoes show pair p.
function DominosaBoard:pairUsage()
    local usage = {}
    for a, b in pairs(self.partner) do
        if a < b then
            local p = self:pairOf(a, b)
            usage[p] = (usage[p] or 0) + 1
        end
    end
    return usage
end

function DominosaBoard:getPlacedCount()
    local n = 0
    for a, b in pairs(self.partner) do
        if a < b then n = n + 1 end
    end
    return n
end

function DominosaBoard:getTotalDominoes()
    return Solver.pairCount(self.m)
end

-- Solved = every cell covered and every pair used once. That is the rule,
-- not "matches the stored solution" -- though the generator guarantees the
-- two coincide.
function DominosaBoard:checkWin()
    if self:getPlacedCount() ~= self:getTotalDominoes() then return false end
    for _, n in pairs(self:pairUsage()) do
        if n ~= 1 then return false end
    end
    return true
end

-- Player dominoes that are not in the solution.
function DominosaBoard:countMistakes()
    local n = 0
    for a, b in pairs(self.partner) do
        if a < b and self.solution[a] ~= b then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Hints. The unit is a domino. A wrong domino is reported first; otherwise
-- the solver is run from the player's correct dominoes and the first domino
-- its logic forces is offered -- a real deduction, not a random reveal.
-- ---------------------------------------------------------------------------

Hint.install(DominosaBoard, {
    -- Only getHintsUsed/noteHintUsed are used from the generic module;
    -- findHint/applyHint are replaced below, since the unit is not a cell.
    getUser     = function() return nil end,
    getSolution = function() return nil end,
    setCell     = function() return false end,
})

local function step(self, kind, a, b)
    local r, c = self:cellRC(math.min(a, b))
    local r2, c2 = self:cellRC(math.max(a, b))
    return { kind = kind, r = r, c = c, r2 = r2, c2 = c2, tag = r2 * 1000 + c2,
             a = a, b = b }
end

function DominosaBoard:findHint()
    -- Lowest cell id first, so the same board always yields the same hint.
    local ncells = self.rows * self.cols
    for a = 1, ncells do
        local b = self.partner[a]
        if b and a < b and self.solution[a] ~= b then
            return step(self, "mistake", a, b)
        end
    end
    local model = Solver.buildModel(self.digits, self.rows, self.cols, self.m)
    local st = Solver.newState(model)
    local placed = {}
    for a = 1, ncells do
        local b = self.partner[a]
        if b and a < b then
            local k = Solver.placementOf(model, a, b)
            if k and Solver.choose(model, st, k) then placed[k] = true end
        end
    end
    local first_done = st.nchosen
    if Solver.propagate(model, st, 3) then
        for i = first_done + 1, st.nchosen do
            local k = st.chosen[i]
            if not placed[k] then return step(self, "fill", model.pa[k], model.pb[k]) end
        end
    end
    -- Logic found nothing new (cannot happen for a generated puzzle, whose
    -- solve is fully logical): reveal the first missing domino instead.
    for a = 1, ncells do
        local b = self.solution[a]
        if a < b and self.partner[a] ~= b then return step(self, "fill", a, b) end
    end
    return nil, "complete"
end

function DominosaBoard:applyHint(s)
    if not s then return false end
    if s.kind == "mistake" then
        if self.partner[s.a] ~= s.b then return false end
        return self:toggleDomino(s.a, s.b)
    end
    if self.partner[s.a] == s.b then return false end
    return self:toggleDomino(s.a, s.b)
end

-- ScreenBase:onHint highlights the cell it talks about.
function DominosaBoard:setSelection(r, c)
    self.selected = self:cellId(r, c)
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function DominosaBoard:serialize()
    local rows, digits = self.rows, {}
    for r = 1, rows do
        digits[r] = {}
        for c = 1, self.cols do digits[r][c] = self.digits[r][c] end
    end
    local sol, dom, bars = {}, {}, {}
    for a = 1, rows * self.cols do
        sol[a] = self.solution[a]
        local b = self.partner[a]
        if b and a < b then dom[#dom + 1] = { a, b } end
    end
    for key in pairs(self.barriers) do bars[#bars + 1] = key end
    table.sort(bars)
    -- Timer:serialize() stops the clock; a save in mid-game must not.
    local running = self.timer:isRunning()
    local timer = self.timer:serialize()
    if running then self.timer:start() end
    return {
        version    = 1,
        m          = self.m,
        difficulty = self.difficulty,
        digits     = digits,
        solution   = sol,
        dominoes   = dom,
        barriers   = bars,
        hints_used = self.hints_used,
        undo       = self.undo:serialize(),
        timer      = timer,
    }
end

function DominosaBoard:load(data)
    if type(data) ~= "table" or type(data.digits) ~= "table"
       or type(data.solution) ~= "table" or not data.m then
        return false
    end
    local m = data.m
    self.m, self.rows, self.cols = m, m + 1, m + 2
    if #data.digits ~= self.rows or #data.solution ~= self.rows * self.cols then
        return false
    end
    self.difficulty = data.difficulty or DEFAULT_DIFFICULTY
    self.digits = {}
    for r = 1, self.rows do
        self.digits[r] = {}
        for c = 1, self.cols do self.digits[r][c] = data.digits[r][c] end
    end
    self.solution = {}
    for a, b in ipairs(data.solution) do self.solution[a] = b end
    self.partner, self.barriers = {}, {}
    for _, d in ipairs(data.dominoes or {}) do
        self.partner[d[1]], self.partner[d[2]] = d[2], d[1]
    end
    for _, key in ipairs(data.barriers or {}) do self.barriers[key] = true end
    self.selected   = nil
    self.hints_used = data.hints_used or 0
    self.undo = UndoStack:new{ max_size = 300 }
    if data.undo then self.undo:load(data.undo) end
    self.timer = Timer:new()
    if data.timer then self.timer:load(data.timer) end
    return true
end

DominosaBoard.Solver = Solver
DominosaBoard.DIFFICULTY_LEVEL = DIFFICULTY_LEVEL

return DominosaBoard
