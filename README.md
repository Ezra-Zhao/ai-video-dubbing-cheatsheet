# 🎙️ AI Video Dubbing Cheatsheet · AI 视频多语种配音速查表

Multilingual video dubbing workflows that actually survived production: Whisper → cloud TTS → ffmpeg → subtitles, with the real pitfalls and fixes.

**Full cheatsheets, one per language (written natively, not translated):**
- [中文版 DUBBING.zh.md](DUBBING.zh.md)
- [English DUBBING.en.md](DUBBING.en.md)
- [Español DUBBING.es.md](DUBBING.es.md)
- [Português DUBBING.pt.md](DUBBING.pt.md)

Runnable pipeline scripts live in [`scripts/`](scripts/).

---

## 中文
60 条多语种技术讲解视频的实战配音流水线：Whisper 转录/翻译、云 TTS 配音、ffmpeg 混音与字幕烧录。
覆盖空音频坑的自动检测、长文本分段、响度归一化、横竖版裁剪、成本与耗时估算。
每版独立成文，直给命令和参数，不讲废话。

## English
The dubbing pipeline behind 60 multilingual tech-explainer videos (ZH/EN/ES/PT/HI, landscape + portrait).
Covers Whisper transcription/translation, cloud TTS dubbing, ffmpeg mixing and subtitle burn-in.
Empty-audio auto-detection, long-text chunking, loudness normalization, portrait cropping, cost/time estimation.
Each language version is written natively — commands first, no fluff.

## Español
El flujo de doblaje detrás de 60 videos técnicos multilingües (ZH/EN/ES/PT/HI, horizontal + vertical).
Cubre transcripción/traducción con Whisper, doblaje con TTS en la nube, mezcla con ffmpeg e incrustación de subtítulos.
Detección automática de audios vacíos, segmentación de textos largos, normalización de volumen, recorte vertical, estimación de costos y tiempos.
Cada idioma está redactado de forma nativa: comandos primero, sin relleno.

## Português
O pipeline de dublagem por trás de 60 vídeos técnicos multilíngues (ZH/EN/ES/PT/HI, horizontal + vertical).
Cobre transcrição/tradução com Whisper, dublagem com TTS em nuvem, mixagem com ffmpeg e queima de legendas.
Detecção automática de áudios vazios, segmentação de textos longos, normalização de volume, recorte vertical, estimativa de custo e tempo.
Cada idioma foi escrito de forma nativa: comandos primeiro, sem enrolação.

## 日本語
60 本の多言語技術解説動画を支えた吹き替えパイプライン（中国語/英語/スペイン語/ポルトガル語/ヒンディー語、横型＋縦型）。
Whisper による文字起こし・翻訳、クラウド TTS による吹き替え、ffmpeg によるミックスと字幕焼き付けを収録。
空オーディオの自動検出、長文分割、ラウドネス正規化、縦型クロップ、コスト・時間見積もり付き。
各言語版はネイティブに執筆——コマンド優先、無駄なし。

## 한국어
60편의 다국어 기술 설명 영상을 만든 더빙 파이프라인(중국어/영어/스페인어/포르투갈어/힌디어, 가로+세로).
Whisper 전사/번역, 클라우드 TTS 더빙, ffmpeg 믹싱과 자막 입히기를 다룹니다.
빈 오디오 자동 감지, 장문 분할, 라우드니스 정규화, 세로 크롭, 비용·시간 추정을 포함합니다.
각 언어판은 네이티브로 작성—명령어 우선, 군더더기 없음.

## Русский
Конвейер дубляжа, на котором сделано 60 многоязычных технических видео (китайский/английский/испанский/португальский/хинди, альбомный + вертикальный формат).
Whisper для транскрибации/перевода, облачный TTS для озвучки, ffmpeg для сведения и вжигания субтитров.
Автодетект пустого аудио, разбивка длинных текстов, нормализация громкости, вертикальный кроп, оценка затрат и времени.
Каждая языковая версия написана носителем стиля — сначала команды, без воды.

---

## License

MIT — see [LICENSE](LICENSE).

> All content is original, written clean-room by the author.
