local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase          = require("screen_base")
local MenuHelper          = require("menu_helper")
local GenProgress         = require("gen_progress")
local DominosaBoard       = lrequire("board")
local DominosaBoardWidget = lrequire("board_widget")

-- Max digit m gives an (m+1) x (m+2) grid.
local MAX_DIGITS = { 3, 4, 5, 6 }

local GAME_RULES_EN = _([[
Dominosa — Rules

The grid holds a complete set of dominoes, laid face up with their outlines removed. Find where each domino lies.

Rules:
• Every cell belongs to exactly one domino (two side-by-side cells).
• Each pair of numbers (0-0, 0-1, … up to the largest digit) appears on exactly one domino.

Controls:
• Tap the border between two cells to place a domino there; tap it again to remove it.
• Or tap a cell, then a neighbouring cell.
• Tap a domino's cell to remove it.
• Hold a border to mark it as "no domino here" (a thick bar); hold again to clear the mark.

The table under the board shows which pairs you have used: black once used, grey with a heavy frame when used twice. Dominoes that repeat a pair are shaded darker on the board.
]])

local GAME_RULES_FR = [[
Dominosa — Règles

La grille contient un jeu complet de dominos, posés face visible sans leurs contours. Retrouvez l'emplacement de chaque domino.

Règles :
• Chaque case appartient à exactement un domino (deux cases voisines).
• Chaque paire de chiffres (0-0, 0-1, … jusqu'au plus grand chiffre) figure sur exactement un domino.

Commandes :
• Touchez la bordure entre deux cases pour y poser un domino ; touchez-la à nouveau pour le retirer.
• Ou touchez une case, puis une case voisine.
• Touchez une case d'un domino pour le retirer.
• Maintenez le doigt sur une bordure pour la marquer « pas de domino ici » (un trait épais) ; recommencez pour effacer la marque.

Le tableau sous la grille indique les paires utilisées : en noir une fois utilisée, en gris avec un cadre épais si elle l'est deux fois. Les dominos qui répètent une paire sont plus foncés sur la grille.
]]

local DominosaScreen = ScreenBase:extend{}

-- The unit is a domino, so the hint names both of its cells.
function DominosaScreen:describeHintStep(step, level)
    if level == 1 then
        return step.kind == "mistake"
            and T(_("The domino R%1C%2–R%3C%4 is wrong. Tap Hint again to remove it."),
                  step.r, step.c, step.r2, step.c2)
            or  T(_("A domino must cover R%1C%2–R%3C%4. Tap Hint again to place it."),
                  step.r, step.c, step.r2, step.c2)
    end
    return step.kind == "mistake"
        and T(_("Removed the domino R%1C%2–R%3C%4."), step.r, step.c, step.r2, step.c2)
        or  T(_("Placed the domino R%1C%2–R%3C%4."), step.r, step.c, step.r2, step.c2)
end

function DominosaScreen:init()
    local state = self.plugin:loadState()
    self.board  = DominosaBoard:new{ max_digit = self.plugin:getSetting("max_digit", 4) }
    if not self.board:load(state) then
        local diff = self.plugin:getSetting("difficulty", "medium")
        GenProgress.run(function(on_progress) self.board:generate(diff, on_progress) end)
    end
    ScreenBase.init(self)
end

function DominosaScreen:serializeState()
    return self.board:serialize()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function DominosaScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Dominosa"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            self:makeDailyButtonConfig(),
            { text = self:getGridButtonText(), callback = function() self:openGridMenu() end },
            { text = self:getDiffButtonText(), callback = function() self:openDifficultyMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    local controls_w = self:getControlsWidth()
    self.status_text:setMaxWidth(controls_w)
    local action_bar = self:buildActionBar({
        { text = _("Check"),     callback = function() self:onCheck() end },
        { text = _("Hint"),      callback = function() self:onHint() end },
        { text = _("Clear All"), callback = function() self:onClearAll() end },
        { id = "undo_button", text = _("Undo"),
          callback = function() self:onUndo() end },
    })
    self.undo_button = action_bar:getButtonById("undo_button")

    -- The pair table lives with the controls. Its cells are capped so that a
    -- small set does not swell, and it never takes more than its share of
    -- the height away from the board.
    local n = self.board.m + 1
    local share = is_landscape and 0.45 or 0.28
    local pc = math.floor(math.min(controls_w / n, self.dimen.h * share / n,
                                   Size.item.height_default * 1.4))
    self.pair_table = DominosaBoardWidget.PairTable:new{ board = self.board, cell = pc }

    local controls = VerticalGroup:new{
        align = "center",
        self.pair_table,
        VerticalSpan:new{ width = Size.span.vertical_large },
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        action_bar,
    }

    local frame_pad   = Size.padding.large
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = DominosaBoardWidget:new{
        board      = self.board,
        max_width  = budget_w - 2 * frame_pad,
        max_height = budget_h - 2 * frame_pad,
        -- A solved board stays as it is until New game.
        onCellTap  = function(r, c)
            if not self.board:checkWin() then self:onCellTap(r, c) end
        end,
        onEdgeTap  = function(a, b)
            if not self.board:checkWin() then self:afterMove(self.board:toggleDomino(a, b)) end
        end,
        onEdgeHold = function(a, b)
            if not self.board:checkWin() then self:afterMove(self.board:toggleBarrier(a, b)) end
        end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }
    self:_updateUndoButton()

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------------

function DominosaScreen:onCellTap(r, c)
    local what = self.board:tapCell(r, c)
    -- Selecting only repaints the board; the rest changed the position.
    if what == "selected" or what == "deselected" then
        self.board_widget:refresh()
        return
    end
    self:afterMove(true)
end

function DominosaScreen:afterMove(changed)
    if changed then
        self.hint_cell = nil
        self.plugin:saveState(self.board:serialize())
    end
    self:_updateUndoButton()
    self:refreshBoard()
    self:updateStatus()
    self:refreshActionBar()
end

function DominosaScreen:refreshBoard()
    self.board_widget:refresh()
    if self.pair_table then self.pair_table:refresh() end
end

-- ---------------------------------------------------------------------------
-- Game actions
-- ---------------------------------------------------------------------------

function DominosaScreen:onNewGame()
    self.board = DominosaBoard:new{ max_digit = self.plugin:getSetting("max_digit", 4) }
    local diff = self.plugin:getSetting("difficulty", "medium")
    GenProgress.run(function(on_progress) self.board:generate(diff, on_progress) end)
    self.hint_cell = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function DominosaScreen:onClearAll()
    self:afterMove(self.board:clearAll())
end

function DominosaScreen:onUndo()
    -- The board's `undo` field (its UndoStack) shadows the :undo() method.
    local ok, msg = DominosaBoard.undo(self.board)
    if ok then
        self:afterMove(true)
    else
        self:updateStatus(msg)
    end
end

function DominosaScreen:isRoundOver()
    return self.board:checkWin()
end

function DominosaScreen:onHint()
    ScreenBase.onHint(self)
    if self.pair_table then self.pair_table:refresh() end
    self:_updateUndoButton()
end

function DominosaScreen:onCheck()
    local b = self.board
    if b:checkWin() then
        self:updateStatus()
        return
    end
    local wrong = b:countMistakes()
    if wrong == 0 then
        self:updateStatus(T(_("No mistakes so far: %1/%2 dominoes placed."),
            b:getPlacedCount(), b:getTotalDominoes()))
    else
        self:updateStatus(T(_("Wrong dominoes: %1"), wrong))
    end
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

local function sizeText(m)
    return (m + 1) .. "\xC3\x97" .. (m + 2)
end

function DominosaScreen:openGridMenu()
    local sizes = {}
    for _, m in ipairs(MAX_DIGITS) do
        sizes[#sizes + 1] = { id = m, text = T(_("%1 (0 to %2)"), sizeText(m), m) }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("max_digit", 4),
        parent    = self,
        on_select = function(m)
            if m ~= self.board.m then
                self.plugin:saveSetting("max_digit", m)
                self:onNewGame()
            end
        end,
    }
end

function DominosaScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "medium"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            self:onNewGame()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

function DominosaScreen:updateStatus(msg)
    local b = self.board
    local status
    if msg then
        status = msg
    elseif b:checkWin() then
        status = self:joinStatus(_("Congratulations! Puzzle solved!"),
            T(_("Time: %1"), b.timer:format()))
    else
        local label = MenuHelper.DIFFICULTY_LABELS[b.difficulty] or b.difficulty
        status = self:joinStatus(sizeText(b.m), label,
            T(_("Dominoes: %1/%2"), b:getPlacedCount(), b:getTotalDominoes()),
            b.timer:format())
    end
    ScreenBase.updateStatus(self, status)
end

function DominosaScreen:getGridButtonText()
    return T(_("Size: %1"), sizeText(self.board.m))
end

function DominosaScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "medium")
    return T(_("Difficulty: %1"), MenuHelper.DIFFICULTY_LABELS[diff] or diff)
end

function DominosaScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return DominosaScreen
