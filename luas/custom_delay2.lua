--[[
  GCC-PHAT LR Delay Analyzer for selected item
  analyzes NEXT take after active
  analyzes WHOLE take in fixed FFT windows and averages GCC-PHAT correlation
]]

local function msg(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end 
 
local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function remove_dc(arr)
  local n = #arr
  if n == 0 then return end
  local s = 0.0
  for i = 1, n do s = s + arr[i] end
  local m = s / n
  for i = 1, n do arr[i] = arr[i] - m end
end

local function rms(arr, start_i, end_i)
  local s = 0.0
  local n = 0
  for i = start_i, end_i do
    local v = arr[i]
    s = s + v * v
    n = n + 1
  end
  if n == 0 then return 0.0 end
  return math.sqrt(s / n)
end

local function hann_window(n)
  local w = {}
  if n <= 1 then
    w[1] = 1.0
    return w
  end
  for i = 1, n do
    w[i] = 0.5 - 0.5 * math.cos(2.0 * math.pi * (i - 1) / (n - 1))
  end
  return w
end

local function fft(re, im, inverse)
  local n = #re
  local j = 1

  for i = 1, n do
    if i < j then
      re[i], re[j] = re[j], re[i]
      im[i], im[j] = im[j], im[i]
    end
    local m = math.floor(n / 2)
    while m >= 1 and j > m do
      j = j - m
      m = math.floor(m / 2)
    end
    j = j + m
  end

  local len = 2
  while len <= n do
    local ang = 2.0 * math.pi / len
    if not inverse then ang = -ang end
    local wlen_re = math.cos(ang)
    local wlen_im = math.sin(ang)

    local i = 1
    while i <= n do
      local w_re = 1.0
      local w_im = 0.0

      for j2 = 0, (len / 2) - 1 do
        local u = i + j2
        local v = u + len / 2

        local vr = re[v] * w_re - im[v] * w_im
        local vi = re[v] * w_im + im[v] * w_re

        local ur = re[u]
        local ui = im[u]

        re[u] = ur + vr
        im[u] = ui + vi
        re[v] = ur - vr
        im[v] = ui - vi

        local next_w_re = w_re * wlen_re - w_im * wlen_im
        local next_w_im = w_re * wlen_im + w_im * wlen_re
        w_re = next_w_re
        w_im = next_w_im
      end

      i = i + len
    end

    len = len * 2
  end

  if inverse then
    for i = 1, n do
      re[i] = re[i] / n
      im[i] = im[i] / n
    end
  end
end

local function idx_to_lag(idx, fft_n)
  if idx > fft_n / 2 then
    return (idx - 1) - fft_n
  else
    return idx - 1
  end
end

local function get_selected_item_next_take()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    return nil, nil, "no selected item"
  end

  local take_count = reaper.CountTakes(item)
  if not take_count or take_count < 2 then
    return nil, nil, "item has no next take"
  end

  local active_take = reaper.GetActiveTake(item)
  if not active_take or reaper.TakeIsMIDI(active_take) then
    return nil, nil, "selected item has no active audio take"
  end

  local active_idx = nil
  for i = 0, take_count - 1 do
    local tk = reaper.GetTake(item, i)
    if tk == active_take then
      active_idx = i
      break
    end
  end

  if active_idx == nil then
    return nil, nil, "failed to locate active take index"
  end

  local next_idx = active_idx + 1
  if next_idx >= take_count then
    return nil, nil, "active take is already the last take"
  end

  local take = reaper.GetTake(item, next_idx)
  if not take or reaper.TakeIsMIDI(take) then
    return nil, nil, "next take is missing or not audio"
  end

  return item, take, nil
end

local function read_take_stereo_samples(take, sample_rate)
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then
    return nil, nil, "failed to get take source"
  end

  local src_channels = reaper.GetMediaSourceNumChannels(src)
  if not src_channels or src_channels < 1 then
    return nil, nil, "invalid source channel count"
  end

  local accessor = reaper.CreateTakeAudioAccessor(take)
  if not accessor then
    return nil, nil, "failed to create audio accessor"
  end

  local acc_start = reaper.GetAudioAccessorStartTime(accessor)
  local acc_end = reaper.GetAudioAccessorEndTime(accessor)

  if not acc_start or not acc_end or acc_end <= acc_start then
    reaper.DestroyAudioAccessor(accessor)
    return nil, nil, "invalid accessor time range"
  end

  local duration = acc_end - acc_start
  if duration <= 0 then
    reaper.DestroyAudioAccessor(accessor)
    return nil, nil, "zero readable duration"
  end

  local num_samples = math.floor(duration * sample_rate)
  if num_samples < 64 then
    reaper.DestroyAudioAccessor(accessor)
    return nil, nil, "too few samples"
  end

  local buf = reaper.new_array(num_samples * src_channels)

  local ok = reaper.GetAudioAccessorSamples(
    accessor,
    sample_rate,
    src_channels,
    acc_start,
    num_samples,
    buf
  )

  reaper.DestroyAudioAccessor(accessor)

  if ok ~= 1 then
    return nil, nil, "GetAudioAccessorSamples failed (channels=" .. tostring(src_channels) .. ", start=" .. tostring(acc_start) .. ", samples=" .. tostring(num_samples) .. ")"
  end

  local t = buf.table()
  local L, R = {}, {}

  for i = 1, num_samples do
    local base = (i - 1) * src_channels
    local ch1 = t[base + 1] or 0.0
    local ch2 = (src_channels >= 2) and (t[base + 2] or 0.0) or ch1
    L[i] = ch1
    R[i] = ch2
  end

  return L, R, nil
end

local function gcc_phat_whole_take(L, R, sample_rate, fft_n, hop, max_search_ms)
  local n = math.min(#L, #R)
  if n < fft_n then
    return nil, nil, nil, nil, 0, "take shorter than fft window"
  end

  local max_lag = math.floor(max_search_ms * sample_rate / 1000.0)
  max_lag = clamp(max_lag, 1, math.floor(fft_n / 2) - 1)

  local w = hann_window(fft_n)
  local accum = {}
  for i = 1, fft_n do accum[i] = 0.0 end

  local frames = 0
  local eps = 1e-12

  local xr, xi, yr, yi, gr, gi = {}, {}, {}, {}, {}, {}
  for i = 1, fft_n do
    xr[i], xi[i], yr[i], yi[i], gr[i], gi[i] = 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
  end

  local start_i = 1
  while start_i + fft_n - 1 <= n do
    local stop_i = start_i + fft_n - 1

    local l_rms = rms(L, start_i, stop_i)
    local r_rms = rms(R, start_i, stop_i)

    if l_rms > 1e-6 and r_rms > 1e-6 then
      for i = 1, fft_n do
        local idx = start_i + i - 1
        xr[i] = L[idx] * w[i]
        xi[i] = 0.0
        yr[i] = R[idx] * w[i]
        yi[i] = 0.0
      end

      fft(xr, xi, false)
      fft(yr, yi, false)

      for k = 1, fft_n do
        local re = xr[k] * yr[k] + xi[k] * yi[k]
        local im = xi[k] * yr[k] - xr[k] * yi[k]
        local mag = math.sqrt(re * re + im * im)

        if mag > eps then
          gr[k] = re / mag
          gi[k] = im / mag
        else
          gr[k] = 0.0
          gi[k] = 0.0
        end
      end

      fft(gr, gi, true)

      for i = 1, fft_n do
        accum[i] = accum[i] + gr[i]
      end

      frames = frames + 1
    end

    start_i = start_i + hop
  end

  if frames == 0 then
    return nil, nil, nil, nil, 0, "no usable frames"
  end

  for i = 1, fft_n do
    accum[i] = accum[i] / frames
  end

  local best_idx = 1
  local best_val = -1e30
  local sum_abs = 0.0
  local count_abs = 0

  for i = fft_n - max_lag + 1, fft_n do
    local v = math.abs(accum[i])
    sum_abs = sum_abs + v
    count_abs = count_abs + 1
    if v > best_val then
      best_val = v
      best_idx = i
    end
  end

  for i = 1, max_lag + 1 do
    local v = math.abs(accum[i])
    sum_abs = sum_abs + v
    count_abs = count_abs + 1
    if v > best_val then
      best_val = v
      best_idx = i
    end
  end

  local mean_abs = count_abs > 0 and (sum_abs / count_abs) or 0.0
  local best_lag = idx_to_lag(best_idx, fft_n)

  local second_val = -1e30
  local exclude_radius = 2

  for i = fft_n - max_lag + 1, fft_n do
    local lag = idx_to_lag(i, fft_n)
    if math.abs(lag - best_lag) > exclude_radius then
      local v = math.abs(accum[i])
      if v > second_val then second_val = v end
    end
  end

  for i = 1, max_lag + 1 do
    local lag = idx_to_lag(i, fft_n)
    if math.abs(lag - best_lag) > exclude_radius then
      local v = math.abs(accum[i])
      if v > second_val then second_val = v end
    end
  end

  if second_val < 0 then second_val = 0.0 end

  local lag_int = best_lag

  local function corr_at_lag(lg)
    local idx
    if lg < 0 then
      idx = fft_n + lg + 1
    else
      idx = lg + 1
    end
    if idx < 1 or idx > fft_n then return 0.0 end
    return accum[idx]
  end

  local y1 = corr_at_lag(lag_int - 1)
  local y2 = corr_at_lag(lag_int)
  local y3 = corr_at_lag(lag_int + 1)

  local denom = (y1 - 2.0 * y2 + y3)
  local delta = 0.0
  if math.abs(denom) > 1e-12 then
    delta = 0.5 * (y1 - y3) / denom
    delta = clamp(delta, -1.0, 1.0)
  end

  local lag_frac = lag_int + delta
  local delay_ms = lag_frac * 1000.0 / sample_rate

  local conf_sep = 0.0
  local conf_bg = 0.0
  local conf_abs = 0.0

  if best_val > eps then
    conf_sep = (best_val - second_val) / (best_val + eps)
    conf_bg  = (best_val - mean_abs) / (best_val + eps)

    -- absolute strength term
    conf_abs = (best_val - 0.01) / (0.05 - 0.01)
  end

  conf_sep = clamp(conf_sep, 0.0, 1.0)
  conf_bg  = clamp(conf_bg, 0.0, 1.0)
  conf_abs = clamp(conf_abs, 0.0, 1.0)

  local confidence = clamp((conf_sep + conf_bg + conf_abs) / 3.0, 0.0, 1.0)

  return lag_frac, delay_ms, confidence, best_val, frames, nil
end

local function main()
  reaper.ClearConsole()

  local _, take, err = get_selected_item_next_take()
  if err then
    msg("Error: " .. err)
    return
  end

  local sample_rate = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
  if not sample_rate or sample_rate <= 0 then
    sample_rate = 44100
  end

  local fft_n = 16384
  local hop = math.floor(fft_n / 2)
  local max_search_ms = 20.0

  local L, R, read_err = read_take_stereo_samples(take, sample_rate)
  if read_err then
    msg("Error: " .. read_err)
    return
  end

  remove_dc(L)
  remove_dc(R)

  local delay_spl, delay_ms, confidence, _, frames, gcc_err =
    gcc_phat_whole_take(L, R, sample_rate, fft_n, hop, max_search_ms)

  if gcc_err then
    msg("Error: " .. gcc_err)
    return
  end

  msg("=== GCC-PHAT LR Delay Analyzer ===")
  msg("Take analyzed: next take after active")
  msg(string.format("Samples analyzed: %d", math.min(#L, #R)))
  msg(string.format("Sample rate: %.0f Hz", sample_rate))
  msg(string.format("FFT size: %d", fft_n))
  msg(string.format("Hop size: %d", hop))
  msg(string.format("Frames averaged: %d", frames))
  msg(string.format("Search range: +/- %.2f ms", max_search_ms))
  msg("")
  msg(string.format("Estimated delay: %.3f samples", delay_spl))
  msg(string.format("Estimated delay: %.6f ms", delay_ms))
  msg(string.format("Confidence: %.3f", confidence))
  msg("")

  if math.abs(delay_spl) < 0.1 then
    msg("Interpretation: channels are time-aligned")
  elseif delay_spl > 0 then
    msg("Interpretation: R lags behind L")
  else
    msg("Interpretation: R is earlier than L")
  end
end

main()
