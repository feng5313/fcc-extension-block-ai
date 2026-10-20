-- fcc-api: >=2
-- ============================================================================
-- main.lua — 方块对抗扩展入口 (纯Lua扩展; 扩展包 block-ai)
--
-- 玩法(风主#2077钦定): AI自动消除 对抗 鼠标点击消除 — AI落块消行
--       (自动消除速度1~10可调), 玩家鼠标左键点击方块消除单个方块/
--       点击一行最后一块=整行消除加分。无键盘玩法。
-- 入口: 右键菜单 → 扩展 → 方块对抗 | 命令行 --run block-ai
--       | RPC block-ai.*
-- 架构: game.lua纯逻辑 → 事件 → board.lua真3D mesh粒子方块(默认)+
--       2D备选(hud.lua屏幕层绘制, renderMode=1) + audio.lua音频;
--       全API(Lua与debug-server)同源: fcc.rpc / HTTP /rpc/block-ai/*。
--
-- 热重载: 宿主hot-reload中心(#2059)监视扩展包*.lua变化自动重跑整包
--         (loadfile+pcall); 模块守卫使重跑幂等, 本文件gen递增
--         使旧代际回调(tick/mouse/on_render)自杀。
-- 路径: 一律绝对路径且经 debug.getinfo 自定位(本地扩展目录可安装在意
--       任意位置 — UI「添加本地扩展」/ market.add_local 注册, 零硬编码)。
local srcInfo = debug.getinfo(1, "S").source
local THIS_PATH = (srcInfo:sub(1, 1) == "@") and srcInfo:sub(2) or srcInfo
local PKG_DIR = (THIS_PATH:match("^(.*)[\\/]") or "."):gsub("\\", "/")

-- 显式按序加载模块(幂等: 模块文件自带守卫, 重复dofile无害;
-- 宿主加载序为字母序, main在render/shaders之前 → 此处补齐依赖序)
local function pkgFile(name) return PKG_DIR .. "/" .. name end
dofile(pkgFile("game.lua"))
dofile(pkgFile("board.lua"))
dofile(pkgFile("hud.lua"))
dofile(pkgFile("audio.lua"))

-- base64编码(set_pixels 128×128 RGBA白纹理用; papers.lua同款)
do
  local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  _G.BLOCKAI.b64 = function(s)
    local out, i = {}, 1
    while i <= #s do
      local a, b, c = s:byte(i), s:byte(i + 1) or 0, s:byte(i + 2) or 0
      local pad = #s - i
      local n = a * 65536 + b * 256 + c
      local e1 = B64:sub(math.floor(n / 262144) % 64 + 1,
                         math.floor(n / 262144) % 64 + 1)
      local e2 = B64:sub(math.floor(n / 4096) % 64 + 1,
                         math.floor(n / 4096) % 64 + 1)
      local e3 = B64:sub(math.floor(n / 64) % 64 + 1,
                         math.floor(n / 64) % 64 + 1)
      local e4 = B64:sub(n % 64 + 1, n % 64 + 1)
      if pad == 1 then out[#out + 1] = e1 .. e2 .. e3 .. "="
      elseif pad == 0 then out[#out + 1] = e1 .. e2 .. "=="
      else out[#out + 1] = e1 .. e2 .. e3 .. e4 end
      i = i + 3
    end
    return table.concat(out)
  end
end

local Game, Board, Hud, Audio =
      _G.BLOCKAI.Game, _G.BLOCKAI.Board,
      _G.BLOCKAI.Hud, _G.BLOCKAI.Audio

local gen = (_G.__BLOCKAI_GEN or 0) + 1
_G.__BLOCKAI_GEN = gen

-- ── 全局状态(热重载代际交接: 继承旧代表保会话/设置连续, 新函数接管) ──────
local S = _G.BLOCKAI.state or {}
-- 设置持久化(风主#9615): 用户设置(AI速度/材质/特效/音量)跨进程重启保留,
-- 存fcc配置目录blockai_settings.json; 仅首次(全新S表)加载, 热重载不覆盖
local function settingsPath()
  local ok, d = pcall(fcc.get_config_dir)
  if ok and type(d) == "string" and #d > 0 then
    return d .. (d:sub(-1) == "\\" and "" or "\\") .. "blockai_settings.json"
  end
  return nil
end

local function loadSettings()
  local p = settingsPath()
  if not p then return end
  local ok, c = pcall(fcc.read_file, p)
  if not ok or type(c) ~= "string" or #c == 0 then return end
  local okD, t = pcall(fcc.json_decode, c)
  if not okD or type(t) ~= "table" then return end
  local num = function(k, lo, hi, dflt)
    local v = tonumber(t[k])
    if v == nil then return dflt end
    return math.max(lo, math.min(hi, math.floor(v + 0.5)))
  end
  S.matId = num("matId", 0, 4, nil)
  S.fxId = num("fxId", 0, 5, nil)
  -- autoClear不持久化(风主#9616): 每局从1爬升, 进程重启也回1
  if type(t.fxAuto) == "boolean" then S.fxAuto = t.fxAuto end
  -- 音效音量(风主#9605: 原"总音量"volMaster): 新键volSfx, 兼容读旧键volMaster
  local vs = tonumber(t.volSfx) or tonumber(t.volMaster)
  if vs then S.volSfx = math.max(0, math.min(1, vs)) end
  local vb = tonumber(t.volBgm)
  if vb then S.volBgm = math.max(0, math.min(1, vb)) end
  print("[block-ai] 设置已加载: AI速度=" .. tostring(S.autoClear))
end

local function saveSettings()
  local p = settingsPath()
  if not p then return end
  local okE, j = pcall(fcc.json_encode, {
    matId = S.matId, fxId = S.fxId,
    fxAuto = S.fxAuto, volSfx = S.volSfx, volBgm = S.volBgm,
  })
  if okE and type(j) == "string" then pcall(fcc.write_file, p, j) end
end

if S._cfgLoaded ~= true then
  S._cfgLoaded = true
  loadSettings()
end
if S.game == nil then S.game = nil end          -- 显式字段(文档性)
if S.active == nil then S.active = false end
if S.renderMode == nil then S.renderMode = 0 end
if S.matId == nil then S.matId = 2 end          -- 材质 0积木/1玻璃/2软糖(默认)/3金属
if S.fxId == nil then S.fxId = 0 end            -- 消除特效 0融化/1爆炸/2缩小/3透明/4雾化
if S.fxAuto == nil then S.fxAuto = true end
if S.volSfx == nil then S.volSfx = S.volMaster end  -- 热重载在内存迁移(旧代S带volMaster)
if S.volSfx == nil then S.volSfx = 0 end    -- 音效音量默认0(静音, 风主钦定; #9605原总音量)
if S.volBgm == nil then S.volBgm = 0 end
if S.autoClear == nil then S.autoClear = 1.0 end -- 自动消除行/秒(1~10, 10=不限速)
-- 对抗模式AI恒玩(风主#2077): 范围钳制1~10, 不再有0=off
S.autoClear = math.max(1, math.min(10, math.floor(S.autoClear + 0.5)))
if S.acAcc == nil then S.acAcc = 0 end
if S.now == nil then S.now = 0 end
if S.requestPause == nil then S.requestPause = false end
if S.requestResume == nil then S.requestResume = false end
if S.requestRestart == nil then S.requestRestart = false end
if S.requestStop == nil then S.requestStop = false end
if S.aiWon == nil then S.aiWon = false end   -- 胜利定格(风主#9622/#9625): AI消满360行
if S.requestRenderMode == nil then S.requestRenderMode = nil end
-- 回调订阅id(旧代已自杀, 下方活跃会话统一重订阅刷新)
S.tickSub = nil; S.renderSub = nil
S.mouseSub = nil         -- 鼠标订阅(点击消除方块)
S.hoverSub = nil         -- 悬停订阅(风主#9624: 鼠标处方块颤动)
-- #10830拖擦状态机: LMB按下期间鼠标经过的方块全部消除 —
-- down置位(棋盘内=mouseHandler独占订阅, 棋盘外=hoverHandler兜底订阅),
-- up清零(两订阅都收up, 宿主up事件不按rect过滤必达), move逐格消除。
S.erasing = false
S.lastErCol, S.lastErRow = -1, -1   -- 去重: 同格move不重复消
S.capRect = nil                     -- 已同步宿主的capture矩形缓存(syncCapRect)
if S.auto == nil then S.auto = nil end          -- autopilot {steps, t}
if S.pendingStart == nil then S.pendingStart = false end
if S.shaderPending == nil then S.shaderPending = false end   -- 2D兜底中(#2077)
if S.shaderTryAt == nil then S.shaderTryAt = 0 end
S.shaderEvSub = nil; S.shaderEvSub2 = nil
_G.BLOCKAI.state = S
_G.BLOCKAI.thisGen = gen

-- ── 事件消费(game.events → 音效/粒子/特效) ────────────────────────────────
local function spawnClearEffects(cells)
  -- 消除特效: 3D模式=mesh特效粒子(board.fx3D); 2D模式=HUD层动画
  -- fxId==5=随机: 每次消除从5种中随机选
  local fx = S.fxId or 0
  if fx == 5 then
    fx = math.random(0, 4)
    if S.fxAuto ~= true then S.fxId = fx end
  end
  if S.renderMode == 0 then
    Board.fx3D(cells, fx, S.matId)
  else
    _G.BLOCKAI.Hud.FxPlay(cells, fx)
  end
  -- 特效固定模式(0-4)恒定不变(风主钦定#9546); 仅5=随机时每次消除随机选
end

local function consumeEvents(game)
  for _, ev in ipairs(game.events) do
    local k = ev[1]
    if k == "move" then
      Audio.play("move", 0.7)
    elseif k == "rotate" then
      Audio.play("rotate", 0.8)
    elseif k == "fall" or k == "soft" then
      -- 自然下落无声(原版), 软降用move音
      if k == "soft" then Audio.play("move", 0.5) end
    elseif k == "land" then
      Audio.play("fall", 0.9)
      -- 块由快照层自动出现(board数组直驱, 无增量出生)
    elseif k == "clear" then
      -- 整行消除=clear和弦; 鼠标单击单格=zap独特音效(风主#9622钦定:
      -- ev.rows仅整行消除携带, 单格消除只有cells)
      if ev.rows then Audio.play("clear", 1.0)
      else Audio.play("zap", 0.9) end
      spawnClearEffects(ev.cells)
      -- 行移/消除由快照层自动反映(数组直驱零同步)
    elseif k == "levelup" then
      -- 下落速度升级时自动消除速度也升1级(风主#2077; 1~10封顶)
      if S.autoClear and S.autoClear < 10 then
        S.autoClear = S.autoClear + 1
        print("[block-ai] 升级! 下落加速+自动消除速度→" .. S.autoClear .. "行/秒")
      end
    elseif k == "gameover" then
      if ev.hard then Audio.play("gameover", 1.0) end
      Audio.stopBgm()
      Board.setHover(-1, -1)   -- 结束定格: 悬停颤动停止(#9624)
    elseif k == "start" then
      -- board清空→快照层自动清场(clear_types原子清+空板重写)
      Audio.play("start", 0.9)   -- 开局音(风主#9622: 原start.wav资产接线)
      Audio.startBgm()
      S.acBase = nil            -- 自动消除基准随新局重置
    elseif k == "reset" then
      S.acBase = nil
    end
  end
  game.events = {}
end

-- ── tick(60Hz worker线程) ─────────────────────────────────────────────────
-- 渲染=board数组纯函数快照(3D mesh粒子, 同帧原子清+写) + HUD屏幕层;
-- fx特效=独立type自生自灭; lua游戏逻辑只更新board数组(#9455铁令)
local function gameTick(inp)
  S.game:tick(inp, 1 / 60)
  consumeEvents(S.game)
end

local tryUpgrade3D   -- 前向声明(定义于生命周期段, tickHandler先引用)
local syncCapRect    -- 前向声明(#10830: 定义于鼠标订阅段, tickHandler先引用)

local function tickHandler(t)
  if _G.__BLOCKAI_GEN ~= gen then return end
  S.now = t
  -- #10830: 棋盘矩形跟随图片(平移/缩放/换图移动锚定矩形) — 每tick比对
  -- 同步(pendingStart等待期订阅已激活, rect也须尽早修正到真实棋盘)
  syncCapRect()
  -- 延迟启动(等网格/粒子系统就绪; 0.5s节流+每tick只探一步 —
  -- boot期粒子RPC可能长超时, 60Hz重试锤爆worker=整机lua假死数分钟)
  if S.pendingStart then
    if not S.pendT then S.pendT = 0 end
    S.pendT = S.pendT + 1 / 60
    if S.pendT >= 0.5 then
      S.pendT = 0
      S.pendStep = ((S.pendStep or 0) % 3) + 1
      local ok = false
      if S.pendStep == 1 then
        ok = Board.ensureFish()
      elseif S.pendStep == 2 then
        ok = Board.refreshGeometry()
      else
        ok = Board.ensureType()
      end
      if ok and S.pendStep == 3 then
        S.pendingStart = false
        S.geoKey = Board.visGeo and Board.visGeo.geoKey
        S.game = Game.new()
        S.game:tick({ start = true })
        consumeEvents(S.game)
        S.injectVerifyAt = t + 3   -- 注入提交后延迟验证落地
        S.injectSecondCheck = nil
      end
    end
    return
  end
  -- 2D兜底期Shader就绪重试(#2077): 2s节流(事件驱动为主通道, 此为兜底)
  if S.shaderPending and t >= (S.shaderTryAt or 0) + 2 then
    S.shaderTryAt = t
    tryUpgrade3D()
  end
  if not S.active or not S.game then return end
  -- RT几何低频刷新(0.5s): 仅服务fx特效重力/新格子的cell取值;
  -- 方块/槽位出生后位置由锚点绝对定位驱动(GPU侧幂等跟随图片矩形),
  -- 缩放零重建零重摆(风主铁令#9501: 方块发射后固定不变)
  S.geoT = (S.geoT or 0) + 1 / 60
  if S.geoT >= 0.5 then
    S.geoT = 0
    Board.refreshGeometry()
  end
  -- 换图检测(geoKey=源图原始像素, 不含显示尺寸): 缩放/全屏切换零重摆
  -- (锚点绝对定位跟随, C++侧重建触发已用源图尺寸, 显示模式切换不再
  -- 全池清屏); 换图(dim/imgRect源变)→防抖0.35s稳定后一次干净全量换血
  local gk = Board.visGeo and Board.visGeo.geoKey
  if gk and S.geoKey and gk ~= S.geoKey then
    S.geoKeyPend = gk
    S.resyncAt = t + 0.35
  end
  if S.resyncAt and t >= S.resyncAt then
    S.resyncAt = nil
    if Board.refreshGeometry() then
      -- 格子位置/尺寸出生定死(锚点) → 换图必须换血; board数据无损,
      -- reconcile自动重铺+全量repaint
      Board.rebuildCells()
      -- 快照层自动用新几何重写(数组直驱零同步); CS特效重力自适应
      Board.setShaderInjects()
      S.injectVerifyAt = t + 3   -- 重新提交后须验证落地
      S.injectSecondCheck = nil
      S.geoKey = S.geoKeyPend or S.geoKey
      S.geoKeyPend = nil
    else
      -- 几何未就绪(owner忙/RPC失败) → 0.35s后重试, 不丢换图重建
      S.resyncAt = t + 0.35
    end
  end
  -- 注入落地自愈: 提交≠生效(全粒子组重编译需0.3~7s; 编译失败后cpp侧
  -- 幂等去重会拦同内容重提交, dirty又被clearInjectDirtyIfUnchanged清掉
  -- → 永不重试=平面方块/旧角度永久服役)。提交后3s/12s查particle/info:
  -- shader_reload_busy(#2077修复②)=管线编译中→ok是陈旧旧值, 仅顺延3s
  -- 复查不重试(防长编译期重提交→重编译排队风暴); 仅!busy且
  -- shader_reload_ok==false(#1822验证钩子, 确定失败)才带retry标记重提交
  -- (内容变化强制重建), 最多8次。
  if S.injectVerifyAt and t >= S.injectVerifyAt then
    -- busy预检(风主#9622): particle.info含emitters的owner同步dump, owner忙
    -- (后台编译着色器)时250ms阻塞持lua锁=on_render跳帧面板闪烁; 先用
    -- hotreload.status(非阻塞)探测, 编译中顺延3s不计次不重试(与下方
    -- shader_reload_busy分支同语义, 但零阻塞)
    if Board.ownerBusy() then
      S.injectVerifyAt = t + 3
    else
      S.injectVerifyAt = nil
      local ri = fcc.rpc("particle", "info", {})
      if ri and ri.ready and ri.shader_reload_busy then
        S.injectVerifyAt = t + 3        -- 编译中: 等待, 不计次不重试
      elseif ri and ri.ready and ri.shader_reload_ok == false then
        S.injectTries = (S.injectTries or 0) + 1
        if S.injectTries <= 8 then
          print("[block-ai] 注入未生效, 带标记重提交 (" .. S.injectTries .. "/8)")
          Board.setShaderInjects(S.injectTries)
          S.injectVerifyAt = t + 3
        end
      else
        S.injectTries = 0
        -- 二次校验: 首查(+3s)可能落在注入版仍在编译中(冷编译6.8s, 读到
        -- init成功残留的true), +12s再查一次兜底
        if not S.injectSecondCheck then
          S.injectSecondCheck = true
          S.injectVerifyAt = t + 9
        end
      end
    end
  end
  -- HUD请求
  if S.requestPause then
    S.requestPause = false
    if S.game.state == "playing" then
      S.game:tick({ pause = true }) consumeEvents(S.game)
    end
  end
  if S.requestResume then
    S.requestResume = false
    if S.game.state == "paused" then
      S.game:tick({ pause = true }) consumeEvents(S.game)
    end
  end
  if S.requestRestart then
    S.requestRestart = false
    S.autoClear = 1   -- 新局AI速度重置(风主#9616): 每局从1随levelup爬升
    S.aiWon = false   -- 胜利定格复位(风主#9622)
    -- 快速重启(资源有效时): game即刻重建; 粒子不清不重建(风主#9623钦定:
    -- 重开只初始化board数据) — 空board数组经快照调和diff逐格自然渐清
    -- (数据直驱, 无视觉跳变); 资源失效(热重载后)才走分步pendingStart重建
    if Board.typeOk and Board.resGen == _G.__BLOCKAI_GEN
       and Board.visGeo then
      local g = Game.new()
      S.game = g
      g:tick({ start = true })
      consumeEvents(g)      -- start事件→bgm; 旧块由调和层diff自然清场
    else
      Board.killAll()       -- 资源换代: 粒子系统随几何重铺, 必须整清
      S.game = nil
      S.pendingStart = true
      S.pendStep = 0
      S.pendT = 0.5
    end
    return
  end
  if S.requestStop then
    S.requestStop = false
    _G.BLOCKAI.stop()
    return
  end
  -- 胜利定格(风主#9622/#9625): AI消满360行→停止一切消除/落块, 盘面冻结,
  -- HUD居中显示"AI胜利！"; [重新开始]复位。gameover则HUD显示"你胜利了！"
  if not S.aiWon and S.game.state == "playing" and S.game.lines >= 360 then
    S.aiWon = true
    print("[block-ai] AI消满360行 → 胜利定格")
  end
  if S.aiWon then return end
  -- gameover不自动续局(风主#9613): 停在结束画面, 玩家点[重新开始]开新局
  -- (旧1.2s自动重开已移除)
  -- 渲染模式切换(3D mesh粒子 ↔ 2D屏幕层): 快照下tick自动反映
  if S.requestRenderMode ~= nil then
    local m = S.requestRenderMode
    S.requestRenderMode = nil
    if S.renderMode ~= m then
      S.renderMode = m
      Board.visible3d = (m == 0)
      print("[block-ai] 渲染模式 → " .. (m == 0 and "3D" or "2D"))
    end
  end
  -- 材质切换: 快照variant直接生效(数组直驱, 无需换血)
  -- 设置变化持久化(风主#9615/#9616): 快照对比(60Hz微开销), 变化即写盘
  -- — AI速度不参与(每局从1爬升, 不持久化)
  local snap = S.matId .. "," .. S.fxId .. ","
               .. tostring(S.fxAuto) .. "," .. S.volSfx .. "," .. S.volBgm
  if S._cfgSnap ~= snap then
    S._cfgSnap = snap
    saveSettings()
  end
  -- 自动消除(#9436/#9438): 真实玩法消行 — autopilot对局机(评估/旋转/
  -- 平移/硬降)匀速节拍出块(步频=目标行数×15步/s, ≈2.5块/行, 无突发冲刺),
  -- 消行数落后目标时匀速追赶; ≥10=不限速; 手动autopilot优先
  -- AI速度1~3档=标称×0.25(原×0.5再减半, 风主#9645), 4~7=×0.5, 8~10=原速
  if S.autoClear and S.autoClear >= 1 and S.game.state == "playing"
      and not S.auto then
    if S.acLastClear ~= S.autoClear then
      S.acLastClear = S.autoClear
      S.acBase = nil
    end
    if not S.acBase then
      S.acBase = S.game.lines S.acAcc = 0 S.acPace = 0
    end
    -- AI速度1~3档在原减半(#9613)基础上再减半=×0.25(风主#9645),
    -- 4~7档保持×0.5, 8~10档原速
    local acSpeed = (S.autoClear >= 8) and S.autoClear
             or (S.autoClear >= 4) and S.autoClear * 0.5
             or S.autoClear * 0.25
    S.acAcc = S.acAcc + acSpeed / 60
    local done = S.game.lines - S.acBase
    if not S.acBot then S.acBot = { steps = 1e9 } end
    if S.autoClear >= 10 then
      -- pcall保护: bot步进抛错会杀死tickHandler(无pcall的宿主回调)
      -- =游戏冻结/消行停滞; 错误捕获到S.botErr供debug诊断
      local okB, inpB = pcall(_G.BLOCKAI_DBG.autopilotStep, S.acBot)
      if not okB then
        S.botErr = tostring(inpB):sub(1, 200)
        inpB = nil
      end
      gameTick(inpB or {})   -- 每tick恰一帧(等待步也推进自然下落);
      S.acTicked = true      -- 跳过下方键输入tick(防双帧=重力2x执行错乱)
    elseif done + 0.999 < S.acAcc then
      S.acPace = S.acPace + (acSpeed * 15) / 60
      if S.acPace >= 1 then
        S.acPace = S.acPace - 1
        local okB, inpB = pcall(_G.BLOCKAI_DBG.autopilotStep, S.acBot)
        if not okB then
          S.botErr = tostring(inpB):sub(1, 200)
          inpB = nil
        end
        if inpB then gameTick(inpB) S.acTicked = true end
      end
    end
  else
    S.acBase = nil
    S.acAcc = 0
    S.acPace = 0
    S.acBot = nil
  end
  -- autopilot(手动RPC触发; 优先于自动消除的bot)
  if S.auto and S.game and S.game.state == "playing" then
    local okA, inpA = pcall(_G.BLOCKAI_DBG.autopilotStep, S.auto)
    if not okA then S.botErr = tostring(inpA):sub(1, 200); inpA = nil end
    if inpA then
      gameTick(inpA)
      S.acTicked = true        -- 已tick, 跳过下方无人输入tick(防双帧)
    end
    if S.auto and S.auto.steps <= 0 then S.auto = nil end
  end
  -- 无人输入tick(去键盘#2077): 自动消除未覆盖的tick推进自然下落/消行
  if not S.acTicked then
    local ok, terr = pcall(gameTick, {})
    if not ok then S.tickErr = tostring(terr):sub(1, 200) end
  end
  S.acTicked = false
  -- 快照泵: board数组→3D粒子整板原子重写(清+写同帧);
  -- fx批(独立type自生自灭, ≤800项/tick)
  local okS = Board.snapshot(S.game)
  if not okS then S.tickErr = Board.statSnap and Board.statSnap.err or "snap" end
  Board.flushFx()
end

-- ── 点击消除(#2077): 对抗玩法核心玩家操作 ────────────────────────────────
-- clickCell(col,row 0基): 消除该格方块; 该行最后一块→整行消除+加分+上方
-- 下移。真实鼠标(mouseHandler坐标命中)与RPC click(格坐标)同链路 —
-- 自动化测试/AI代理经RPC即可当"鼠标玩家"(所有UI功能必须可API调用)。
local function clickCell(col, row)
  local g = S.game
  if not g or g.state ~= "playing" then
    return { ok = false, error = "not playing" }
  end
  local v = g.board[row + 1][col + 1]
  if not v then return { ok = false, error = "empty cell" } end
  g.boardSeq = g.boardSeq + 1          -- 写临界区开(与boardSnapshot并发防护)
  g.board[row + 1][col + 1] = false
  -- 消除格(含组id): 特效/音效统一走"clear"事件链路(consumeEvents消费,
  -- 与AI消行同源; 单格与整行都推事件=零双触发零遗漏)
  local cell = { col, row, v % 8, math.floor(v / 8) }
  -- 整行清空判定(风主#2077): 点击的是该行最后一块 → 整行消除加分
  -- +上方方块下落填满空行(与lockPiece消行同源规则)
  local rowAny = false
  for c = 1, 10 do
    if g.board[row + 1][c] then rowAny = true break end
  end
  if not rowAny then
    g.score = g.score + 100
    g.lines = g.lines + 1
    for read = row, 1, -1 do           -- 被清行上方整体下移一行
      for c = 1, 10 do g.board[read + 1][c] = g.board[read][c] end
    end
    for c = 1, 10 do g.board[1][c] = false end
    -- 升级判定与game.lua完全同源(Game:checkLevelUp, 风主#9622门槛
    -- min(5*2^n,50)) — 旧内联"每5行"公式与summon的指数门槛分歧已统一
    g:checkLevelUp()
    g:push({ "clear", rows = { row + 1 }, cells = { cell },
             score = 100, total = g.lines })
  else
    g:push({ "clear", cells = { cell } })   -- 单格消除: 同链路特效/音效
  end
  g.boardSeq = g.boardSeq + 1          -- 写临界区关
  return { ok = true, col = col, row = row, rowCleared = not rowAny,
           score = g.score, lines = g.lines }
end

-- 鼠标左键: 屏幕坐标→棋盘格→clickCell
-- col/row命中用cellX/cellY(RT量化纵横比修正, hud.boardRect同源) —
-- 水平cellX≠垂直cellY时各向同性假设会让边缘列点击错位近一格
-- #10830拖擦: 独占订阅(棋盘矩形内capture)收down+up(button 0) —
-- down消格+置拖擦态, up清拖擦态(宿主up不按rect过滤, 任何位置必达);
-- 拖动经过的格子由hoverHandler(move)逐格消除。
local function mouseHandler(kind, x, y, button)
  if _G.__BLOCKAI_GEN ~= gen or not S.active then return end
  if button ~= 0 then return end
  if kind == "up" then
    S.erasing = false          -- 释放: 拖擦结束(棋盘内外任何位置)
    return
  end
  if kind ~= "down" then return end
  S.lastMouseEv = os.clock()      -- #2104诊断打点: 事件到达证明capture链路活
  S.erasing = false               -- 新按下: 拖擦状态重开
  S.lastErCol, S.lastErRow = -1, -1
  local g = S.game
  if not g then return end
  local b = _G.BLOCKAI.Hud.boardRect()
  if not b then return end
  local col = math.floor((x - b.x) / b.cellX)
  local row = math.floor((y - b.y) / b.cellY)
  if col < 0 or col > 9 or row < 0 or row > 19 then return end
  -- 游戏结束: 点击棋盘区域=自动重新开始(风主#9648, 无需找面板按钮)
  if g.state == "gameover" then
    S.requestRestart = true
    return
  end
  if g.state ~= "playing" then return end
  S.erasing = true                -- 按住: 进入拖擦(经过的方块全消除)
  S.lastErCol, S.lastErRow = col, row
  clickCell(col, row)
end

-- 悬停跟踪(风主#9624): 鼠标处的方块轻微颤动 — move事件→格坐标→
-- Board.setHover(varParams user.y, SSBO实时零重编译, VS注入消费)。
-- 非capture订阅(宿主鼠标移动行为零影响); 仅playing态生效, 跨格才发RPC。
-- #10830拖擦兜底: 本订阅另收棋盘外LMB down(棋盘内被mouseSub独占)+全部
-- up(button 0) — 棋盘外按下扫入棋盘同样消除; move期间S.erasing逐格消除。
local function hoverHandler(kind, x, y, button)
  if _G.__BLOCKAI_GEN ~= gen or not S.active then return end
  if button == 0 then
    if kind == "down" then
      -- 棋盘外按下: 也进入拖擦(需求"左键按下时经过的方块都消除",
      -- 无论起手点; 此处收到down=棋盘外, 棋盘内被mouseSub独占)
      local g = S.game
      S.erasing = g ~= nil and g.state == "playing"
      S.lastErCol, S.lastErRow = -1, -1
    elseif kind == "up" then
      S.erasing = false   -- 双保险(mouseHandler的up若因热重载丢失在此兜底)
    end
  end
  if kind ~= "move" then return end
  local g = S.game
  if not g or g.state ~= "playing" then
    if Board.hoverTag1 ~= 0 then Board.setHover(-1, -1) end
    return
  end
  local b = _G.BLOCKAI.Hud.boardRect()
  if not b then return end
  local col = math.floor((x - b.x) / b.cellX)
  local row = math.floor((y - b.y) / b.cellY)
  if col < 0 or col > 9 or row < 0 or row > 19 then
    if Board.hoverTag1 ~= 0 then Board.setHover(-1, -1) end
    return
  end
  Board.setHover(col, row)
  -- 拖擦: LMB按住期间鼠标经过的格子全部消除(同格去重, 空格clickCell
  -- 幂等no-op; 整行清空→行消除加分与单点点击同链路)
  if S.erasing and (col ~= S.lastErCol or row ~= S.lastErRow) then
    S.lastErCol, S.lastErRow = col, row
    clickCell(col, row)
  end
end

-- ── capture矩形(#10830) ──────────────────────────────────────────────────
-- 棋盘屏幕矩形(宿主capture消费/匹配的作用域): 图未就绪→零矩形(全不命中,
-- 就绪后tick同步修正); 有图→{x,y,w,h}(20行×10列, cellX/cellY各向异性)。
local function boardCapRect()
  local b = _G.BLOCKAI.Hud.boardRect()
  if not b then return 0, 0, 0, 0 end
  return b.x, b.y, b.cellX * 10, b.cellY * 20
end

-- 棋盘矩形跟随图片(平移/缩放/换图都会移动棋盘锚定矩形): 每tick比对,
-- 变化才events.set_rect推送(订阅不变零重订阅; 宿主侧快照即时生效)。
syncCapRect = function()
  if not S.mouseSub then return end
  local x, y, w, h = boardCapRect()
  local r = S.capRect
  if r and r.x == x and r.y == y and r.w == w and r.h == h then return end
  if fcc.events.set_rect(S.mouseSub, x, y, w, h) then
    S.capRect = { x = x, y = y, w = w, h = h }
  end
end

-- 输入/事件订阅(幂等: 先off旧再on新; start与热重载代际交接共用)
-- 去键盘#2077: 只订阅tick+鼠标+shader事件(游戏输入=鼠标点击消除)
local function subscribeInputs()
  if S.tickSub then fcc.events.off(S.tickSub) S.tickSub = nil end
  if S.mouseSub then fcc.events.off(S.mouseSub) S.mouseSub = nil end
  if S.hoverSub then fcc.events.off(S.hoverSub) S.hoverSub = nil end
  if S.shaderEvSub then fcc.events.off(S.shaderEvSub) S.shaderEvSub = nil end
  if S.shaderEvSub2 then fcc.events.off(S.shaderEvSub2) S.shaderEvSub2 = nil end
  S.tickSub = fcc.events.on("tick", tickHandler, { hz = 60 })
  -- 鼠标左键独占capture(风主#2077+#10830): capture作用矩形=棋盘屏幕矩形 —
  -- 仅棋盘内消费LMB(禁宿主拖图/双击全屏), 棋盘外LMB完全归还宿主(拖图/
  -- 双击全屏照常); ImGui面板输入不经此链路不受影响。按住拖擦:
  -- mouseHandler收棋盘内down+全部up, hoverHandler收move+棋盘外down兜底。
  local rx, ry, rw, rh = boardCapRect()
  S.mouseSub = fcc.events.on("mouse", mouseHandler,
                             { buttons = { 0 }, capture = true,
                               rect = { x = rx, y = ry, w = rw, h = rh } })
  S.capRect = { x = rx, y = ry, w = rw, h = rh }
  -- 悬停跟踪订阅(风主#9624, 非capture=宿主鼠标行为零影响): move→颤动
  -- + #10830拖擦(move逐格消除/棋盘外down兜底/up双保险)
  S.hoverSub = fcc.events.on("mouse", hoverHandler, { move = true })
  -- shader就绪事件驱动(#2077): 编译完成/重载完成→尝试2D→3D升级(1s节流)
  local onShaderEv = function()
    if _G.__BLOCKAI_GEN ~= gen or not S.active or not S.shaderPending then
      return
    end
    if S.now < (S.shaderTryAt or 0) + 1 then return end
    S.shaderTryAt = S.now
    tryUpgrade3D()
  end
  S.shaderEvSub = fcc.events.on("shader_compiled", onShaderEv)
  S.shaderEvSub2 = fcc.events.on("hot_reload", onShaderEv)
end

-- ── 生命周期 ──────────────────────────────────────────────────────────────
-- Shader/粒子就绪→2D兜底升级3D(#2077): 事件驱动(shader_compiled/hot_reload)
-- +tick节流重试双通道; ensureType全链成功才切换(部分就绪=下次再试)
tryUpgrade3D = function()
  if not S.shaderPending or not S.active then return end
  if not Board.ensureType() then return end
  if not Board.ensureFish() then return end
  if not Board.refreshGeometry() then return end
  Board.setShaderInjects()
  S.shaderPending = false
  S.renderMode = 0
  Board.visible3d = true
  S.geoKey = Board.visGeo and Board.visGeo.geoKey
  S.injectVerifyAt = S.now + 3
  S.injectSecondCheck = nil
  print("[block-ai] Shader就绪 → 2D切换3D渲染")
end

function _G.BLOCKAI.start()
  if S.active then return { ok = true, note = "already running" } end
  S.active = true
  S.autoClear = 1   -- 会话开始AI速度重置(风主#9616): 与新局同源, 从1爬升
  S.aiWon = false   -- 胜利定格复位(风主#9622): 新会话从零开始
  _G.__BLOCKAI_WAS_ACTIVE = true
  S.now = fcc.ui_get_time and fcc.ui_get_time() or os.clock()
  if not Board.ensureType() then
    -- 粒子/Shader未就绪(#2077): 2D兜底立即开玩, shader就绪自动切3D
    S.renderMode = 1
    Board.visible3d = false
    S.shaderPending = true
    S.shaderTryAt = S.now
    S.pendingStart = false
    S.game = Game.new()
    S.game:tick({ start = true })
    consumeEvents(S.game)
    print("[block-ai] Shader未就绪 → 2D兜底模式开局(就绪自动切3D)")
  else
    Board.ensureFish()
    Board.refreshGeometry()
    Board.setShaderInjects()   -- CS特效重力随当帧cell
    S.pendingStart = true
  end
  subscribeInputs()
  print("[block-ai] 会话开始 (" ..
        (S.shaderPending and "2D兜底, 等Shader就绪..." or "等待网格就绪...") .. ")")
  return { ok = true }
end

function _G.BLOCKAI.stop()
  if not S.active then return { ok = true, note = "not running" } end
  S.active = false
  _G.__BLOCKAI_WAS_ACTIVE = false
  S.game = nil
  S.auto = nil
  S.shaderPending = false
  S.erasing = false         -- #10830: 订阅已摘, 拖擦态复位
  S.capRect = nil
  if S.tickSub then fcc.events.off(S.tickSub) S.tickSub = nil end
  if S.mouseSub then fcc.events.off(S.mouseSub) S.mouseSub = nil end
  Board.killAll()
  Board.clearPbrInject()
  Board.removeOwnFish()
  Audio.shutdown()
  print("[block-ai] 会话结束")
  return { ok = true }
end

-- ── RPC域 block-ai(Lua与debug-server同源) ─────────────────────────────────
local function dumpState()
  local g = S.game
  local board = nil
  if g then
    -- seqlock一致读(与逻辑线程并发防护)
    local rows = g:boardSnapshot()
    if rows then
      board = {}
      for r = 1, 20 do
        local row = {}
        for c = 1, 10 do
          local v = rows[r][c]
          row[c] = v and (v % 8) or -1   -- %8解包type(组id高位不显示)
        end
        board[r] = table.concat(row, ",")
      end
    end
  end
  return {
    ok = true, active = S.active,
    state = g and g.state or "stopped",
    score = g and g.score or 0,
    lines = g and g.lines or 0,
    speed = g and g.framesPerStep or 0,
    -- level与升级门槛min(5*2^n,50)同源(game.level; 旧代际热重载兜底旧算法)
    level = g and (g.level or (math.floor(g.lines / 5) + 1)) or 0,
    piece = g and g.active and {
      type = g.active.type, rot = g.active.rot,
      x = g.active.x, y = g.active.y,
      seq = g.active.seq } or nil,
    bag = g and { unpack(g.bag, 1, math.min(#g.bag, 7)) } or nil,
    next3 = g and g.bag and #g.bag >= 3 and {
      g.bag[#g.bag], g.bag[#g.bag - 1], g.bag[#g.bag - 2] } or nil,
    material = S.matId, effect = S.fxId, effectAuto = S.fxAuto,
    renderMode = S.renderMode,
    autoClear = S.autoClear,
    particles = (Board.typeId and 1 or 0)
                + (Board.slotTypeId and 2 or 0),
    geo = Board.visGeo and { cell = Board.visGeo.cell,
                             z = Board.visGeo.z } or nil,
    typeId = Board.typeId,
    slotTypeId = Board.slotTypeId,
    bioCell = Board.bio and { Board.bio.cellX, Board.bio.cellY,
                              Board.bio.cellZ } or nil,
    board = board,
    gen = gen,
  }
end

local function rpcHandler(op, args)
  args = args or {}
  if op == "ping" then return { ok = true, pong = true }
  elseif op == "state" then return dumpState()
  elseif op == "start" then return _G.BLOCKAI.start()
  elseif op == "stop" then return _G.BLOCKAI.stop()
  elseif op == "restart" then
    if S.active then
      S.requestRestart = true
      return { ok = true }
    end
    return _G.BLOCKAI.start()
  elseif op == "pause" then
    if S.game and S.game.state == "playing" then
      S.requestPause = true return { ok = true }
    end
    return { ok = false, error = "not playing" }
  elseif op == "resume" then
    if S.game and S.game.state == "paused" then
      S.requestResume = true return { ok = true }
    end
    return { ok = false, error = "not paused" }
  elseif op == "autopilot" then
    -- {steps=600} — 自动驾驶N步(简单启发式; 测试消行链路)
    if not S.active then return { ok = false, error = "not active" } end
    S.auto = { steps = args.steps or 600, t = 0 }
    return { ok = true, steps = S.auto.steps }
  elseif op == "click" then
    -- {col,row}(0基) — 点击消除(与真实鼠标同链路; 自动化测试/AI代理
    -- 经RPC即可扮演"鼠标玩家"对抗AI)
    local c = math.floor(tonumber(args.col) or -1)
    local r = math.floor(tonumber(args.row) or -1)
    if c < 0 or c > 9 or r < 0 or r > 19 then
      return { ok = false, error = "col/row out of range (0-9/0-19)" }
    end
    return clickCell(c, r)
  elseif op == "reseed_material" then
    -- 图案随机重摇(显式可选; 默认不动已认可外观): 木纹/糖霜/拉丝
    -- 整板重新随机 — VS注入vSeed混入varParams user通道, 零重编译
    local B = _G.BLOCKAI.Board
    B.reseedMat()
    return { ok = true }
  elseif op == "force_effect" then
    -- 强制下一次消除用指定特效(0..4, 5=随机)
    S.fxId = math.max(0, math.min(5, args.id or 0))
    S.fxAuto = false
    return { ok = true, effect = S.fxId }
  elseif op == "set_effect" then
    S.fxId = math.max(0, math.min(5, args.id or 0))
    S.fxAuto = args.auto == true
    return { ok = true, effect = S.fxId, auto = S.fxAuto }
  elseif op == "set_material" then
    -- 快照variant直接生效(数组直驱, 下tick快照用新材质; 无需换血)
    -- 0-3材质 / 4=随机材质(per格hash)
    S.matId = math.max(0, math.min(4, args.id or 0))
    return { ok = true, material = S.matId }
  elseif op == "set_render_mode" then
    -- 渲染模式: 0=3D mesh粒子(默认) 1=2D屏幕层(备选)
    local m = math.max(0, math.min(1, args.id or 0))
    if S.active then
      S.requestRenderMode = m
      return { ok = true, renderMode = m, pending = true }
    end
    S.renderMode = m
    Board.visible3d = (m == 0)
    return { ok = true, renderMode = m }
  elseif op == "set_auto_clear" then
    -- 自动消除: 整数1~10行/秒(10=不限速; 对抗模式AI恒玩无off, 风主#2077)
    S.autoClear = math.max(1, math.min(10, math.floor(
        tonumber(args.value) or 1)))
    S.acAcc = 0
    return { ok = true, autoClear = S.autoClear }
  elseif op == "set_volume" then
    -- {sfx=0..1, bgm=0..1} — 音效/音乐音量独立(风主#9605; master为旧别名)
    local ms = tonumber(args.sfx) or tonumber(args.master)
    if type(ms) == "number" then
      S.volSfx = math.max(0.0, math.min(1.0, ms))
    end
    if type(args.bgm) == "number" then
      S.volBgm = math.max(0.0, math.min(1.0, args.bgm))
      if Audio.bgmId then
        Audio.applyVolume(S.volBgm)
      elseif not Audio.musicOn and S.volBgm > 0.001 then
        Audio.musicOn = true     -- 与HUD音乐滑条同语义: >0=开乐
        Audio.startBgm(S.volBgm)
      end
    end
    return { ok = true, sfx = S.volSfx, bgm = S.volBgm }
  elseif op == "debug_dump" then
    local d = dumpState()
    d.subs = { tick = S.tickSub, mouse = S.mouseSub }
    d.audio = { bgm = Audio.bgmId, sfx = Audio.sfxOn,
                music = Audio.musicOn,
                volSfx = S.volSfx, volBgm = S.volBgm }
    d.visible3d = Board.visible3d
    d.pbrOk = Board.pbrOk
    d.texSlots = Board.texSlots
    d.fxTypeId = Board.fxTypeId
    d.snap = Board.statSnap
    d.pendingFx = #(Board.pendingFx or {})
  d.tickErr = S.tickErr
  d.botErr = S.botErr
  d.now = S.now
  return d
  end
  return { ok = false, error = "block-ai: unknown op '" .. tostring(op) .. "'" }
end

-- ── 注册: 菜单 / --run / RPC域 / on_render ───────────────────────────────
if _G.__BLOCKAI_GEN == gen then
  local function try(label, fn)
    local ok, err = pcall(fn)
    if not ok then
      print("[block-ai] 注册失败 " .. label .. ": " .. tostring(err))
    end
    return ok
  end
  try("menu", function()
    fcc.register_menu_item("扩展/方块对抗", function()
      if S.active then _G.BLOCKAI.stop() else _G.BLOCKAI.start() end
    end)
  end)
  try("run", function()
    local function runEntry()
      local r = _G.BLOCKAI.start()
      return { ok = r.ok, started = r.ok }
    end
    fcc.register_run("block-ai", runEntry)
  end)
  try("rpc", function()
    fcc.rpc_register("block-ai", rpcHandler)
  end)
  -- 安装期预编译协作(#2235): 宿主gen进程(--gen-shader-cache, 安装器/build.bat
  -- 调用)在lua boot完成后广播'shader_precompile'(运行期无人发射=本订阅静默)。
  -- 激活型扩展的注入只在交互时提交 → 安装缓存从未包含 → 首次激活现场冷编
  -- 粒子组注入版(实测8个shader, 用户报告#10501)。此处提交激活期注入:
  -- 注册类型/纹理/mesh(ensureType幂等)后setShaderInjects — 不启动游戏逻辑;
  -- gen收敛泵等注入代数静默后编译入缓存, 首次激活零编译。
  try("precompile", function()
    fcc.events.on("shader_precompile", function()
      if _G.__BLOCKAI_GEN ~= gen then return end   -- 热重载旧代际不自投
      local ok, err = pcall(Board.ensureType)
      if not ok then
        print("[block-ai] precompile: " .. tostring(err))
      end
    end)
  end)
  -- 热重载代际交接(风主#2077): 继承的活跃会话重订阅输入/事件
  -- (旧代订阅已自杀; 游戏局/设置经S表继承无缝继续)
  if S.active and S.game then
    subscribeInputs()
    -- 代际交接预刷新Board资源(风主#9621): 热重载即时刷新resGen等
    -- 资源代际标记, 用户点[重新开始]走快速路径 — 否则resGen失效走
    -- pendingStart分步重建(0.5s节流×3步+粒子重编译)=UI和方块消失几秒
    local okR1 = pcall(function()
      if Board.ensureFish() and Board.refreshGeometry()
         and Board.ensureType() then
        print("[block-ai] 代际交接: Board资源预刷新完成")
      end
    end)
    if not okR1 then print("[block-ai] 代际交接资源预刷新失败(重开走重建)") end
    print("[block-ai] 热重载代际交接: 会话继续 (score=" ..
          tostring(S.game.score) .. ")")
  end

  S.renderSub = fcc.on_render(function()
    if _G.__BLOCKAI_GEN ~= gen then return end
    if not S.active and not S.game then return end
    local ok, err = pcall(Hud.draw, S)
    if not ok then print("[block-ai] hud error: " .. tostring(err)) end
  end)
end

-- autopilot: 2-ply前瞻评估(#9457: next队列全考虑) + 计划执行
-- 评估: Dellacherie六特征(landing/eroded/rowT/colT/holes/wells) —
-- 天然摊平布局(colTrans惩罚塔缘), 经典权重百万行级;
-- 前瞻: 当前块全候选可达过滤取top8 → 模拟盖章 → next1贪心最优
-- 的落定板分 → 同深度终局板分比较取全局最优落点。
local SH_T = _G.BLOCKAI.Game.SHAPES
local BW, BH = 10, 20

-- 盖章指定placement并返回消行后的grid + Dellacherie特征分
-- (cells/x/y=placement; 返回nil=放不进)
-- 落点=硬降物理(#2104根因修复): 从顶部直落, 停在第一个障碍上 —
-- 与game.lua硬降/ghostY完全同构。旧"从底向上找可塞位置"允许块穿越
-- 障碍放进被遮挡谷底, 评估器以为能填谷(高分), 实际浮空停在突出物上
-- =洞=盘面污染=连续犯错死亡螺旋的根中之根。
local function placeEval(grid, typ, x, rot)
  local cells = SH_T[typ][rot + 1]
  local y = -2
  -- 顶部spawn位即碰撞=放不进
  for i = 1, 4 do
    local cx, cy = x + cells[i][1], y + cells[i][2]
    if cx < 0 or cx >= BW or cy >= BH
       or (cy >= 0 and grid[cy + 1][cx + 1]) then
      return nil
    end
  end
  -- 直落到第一个被挡位置(y+1碰撞 → y即落点)
  while true do
    local ov = false
    for i = 1, 4 do
      local cx, cy = x + cells[i][1], y + 1 + cells[i][2]
      if cx < 0 or cx >= BW or cy >= BH
         or (cy >= 0 and grid[cy + 1][cx + 1]) then
        ov = true; break
      end
    end
    if ov then break end
    y = y + 1
  end
  -- landingHeight: 块重心离底高度(底=0, 顶部悬挂=高惩罚)
  local cySum = 0
  for i = 1, 4 do cySum = cySum + y + cells[i][2] end
  local landing = (BH - 1) - cySum / 4
  -- 盖章(手写行复制: unpack是LuaJIT NYI解释执行 — AI速度10时规划53ms
  -- 挤爆worker→渲染线程6ms抢锁失败跳帧=UI面板闪烁的元凶)
  local g2 = {}
  for r = 1, BH do
    local src, dst = grid[r], {}
    for c = 1, BW do dst[c] = src[c] end
    g2[r] = dst
  end
  for i = 1, 4 do
    local cx, cy = x + cells[i][1], y + cells[i][2]
    if cy < 0 then return nil end
    g2[cy + 1][cx + 1] = true
  end
  -- 满行检测(一次扫描同时供eroded统计与消行重建, 原两次全板扫描去重)
  local fullRows, nFull = {}, 0
  for r = 1, BH do
    local full = true
    local row = g2[r]
    for c = 1, BW do if not row[c] then full = false break end end
    if full then nFull = nFull + 1 fullRows[nFull] = r end
  end
  local eroded = 0
  if nFull > 0 then
    -- eroded = 消行数 × 块在满行中的格数
    local pieceInFull = 0
    for fi = 1, nFull do
      local fr = fullRows[fi]
      for i = 1, 4 do
        if (y + cells[i][2]) + 1 == fr then pieceInFull = pieceInFull + 1 end
      end
    end
    eroded = nFull * pieceInFull
    -- 消行(重建法: 上方行下移, 顶部补空)
    local out = {}
    for r = 1, BH do
      local isFull = false
      for fi = 1, nFull do if fullRows[fi] == r then isFull = true break end end
      if not isFull then out[#out + 1] = g2[r] end
    end
    for i = 1, nFull do
      local row = {}
      for c = 1, BW do row[c] = false end
      table.insert(out, 1, row)
    end
    for r = 1, BH do g2[r] = out[r] end
  end
  -- rowTransitions(含左右墙=满)
  local rowT = 0
  for r = 1, BH do
    local prev = 1
    for c = 1, BW do
      local cur = g2[r][c] and 1 or 0
      if cur ~= prev then rowT = rowT + 1 end
      prev = cur
    end
    if prev == 0 then rowT = rowT + 1 end
  end
  -- colTransitions(顶墙=空, 底墙=满) + holes + cumulativeWells
  local colT, holes, wells = 0, 0, 0
  for c = 1, BW do
    local prev = 0
    for r = 1, BH do
      local cur = g2[r][c] and 1 or 0
      if cur ~= prev then colT = colT + 1 end
      prev = cur
    end
    if prev == 0 then colT = colT + 1 end
    -- holes: 列内最高块下方的空格
    local seen = false
    for r = 1, BH do
      if g2[r][c] then seen = true
      elseif seen then holes = holes + 1 end
    end
    -- wells: 两侧为满(或墙)的连续空格井深累积 d*(d+1)/2
    local run = 0
    for r = 1, BH do
      if not g2[r][c] then
        local lFull = (c == 1) or g2[r][c - 1]
        local rFull = (c == BW) or g2[r][c + 1]
        if lFull and rFull then run = run + 1
        elseif run > 0 then wells = wells + run * (run + 1) / 2; run = 0
        else run = 0 end
      elseif run > 0 then
        wells = wells + run * (run + 1) / 2; run = 0
      end
    end
    if run > 0 then wells = wells + run * (run + 1) / 2 end
  end
  -- Dellacherie经典权重(相对比例是关键: colT/holes惩罚远重于landing)
  local score = -4.500158825082766 * landing + 3.4181268101392694 * eroded
                - 3.2178882868487753 * rowT - 9.348695305445199 * colT
                - 7.899265427351652 * holes - 3.3855972247263626 * wells
  -- 额外返回landing/eroded分项: 2-ply需把"当前块"的过程奖励
  -- (landing惩罚/eroded消行奖励)叠加到深态终局板分上, 否则当前块
  -- 高放与不消行无代价(实测17次GO/100s灾难性劣化)
  return score, g2, landing, eroded
end

-- 1-ply: typ块在grid上的最优落点
-- opts.all=true返回全部{score,x,rot}(降序); 否则返回最优{score,x,rot,grid}
local function bestOn(grid, typ, opts)
  local best, bestScore, list = nil, -1e9, opts and opts.all and {} or nil
  for rot = 0, 3 do
    for x = -2, BW - 1 do
      local score, g2 = placeEval(grid, typ, x, rot)
      if score then
        if list then
          list[#list + 1] = { score = score, x = x, rot = rot }
        elseif score > bestScore then
          bestScore = score
          best = { score = score, x = x, rot = rot, grid = g2 }
        end
      end
    end
  end
  if list then
    table.sort(list, function(a, b) return a.score > b.score end)
    return list
  end
  return best
end

-- 水平+下落可达列集合(标准方块游戏可达性近似): 从(x0,y0)出发
-- 每步{左,右,下}BFS, 返回{[可着陆锚x]=着陆y} — 规划只选可达落点。
-- 锚x范围[-3,12]按块cells实际占用列判界(overlap含越界检查),
-- I竖直等锚x=-2(实际列0)是合法贴墙落点, 不能按锚≥0截断。
local function reachableCols(g, ty, rot, x0, y0)
  local ov = Game._overlap
  local seen = { [x0 * 32 + y0] = true }
  local lands = {}
  local stack = { { x0, y0 } }
  while #stack > 0 do
    local cur = table.remove(stack)
    local x, y = cur[1], cur[2]
    for _, nx in ipairs({ x - 1, x + 1 }) do
      local key = nx * 32 + y
      if nx >= -3 and nx <= 12 and not seen[key]
         and not ov(g, ty, rot, nx, y) then
        seen[key] = true
        stack[#stack + 1] = { nx, y }
      end
    end
    if ov(g, ty, rot, x, y + 1) then
      lands[x] = y
    else
      local key = x * 32 + y + 1
      if not seen[key] then
        seen[key] = true
        stack[#stack + 1] = { x, y + 1 }
      end
    end
  end
  return lands
end

-- 2-ply规划(默认, Yiyuan Lee规范法): 全候选→可达性过滤→top8盖章→
-- 每个盖章板g1上用下一块n1=bag[#bag]贪心bestOn取"落定板分"→
-- 统一在"两块都放完"的终局板上比较 — Dellacherie分是板质量绝对值,
-- 同深度比较杜绝旧跨深度混权(s1*0.55+s2*0.45)的基线漂移;
-- 无next时退化1-ply; _G.__PLAN_1PLY=true可回退纯1-ply对照。
local function planLookahead(g)
  local a = g.active
  local PD = _G.__PLAN_DIAG
  local n1 = g.bag[#g.bag]
  local cands = bestOn(g.board, a.type, { all = true })
  if not cands or #cands == 0 then return { x = 3, rot = 0 } end
  -- 可达性过滤(每rot一次BFS; 旋转踢墙近似为原x, rotFails机制兜底);
  -- rankMap[过滤后序]=原始1-ply名次(诊断用); 全不可达(极端)回退全候选
  local landsByRot = {}
  local okC, rankMap = {}, {}
  for i, c in ipairs(cands) do
    local lands = landsByRot[c.rot]
    if not lands then
      lands = reachableCols(g, a.type, c.rot, a.x, a.y)
      landsByRot[c.rot] = lands
    end
    if lands[c.x] then
      rankMap[#okC + 1] = i
      okC[#okC + 1] = c
    end
  end
  if #okC > 0 then cands = okC else rankMap = nil end
  -- top8盖章+深态终局板分; 并列分取更居中候选(防对称分恒选最左缘)
  local best, bestTotal, bestIdx = nil, -1e9, 0
  if _G.__PLAN_1PLY then bestIdx = 1 end
  for i = 1, (_G.__PLAN_1PLY and 1 or math.min(8, #cands)) do
    local c1 = cands[i]
    local s1, g1, L1, E1 = placeEval(g.board, a.type, c1.x, c1.rot)
    if g1 then
      local s2 = s1   -- 无next时退化1-ply
      if n1 ~= nil and not _G.__PLAN_1PLY then
        local b2 = bestOn(g1, n1)
        if b2 then
          -- 深态终局板分(b2.score=n1过程奖励+终局板特征) + 当前块
          -- 过程奖励(landing惩罚/eroded消行奖励) — 缺后者则当前块
          -- 高放/不消行无代价, 死亡螺旋反而加剧
          s2 = b2.score + (-4.500158825082766 * L1
                           + 3.4181268101392694 * E1)
        end
      end
      if _G.__PLAN_DBG then
        _G.__PLAN_DBG[#_G.__PLAN_DBG + 1] = string.format(
          "c%d(x%d,r%d) s1=%.2f deep=%.2f", i, c1.x, c1.rot, s1, s2)
      end
      if s2 > bestTotal + 0.01
         or (best and math.abs(s2 - bestTotal) <= 0.01
             and math.abs(c1.x - 4.5) < math.abs(best.x - 4.5)) then
        bestTotal = s2
        best = { x = c1.x, rot = c1.rot }
        bestIdx = i
      end
    end
  end
  if PD then
    PD.n = PD.n + 1
    if #okC == 0 or bestIdx == 0 then PD.fb = PD.fb + 1 else PD.ok = PD.ok + 1 end
    if PD.n <= PD.cap or PD.cap == nil then
      local c1 = cands[1]
      local rank = bestIdx > 0 and rankMap and rankMap[bestIdx] or bestIdx
      PD.picks[#PD.picks + 1] = string.format(
        "s%d t%d@(%d,%d,r%d) nc=%d rank=%d pick=(x%d,r%d,%.1f) top=(x%d,r%d,%.1f)",
        a.seq, a.type, a.x, a.y, a.rot, #cands, rank,
        best and best.x or 3, best and best.rot or 0, bestTotal,
        c1 and c1.x or -9, c1 and c1.rot or -9, c1 and c1.score or 0)
    end
  end
  return best or cands[1]
end


_G.BLOCKAI_DBG = {
  state = dumpState,
  start = function() return _G.BLOCKAI.start() end,
  stop = function() return _G.BLOCKAI.stop() end,
  rpc = rpcHandler,
  best = function() return planLookahead(S.game) end,
  placeEval = placeEval,   -- 诊断导出: 逐分比对/外部验证
  bestOn = bestOn,
  autopilotStep = function(a)
    -- 新块2-ply规划(可达过滤)→旋转到位→恒定方向横移
    -- (被挡则等待自然下落换层, 无逐tick路径重算=无震荡)→到位硬降;
    -- 滞留兜底: 当前形状可达列内重锁一次, 再滞留硬降。
    local g = S.game
    if not g then return nil end
    -- gameover不自动续局(风主#9613): 旧start分支已移除, 由玩家点重新开始
    if g.state ~= "playing" or not g.active then return nil end
    if a.steps <= 0 then return nil end
    a.steps = a.steps - 1
    local p = g.active

    if a.seq ~= p.seq or a.bSeq ~= g.boardSeq then
      -- 新块 或 盘面被鼠标点击消除改动 → 立即重规划
      -- (风主#2077: 自动消除AI必须感知玩家点击消除后的盘面)
      a.seq = p.seq
      a.bSeq = g.boardSeq
      a.plan = planLookahead(g)
      a.stuck = 0
      a.relocked = false
    end
    local pl = a.plan
    a.stuck = (a.stuck or 0) + 1
    if a.stuck > 24 then
      if not a.relocked then
        -- 可达列内重锁: 规划目标被堵(绕行死胡同等)时按当前形状
        -- 在真正可达的列里选最佳, 断开"朝不可达目标横跳到耗尽"
        a.relocked = true
        local lands = reachableCols(g, p.type, p.rot, p.x, p.y)
        local bestC, bestS = { x = p.x, rot = p.rot }, -1e9
        for x, _ in pairs(lands) do
          local s = placeEval(g.board, p.type, x, p.rot)
          if s and s > bestS then

            bestS = s
            bestC = { x = x, rot = p.rot }
          end
        end
        a.plan = bestC
        a.stuck = 0
      else
        return { hard = true }
      end
    end

    if p.rot ~= pl.rot then
      local dcw = (p.rot - pl.rot) % 4
      local inp = {}
      if dcw > 2 then inp.rot_ccw = true else inp.rot_cw = true end
      return inp
    end
    if p.x ~= pl.x then
      local inp = {}
      if p.x > pl.x then inp.left = true else inp.right = true end
      return inp
    end
    return { hard = true }
  end,
}
print("[block-ai] 方块对抗扩展已加载 (gen=" .. gen ..
      ") — 菜单: 扩展/方块对抗 | --run block-ai | RPC block-ai.*" ..
      "  玩法: AI自动消除 对抗 鼠标点击消除(1~10可调)")
-- 热重载会话延续: 上一代际在游戏中 → 自动重开(宿主hot-reload整包重跑)
if _G.__BLOCKAI_WAS_ACTIVE then
  _G.__BLOCKAI_WAS_ACTIVE = false
  _G.BLOCKAI.start()
end
return true
