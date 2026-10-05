# 🎙️ AI 视频多语种配音速查表（中文版）

> 实战来源：60 条多语种技术讲解视频（6 个项目 × 中/英/西/葡/印地 5 语言 × 16:9 + 9:16 双版），
> 每条 7 段：5 段技术讲解 + 中场中国文化卡 + 片尾祝福页。
> 流水线：讲稿 → Whisper（校对）→ 云 TTS 配音 → ffmpeg 混音 → 字幕烧录 → 双版渲染。

---

## 0. 流水线总览（7 步）

```
1. 讲稿定稿（按段落拆分，每段独立计时）
2. TTS 配音 → 每段一个 mp3（分段！不要整篇一次喂）
3. 音频质检（空音频/静音检测，见第 3 节）
4. ffmpeg 响度归一化 + 变速对齐时长
5. 混音（配音 + 背景音乐，ducking）
6. 字幕生成与烧录（SRT → ASS 双语）
7. 双版渲染：16:9 横版 / 9:16 竖版裁剪
```

**黄金法则：**
- 一段一文件：`seg01_intro.zh.mp3`，流水线按段并行，出错只重跑一段。
- 时长预算先行：先定每段目标秒数，再调语速/文案去凑，不要反过来。
- 永远保留无字幕母版，烧字幕是最后一步。

---

## 1. Whisper：转录 / 翻译 / 时间戳

### 1.1 基础转录（校对已有讲稿 / 从样片扒时间轴）

```bash
# 中文转录，输出 srt + 词级时间戳
whisper audio.mp3 --model large-v3 --language zh \
  --task transcribe --output_format srt --word_timestamps True \
  --output_dir ./subs

# 英文翻译（把任何语言翻成英文）
whisper audio.mp3 --model large-v3 --task translate --output_format srt
```

### 1.2 多语言关键参数

| 参数 | 说明 | 实战取值 |
|---|---|---|
| `--language` | 源语言，不写则自动检测（慢且可能误判） | `zh` / `en` / `es` / `pt` / `hi`，**永远显式指定** |
| `--task` | `transcribe` 转录 / `translate` 翻成英文 | 校对讲稿用 transcribe |
| `--model` | tiny/base/small/medium/large-v3 | 终版用 `large-v3`，草稿用 `medium` 省一半时间 |
| `--initial_prompt` | 术语提示词，纠正专有名词 | `"以下是云原生与可观测性技术讲座，包含 Prometheus、Grafana、Kubernetes 等术语。"` |
| `--condition_on_previous_text` | 上文条件，关掉可减少幻觉复读 | 长音频设 `False` |
| `--word_timestamps True` | 词级时间戳（字幕对齐用） | 配音对口型/卡点必须开 |
| `--vad_filter` | faster-whisper 的 VAD，跳过静音段 | 长讲座开，省 20–40% 时间 |

### 1.3 长音频与幻觉控制

```bash
# faster-whisper：VAD + 批量，速度快 4 倍
python3 - <<'EOF'
from faster_whisper import WhisperModel
model = WhisperModel("large-v3", device="cuda", compute_type="float16")
segments, info = model.transcribe(
    "lecture.mp3",
    language="zh",
    vad_filter=True,                     # 跳过静音
    vad_parameters=dict(min_silence_duration_ms=500),
    condition_on_previous_text=False,    # 防幻觉复读
    initial_prompt="云原生技术讲座，术语：Prometheus、Grafana、Kubernetes",
    word_timestamps=True,
)
for s in segments:
    print(f"[{s.start:.2f}->{s.end:.2f}] {s.text}")
EOF
```

**坑：**
- Whisper 对音乐/片头曲会"幻觉"出歌词——片头片尾先用 ffmpeg 切掉再转录。
- 中英混读时 `--language zh` 会把英文词硬转成中文谐音；混读严重的讲稿用 `--language en` 跑一遍再人工合并。
- 时间戳漂移：超过 10 分钟的音频，词级时间戳尾部会飘 ±1s，字幕按句级时间戳 + 手动微调。

---

## 2. 云 TTS 配音（以 VoiceStudio 这类云 TTS 为例）

### 2.1 多语言 voice 选择

| 语言 | 选择原则 | 实战备注 |
|---|---|---|
| 中文 | 母语 neural 女声/男声，普通话 | 语速 0.95–1.0 最稳，太快吞字 |
| 英语 | 美音/英音按受众定 | 技术讲解用美音，语速 1.0 |
| 西语 | 拉美口音 vs 半岛口音二选一 | **全片统一，不要混** |
| 葡语 | 巴西葡语 vs 欧洲葡语二选一 | **全片统一，不要混** |
| 印地语 | 确认 voice 支持天城文输入 | 有些 voice 只认拉丁转写，先测一句 |

### 2.2 语速 / 停顿控制（SSML）

```xml
<speak>
  <prosody rate="0.95" pitch="+0%">
    这是正文，语速稍慢更清楚。
  </prosody>
  <break time="600ms"/>
  <prosody rate="1.0">
    这是第二段，段落之间留 600 毫秒呼吸感。
  </prosody>
</speak>
```

- 逗号靠 TTS 引擎自然停顿；**段落/章节切换必须手写 `<break>`**，否则听感赶。
- 中场休息卡这种过渡句，单独成段 + 800ms break，听感完全不一样。

### 2.3 长文本分段策略（核心）

```
规则：
1. 按句切分，绝不在逗号中间断开
2. 中文单段 ≤ 200 字；英文/西/葡单段 ≤ 300 字符
3. 每段独立调用 TTS，独立文件：seg01.mp3, seg02.mp3...
4. 拼接时段与段之间插入 300ms 静音：
```

```bash
# 生成 300ms 静音
ffmpeg -f lavfi -i anullsrc=r=48000:cl=stereo -t 0.3 -q:a 9 -acodec libmp3lame silence_03.mp3 -y
# 按顺序拼接（filelist.txt 每行：file 'seg01.mp3' / file 'silence_03.mp3' ...）
ffmpeg -f concat -safe 0 -i filelist.txt -c copy full_dub.mp3 -y
```

**为什么必须分段：** 整篇一次喂给云 TTS，轻则超时截断，重则后半段语速漂移、重音错乱。60 条视频全部按段配音，零翻车。

### 2.4 空音频坑：检测 + 替换（本仓库最值钱的一节）

**现象（实测，稳定复现）：** 某些短语 TTS 会返回"成功"但音频文件是空的/全静音。
例如西语过渡句 `Tomemos un respiro.`（让我们歇口气）在某云 TTS 上**稳定生成空音频**，
换成 `Tomemos un descanso.` 就正常；同场景另一项目的 `Hagamos una pausa.` 也正常。

**检测（配音后必跑，见 `scripts/check_audio.py`）：**

```bash
# 快速检测：时长 ≈ 0 或文件过小
ffprobe -v error -show_entries format=duration,size -of csv=p=0 seg03.mp3

# 静音检测：整段静音超过 90% 判为坏文件
ffmpeg -i seg03.mp3 -af silencedetect=noise=-30dB:d=0.5 -f null - 2>&1 | grep silencedetect
```

**处理流程：**
1. 配音脚本每段生成后立即检测，坏段自动重试 3 次（指数退避）。
2. 3 次仍坏 → 查"黑名单短语替换表"，换措辞重配。
3. 把触发坏段的短语记入黑名单，下次直接避开。

**黑名单替换表示例（西语）：**

| 坏短语 | 替换 |
|---|---|
| `Tomemos un respiro.` | `Tomemos un descanso.` / `Hagamos una pausa.` |

> 教训：TTS 的文本前端对特定短语组合有 bug，与语义无关。不要跟它讲道理，换措辞是最便宜的解法。
> 每种语言维护自己的黑名单，跨项目复用。

---

## 3. ffmpeg：混音 / 响度 / 变速 / 烧字幕 / 裁剪

### 3.1 音频提取与合并

```bash
# 从成片提取音频（检查用）
ffmpeg -i final.mp4 -vn -ac 2 -ar 48000 audio.wav -y

# 配音 + 视频合并（视频流直接复制，不重编码）
ffmpeg -i video_silent.mp4 -i dub.mp3 -c:v copy -map 0:v:0 -map 1:a:0 -shortest out.mp4 -y

# 配音 + 背景音乐混音（音乐压到 -20dB，配音优先）
ffmpeg -i dub.mp3 -i bgm.mp3 -filter_complex \
  "[1:a]volume=0.15[bg];[0:a][bg]amix=inputs=2:duration=first:dropout_transition=2" \
  -c:a aac -b:a 192k mixed.m4a -y
```

### 3.2 响度归一化（多段拼接后必须做）

```bash
# 第一遍：测量
ffmpeg -i full_dub.mp3 -af loudnorm=print_format=json -f null - 2>&1 | grep -A12 Parsed_loudnorm

# 第二遍：按测量值归一化（把 JSON 里的 measured_* 填进去）
ffmpeg -i full_dub.mp3 -af \
  "loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=-19.2:measured_TP=-3.1:measured_LRA=7.5:measured_thresh=-29.4:offset=0.83:linear=true" \
  -ar 48000 dub_norm.mp3 -y
```

- 目标：网络视频用 `I=-16 LUFS`；多段不同 voice/不同次配音，响度不统一听感很廉价。
- 单遍 `loudnorm`（不测直接压）会动态压限，音质损失大，**正式成片永远用双遍**。

### 3.3 变速不变调（配音时长对齐画面）

```bash
# 加速 1.2 倍（音调不变）
ffmpeg -i dub.mp3 -af "atempo=1.2" dub_fast.mp3 -y

# atempo 单滤镜范围 0.5–2.0，超出要串联：
ffmpeg -i dub.mp3 -af "atempo=1.5,atempo=1.5" dub_225.mp3 -y   # = 2.25x
```

- 实战区间：0.9–1.15 超出这个范围听感就假，**优先改文案字数而不是硬拉速度**。
- 经验公式：中文配音约 4–4.5 字/秒，英文约 2.5–3 词/秒，倒推文案字数。

### 3.4 字幕烧录（SRT → 硬字幕）

```bash
# SRT 直烧（样式内联）
ffmpeg -i out.mp4 -vf \
  "subtitles=sub.srt:force_style='FontName=Noto Sans CJK SC,FontSize=22,PrimaryColour=&H00FFFFFF,OutlineColour=&H90000000,BorderStyle=1,Outline=2,Shadow=0,MarginV=45'" \
  -c:a copy final_sub.mp4 -y

# 双语字幕：先用 ASS（见第 4 节），再烧
ffmpeg -i out.mp4 -vf "ass=sub_bilingual.ass" -c:a copy final_sub.mp4 -y
```

**字体坑（实测）：** 多语言混排（汉字 + 拉丁 + 天城文）时，系统缺字形会烧出"口口口"。
烧录前必须做字形覆盖检查：

```bash
# 检查字体是否覆盖所需字符（fc-match 看回退链）
fc-match "Noto Sans CJK SC" --verbose | grep -i charset | head -3
# 终极方案：ASS 里按语言分 Style 指定不同字体，或用 Noto 全家桶
```

### 3.5 横竖版裁剪（16:9 ↔ 9:16）

```bash
# 16:9 横版 → 9:16 竖版（居中裁剪，1080x1920）
ffmpeg -i landscape.mp4 -vf \
  "crop=ih*9/16:ih,scale=1080:1920" -c:a copy portrait.mp4 -y

# 关键内容不在中央时，手动定裁剪起点 x:y
ffmpeg -i landscape.mp4 -vf "crop=607:1080:656:0,scale=1080:1920" -c:a copy portrait.mp4 -y

# 字幕位置：竖版 MarginV 要加大，否则被平台 UI 遮挡
# force_style 里 MarginV=120（竖版）vs MarginV=45（横版）
```

---

## 4. 字幕：SRT 要点 / 双语排版 / 时间轴微调

### 4.1 SRT 格式（错一个空行就全崩）

```
1
00:00:01,000 --> 00:00:04,500
第一行字幕

2
00:00:05,000 --> 00:00:08,000
第二行字幕

```
- 时间格式 `HH:MM:SS,mmm`，注意是**逗号**不是点。
- 每条之间** exactly 一个空行**，文件末尾也要空行。
- 每行 ≤ 20 个汉字 / ≤ 42 个英文字符；单条时长 ≤ 7 秒。

### 4.2 双语字幕（ASS）

```ini
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.50,Top,,0,0,0,,{\fnNoto Sans CJK SC}原文第一行\N{\fnNoto Sans}Second line translation
```

- `\N` 硬换行；原文在上、译文在下是通用排版。
- 竖版视频字幕放上方（`Alignment=8`），避开底部点赞/评论区。

### 4.3 时间轴微调

```bash
# 整体平移 +500ms（配音比画面慢半拍时）
ffmpeg -itsoffset 0.5 -i sub.srt -c copy sub_shifted.srt -y

# 批量逐条微调：用 python 按比例缩放时间轴（见 scripts/）
# 经验：TTS 分段拼接后，累计误差约每分钟 ±0.3s，长视频按段对齐不要按全片对齐
```

---

## 5. 批量流水线脚本

`scripts/` 下有两个可跑脚本：

| 脚本 | 功能 |
|---|---|
| `dub_pipeline.sh` | 端到端：分段 TTS 配音（含重试）→ 空音频检测 → 静音拼接 → loudnorm → 混音 → 输出母版。支持 `--dry-run` 预演 |
| `check_audio.py` | 音频质检：时长/文件大小/静音占比三重检测，坏段列清单 |

```bash
# 预演（不调 API，只打印将要执行的步骤）
./scripts/dub_pipeline.sh --dry-run --lang es --segments ./segments/

# 正式跑（需要 export TTS_API_KEY=...）
./scripts/dub_pipeline.sh --lang es --segments ./segments/ --out ./output/

# 单独质检一批配音
python3 scripts/check_audio.py ./segments/es/*.mp3
```

---

## 6. 成本与耗时估算

### 6.1 耗时模型（60 条视频实测量级）

| 环节 | 耗时（每分钟成片） | 说明 |
|---|---|---|
| 讲稿撰写/定稿 | 人力主导 | 最大的时间黑洞，单独排期 |
| TTS 配音 | 约 0.5–1× 时长 | API 并发 3–5 路，瓶颈在网络 |
| Whisper 转录校对 | GPU 约 0.3× / CPU 约 3–5× | large-v3 + VAD |
| ffmpeg 渲染 | 约 0.5–2× | 烧字幕要重编码，最慢的一步 |
| 人工质检 | 约 1× | 必须完整听一遍，快进听会漏空音频 |

### 6.2 费用估算思路

```
TTS 费用 ≈ 总字符数 × 单价/千字符
  └─ 先统计：wc -m DUBBING.*.md 级别的讲稿字符数
  └─ 中场/片尾固定段落只配一次，多语言版本复用音频（省！）

Whisper 本地跑 = 0 元（电费除外）；云 API 按分钟计费
ffmpeg = 0 元
```

### 6.3 免费额度预警（70% / 90%）

- 每月 1 号记录各云 TTS 剩余额度，脚本里加计数器：每配一段累加字符数。
- 用到 70% 发预警（还能撑几天？），90% 停新任务，只跑修复。
- **固定段落（片头/中场/片尾）音频跨视频复用**，是省额度最有效的一招。

---

## 7. 实战坑点 Top 8

| # | 坑 | 症状 | 解法 |
|---|---|---|---|
| 1 | **空音频** | TTS 返回成功但文件无声（特定短语稳定复现，如西语 `Tomemos un respiro.`） | 配音后必跑 `check_audio.py`；黑名单短语替换表 |
| 2 | **字体方框** | 多语言字幕烧出"口口口"（天城文/生僻汉字） | 烧录前 fc-match 查字形覆盖；ASS 按语言分 Style |
| 3 | **整篇喂 TTS** | 超时截断 / 后半段语速漂移 | 按句分段 ≤200 字，段间 300ms 静音拼接 |
| 4 | **响度不一** | 多段拼接听感忽大忽小 | 双遍 loudnorm 统一到 -16 LUFS |
| 5 | **竖版字幕被遮** | 9:16 烧完字幕被平台 UI 挡住 | MarginV 加大 / 字幕放上方 |
| 6 | **Whisper 幻觉** | 片头音乐转出歌词 | 先切掉片头片尾再转录；`condition_on_previous_text=False` |
| 7 | **时长对不上** | 配音比画面长/短 | 先定秒数倒推字数（中文 4–4.5 字/秒）；atempo 只微调 0.9–1.15 |
| 8 | **中场/片尾超时** | 固定段落越做越长（中文曾到 30–36 秒） | 给固定段落设硬时长预算，文案按秒数字数卡死 |

---

*本文件为作者实战原创（clean-room 编写），命令均经生产环境验证。*
