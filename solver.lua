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
-- There is no trial level ("assume this domino, find a contradiction"):
-- that is guessing, and no puzzle may need it. Easy needs level 1 alone;
-- medium a few level-2 deductions, hard several times more (see board.lua).
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

-- The placements' cells depend on the grid's shape only: built once per
-- shape and shared (read-only) by every model of that shape. The generator
-- builds a model for every numbering it tries, so only the pairs are redone.
local topo_cache = {}

local function topology(rows, cols)
    local key = rows * 1000 + cols
    local t = topo_cache[key]
    if t then return t end
    local pa, pb, cellPl = {}, {}, {}
    for i = 1, rows * cols do cellPl[i] = {} end
    for r = 1, rows do
        for c = 1, cols do
            local a = (r - 1) * cols + c
            if c < cols then
                local k = #pa + 1
                pa[k], pb[k] = a, a + 1
                cellPl[a][#cellPl[a] + 1] = k
                cellPl[a + 1][#cellPl[a + 1] + 1] = k
            end
            if r < rows then
                local k = #pa + 1
                pa[k], pb[k] = a, a + cols
                cellPl[a][#cellPl[a] + 1] = k
                cellPl[a + cols][#cellPl[a + cols] + 1] = k
            end
        end
    end
    t = { pa = pa, pb = pb, cellPl = cellPl }
    topo_cache[key] = t
    return t
end

-- digits[r][c] in 0..m. Cells are numbered (r-1)*cols + c. The model is
-- read-only once built (pa, pb and cellPl are shared between models).
-- `into` (optional): a model of the same shape and m to rebuild in place --
-- the generator's climb builds one per numbering it tries.
function Solver.buildModel(digits, rows, cols, m, into)
    local t = topology(rows, cols)
    local pa, pb = t.pa, t.pb
    local np, npairs = #pa, Solver.pairCount(m)
    local model = into
    if not model then
        model = {
            rows = rows, cols = cols, m = m,
            ncells = rows * cols, npairs = npairs,
            pa = pa, pb = pb, pp = {},       -- placement k: cells pa,pb, pair pp
            cellPl = t.cellPl, pairPl = {},
            nplacements = np,
        }
        for p = 1, npairs do model.pairPl[p] = {} end
    else
        local pairPl = model.pairPl
        for p = 1, npairs do
            local pl = pairPl[p]
            for q = #pl, 1, -1 do pl[q] = nil end
        end
    end
    local pp, pairPl = model.pp, model.pairPl
    for k = 1, np do
        local ra, ca = floor((pa[k] - 1) / cols) + 1, (pa[k] - 1) % cols + 1
        local rb, cb = floor((pb[k] - 1) / cols) + 1, (pb[k] - 1) % cols + 1
        local x, y = digits[ra][ca], digits[rb][cb]
        if x > y then x, y = y, x end
        local p = x * (m + 1) - floor(x * (x - 1) / 2) + (y - x) + 1
        pp[k] = p
        local pl = pairPl[p]
        pl[#pl + 1] = k
    end
    return model
end

-- Placement index joining cells a and b, or nil when they are not adjacent.
function Solver.placementOf(model, a, b)
    for _, k in ipairs(model.cellPl[a]) do
        if model.pa[k] == b or model.pb[k] == b then return k end
    end
end

-- alive/cellDone/pairDone are plain arrays (false = not done), so copies
-- and scans run as numeric loops: the solution counter copies the state at
-- every branch.
-- `into` (optional): a state of the same model to reset in place.
function Solver.newState(model, into)
    local st = into
    if st then
        st.nchosen, st.nalive = 0, model.nplacements
    else
        st = { alive = {}, cellDone = {}, pairDone = {}, chosen = {}, nchosen = 0,
               nalive = model.nplacements, ncells = model.ncells, npairs = model.npairs }
    end
    local alive, cellDone, pairDone = st.alive, st.cellDone, st.pairDone
    for k = 1, model.nplacements do alive[k] = true end
    for i = 1, model.ncells do cellDone[i] = false end
    for p = 1, model.npairs do pairDone[p] = false end
    return st
end

local function copyState(st)
    local alive, cellDone, pairDone, chosen = {}, {}, {}, {}
    local sa, sc, sp, sch = st.alive, st.cellDone, st.pairDone, st.chosen
    for k = 1, st.nalive do alive[k] = sa[k] end
    for i = 1, st.ncells do cellDone[i] = sc[i] end
    for p = 1, st.npairs do pairDone[p] = sp[p] end
    for i = 1, st.nchosen do chosen[i] = sch[i] end
    return { alive = alive, cellDone = cellDone, pairDone = pairDone, chosen = chosen,
             nchosen = st.nchosen, nalive = st.nalive, ncells = st.ncells, npairs = st.npairs }
end
Solver.copyState = copyState

-- Places placement k. Returns false if it was already ruled out.
local function choose(model, st, k)
    local alive = st.alive
    if not alive[k] then return false end
    local a, b, p = model.pa[k], model.pb[k], model.pp[k]
    local list = model.cellPl[a]
    for i = 1, #list do alive[list[i]] = false end
    list = model.cellPl[b]
    for i = 1, #list do alive[list[i]] = false end
    list = model.pairPl[p]
    for i = 1, #list do alive[list[i]] = false end
    st.cellDone[a], st.cellDone[b], st.pairDone[p] = true, true, true
    local nc = st.nchosen + 1
    st.nchosen = nc
    st.chosen[nc] = k
    return true
end
Solver.choose = choose

-- Count alive placements in list; returns count and the last alive one.
local function aliveIn(st, list)
    local n, last = 0, nil
    local alive = st.alive
    for i = 1, #list do
        local k = list[i]
        if alive[k] then n, last = n + 1, k end
    end
    return n, last
end

-- Level 1: singles. Returns changed, ok. (Counting inlined: with
-- sharedCell, the generator's hot loop.)
local function singles(model, st)
    local changed = false
    local alive, cellDone, pairDone = st.alive, st.cellDone, st.pairDone
    local cellPl, pairPl = model.cellPl, model.pairPl
    for i = 1, model.ncells do
        if not cellDone[i] then
            local list = cellPl[i]
            local n, last = 0, 0
            for q = 1, #list do
                local k = list[q]
                if alive[k] then n = n + 1; last = k end
            end
            if n == 0 then return changed, false end
            if n == 1 then choose(model, st, last); changed = true end
        end
    end
    for p = 1, model.npairs do
        if not pairDone[p] then
            local list = pairPl[p]
            local n, last = 0, 0
            for q = 1, #list do
                local k = list[q]
                if alive[k] then n = n + 1; last = k end
            end
            if n == 0 then return changed, false end
            if n == 1 then choose(model, st, last); changed = true end
        end
    end
    return changed, true
end

-- Level 2: shared cell, in both directions. (0 stands for "no cell" and
-- the loops are numeric so LuaJIT keeps one trace per loop: this is the
-- generator's hottest function.)
local function sharedCell(model, st)
    local pa, pb, pp = model.pa, model.pb, model.pp
    local alive, pairPl, cellPl = st.alive, model.pairPl, model.cellPl
    local pairDone, cellDone = st.pairDone, st.cellDone
    -- Every position of pair p covers cell x: x belongs to p.
    for p = 1, model.npairs do
        if not pairDone[p] then
            local x1, x2, first = 0, 0, true
            local list = pairPl[p]
            for i = 1, #list do
                local k = list[i]
                if alive[k] then
                    local a, b = pa[k], pb[k]
                    if first then
                        x1, x2, first = a, b, false
                    else
                        if x1 ~= a and x1 ~= b then x1 = 0 end
                        if x2 ~= a and x2 ~= b then x2 = 0 end
                    end
                end
            end
            for w = 1, 2 do
                local x = w == 1 and x1 or x2
                if x ~= 0 then
                    local hit = false
                    local cl = cellPl[x]
                    for i = 1, #cl do
                        local j = cl[i]
                        if alive[j] and pp[j] ~= p then alive[j] = false; hit = true end
                    end
                    if hit then return true end
                end
            end
        end
    end
    -- Every placement of cell x carries pair p: p goes nowhere else.
    for x = 1, model.ncells do
        if not cellDone[x] then
            local p0, same = 0, true
            local cl = cellPl[x]
            for i = 1, #cl do
                local k = cl[i]
                if alive[k] then
                    if p0 == 0 then p0 = pp[k] elseif pp[k] ~= p0 then same = false; break end
                end
            end
            if same and p0 ~= 0 then
                local hit = false
                local list = pairPl[p0]
                for i = 1, #list do
                    local j = list[i]
                    if alive[j] and pa[j] ~= x and pb[j] ~= x then
                        alive[j] = false; hit = true
                    end
                end
                if hit then return true end
            end
        end
    end
    return false
end

-- Runs deductions up to `level` (1 or 2; anything higher is 2) until
-- nothing changes. Returns false on a contradiction (the state then has no
-- solution). `stats` (optional): stats.t2 is incremented for every level-2
-- deduction made, the measure of how much work a puzzle takes beyond singles.
function Solver.propagate(model, st, level, stats)
    while true do
        local changed, ok = singles(model, st)
        if not ok then return false end
        if not changed and level >= 2 then
            changed = sharedCell(model, st)
            if changed and stats then stats.t2 = stats.t2 + 1 end
        end
        if not changed then return true end
    end
end

-- The same deductions as propagate(), with a work list instead of rescans:
-- each cell and pair keeps a count of its live placements, and only those
-- whose count drops to 1 (a single) or 0 (a contradiction) are looked at
-- again. Singles all follow from one another whatever the order they are
-- made in, so every shared-cell step sees the very same state as in
-- propagate() and the result is the same: same verdict, same live
-- placements, same choices (st.chosen may list them in another order) and
-- the same stats.t2. propagate() keeps its order for the hint, whose
-- message follows it; the generator and the grading use this one (the
-- generator's climb runs it on every numbering it tries).
function Solver.propagateFast(model, st, level, stats)
    local pa, pb, pp = model.pa, model.pb, model.pp
    local cellPl, pairPl = model.cellPl, model.pairPl
    local ncells, npairs = model.ncells, model.npairs
    local alive, cellDone, pairDone, chosen = st.alive, st.cellDone, st.pairDone, st.chosen
    -- cnt[i] for cell i, cnt[ncells + p] for pair p; queue holds the same ids.
    local cnt, queue = st.cnt, st.queue
    if not cnt then cnt, queue = {}, {}; st.cnt, st.queue = cnt, queue end
    local qn = 0
    for i = 1, ncells do
        local list, n = cellPl[i], 0
        for q = 1, #list do if alive[list[q]] then n = n + 1 end end
        cnt[i] = n
        if not cellDone[i] and n <= 1 then qn = qn + 1; queue[qn] = i end
    end
    for p = 1, npairs do
        local list, n = pairPl[p], 0
        for q = 1, #list do if alive[list[q]] then n = n + 1 end end
        cnt[ncells + p] = n
        if not pairDone[p] and n <= 1 then qn = qn + 1; queue[qn] = ncells + p end
    end
    local function kill(k)
        alive[k] = false
        local a, b, p = pa[k], pb[k], ncells + pp[k]
        local n = cnt[a] - 1
        cnt[a] = n
        if n <= 1 then qn = qn + 1; queue[qn] = a end
        n = cnt[b] - 1
        cnt[b] = n
        if n <= 1 then qn = qn + 1; queue[qn] = b end
        n = cnt[p] - 1
        cnt[p] = n
        if n <= 1 then qn = qn + 1; queue[qn] = p end
    end
    while true do
        -- Singles to a fixpoint.
        while qn > 0 do
            local id = queue[qn]
            qn = qn - 1
            local list
            if id <= ncells then
                if not cellDone[id] then list = cellPl[id] end
            elseif not pairDone[id - ncells] then
                list = pairPl[id - ncells]
            end
            if list then
                local n = cnt[id]
                if n == 0 then return false end
                if n == 1 then
                    local k
                    for q = 1, #list do
                        if alive[list[q]] then k = list[q]; break end
                    end
                    local a, b, p = pa[k], pb[k], pp[k]
                    local l2 = cellPl[a]
                    for q = 1, #l2 do if alive[l2[q]] then kill(l2[q]) end end
                    l2 = cellPl[b]
                    for q = 1, #l2 do if alive[l2[q]] then kill(l2[q]) end end
                    l2 = pairPl[p]
                    for q = 1, #l2 do if alive[l2[q]] then kill(l2[q]) end end
                    cellDone[a], cellDone[b], pairDone[p] = true, true, true
                    local nc = st.nchosen + 1
                    st.nchosen = nc
                    chosen[nc] = k
                end
            end
        end
        if level < 2 then return true end
        -- One shared-cell step (as sharedCell), then singles again.
        local hit = false
        for p = 1, npairs do
            if not pairDone[p] then
                local x1, x2, first = 0, 0, true
                local list = pairPl[p]
                for q = 1, #list do
                    local k = list[q]
                    if alive[k] then
                        local a, b = pa[k], pb[k]
                        if first then
                            x1, x2, first = a, b, false
                        else
                            if x1 ~= a and x1 ~= b then x1 = 0 end
                            if x2 ~= a and x2 ~= b then x2 = 0 end
                        end
                    end
                end
                for w = 1, 2 do
                    local x = w == 1 and x1 or x2
                    if x ~= 0 then
                        local cl = cellPl[x]
                        for q = 1, #cl do
                            local j = cl[q]
                            if alive[j] and pp[j] ~= p then kill(j); hit = true end
                        end
                        if hit then break end
                    end
                end
                if hit then break end
            end
        end
        if not hit then
            for x = 1, ncells do
                if not cellDone[x] then
                    local p0, same = 0, true
                    local cl = cellPl[x]
                    for q = 1, #cl do
                        local k = cl[q]
                        if alive[k] then
                            if p0 == 0 then p0 = pp[k] elseif pp[k] ~= p0 then same = false; break end
                        end
                    end
                    if same and p0 ~= 0 then
                        local list = pairPl[p0]
                        for q = 1, #list do
                            local j = list[q]
                            if alive[j] and pa[j] ~= x and pb[j] ~= x then kill(j); hit = true end
                        end
                        if hit then break end
                    end
                end
            end
        end
        if not hit then return true end
        if stats then stats.t2 = stats.t2 + 1 end
    end
end

function Solver.isSolved(model, st)
    return st.nchosen * 2 == model.ncells
end

-- Weakest level (1 or 2) whose logic alone solves the puzzle, or nil, then
-- the solved state and the number of level-2 deductions it took.
function Solver.rate(model)
    for level = 1, 2 do
        local st, stats = Solver.newState(model), { t2 = 0 }
        if Solver.propagateFast(model, st, level, stats) and Solver.isSolved(model, st) then
            return level, st, stats.t2
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
