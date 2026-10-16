-- ============================================================================
-- board.lua — 棋盘3D层 = 静态格子=方块本体(#9472/#9445/#9455三令合一)
--
-- 架构: 200个固定格子粒子(10×20)出生一次 — 位置/尺寸出生时定死,
-- 永不移动永不死亡(与鱼同构的渲染流程); 每tick从board数组(+active/
-- ghost)计算每格期望态(variant/hue/light/pin) → set_state批量窄写
-- 差异格。零kill零spawn零move: 消行/锁块/材质切换/幽灵/下落全部=
-- 数据变化的即时repaint, 渲染层是board数组的纯函数。
-- 格态: 空=variant4暗格(pin3休眠不占bio格) 锁定=材质+色相(pin1阻挡)
--       下落=材质+色相+亮(pin2驱离) 幽灵=variant4+块色相(pin3)。
-- 渲染管线: 程序化圆角圆边立方体 → behavior=17静态mesh域粒子,
-- 与鱼/鸟/昆虫同一vs_particle_mesh管线(法线光照/PBR注入/深度遮挡)。
-- 坐标系: pos=RT像素(中心原点y向上); blockPx=半边长(mesh size语义)。
-- fx消除特效: 独立type自生自灭(寿命自然消亡, 不受格子调和影响)。
-- board读取: game:boardSnapshot() seqlock一致性读(防读到写一半数据)。
-- ============================================================================

_G.BLOCKAI = _G.BLOCKAI or {}
local Board = _G.BLOCKAI.Board
if not Board then Board = {}; _G.BLOCKAI.Board = Board end

local rpc = function(domain, op, args)
  return fcc.rpc(domain, op, args)
end

-- ── owner忙探测(风主#9622): 后台编译着色器期不让owner同步RPC阻塞worker ────
-- 闪烁机理: rpcOnOwnerSync对lua worker是250ms超时同步等待, 等待期间worker
-- 持g_luaRenderMutex → 渲染线程on_render(12ms限时抢锁, ImGui面板立即模式)
-- 跳帧 = UI面板整帧消失闪烁; owner忙=全粒子组后台编译0.3~7s, 编译期每tick
-- 重试同步RPC = 持续闪烁。hotreload.status(#2077)纯原子/短锁读取非阻塞,
-- 0.25s节流缓存; busy=true时tick路径的owner同步RPC(bio_grid_info/
-- emitters.add/particle.info)全部让路, 编译结束自动恢复。
Board.busyAt = -1e9
Board.busyVal = false
function Board.ownerBusy()
  local st = _G.BLOCKAI.state
  local now = (st and st.now and st.now > 0) and st.now or os.clock()
  if now - Board.busyAt < 0.25 then return Board.busyVal end
  Board.busyAt = now
  local r = rpc("hotreload", "status", {})
  Board.busyVal = (tonumber(r and r.in_flight) or 0) > 0
  return Board.busyVal
end

-- 旧代际类型清理(热重载残留)
if Board.bbTypeId then
  rpc("particle", "unregister_type", { type = Board.bbTypeId })
  Board.bbTypeId = nil
end
if Board.typeId and Board.typeOk == nil then
  rpc("particle", "unregister_type", { type = Board.typeId })
  Board.typeId = nil
end
if Board.fxTypeId then
  rpc("particle", "unregister_type", { type = Board.fxTypeId })
  Board.fxTypeId = nil
end

-- 7种方块颜色: 原版hex(方块对抗前作C++工程), I块=天蓝(风主指定)
local HUES = { [0] = 192.999, [1] = 240.999, [2] = 38.999,
               [3] = 60.846, [4] = 120.953, [5] = 270.831,
               [6] = 0.999 }
local BLOCK_L = { [0] = 0.66, [1] = 0.67, [2] = 0.50, [3] = 0.57,
                  [4] = 0.66, [5] = 0.63, [6] = 0.75 }
local BLOCK_HEX = { [0] = { 0.0, 0xc8 / 255, 1.0 },
                    [1] = { 0x55 / 255, 0x55 / 255, 0xff / 255 },
                    [2] = { 0xff / 255, 0xa5 / 255, 0x00 / 255 },
                    [3] = { 0xee / 255, 0xdd / 255, 0x33 / 255 },
                    [4] = { 0x58 / 255, 0xfb / 255, 0x58 / 255 },
                    [5] = { 0xa1 / 255, 0x52 / 255, 0xef / 255 },
                    [6] = { 0xff / 255, 0x80 / 255, 0x80 / 255 } }
Board.HUES = HUES
Board.visible3d = true   -- 渲染模式(2D备选=false: 只留footprint占格)

function Board.pieceColor(t)
  -- t可能为board打包值(type+seq*8): %8解包; 纯type(0-6)幂等
  local c = BLOCK_HEX[t % 8] or BLOCK_HEX[0]
  return c[1], c[2], c[3]
end

-- ── 程序化圆角盒模型(set_mesh格式: 8f顶点+索引) ──────────────────────────
local CUBE_N = 16
local FACES = {
  { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } },
  { { -1, 0, 0 }, { 0, 1, 0 }, { 0, 0, -1 } },
  { { 0, 1, 0 }, { 0, 0, 1 }, { 1, 0, 0 } },
  { { 0, -1, 0 }, { 0, 0, 1 }, { -1, 0, 0 } },
  { { 0, 0, 1 }, { 1, 0, 0 }, { 0, 1, 0 } },
  { { 0, 0, -1 }, { 1, 0, 0 }, { 0, -1, 0 } },
}
function Board.buildRoundBox(hx, hy, hz)
  local r = math.min(0.30, hx, hy, hz)
  local lx, ly, lz = hx - r, hy - r, hz - r
  local H = { hx, hy, hz }
  local function hOf(v)
    if v[1] ~= 0 then return H[1] end
    if v[2] ~= 0 then return H[2] end
    return H[3]
  end
  local verts, idx = {}, {}
  local nv = 0
  local function round(px, py, pz, fn)
    local ix = math.max(-lx, math.min(lx, px))
    local iy = math.max(-ly, math.min(ly, py))
    local iz = math.max(-lz, math.min(lz, pz))
    local dx, dy, dz = px - ix, py - iy, pz - iz
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 > 1e-9 then
      local d = math.sqrt(d2)
      local k = r / d
      return ix + dx * k, iy + dy * k, iz + dz * k,
             dx / d, dy / d, dz / d
    end
    return px, py, pz, fn[1], fn[2], fn[3]
  end
  for _, f in ipairs(FACES) do
    local fn, fu, fv = f[1], f[2], f[3]
    local hn, hu, hv = hOf(fn), hOf(fu), hOf(fv)
    local base = nv
    for j = 0, CUBE_N do
      for i = 0, CUBE_N do
        local u = i / CUBE_N * 2 - 1
        local v = j / CUBE_N * 2 - 1
        local px = fn[1] * hn + fu[1] * hu * u + fv[1] * hv * v
        local py = fn[2] * hn + fu[2] * hu * u + fv[2] * hv * v
        local pz = fn[3] * hn + fu[3] * hu * u + fv[3] * hv * v
        local x, y, z, nx, ny, nz = round(px, py, pz, fn)
        local m = nv * 8
        verts[m + 1] = x; verts[m + 2] = y; verts[m + 3] = z
        verts[m + 4] = (u + 1) * 0.5; verts[m + 5] = (v + 1) * 0.5
        verts[m + 6] = nx; verts[m + 7] = ny; verts[m + 8] = nz
        nv = nv + 1
      end
    end
    local W = CUBE_N + 1
    for j = 0, CUBE_N - 1 do
      for i = 0, CUBE_N - 1 do
        local a = base + j * W + i
        local b = a + 1
        local c = a + W
        local d = c + 1
        idx[#idx + 1] = a; idx[#idx + 1] = b; idx[#idx + 1] = d
        idx[#idx + 1] = a; idx[#idx + 1] = d; idx[#idx + 1] = c
      end
    end
  end
  return verts, idx
end

-- 单位扁盒mesh(棋盘背景格): 半轴(1,2,0.02)规则网格顶点
-- (4顶点裸quad会破坏mesh管线顶点假设→驱动崩溃, 禁用)

-- 5变体程序化纹理: 0-3材质(积木/玻璃/软糖/金属) 4ghost/柔体特效
local function matTexture(matId)
  local W = 128
  local rows = {}
  for y = 1, W do
    local row = {}
    for x = 1, W do
      local g, a = 235, 255
      local u, v = (x - 0.5) / W, (y - 0.5) / W
      if matId == 0 then          -- 积木: 强木纹横带+颗粒+顶亮线
        local grain = math.sin(y * 0.42 + math.floor(x / 9) * 1.3) * 26
        g = 226 + grain + ((x * 7 + y * 13) % 5) * 3
        if v < 0.10 then g = 252 end
        if v > 0.92 then g = 186 end
      elseif matId == 1 then      -- 玻璃: 中心高透+斜向亮纹+边缘亮框
        a = 72
        g = 196 + math.floor((1 - math.abs(u - 0.5) * 2) * 34)
        local diag = math.abs((u + v) - 1.0)
        if diag < 0.06 then g = 245 end
        local e = math.max(math.abs(u - 0.5), math.abs(v - 0.5))
        if e > 0.72 then g, a = 255, 236 end
      elseif matId == 2 then      -- 软糖: 气泡内亮斑+饱和半透
        g = 238
        a = 228
        local d = math.sqrt((u - 0.5) ^ 2 + (v - 0.5) ^ 2)
        if d < 0.24 then g, a = 255, 202 end
        local bub = math.sqrt((u - 0.28) ^ 2 + (v - 0.36) ^ 2)
        if bub < 0.10 or math.abs(bub - 0.16) < 0.025 then g = g - 26 end
        local bub2 = math.sqrt((u - 0.72) ^ 2 + (v - 0.68) ^ 2)
        if bub2 < 0.08 or math.abs(bub2 - 0.13) < 0.02 then g = g - 22 end
      elseif matId == 3 then      -- 金属: 水平拉丝强对比条纹
        local s = math.sin(y * 2.1 + (x % 11) * 0.55) * 0.5 + 0.5
        g = 142 + math.floor(s * 92)
        if (y % 16) < 2 then g = g - 34 end
        if v < 0.08 or v > 0.94 then g = g + 30 end
      else                        -- ghost/柔体: 浅纹(白闪/雾化共用)
        g, a = 200, 255
        local e2 = math.max(math.abs(u - 0.5), math.abs(v - 0.5)) * 2
        if e2 > 0.86 then g = 255 end
        if math.abs(e2 - 0.62) < 0.045 then g = 128 end
      end
      if matId == 5 then          -- 棋盘背景格: 10×20格线+透明底
        g, a = 235, 0
        local gx = (x - 1) / W * 10
        local gy = (y - 1) / W * 20
        local fx = math.abs(gx - math.floor(gx + 0.5))
        local fy = math.abs(gy - math.floor(gy + 0.5))
        local lw = W / 160        -- 线宽~0.8px
        if fx * 10 < lw or fy * 20 < lw or gx < 0.5 or gx > 9.5
           or gy < 0.5 or gy > 19.5 then
          a = 255                 -- 格线+外框
        end
        if math.floor(gx) % 2 == math.floor(gy) % 2 then
          a = math.max(a, 14)     -- 棋盘微底色
        end
      end
      row[#row + 1] = string.char(
          math.max(0, math.min(255, math.floor(g))),
          math.max(0, math.min(255, math.floor(g))),
          math.max(0, math.min(255, math.floor(g))),
          math.max(0, math.min(255, math.floor(a))))
    end
    rows[#rows + 1] = table.concat(row)
  end
  return table.concat(rows)
end

-- ── 类型+模型+纹理注册(幂等; 出错返回false不抛出—防start()僵死) ──────────
function Board.ensureType()
  local resGen = _G.__BLOCKAI_GEN
  if Board.typeId and Board.typeOk and Board.resGen == resGen then
    if not Board.pbrOk then Board.setShaderInjects() end
    return Board.pbrOk and Board.slotTypeId ~= nil
  end
  -- 同代际失败重试保留既有注册: unregister+re-register会重分配texBase
  -- (boot期owner忙的多次重试=槽段漂移, 已出生粒子texIdx/纹理槽/注入
  -- 区间三者错位=材质脱靶+倾角失效根因, 实测240→239)。跨代际残留由
  -- 模块顶部清理负责; register_type同名单单例幂等(同名复用id/槽段)。
  local fresh = not Board.typeId
  local ok, err = pcall(function()
    local upOk = true
    if fresh then
      -- 块type: behavior=17静态mesh域, 通用mesh管线
      -- hidden=true(风主#9622): 扩展内部渲染类型不进特效编辑面板
      -- (host侧TypeMeta.hidden过滤按钮; 未支持时未知字段被忽略=前向兼容)
      local r = rpc("particle", "register_type",
                    { name = "方块对抗", name_en = "BlockAI",
                      behavior = 17, variants = 6, defaultsFrom = 0,
                      hidden = true })
      if not r or not r.ok then error("register_type failed") end
      Board.typeId = r.type
    end
    -- 占格粒子独立类型(behavior=0 billboard): size≈0不渲染, 纯bio槽位
    if not Board.slotTypeId then
      local rs = rpc("particle", "register_type",
                      { name = "方块对抗槽位", name_en = "BlockAISlot",
                        behavior = 0, variants = 1, defaultsFrom = 0,
                        hidden = true })
      if not rs or not rs.ok then error("slot register_type failed") end
      Board.slotTypeId = rs.type
    end
    -- fx特效独立类型: 同mesh管线, 不进快照不受清场影响(自生自灭)
    if not Board.fxTypeId then
      local rf = rpc("particle", "register_type",
                      { name = "方块对抗特效", name_en = "BlockAIFx",
                        behavior = 17, variants = 5, defaultsFrom = 0,
                        hidden = true })
      if not rf or not rf.ok then error("fx register_type failed") end
      Board.fxTypeId = rf.type
    end
    Board.texSlots = Board.texSlots or {}
    for v = 0, 5 do
      -- 变体命名(面板显示); 槽位真值只由下方set_pixels的base+v单源
      -- (register_variant的slot返回与寻址可错位, 勿用作注入区间基准)
      rpc("particle", "register_variant",
          { type = Board.typeId, cn = "方块" .. v, en = "block" .. v })
    end
    Board.fxSlots = Board.fxSlots or {}
    for v = 0, 4 do
      rpc("particle", "register_variant",
          { type = Board.fxTypeId, cn = "特效" .. v, en = "fx" .. v })
    end
    -- 纹理缓存(风主#9622): matTexture+base64纯函数确定性输出, _G级缓存
    -- 跨热重载复用 — 每次重注册重生成11张纹理=worker持lua锁40~60ms
    -- (纯Lua sin×16万+base64×72万字节) → on_render跳帧=面板闪烁
    local texB64 = _G.BLOCKAI.texB64
    if not texB64 then texB64 = {}; _G.BLOCKAI.texB64 = texB64 end
    -- 纹理上传+槽位真值采录: set_pixels失败(owner route未激活等)整体
    -- 返回false由pendingStart重试 — 否则纹理缺失+注入区间错位(黑块/
    -- 背景格走错材质分支)永无修复机会
    if _G.BLOCKAI.b64 then
      -- 热重载跳过重上传(风主#9622): 纹理内容确定性+atlas进程内持久,
      -- typeId不变时set_pixels重传=11×87KB JSON解析≈100ms持lua锁=
      -- on_render跳帧闪烁; ownerId校验防type被外部清除重注册的槽段漂移
      local texDone = Board.texOwnerId == Board.typeId
      if not texDone then
        for v = 0, 5 do
          local px = texB64[v]
          if not px then
            px = _G.BLOCKAI.b64(matTexture(v))
            texB64[v] = px
          end
          local rs = rpc("particle", "set_pixels",
              { type = Board.typeId, variant = v, w = 128, h = 128,
                pixels_b64 = px })
          if rs and rs.ok then
            -- base=TypeMeta真值单源(texIdx寻址/uTexBase同源); slot与其数学
            -- 恒等(base+v)但取base防任何错位快照残留
            if type(rs.base) == "number" then
              Board.texSlots[v] = rs.base + v
            elseif type(rs.slot) == "number" then
              Board.texSlots[v] = rs.slot
            end
          else
            print("[block-ai] tex v" .. v .. ": " ..
                  tostring(rs and rs.error or rs))
            if rs and rs.error and rs.error:find("invalid type") then
              Board.typeId = nil   -- 注册被外部清除, 下轮重新register
            end
            upOk = false
          end
        end
      end
      local fxDone = Board.fxOwnerId == Board.fxTypeId
      if not fxDone then
        for v = 0, 4 do
          local px = texB64[v]
          if not px then
            px = _G.BLOCKAI.b64(matTexture(v))
            texB64[v] = px
          end
          local rs = rpc("particle", "set_pixels",
              { type = Board.fxTypeId, variant = v, w = 128, h = 128,
                pixels_b64 = px })
          if rs and rs.ok then
            if type(rs.base) == "number" then
              Board.fxSlots[v] = rs.base + v
            elseif type(rs.slot) == "number" then
              Board.fxSlots[v] = rs.slot
            end
          else
            print("[block-ai] fx v" .. v .. ": " ..
                  tostring(rs and rs.error or rs))
            if rs and rs.error and rs.error:find("invalid type") then
              Board.fxTypeId = nil
            end
            upOk = false
          end
        end
      end
      if not upOk then return false end
      if Board.typeId then Board.texOwnerId = Board.typeId end
      if Board.fxTypeId then Board.fxOwnerId = Board.fxTypeId end
    end    -- 程序化模型: 0-4=圆角立方体(材质×4+ghost/柔体)
    -- mesh同skip(热重载2×150KB JSON≈40ms): 模型确定性+owner侧进程内持久
    if Board.meshOwnerId ~= Board.typeId
        or Board.meshOwnerFx ~= Board.fxTypeId then
      local cv, ci = Board.buildRoundBox(1, 1, 1)
      local mr = rpc("particle", "set_mesh",
                     { type = Board.typeId,
                       variants = { { verts = cv, indices = ci },
                                    { verts = cv, indices = ci },
                                    { verts = cv, indices = ci },
                                    { verts = cv, indices = ci },
                                    { verts = cv, indices = ci } } })
      if not mr or mr.ok == false then error("set_mesh failed") end
      local mf = rpc("particle", "set_mesh",
                     { type = Board.fxTypeId,
                       variants = { { verts = cv, indices = ci },
                                     { verts = cv, indices = ci },
                                     { verts = cv, indices = ci },
                                     { verts = cv, indices = ci },
                                     { verts = cv, indices = ci } } })
      if not mf or mf.ok == false then error("fx set_mesh failed") end
      Board.meshOwnerId = Board.typeId
      Board.meshOwnerFx = Board.fxTypeId
    end
    -- 渲染深度模式(通用API): 块type不透明粒子(alpha≥0.5)走真深度通道
    -- (粒子间像素级硬遮挡, 修排序键全等的bitonic乱序); 半透明(玻璃0.46/
    -- 空格/幽灵)自动留透明合并pass — 材质切换零同步。fx自生自灭含低alpha
    -- 柔体, 不设(恒透明混合)。
    rpc("particle", "set_mesh_depth_mode",
        { type = Board.typeId, mode = 1 })
    return upOk
  end)
  if not ok then
    print("[block-ai] ensureType失败: " .. tostring(err))
    return false
  end
  if err == false then return false end   -- 纹理上传未就绪, pendingStart重试
  Board.typeOk = true
  Board.resGen = resGen
  Board.setShaderInjects()
  return true
end

-- ── PBR材质着色注入(FS @fs_paper_color) ──────────────────────────────────
-- 命中=块texIdx或fx texIdx落在各自slot段(两组范围)。
-- 空格/幽灵(aCell<0.5, VS已压平正对屏幕): 无明暗无棱带, 近黑平贴+
-- 格线凹槽, 棋盘退背景不喧宾; 幽灵=块色相平贴+微弱描边。
-- 方块(aCell>=0.5): 宝石感PBR — 饱和提亮base + 面明暗(顶1.35/正1.0/
-- 侧0.42) + 全材质棱线亮边; 4材质各具质感; fx白闪/雾化走variant4。
-- alpha统一由vColor.a驱动(软件背面剔除: 法线z<0=discard)。
local PBR_INJECT = [[
{
  // texIdx槽段守卫(0cf04b3风主认可版r30_fs_after): 动态槽段由分配器
  // 独占分配(fish-pack 167-238 / block-ai 239-244 / fx 246-250), 段命中
  // 即本扩展粒子。⚠禁用vType: VS侧vType已按uBehaviorAlias重映射为
  // 行为域id(静态mesh=17), 恒≠注册type(18) → 守卫永不命中 = 材质/
  // 倾角/糖霜全灭(r30后材质变狗屎根因, 误当补丁保留)
  bool inTet = (vTexIdx >= TET_SLOT0 && vTexIdx <= TET_SLOT0 + 5)
            || (vTexIdx >= FX_SLOT0 && vTexIdx <= FX_SLOT0 + 4);
  if(inTet){
    if(vNormalTrueVS.z < 0.0) discard;   // 背面剔除(闭立方体)
    bool fxFin = (vInitLife < 1000000.0);
    float aCell = vColor.a;
    float3 Np = normalize(vNormalTrueVS + float3(1e-5, 1e-5, 1e-5));
    float2 fp = clamp(vUV, float2(0.0, 0.0), float2(1.0, 1.0));
    float eu = abs(fp.x - 0.5) * 2.0, ev2 = abs(fp.y - 0.5) * 2.0;
    float edge = max(eu, ev2);
    float bev = smoothstep(0.88, 1.0, edge);          // 圆角棱带
    float3 Lp = normalize(float3(-0.42, 0.66, 0.62));
    float ndl = max(dot(Np, Lp), 0.0);
    float ndv = max(Np.z, 0.0);
    float fres = pow(1.0 - ndv, 3.0);
    float3 Hq = normalize(Lp + float3(0.0, 0.0, 1.0));
    float ndh = max(dot(Np, Hq), 0.0);
    float relSlot = (vTexIdx - TET_SLOT0 < 0) ? (vTexIdx - FX_SLOT0)
                                              : (vTexIdx - TET_SLOT0);
    float sd = frac(vSeed * 0.7311);
    float3 base = vColor.rgb;
    // 色度归一(满饱和): mesh管线vColor=HSL(hue,L 0.5~0.75)先天粉彩=
    // 过亮低饱和根因 — max通道归一到1(hue不变, 白fx不受影响), 明暗
    // 全部交由faceLit面光照+高光承担(替代旧mix饱和×1.55+×1.06+0.05提亮)
    float mxB = max(base.r, max(base.g, base.b));
    base = base / max(mxB, 1e-4);
    float faceF = smoothstep(0.45, 0.75, Np.z);
    float faceT = smoothstep(0.35, 0.65, Np.y);
    float faceLit = lerp(0.42, 1.0, faceF);              // 侧0.42 正1.0
    faceLit = lerp(faceLit, 1.35, faceT);                // 顶1.35
    // ── 场景反射采样(风主钦定: 玻璃/金属反射环境) ──
    // 真反射语义: 镜面按反射向量R=V-2(V·N)N取环境(V视线, N面法线) —
    // 左面采右侧景物/右面采左侧/正面+顶面系统性采上部天空(带+0.18上偏),
    // 面间反射内容互异=反射感; 就地采样=采到方块背后被挡内容=透明感(禁)
    float2 sBase = float2(0.5, 0.5);
    float3 sceneR = float3(0.24, 0.27, 0.32);
    if(uHasScene != 0){
      if(uSceneUVMode == 1){
        float2 sLocal = float2(gl_FragCoord.x - uImgRect.x,
                               gl_FragCoord.y - uImgRect.y);
        float2 sSz = max(uImgRect.zw, float2(1.0, 1.0));
        sBase = float2(sLocal.x / sSz.x, 1.0 - sLocal.y / sSz.y);
      } else {
        sBase = float2(gl_FragCoord.x / max(uScreenSize.x, 1.0),
                       1.0 - gl_FragCoord.y / max(uScreenSize.y, 1.0));
      }
      // R=V-2(V·N)N, V=(0,0,1) → R.xy = -2·N.xy·N.z (屏面投影)
      float2 rOff = -2.0 * Np.xy * Np.z;
      // 偏移=反射向×位移尺度 + 天空上偏(面级环境差+反射偏亮)
      float2 sRefl = clamp(sBase + rOff * 0.35 + float2(0.0, 0.18),
                           float2(0.0, 0.0), float2(1.0, 1.0));
      sceneR = uSceneTex.Sample(s0, sRefl).rgb * 1.12;
    }
    if(aCell < 0.5){
      if(aCell < 0.10){                 // 幽灵(0.05): 平贴色块+微弱描边
        col = base * 1.10;
        a = aCell * (1.0 + 1.6 * bev);
      } else {                          // 空格(0.2): 近黑平贴+格线凹槽
        float gline = smoothstep(0.72, 0.95, edge);
        col = float3(0.030, 0.036, 0.055);
        a = aCell * (0.40 + 1.05 * gline);
      }
    } else if(relSlot > 3.5){           // fx白闪核心/雾化柔体(variant4)
      col = base * (0.95 + 0.30 * ndl);
      col += float3(1.0, 1.0, 1.0) * pow(ndh, 22.0) * 0.45;
      col += float3(1.0, 1.0, 1.0) * pow(ndh, 8.0) * 0.35;   // 大范围光晕
      col += float3(1.0, 1.0, 1.0) * pow(1.0 - edge, 2.0) * 0.30;
      col += float3(1.0, 1.0, 1.0) * fres * 0.40;            // 掠射辉光
      a = aCell;
    } else if(relSlot < 0.5){           // 积木: 鲜艳木纹+强塑料高光
      float grain = sin(fp.y * 30.0 + sin(fp.x * 7.0 + sd * 6.0) * 1.8);
      float wood = 0.86 + 0.14 * (grain * 0.5 + 0.5);
      col = base * wood * faceLit * (0.72 + 0.36 * ndl);
      col += float3(1.0, 1.0, 1.0) * pow(ndh, 48.0) * 0.55;
      col += float3(1.0, 1.0, 1.0) * bev * 0.30 * faceLit;
      col += base * fres * 0.10;
      a = aCell;
    } else if(relSlot < 1.5){           // 玻璃: 彩色玻璃管(参照: 高饱和浓彩+垂直光带+边缘亮, 无面条纹)
      // 垂直亮度梯度(参照: 顶亮底深, 屏幕空间全板一致)
      float vgrad = lerp(0.62, 1.28,
          clamp((gl_FragCoord.y - uImgRect.y) / max(uImgRect.w, 1.0),
                0.0, 1.0));
      col = base * 1.10 * vgrad * faceLit;         // 浓彩糖体(参照管色浓郁)
      col += base * 0.26;                          // 透射底(染色提饱和)
      float grim = smoothstep(0.45, 0.98, edge);
      col += (base * 0.65 + float3(0.35, 0.35, 0.35)) * grim * 0.50;   // 边缘辉光(染色为主)
      col += float3(0.80, 0.88, 1.0) * fres * 0.85;        // 掠射缘(减白)
      col += lerp(float3(1.0, 1.0, 1.0), base, 0.30) * pow(ndh, 90.0) * 0.90;  // 锐镜面(30%染色)
      col += lerp(float3(1.0, 1.0, 1.0), base, 0.45) * bev * 0.50 * faceLit;   // 棱线亮(染色)
      col = lerp(col, sceneR * lerp(float3(1.0, 1.0, 1.0), base, 0.45),
               0.30 + 0.30 * fres);                // 场景反射(就地采样, 染色, 强度提高)
      // 饱和度补偿: 白高光/反射混入后resaturate(参照管色高饱和)
      float glLum = dot(col, float3(0.299, 0.587, 0.114));
      col = lerp(float3(glLum, glLum, glLum), col, 1.45);
      a = aCell * 0.46;                            // 半透浓彩(参照实心感)
    } else if(relSlot < 2.5){           // 软糖: 糖霜颗粒+边缘透光辉光(风主参照)
      // 糖霜白色颗粒(shader内实现, 风主参照: 每颗方块图案完全不同+大颗密集)
      // per块种子sA/sB进入hash输入 → 每颗的颗粒分布/大小/亮度独立;
      // 双层颗粒: 大粒层(20格, 58%覆盖, 大颗) + 细粒层(46格, 稀疏小点)
      float2 gp = fp * 20.0;
      float2 gid = floor(gp);
      float sA = frac(sd * 17.31 + 0.217);
      float sB = frac(sd * 43.77 + 0.613);
      float2 hq = frac((gid + float2(sA * 61.0, sB * 47.0))
                       * float2(0.1031, 0.1030));
      hq += dot(hq, hq.yx + 33.33);
      float gh = frac((hq.x + hq.y) * hq.x);
      // 网格内jitter(每粒位置hash偏移) — 消规则网格棋盘感(风主#9530)
      float2 jit = (float2(frac(hq.x * 73.13 + sA * 5.0),
                           frac(hq.y * 97.71 + sB * 7.0)) - 0.5) * 0.55;
      float2 gc = frac(gp) - 0.5 + jit;
      float gs = 0.24 + 0.16 * gh;               // 大颗(参照糖霜粒)
      float grain = smoothstep(gs, gs * 0.30, length(gc))
                  * step(0.42, gh);              // 58%格有粒(密集)
      float2 gp2 = fp * 46.0 + float2(sA * 7.0, sB * 13.0);
      float2 hq2 = frac(floor(gp2) * float2(0.1031, 0.1030));
      hq2 += dot(hq2, hq2.yx + 33.33);
      float gh2 = frac((hq2.x + hq2.y) * hq2.x);
      float grain2 = step(0.68, gh2)
                  * step(length(frac(gp2) - 0.5), 0.10 + 0.09 * gh2);
      // 边缘透光带(胶体内辉光, 风主: 只是本体色加亮, 勿白) + Q弹呼吸
      float rim = smoothstep(0.45, 0.98, edge);
      float breathe = 0.85 + 0.15 * sin(uTime * 3.2 + sd * 6.2832);
      col = base * (0.72 + 0.20 * ndl) * faceLit;      // 糖体
      col -= base * (1.0 - rim) * 0.18;                // 中心略深(果冻厚度)
      col += base * 1.45 * rim * 0.30 * breathe;       // 边缘=本体加亮(无白)
      col += float3(1.0, 1.0, 1.0) * grain * (0.70 + 0.30 * gh);   // 糖霜大粒
      col += float3(1.0, 1.0, 1.0) * grain2 * 0.45;                // 细粒层
      col += float3(1.0, 1.0, 1.0) * pow(ndh, 24.0) * 0.50;        // 糖面高光点
      col += base * 1.20 * bev * 0.35 * faceLit;       // 棱线(本体亮, 去白)
      a = aCell * 0.88;                                // 厚实果冻轻半透
    } else {                            // 金属: 阳极氧化(满饱和+面间强反差+染色镜面)
      float br = sin(fp.y * 84.0 + sd * 4.0) * 0.5 + 0.5;
      float br2 = sin(fp.y * 250.0) * 0.5 + 0.5;
      float brush = 0.82 + 0.18 * lerp(br, br2, 0.5);   // 拉丝明暗
      float spec = pow(ndh, 26.0) * brush;
      float3 mb = base;                         // 阳极氧化: 满饱和(同软糖)
      // 面间强反差(参照: 受光面亮饱和/背光面深饱和) + 环境亮带
      float band = smoothstep(-0.15, 0.25, Np.y) * 0.45 + 0.55;
      col = mb * band * faceLit * (0.85 + 0.25 * ndl);
      col += lerp(float3(1.0, 1.0, 1.0), mb, 0.55) * spec * 3.0;    // 镜面(55%染色保饱和)
      col += mb * fres * 0.45;
      col += lerp(float3(1.0, 1.0, 1.0), mb, 0.35) * bev * 0.50 * faceLit;  // 棱线受光(染色)
      col = lerp(col, sceneR * lerp(float3(1.0, 1.0, 1.0), mb, 0.45) * 1.10,
               0.32 + 0.24 * fres);             // 镜面反射(R向环境+天空上偏)
      // 饱和度补偿: 镜面/反射混白后resaturate(参照阳极氧化浓彩)
      float mtLum = dot(col, float3(0.299, 0.587, 0.114));
      col = lerp(float3(mtLum, mtLum, mtLum), col, 1.35);
      a = aCell;
    }
    if(fxFin){   // 消除特效透明度(风主#2077钦定): 0.18起步线性渐变到0消失
      a *= 0.18 * vLifeRatio;
    }
  }
}]]

-- VS注入(@vs_type_deform): 块(alpha>=0.5)=Ry(-0.25)+pitch(-0.17)倾角
-- (风主钦定: 左右+上下都反向, 露出方块顶部+右面; blockPx=0.34补偿投影);
-- 空格/幽灵(alpha<0.5, pdF(base+20)读出生/repaint真值)=
-- 不倾不正对屏幕平贴(底格); fx按extra2.x模式做几何动画(融化压扁/
-- 爆炸自旋/缩小塌缩/透明微膨胀/雾化膨胀趋球)。
local VS_INJECT = [[
{
  // type守卫: 读SSBO裸类型(pdF(base+16)=注册type, 勿用vType
  // — 那是uBehaviorAlias行为域id(17)恒≠注册type) + 槽段双重校验
  float tTy = pdF(base + 16);
  if(texIdxF_early >= TET_SLOT0 && texIdxF_early <= TET_SLOT0 + 5.0
     && tTy == float(TET_TYPE)){
    float tVA = pdF(base + 20);
    // per块稳定种子: tag(base+28)低16位=c+r*256每块唯一恒定 — angVel.y
    // 种子槽可能被物理CS消费/清零(所有块颗粒图案相同根因#9530)
    // (GLSL mod(a,b)→a-b*floor(a/b) 规范§4: fmod截断语义负数不同禁用)
    float tagVal = pdF(base + 28);
    float tagS = tagVal - 65536.0 * floor(tagVal / 65536.0);
    // 材质随机种子(风主#2077): varParams user通道(particle.set_params
    // 实时写, 每次设置材质lua重摇) — vSeed=块位+matSeed → 木纹/糖霜/
    // 拉丝图案随每次材质设置重新随机(非位置固定); fvidx=本块材质变体
    // (随机材质模式per组材质各自取种子); SSBO数据变化零shader重编译
    float matSeed = varParams[TET_TYPE * 1024 + fvidx * 4 + 3].x;
    if(tagS > 0.5) vSeed = frac(tagS / 65536.0 + matSeed);
    if(tVA >= 0.5){
      float tVCy = cos(-0.25), tVSy = sin(-0.25);
      mpos = float3(tVCy * mpos.x + tVSy * mpos.z, mpos.y,
                    -tVSy * mpos.x + tVCy * mpos.z);
      mnor = float3(tVCy * mnor.x + tVSy * mnor.z, mnor.y,
                    -tVSy * mnor.x + tVCy * mnor.z);
      mnorTrue = float3(tVCy * mnorTrue.x + tVSy * mnorTrue.z, mnorTrue.y,
                        -tVSy * mnorTrue.x + tVCy * mnorTrue.z);
      pitch = -0.17;
      roll = 0.0;
      // 悬停格颤动(风主#9624终版钦定): 只旋转不改位置, 绕方块自身中心 —
      // 通用管线L1262 rp=Rz(roll)*Rx(pitch)*mpos, mpos=块局部顶点(原点=块
      // 中心) → roll直接绕中心摆, 零位移。5Hz左右摆±8°; user.y=鼠标处格
      // tag+1(setHover实时写, SSBO零重编译), 离开=0即恢复。
      // 槽位: fvidx*4+3=user(vec4, 同vSeed行)
      float hovTag = varParams[TET_TYPE * 1024 + fvidx * 4 + 3].y;
      if(hovTag > 0.5 && tagS > 0.5 && tagS + 1.0 == hovTag){
        float hph = frac(tagS / 65536.0 * 7.13) * 6.2832;
        roll = 0.1396 * sin(31.4159 * uTime + hph);   // 5Hz×2π, ±8°
      }
    } else {
      pitch = 0.0;
      roll = 0.0;
    }
  } else if(texIdxF_early >= FX_SLOT0 && texIdxF_early <= FX_SLOT0 + 4.0){
    float tVFx = pdF(base + 24);
    float tVLr = clamp(pdF(base + 7)
                       / max(pdF(base + 10), 1e-4), 0.0, 1.0);
    if(tVFx > 0.5 && tVFx < 2.5){
      mpos.y *= 0.15 + 0.85 * tVLr;
      size *= 0.92 + 0.08 * tVLr;
    } else if(tVFx > 2.5 && tVFx < 3.5){
      roll = uTime * (2.5 + frac(seed * 0.731) * 4.5) + seed;
      pitch = 0.5 + frac(seed * 0.373) * 1.3;
    } else if(tVFx > 3.5 && tVFx < 4.5){
      roll = uTime * 3.0 + seed * 7.0;         // 白闪核心自旋
      pitch = 0.5;
    } else if(tVFx > 4.5 && tVFx < 5.5){
      size *= tVLr * tVLr * 1.05 + 0.02;
    } else if(tVFx > 5.5 && tVFx < 6.5){
      size *= 1.0 + (1.0 - tVLr) * 0.55;
    } else if(tVFx > 6.5){
      size *= 1.0 + (1.0 - tVLr) * 3.6;
      float tVSph = lerp(1.0, 0.42, 1.0 - tVLr);
      mpos *= float3(tVSph, tVSph, 0.35 + 0.65 * tVSph);
    }
  }
}
]]

-- CS注入(cs_mesh_physics): fx粒子per-mode重力/阻力(fxM=extra2.x)
-- 守卫: behavior域type=17 + texIdx槽段(p.typeColor.y)
local CS_INJECT = [[
if(type == 17u){
  float tiC = p.typeColor.y;
  // type守卫同FS/VS注入(槽段漂移防误染)
  if((p.typeColor.x == float(TET_TYPE) || p.typeColor.x == float(FX_TYPE))
     && tiC >= TET_SLOT0 && tiC <= FX_SLOT0 + 4){
    float fxM = p.extra2.x;
    if(p.extra3.y < 0.5 && fxM >= 1.0){
      windFactor = 0.0; turbFactor = 0.0;
      if(fxM < 2.5){       gravity = 9.0 * cellPx; drag = 0.010; }
      else if(fxM < 3.5){  gravity = 24.0 * cellPx; drag = 0.004; }
      else if(fxM < 4.5){  gravity = 0.0;  drag = 0.0; }
      else if(fxM < 5.5){  gravity = 0.0;  drag = 0.0; }
      else if(fxM < 6.5){  gravity = -2.6 * cellPx; drag = 0.012; }
      else {               gravity = -3.5 * cellPx; drag = 0.014; }
    }
  }
}]]

function Board.setShaderInjects(retry)
  local slots = Board.texSlots or {}
  local fslots = Board.fxSlots or {}
  local base = slots[0]
  local fbase = fslots[0]
  if not base or not fbase then return end
  local cell = (Board.visGeo and Board.visGeo.cell) or 54
  -- 重试标记: cpp侧setLuaInject对相同内容幂等(不gen++不重建) — 编译
  -- 失败后同内容重提交=零动作, 注入永不重试(平面方块永久服役根因)。
  -- 自愈路径追加HLSL注释改变内容 → 强制走重建管线重编译。
  local mark = "\n// blockai mat v36 (hover终版: 只绕中心旋转5Hz±8°, 零位移) \n"
  if retry and retry > 0 then
    mark = mark .. "\n// blockai inject retry " .. retry .. "\n"
  end
  local tyId, ftyId = tostring(Board.typeId), tostring(Board.fxTypeId)
  local code = (PBR_INJECT:gsub("TET_SLOT0", tostring(base))
                          :gsub("FX_SLOT0", tostring(fbase))
                          :gsub("TET_TYPE", tyId)
                          :gsub("FX_TYPE", ftyId)) .. mark
  local ok1 = false
  local r1 = rpc("shader", "set_inject",
      { hook = "fs_paper_color", code = code, id = "blockai" })
  if r1 and r1.ok ~= false then ok1 = true
  else print("[block-ai] PBR注入失败: " .. tostring(r1 and r1.error or r1)) end
  local vsCode = (VS_INJECT:gsub("TET_SLOT0", tostring(base))
                              :gsub("FX_SLOT0", tostring(fbase))
                              :gsub("TET_TYPE", tyId)
                              :gsub("FX_TYPE", ftyId)) .. mark
  local r2 = rpc("shader", "set_inject",
      { hook = "vs_type_deform", code = vsCode, id = "blockai_vs" })
  if not (r2 and r2.ok ~= false) then
    print("[block-ai] VS注入失败: " .. tostring(r2 and r2.error or r2))
  end
  local r3 = rpc("shader", "set_inject",
      { hook = "cs_mesh_physics",
        -- cellPx量化到4px步进: RT/imgRect轻微抖动不改变注入内容
        -- (内容变化=gen++=全粒子组重编译, 多秒旧程序服役窗口=闪烁/变
        -- 角度根因; 4px内重力差异不可感知)
        code = ((CS_INJECT:gsub("TET_SLOT0", tostring(base))
                          :gsub("FX_SLOT0", tostring(fbase))
                          :gsub("TET_TYPE", tyId)
                          :gsub("FX_TYPE", ftyId)
                           :gsub("cellPx", string.format("%.2f",
                                    math.floor(cell / 4 + 0.5) * 4))) .. mark),
        id = "blockai_cs" })
  if not (r3 and r3.ok ~= false) then
    print("[block-ai] CS注入失败: " .. tostring(r3 and r3.error or r3))
  end
  Board.pbrOk = ok1
end

function Board.clearPbrInject()
  rpc("shader", "set_inject",
      { hook = "fs_paper_color", code = "", id = "blockai" })
  rpc("shader", "set_inject",
      { hook = "vs_type_deform", code = "", id = "blockai_vs" })
  rpc("shader", "set_inject",
      { hook = "cs_mesh_physics", code = "", id = "blockai_cs" })
  Board.pbrOk = false
end

-- ── 材质随机种子重摇(可选, 风主#2077): varParams user通道(variant 0-3=
-- 可见材质)写入新随机值 → VS注入vSeed混入 → 木纹/糖霜/拉丝图案
-- 整板重摇(per块仍互异); SSBO数据变化零shader重编译即时生效。
-- ⚠默认不调用(user=0=无偏移=原始图案): 自动重摇会改变已认可外观 —
-- 仅经RPC block-ai.reseed_material显式触发。
Board.matSeed = 0        -- user.x=材质图案种子(setHover写user时同源保留)
Board.hoverTag1 = 0      -- user.y=悬停格tag+1(c+r*256+1; 0=无悬停, #9624)
function Board.reseedMat()
  if not Board.typeOk or not Board.typeId then return end
  Board.matSeed = math.random()
  for v = 0, 3 do
    rpc("particle", "set_params",
        { type = Board.typeId, variant = v,
          user = { Board.matSeed, Board.hoverTag1, 0, 0 } })
  end
end

-- 悬停格(风主#9624): 鼠标处方块轻微颤动 — tag+1写user.y(全variant同源,
-- 随机材质per组variant也能命中), VS注入按tag匹配+uTime微抖; 0=停抖
function Board.setHover(col, row)
  local t = (col >= 0 and row >= 0) and (col + row * 256 + 1) or 0
  if t == Board.hoverTag1 then return end
  Board.hoverTag1 = t
  if not Board.typeOk or not Board.typeId then return end
  for v = 0, 3 do
    rpc("particle", "set_params",
        { type = Board.typeId, variant = v,
          user = { Board.matSeed, t, 0, 0 } })
  end
end

-- ── 几何: pos=居中世界系(x∈±rtW/2, y∈±rtH/2, y向上; VS投影同域) ──────────
-- bio网格=图片级常量(源图不变则不变): 按源图尺寸缓存, 避免每tick
-- bio_grid_info owner同步RPC把tick拖死(owner忙时250ms×N=on_render
-- 永久skipped=HUD消失, 实测)。world_info为廉价直读(无owner同步)。
Board.bioCache = nil   -- {key=imgW*2^20+imgH, dim, mn, mx, cellX/Y/Z, diag}

function Board.refreshGeometry()
  local w = rpc("particle", "world_info", {})
  local m = w and w.main
  if not m or not m.rtH or m.rtH <= 0 then return false end
  local rtH, sizeBase = m.rtH, m.sizeBase or 1080
  local imgRT = m.imgRect   -- {minX,minY,w,h} 居中世界系图片内容矩形
  if not (imgRT and imgRT[3] > 1 and imgRT[4] > 1) then return false end
  local imgW = fcc.env_get("viewer.imageW") or 0
  local imgH = fcc.env_get("viewer.imageH") or 0
  -- bio网格缓存(源图维度变化才重取owner)
  local bioKey = imgW * 2 ^ 20 + imgH
  if not (Board.bioCache and Board.bioCache.key == bioKey) then
    -- owner忙(shader后台编译)让路(风主#9622): bio_grid_info=owner同步RPC,
    -- 忙时250ms阻塞持lua锁=on_render跳帧面板闪烁; 下个0.5s周期重试
    if Board.ownerBusy() then return false end
    local r = rpc("particle", "bio_grid_info", {})
    local b = r and r.main
    if not b or not b.enabled then return false end
    local dim, mn, mx = b.dim, b.min, b.max
    Board.bioCache = {
      key = bioKey, dim = dim, mn = mn, mx = mx,
      cellX = (mx[1] - mn[1]) / dim[1],
      cellY = (mx[2] - mn[2]) / dim[2],
      cellZ = (mx[3] - mn[3]) / dim[3],
    }
    Board.bioCache.diag = math.sqrt(
        Board.bioCache.cellX ^ 2 + Board.bioCache.cellY ^ 2
        + Board.bioCache.cellZ ^ 2)
  end
  local bio = Board.bioCache
  -- 位置格宽=图片内容高/20(与锚点归一化同源): 缩放时锚点按图片矩形
  -- 精确缩放, 旧格与新格零错位(风主钦定#9511: 方块发射后固定不变,
  -- 跟随图片自然缩放, 不rebuild不重摆)。
  -- blockPx与位置格宽解耦=宇宙常数(见visGeo注释): 所有方块(无论何时
  -- 出生)屏上尺寸恒等且∝图片高度, 零重算; 旧方案blockPx含出生期
  -- rtH比值 → 缩放后新旧块尺寸互异=算不对大小根因。
  local cell = imgRT[4] / 20
  local bhPx = cell * 20
  -- 居中世界系: 棋盘水平居中(x中心=0), 纵向=图片高度居中(yTop=图片顶)
  -- (VS投影 clip=pos/(rt/2), 出生y必须居中 — 底上制坐标会分裂两截)
  local yTop = bhPx / 2
  local bz = math.min(bio.dim[3] - 1, math.floor(bio.dim[3] * 0.86))
  Board.visGeo = {
    x0 = -cell * 5, yTop = yTop,
    cell = cell, bw = 10, bh = 20,
    boardW = cell * 10, boardH = bhPx,
    -- blockPx=半边长(mesh size语义)。出生定死(风主铁令: 只发射一次,
    -- 永不重算): blockPx=0.0238×imgRect.h(间隙=方块1/20: drawn/cell=
    -- 20/21≈0.952), 换图rebuild时随新图取值。缩放跟随由CS增量等比承担
    -- (b1p: size×=√(vs×vsY)与b4水花同式) — 无锚无每帧重算, 天然跟随图片。
    blockPx = 0.0238 * imgRT[4],
    z = bio.mn[3] + (bz + 0.5) * bio.cellZ,
    imgRect = imgRT,
    -- geoKey=源图原始像素(仅换图触发rebuild): 缩放只变显示尺寸,
    -- 锚点定位自动跟随 — 方块出生后固定零重建(风主铁令#9501)
    geoKey = math.floor(imgW) * 2 ^ 39 + math.floor(imgH) * 2 ^ 26,
  }
  Board.bio = {
    mn = bio.mn, dim = bio.dim,
    cellX = bio.cellX, cellY = bio.cellY, cellZ = bio.cellZ,
    cellDiag = bio.diag,
  }
  Board.geo = Board.visGeo
  return true
end

-- (col,row 0基; row0=顶部) → world x,y (居中世界系, y向上)
function Board.cellWorld(col, row)
  local g = Board.visGeo
  return g.x0 + (col + 0.5) * g.cell, g.yTop - (row + 0.5) * g.cell
end


-- ══ 静态格子调和(#9472/#9445/#9455/#9480四令合一): 棋盘格=方块本体 ═══
-- 200个固定格子粒子出生一次(位置/尺寸定死, 永不移动永不死亡=鱼管线);
-- 每tick board数组+active/ghost → 每格期望态 → set_state批量窄写差异格
-- — 常规tick零kill零spawn零move。全格同一方块材质(#9480): 只用色相/
-- 亮度/透明度区分 — 空=黑色a0.2 锁定=块色相a1(p1阻挡) 下落=块色相
-- 增亮a1(p2驱离) 幽灵=块色相a0.16(p3)。
-- 渲染层=数据纯函数: 数组是唯一真相, 粒子被动repaint收敛。
Board.statSnap = Board.statSnap or { calls = 0, items = 0, err = "none" }
Board.cellState = Board.cellState or {}  -- [idx]=已发送期望态{v,h,l,p}
Board.cellQ = Board.cellQ or {}          -- 格子出生批队列(50格/批)
local CELL_TAG = 0x300000                -- tag段: 0x300000+c+r*256

-- 20f条目构造(k为items浮点游标闭包由调用方管理)
-- alpha: 出生透明度(spawn flags.w; -1=缺省1) — 半透出生消除先实心后修正闪现
local function emitItem(items, k, x, y, z, size, ty, variant, tag,
                        pin, hue, light, fx1, rgb, alpha)
  rgb = rgb or BLOCK_HEX[0]
  items[k + 1] = x; items[k + 2] = y; items[k + 3] = z
  items[k + 4] = size
  items[k + 5] = 0; items[k + 6] = 0; items[k + 7] = 0
  items[k + 8] = 1e9
  items[k + 9] = ty; items[k + 10] = variant
  items[k + 11] = -1; items[k + 12] = tag
  items[k + 13] = pin; items[k + 14] = hue
  items[k + 15] = light; items[k + 16] = alpha or -1
  items[k + 17] = fx1; items[k + 18] = rgb[1]
  items[k + 19] = rgb[2]; items[k + 20] = rgb[3]
  return k + 20
end

-- 格子出生入队: 200格÷50格/批(4帧铺完, 防大批出生峰值); 出生即休眠空格
-- 出生顺序=绘制序(风主钦定: 先下后上, 先左后右 — 倾角下上/右近, 近后
-- 画覆盖远)。机制: cs_mesh_sort排序键按16px深度带粗化, 全格z恒等
-- (g.z)恒同band → 同band按槽位id决胜(出生分配序) → 绘制序≡出生序;
-- 不透明材质另走真深度通道像素级遮挡(ensureType set_mesh_depth_mode)。
-- 锚点=出生时世界坐标÷当帧uImgContent归一化(cs_lua_spawn计算存储),
-- b1p每帧按活体imgRect绝对定位 — 全屏切换/缩放零重建零重摆(风主铁令
-- #9501: 方块发射后固定不变, 跟随图片自然缩放)。
local function queueCells()
  if Board.cellsQueued then return end
  local g, b = Board.visGeo, Board.bio
  local items, k = {}, 0
  for r = 19, 0, -1 do
    for c = 0, 9 do
      local x, y = Board.cellWorld(c, r)
      k = emitItem(items, k, x, y, g.z, g.blockPx, Board.typeId, 0,
                    CELL_TAG + c + r * 256, 3, 0, 0,
                    b.cellDiag * 1.5, BLOCK_HEX[0], 0.2)
      if k >= 50 * 20 then
        Board.cellQ[#Board.cellQ + 1] = items
        items, k = {}, 0
      end
    end
  end
  if k > 0 then Board.cellQ[#Board.cellQ + 1] = items end
  Board.cellsQueued = true
end

-- 期望态纯函数: rows数组+active/ghost叠加 → 200格{v,h,l,p,a}
-- 风主钦定(#9480): 全格同一方块材质(variant=matId), 只用色相/亮度/
-- 透明度区分格态 — 空格=淡蓝低alpha棋盘底, 幽灵=块色相半透, 锁定/
-- 下落=块色相不透明; 材质切换=全板repaint同一variant。
-- matId==4=随机材质: **按组**(每个tetromino同一材质, 风主#9548) —
-- 组id=块seq(board值高位/active.seq), 确定性hash(grp)取0-3,
-- 同组4格恒同材质, 下落/锁定前后一致。
local MAT_HASH = function(grp)
  local s = math.sin((grp or 0) * 12.9898 + 78.233 + 99.5) * 43758.5453
  return math.floor((s - math.floor(s)) * 4)
end
Board.MAT_HASH = MAT_HASH

local function buildWant(game, rows, matId, visible)
  local want = {}
  if visible then
    -- rm作用域=整个buildWant(锁定/下落/幽灵三循环共用): 声明在锁定循环
    -- 内曾致下落循环(784)取全局nil → reconcile每tick抛错中止=playing
    -- 期间方块永不显示(暂停/结束才显示)的根因
    local rm = (matId == 4) and -1 or matId   -- -1=per组随机
    for r = 0, 19 do
      local br = rows[r + 1]
      for c = 0, 9 do
        local t = br[c + 1]
        if t then
          local ty = t % 8                    -- 解包type(低3位)
          local v = (rm >= 0) and rm or MAT_HASH(math.floor(t / 8))
          want[c + 1 + r * 10] = { v = v, h = HUES[ty] or HUES[0],
                                    l = BLOCK_L[ty] or 0.62, p = 1, a = 1 }
        end
      end
    end
    local a = game.active
    if a and game.state == "playing" then
      local hueA = HUES[a.type] or HUES[0]
      local lA = (BLOCK_L[a.type] or 0.62) + 0.07
      local vA = (rm >= 0) and rm or MAT_HASH(a.seq or 0)
      for _, cc in ipairs(game:activeCells()) do
        want[cc[1] + 1 + cc[2] * 10] = { v = vA, h = hueA, l = lA,
                                          p = 2, a = 1 }
      end
      local gy = game:ghostY()
      if gy and gy ~= a.y then
        for _, cc in ipairs(game:activeCells(
            { type = a.type, rot = a.rot, x = a.x, y = gy })) do
          local i = cc[1] + 1 + cc[2] * 10
          if not want[i] then
            local gv = (rm >= 0) and rm or 0   -- 幽灵variant(随机材质用0)
            want[i] = { v = gv, h = hueA, l = 0.70, p = 3, a = 0.05 }
          end
        end
      end
    end
  end
  return want
end

local function sameState(s, v, h, l, p, a)
  return s and s.v == v and s.h == h and s.l == l and s.p == p and s.a == a
end

function Board.reconcile(game)
  if not Board.visGeo or not Board.typeOk or not game then return end
  local ok, ret = pcall(function()
    local g = Board.visGeo
    local m = (_G.BLOCKAI.state and _G.BLOCKAI.state.matId) or 0
    -- ① 分批出生格子(每tick一批); 出生未完成前不paint(set_state只写
    -- 活粒子, 早到的paint会丢且账本误记=永久错格)
    if not Board.cellsQueued then queueCells() end
    -- kill窗口护栏: kill_type为排队消费(每type 3重发帧, 连发多type
    -- 依次清场) — kill窗口内重铺=新批被兜杀成洞且账本误记永久缺格。
    -- killAll/rebuildCells后停25tick(≈0.42s)再出生。
    if Board.spawnHold and Board.spawnHold > 0 then
      Board.spawnHold = Board.spawnHold - 1
      return false
    end
    if #Board.cellQ > 0 then
      -- 先验队首再消费: 失败(类型未注册/系统忙)不丢批, 有限重试
      local r = rpc("particle", "spawn_batch",
                    { items = Board.cellQ[1] })
      if not (r and r.ok) then
        Board.statSnap.err = "cellspawn: " .. tostring(r and r.error)
        -- 不丢批(旧版120tick=2s放弃 → boot期全粒子组冷编译0.3~7s占住
        -- owner线程, 批中途被放弃=该批50格永久消失, 实测底部9行整体缺失);
        -- 批留在队首逐tick重试, 失败RPC即时返回代价可忽略, 停止游戏时
        -- tick退订自然停止
        return false
      end
      table.remove(Board.cellQ, 1)
      Board.cellRetry = 0
      return true   -- 剩余批下tick继续
    end
    -- ② 期望态 → 差异repaint(set_state批量窄写)
    local rows = game:boardSnapshot()
    if not rows then return false end
    local want = buildWant(game, rows, m, Board.visible3d)
    -- 空格variant(m=4时用0, 其余=m) — 发送与账本共用, 谨防两处不同源
    local v0 = (m == 4) and 0 or m
    local items = {}
    local k = 0
    local dirty = {}
    local nd = 0
    for r = 0, 19 do
      for c = 0, 9 do
        local i = c + 1 + r * 10
        local w = want[i]
        -- 空格: 黑色×0.05(近全透, 风主#2077: 明亮海面/天空背景下棋盘
        -- 退到几乎不可见 — 对齐r40_full_now认可观感); 随机材质(4)空格用
        -- variant 0(与r30_fs_after一致)。⚠账本记录必须与发送值同源(v0)
        local v, h, l, p, a = v0, 0, 0.0, 3, 0.05
        if w then v, h, l, p, a = w.v, w.h, w.l, w.p, w.a end
        if not sameState(Board.cellState[i], v, h, l, p, a) then
          nd = nd + 1
          -- 单帧差异预算: 超100格只发前100(账本只记已发格, 未发格state
          -- 未更新→下tick重算仍dirty自动续发)。消行下移的大批量窄写
          -- 不再挤爆渲染线程6ms lua锁窗口(on_render跳帧=UI闪烁根因)。
          if nd <= 100 then
            dirty[nd] = i
            -- 条目12f: match(type,tag,0,0)+attrs(v,h,l,p)+attrs2(alpha,0,0,0)
            k = k + 12
            items[k - 11] = Board.typeId
            items[k - 10] = CELL_TAG + c + r * 256
            items[k - 9] = 0; items[k - 8] = 0
            items[k - 7] = v; items[k - 6] = h
            items[k - 5] = l; items[k - 4] = p
            items[k - 3] = a; items[k - 2] = 0
            items[k - 1] = 0; items[k] = 0
          end
        end
      end
    end
    if nd > 100 then nd = 100 end   -- 截断尾格: 帐本只记已发送的dirty前100
    if nd > 0 then
      local r = rpc("particle", "set_state", { items = items })
      if not (r and r.ok) then
        Board.statSnap.err = "set_state: " .. tostring(r and r.error)
        return false
      end
      for di = 1, nd do
        local i = dirty[di]
        local w = want[i]
        -- 账本记录实际发送值(空格=v0, 与上方发送同源 — 记m会让随机材质
        -- 空格永久dirty)
        Board.cellState[i] = w or { v = v0, h = 0, l = 0.0, p = 3, a = 0.05 }
      end
    end
    Board.statSnap.calls = Board.statSnap.calls + 1
    Board.statSnap.items = nd
    Board.statSnap.dirtyN = nd
    Board.statSnap.err = "none"
    return true
  end)
  if not ok then
    Board.statSnap.err = tostring(ret):sub(1, 200)
  end
  return ok
end

-- 兼容旧调用名(main.lua迁移期)
Board.snapshot = Board.reconcile


-- ── fx消除特效: 被消除方块本体材质动画(风主#9530钦定: 用被消除方块
-- 本身的材质做旋转/缩放/透明) ────────────────────────────────────
-- 每格=1主块+1~2子块, 全部fxTypeId原材质variant=mat+原块色相/亮度;
-- VS注入fxM模式驱动旋转(爆炸自旋)/缩放(融化压扁/塌缩/膨胀)/形变
-- (雾化趋球), FS fxFin统一寿命淡入淡出(透明), CS注入per模式重力。
Board.pendingFx = {}

local function enqFx(col, row, sizeRel, vx, vy, life, mat, hue, light,
                     fxM, jx, jy)
  Board.pendingFx[#Board.pendingFx + 1] =
      { col = col, row = row, sizeRel = sizeRel, vx = vx, vy = vy,
        life = life, mat = mat, hue = hue, light = light,
        fxM = fxM or 0, jx = jx or 0, jy = jy or 0 }
end

-- cells={{col,row,typeIdx},...}; 速度单位=格/秒; 原材质方块≤3粒/格
-- 参数确定性(风主: 消除效果不要动态随机): 全部随机量=hash(col,row,k),
-- 同格每次消除效果恒定, 不同格自然差异
local function fh(col, row, k)
  local s = math.sin(col * 12.9898 + row * 78.233 + k * 43.123) * 43758.5453
  return s - math.floor(s)
end

function Board.fx3D(cells, fxId, mat)
  if not Board.typeOk or not Board.visGeo then return end
  local m = mat or (_G.BLOCKAI.state and _G.BLOCKAI.state.matId) or 0
  for _, c in ipairs(cells) do
    local col, row, t = c[1], c[2], c[3] or 0
    local hue = HUES[t] or HUES[0]
    local lit = BLOCK_L[t] or 0.62
    -- 随机材质按组(c[4]=组id, 与格子本体同源 → 消除动画材质=原块材质)
    local mm = (m == 4) and MAT_HASH(c[4] or 0) or m
    if fxId == 0 then          -- 融化: 主块压扁下坠 + 2糖浆滴块
      enqFx(col, row, 1.0, 0, -0.55, 0.75, mm, hue, lit, 1)
      for d = 1, 2 do
        enqFx(col, row, 0.28 + 0.10 * fh(col, row, d),
              (fh(col, row, d + 4) - 0.5) * 1.2, -0.5,
              0.60, mm, hue, lit, 1,
              (fh(col, row, d + 8) - 0.5) * 0.6, 0.12 * d)
      end
    elseif fxId == 1 then      -- 爆炸: 主块自旋飞散 + 2小块自旋
      enqFx(col, row, 1.0, (fh(col, row, 1) - 0.5) * 1.6,
            0.9 + fh(col, row, 2) * 1.2, 0.62, mm, hue, lit, 3)
      for f = 1, 2 do
        enqFx(col, row, 0.24 + 0.10 * fh(col, row, f),
              (fh(col, row, f + 4) - 0.5) * 3.2,
              0.7 + fh(col, row, f + 8) * 1.6,
              0.55, mm, hue, lit, 3,
              (fh(col, row, f + 12) - 0.5) * 0.7,
              (fh(col, row, f + 16) - 0.5) * 0.4)
      end
    elseif fxId == 2 then      -- 缩小: 主块塌缩 + 1小块
      enqFx(col, row, 1.0, 0, 0, 0.42, mm, hue, lit, 5)
      enqFx(col, row, 0.30, (fh(col, row, 1) - 0.5) * 1.0, 0.3,
            0.35, mm, hue, lit, 5, (fh(col, row, 2) - 0.5) * 0.5, 0.1)
    elseif fxId == 3 then      -- 透明: 主块升腾淡出(微膨胀) + 1小块
      enqFx(col, row, 1.0, 0, 0.8, 0.70, mm, hue, lit, 6)
      enqFx(col, row, 0.34, (fh(col, row, 1) - 0.5) * 0.6, 1.1,
            0.55, mm, hue, lit, 6, (fh(col, row, 2) - 0.5) * 0.4, 0.2)
    else                       -- 雾化: 主块膨胀趋球淡出 + 1小块(0.6s, 风主#9556)
      enqFx(col, row, 1.0, 0, 0.5, 0.60, mm, hue, lit, 7)
      enqFx(col, row, 0.36, (fh(col, row, 1) - 0.5) * 0.8, 0.7,
            0.45, mm, hue, lit, 7, (fh(col, row, 2) - 0.5) * 0.6, 0.2)
    end
  end
end


-- fx批泵(每tick≤150项分帧摊薄): spawn_batch自生自灭
-- (单批JSON峰值>6ms会占住lua锁→渲染线程on_render跳帧=UI闪烁, 故分帧)
function Board.flushFx()
  local q = Board.pendingFx
  if #q == 0 then return end
  local ok, ret = pcall(function()
    local g = Board.visGeo
    if not g then return false end
    local n = math.min(#q, 150)
    local items = {}
    local k = 0
    local z0 = g.z + 0.35 * g.cell   -- 格子同板面(+0.35cell前方浮出)
    for i = 1, n do
      local it = q[i]
      local x, y = Board.cellWorld(it.col, it.row)
      x = x + it.jx * g.cell
      y = y + it.jy * g.cell
      items[k + 1] = x; items[k + 2] = y; items[k + 3] = z0
      items[k + 4] = g.blockPx * it.sizeRel
      items[k + 5] = it.vx * g.cell; items[k + 6] = it.vy * g.cell
      items[k + 7] = 0
      items[k + 8] = it.life
      items[k + 9] = Board.fxTypeId; items[k + 10] = it.mat
      items[k + 11] = -1
      items[k + 12] = CELL_TAG + it.col + it.row * 256  -- per位置tag→稳定种子
      items[k + 13] = 0; items[k + 14] = it.hue
      items[k + 15] = it.light; items[k + 16] = -1
      items[k + 17] = it.fxM; items[k + 18] = 0
      items[k + 19] = 0; items[k + 20] = 0
      k = k + 20
    end
    if k > 0 then
      local r = rpc("particle", "spawn_batch", { items = items })
      if not (r and r.error == nil) then
        Board.statSnap.err = "fx: " .. tostring(r and r.error)
      end
    end

    for i = 1, n do q[i] = nil end
    local j = 0
    for i = n + 1, #q do j = j + 1; q[j] = q[i]; q[i] = nil end
    return true
  end)
  if not ok then
    Board.statSnap.err = "fx: " .. tostring(ret):sub(1, 200)
    Board.pendingFx = {}
  end
end

-- ── 格子换血: 几何变化(RT/网格/换图)后重建200格 ─────────────────────────
-- 格子位置/尺寸出生定死 → 几何变化必须换血(游戏board数据无损, 4帧重铺);
-- 只杀块type(fx自生自灭, 槽位type不受影响), 账本复位后reconcile自动
-- 重queue新几何出生+按board数组repaint全量恢复。
function Board.rebuildCells()
  if Board.typeId then
    rpc("particle", "kill_type", { type = Board.typeId })
  end
  Board.cellState = {}
  Board.cellQ = {}
  Board.cellsQueued = nil
  Board.spawnHold = 25   -- kill重发窗口内不重铺(防新批被兜杀)
end

-- ── 停止清理(扩展关闭/重启): kill_type全清+格子状态账本复位 ───────────────
function Board.killAll()
  if Board.typeId then
    rpc("particle", "kill_type", { type = Board.typeId })
  end
  if Board.slotTypeId then
    rpc("particle", "kill_type", { type = Board.slotTypeId })
  end
  if Board.fxTypeId then
    rpc("particle", "kill_type", { type = Board.fxTypeId })
  end
  Board.pendingFx = {}
  Board.cellState = {}
  Board.cellQ = {}
  Board.cellsQueued = nil
  Board.spawnHold = 25   -- kill重发窗口内不重铺(防新批被兜杀)
end

-- ── 发射器保障 ───────────────────────────────────────────────────────────
-- ① 鱼: bio网格激活需behavior=6发射器在场。
-- ② 方块对抗保留发射器(emitRate=0): 渲染实例窗/物理窗口按emitter配额计算。
function Board.ensureFish()
  -- keepEmitter(渲染实例窗保障): emitters.add=owner同步RPC, 编译期让路
  -- (风主#9622: 忙时250ms阻塞持lua锁=面板闪烁; 空闲再补)
  if Board.typeId and not Board.keepEmitterId
      and not Board.ownerBusy() then
    local ek = rpc("particle", "emitters.add",
                   { type = Board.typeId, maxParticles = 4000,
                     emitRate = 0 })
    if ek and ek.id and ek.id >= 0 then Board.keepEmitterId = ek.id end
  end
  -- bio网格就绪: 首选bioCache(refreshGeometry维护, enabled才落地, 图片级
  -- 缓存) — 旧版每次直调bio_grid_info(main+fs两个owner同步, 忙时500ms
  -- 阻塞×pendingStart每0.5s重试 = 编译期面板持续闪烁元凶, 风主#9622)
  if Board.bioCache then return true end
  if Board.ownerBusy() then return false end
  local r = rpc("particle", "bio_grid_info", {})
  local m = r and r.main
  if m and m.enabled then return true end
  if not Board.fishEmitterId then
    local e = rpc("particle", "emitters.add",
                  { type = 6, maxParticles = 3, emitRate = 0.3 })
    if e and e.id and e.id >= 0 then
      Board.fishEmitterId = e.id
    end
  end
  return false
end

function Board.removeOwnFish()
  if Board.fishEmitterId then
    rpc("particle", "emitters.remove", { id = Board.fishEmitterId })
    Board.fishEmitterId = nil
  end
  if Board.keepEmitterId then
    rpc("particle", "emitters.remove", { id = Board.keepEmitterId })
    Board.keepEmitterId = nil
  end
end

return Board
