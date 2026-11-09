-- Difficulty guarantees for Dominosa (see docs/dev/TESTING.md, "Difficulty
-- specs"). Grids are graded by the solver's levels (solver.lua): level 1 =
-- singles, level 2 = + shared cell, never trial. Easy: level 1 only;
-- Medium/Hard: level 2 with a window of level-2 deductions
-- (Board.t2Window), Hard's window above Medium's.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("Dominosa difficulty", function()
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

    describe("generate", function()
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
        it("level-2 work goes up from Easy to Hard on averages over seeds", function()
            local SEEDS = 6
            for _, m in ipairs({ 3, 4, 5 }) do
                local avg = {}
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local sum = 0
                    for seed = 1, SEEDS do
                        local b = newBoard(m, diff, seed * 13 + m)
                        local _, _, t2 = Solver.rate(Solver.buildModel(b.digits, b.rows, b.cols, b.m))
                        sum = sum + t2
                    end
                    avg[diff] = sum / SEEDS
                end
                assert.are.equal(0, avg.easy)
                assert.is_true(avg.easy < avg.medium and avg.medium < avg.hard,
                    ("m=%d: %.1f / %.1f / %.1f"):format(m, avg.easy, avg.medium, avg.hard))
            end
        end)

        -- Generation is bounded by attempt and climb counts, never by time:
        -- with a clock that jumps 1000 s at every read, a seed still gives
        -- the same grid.
        it("generation never reads the clock", function()
            local oc, ot = os.clock, os.time
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                local a = newBoard(4, diff, 123)
                local t = 0
                os.clock = function() t = t + 1000; return t end
                os.time = function(x) if x then return ot(x) end; t = t + 1000; return t end
                local ok, b = pcall(newBoard, 4, diff, 123)
                os.clock, os.time = oc, ot
                assert.is_true(ok, tostring(b))
                assert.are.same(a.digits, b.digits)
                assert.are.same(a.solution, b.solution)
            end
            for _, f in ipairs({ "board.lua", "solver.lua" }) do
                local src = assert(io.open(DIR .. f)):read("*a")
                assert.is_nil(src:find("os%.clock"), f)
                assert.is_nil(src:find("os%.time"), f)
            end
        end)
    end)
end)
