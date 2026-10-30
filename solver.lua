-- ---------------------------------------------------------------------------
-- solver.lua — Dominosa model, logical solver and solution counter.
--
-- A Dominosa grid with max digit m has (m+1) rows and (m+2) columns, so it
-- holds exactly one full double-m set: (m+1)(m+2)/2 dominoes. Solving it is an
-- exact cover: every cell covered once, every pair {a,b} used once. A
-- "placement" is one domino position (two adjacent cells) together with the
-- pair its two digits form; the solver works by killing placements.
--
-- The logical solver is graded, so the generator can rate a puzzle by the
-- weakest technique set that cracks it:
--   level 1  singles -- a cell with one possible partner, or a pair with one
--            possible position, is placed. Placing kills every placement
--            touching its cells and every other position of its pair.
--   level 2  + shared cell -- if every remaining position of a pair covers
--            the same cell, no other pair may use that cell; and if every
--            remaining placement of a cell carries the same pair, that pair
--            may go nowhere else.
--   level 3  + one-step trial -- a placement that, once assumed, leads to a
--            contradiction under level 2 is killed.
-- Every deduction is sound, so a puzzle the solver completes has exactly one
-- solution; countSolutions() (plain backtracking) cross-checks that in tests.
-- ---------------------------------------------------------------------------

local Solver = {}

local floor = math.floor

-- 1-based index of the unordered pair {a, b}, 0 <= a, b <= m.
function Solver.pairIndex(a, b, m)
    if a > b then a, b = b, a end
    return a * (m + 1) - floor(a * (a - 1) / 2) + (b - a) + 1
end

function Solver.pairCount(m)
    return floor((m + 1) * (m + 2) / 2)
end

-- Inverse of pairIndex, for display.
function Solver.pairDigits(p, m)
    for a = 0, m do
        for b = a, m do
            if Solver.pairIndex(a, b, m) == p then return a, b end
        end
    end
end

-- digits[r][c] in 0..m. Cells are numbered (r-1)*cols + c.
function Solver.buildModel(digits, rows, cols, m)
    local model = {
        rows = rows, cols = cols, m = m,
        ncells = rows * cols, npairs = Solver.pairCount(m),
        pa = {}, pb = {}, pp = {},       -- placement k: cells pa,pb, pair pp
        cellPl = {}, pairPl = {},
    }
    for i = 1, model.ncells do model.cellPl[i] = {} end
    for p = 1, model.npairs do model.pairPl[p] = {} end
    local function add(r1, c1, r2, c2)
        local a = (r1 - 1) * cols + c1
        local b = (r2 - 1) * cols + c2
        local p = Solver.pairIndex(digits[r1][c1], digits[r2][c2], m)
        local k = #model.pa + 1
        model.pa[k], model.pb[k], model.pp[k] = a, b, p
        local ca, cb, pl = model.cellPl[a], model.cellPl[b], model.pairPl[p]
        ca[#ca + 1] = k
        cb[#cb + 1] = k
        pl[#pl + 1] = k
    end
    for r = 1, rows do
        for c = 1, cols do
            if c < cols then add(r, c, r, c + 1) end
            if r < rows then add(r, c, r + 1, c) end
        end
    end
    model.nplacements = #model.pa
    return model
end

-- Placement index joining cells a and b, or nil when they are not adjacent.
function Solver.placementOf(model, a, b)
    for _, k in ipairs(model.cellPl[a]) do
        if model.pa[k] == b or model.pb[k] == b then return k end
    end
end

function Solver.newState(model)
    local st = { alive = {}, cellDone = {}, pairDone = {}, chosen = {}, nchosen = 0 }
    for k = 1, model.nplacements do st.alive[k] = true end
    return st
end

local function copyState(st)
    local n = { alive = {}, cellDone = {}, pairDone = {}, chosen = {}, nchosen = st.nchosen }
    for k, v in pairs(st.alive) do n.alive[k] = v end
    for k, v in pairs(st.cellDone) do n.cellDone[k] = v end
    for k, v in pairs(st.pairDone) do n.pairDone[k] = v end
    for i, v in ipairs(st.chosen) do n.chosen[i] = v end
    return n
end
Solver.copyState = copyState

-- Places placement k. Returns false if it was already ruled out.
function Solver.choose(model, st, k)
    if not st.alive[k] then return false end
    local a, b, p = model.pa[k], model.pb[k], model.pp[k]
    for _, list in ipairs({ model.cellPl[a], model.cellPl[b], model.pairPl[p] }) do
        for _, j in ipairs(list) do st.alive[j] = false end
    end
    st.cellDone[a], st.cellDone[b], st.pairDone[p] = true, true, true
    st.nchosen = st.nchosen + 1
    st.chosen[st.nchosen] = k
    return true
end

-- Count alive placements in list; returns count and the last alive one.
local function aliveIn(st, list)
    local n, last = 0, nil
    for _, k in ipairs(list) do
        if st.alive[k] then n, last = n + 1, k end
    end
    return n, last
end

-- Level 1: singles. Returns changed, ok.
local function singles(model, st)
    local changed = false
    for i = 1, model.ncells do
        if not st.cellDone[i] then
            local n, k = aliveIn(st, model.cellPl[i])
            if n == 0 then return changed, false end
            if n == 1 then Solver.choose(model, st, k); changed = true end
        end
    end
    for p = 1, model.npairs do
        if not st.pairDone[p] then
            local n, k = aliveIn(st, model.pairPl[p])
            if n == 0 then return changed, false end
            if n == 1 then Solver.choose(model, st, k); changed = true end
        end
    end
    return changed, true
end

-- Level 2: shared cell, in both directions.
local function sharedCell(model, st)
    local pa, pb, pp = model.pa, model.pb, model.pp
    -- Every position of pair p covers cell x: x belongs to p.
    for p = 1, model.npairs do
        if not st.pairDone[p] then
            local x1, x2, first = nil, nil, true
            for _, k in ipairs(model.pairPl[p]) do
                if st.alive[k] then
                    if first then
                        x1, x2, first = pa[k], pb[k], false
                    else
                        if x1 and x1 ~= pa[k] and x1 ~= pb[k] then x1 = nil end
                        if x2 and x2 ~= pa[k] and x2 ~= pb[k] then x2 = nil end
                    end
                end
            end
            for _, x in ipairs({ x1 or false, x2 or false }) do
                if x then
                    local hit = false
                    for _, j in ipairs(model.cellPl[x]) do
                        if st.alive[j] and pp[j] ~= p then st.alive[j] = false; hit = true end
                    end
                    if hit then return true end
                end
            end
        end
    end
    -- Every placement of cell x carries pair p: p goes nowhere else.
    for x = 1, model.ncells do
        if not st.cellDone[x] then
            local p0, same = nil, true
            for _, k in ipairs(model.cellPl[x]) do
                if st.alive[k] then
                    if p0 == nil then p0 = pp[k] elseif pp[k] ~= p0 then same = false; break end
                end
            end
            if same and p0 then
                local hit = false
                for _, j in ipairs(model.pairPl[p0]) do
                    if st.alive[j] and pa[j] ~= x and pb[j] ~= x then
                        st.alive[j] = false; hit = true
                    end
                end
                if hit then return true end
            end
        end
    end
    return false
end

-- Runs deductions up to `level` until nothing changes. Returns false on a
-- contradiction (the state then has no solution).
function Solver.propagate(model, st, level)
    while true do
        local changed, ok = singles(model, st)
        if not ok then return false end
        if not changed and level >= 2 then changed = sharedCell(model, st) end
        if not changed and level >= 3 and st.nchosen < model.ncells / 2 then
            for k = 1, model.nplacements do
                if st.alive[k] then
                    local trial = copyState(st)
                    Solver.choose(model, trial, k)
                    if not Solver.propagate(model, trial, 2) then
                        st.alive[k] = false
                        changed = true
                        break
                    end
                end
            end
        end
        if not changed then return true end
    end
end

function Solver.isSolved(model, st)
    return st.nchosen * 2 == model.ncells
end

-- Weakest level (1..3) whose logic alone solves the puzzle, or nil.
function Solver.rate(model)
    for level = 1, 3 do
        local st = Solver.newState(model)
        if Solver.propagate(model, st, level) and Solver.isSolved(model, st) then
            return level, st
        end
    end
    return nil
end

-- Plain backtracking: number of solutions, capped at `limit`.
function Solver.countSolutions(model, limit, st)
    limit = limit or 2
    st = st or Solver.newState(model)
    local count = 0
    local function search(s)
        if not Solver.propagate(model, s, 1) then return end
        if Solver.isSolved(model, s) then count = count + 1; return end
        -- Branch on the most constrained cell.
        local best, best_n = nil, math.huge
        for i = 1, model.ncells do
            if not s.cellDone[i] then
                local n = aliveIn(s, model.cellPl[i])
                if n < best_n then best, best_n = i, n end
            end
        end
        for _, k in ipairs(model.cellPl[best]) do
            if s.alive[k] then
                local t = copyState(s)
                Solver.choose(model, t, k)
                search(t)
                if count >= limit then return end
            end
        end
    end
    search(copyState(st))
    return count
end

return Solver
