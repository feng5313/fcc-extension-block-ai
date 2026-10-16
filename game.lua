-- ============================================================================
-- game.lua — 方块对抗游戏逻辑(纯逻辑, 零副作用; 忠实复刻前作C++工程)
--
-- 契约:
--   Game.new() → 实例; 每帧 :tick(input) 推进(60Hz假设, 帧计数与原版同源);
--   副作用通过 events 队列输出(由 main.lua 消费: 音效/粒子/xgl重建)。
--   input = {left,right,rot_cw,rot_ccw,soft,hard,pause,reset,start} (bool)
--
-- 与原版逐条对齐:
--   10×20棋盘; SRS数据表+踢±1; 7-bag(bag<4补7洗牌, 从back取);
--   计分100/300/500/1000; 升级门槛增量min(5*2^n,50), 每级-5帧(45→min15);
--   软降立即+1行(不加分); 硬降直落; ghost; 旋转音效仅"原地转成功"时播放;
--   状态机 title/playing/paused/gameover; reset只清棋盘不清状态;
--   自然落地gameover无音效, 硬降gameover有音效(原版行为)。
-- ============================================================================
-- 模块热重载协议: 原地刷新(保表身保数据, 重定义函数) — 宿主hot-reload重跑
-- 本文件时新逻辑立即生效, typeId/boardGen等数据不丢。
-- ============================================================================
_G.BLOCKAI = _G.BLOCKAI or {}
local Game = _G.BLOCKAI.Game
if not Game then
  Game = {}
  _G.BLOCKAI.Game = Game
end

local W, H = 10, 20
local INIT_FRAMES = 45

-- 4旋转×4块 相对坐标 (SRS数据, 原版tetromino_data同表)
local SHAPES = {
  [0] = { -- I
    {{0,1},{1,1},{2,1},{3,1}}, {{2,0},{2,1},{2,2},{2,3}},
    {{0,2},{1,2},{2,2},{3,2}}, {{1,0},{1,1},{1,2},{1,3}}},
  [1] = { -- J
    {{0,0},{0,1},{1,1},{2,1}}, {{1,0},{2,0},{1,1},{1,2}},
    {{0,1},{1,1},{2,1},{2,2}}, {{1,0},{1,1},{0,2},{1,2}}},
  [2] = { -- L
    {{2,0},{0,1},{1,1},{2,1}}, {{1,0},{1,1},{1,2},{2,2}},
    {{0,1},{1,1},{2,1},{0,2}}, {{0,0},{1,0},{1,1},{1,2}}},
  [3] = { -- O
    {{1,0},{2,0},{1,1},{2,1}}, {{1,0},{2,0},{1,1},{2,1}},
    {{1,0},{2,0},{1,1},{2,1}}, {{1,0},{2,0},{1,1},{2,1}}},
  [4] = { -- S
    {{1,0},{2,0},{0,1},{1,1}}, {{1,0},{1,1},{2,1},{2,2}},
    {{1,1},{2,1},{0,2},{1,2}}, {{0,0},{0,1},{1,1},{1,2}}},
  [5] = { -- T
    {{1,0},{0,1},{1,1},{2,1}}, {{1,0},{1,1},{2,1},{1,2}},
    {{0,1},{1,1},{2,1},{1,2}}, {{1,0},{0,1},{1,1},{1,2}}},
  [6] = { -- Z
    {{0,0},{1,0},{1,1},{2,1}}, {{2,0},{1,1},{2,1},{1,2}},
    {{0,1},{1,1},{1,2},{2,2}}, {{1,0},{0,1},{1,1},{0,2}}},
}

-- 块颜色 (与前作C++工程原版hex一致; I淡紫/J蓝/L橙/O黄/S绿/T紫/Z红)
local COLORS = {
  [0] = {0.00, 0.78, 1.00}, [1] = {0.33, 0.33, 1.0},
  [2] = {1.0, 0.65, 0.0},   [3] = {0.93, 0.87, 0.20},
  [4] = {0.35, 0.98, 0.35}, [5] = {0.63, 0.32, 0.94},
  [6] = {1.0, 0.50, 0.50},
}
Game.COLORS = COLORS   -- 兼容引用(实际显示色用Board.pieceColor)

Game.__index = Game
Game.W, Game.H = W, H
Game.SHAPES, Game.COLORS = SHAPES, COLORS

function Game.new()
  local g = setmetatable({}, Game)
  g.state = "title"
  g.score, g.lines = 0, 0
  g.framesPerStep = INIT_FRAMES
  g.framesUntilFall = INIT_FRAMES
  g.board = {}          -- board[row][col] = tetrominoIdx | nil
  g.bag = {}
  g.active = nil        -- {type, rot, x, y}
  g.blink = 0
  g.events = {}
  g.pieceSeq = 0        -- 已出生块计数(种子用)
  for r = 1, H do
    g.board[r] = {}
    for c = 1, W do g.board[r][c] = false end
  end
  return g
end

function Game:push(ev)
  local n = #self.events + 1
  self.events[n] = ev
end

local function overlap(g, t, rot, x, y)
  local coords = SHAPES[t][rot + 1]
  for i = 1, 4 do
    local cx = x + coords[i][1]
    local cy = y + coords[i][2]
    if cx < 0 or cx >= W or cy < 0 or cy >= H then return true end
    if g.board[cy + 1][cx + 1] then return true end
  end
  return false
end
Game._overlap = overlap

function Game:activeCells(a)
  a = a or self.active
  local coords = SHAPES[a.type][a.rot + 1]
  local out = {}
  for i = 1, 4 do
    out[i] = { a.x + coords[i][1], a.y + coords[i][2] }
  end
  return out
end

function Game:ghostY()
  local a = self.active
  local y = a.y
  while not overlap(self, a.type, a.rot, a.x, y + 1) do y = y + 1 end
  return y
end

local function shuffle(t)
  for i = #t, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
end

function Game:generate()
  local pick = self.bag[#self.bag]
  self.bag[#self.bag] = nil
  self.pieceSeq = self.pieceSeq + 1
  local a = { type = pick, rot = 0, x = math.floor((W - 4) / 2), y = 0,
              seq = self.pieceSeq }
  self.active = a
  if #self.bag < 4 then
    local pieces = { 0, 1, 2, 3, 4, 5, 6 }
    shuffle(pieces)
    for i = 1, #self.bag do pieces[#pieces + 1] = self.bag[i] end
    self.bag = pieces
  end
  if overlap(self, a.type, a.rot, a.x, a.y) then return false end
  self.framesUntilFall = INIT_FRAMES
  self:push({ "spawn", type = pick, seq = self.pieceSeq })
  return true
end

function Game:startPlaying()
  self.score, self.lines = 0, 0
  self.framesPerStep = INIT_FRAMES
  self.framesUntilFall = INIT_FRAMES
  self.level = 1            -- 升级门槛增量min(5*2^n,50)(风主#9620/#9622)
  self.nextLevelLines = 5
  self.boardSeq = (self.boardSeq or 0) + 1   -- 写临界区开(奇=写中)
  for r = 1, H do
    for c = 1, W do self.board[r][c] = false end
  end
  self.boardSeq = self.boardSeq + 1          -- 写临界区关(偶=一致)
  self.bag = { 0, 1, 2, 3, 4, 5, 6 }
  shuffle(self.bag)
  self:generate()
  self:push({ "start" })
end

function Game:reset()
  self.boardSeq = (self.boardSeq or 0) + 1   -- 写临界区开
  for r = 1, H do
    for c = 1, W do self.board[r][c] = false end
  end
  self.boardSeq = self.boardSeq + 1          -- 写临界区关
  self.lines, self.score = 0, 0
  self:push({ "reset" })
end

-- 一致性快照读(seqlock): 渲染层(2D/3D/debug)唯一合法读法 —
-- 奇seq=写中/读后seq变化=读到一半 → 重试(4次), 全失败返回nil
-- (调用方跳过本帧, 下tick数据一致; 杜绝"消行移位到一半"的撕裂板)
function Game:boardSnapshot()
  for _ = 1, 4 do
    local v1 = self.boardSeq or 0
    if (v1 % 2) == 0 then
      local rows = {}
      for r = 1, H do
        local src, dst = self.board[r], {}
        for c = 1, W do dst[c] = src[c] end
        rows[r] = dst
      end
      if self.boardSeq == v1 then return rows end   -- 读后复查一致
    end
  end
  return nil
end

-- 落块入板 + 消行检测 + 计分/提速 (原版summon_tetromino_to_board)
-- board值打包: type + seq*8 (seq=块组id, 随机材质按组统一用;
-- 低3位=type(0-6), 高位=组id; 逻辑层只用truthiness不受影响)
function Game:summon(a, viaHard)
  local coords = SHAPES[a.type][a.rot + 1]
  local landed = {}
  self.boardSeq = (self.boardSeq or 0) + 1   -- 写临界区开(盖章+消行移位)
  for i = 1, 4 do
    local cx, cy = a.x + coords[i][1], a.y + coords[i][2]
    if cx >= 0 and cx < W and cy >= 0 and cy < H then
      self.board[cy + 1][cx + 1] = a.type + a.seq * 8
      landed[#landed + 1] = { cx, cy, a.type }
    end
  end
  self:push({ "land", viaHard = viaHard, cells = landed })

  -- 满行检测
  local fullRows = {}
  for r = 1, H do
    local full = true
    for c = 1, W do
      if not self.board[r][c] then full = false break end
    end
    if full then fullRows[#fullRows + 1] = r end
  end

  local clearedCells = {}
  if #fullRows > 0 then
    local n = #fullRows
    local sc = (n >= 4) and 1000 or ({ 100, 300, 500 })[n]
    local oldLines = self.lines
    self.score = self.score + sc
    self.lines = self.lines + n
    for _, r in ipairs(fullRows) do
      for c = 1, W do
        local v0 = self.board[r][c]
        clearedCells[#clearedCells + 1] =
            { c - 1, r - 1, v0 % 8, math.floor(v0 / 8) }  -- type解包+组id
      end
    end
    -- 消行下移(从底往上写)
    local write = H
    for read = H, 1, -1 do
      local isFull = false
      for _, fr in ipairs(fullRows) do
        if fr == read then isFull = true break end
      end
      if not isFull then
        if write ~= read then
          for c = 1, W do self.board[write][c] = self.board[read][c] end
        end
        write = write - 1
      end
    end
    for r = write, 1, -1 do
      for c = 1, W do self.board[r][c] = false end
    end
    self:push({ "clear", rows = fullRows, cells = clearedCells,
                score = sc, total = self.lines })
    -- 升级门槛=min(5*2^n, 50)(风主#9620/#9622): checkLevelUp单一权威
    -- (鼠标整行消除main.lua clickCell同源调用)
    self:checkLevelUp()
  end
  self.boardSeq = self.boardSeq + 1          -- 写临界区关(盖章+消行完成)
end

-- 升级判定(单一权威, summon与鼠标整行消除共用, 风主#9622): 门槛增量
-- = min(5*2^n, 50) — 5,10,20,40,50,50...指数翻倍到50封顶(后期不无限
-- 陡峭); 累计阈值nextLevelLines越过即升级+提速(每级-5帧, 下限15帧),
-- levelup事件由consumeEvents联动AI速度+1。n=level-1(新级), 首个门槛5行
-- 在startPlaying设置; while兼容单次多行跨越多门槛。
function Game:checkLevelUp()
  if self.level == nil then
    self.level = 1
    self.nextLevelLines = 5
  end
  while self.lines >= (self.nextLevelLines or 5) do
    self.level = self.level + 1
    self.nextLevelLines = (self.nextLevelLines or 5)
                         + math.min(5 * 2 ^ (self.level - 1), 50)
    self.framesPerStep = math.max(15, self.framesPerStep - 5)
    self:push({ "levelup", speed = self.framesPerStep })
  end
end

function Game:updatePlaying(inp)
  if inp.pause then
    self.state = "paused"
    self:push({ "pause" })
  end
  local a = self.active
  if not a then return end
  -- 水平移动
  if inp.left or inp.right then
    local nx = a.x + (inp.left and -1 or 1)
    if not overlap(self, a.type, a.rot, nx, a.y) then
      a.x = nx
      self:push({ "move", dir = inp.left and -1 or 1 })
    end
  end
  -- 旋转(原版语义: rot_cw=(r+3)%4踢±1; rot_ccw=(r+1)%4踢±1; 音效仅原位成功)
  for _, dirRot in ipairs({ inp.rot_cw and 1 or 0, inp.rot_ccw and 2 or 0 }) do
    if dirRot > 0 then
      local nr = (dirRot == 1) and (a.rot + 3) % 4 or (a.rot + 1) % 4
      if overlap(self, a.type, nr, a.x, a.y) then
        if not overlap(self, a.type, nr, a.x - 1, a.y) then
          a.rot, a.x = nr, a.x - 1
          self:push({ "rotate", kicked = true })
        elseif not overlap(self, a.type, nr, a.x + 1, a.y) then
          a.rot, a.x = nr, a.x + 1
          self:push({ "rotate", kicked = true })
        end
      else
        a.rot = nr
        self:push({ "rotate" })
      end
    end
  end
  -- 自然下落
  self.framesUntilFall = self.framesUntilFall - 1
  if self.framesUntilFall <= 0 then
    self.framesUntilFall = self.framesPerStep
    if overlap(self, a.type, a.rot, a.x, a.y + 1) then
      self:summon(a, false)
      if not self:generate() then
        self.state = "gameover"
        self:push({ "gameover", hard = false })
      end
    else
      a.y = a.y + 1
      self:push({ "fall" })
    end
  end
  -- 软降
  if inp.soft then
    if not overlap(self, a.type, a.rot, a.x, a.y + 1) then
      a.y = a.y + 1
      self:push({ "soft" })
    end
  end
  -- 硬降
  if inp.hard then
    local y = a.y
    while not overlap(self, a.type, a.rot, a.x, y + 1) do y = y + 1 end
    a.y = y
    self:summon(a, true)
    if not self:generate() then
      self.state = "gameover"
      self:push({ "gameover", hard = true })
    end
  end
  if inp.reset then self:reset() end
end

function Game:tick(inp, dt)
  self.blink = (self.blink + (dt or 1 / 60)) % 1.0
  if self.state == "title" then
    if inp.start then
      self:startPlaying()
      self.state = "playing"
    end
  elseif self.state == "playing" then
    self:updatePlaying(inp)
  elseif self.state == "paused" then
    if inp.pause then
      self.state = "playing"
      self:push({ "resume" })
    end
  elseif self.state == "gameover" then
    if inp.start then
      self:startPlaying()
      self.state = "playing"
    end
  end
end

_G.BLOCKAI.Game = Game
return Game
