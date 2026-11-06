local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("DominosaBoard", function()
    local Board, Solver

    setup(function()
        Board  = dofile(DIR .. "board.lua")
        Solver = Board.Solver
    end)

    local function newBoard(m, diff, seed)
        math.randomseed(seed or 42)
        local b = Board:new{ max_digit = m or 4 }
        b:generate(diff or "medium")
        return b
    end

    -- Places every domino of the stored solution.
    local function solve(b)
        for a = 1, b.rows * b.cols do
            local p = b.solution[a]
            if a < p and b.partner[a] ~= p then b:toggleDomino(a, p) end
        end
    end

    describe("solver basics", function()
        it("pairIndex covers 1..npairs exactly once and is symmetric", function()
            for m = 3, 6 do
                local seen = {}
                for a = 0, m do
                    for b = a, m do
                        local p = Solver.pairIndex(a, b, m)
                        assert.are.equal(p, Solver.pairIndex(b, a, m))
                        assert.is_nil(seen[p])
                        seen[p] = true
                        local x, y = Solver.pairDigits(p, m)
                        assert.are.same({ a, b }, { x, y })
                    end
                end
                for p = 1, Solver.pairCount(m) do assert.is_true(seen[p]) end
            end
        end)

        it("the logic never completes a puzzle with several solutions", function()
            -- Random numberings of a tiling are rarely unique: collect some
            -- that are not, and check no level of logic claims to solve them.
            math.randomseed(5)
            local found = 0
            for _ = 1, 200 do
                local b = Board:new{ max_digit = 4 }
                local digits = {}
                for r = 1, b.rows do digits[r] = {} end
                local cells = {}
                for a = 1, b.rows * b.cols do cells[a] = a end
                -- Any full set laid on straight horizontal dominoes (cols even).
                local list = {}
                for x = 0, 4 do for y = x, 4 do list[#list + 1] = { x, y } end end
                for i = #list, 2, -1 do
                    local j = math.random(i)
                    list[i], list[j] = list[j], list[i]
                end
                local k = 0
                for r = 1, b.rows do
                    for c = 1, b.cols, 2 do
                        k = k + 1
                        digits[r][c], digits[r][c + 1] = list[k][1], list[k][2]
                    end
                end
                local model = Solver.buildModel(digits, b.rows, b.cols, 4)
                if Solver.countSolutions(model, 2) >= 2 then
                    found = found + 1
                    assert.is_nil(Solver.rate(model))
                end
            end
            assert.is_true(found > 50)
        end)
    end)

    describe("generate", function()
        it("has an (m+1) x (m+2) grid of digits 0..m", function()
            for m = 3, 6 do
                local b = newBoard(m, "easy")
                assert.are.equal(m + 1, b.rows)
                assert.are.equal(m + 2, b.cols)
                for r = 1, b.rows do
                    for c = 1, b.cols do
                        local d = b.digits[r][c]
                        assert.is_true(d >= 0 and d <= m)
                    end
                end
            end
        end)

        it("stores a solution that is a full set, each pair once", function()
            local b = newBoard(5, "hard")
            local seen, n = {}, 0
            for a = 1, b.rows * b.cols do
                local p = b.solution[a]
                assert.are.equal(a, b.solution[p])
                assert.is_true(b:isAdjacent(a, p))
                if a < p then
                    local pi = b:pairOf(a, p)
                    assert.is_nil(seen[pi])
                    seen[pi], n = true, n + 1
                end
            end
            assert.are.equal(b:getTotalDominoes(), n)
        end)

        -- No level ever needs a trial: every grid falls to levels 1-2, with
        -- its level-2 deduction count inside the difficulty's window.
        it("is unique, guess-free and in its difficulty's window, over many seeds", function()
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                for m = 3, 6 do
                    for seed = 1, 10 do
                        local b = newBoard(m, diff, seed * 31 + m)
                        local model = Solver.buildModel(b.digits, b.rows, b.cols, b.m)
                        assert.are.equal(1, Solver.countSolutions(model, 2),
                            ("not unique: m=%d %s seed %d"):format(m, diff, seed))
                        local level, _, t2 = Solver.rate(model)
                        assert.are.equal(Board.DIFFICULTY_LEVEL[diff], level,
                            ("wrong level: m=%d %s seed %d"):format(m, diff, seed))
                        local w = Board.t2Window(diff, m)
                        assert.is_true(t2 >= w[1] and t2 <= w[2],
                            ("t2=%d outside window: m=%d %s seed %d"):format(t2, m, diff, seed))
                    end
                end
            end
        end)

        it("keeps the levels apart: hard needs more shared-cell work than medium", function()
            for m = 3, 6 do
                assert.is_true(Board.t2Window("hard", m)[1] > Board.t2Window("medium", m)[2])
                assert.is_true(Board.t2Window("medium", m)[1] > Board.t2Window("easy", m)[2])
            end
        end)

        -- The Daily Challenge builds the same grid from the same seed on
        -- every device: no clock, progress reporting changes nothing.
        it("builds the same grid from the same seed, progress reported or not", function()
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                local a = newBoard(5, diff, 99)
                math.randomseed(99)
                local b = Board:new{ max_digit = 5 }
                local last = -1
                b:generate(diff, function(f) assert.is_true(f >= last); last = f end)
                assert.are.same(a.digits, b.digits)
                assert.are.same(a.solution, b.solution)
            end
        end)

        it("generates Hard grids quickly", function()
            for m = 3, 6 do
                local worst = 0
                for seed = 1, 6 do
                    local t0 = os.clock()
                    newBoard(m, "hard", seed * 77 + m)
                    worst = math.max(worst, os.clock() - t0)
                end
                -- generous: ~0.1 s at most on a desktop under LuaJIT
                assert.is_true(worst < 3.0, ("m=%d took %.2f s"):format(m, worst))
            end
        end)

        it("the logical solve agrees with the stored solution", function()
            local b = newBoard(6, "hard", 7)
            local model = Solver.buildModel(b.digits, b.rows, b.cols, b.m)
            local _, st = Solver.rate(model)
            for _, k in ipairs(st.chosen) do
                assert.are.equal(model.pb[k], b.solution[model.pa[k]])
            end
        end)
    end)

    describe("moves", function()
        it("toggleDomino places and removes", function()
            local b = newBoard(3, "easy")
            assert.is_true(b:toggleDomino(1, 2))
            assert.are.equal(2, b.partner[1])
            assert.is_true(b:toggleDomino(2, 1))
            assert.is_nil(b.partner[1])
            assert.is_nil(b.partner[2])
        end)

        it("refuses non-adjacent cells", function()
            local b = newBoard(3, "easy")
            local ok, err = b:toggleDomino(1, 3)
            assert.is_false(ok)
            assert.are.equal("not_adjacent", err)
        end)

        it("a new domino replaces the ones it overlaps", function()
            local b = newBoard(3, "easy")
            b:toggleDomino(1, 2)
            b:toggleDomino(3, 4)
            b:toggleDomino(2, 3)
            assert.is_nil(b.partner[1])
            assert.is_nil(b.partner[4])
            assert.are.equal(3, b.partner[2])
            assert.are.equal(1, b:getPlacedCount())
        end)

        it("two taps on neighbours place a domino; a tap on it lifts it", function()
            local b = newBoard(3, "easy")
            assert.are.equal("selected", b:tapCell(1, 1))
            assert.are.equal("placed", b:tapCell(2, 1))
            assert.are.equal(b:cellId(2, 1), b.partner[1])
            assert.are.equal("removed", b:tapCell(2, 1))
            assert.is_nil(b.partner[1])
            assert.are.equal("selected", b:tapCell(1, 1))
            assert.are.equal("selected", b:tapCell(3, 3))   -- not adjacent: moves
            assert.are.equal("deselected", b:tapCell(3, 3))
        end)

        it("barriers toggle and give way to a domino", function()
            local b = newBoard(3, "easy")
            b:toggleBarrier(1, 2)
            assert.is_true(b.barriers[Board.edgeKey(1, 2)])
            b:toggleDomino(1, 2)
            assert.is_nil(b.barriers[Board.edgeKey(1, 2)])
            b:toggleBarrier(1, 2)
            assert.is_nil(b.partner[1])
            assert.is_true(b.barriers[Board.edgeKey(2, 1)])
        end)

        it("undo reverts each move, including a replacing one", function()
            local b = newBoard(3, "easy")
            b:toggleDomino(1, 2)
            b:toggleDomino(2, 3)
            assert.is_true(Board.undo(b))
            assert.are.equal(2, b.partner[1])
            assert.is_nil(b.partner[3])
            assert.is_true(Board.undo(b))
            assert.are.equal(0, b:getPlacedCount())
            assert.is_false(Board.undo(b))
        end)

        it("pairUsage counts duplicates", function()
            local b = newBoard(3, "easy")
            -- Two dominoes with the same digits somewhere: find a repeated pair.
            local first = {}
            local done = false
            for a = 1, b.rows * b.cols do
                for _, d in ipairs({ 1, b.cols }) do
                    local o = a + d
                    if not done and o <= b.rows * b.cols and b:isAdjacent(a, o) then
                        local p = b:pairOf(a, o)
                        local f = first[p]
                        if f and f[1] ~= a and f[2] ~= a and f[1] ~= o and f[2] ~= o then
                            b:toggleDomino(f[1], f[2])
                            b:toggleDomino(a, o)
                            assert.are.equal(2, b:pairUsage()[p])
                            done = true
                        elseif not f then
                            first[p] = { a, o }
                        end
                    end
                end
            end
            assert.is_true(done)
        end)
    end)

    describe("win detection", function()
        it("the full solution wins and stops the timer", function()
            local b = newBoard(4, "medium")
            assert.is_false(b:checkWin())
            solve(b)
            assert.is_true(b:checkWin())
            assert.is_false(b.timer:isRunning())
        end)

        it("a full cover with a wrong domino does not win", function()
            local b = newBoard(4, "medium")
            solve(b)
            -- Undo the last domino: one pair missing.
            Board.undo(b)
            assert.is_false(b:checkWin())
        end)

        it("clearAll empties the board and is undoable", function()
            local b = newBoard(3, "easy")
            solve(b)
            b:toggleBarrier(1, b.cols + 1)
            b:clearAll()
            assert.are.equal(0, b:getPlacedCount())
            assert.is_nil(next(b.barriers))
            Board.undo(b)
            assert.is_true(b:checkWin() or b:getPlacedCount() > 0)
        end)
    end)

    describe("hints", function()
        it("reports a wrong domino first, then removes it", function()
            local b = newBoard(4, "medium")
            -- A domino that is not in the solution.
            local a, o
            for x = 1, b.rows * b.cols do
                local y = x + 1
                if b:isAdjacent(x, y) and b.solution[x] ~= y then a, o = x, y; break end
            end
            b:toggleDomino(a, o)
            local step = b:findHint()
            assert.are.equal("mistake", step.kind)
            assert.is_true(b:applyHint(step))
            assert.is_nil(b.partner[a])
        end)

        it("fill hints are always correct and finish the puzzle", function()
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                local b = newBoard(5, diff, 3)
                local guard = 0
                while not b:checkWin() do
                    local step = b:findHint()
                    assert.are.equal("fill", step.kind)
                    assert.are.equal(step.b, b.solution[step.a])
                    assert.is_true(b:applyHint(step) and true)
                    b:noteHintUsed()
                    guard = guard + 1
                    assert.is_true(guard <= b:getTotalDominoes())
                end
                local _, reason = b:findHint()
                assert.are.equal("complete", reason)
                assert.are.equal(b:getTotalDominoes(), b:getHintsUsed())
            end
        end)

        it("the hint is a forced deduction, deterministic", function()
            local b = newBoard(6, "hard", 11)
            local s1, s2 = b:findHint(), b:findHint()
            assert.are.same(s1, s2)
        end)
    end)

    describe("persistence", function()
        it("round-trips through serialize/load", function()
            local b = newBoard(5, "hard")
            b:toggleDomino(1, 2)
            b:toggleBarrier(3, 3 + b.cols)
            b:noteHintUsed()
            local data = b:serialize()
            assert.is_true(b.timer:isRunning())   -- saving does not stop the clock
            local c = Board:new{}
            assert.is_true(c:load(data))
            assert.are.equal(5, c.m)
            assert.are.equal("hard", c.difficulty)
            assert.are.same(b.digits, c.digits)
            assert.are.same(b.solution, c.solution)
            assert.are.same(b.partner, c.partner)
            assert.are.same(b.barriers, c.barriers)
            assert.are.equal(1, c:getHintsUsed())
            assert.is_true(c:canUndo())
            assert.is_true(Board.undo(c))
            assert.is_nil(next(c.barriers))
        end)

        -- A Hard grid saved by 1.1.x could need a one-step trial, which
        -- the solver no longer does: it must still load, and the hint must
        -- still finish it (by revealing dominoes once logic is stuck).
        it("loads and finishes a Hard grid saved by 1.1.x", function()
            local c = Board:new{}
            assert.is_true(c:load({
                version = 1, m = 3, difficulty = "hard",
                digits = { { 3, 3, 0, 2, 2 }, { 2, 2, 0, 1, 0 }, { 1, 1, 0, 0, 3 }, { 2, 3, 3, 1, 1 } },
                solution = { 2, 1, 8, 9, 10, 7, 6, 3, 4, 5, 12, 11, 18, 19, 20, 17, 16, 13, 14, 15 },
                dominoes = {}, barriers = {}, hints_used = 0,
            }))
            assert.is_nil((Solver.rate(Solver.buildModel(c.digits, c.rows, c.cols, c.m))))
            local guard = 0
            while not c:checkWin() do
                local step = c:findHint()
                assert.are.equal("fill", step.kind)
                assert.are.equal(step.b, c.solution[step.a])
                assert.is_true(c:applyHint(step) and true)
                guard = guard + 1
                assert.is_true(guard <= c:getTotalDominoes())
            end
        end)

        it("rejects bad data", function()
            local c = Board:new{}
            assert.is_false(c:load(nil))
            assert.is_false(c:load({}))
            assert.is_false(c:load({ m = 3, digits = {}, solution = {} }))
        end)
    end)
end)
