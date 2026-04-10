local GMEM_NAME = "ITEM_LR_DELTA_8K"
local FFT_SIZE = 32768
local HOP = FFT_SIZE
local FALLBACK_SR = 44100

local EPS = 1e-12
local TAKE_MODE = 2

reaper.gmem_attach(GMEM_NAME)

local function clear_payload()
  reaper.gmem_write(0, 0)
  reaper.gmem_write(1, 0)
  reaper.gmem_write(2, 0)
  reaper.gmem_write(4, 0)
  reaper.gmem_write(5, 0)

  reaper.gmem_write(6, 0)
  reaper.gmem_write(7, 0)
  reaper.gmem_write(8, 0)
  reaper.gmem_write(9, 0)
  reaper.gmem_write(10, 0)
  reaper.gmem_write(11, 0)
  reaper.gmem_write(12, 0)
  reaper.gmem_write(13, 0)

  for i = 0, 200000 do
    reaper.gmem_write(16 + i, 0)
  end
end

local function bump_token()
  local tok = reaper.gmem_read(3) or 0
  tok = math.floor(tok + 1)
  reaper.gmem_write(3, tok)
  return tok
end

local function clamp(x, a, b)
  if x < a then return a end
  if x > b then return b end
  return x
end

local function fft(re, im)
  local n = #re
  local j = 1

  for i = 1, n do
    if i < j then
      re[i], re[j] = re[j], re[i]
      im[i], im[j] = im[j], im[i]
    end

    local m = n // 2
    while m >= 1 and j > m do
      j = j - m
      m = m // 2
    end
    j = j + m
  end

  local mmax = 1
  while n > mmax do
    local istep = mmax * 2
    local theta = -math.pi / mmax
    local wtemp = math.sin(0.5 * theta)
    local wpr = -2.0 * wtemp * wtemp
    local wpi = math.sin(theta)
    local wr = 1.0
    local wi = 0.0

    for m = 1, mmax do
      local i = m
      while i <= n do
        local j2 = i + mmax
        local tempr = wr * re[j2] - wi * im[j2]
        local tempi = wr * im[j2] + wi * re[j2]

        re[j2] = re[i] - tempr
        im[j2] = im[i] - tempi
        re[i] = re[i] + tempr
        im[i] = im[i] + tempi

        i = i + istep
      end

      local wr_old = wr
      wr = wr * wpr - wi * wpi + wr
      wi = wi * wpr + wr_old * wpi + wi
    end

    mmax = istep
  end
end

local function get_take_by_mode(item, mode)
  if not item then return nil end
  if mode == 0 then return reaper.GetActiveTake(item) end
  if mode == 1 then return reaper.GetTake(item, 0) end
  if mode == 2 then return reaper.GetTake(item, 1) end
  return nil
end

local item = reaper.GetSelectedMediaItem(0, 0)
if not item then
  clear_payload()
  bump_token()
  return
end

local take = get_take_by_mode(item, TAKE_MODE)
if not take or reaper.TakeIsMIDI(take) then
  clear_payload()
  bump_token()
  return
end

local accessor = reaper.CreateTakeAudioAccessor(take)
if not accessor then
  clear_payload()
  bump_token()
  return
end

local src = reaper.GetMediaItemTake_Source(take)
if not src then
  reaper.DestroyAudioAccessor(accessor)
  clear_payload()
  bump_token()
  return
end

local nch = reaper.GetMediaSourceNumChannels(src)
if not nch or nch < 2 then
  reaper.DestroyAudioAccessor(accessor)
  clear_payload()
  bump_token()
  return
end

local sr = reaper.GetMediaSourceSampleRate(src)
if not sr or sr <= 0 then
  sr = FALLBACK_SR
end

local start_t = reaper.GetAudioAccessorStartTime(accessor)
local end_t = reaper.GetAudioAccessorEndTime(accessor)

local nbins = FFT_SIZE // 2 + 1

local lmag, rmag = {}, {}
local mmag, smag = {}, {}
local corr_spec = {}

for i = 1, nbins do
  lmag[i] = 0.0
  rmag[i] = 0.0
  mmag[i] = 0.0
  smag[i] = 0.0
  corr_spec[i] = 0.0
end

local win = {}
for i = 1, FFT_SIZE do
  win[i] = 0.5 * (1.0 - math.cos((2.0 * math.pi * (i - 1)) / (FFT_SIZE - 1)))
end

local buf = reaper.new_array(FFT_SIZE * 2)
local frames = 0
local pos = start_t
local hop_sec = HOP / sr
local fft_sec = FFT_SIZE / sr

local sumLR = 0.0
local sumL2 = 0.0
local sumR2 = 0.0
local total_samples = 0

local peakL = 0.0
local peakR = 0.0

while (pos + fft_sec) <= end_t do
  buf.clear()
  local ok = reaper.GetAudioAccessorSamples(accessor, sr, 2, pos, FFT_SIZE, buf)

  if ok == 1 then
    local t = buf.table()

    local reL, imL = {}, {}
    local reR, imR = {}, {}

    for i = 1, FFT_SIZE do
      local li = t[(i - 1) * 2 + 1] or 0.0
      local ri = t[(i - 1) * 2 + 2] or 0.0

      sumLR = sumLR + (li * ri)
      sumL2 = sumL2 + (li * li)
      sumR2 = sumR2 + (ri * ri)
      total_samples = total_samples + 1

      local absL = math.abs(li)
      local absR = math.abs(ri)
      if absL > peakL then peakL = absL end
      if absR > peakR then peakR = absR end

      reL[i] = li * win[i]
      imL[i] = 0.0

      reR[i] = ri * win[i]
      imR[i] = 0.0
    end

    fft(reL, imL)
    fft(reR, imR)

    for k = 1, nbins do
      local lre = reL[k]
      local lim = imL[k]
      local rre = reR[k]
      local rim = imR[k]

      local mre = 0.5 * (lre + rre)
      local mim = 0.5 * (lim + rim)
      local sre = 0.5 * (lre - rre)
      local sim = 0.5 * (lim - rim)

      local ml = math.sqrt(lre * lre + lim * lim)
      local mr = math.sqrt(rre * rre + rim * rim)
      local mm = math.sqrt(mre * mre + mim * mim)
      local ms = math.sqrt(sre * sre + sim * sim)

      lmag[k] = lmag[k] + ml
      rmag[k] = rmag[k] + mr
      mmag[k] = mmag[k] + mm
      smag[k] = smag[k] + ms

      local num = (lre * rre) + (lim * rim)
      local den = (ml * mr) + EPS
      local c = clamp(num / den, -1.0, 1.0)
      corr_spec[k] = corr_spec[k] + c
    end

    frames = frames + 1
  end

  pos = pos + hop_sec
end

reaper.DestroyAudioAccessor(accessor)

if frames == 0 then
  clear_payload()
  bump_token()
  return
end

for k = 1, nbins do
  lmag[k] = lmag[k] / frames
  rmag[k] = rmag[k] / frames
  mmag[k] = mmag[k] / frames
  smag[k] = smag[k] / frames
  corr_spec[k] = corr_spec[k] / frames
end

local left_db = {}
local right_db = {}
local stereo_db = {}
local mid_db = {}
local side_db = {}

for k = 1, nbins do
  local ldb = 20.0 * math.log(lmag[k] + EPS, 10)
  local rdb = 20.0 * math.log(rmag[k] + EPS, 10)
  local mdb = 20.0 * math.log(mmag[k] + EPS, 10)
  local sdb = 20.0 * math.log(smag[k] + EPS, 10)

  left_db[k] = ldb
  right_db[k] = rdb
  stereo_db[k] = 20.0 * math.log(((lmag[k] + rmag[k]) * 0.5) + EPS, 10)
  mid_db[k] = mdb
  side_db[k] = sdb
end

local total_corr = 0.0
local total_denom = math.sqrt(sumL2 * sumR2)
if total_denom > EPS then
  total_corr = sumLR / total_denom
end
total_corr = clamp(total_corr, -1.0, 1.0)

local rmsL = 0.0
local rmsR = 0.0
local rmsL_db = -150.0
local rmsR_db = -150.0
local diff_r_db = 0.0

local peakL_db = -150.0
local peakR_db = -150.0
local crestL_db = 0.0
local crestR_db = 0.0

if total_samples > 0 then
  rmsL = math.sqrt(sumL2 / total_samples)
  rmsR = math.sqrt(sumR2 / total_samples)

  rmsL_db = 20.0 * math.log(rmsL + EPS, 10)
  rmsR_db = 20.0 * math.log(rmsR + EPS, 10)

  diff_r_db = rmsR_db - rmsL_db

  peakL_db = 20.0 * math.log(peakL + EPS, 10)
  peakR_db = 20.0 * math.log(peakR + EPS, 10)

  crestL_db = peakL_db - rmsL_db
  crestR_db = peakR_db - rmsR_db
end

reaper.gmem_write(4, 0)

local base_left   = 16
local base_right  = base_left + nbins
local base_stereo = base_right + nbins
local base_corr   = base_stereo + nbins
local base_mid    = base_corr + nbins
local base_side   = base_mid + nbins

for k = 1, nbins do
  reaper.gmem_write(base_left   + (k - 1), left_db[k])
  reaper.gmem_write(base_right  + (k - 1), right_db[k])
  reaper.gmem_write(base_stereo + (k - 1), stereo_db[k])
  reaper.gmem_write(base_corr   + (k - 1), corr_spec[k])
  reaper.gmem_write(base_mid    + (k - 1), mid_db[k])
  reaper.gmem_write(base_side   + (k - 1), side_db[k])
end

reaper.gmem_write(0, FFT_SIZE)
reaper.gmem_write(1, nbins)
reaper.gmem_write(2, frames)
reaper.gmem_write(4, 1)
reaper.gmem_write(5, sr)

reaper.gmem_write(6, total_corr)
reaper.gmem_write(7, rmsL_db)
reaper.gmem_write(8, rmsR_db)
reaper.gmem_write(9, diff_r_db)
reaper.gmem_write(10, peakL_db)
reaper.gmem_write(11, peakR_db)
reaper.gmem_write(12, crestL_db)
reaper.gmem_write(13, crestR_db)

bump_token()
