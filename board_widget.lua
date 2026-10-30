local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText     = require("ui/rendertext")
local UIManager      = require("ui/uimanager")
local Widget         = require("ui/widget/widget")

local gwb      = require("grid_widget_base")
local drawLine = gwb.drawLine

local floor = math.floor

-- ---------------------------------------------------------------------------
-- Colours
-- ---------------------------------------------------------------------------

local C_BG        = Blitbuffer.COLOR_WHITE
local C_GRID      = Blitbuffer.COLOR_GRAY_B
local C_LINE      = Blitbuffer.COLOR_BLACK
local C_DOMINO    = Blitbuffer.COLOR_GRAY_E   -- a placed domino
local C_DUPLICATE = Blitbuffer.COLOR_GRAY_9   -- a domino whose pair is used twice
local C_SELECTED  = Blitbuffer.COLOR_GRAY_B
local C_TEXT      = Blitbuffer.COLOR_BLACK
local C_USED      = Blitbuffer.COLOR_BLACK
local C_USED_TEXT = Blitbuffer.COLOR_WHITE

-- A tap this close to an inner edge (as a fraction of the cell) acts on the
-- edge: it places or lifts the domino across it. Further in, it acts on the
-- cell. A quarter cell each side gives a half-cell-wide band per edge.
local EDGE_BAND = 0.25

-- Largest face whose ink fits max_w x max_h. Measured unbounded: with a width
-- limit sizeUtf8Text truncates and the test could never fail.
local function fitFace(font, sample, max_w, max_h)
    local lo, hi, best = 5, math.max(5, floor(max_h * 2)), 5
    while lo <= hi do
        local mid = floor((lo + hi) / 2)
        local m   = RenderText:sizeUtf8Text(0, Device.screen:getWidth(),
            Font:getFace(font, mid), sample, true, false)
        if m.x <= max_w and (m.y_top + m.y_bottom) <= max_h then
            best, lo = mid, mid + 1
        else
            hi = mid - 1
        end
    end
    return Font:getFace(font, best)
end

local function paintCentered(bb, face, text, cx, cy, w, h, color)
    local m    = RenderText:sizeUtf8Text(0, w, face, text, true, false)
    local base = cy + floor((h + m.y_top - m.y_bottom) / 2)
    local tx   = cx + floor((w - m.x) / 2)
    RenderText:renderUtf8Text(bb, tx, base, face, text, true, false, color)
end

-- ---------------------------------------------------------------------------
-- DominosaBoardWidget -- rectangular grid, square cells
-- ---------------------------------------------------------------------------

local DominosaBoardWidget = InputContainer:extend{
    board      = nil,
    max_width  = 0,
    max_height = 0,
    onCellTap  = nil,   -- function(r, c)
    onEdgeTap  = nil,   -- function(a, b)  cell ids
    onEdgeHold = nil,   -- function(a, b)
}

function DominosaBoardWidget:init()
    local board = self.board
    local rows, cols = board.rows, board.cols
    local cell = floor(math.min(self.max_width / cols, self.max_height / rows))
    cell = math.max(cell, 12)
    self.cell = cell
    self.w, self.h = cell * cols, cell * rows
    self.dimen = Geom:new{ w = self.w, h = self.h }
    self.digit_face = fitFace("cfont", "8", cell * 0.45, cell * 0.45)
    self.paint_rect = nil
    self.ges_events = {
        BoardTap  = { GestureRange:new{ ges = "tap",          range = function() return self.paint_rect end } },
        BoardHold = { GestureRange:new{ ges = "hold_release", range = function() return self.paint_rect end } },
    }
end

-- Resolves a screen point to either a cell or an inner edge.
-- Returns "cell", r, c  |  "edge", a, b  |  nil.
-- With `nearest_edge`, always returns the closest inner edge.
function DominosaBoardWidget:hitTest(px, py, nearest_edge)
    local rect = self.paint_rect
    if not rect then return nil end
    local lx, ly = px - rect.x, py - rect.y
    if lx < 0 or ly < 0 or lx >= self.w or ly >= self.h then return nil end
    local board = self.board
    local c = floor(lx / self.cell) + 1
    local r = floor(ly / self.cell) + 1
    local fx, fy = lx / self.cell - (c - 1), ly / self.cell - (r - 1)
    local best, best_d
    local function try(d, nr, nc)
        if nr >= 1 and nr <= board.rows and nc >= 1 and nc <= board.cols
           and (not best_d or d < best_d) then
            best, best_d = { nr, nc }, d
        end
    end
    try(fx, r, c - 1)
    try(1 - fx, r, c + 1)
    try(fy, r - 1, c)
    try(1 - fy, r + 1, c)
    if best and (nearest_edge or best_d < EDGE_BAND) then
        return "edge", board:cellId(r, c), board:cellId(best[1], best[2])
    end
    return "cell", r, c
end

function DominosaBoardWidget:onBoardTap(_, ges)
    if not (ges and ges.pos) then return false end
    local kind, x, y = self:hitTest(ges.pos.x, ges.pos.y)
    if kind == "edge" and self.onEdgeTap then
        self.onEdgeTap(x, y)
    elseif kind == "cell" and self.onCellTap then
        self.onCellTap(x, y)
    end
    return kind ~= nil
end

function DominosaBoardWidget:onBoardHold(_, ges)
    if not (ges and ges.pos) then return false end
    local kind, a, b = self:hitTest(ges.pos.x, ges.pos.y, true)
    if kind == "edge" and self.onEdgeHold then self.onEdgeHold(a, b) end
    return kind ~= nil
end

function DominosaBoardWidget:refresh()
    UIManager:setDirty(self, function()
        return "ui", self.paint_rect or self.dimen
    end)
end

function DominosaBoardWidget:paintTo(bb, x, y)
    self.paint_rect = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local board = self.board
    local rows, cols, cell = board.rows, board.cols, self.cell
    local thick = math.max(2, floor(cell * 0.05))
    local inset = math.max(2, floor(cell * 0.08))
    local usage = board:pairUsage()

    bb:paintRect(x, y, self.w, self.h, C_BG)

    -- Grid lines: light, so the dominoes are what the eye picks out.
    for i = 1, cols - 1 do drawLine(bb, x + i * cell, y, 1, self.h, C_GRID) end
    for i = 1, rows - 1 do drawLine(bb, x, y + i * cell, self.w, 1, C_GRID) end

    -- Selected cell (the first tap of a two-tap placement, or a hint).
    if board.selected then
        local r, c = board:cellRC(board.selected)
        bb:paintRect(x + (c - 1) * cell, y + (r - 1) * cell, cell, cell, C_SELECTED)
    end

    -- Dominoes: an inset box with a black outline around both cells.
    for a, b in pairs(board.partner) do
        if a < b then
            local r1, c1 = board:cellRC(a)
            local r2, c2 = board:cellRC(b)
            local dx = x + (c1 - 1) * cell + inset
            local dy = y + (r1 - 1) * cell + inset
            local dw = (c2 - c1 + 1) * cell - 2 * inset
            local dh = (r2 - r1 + 1) * cell - 2 * inset
            local dup = (usage[board:pairOf(a, b)] or 0) > 1
            bb:paintRect(dx, dy, dw, dh, C_LINE)
            bb:paintRect(dx + thick, dy + thick, dw - 2 * thick, dh - 2 * thick,
                dup and C_DUPLICATE or C_DOMINO)
            -- The dividing line between the two halves.
            if r1 == r2 then
                drawLine(bb, x + c2 * cell - cell, dy + thick, 1, dh - 2 * thick, C_LINE)
            else
                drawLine(bb, dx + thick, y + r2 * cell - cell, dw - 2 * thick, 1, C_LINE)
            end
        end
    end

    -- Barriers: a thick bar along the edge, "no domino across here".
    local bar_len = floor(cell * 0.6)
    for key in pairs(board.barriers) do
        local a, b = floor(key / 1000), key % 1000
        local r1, c1 = board:cellRC(a)
        local r2, c2 = board:cellRC(b)
        local bw = math.max(3, floor(cell * 0.09))
        if r1 == r2 then
            local ex = x + c2 * cell - cell
            drawLine(bb, ex - floor(bw / 2), y + (r1 - 1) * cell + floor((cell - bar_len) / 2),
                bw, bar_len, C_LINE)
        else
            local ey = y + r2 * cell - cell
            drawLine(bb, x + (c1 - 1) * cell + floor((cell - bar_len) / 2), ey - floor(bw / 2),
                bar_len, bw, C_LINE)
        end
    end

    -- Digits.
    for r = 1, rows do
        for c = 1, cols do
            paintCentered(bb, self.digit_face, tostring(board.digits[r][c]),
                x + (c - 1) * cell, y + (r - 1) * cell, cell, cell, C_TEXT)
        end
    end

    -- Outer border.
    drawLine(bb, x, y, self.w, thick, C_LINE)
    drawLine(bb, x, y + self.h - thick, self.w, thick, C_LINE)
    drawLine(bb, x, y, thick, self.h, C_LINE)
    drawLine(bb, x + self.w - thick, y, thick, self.h, C_LINE)
end

-- ---------------------------------------------------------------------------
-- PairTable -- which of the (m+1)(m+2)/2 pairs the player has used.
-- Row a, column b (b >= a) holds the pair a-b: white while free, black once
-- used, and boxed in grey when used more than once.
-- ---------------------------------------------------------------------------

local PairTable = Widget:extend{
    board    = nil,
    cell     = 40,
}

function PairTable:init()
    local n = self.board.m + 1
    self.dimen = Geom:new{ w = n * self.cell, h = n * self.cell }
    self.face = fitFace("cfont", "8-8", self.cell * 0.66, self.cell * 0.38)
end

function PairTable:getSize()
    return self.dimen
end

function PairTable:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local board, pc = self.board, self.cell
    local m = board.m
    local usage = board:pairUsage()
    local gap = math.max(1, floor(pc * 0.06))
    local Solver = board.Solver
    for a = 0, m do
        for b = a, m do
            local cx, cy = x + b * pc + gap, y + a * pc + gap
            local w = pc - 2 * gap
            local used = usage[Solver.pairIndex(a, b, m)] or 0
            local label = a .. "-" .. b
            if used == 0 then
                bb:paintRect(cx, cy, w, w, C_LINE)
                bb:paintRect(cx + 1, cy + 1, w - 2, w - 2, C_BG)
                paintCentered(bb, self.face, label, cx, cy, w, w, C_TEXT)
            elseif used == 1 then
                bb:paintRect(cx, cy, w, w, C_USED)
                paintCentered(bb, self.face, label, cx, cy, w, w, C_USED_TEXT)
            else
                -- Used twice or more: a mistake, drawn grey with a heavy frame.
                local t = math.max(2, floor(pc * 0.1))
                bb:paintRect(cx, cy, w, w, C_LINE)
                bb:paintRect(cx + t, cy + t, w - 2 * t, w - 2 * t, C_DUPLICATE)
                paintCentered(bb, self.face, label, cx, cy, w, w, C_TEXT)
            end
        end
    end
end

function PairTable:refresh()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

DominosaBoardWidget.PairTable = PairTable

return DominosaBoardWidget
