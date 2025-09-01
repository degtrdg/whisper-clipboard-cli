-- Cmd–Shift–X: record microphone audio
-- After stopping: transcribe with Deepgram → copy transcript to clipboard → optional auto-paste

-- Configurable paths
local homeDirectory = os.getenv("HOME")
local recordingsDirectory = homeDirectory .. "/Recordings"
local transcribeScript = homeDirectory .. "/.hammerspoon/whisper-clipboard-cli/scripts/transcribe_and_copy.py"
local envFilePath = homeDirectory .. "/.hammerspoon/whisper-clipboard-cli/.env"
local uvPath = "/opt/homebrew/bin/uv" -- adjust if uv is elsewhere

-- Behavior
local autoPasteAfterCopy = true

-- Audio settings
local audioSampleRate = 48000
local audioBitrate = "192k"
local fileExtension = "wav" -- Use WAV format to avoid M4A corruption issues

-- avfoundation device indices (auto-detected during installation)
local microphoneDevice  = ":1"   -- MacBook Pro Microphone (change if auto-detection fails)

-- Internal state
local recordingTask = nil
local lastOutputFile = nil

-- Find ffmpeg in common locations and via a login shell
local function findFFmpeg()
  local candidates = {
    "/opt/homebrew/bin/ffmpeg",
    "/usr/local/bin/ffmpeg",
    "/usr/bin/ffmpeg",
  }
  for _, p in ipairs(candidates) do
    if hs.fs.attributes(p) then return p end
  end
  local fromWhich = hs.execute("/bin/bash -lc 'which ffmpeg'"):gsub("%s+$", "")
  if fromWhich ~= "" then return fromWhich end
  return nil
end

local ffmpegPath = findFFmpeg()
if ffmpegPath then
  print("ffmpeg detected at: " .. ffmpegPath)
else
  hs.alert.show("ffmpeg not found. brew install ffmpeg")
end

-- Simple .env reader (KEY=VALUE, supports quoted values)
local function readEnvVarFromFile(filePath, key)
  local file = io.open(filePath, "r")
  if not file then return nil end
  for line in file:lines() do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" and not trimmed:match("^#") then
      local k, v = trimmed:match("^([A-Za-z_][A-Za-z0-9_]*)%s*=%s*(.+)$")
      if k == key and v then
        v = v:gsub('^%s*"', ""):gsub('"%s*$', "")
        v = v:gsub("^%s*'", ""):gsub("'%s*$", "")
        file:close()
        return v
      end
    end
  end
  file:close()
  return nil
end

local function runTranscription(path)
  if not hs.fs.attributes(transcribeScript) then
    print("Transcription script not found: " .. transcribeScript)
    return
  end
  if not hs.fs.attributes(uvPath) then
    hs.alert.show("uv not found at " .. uvPath .. " - reinstall required")
    return
  end
  local apiKey = readEnvVarFromFile(envFilePath, "DEEPGRAM_API_KEY")
  if not apiKey or apiKey == "" then
    hs.alert.show("Set DEEPGRAM_API_KEY in ~/.hammerspoon/whisper-clipboard-cli/.env")
    return
  end

  hs.alert.show("Transcribing…")
  local cmd = string.format("%q run --no-project %q --api-key %q %q", uvPath, transcribeScript, apiKey, path)
  hs.task.new("/bin/bash", function(exitCode, stdOut, stdErr)
    if exitCode == 0 then
      hs.alert.show("Copied to clipboard")
      if autoPasteAfterCopy then
        hs.timer.doAfter(0.05, function()
          hs.eventtap.keyStroke({"cmd"}, "v", 0)
        end)
      end
    else
      hs.alert.show("Transcription failed")
      if stdErr and #stdErr > 0 then print(stdErr) end
    end
  end, {"-lc", cmd}):start()
end

local function startRecording()
  if not ffmpegPath then
    hs.alert.show("ffmpeg not available")
    return
  end
  hs.fs.mkdir(recordingsDirectory)
  local timestamp = os.date("%Y-%m-%d_%H-%M-%S")
  local outFile = string.format("%s/audio-%s.%s", recordingsDirectory, timestamp, fileExtension)
  lastOutputFile = outFile

  local cmd = string.format([[%s -hide_banner -loglevel error \
    -f avfoundation -i "%s" \
    -ar %d -c:a pcm_s16le "%s"]],
    ffmpegPath, microphoneDevice, audioSampleRate, outFile)

  recordingTask = hs.task.new("/bin/bash", function() end, {"-lc", cmd})
  recordingTask:start()
  hs.alert.show("Recording started")
end

local function stopRecording()
  if recordingTask and recordingTask:isRunning() then
    local pid = recordingTask:pid()
    print("Stopping ffmpeg with PID: " .. tostring(pid))
    if pid then
      -- Send SIGINT to allow ffmpeg to properly close the file
      hs.task.new("/bin/kill", function() end, {"-INT", tostring(pid)}):start()
      
      -- Wait for ffmpeg to finish writing properly
      hs.timer.doAfter(2.0, function()
        if recordingTask and recordingTask:isRunning() then
          recordingTask:terminate()
        end
        recordingTask = nil
      end)
    else
      recordingTask:terminate()
      recordingTask = nil
    end
  end
  hs.alert.show("Recording ended")

  if lastOutputFile then
    -- Increased delay to ensure file is fully written
    hs.timer.doAfter(2.5, function()
      if hs.fs.attributes(lastOutputFile) then
        runTranscription(lastOutputFile)
      end
    end)
  end
end

local function toggleRecording()
  if recordingTask and recordingTask:isRunning() then
    stopRecording()
  else
    startRecording()
  end
end

hs.hotkey.bind({"cmd","shift"}, "x", toggleRecording)
