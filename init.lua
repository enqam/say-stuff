-- Push-to-Talk: Record audio via ffmpeg, transcribe with whisper.cpp
-- Hotkeys:
--   alt+cmd+v = English transcription
--   alt+cmd+r = Russian transcription

local hotkeyMods = {"alt", "cmd"}

-- Paths and configuration
local recPath = "/tmp/whisper_ptt.wav"
local outBase = "/tmp/whisper_ptt_out"
local model   = os.getenv("HOME") .. "/whisper.cpp/models/ggml-large-v3-turbo.bin"
local whisper = os.getenv("HOME") .. "/whisper.cpp/build/bin/whisper-cli"
local ffmpeg  = "/opt/homebrew/bin/ffmpeg"

-- Input device (from ffmpeg -f avfoundation -list_devices true -i "")
local inputDevice = "none:MacBook Pro Microphone"

-- Minimum audio file size in bytes to attempt transcription
local MIN_AUDIO_BYTES = 512

-- State variables
local recTask = nil
local monitorTimer = nil
local recordingAlert = nil
local currentLanguage = "en"  -- Set by hotkey handler
local recordingStartTime = nil  -- For duration timing

local function cleanupMonitors()
  if monitorTimer then
    monitorTimer:stop()
    monitorTimer = nil
  end
end

-- Force-upgrade to "Recording" after a short, fixed time
local function forceRecordingBanner()
  if recTask then
    if recordingAlert then hs.alert.closeSpecific(recordingAlert) end
    recordingAlert = hs.alert.show("🎙️ Recording… (hold)", 9999)
    -- Play Funk sound to signal "start speaking now"
    hs.sound.getByName("Funk"):play()
  end
end

-- Watch for real audio to upgrade the banner sooner
local function startRecordingBannerWhenReady()
  cleanupMonitors()
  monitorTimer = hs.timer.doEvery(0.05, function()
    if not recTask then
      cleanupMonitors()
      return
    end
    local attr = hs.fs.attributes(recPath)
    if attr and attr.size and attr.size > MIN_AUDIO_BYTES then
      cleanupMonitors()
      if recordingAlert then hs.alert.closeSpecific(recordingAlert) end
      recordingAlert = hs.alert.show("🎙️ Recording… (hold)", 9999)
    end
  end)
end

local function typeText(s)
  if not s or #s == 0 then return end

  -- Save current clipboard contents
  local old = hs.pasteboard.getContents()

  -- Put transcript on clipboard
  hs.pasteboard.setContents(s)

  -- Auto-paste into the focused app
  hs.eventtap.keyStroke({"cmd"}, "v", 0)

  -- Restore previous clipboard after a brief delay to ensure paste completes
  hs.timer.doAfter(0.1, function()
    if old then
      hs.pasteboard.setContents(old)
    else
      hs.pasteboard.clearContents()
    end
  end)
end

-- Actual transcription after ffmpeg closes
local function reallyStopAndTranscribe()
  cleanupMonitors()
  if recordingAlert then
    hs.alert.closeSpecific(recordingAlert)
    recordingAlert = nil
  end

  local attr = hs.fs.attributes(recPath)
  if not (attr and attr.size and attr.size > MIN_AUDIO_BYTES) then
    hs.alert.show("🛑 No audio captured.", 2)
    return
  end

  local langLabels = { en = "🇺🇸", ru = "🇷🇺", auto = "🌐" }
  local langLabel = langLabels[currentLanguage] or "�"
  local transcribing = hs.alert.show("⏳ Transcribing " .. langLabel .. "…", 9999)

  -- Run whisper with quality parameters:
  --   -bo 5 / -bs 5 = beam search for better accuracy (defaults, explicit for clarity)
  --   -nt = no timestamps for cleaner text output
  --   -np = suppress whisper progress/debug output
  local whisperCmd = string.format(
    "%s -m %s -f %s -l %s -bo 5 -bs 5 -nt -np -otxt -of %s",
    whisper, model, recPath, currentLanguage, outBase
  )
  hs.execute(whisperCmd, true)  -- Use user's shell environment for proper GPU/Metal paths

  local f = io.open(outBase .. ".txt", "r")
  local text = f and f:read("*a") or ""
  if f then f:close() end

  if transcribing then hs.alert.closeSpecific(transcribing) end

  -- Clean up text
  text = text:gsub("\r?\n+", " ")
  text = text:gsub("%s%s+", " ")
  text = text:match("^%s*(.-)%s*$") or ""

  typeText(text)

  -- Ensure any old alerts are closed
  if recordingAlert then
    hs.alert.closeSpecific(recordingAlert)
    recordingAlert = nil
  end

  -- Play Glass sound and show word count + duration
  hs.sound.getByName("Glass"):play()
  local wordCount = select(2, text:gsub("%S+", ""))
  if recordingStartTime then
    local duration = hs.timer.secondsSinceEpoch() - recordingStartTime
    hs.alert.show(string.format("✅ %d words in %.1fs", wordCount, duration), 1.5)
  else
    hs.alert.show(string.format("✅ %d words pasted", wordCount), 1.5)
  end


end

-- Start recording with specified language
local function startRecording(lang)
  if recTask then return end

  currentLanguage = lang or "auto"
  local langLabels = { en = "🇺🇸", ru = "🇷🇺", auto = "🌐" }
  local langLabel = langLabels[currentLanguage] or "�"

  os.remove(recPath)
  os.remove(outBase .. ".txt")

  if recordingAlert then hs.alert.closeSpecific(recordingAlert) end
  recordingAlert = hs.alert.show("⏳ Arming mic " .. langLabel .. "…", 9999)
  recordingStartTime = hs.timer.secondsSinceEpoch()  -- Start timing

  recTask = hs.task.new(ffmpeg, function(exitCode, so, se)
    if exitCode ~= 0 then
      hs.printf("[ffmpeg exit %d] stdout: %s | stderr: %s", exitCode, so or "", se or "")
    end
    recTask = nil
    hs.timer.doAfter(0.05, reallyStopAndTranscribe)
  end, {
    "-hide_banner",
    "-loglevel", "error",
    "-f", "avfoundation",
    "-thread_queue_size", "1024",  -- Larger buffer to prevent audio dropouts
    "-i", inputDevice,
    "-ar", "16000",  -- Resample to 16kHz for whisper
    "-ac", "1",
    "-c:a", "pcm_s16le",
    recPath
  })
  recTask:start()

  startRecordingBannerWhenReady()
  hs.timer.doAfter(0.3, forceRecordingBanner)
end

-- Stop recording (transcription triggered via callback)
local function stopAndTranscribe()
  if not recTask then return end
  recTask:terminate()
  cleanupMonitors()
  if recordingAlert then
    hs.alert.closeSpecific(recordingAlert)
    recordingAlert = nil
  end
end

-- Hotkeys:
-- alt+cmd+v = Auto-detect (English/Russian)
-- alt+cmd+c = Russian only
-- alt+cmd+e = English only (optional, if you want explicit English)
hs.hotkey.bind(hotkeyMods, "v", function() startRecording("auto") end, stopAndTranscribe)
hs.hotkey.bind(hotkeyMods, "c", function() startRecording("ru") end, stopAndTranscribe)
hs.hotkey.bind(hotkeyMods, "e", function() startRecording("en") end, stopAndTranscribe)
