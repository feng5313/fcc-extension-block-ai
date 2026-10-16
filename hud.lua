-- ============================================================================
-- hud.lua — HUD层(屏幕绘制队列 + ImGui面板)
-- 默认(3D模式): 方块/ghost/特效=board.lua mesh粒子管线, 本层只画空格标记;
-- 2D备选(renderMode=1): 可见方块/ghost/消除特效=本层fcc.draw_rect屏幕层绘制。
-- 信息面板: 得分/队列/渲染/材质/特效/音量/按钮。
-- ============================================================================
-- 原地刷新模块(热重载协议)
_G.BLOCKAI = _G.BLOCKAI or {}
local Hud = _G.BLOCKAI.Hud
if not Hud then Hud = {}; _G.BLOCKAI.Hud = Hud end

-- ── i18n(风主#9586): 所有UI文字经fcc.tr翻译 ──────────────────────────────
-- key=中文(即fallback), 注册5语言; combo串显示时按\0拆分逐项tr再重组。
-- 菜单项label由宿主settings_ui _()翻译(与本词典同源, 见explorer.lua)。
-- 注: en渲染词避免"3D/2D"拉丁字形(窗体字体缺字), 用Solid/Flat。
local function regI18n()
  local langs = {
    en_US = {
      ["方块对抗"] = "Block Battle",
      ["AI 对抗 鼠标点击"] = "AI vs Mouse Click",
      ["玩法(无键盘):"] = "How to play (no keyboard):",
      ["AI自动消除 -- 落块消行(1~10可调)"] = "AI auto-clear — drop & clear lines (1-10)",
      ["鼠标左键点击 -- 消除单个方块"] = "Left click — remove one block",
      ["点击一行最后一块 -- 整行消除+加分"] = "Click a row's last block — clear row + bonus",
      ["开始游戏..."] = "Starting...",
      ["行数"] = "Lines",
      ["得分"] = "Score",
      ["渲染"] = "Render",
      ["材质"] = "Material",
      ["消除特效"] = "Clear FX",
      ["总音量"] = "Master Vol",   -- 已弃用(风主#9605改音效)
      ["音效"] = "SFX Vol",
      ["音乐"] = "Music",
      ["AI速度"] = "AI Speed",
      ["立体"] = "Solid",
      ["平面"] = "Flat",
      ["积木"] = "Blocks",
      ["玻璃"] = "Glass",
      ["软糖"] = "Gummy",
      ["金属"] = "Metal",
      ["随机"] = "Random",
      ["融化"] = "Melt",
      ["爆炸"] = "Explode",
      ["缩小"] = "Shrink",
      ["透明"] = "Fade",
      ["雾化"] = "Mist",
      ["暂停"] = "Pause",
      ["继续游戏"] = "Resume",
      ["重新开始"] = "Restart",
      ["退出"] = "Quit",
      ["—— 游戏暂停 ——"] = "—— Paused ——",   -- 已弃用(风主#9622删显示)
      ["游戏结束!  最终得分 "] = "Game Over!  Final Score ",
      ["点击重新开始"] = "Click Restart",
      ["AI胜利！"] = "AI Wins!",
      ["你胜利了！"] = "You Win!",
    },
    ja_JP = {
      ["方块对抗"] = "ブロック対決",
      ["AI 对抗 鼠标点击"] = "AI 対 マウスクリック",
      ["玩法(无键盘):"] = "遊び方（キーボード不要）:",
      ["AI自动消除 -- 落块消行(1~10可调)"] = "AI自動消去 -- 落下と行消去（1~10調整可）",
      ["鼠标左键点击 -- 消除单个方块"] = "左クリック -- ブロックを1個消去",
      ["点击一行最后一块 -- 整行消除+加分"] = "行の最後のブロックで行消去+ボーナス",
      ["开始游戏..."] = "開始中...",
      ["行数"] = "行数",
      ["得分"] = "スコア",
      ["渲染"] = "描画",
      ["材质"] = "素材",
      ["消除特效"] = "消去演出",
      ["总音量"] = "音量",   -- 已弃用(#9605)
      ["音效"] = "効果音",
      ["音乐"] = "音楽",
      ["AI速度"] = "AI速度",
      ["立体"] = "立体",
      ["平面"] = "平面",
      ["积木"] = "ブロック",
      ["玻璃"] = "ガラス",
      ["软糖"] = "グミ",
      ["金属"] = "メタル",
      ["随机"] = "ランダム",
      ["融化"] = "融解",
      ["爆炸"] = "爆発",
      ["缩小"] = "縮小",
      ["透明"] = "透明化",
      ["雾化"] = "霧散",
      ["暂停"] = "一時停止",
      ["继续游戏"] = "再開",
      ["重新开始"] = "再スタート",
      ["退出"] = "終了",
      ["—— 游戏暂停 ——"] = "—— 一時停止 ——",
      ["游戏结束!  最终得分 "] = "ゲームオーバー!  最終スコア ",
      ["点击重新开始"] = "再スタートをクリック",
      ["AI胜利！"] = "AI の勝ち！",
      ["你胜利了！"] = "あなたの勝ち！",
    },
    fr_FR = {
      ["方块对抗"] = "Bataille de blocs",
      ["AI 对抗 鼠标点击"] = "IA contre clic de souris",
      ["玩法(无键盘):"] = "Comment jouer (sans clavier) :",
      ["AI自动消除 -- 落块消行(1~10可调)"] = "Auto-effacement IA — chute et lignes (1-10)",
      ["鼠标左键点击 -- 消除单个方块"] = "Clic gauche — supprime un bloc",
      ["点击一行最后一块 -- 整行消除+加分"] = "Dernier bloc d'une ligne — ligne complète + bonus",
      ["开始游戏..."] = "Démarrage...",
      ["行数"] = "Lignes",
      ["得分"] = "Score",
      ["渲染"] = "Rendu",
      ["材质"] = "Matériau",
      ["消除特效"] = "Effets",
      ["总音量"] = "Volume",   -- 已弃用(#9605)
      ["音效"] = "Effets sonores",
      ["音乐"] = "Musique",
      ["AI速度"] = "Vitesse IA",
      ["立体"] = "Solide",
      ["平面"] = "Plat",
      ["积木"] = "Briques",
      ["玻璃"] = "Verre",
      ["软糖"] = "Gomme",
      ["金属"] = "Métal",
      ["随机"] = "Aléatoire",
      ["融化"] = "Fonte",
      ["爆炸"] = "Explosion",
      ["缩小"] = "Rétrécit",
      ["透明"] = "Fondu",
      ["雾化"] = "Brume",
      ["暂停"] = "Pause",
      ["继续游戏"] = "Reprendre",
      ["重新开始"] = "Recommencer",
      ["退出"] = "Quitter",
      ["—— 游戏暂停 ——"] = "—— En pause ——",
      ["游戏结束!  最终得分 "] = "Partie terminée !  Score final ",
      ["点击重新开始"] = "Cliquer pour recommencer",
      ["AI胜利！"] = "L'IA gagne !",
      ["你胜利了！"] = "Tu as gagné !",
    },
    de_DE = {
      ["方块对抗"] = "Block-Duell",
      ["AI 对抗 鼠标点击"] = "KI gegen Mausklick",
      ["玩法(无键盘):"] = "Spielweise (ohne Tastatur):",
      ["AI自动消除 -- 落块消行(1~10可调)"] = "KI-Auto-Löschen — Fallen & Linien (1-10)",
      ["鼠标左键点击 -- 消除单个方块"] = "Linksklick — entfernt einen Block",
      ["点击一行最后一块 -- 整行消除+加分"] = "Letzten Block einer Reihe — Reihe räumen + Bonus",
      ["开始游戏..."] = "Start...",
      ["行数"] = "Linien",
      ["得分"] = "Punkte",
      ["渲染"] = "Rendering",
      ["材质"] = "Material",
      ["消除特效"] = "Effekte",
      ["总音量"] = "Lautstärke",   -- 已弃用(#9605)
      ["音效"] = "Sound",   -- 避免与消除特效"Effekte"同词
      ["音乐"] = "Musik",
      ["AI速度"] = "KI-Tempo",
      ["立体"] = "Massiv",
      ["平面"] = "Flach",
      ["积木"] = "Bausteine",
      ["玻璃"] = "Glas",
      ["软糖"] = "Gummi",
      ["金属"] = "Metall",
      ["随机"] = "Zufall",
      ["融化"] = "Schmelzen",
      ["爆炸"] = "Explosion",
      ["缩小"] = "Schrumpfen",
      ["透明"] = "Verblassen",
      ["雾化"] = "Nebel",
      ["暂停"] = "Pause",
      ["继续游戏"] = "Fortsetzen",
      ["重新开始"] = "Neustart",
      ["退出"] = "Beenden",
      ["—— 游戏暂停 ——"] = "—— Pause ——",
      ["游戏结束!  最终得分 "] = "Spielende!  Endstand ",
      ["点击重新开始"] = "Neustart anklicken",
      ["AI胜利！"] = "KI gewinnt!",
      ["你胜利了！"] = "Du hast gewonnen!",
    },
    es_ES = {
      ["方块对抗"] = "Batalla de bloques",
      ["AI 对抗 鼠标点击"] = "IA contra clic del ratón",
      ["玩法(无键盘):"] = "Cómo jugar (sin teclado):",
      ["AI自动消除 -- 落块消行(1~10可调)"] = "Borrado automático IA — caída y líneas (1-10)",
      ["鼠标左键点击 -- 消除单个方块"] = "Clic izquierdo — elimina un bloque",
      ["点击一行最后一块 -- 整行消除+加分"] = "Último bloque de una fila — fila + bono",
      ["开始游戏..."] = "Iniciando...",
      ["行数"] = "Líneas",
      ["得分"] = "Puntos",
      ["渲染"] = "Render",
      ["材质"] = "Material",
      ["消除特效"] = "Efectos",
      ["总音量"] = "Volumen",   -- 已弃用(#9605)
      ["音效"] = "Sonido",
      ["音乐"] = "Música",
      ["AI速度"] = "Vel. IA",
      ["立体"] = "Sólido",
      ["平面"] = "Plano",
      ["积木"] = "Bloques",
      ["玻璃"] = "Vidrio",
      ["软糖"] = "Gominola",
      ["金属"] = "Metal",
      ["随机"] = "Aleatorio",
      ["融化"] = "Fundir",
      ["爆炸"] = "Explosión",
      ["缩小"] = "Encoger",
      ["透明"] = "Fundido",
      ["雾化"] = "Niebla",
      ["暂停"] = "Pausa",
      ["继续游戏"] = "Continuar",
      ["重新开始"] = "Reiniciar",
      ["退出"] = "Salir",
      ["—— 游戏暂停 ——"] = "—— En pausa ——",
      ["游戏结束!  最终得分 "] = "¡Fin del juego!  Puntuación ",
      ["点击重新开始"] = "Clic para reiniciar",
    },
  }
  for lang, entries in pairs(langs) do
    for key, val in pairs(entries) do
      fcc.add_translation(lang, key, val)
    end
  end
end
pcall(regI18n)

local function tr(key) return fcc.tr(key) end

-- combo串显示时翻译: "a\0b\0"→逐项tr重组(每帧成本: 几次查表)
-- 注: 拆分必须用plain find手撕 — Lua pattern引擎对字符类内NUL字节
-- 按"pattern提前终止"解析([^\0]+ → malformed pattern missing ']'),
-- combo串整体被pcall吞错=控件不渲染=空白框
local function trCombo(s)
  local out = {}
  local start, len = 1, #s
  while start <= len do
    local e = s:find("\0", start, true) or len + 1
    local w = s:sub(start, e - 1)
    if #w > 0 then out[#out + 1] = tr(w) end
    start = e + 1
  end
  return table.concat(out, "\0") .. "\0"
end

local MATS = { "积木\0玻璃\0软糖\0金属\0随机\0" }
local FXS = { "融化\0爆炸\0缩小\0透明\0雾化\0随机\0" }
-- 纯中文: 窗体字体缺部分拉丁字形("3D"的D会渲染成0)=显示错乱
local RMS = { "立体\0平面\0" }

-- 棋盘屏幕矩形(与board.visGeo同构: 20格对齐图片高, 10格宽居中)
-- DX11 ImageArea: 粒子RT宽/高独立量化(宽256px/高64px块+滞回) → RT纵横比≠
-- 图片纵横比(1920×1080图→RT2048×1088=5.6%失真), overlay各向异性拉伸RT铺满
-- 图片矩形 → 棋盘(RT域, cell_rt=imgRT.h/20)屏幕水平格宽=cellY·(iw/imgRT.w)
-- ≠ih/20; 各向同性假设让边缘列点击映射错位近一格(左缘死区/右列点中邻列)。
-- 水平格宽按RT真值修正(GL版粒子画窗口FBO 1:1无此问题; visGeo.imgRect=
-- 最终FBO量化后真值, 与3D方块锚点/物理同源); cellY恒=ih/20(垂直满铺精确)
local function boardRect()
  local okR, ix, iy, iw, ih = pcall(fcc.image_get_rect)
  if not okR or not iw or iw < 100 or ih < 100 then return nil end
  local cellY = ih / 20
  local cellX = cellY
  local vg = _G.BLOCKAI.Board and _G.BLOCKAI.Board.visGeo
  if vg and vg.imgRect and vg.imgRect[3] > 1 and vg.imgRect[4] > 1 then
    cellX = (vg.imgRect[4] / 20) * (iw / vg.imgRect[3])
  end
  return { x = ix + (iw - cellX * 10) / 2, y = iy,
           cellX = cellX, cellY = cellY, cell = cellY }
end
Hud.boardRect = boardRect   -- 暴露: main.lua鼠标点击命中检测用

-- 通道混合: m>0向白靠拢, m<0向黑靠拢
local function mix3(r, g, b, m)
  if m >= 0 then
    local u = 1 - m
    return r * u + m, g * u + m, b * u + m
  end
  local d = 1 + m
  return r * d, g * d, b * d
end

-- 单格材质绘制(屏幕层): mat 0积木/1玻璃/2软糖/3金属; shadow=下落块右下阴影
-- cw/ch=格宽/格高(RT量化纵横比修正后可互异, 水平尺寸用cw/垂直用ch)
local function drawCellMat(x, y, cw, ch, r, g, b, mat, shadow)
  local cell = math.min(cw, ch)
  local i = cell >= 12 and 1.5 or 0.5     -- 格缝(立方体感)
  local x2, y2 = x + i, y + i
  local w, h = cw - i * 2, ch - i * 2
  if shadow then
    fcc.draw_rect(x2 + 2.5, y2 + 2.5, w, h, 0, 0, 0, 0.22)
  end
  local band = math.max(2, ch * 0.22)
  if mat == 0 then          -- 积木: 底色+顶亮条+底暗条+左亮缘
    fcc.draw_rect(x2, y2, w, h, r, g, b, 0.98)
    local tr, tg, tb = mix3(r, g, b, 0.35)
    local dr, dg, db = mix3(r, g, b, -0.28)
    fcc.draw_rect(x2, y2, w, band, tr, tg, tb, 0.98)
    fcc.draw_rect(x2, y2 + h - band, w, band, dr, dg, db, 0.98)
    fcc.draw_rect(x2, y2, 2, h, tr, tg, tb, 0.95)
  elseif mat == 1 then      -- 玻璃: 半透底+白框+顶部白条
    fcc.draw_rect(x2, y2, w, h, r, g, b, 0.50)
    fcc.draw_rect(x2, y2, w, band, 1, 1, 1, 0.35)
    fcc.draw_rect(x2, y2, w, 2, 1, 1, 1, 0.80)
    fcc.draw_rect(x2, y2 + h - 2, w, 2, 1, 1, 1, 0.80)
    fcc.draw_rect(x2, y2, 2, h, 1, 1, 1, 0.80)
    fcc.draw_rect(x2 + w - 2, y2, 2, h, 1, 1, 1, 0.80)
  elseif mat == 2 then      -- 软糖: 底色+内芯发光
    fcc.draw_rect(x2, y2, w, h, r, g, b, 0.92)
    local k = ch * 0.18
    local cr, cg, cb = mix3(r, g, b, 0.30)
    fcc.draw_rect(x2 + k, y2 + k, w - k * 2, h - k * 2,
                  cr, cg, cb, 0.50)
  else                      -- 金属: 三横带+亮顶缘
    local tr, tg, tb = mix3(r, g, b, 0.45)
    local dr, dg, db = mix3(r, g, b, -0.35)
    local h3 = h / 3
    fcc.draw_rect(x2, y2, w, h3, tr, tg, tb, 0.98)
    fcc.draw_rect(x2, y2 + h3, w, h3, r, g, b, 0.98)
    fcc.draw_rect(x2, y2 + h3 * 2, w, h3, dr, dg, db, 0.98)
    fcc.draw_rect(x2, y2, w, 1, 1, 1, 1, 0.90)
  end
end

-- 棋盘层: 2D备选模式专用(3D模式棋盘格=同管线平面粒子, 零坐标系错位)
local function drawBoardLayer(game, st)
  local b = boardRect()
  if not b then return nil end
  local cellX, cellY = b.cellX, b.cellY
  -- seqlock一致读(渲染线程与逻辑线程并发, 防读到写一半数据)
  local rows = game:boardSnapshot()
  if not rows then return b end
  if st and st.renderMode ~= 1 then return b end   -- 3D模式: 方块走mesh管线
  local Board = _G.BLOCKAI.Board
  local mat = st and st.matId or 0
  -- 悬停颤动(风主#9642/#9646): 3D=VS注入v36绕块中心5Hz±8°旋转;
  -- 2D屏幕层draw_rect无旋转API → 等效反馈=绕中心缩放脉冲±1.5%@5Hz
  -- (位置不变); 点击消除两模式同链路(mouseHandler→clickCell)
  local hv = Board.hoverTag1 or 0
  local hc, hr = -1, -1
  if hv > 0 and game.state == "playing" then
    hc = (hv - 1) % 256
    hr = math.floor((hv - 1) / 256)
  end
  local tNow = st and st.now or 0
  local pulse = 1.0 + (hc >= 0 and 0.015 * math.sin(tNow * 31.4159) or 0.0)
  -- 落定块(随机材质4=按组: 同块4格同材质, Board.MAT_HASH同源)
  for r = 0, 19 do
    local row = rows[r + 1]
    for c = 0, 9 do
      local t = row[c + 1]
      if t then
        local pr, pg, pb = Board.pieceColor(t)
        local m = (mat == 4) and Board.MAT_HASH(math.floor(t / 8))
                    or mat
        local x, y = b.x + c * cellX, b.y + r * cellY
        local cw, ch = cellX, cellY
        if c == hc and r == hr then   -- 悬停格: 绕中心缩放脉冲
          local dx, dy = cw * (pulse - 1.0), ch * (pulse - 1.0)
          x, y = x - dx * 0.5, y - dy * 0.5
          cw, ch = cw * pulse, ch * pulse
        end
        drawCellMat(x, y, cw, ch, pr, pg, pb, m, false)
      end
    end
  end
  -- 下落块(带右下阴影提层次; paused冻结显示)
  if (game.state == "playing" or game.state == "paused")
     and game.active then
    local a = game.active
    local pr, pg, pb = Board.pieceColor(a.type)
    local mA = (mat == 4) and Board.MAT_HASH(a.seq or 0) or mat
    for _, c in ipairs(game:activeCells()) do
      if c[1] >= 0 and c[1] < 10 and c[2] >= 0 and c[2] < 20 then
        local x, y = b.x + c[1] * cellX, b.y + c[2] * cellY
        local cw, ch = cellX, cellY
        if c[1] == hc and c[2] == hr then
          local dx, dy = cw * (pulse - 1.0), ch * (pulse - 1.0)
          x, y = x - dx * 0.5, y - dy * 0.5
          cw, ch = cw * pulse, ch * pulse
        end
        drawCellMat(x, y, cw, ch, pr, pg, pb, mA, true)
      end
    end
  end
  return b
end

-- ghost落点(2D模式绘制; 透明度0.05, 方块色; 贴合实块时不画)
local function drawGhost(game, b, st)
  if not b or st and st.renderMode ~= 1 then return end
  if game.state ~= "playing" and game.state ~= "paused" then return end
  if not game.active then return end
  local cellX, cellY = b.cellX, b.cellY
  local a = game.active
  local gy = game:ghostY()
  if gy == a.y then return end
  local pr, pg, pb = _G.BLOCKAI.Board.pieceColor(a.type)
  for _, c in ipairs(game:activeCells(
      { type = a.type, rot = a.rot, x = a.x, y = gy })) do
    local x, y = b.x + c[1] * cellX, b.y + c[2] * cellY
    fcc.draw_rect(x, y, cellX, cellY, pr, pg, pb, 0.05)
    fcc.draw_rect(x, y, cellX, 2, pr, pg, pb, 0.05)
    fcc.draw_rect(x, y + cellY - 2, cellX, 2, pr, pg, pb, 0.05)
    fcc.draw_rect(x, y, 2, cellY, pr, pg, pb, 0.05)
    fcc.draw_rect(x + cellX - 2, y, 2, cellY, pr, pg, pb, 0.05)
  end
end

-- ── 消除特效(HUD层动画×5): 融化/爆炸/缩小/透明/雾化 ──────────────────────
-- 每格多条子动画(主体+碎屑/雾团, 各自delay/dur/方向), t0<0=首帧校时(st.now)
Hud.Fx = Hud.Fx or { list = {} }

-- cells={{col,row,typeIdx},...}(worker调用; 随机参数在此预生成)
function Hud.FxPlay(cells, fxId)
  local list = Hud.Fx.list
  local add = function(col, row, t, fx, dur, delay, dx, dy, sz, ex)
    list[#list + 1] = { col = col, row = row, t = t, fx = fx, dur = dur,
                        delay = delay or 0, dx = dx or 0, dy = dy or 0,
                        sz = sz or 1, ex = ex or 0, t0 = -1 }
  end
  for _, c in ipairs(cells) do
    local col, row, t = c[1], c[2], c[3] or 0
    if fxId == 0 then            -- 融化: 主体下沉压扁 + 2滴坠滴
      add(col, row, t, 0, 0.55)
      for k = 1, 2 do
        add(col, row, t, 0, 0.45, 0.08 * k, (math.random() - 0.5) * 0.5,
            0, 0.22 + math.random() * 0.16, 1)
      end
    elseif fxId == 1 then        -- 爆炸: 白闪核心 + 4块径向碎片
      add(col, row, t, 1, 0.30, 0, 0, 0, 1, 1)
      for _ = 1, 4 do
        local ang = math.random() * 6.28318
        add(col, row, t, 1, 0.55, 0.02, math.cos(ang), math.sin(ang),
            0.30 + math.random() * 0.28)
      end
    elseif fxId == 2 then        -- 缩小: 原位塌缩
      add(col, row, t, 2, 0.45)
    elseif fxId == 3 then        -- 透明: 增亮淡出
      add(col, row, t, 3, 0.50)
    else                         -- 雾化: 3团膨胀变白上飘
      for k = 0, 2 do
        add(col, row, t, 4, 0.60, 0.09 * k, (math.random() - 0.5) * 0.6,
            0, 0.30 + math.random() * 0.25)
      end
    end
  end
end

local function fxDraw(b, now)
  local list = Hud.Fx.list
  local Board = _G.BLOCKAI.Board
  local i = 1
  while i <= #list do
    local e = list[i]
    if e.t0 < 0 then e.t0 = now end
    local p = (now - e.t0 - e.delay) / e.dur
    if p >= 1 then
      list[i] = list[#list]
      list[#list] = nil
    elseif p < 0 then
      i = i + 1
    else
      local r, g, bl = Board.pieceColor(e.t)
      local cellX, cellY = b.cellX, b.cellY
      local cx, cy = b.x + e.col * cellX, b.y + e.row * cellY
      if e.fx == 0 then          -- 融化
        if e.ex == 0 then        -- 主体: 下沉压扁
          local w = cellX * (1 - p * 0.2)
          local h = cellY * (1 - p * 0.75)
          fcc.draw_rect(cx + (cellX - w) / 2, cy + (cellY - h), w, h,
                        r, g, bl, 0.92 * (1 - p))
        else                     -- 坠滴
          local s = cellY * e.sz * (1 - p * 0.4)
          fcc.draw_rect(cx + (cellX - s) / 2 + e.dx * p * cellX,
                        cy + cellY - 2 + p * cellY * 2.4, s, s,
                        r, g, bl, 0.85 * (1 - p))
        end
      elseif e.fx == 1 then      -- 爆炸
        if e.ex == 1 then        -- 白闪核心
          local s = cellY * (0.9 + p * 1.1)
          fcc.draw_rect(cx + (cellX - s) / 2, cy + (cellY - s) / 2, s, s,
                        1, 1, 1, 0.85 * (1 - p))
          fcc.draw_rect(cx + 1, cy + 1, cellX - 2, cellY - 2,
                        1, 1, 0.9, 0.55 * (1 - p))
        else                     -- 碎片
          local s = cellY * e.sz * (1 - p * 0.85)
          local ox, oy = e.dx * p * cellX * 3.0, e.dy * p * cellY * 3.0
          fcc.draw_rect(cx + (cellX - s) / 2 + ox, cy + (cellY - s) / 2 + oy,
                        s, s, r, g, bl, 0.95 * (1 - p))
        end
      elseif e.fx == 2 then      -- 缩小: 加速塌缩
        local k = 1 - p
        local s = cellY * k * k
        fcc.draw_rect(cx + (cellX - s) / 2, cy + (cellY - s) / 2, s, s,
                      r + (1 - r) * 0.3 * p, g + (1 - g) * 0.3 * p,
                      bl + (1 - bl) * 0.3 * p, 0.95 * (1 - p * 0.4))
      elseif e.fx == 3 then      -- 透明: 增亮后淡出
        local m = p < 0.35 and (0.35 - p) * 2 or 0
        fcc.draw_rect(cx, cy, cellX, cellY,
                      r + (1 - r) * m, g + (1 - g) * m, bl + (1 - bl) * m,
                      0.92 * (1 - p))
      else                       -- 雾化: 膨胀变白上飘
        local s = cellY * e.sz * (1 + p * 2.2)
        local m = p * 0.75
        fcc.draw_rect(cx + (cellX - s) / 2 + e.dx * p * cellX,
                      cy + (cellY - s) / 2 - p * cellY * 1.3, s, s,
                      r + (1 - r) * m, g + (1 - g) * m, bl + (1 - bl) * m,
                      0.5 * (1 - p))
      end
      i = i + 1
    end
  end
end

-- 面板位置平滑缓存(小于3px的取整抖动不更新, 防面板闪烁)
Hud.lastPx = Hud.lastPx or { x = 300, y = 140 }

-- 控件行布局(风主钦定#9549): [<][控件定宽][>] 说明文字 —
-- 说明文字在右微调按钮之后; 左右按钮与控件边缘跨行严格对齐。
-- 绝对定位(ui_set_cursor_pos)+定宽(ui_set_next_item_width):
-- SameLine流式布局中combo/滑条默认占剩余全宽会挤飞同行按钮。
-- 滑条行withAdj=false: cb_ui_slider_float/int自带左右微调按钮
-- (风主#8530全局钦定), ctlRow再加一对=双重按钮(#9400), 故滑条行
-- 不加外层按钮, 控件仍占同一几何槽位(跨行对齐不变)。
local CTL_DX = 30     -- "<"按钮螺距(自然宽~22+间隙)
local CTL_W = 112     -- 控件(combo/滑条)统一宽度(对齐关键)
local function ctlRow(label, key, drawCtl, onAdj, withAdj)
  local bx, y = fcc.ui_get_cursor_pos()
  local adj = 0
  if withAdj ~= false then
    if fcc.ui_button("<##ar_" .. key) then adj = -1 end
    fcc.ui_set_cursor_pos(bx + CTL_DX, y)
    if fcc.ui_set_next_item_width then fcc.ui_set_next_item_width(CTL_W) end
  else
    -- 滑条行: 占据[<]至[>]整行槽位(bx..bx+CTL_DX+CTL_W+30) — 内建微调
    -- 按钮(~17px)与combo行外层按钮(~22px)两端对齐, 滑条本体加长补齐
    fcc.ui_set_cursor_pos(bx, y)
    if fcc.ui_set_next_item_width then
      fcc.ui_set_next_item_width(CTL_DX + CTL_W + 30)
    end
  end
  local ok, ch, val = pcall(drawCtl)
  if withAdj ~= false then
    fcc.ui_set_cursor_pos(bx + CTL_DX + CTL_W + 8, y)
    if fcc.ui_button(">##ar_" .. key) then adj = 1 end
    fcc.ui_same_line()
  else
    -- 标签x与带按钮行严格对齐(按钮宽~22+间隙8)
    fcc.ui_set_cursor_pos(bx + CTL_DX + CTL_W + 38, y)
  end
  fcc.ui_text(label)
  if not ok then print("[block-ai] ctlRow " .. key .. ": " .. tostring(ch)) end
  if adj ~= 0 and onAdj then onAdj(adj) end
  return ch == true, val
end

-- st = _G.BLOCKAI.state
function Hud.draw(st)
  local game = st.game
  if not game then return end

  -- 屏幕绘制队列每帧重建: 空格标记→(2D:方块)→特效→(2D:ghost)
  fcc.draw_clear()
  local b = drawBoardLayer(game, st)
  if b and st.renderMode == 1 then
    fxDraw(b, st.now or 0)
    drawGhost(game, b, st)
  end

  -- 胜利/失败大字(风主#9622/#9625): 棋盘区居中黑边大字 — AI消满360行定格=
  -- 红字"AI胜利！"; gameover=金字"你胜利了！"(定格/结束画面全程显示)
  local winTxt, wr, wg, wb
  if st.aiWon then
    winTxt, wr, wg, wb = tr("AI胜利！"), 1.0, 0.16, 0.12
  elseif game.state == "gameover" then
    winTxt, wr, wg, wb = tr("你胜利了！"), 1.0, 0.84, 0.2
  end
  if winTxt then
    local b2 = b or boardRect()
    if b2 then
      local sz = math.max(34.0, math.min(b2.cellY * 1.35, 110.0))
      local tw = 0
      local okT, wT = pcall(fcc.calc_text_width, winTxt, sz)
      if okT and wT then tw = wT end
      local tx = b2.x + b2.cellX * 5 - tw * 0.5
      local ty = b2.y + b2.cellY * 10 - sz * 0.6
      fcc.draw_text_shadow(tx, ty, winTxt, sz, wr, wg, wb, 1.0,
                           0, 0, 0, 0.95, 3)
    end
  end

  -- 信息面板位置(#9598/#9601/#9607风主钦定): 行数/得分=屏幕层大字(原字体
  -- 风格)画在面板内部上方; 面板锚图片左侧顶部; 棋盘左侧(图片内)空间不足
  -- → 面板移图片左侧屏幕区, 右缘精确贴图片本体左缘(零间隙, 用实际面板宽
  -- 缓存 — 估算288会留~32px缝+隔阴影带)
  local px, py = Hud.lastPx.x, Hud.lastPx.y
  local okR, ix, iy, iw, ih = pcall(fcc.image_get_rect)
  if okR and iw and iw > 100 and ih > 100 then
    local gx, gy = ix + iw * 0.02, iy + ih * 0.06
    local nx = math.max(ix + 4, gx)
    local pw = Hud.lastPw or 288
    local brect = boardRect()
    if brect and (brect.x - (ix + 4)) < pw + 12 and ix >= pw + 4 then
      nx = ix - pw   -- 右缘贴图片本体左缘(零间隙)
    end
    local ny = gy
    -- 屏幕内钳制(#9607): 图片可拖到边缘, 面板必须始终完整可见
    local okS, sw, sh = pcall(fcc.viewer_get_screen_size)
    if okS and sw and sh and sw > 100 and sh > 100 then
      if nx < 4 then nx = 4 end
      if nx > sw - pw - 4 then nx = sw - pw - 4 end
      if ny < 4 then ny = 4 end
      if ny > sh - 340 then ny = sh - 340 end
    end
    if math.abs(nx - px) > 3 or math.abs(ny - py) > 3 then
      px, py = nx, ny
      Hud.lastPx.x, Hud.lastPx.y = nx, ny
    end
  end
  -- 79=71(每帧锚定图片内右上+NoMove+NoCollapse+NoResize)+8(AlwaysAutoResize
  -- 高度自适应内容, 风主#2077; h=0跳过SetNextWindowSize=ImGui全自适应)
  fcc.ui_push_style_color(2, 0.05, 0.06, 0.09, 0.25)   -- WindowBg
  fcc.ui_push_style_color(10, 0.08, 0.09, 0.13, 0.25)  -- TitleBg
  fcc.ui_push_style_color(11, 0.10, 0.12, 0.16, 0.25)  -- TitleBgActive
  fcc.ui_push_style_color(12, 0.08, 0.09, 0.13, 0.25)  -- TitleBgCollapsed
  fcc.ui_push_style_color(3, 0, 0, 0, 0)     -- ChildBg(嵌入区透, 面板底已半透)
  fcc.ui_push_style_color(7, 0.15, 0.17, 0.2, 0.45)   -- FrameBg半透
  fcc.ui_push_style_color(9, 0.2, 0.23, 0.27, 0.55)   -- FrameBgActive
  fcc.ui_begin(tr("方块对抗"), px, py, 272, 0, 79)
  -- 面板实际宽度缓存(AlwaysAutoResize自适应): 下帧贴边计算用 —
  -- 估算288会在图片左侧留~32px缝(隔外部阴影带更显眼)
  local okW, wpx = pcall(fcc.ui_get_window_size)
  if okW and wpx and wpx > 50 then Hud.lastPw = wpx end
  local ok, err = pcall(function()
    if game.state == "title" then
      fcc.ui_text_colored(1.0, 0.75, 0.1, 1.0, tr("方块对抗"))
      fcc.ui_text_colored(0.6, 0.85, 1.0, 1.0, tr("AI 对抗 鼠标点击"))
      fcc.ui_separator()
      fcc.ui_text(tr("玩法(无键盘):"))
      fcc.ui_text(tr("AI自动消除 -- 落块消行(1~10可调)"))
      fcc.ui_text(tr("鼠标左键点击 -- 消除单个方块"))
      fcc.ui_text(tr("点击一行最后一块 -- 整行消除+加分"))
      fcc.ui_separator()
      if game.blink < 0.5 then
        fcc.ui_text_colored(0.0, 0.75, 1.0, 1.0, tr("开始游戏..."))
      end
    else
      -- 行数/得分(风主#9601: 字体大小/风格保持原屏显版): 屏幕层大字
      -- 画在面板内部上方(标签25/数字39/标签30/数字52px, 行数绿黄/得分
      -- 青橙, 黑边阴影); 面板内容光标下移预留大字区(~212px), 下接分割线
      fcc.draw_text_shadow(px + 14, py + 30, tr("行数"), 25,
                           0.2, 0.95, 0.35, 1.0, 0, 0, 0, 0.9, 1.6)
      fcc.draw_text_shadow(px + 14, py + 61, tostring(game.lines), 39,
                           1.0, 0.9, 0.1, 1.0, 0, 0, 0, 0.9, 1.6)
      fcc.draw_text_shadow(px + 14, py + 108, tr("得分"), 30,
                           0.0, 0.75, 1.0, 1.0, 0, 0, 0, 0.86, 2)
      fcc.draw_text_shadow(px + 14, py + 148, string.format("%d", game.score),
                           52, 1.0, 0.55, 0.1, 1.0,
                           0, 0, 0, 0.86, 2.5)
      fcc.ui_set_cursor_pos(8, 212)   -- 大字区预留(标题栏~26+大字~186)
      -- 下一块队列显示已去除(风主#2077; bag逻辑保留, AI自动消费)
      -- 控件行(渲染/材质/特效/音量×2/AI速度): 统一[<][定宽][>]说明
      local chA, curR = ctlRow(tr("渲染"), "rm",
        function()
          return fcc.ui_combo("##tet_rm", st.renderMode or 0, trCombo(RMS[1]))
        end,
        function(d)
          st.requestRenderMode = ((st.renderMode or 0) + d + 2) % 2
        end)
      if chA then st.requestRenderMode = curR end
      local chM, curM = ctlRow(tr("材质"), "mat",
        function()
          return fcc.ui_combo("##tet_mat", st.matId, trCombo(MATS[1]))
        end,
        function(d) st.matId = (st.matId + d + 5) % 5 end)
      if chM then st.matId = curM end   -- variant直接生效(数组直驱)
      local ch2, cur2 = ctlRow(tr("消除特效"), "fx",
        function()
          return fcc.ui_combo("##tet_fx", st.fxId, trCombo(FXS[1]))
        end,
        function(d) st.fxId = (st.fxId + d + 6) % 6 end)
      if ch2 then st.fxId = cur2 end
      if type(st.volSfx) ~= "number" then st.volSfx = 0 end
      -- 音效音量(风主#9605, 原"总音量"): 只调节SFX — SFX每次play即读
      -- volSfx实时生效, 零RPC联动; 音乐滑条(volBgm)独立控制BGM
      local chV, vV = ctlRow(tr("音效"), "volm",
        function()
          local v, c = fcc.ui_slider_float("##tet_volm",
                                           st.volSfx, 0.0, 1.0)
          return c, v
        end,
        function(d)
          st.volSfx = math.max(0.0, math.min(1.0, st.volSfx + d * 0.05))
        end, false)
      if chV then
        st.volSfx = vV
      end
      if type(st.volBgm) ~= "number" then st.volBgm = 0.0 end
      local chB, vB = ctlRow(tr("音乐"), "volb",
        function()
          local v, c = fcc.ui_slider_float("##tet_volb", st.volBgm, 0.0, 1.0)
          return c, v
        end,
        function(d)
          st.volBgm = math.max(0.0, math.min(1.0, st.volBgm + d * 0.05))
          local A = _G.BLOCKAI.Audio
          if A.bgmId then A.applyVolume(st.volBgm)
          elseif not A.musicOn and st.volBgm > 0.001 then
            A.musicOn = true
            A.startBgm(st.volBgm)
          end
        end, false)
      if chB then
        st.volBgm = vB
        local A = _G.BLOCKAI.Audio
        if A.bgmId then
          A.applyVolume(vB)          -- 播放中实时调
        elseif not A.musicOn and vB > 0.001 then
          A.musicOn = true           -- 滑条/按钮>0=开乐意图
          A.startBgm(vB)
        end
      end
      -- AI速度(风主#2077命名; 原"自动消除"): 整数1~10=平均每秒真实消行数
      -- (10=不限速; 对抗模式AI恒玩无off)
      if type(st.autoClear) ~= "number" then st.autoClear = 1 end
      st.autoClear = math.max(1, math.min(10,
          math.floor(st.autoClear + 0.5)))
      local chC, vC = ctlRow(tr("AI速度"), "ac",
        function()
          local v, c = fcc.ui_slider_int("##tet_ac",
                                         math.floor(st.autoClear + 0.5), 1, 10)
          return c, v
        end,
        function(d)
          st.autoClear = math.max(1, math.min(10,
              math.floor(st.autoClear + 0.5) + d))
        end, false)
      if chC then st.autoClear = vC end
      fcc.ui_separator()
      if game.state == "paused" then
        if fcc.ui_button(tr("继续游戏")) then st.requestResume = true end
      else
        if fcc.ui_button(tr("暂停")) then st.requestPause = true end
      end
      fcc.ui_same_line()
      if fcc.ui_button(tr("重新开始")) then st.requestRestart = true end
      fcc.ui_same_line()
      -- 退出=关闭方块对抗扩展会话(风主#2077: 非退出fcc)
      if fcc.ui_button(tr("退出")) then _G.BLOCKAI.stop() end
      -- "游戏暂停"文字已删(风主#9622): 暂停态由[继续游戏]按钮自明
      if game.state == "gameover" then
        fcc.ui_text_colored(1.0, 0.25, 0.2, 1.0,
                            tr("游戏结束!  最终得分 ") .. game.score)
        -- 重开引导已去文字提示(风主#9648): 点击棋盘区域即自动重新开始
      end
      if st.aiWon then
        fcc.ui_text_colored(1.0, 0.2, 0.15, 1.0, tr("AI胜利！"))
      end
    end
  end)
  if not ok then print("[block-ai] hud error: " .. tostring(err)) end
  fcc.ui_end()
  fcc.ui_pop_style_color(7)
end

_G.BLOCKAI.Hud = Hud
return Hud
