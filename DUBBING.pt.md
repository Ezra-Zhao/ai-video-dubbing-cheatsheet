# 🎙️ Guia de dublagem multilíngue com IA (Português)

> Testado em produção com 60 vídeos técnicos multilíngues (6 projetos × ZH/EN/ES/PT/HI × 16:9 + 9:16).
> Cada vídeo: 5 segmentos técnicos + cartão cultural no intervalo + página final de bênção.
> Fluxo: roteiro → Whisper (controle de qualidade) → dublagem com TTS em nuvem → mixagem com ffmpeg → queima de legendas → render em dois formatos.

---

## 0. O fluxo em 7 passos

```
1. Roteiro fechado (dividido em segmentos, com orçamento de segundos por segmento ANTES de escrever)
2. Dublagem TTS → um mp3 por segmento (fragmente! nunca alimente o roteiro inteiro de uma vez)
3. Controle de qualidade do áudio (detecção de áudios vazios, ver §3)
4. Normalização de volume + ajuste de velocidade com ffmpeg
5. Mixagem (dublagem + música de fundo, atenuada)
6. Legendas (SRT → ASS bilíngue)
7. Render duplo: 16:9 horizontal / 9:16 vertical
```

**Regras de ouro:**
- Um segmento, um arquivo: `seg01_intro.pt.mp3`. Paralelize por segmento; uma falha só repete um segmento.
- Primeiro os segundos, depois as palavras. Ajuste o texto/a velocidade ao tempo, nunca o contrário.
- Guarde sempre um master limpo sem legendas. A queima é o último passo.

---

## 1. Whisper: transcrição / tradução / marcas de tempo

### 1.1 Transcrição básica

```bash
# Transcrição em português com marcas de tempo por palavra
whisper audio.mp3 --model large-v3 --language pt \
  --task transcribe --output_format srt --word_timestamps True \
  --output_dir ./subs

# Traduzir qualquer idioma para o inglês
whisper audio.mp3 --model large-v3 --task translate --output_format srt
```

### 1.2 Parâmetros-chave multilíngues

| Parâmetro | O que faz | Valor em produção |
|---|---|---|
| `--language` | Idioma de origem; a detecção automática é lenta e falha | `pt`/`en`/`es`/`zh`/`hi` — **sempre explícito** |
| `--task` | `transcribe` vs `translate` (para o inglês) | transcribe para revisar o roteiro |
| `--model` | tiny → large-v3 | `large-v3` para a versão final, `medium` para rascunhos (metade do tempo) |
| `--initial_prompt` | Dica de terminologia, corrige nomes próprios | `"Palestra de observabilidade cloud-native. Termos: Prometheus, Grafana, Kubernetes."` |
| `--condition_on_previous_text` | Condicionamento com texto anterior; desligado reduz alucinações | `False` em áudios longos |
| `--word_timestamps True` | Marcas por palavra | Essencial para sincronizar legendas |
| `--vad_filter` | VAD do faster-whisper, pula silêncios | Ligado em palestras longas, economiza 20–40% |

### 1.3 Áudios longos e controle de alucinações

```bash
python3 - <<'EOF'
from faster_whisper import WhisperModel
model = WhisperModel("large-v3", device="cuda", compute_type="float16")
segments, info = model.transcribe(
    "palestra.mp3",
    language="pt",
    vad_filter=True,
    vad_parameters=dict(min_silence_duration_ms=500),
    condition_on_previous_text=False,   # elimina repetições alucinadas
    initial_prompt="Palestra cloud-native. Termos: Prometheus, Grafana, Kubernetes",
    word_timestamps=True,
)
for s in segments:
    print(f"[{s.start:.2f}->{s.end:.2f}] {s.text}")
EOF
```

**Armadilhas:**
- O Whisper alucina letras de música sobre a trilha de abertura/encerramento — corte-as com ffmpeg antes de transcrever.
- As marcas por palavra derivam ±1s no fim de áudios com mais de 10 min; alinhe por frase e ajuste à mão.
- Português brasileiro vs europeu: o Whisper lida bem, mas **nunca misture os dois num mesmo vídeo**; o ouvido percebe na hora.

---

## 2. Dublagem com TTS em nuvem (serviços tipo VoiceStudio como exemplo)

### 2.1 Escolha de voz por idioma

| Idioma | Regra | Nota de produção |
|---|---|---|
| Português | Brasileiro OU europeu — escolha UM | **Nunca misture num vídeo** |
| Espanhol | Latino-americano OU peninsular — escolha UM | **Nunca misture num vídeo** |
| Inglês | Americano ou britânico conforme a audiência | Americano para tutoriais técnicos, velocidade 1.0 |
| Chinês | Voz neural nativa em mandarim | Velocidade 0.95–1.0; mais rápido engole caracteres |
| Hindi | Verifique se a voz aceita devanagari | Algumas só aceitam transliteração latina — teste uma frase primeiro |

### 2.2 Velocidade e pausas (SSML)

```xml
<speak>
  <prosody rate="1.0" pitch="+0%">
    Narração principal em ritmo natural.
  </prosody>
  <break time="600ms"/>
  <prosody rate="0.95">
    Mais lento na transição: 600ms de respiro entre seções.
  </prosody>
</speak>
```

- As vírgulas já geram pausas naturais; **mudanças de seção precisam de `<break>` manual** ou soa apressado.
- Frases de transição ("vamos fazer uma pausa") merecem segmento próprio + 800ms de pausa.

### 2.3 Fragmentação de textos longos (técnica central)

```
Regras:
1. Corte por frases — nunca no meio de uma oração
2. ≤ 300 caracteres por fragmento (PT/ES/EN); ≤ 200 em chinês
3. Uma chamada TTS por fragmento, um arquivo cada: seg01.mp3, seg02.mp3...
4. Insira 300ms de silêncio entre fragmentos ao concatenar:
```

```bash
ffmpeg -f lavfi -i anullsrc=r=48000:cl=stereo -t 0.3 -q:a 9 -acodec libmp3lame silence_03.mp3 -y
# filelist.txt: file 'seg01.mp3' / file 'silence_03.mp3' / ...
ffmpeg -f concat -safe 0 -i filelist.txt -c copy full_dub.mp3 -y
```

**Por que fragmentar é obrigatório:** alimentar o roteiro inteiro ao TTS em nuvem arrisca timeouts, truncamentos e — pior — ritmo à deriva e ênfases erradas na segunda metade. Os 60 vídeos foram dublados por segmentos. Zero falhas.

### 2.4 A armadilha do áudio vazio: detectar + substituir (a seção mais valiosa)

**Sintoma (reproduzido de forma confiável):** certas frases fazem o TTS retornar "sucesso" com um arquivo vazio ou em silêncio.
Caso real: a transição em espanhol `Tomemos un respiro.` **gerava sistematicamente áudio vazio** num provedor de TTS em nuvem. `Tomemos un descanso.` funciona bem; `Hagamos una pausa.` (usado em outro projeto) também. O mesmo tipo de problema pode atingir qualquer idioma — inclusive o português.

**Detecção (obrigatória após cada dublagem, ver `scripts/check_audio.py`):**

```bash
# Checagem rápida: duração ≈ 0 ou arquivo suspeitamente pequeno
ffprobe -v error -show_entries format=duration,size -of csv=p=0 seg03.mp3

# Detecção de silêncio: >90% em silêncio = arquivo defeituoso
ffmpeg -i seg03.mp3 -af silencedetect=noise=-30dB:d=0.5 -f null - 2>&1 | grep silencedetect
```

**Fluxo de recuperação:**
1. O script de dublagem verifica cada segmento na hora; os defeituosos tentam de novo 3 vezes com espera exponencial.
2. Se após 3 tentativas continuar ruim → consulte a lista negra de frases, reformule e duble de novo.
3. Registre a frase problemática na lista negra para evitá-la da próxima vez.

**Lista negra (espanhol, como referência):**

| Frase problemática | Substituição |
|---|---|
| `Tomemos un respiro.` | `Tomemos un descanso.` / `Hagamos una pausa.` |

> Lição: o frontend de texto do TTS tem bugs com combinações específicas de frases — não é questão de significado. Não discuta com ele; reformular é a solução mais barata. Mantenha uma lista negra por idioma e reutilize entre projetos.

---

## 3. ffmpeg: mixagem / volume / velocidade / legendas / recorte

### 3.1 Extrair e unir

```bash
ffmpeg -i final.mp4 -vn -ac 2 -ar 48000 audio.wav -y   # extrair para controle de qualidade

# Unir dublagem com vídeo (copia o vídeo sem recodificar)
ffmpeg -i video_silent.mp4 -i dub.mp3 -c:v copy -map 0:v:0 -map 1:a:0 -shortest out.mp4 -y

# Dublagem + música de fundo (música a -20dB, sob a voz)
ffmpeg -i dub.mp3 -i bgm.mp3 -filter_complex \
  "[1:a]volume=0.15[bg];[0:a][bg]amix=inputs=2:duration=first:dropout_transition=2" \
  -c:a aac -b:a 192k mixed.m4a -y
```

### 3.2 Normalização de volume (obrigatória após concatenar segmentos)

```bash
# Passada 1: medir
ffmpeg -i full_dub.mp3 -af loudnorm=print_format=json -f null - 2>&1 | grep -A12 Parsed_loudnorm

# Passada 2: normalizar com os valores medidos
ffmpeg -i full_dub.mp3 -af \
  "loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=-19.2:measured_TP=-3.1:measured_LRA=7.5:measured_thresh=-29.4:offset=0.83:linear=true" \
  -ar 48000 dub_norm.mp3 -y
```

- Alvo `I=-16 LUFS` para vídeo web. Segmentos de vozes/sessões diferentes soam baratos sem isso.
- O `loudnorm` de passada única aplica limitação dinâmica e degrada a qualidade — **sempre duas passadas na versão final**.

### 3.3 Velocidade sem mudar o tom (ajustar a dublagem à imagem)

```bash
ffmpeg -i dub.mp3 -af "atempo=1.2" dub_fast.mp3 -y
# Faixa por filtro atempo: 0.5–2.0; encadeie para mais:
ffmpeg -i dub.mp3 -af "atempo=1.5,atempo=1.5" dub_225.mp3 -y   # = 2.25x
```

- Faixa útil na prática: 0.9–1.15. Além disso soa falso — **reescreva o texto em vez de esticar**.
- Regra prática: português/espanhol ~3 palavras/seg. Calcule de trás para frente o número de palavras.

### 3.4 Queima de legendas

```bash
ffmpeg -i out.mp4 -vf \
  "subtitles=sub.srt:force_style='FontName=Noto Sans,FontSize=22,PrimaryColour=&H00FFFFFF,OutlineColour=&H90000000,BorderStyle=1,Outline=2,Shadow=0,MarginV=45'" \
  -c:a copy final_sub.mp4 -y

# Bilíngue: monte o ASS primeiro (ver §4) e depois queime
ffmpeg -i out.mp4 -vf "ass=sub_bilingual.ass" -c:a copy final_sub.mp4 -y
```

**Armadilha de fontes (ocorrida em produção):** misturar alfabetos (latino + CJK + devanagari) produz caixinhas "□□□" se faltarem glifos. Verifique a cobertura antes de queimar:

```bash
fc-match "Noto Sans" --verbose | grep -i charset | head -3
# Opção nuclear: estilos por idioma no ASS, ou a família Noto completa
```

### 3.5 Recorte horizontal ↔ vertical

```bash
# 16:9 → 9:16 recorte centralizado em 1080x1920
ffmpeg -i landscape.mp4 -vf "crop=ih*9/16:ih,scale=1080:1920" -c:a copy portrait.mp4 -y

# Conteúdo-chave fora do centro? Fixe a janela manualmente (x:y)
ffmpeg -i landscape.mp4 -vf "crop=607:1080:656:0,scale=1080:1920" -c:a copy portrait.mp4 -y

# Legendas: aumente o MarginV no vertical ou a interface da plataforma as cobre
# MarginV=120 (vertical) vs MarginV=45 (horizontal)
```

---

## 4. Legendas: essenciais do SRT / layout bilíngue / ajustes de tempo

### 4.1 Formato SRT (uma linha em branco a menos quebra tudo)

```
1
00:00:01,000 --> 00:00:04,500
Primeira linha de legenda

2
00:00:05,000 --> 00:00:08,000
Segunda linha de legenda

```
- `HH:MM:SS,mmm` — **vírgula**, não ponto.
- **Exatamente uma linha em branco** entre entradas, inclusive no fim do arquivo.
- ≤ 42 caracteres por linha, ≤ 7 segundos por legenda.

### 4.2 Legendas bilíngues (ASS)

```ini
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.50,Top,,0,0,0,,{\fnNoto Sans}Linha original\N{\fnNoto Sans}Segunda linha traduzida
```

- `\N` = quebra de linha forçada; original em cima, tradução embaixo é o layout padrão.
- Vídeo vertical: legendas no topo (`Alignment=8`) para fugir da interface de curtidas/comentários.

### 4.3 Ajustes de tempo

```bash
# Deslocar tudo +500ms (a dublagem está atrás da imagem)
ffmpeg -itsoffset 0.5 -i sub.srt -c copy sub_shifted.srt -y
# Regra: a concatenação de fragmentos TTS deriva ≈ ±0.3s por minuto — alinhe por segmento, não pelo vídeo inteiro
```

---

## 5. Scripts do fluxo em lote

Dois scripts executáveis em `scripts/`:

| Script | Faz |
|---|---|
| `dub_pipeline.sh` | Ponta a ponta: dublagem TTS por fragmentos (com tentativas) → checagem de áudio vazio → concatenação com silêncios → loudnorm → mixagem → master. Suporta `--dry-run` |
| `check_audio.py` | Controle de qualidade: checagem tripla de duração + tamanho + proporção de silêncio, lista os segmentos defeituosos |

```bash
./scripts/dub_pipeline.sh --dry-run --lang pt --segments ./segments/   # ensaio, sem chamadas API
./scripts/dub_pipeline.sh --lang pt --segments ./segments/ --out ./output/  # precisa de TTS_API_KEY
python3 scripts/check_audio.py ./segments/pt/*.mp3
```

---

## 6. Estimativa de custos e tempos

### 6.1 Modelo de tempo (medido em 60 vídeos)

| Etapa | Tempo por minuto de vídeo final | Notas |
|---|---|---|
| Roteiro | Dominado por humanos | O maior buraco de tempo — planeje separadamente |
| Dublagem TTS | ~0.5–1× a duração | 3–5 chamadas em paralelo; limitado pela rede |
| Transcrição Whisper | GPU ~0.3× / CPU ~3–5× | large-v3 + VAD |
| Render ffmpeg | ~0.5–2× | Queimar legendas recodifica — o passo mais lento |
| Controle humano | ~1× | É preciso ouvir inteiro; adiantar esconde áudios vazios |

### 6.2 Modelo de custos

```
Custo TTS ≈ caracteres totais × preço por 1k caracteres
  └─ Conte primeiro: wc -m do roteiro
  └─ Segmentos fixos (abertura/pausa/encerramento) dublados UMA vez
     e reutilizados entre versões — a maior economia

Whisper local = $0 (menos eletricidade); API em nuvem por minuto
ffmpeg = $0
```

### 6.3 Alertas de cota gratuita (70% / 90%)

- Registre a cota restante no dia 1 de cada mês; o script conta caracteres por segmento.
- 70% → aviso (quantos dias restam?); 90% → congela novos trabalhos, só correções.
- **Reutilizar o áudio de segmentos fixos entre vídeos** é a economia mais eficaz.

---

## 7. As 8 armadilhas de produção

| # | Armadilha | Sintoma | Solução |
|---|---|---|---|
| 1 | **Áudio vazio** | O TTS diz "sucesso" mas o arquivo está em silêncio (específico por frase, ex. ES `Tomemos un respiro.`) | Rode `check_audio.py` após dublar; lista negra de frases |
| 2 | **Caixinhas tofu** | Glifos faltando nas legendas queimadas (devanagari/CJK) | Verifique cobertura com fc-match; estilos ASS por idioma |
| 3 | **Roteiro inteiro no TTS** | Timeouts / ritmo à deriva na segunda metade | Fragmente ≤300 caracteres por frase, 300ms de silêncio entre |
| 4 | **Volume desigual** | A concatenação soa amadora | loudnorm de duas passadas a -16 LUFS |
| 5 | **Legendas cobertas** | No 9:16 a interface as esconde | MarginV maior / alinhamento no topo |
| 6 | **Alucinações do Whisper** | Letras transcritas sobre a música de abertura | Corte abertura/encerramento antes; `condition_on_previous_text=False` |
| 7 | **Duração desencontrada** | Dublagem mais longa/curta que a imagem | Orce segundos primeiro (~3 palavras/seg PT); atempo só 0.9–1.15 |
| 8 | **Segmentos fixos que crescem** | A pausa/o encerramento se alongam sem controle | Orçamento duro de segundos por segmento fixo; corte o texto |

---

*Conteúdo original do autor, escrito em sala limpa. Todos os comandos verificados em produção.*
