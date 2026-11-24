# Abyss 录制与调试工具

这些脚本通过本地 UrhoX 运行器的离屏截图模式驱动录制入口（`scripts/record.lua`），在项目根目录运行。

## 环境变量

| 变量 | 说明 |
|---|---|
| `URHOX_RUN` | 运行器，默认 `tools/run-local.sh`（本地开发环境提供）。调用方式为 `<runner> shot <frame>`，通过环境变量 `ENTRY`（入口脚本）、`W` / `H`（窗口尺寸）、`SHOT`（截图路径）、`TIMEOUT` 传参 |
| `ABYSS_SAVE_DIR` | 引擎本地存档目录。游戏脚本只能写相对路径（引擎沙盒），帧序列会写到这个目录下，脚本从这里读取 |

## 脚本

| 脚本 | 作用 |
|---|---|
| `render.sh <name> <w> <h> <fps> <秒> <sub> <分段数> [起始秒]` | 逐帧渲染 PNG 序列并用 ffmpeg 合成 `.tmp/<name>.mp4`；分段数大于 1 时并行渲染 |
| `one.sh <t> <out.png> [debug] [w] [h]` | 渲染巡航路径上第 t 秒的单帧；`debug` 传 Lua 表，如 `"{1,0,0,0}"` 关雾，`"{0,1,0,0}"` 看法线，`"{0,3,0,0}"` 看步进次数 |
| `sheet.sh [起始] [间隔] [帧数] [w] [h] [sub]` | 沿巡航路径等间隔取帧，拼成联系表 `.tmp/sheet.png` |

```bash
tools/abyss/render.sh preview 640 270 30 30 1 2       # 30 s 低清预览
tools/abyss/render.sh final 2560 1080 60 30 4 3       # 2560×1080 · 60 fps · 每帧 4 次子采样 + 180° 快门
```

## 注意

- `sub > 1` 时每个视频帧累积多次子像素抖动采样，采样时刻分布在快门时间内（运动模糊）；`sub = 1` 时走实时 TAA。
- 改了 `assets/Shaders/BLGL/Abyss/*` 之后，第一次运行要重新编译着色器。先单进程跑一次 `one.sh` 再并行，
  避免多个进程同时写生成文件导致编译失败。
- 渲染进行中不要修改 `scripts/` 与 `assets/`：引擎会热重载着色器，后面的帧会和前面不一致。
- GL 后端回读的图像是自下而上的行序，`record.lua` 里的 `flipY` 负责翻转。
