---
name: debug-server
description: fcc debug-server HTTP调试接口使用指南。当需要运行/调试fcc扩展（--run）、截屏验证UI（窗口级/全屏/区域截图）、查询ImGui窗口几何、模拟键鼠输入、执行lua代码操纵扩展状态、查看日志时使用。触发词：fcc截图、debug-server、fcc调试、验证UI、窗口截图、fcc扩展调试。
---

# fcc debug-server

fcc.exe 启动时加 `--debug-server <端口>`（默认8620，多实例时各用不同端口避冲突）：

```
D:\work\fcc\build\Release\fcc.exe <图片> --run <扩展名> --debug-server 8623
```

## 截图（关键！按场景选端点）

**验证单个UI面板 → 首选窗口级截图（不受DPI缩放影响）**：
```
curl -s "http://127.0.0.1:PORT/window_screenshot?name=<URL编码的窗口显示名>" -o panel.png
```
窗口名先用 `/ui_windows` 查 `name` 字段（显示名，非含###的全名）。输出PNG直接read查看，尺寸=窗口原始像素。

**查询所有ImGui窗口几何（面板是否渲染/位置/大小）**：
```
curl -s "http://127.0.0.1:PORT/ui_windows"
```
返回 windows[]: {name, full_name, pos, size, visible, collapsed}。

**全屏/区域截图**：`GET /screenshot?x=&y=&w=&h=[&fmt=bmp|png]` — 渲染帧抓取。
⚠️ 坑：输出按DPI缩放（如3840×2160屏→1347×758），小面板文字看不清，验证面板布局勿用，用window_screenshot。

**全屏粒子(FS)层**（独立RT+DComp层，/screenshot抓不到）：`GET /fs_screenshot`。

**截图落盘到指定文件（RPC域）**：`POST /rpc/app/screenshot` body=`{"path":"D:/xx.png"}`。

## 操纵扩展状态

- `POST /lua` body=lua代码（?timeout=ms）：读写 _G.<扩展> 全局状态，如启动游戏 `g:startPlaying(); g.state='playing'`。⚠️ 勿在帧外调ImGui函数。
- `POST /input` body=`{"type":"mouse_click","x":..,"y":..}` 或 key_press/type_text：模拟键鼠。
- lua的print输出 → `GET /log` / `GET /log/tail?n=50` / `GET /log/search?q=关键词` 查看。

## 其他端点

- `GET /health` 存活+版本+帧号；`GET /`或`/help` 全部接口说明
- `POST /restart?args=<新参数>` 重启进程
- `GET|POST /env`、`/env/<name>` 环境字段
- `POST /action/<name>`、`GET /actions` 注册动作
- `POST /rpc/<domain>/<op>` body=JSON：各扩展RPC域
- `GET /original_image[?info=1]` 原图数据

## 典型工作流（UI布局验证）

1. daemon启动fcc（--debug-server 新端口）
2. `/health`确认就绪 → `/lua`把扩展切到目标状态
3. `/ui_windows`确认面板visible+pos/size
4. `/window_screenshot?name=<面板名>`截图 → read查看像素细节
5. 迭代修改lua扩展（fcc支持热重载lua watcher）→ 重复3-4
6. 验证完 `stop <daemon_id>` 清理
