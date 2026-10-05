# 🎙️ Guía de doblaje multilingüe con IA (Español)

> Probado en producción con 60 videos técnicos multilingües (6 proyectos × ZH/EN/ES/PT/HI × 16:9 + 9:16).
> Cada video: 5 segmentos técnicos + tarjeta cultural intermedia + página final de bendición.
> Flujo: guion → Whisper (control de calidad) → doblaje con TTS en la nube → mezcla con ffmpeg → incrustación de subtítulos → render en dos formatos.

---

## 0. El flujo en 7 pasos

```
1. Guion cerrado (dividido en segmentos, con presupuesto de segundos por segmento ANTES de escribir)
2. Doblaje TTS → un mp3 por segmento (¡fragmenta! nunca alimentes el guion entero de una vez)
3. Control de calidad del audio (detección de audios vacíos, ver §3)
4. Normalización de volumen + ajuste de velocidad con ffmpeg
5. Mezcla (doblaje + música de fondo, atenuada)
6. Subtítulos (SRT → ASS bilingüe)
7. Doble render: 16:9 horizontal / 9:16 vertical
```

**Reglas de oro:**
- Un segmento, un archivo: `seg01_intro.es.mp3`. Paraleliza por segmento; un fallo solo repite un segmento.
- Primero los segundos, después las palabras. Ajusta el texto/la velocidad al tiempo, nunca al revés.
- Guarda siempre un máster limpio sin subtítulos. La incrustación es el último paso.

---

## 1. Whisper: transcripción / traducción / marcas de tiempo

### 1.1 Transcripción básica

```bash
# Transcripción en español con marcas de tiempo por palabra
whisper audio.mp3 --model large-v3 --language es \
  --task transcribe --output_format srt --word_timestamps True \
  --output_dir ./subs

# Traducir cualquier idioma al inglés
whisper audio.mp3 --model large-v3 --task translate --output_format srt
```

### 1.2 Parámetros clave multilingües

| Parámetro | Qué hace | Valor en producción |
|---|---|---|
| `--language` | Idioma origen; la detección automática es lenta y falla | `es`/`en`/`pt`/`zh`/`hi` — **siempre explícito** |
| `--task` | `transcribe` vs `translate` (al inglés) | transcribe para revisar el guion |
| `--model` | tiny → large-v3 | `large-v3` para la versión final, `medium` para borradores (mitad de tiempo) |
| `--initial_prompt` | Pista de terminología, corrige nombres propios | `"Charla de observabilidad cloud-native. Términos: Prometheus, Grafana, Kubernetes."` |
| `--condition_on_previous_text` | Condicionamiento con texto previo; desactivado reduce alucinaciones | `False` en audios largos |
| `--word_timestamps True` | Marcas por palabra | Imprescindible para sincronizar subtítulos |
| `--vad_filter` | VAD de faster-whisper, salta silencios | Activado en charlas largas, ahorra 20–40% |

### 1.3 Audios largos y control de alucinaciones

```bash
python3 - <<'EOF'
from faster_whisper import WhisperModel
model = WhisperModel("large-v3", device="cuda", compute_type="float16")
segments, info = model.transcribe(
    "charla.mp3",
    language="es",
    vad_filter=True,
    vad_parameters=dict(min_silence_duration_ms=500),
    condition_on_previous_text=False,   # elimina repeticiones alucinadas
    initial_prompt="Charla cloud-native. Términos: Prometheus, Grafana, Kubernetes",
    word_timestamps=True,
)
for s in segments:
    print(f"[{s.start:.2f}->{s.end:.2f}] {s.text}")
EOF
```

**Trampas:**
- Whisper alucina letras de canciones sobre la música de intro/outro — recórtala con ffmpeg antes de transcribir.
- Las marcas por palabra derivan ±1s al final de audios de más de 10 min; alinea por frase y ajusta a mano.
- Acento latino vs peninsular: Whisper los maneja, pero **no mezcles acentos en un mismo video**; el oído lo nota al instante.

---

## 2. Doblaje con TTS en la nube (servicios tipo VoiceStudio como ejemplo)

### 2.1 Elección de voz por idioma

| Idioma | Regla | Nota de producción |
|---|---|---|
| Español | Acento latinoamericano O peninsular — elige UNO | **Nunca mezcles en un video** |
| Portugués | Brasileño O europeo — elige UNO | **Nunca mezcles en un video** |
| Inglés | Americano o británico según la audiencia | Americano para tutoriales técnicos, velocidad 1.0 |
| Chino | Voz neural nativa en mandarín | Velocidad 0.95–1.0; más rápido se come caracteres |
| Hindi | Verifica que la voz acepte devanagari | Algunas solo aceptan transliteración latina — prueba una frase primero |

### 2.2 Velocidad y pausas (SSML)

```xml
<speak>
  <prosody rate="1.0" pitch="+0%">
    Narración principal a ritmo natural.
  </prosody>
  <break time="600ms"/>
  <prosody rate="0.95">
    Más lento en la transición: 600ms de respiro entre secciones.
  </prosody>
</speak>
```

- Las comas ya generan pausas naturales; **los cambios de sección necesitan `<break>` manual** o suena apresurado.
- Las frases de transición ("tomemos un descanso") merecen su propio segmento + 800ms de pausa.

### 2.3 Fragmentación de textos largos (técnica central)

```
Reglas:
1. Corta por frases — nunca en mitad de una cláusula
2. ≤ 300 caracteres por fragmento (ES/PT/EN); ≤ 200 en chino
3. Una llamada TTS por fragmento, un archivo cada uno: seg01.mp3, seg02.mp3...
4. Inserta 300ms de silencio entre fragmentos al concatenar:
```

```bash
ffmpeg -f lavfi -i anullsrc=r=48000:cl=stereo -t 0.3 -q:a 9 -acodec libmp3lame silence_03.mp3 -y
# filelist.txt: file 'seg01.mp3' / file 'silence_03.mp3' / ...
ffmpeg -f concat -safe 0 -i filelist.txt -c copy full_dub.mp3 -y
```

**Por qué fragmentar es obligatorio:** alimentar el guion entero al TTS en la nube arriesga tiempos de espera agotados, truncados y — peor — ritmo a la deriva y acentos mal puestos en la segunda mitad. Los 60 videos se doblaron por segmentos. Cero fallos.

### 2.4 La trampa del audio vacío: detectar + reemplazar (la sección más valiosa)

**Síntoma (reproducido de forma fiable):** ciertas frases hacen que el TTS devuelva "éxito" con un archivo vacío o en silencio.
Caso real: la transición en español `Tomemos un respiro.` **generaba sistemáticamente audio vacío** en un proveedor de TTS en la nube. `Tomemos un descanso.` funciona bien; `Hagamos una pausa.` (usado en otro proyecto) también.

**Detección (obligatoria tras cada doblaje, ver `scripts/check_audio.py`):**

```bash
# Chequeo rápido: duración ≈ 0 o archivo sospechosamente pequeño
ffprobe -v error -show_entries format=duration,size -of csv=p=0 seg03.mp3

# Detección de silencio: >90% en silencio = archivo defectuoso
ffmpeg -i seg03.mp3 -af silencedetect=noise=-30dB:d=0.5 -f null - 2>&1 | grep silencedetect
```

**Flujo de recuperación:**
1. El script de doblaje verifica cada segmento al momento; los defectuosos reintentan 3 veces con espera exponencial.
2. Si tras 3 intentos sigue mal → consulta la lista negra de frases, reformula y vuelve a doblar.
3. Registra la frase problemática en la lista negra para evitarla la próxima vez.

**Lista negra (español):**

| Frase problemática | Reemplazo |
|---|---|
| `Tomemos un respiro.` | `Tomemos un descanso.` / `Hagamos una pausa.` |

> Lección: el frontend de texto del TTS tiene errores con combinaciones específicas de frases — no es cuestión de significado. No discutas con él; reformular es la solución más barata. Mantén una lista negra por idioma y reutilízala entre proyectos.

---

## 3. ffmpeg: mezcla / volumen / velocidad / subtítulos / recorte

### 3.1 Extraer y unir

```bash
ffmpeg -i final.mp4 -vn -ac 2 -ar 48000 audio.wav -y   # extraer para control de calidad

# Unir doblaje con video (copia el video sin recodificar)
ffmpeg -i video_silent.mp4 -i dub.mp3 -c:v copy -map 0:v:0 -map 1:a:0 -shortest out.mp4 -y

# Doblaje + música de fondo (música a -20dB, bajo la voz)
ffmpeg -i dub.mp3 -i bgm.mp3 -filter_complex \
  "[1:a]volume=0.15[bg];[0:a][bg]amix=inputs=2:duration=first:dropout_transition=2" \
  -c:a aac -b:a 192k mixed.m4a -y
```

### 3.2 Normalización de volumen (obligatoria tras concatenar segmentos)

```bash
# Pasada 1: medir
ffmpeg -i full_dub.mp3 -af loudnorm=print_format=json -f null - 2>&1 | grep -A12 Parsed_loudnorm

# Pasada 2: normalizar con los valores medidos
ffmpeg -i full_dub.mp3 -af \
  "loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=-19.2:measured_TP=-3.1:measured_LRA=7.5:measured_thresh=-29.4:offset=0.83:linear=true" \
  -ar 48000 dub_norm.mp3 -y
```

- Objetivo `I=-16 LUFS` para video web. Segmentos de distintas voces/sesiones suenan baratos sin esto.
- El `loudnorm` de una sola pasada aplica limitación dinámica y degrada la calidad — **siempre dos pasadas en la versión final**.

### 3.3 Velocidad sin cambiar el tono (ajustar el doblaje a la imagen)

```bash
ffmpeg -i dub.mp3 -af "atempo=1.2" dub_fast.mp3 -y
# Rango por filtro atempo: 0.5–2.0; encadena para más:
ffmpeg -i dub.mp3 -af "atempo=1.5,atempo=1.5" dub_225.mp3 -y   # = 2.25x
```

- Rango útil en la práctica: 0.9–1.15. Más allá suena falso — **reescribe el texto en vez de estirar**.
- Regla práctica: español/portugués ~3 palabras/seg. Calcula hacia atrás el número de palabras.

### 3.4 Incrustación de subtítulos

```bash
ffmpeg -i out.mp4 -vf \
  "subtitles=sub.srt:force_style='FontName=Noto Sans,FontSize=22,PrimaryColour=&H00FFFFFF,OutlineColour=&H90000000,BorderStyle=1,Outline=2,Shadow=0,MarginV=45'" \
  -c:a copy final_sub.mp4 -y

# Bilingüe: construye el ASS primero (ver §4) y luego incrusta
ffmpeg -i out.mp4 -vf "ass=sub_bilingual.ass" -c:a copy final_sub.mp4 -y
```

**Trampa de fuentes (ocurrida en producción):** mezclar alfabetos (latino + CJK + devanagari) produce cajitas "□□□" si faltan glifos. Verifica la cobertura antes de incrustar:

```bash
fc-match "Noto Sans" --verbose | grep -i charset | head -3
# Opción nuclear: estilos por idioma en el ASS, o la familia Noto completa
```

### 3.5 Recorte horizontal ↔ vertical

```bash
# 16:9 → 9:16 recorte centrado a 1080x1920
ffmpeg -i landscape.mp4 -vf "crop=ih*9/16:ih,scale=1080:1920" -c:a copy portrait.mp4 -y

# ¿Contenido clave fuera del centro? Fija la ventana manualmente (x:y)
ffmpeg -i landscape.mp4 -vf "crop=607:1080:656:0,scale=1080:1920" -c:a copy portrait.mp4 -y

# Subtítulos: sube MarginV en vertical o la interfaz de la plataforma los tapa
# MarginV=120 (vertical) vs MarginV=45 (horizontal)
```

---

## 4. Subtítulos: esenciales SRT / diseño bilingüe / ajustes de tiempo

### 4.1 Formato SRT (una línea en blanco de menos lo rompe todo)

```
1
00:00:01,000 --> 00:00:04,500
Primera línea de subtítulo

2
00:00:05,000 --> 00:00:08,000
Segunda línea de subtítulo

```
- `HH:MM:SS,mmm` — **coma**, no punto.
- **Exactamente una línea en blanco** entre entradas, incluida al final del archivo.
- ≤ 42 caracteres por línea, ≤ 7 segundos por subtítulo.

### 4.2 Subtítulos bilingües (ASS)

```ini
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.50,Top,,0,0,0,,{\fnNoto Sans}Línea original\N{\fnNoto Sans}Segunda línea traducida
```

- `\N` = salto de línea forzado; original arriba, traducción abajo es el diseño estándar.
- Video vertical: subtítulos arriba (`Alignment=8`) para esquivar la interfaz de me gusta/comentarios.

### 4.3 Ajustes de tiempo

```bash
# Desplazar todo +500ms (el doblaje va detrás de la imagen)
ffmpeg -itsoffset 0.5 -i sub.srt -c copy sub_shifted.srt -y
# Regla: la concatenación de fragmentos TTS deriva ≈ ±0.3s por minuto — alinea por segmento, no por video completo
```

---

## 5. Scripts del flujo por lotes

Dos scripts ejecutables en `scripts/`:

| Script | Hace |
|---|---|
| `dub_pipeline.sh` | Extremo a extremo: doblaje TTS por fragmentos (con reintentos) → chequeo de audio vacío → concatenación con silencios → loudnorm → mezcla → máster. Soporta `--dry-run` |
| `check_audio.py` | Control de calidad: triple chequeo de duración + tamaño + proporción de silencio, lista los segmentos defectuosos |

```bash
./scripts/dub_pipeline.sh --dry-run --lang es --segments ./segments/   # ensayo, sin llamadas API
./scripts/dub_pipeline.sh --lang es --segments ./segments/ --out ./output/  # necesita TTS_API_KEY
python3 scripts/check_audio.py ./segments/es/*.mp3
```

---

## 6. Estimación de costos y tiempos

### 6.1 Modelo de tiempo (medido en 60 videos)

| Etapa | Tiempo por minuto de video final | Notas |
|---|---|---|
| Guion | Dominado por humanos | El mayor agujero de tiempo — planifícalo aparte |
| Doblaje TTS | ~0.5–1× la duración | 3–5 llamadas en paralelo; limitado por red |
| Transcripción Whisper | GPU ~0.3× / CPU ~3–5× | large-v3 + VAD |
| Render ffmpeg | ~0.5–2× | Incrustar subtítulos recodifica — el paso más lento |
| Control humano | ~1× | Hay que escucharlo entero; adelantar oculta audios vacíos |

### 6.2 Modelo de costos

```
Costo TTS ≈ caracteres totales × precio por 1k caracteres
  └─ Cuenta primero: wc -m del guion
  └─ Los segmentos fijos (intro/pausa intermedia/cierre) se doblan UNA vez
     y se reutilizan entre versiones — el mayor ahorro

Whisper local = $0 (menos electricidad); API en la nube por minuto
ffmpeg = $0
```

### 6.3 Alertas de cuota gratuita (70% / 90%)

- Registra la cuota restante el día 1 de cada mes; el script cuenta caracteres por segmento.
- 70% → aviso (¿cuántos días quedan?); 90% → congela nuevos trabajos, solo arreglos.
- **Reutilizar el audio de segmentos fijos entre videos** es el ahorro más efectivo.

---

## 7. Las 8 trampas de producción

| # | Trampa | Síntoma | Solución |
|---|---|---|---|
| 1 | **Audio vacío** | El TTS dice "éxito" pero el archivo está en silencio (específico por frase, ej. `Tomemos un respiro.`) | Ejecuta `check_audio.py` tras doblar; lista negra de frases |
| 2 | **Cajitas tofu** | Glifos faltantes en subtítulos incrustados (devanagari/CJK) | Verifica cobertura con fc-match; estilos ASS por idioma |
| 3 | **Guion entero al TTS** | Tiempos agotados / ritmo a la deriva en la segunda mitad | Fragmenta ≤300 caracteres por frase, 300ms de silencio entre |
| 4 | **Volumen desigual** | La concatenación suena amateur | loudnorm de dos pasadas a -16 LUFS |
| 5 | **Subtítulos tapados** | En 9:16 la interfaz los cubre | Mayor MarginV / alineación superior |
| 6 | **Alucinaciones Whisper** | Letras transcritas sobre la música de intro | Recorta intro/outro antes; `condition_on_previous_text=False` |
| 7 | **Desajuste de duración** | Doblaje más largo/corto que la imagen | Presupuesta segundos primero (~3 palabras/seg ES); atempo solo 0.9–1.15 |
| 8 | **Segmentos fijos que crecen** | La pausa intermedia/el cierre se alargan sin control | Presupuesto duro de segundos por segmento fijo; corta el texto |

---

*Contenido original del autor, escrito en sala limpia. Todos los comandos verificados en producción.*
