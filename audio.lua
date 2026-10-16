-- ============================================================================
-- audio.lua — BGM + 音效封装 (audio域; 资产=扩展包assets/, debug.getinfo
-- 自定位绝对路径 — 本地扩展目录可装在任意位置, resolvePath绝对路径透传)
-- 音量架构(风主#9605): 音效音量volSfx只作用于SFX(每play即乘); BGM=volBgm
-- 独立直调(不受音效滑条影响)。sfxVol读state.volSfx, 缺省0(静音安全)。
-- 不动引擎全局master(那是全部音频含视频播放器的总闸, 扩展无权改)。
-- ============================================================================
-- 原地刷新模块(热重载协议: 保bgmId/开关等数据, 重定义函数)
_G.BLOCKAI = _G.BLOCKAI or {}
local Audio = _G.BLOCKAI.Audio
if not Audio then Audio = {}; _G.BLOCKAI.Audio = Audio end
if Audio.sfxOn == nil then Audio.sfxOn = true end
if Audio.musicOn == nil then Audio.musicOn = true end
  -- 音乐开关语义(风主#9605修): volBgm>0即开乐(开局自动响, 无需手调滑块);
  -- volBgm=0时startBgm被音量检查拦截=静音。musicOn仅作滑条代码兼容标记。

local _src = debug.getinfo(1, "S").source
local _this = (_src:sub(1, 1) == "@") and _src:sub(2) or _src
local A = ((_this:match("^(.*)[\\/]") or "."):gsub("\\", "/")
             .. "/assets/")
local function rpc(d, o, a) return fcc.rpc(d, o, a) end

local function clamp01(v)
  if type(v) ~= "number" then return 0 end
  return math.max(0.0, math.min(1.0, v))
end

-- 音效音量: 唯一来源=state.volSfx(风主#9605: 只管SFX), 缺失/类型错→0(静音安全)
function Audio.sfxVol()
  local st = _G.BLOCKAI.state
  return clamp01(st and st.volSfx)
end

function Audio.play(name, vol)
  if not Audio.sfxOn then return end
  rpc("audio", "play", { path = A .. name .. ".wav",
                         volume = clamp01(vol or 1.0) * Audio.sfxVol() })
end

function Audio.startBgm(vol)
  if Audio.bgmId then return end
  local v = vol
  if type(v) ~= "number" then
    v = (_G.BLOCKAI.state and _G.BLOCKAI.state.volBgm) or 0
  end
  -- BGM=volBgm独立直调(风主#9605): >0即放(开局自动有音乐), 0=静音不放
  v = clamp01(v)
  if v <= 0.001 then Audio.musicOn = false return end
  Audio.musicOn = true
  -- BGM=贝多芬月光奏鸣曲(风主#9602): SMF→宿主audio域midiOut通道(循环)
  local r = rpc("audio", "play",
                { path = A .. "Beethoven-Moonlight-Sonata.mid",
                  volume = v, loop = true })
  if r and r.ok then Audio.bgmId = r.id end
end

-- BGM实时调音(滑条变化即响应; 独立于音效音量)
function Audio.applyVolume(v)
  if type(v) ~= "number" then return end
  if Audio.bgmId then
    rpc("audio", "volume", { id = Audio.bgmId, value = clamp01(v) })
  end
end

function Audio.stopBgm()
  if Audio.bgmId then
    rpc("audio", "stop", { id = Audio.bgmId })
    Audio.bgmId = nil
  end
end

function Audio.shutdown()
  Audio.stopBgm()
  rpc("audio", "stop_all", {})
end

return Audio
