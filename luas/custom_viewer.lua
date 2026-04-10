local SCRIPT_NAME = "LR Spectrum Viewer"
local GMEM_NAME = "ITEM_LR_DELTA_8K"

local FONT_NAME = "Sometype Mono"
local FONT_SIZE = 15
local UI_FONT_SIZE = 15

local ctx = reaper.ImGui_CreateContext(SCRIPT_NAME)
local font_ui = reaper.ImGui_CreateFont(FONT_NAME, UI_FONT_SIZE)
local font_menu = reaper.ImGui_CreateFont(FONT_NAME, FONT_SIZE)
reaper.ImGui_Attach(ctx, font_ui)
reaper.ImGui_Attach(ctx, font_menu)

reaper.gmem_attach(GMEM_NAME)

local show_left = false
local show_right = false
local show_stereo = true
local show_mid = false
local show_side = false

local active_tab = 0

local SLOPE_DB_PER_OCT = 5.0
local SLOPE_REF_FREQ = 632.0
local SLOPE_ENABLED = true
local slope_values = {5.0, 4.5, 4.0}
local slope_choice = 0
SLOPE_DB_PER_OCT = slope_values[slope_choice + 1]

local SPEC_CEIL_DB = 48.0
local SPEC_FLOOR_DB = 0.0
local SPEC_FLOOR_MIN = -24.0
local SPEC_FLOOR_MAX = 24.0
local FLOOR_SCROLL_STEP = 1.0

local CORR_TOP = 1.0
local CORR_BOTTOM = -1.0
local CORR_BOTTOM_MIN = -1.0
local CORR_BOTTOM_MAX = 0.0
local CORR_SCROLL_STEP = 0.05

local SMOOTH_FRACTION = 48

local WIN_W = 760
local WIN_H = 420

local TOKEN_DOT_TTL = 2.5
local TOKEN_DOT_RADIUS = 3.0

local function clamp(x, a, b)
  if x < a then return a end
  if x > b then return b end
  return x
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function freq_for_bin(bin_idx, fft_size, sr)
  return ((bin_idx - 1) * sr) / fft_size
end

local function freq_from_plot_x(x, plot_x, plot_w, sr)
  local min_freq = 20.0
  local max_freq = sr * 0.5
  local nx = clamp((x - plot_x) / plot_w, 0.0, 1.0)
  local log_min = math.log(min_freq, 10)
  local log_max = math.log(max_freq, 10)
  return 10 ^ lerp(log_min, log_max, nx)
end

local function format_freq_text(freq)
  if freq >= 1000.0 then
    return string.format("%.2fk", freq / 1000.0)
  else
    return string.format("%.0f", freq)
  end
end

local function format_status(diff_r_db, total_corr)
  return string.format("dR: %+06.2f c: %+06.2f", diff_r_db or 0.0, total_corr or 0.0)
end

local function format_slope_value(idx)
  return string.format("%.1f", slope_values[(idx or 0) + 1] or slope_values[1])
end

local function apply_slope(v, freq)
  if not SLOPE_ENABLED then return v end
  if freq <= 0 then return v end
  local oct = math.log(freq / SLOPE_REF_FREQ, 2)
  return v + (SLOPE_DB_PER_OCT * oct)
end

local function smooth_octave(arr, fft_size, sr, nbins, fraction)
  if not arr or nbins <= 0 or fraction <= 0 then
    return arr or {}
  end

  local out = {}
  local half_oct = 1.0 / (2.0 * fraction)

  for i = 1, nbins do
    local freq = freq_for_bin(i, fft_size, sr)

    if freq <= 0 then
      out[i] = arr[i] or 0.0
    else
      local f1 = freq / (2 ^ half_oct)
      local f2 = freq * (2 ^ half_oct)

      local bin1 = math.floor((f1 / sr) * fft_size + 1)
      local bin2 = math.ceil((f2 / sr) * fft_size + 1)

      bin1 = clamp(bin1, 1, nbins)
      bin2 = clamp(bin2, 1, nbins)

      local sum = 0.0
      local count = 0

      for k = bin1, bin2 do
        sum = sum + (arr[k] or 0.0)
        count = count + 1
      end

      out[i] = count > 0 and (sum / count) or (arr[i] or 0.0)
    end
  end

  return out
end

local function read_payload()
  local fft_size = math.floor(reaper.gmem_read(0) or 0)
  local nbins = math.floor(reaper.gmem_read(1) or 0)
  local frames = math.floor(reaper.gmem_read(2) or 0)
  local valid = math.floor(reaper.gmem_read(4) or 0)
  local sr = reaper.gmem_read(5) or 44100

  local total_corr = reaper.gmem_read(6) or 0.0
  local rmsL_db    = reaper.gmem_read(7) or 0.0
  local rmsR_db    = reaper.gmem_read(8) or 0.0
  local diff_r_db  = reaper.gmem_read(9) or 0.0
  local peakL_db   = reaper.gmem_read(10) or 0.0
  local peakR_db   = reaper.gmem_read(11) or 0.0
  local crestL_db  = reaper.gmem_read(12) or 0.0
  local crestR_db  = reaper.gmem_read(13) or 0.0

  local payload = {
    valid = false,
    fft_size = fft_size,
    nbins = nbins,
    frames = frames,
    sr = sr,

    total_corr = total_corr,
    rmsL_db = rmsL_db,
    rmsR_db = rmsR_db,
    diff_r_db = diff_r_db,
    peakL_db = peakL_db,
    peakR_db = peakR_db,
    crestL_db = crestL_db,
    crestR_db = crestR_db,

    left = {},
    right = {},
    stereo = {},
    corr = {},
    mid = {},
    side = {},
  }

  if valid ~= 1 or fft_size <= 0 or nbins <= 0 then
    return payload
  end

  local base_left   = 16
  local base_right  = base_left + nbins
  local base_stereo = base_right + nbins
  local base_corr   = base_stereo + nbins
  local base_mid    = base_corr + nbins
  local base_side   = base_mid + nbins

  for i = 1, nbins do
    payload.left[i]   = reaper.gmem_read(base_left   + (i - 1)) or 0.0
    payload.right[i]  = reaper.gmem_read(base_right  + (i - 1)) or 0.0
    payload.stereo[i] = reaper.gmem_read(base_stereo + (i - 1)) or 0.0
    payload.corr[i]   = reaper.gmem_read(base_corr   + (i - 1)) or 0.0
    payload.mid[i]    = reaper.gmem_read(base_mid    + (i - 1)) or 0.0
    payload.side[i]   = reaper.gmem_read(base_side   + (i - 1)) or 0.0
  end

  payload.valid = true
  return payload
end

local function draw_line(draw_list, x1, y1, x2, y2, col, th)
  reaper.ImGui_DrawList_AddLine(draw_list, x1, y1, x2, y2, col, th or 1.0)
end

local function draw_rect(draw_list, x1, y1, x2, y2, col)
  reaper.ImGui_DrawList_AddRect(draw_list, x1, y1, x2, y2, col, 0.0, 0, 1.0)
end

local function draw_rect_filled(draw_list, x1, y1, x2, y2, col)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x1, y1, x2, y2, col, 0.0, 0)
end

local token_dot_until = 0.0

local function draw_token_dot(draw_list, win_x, win_y, win_w, win_h)
  local now = reaper.time_precise()
  local remaining = token_dot_until - now
  if remaining <= 0.0 then return end

  local fade = clamp(remaining / TOKEN_DOT_TTL, 0.0, 1.0)
  local col = reaper.ImGui_ColorConvertDouble4ToU32(0.60, 0.60, 1.00, 0.35 + 0.65 * fade)

  local cx = win_x + 6
  local cy = win_y + win_h - 10
  reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, TOKEN_DOT_RADIUS, col, 16)
end

local function value_to_y(v, minv, maxv, plot_y, plot_h)
  local t = (clamp(v, minv, maxv) - minv) / (maxv - minv)
  return plot_y + (1.0 - t) * plot_h
end

local function corr_to_y(v, plot_y, plot_h)
  local t = (clamp(v, CORR_BOTTOM, CORR_TOP) - CORR_BOTTOM) / (CORR_TOP - CORR_BOTTOM)
  return plot_y + (1.0 - t) * plot_h
end

local function draw_grid(draw_list, plot_x, plot_y, plot_w, plot_h, is_corr_tab)
  local col_bg = reaper.ImGui_ColorConvertDouble4ToU32(0.2, 0.2, 0.2, 1.0)
  local col_border = reaper.ImGui_ColorConvertDouble4ToU32(0.18, 0.18, 0.20, 1.0)
  local col_grid = reaper.ImGui_ColorConvertDouble4ToU32(0.6, 0.6, 0.6, 0.35)
  local col_zero = reaper.ImGui_ColorConvertDouble4ToU32(1.0, 1.0, 1.0, 1.0)

  draw_rect_filled(draw_list, plot_x, plot_y, plot_x + plot_w, plot_y + plot_h, col_bg)
  draw_rect(draw_list, plot_x, plot_y, plot_x + plot_w, plot_y + plot_h, col_border)

  if is_corr_tab then
    local v = -1.0
    while v <= 1.0001 do
      local y = corr_to_y(v, plot_y, plot_h)
      local is_zero = math.abs(v) < 0.0001
      local col = is_zero and col_zero or col_grid
      local th = is_zero and 2.0 or 1.0
      draw_line(draw_list, plot_x, y, plot_x + plot_w, y, col, th)
      v = v + 0.25
    end
    return
  end

end

local function sample_spectrum_nearest(arr, fft_size, sr, nbins, freq)
  if not arr then return 0.0 end
  local binf = (freq / sr) * fft_size + 1.0
  local bin = math.floor(binf + 0.5)
  bin = clamp(bin, 1, nbins)
  return arr[bin] or 0.0
end

local function draw_curve(draw_list, arr, fft_size, sr, nbins, plot_x, plot_y, plot_w, plot_h, minv, maxv, col, thickness, use_slope)
  if not arr then return end

  local min_freq = 20.0
  local max_freq = sr * 0.5
  if max_freq < min_freq then return end

  local log_min = math.log(min_freq, 10)
  local log_max = math.log(max_freq, 10)

  local prev_x, prev_y = nil, nil
  local steps = math.max(2, math.min(1024, math.floor(plot_w)))

  for px = 0, steps do
    local nx = px / steps
    local freq = 10 ^ (log_min + (log_max - log_min) * nx)

    local v = sample_spectrum_nearest(arr, fft_size, sr, nbins, freq)
    if use_slope then
      v = apply_slope(v, freq)
    end

    local x = plot_x + nx * plot_w
    local y = value_to_y(v, minv, maxv, plot_y, plot_h)

    if prev_x then
      draw_line(draw_list, prev_x, prev_y, x, y, col, thickness)
    end

    prev_x, prev_y = x, y
  end
end

local function draw_corr_curve(draw_list, arr, fft_size, sr, nbins, plot_x, plot_y, plot_w, plot_h, col, thickness)
  if not arr then return end

  local min_freq = 20.0
  local max_freq = sr * 0.5
  if max_freq < min_freq then return end

  local log_min = math.log(min_freq, 10)
  local log_max = math.log(max_freq, 10)

  local prev_x, prev_y = nil, nil
  local steps = math.max(2, math.min(1024, math.floor(plot_w)))

  for px = 0, steps do
    local nx = px / steps
    local freq = 10 ^ (log_min + (log_max - log_min) * nx)
    local v = sample_spectrum_nearest(arr, fft_size, sr, nbins, freq)

    local x = plot_x + nx * plot_w
    local y = corr_to_y(v, plot_y, plot_h)

    if prev_x then
      draw_line(draw_list, prev_x, prev_y, x, y, col, thickness)
    end

    prev_x, prev_y = x, y
  end
end

local function draw_tabs(content_x, content_y)
  reaper.ImGui_SetCursorScreenPos(ctx, content_x + 6, content_y + 6)

  local col_btn        = reaper.ImGui_ColorConvertDouble4ToU32(0.6, 0.6, 0.6, 0.25)
  local col_btn_hover  = reaper.ImGui_ColorConvertDouble4ToU32(0.7, 0.7, 0.7, 0.35)
  local col_btn_active = reaper.ImGui_ColorConvertDouble4ToU32(0.8, 0.8, 0.8, 0.45)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col_btn)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), col_btn_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  col_btn_active)

  if reaper.ImGui_Button(ctx, "spec", 52, 26) then
    active_tab = 0
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "coR", 52, 26) then
    active_tab = 1
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "vol", 52, 26) then
    active_tab = 2
  end

  reaper.ImGui_PopStyleColor(ctx, 3)
end

local function draw_value_pill(draw_list, x, y, text)
  local text_col = reaper.ImGui_ColorConvertDouble4ToU32(0.95, 0.95, 0.95, 1.0)
  local border = reaper.ImGui_ColorConvertDouble4ToU32(0.6, 0.6, 1.0, 1.0)

  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  draw_rect(draw_list, x, y, x + tw + 16, y + th + 8, border)
  reaper.ImGui_DrawList_AddText(draw_list, x + 8, y + 4, text_col, text)

  return tw + 16, th + 8
end

local last_token = -1
local cached = read_payload()

local smooth_left = {}
local smooth_right = {}
local smooth_stereo = {}
local smooth_corr = {}
local smooth_mid = {}
local smooth_side = {}

local function rebuild_smoothed()
  if cached.valid then
    smooth_left   = smooth_octave(cached.left,   cached.fft_size, cached.sr, cached.nbins, SMOOTH_FRACTION)
    smooth_right  = smooth_octave(cached.right,  cached.fft_size, cached.sr, cached.nbins, SMOOTH_FRACTION)
    smooth_stereo = smooth_octave(cached.stereo, cached.fft_size, cached.sr, cached.nbins, SMOOTH_FRACTION)
    smooth_corr   = smooth_octave(cached.corr,   cached.fft_size, cached.sr, cached.nbins, SMOOTH_FRACTION)
    smooth_mid    = smooth_octave(cached.mid,    cached.fft_size, cached.sr, cached.nbins, SMOOTH_FRACTION)
    smooth_side   = smooth_octave(cached.side,   cached.fft_size, cached.sr, cached.nbins, SMOOTH_FRACTION)
  else
    smooth_left = {}
    smooth_right = {}
    smooth_stereo = {}
    smooth_corr = {}
    smooth_mid = {}
    smooth_side = {}
  end
end

rebuild_smoothed()

local function loop()
  reaper.ImGui_SetNextWindowSize(ctx, WIN_W, WIN_H, reaper.ImGui_Cond_Once())

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 4, 2)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 4, 4)

  local window_flags =
      reaper.ImGui_WindowFlags_NoScrollbar()
    | reaper.ImGui_WindowFlags_NoResize()
    | reaper.ImGui_WindowFlags_NoCollapse()

  local visible, open = reaper.ImGui_Begin(ctx, SCRIPT_NAME, true, window_flags)

  if visible then
    reaper.ImGui_PushFont(ctx, font_menu, FONT_SIZE)

    local token = math.floor(reaper.gmem_read(3) or 0)
    if token ~= last_token then
      if last_token >= 0 then
        token_dot_until = reaper.time_precise() + TOKEN_DOT_TTL
      end
      cached = read_payload()
      last_token = token
      rebuild_smoothed()
    end

    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local content_x, content_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)

    local win_x, win_y = reaper.ImGui_GetWindowPos(ctx)
    local win_w, win_h = reaper.ImGui_GetWindowSize(ctx)

    local plot_x = content_x
    local plot_y = content_y
    local plot_w = avail_w
    local plot_h = avail_h
    if plot_h < 1 then plot_h = 1 end

    local col_cross = reaper.ImGui_ColorConvertDouble4ToU32(1.00, 1.00, 1.00, 0.18)

	    if active_tab == 0 then
	      local minv, maxv = SPEC_FLOOR_DB, SPEC_CEIL_DB
	      local controls_x = content_x + 6
	      local controls_x2 = controls_x + 56
	      local controls_x3 = controls_x + 112
	      draw_grid(draw_list, plot_x, plot_y, plot_w, plot_h, false)

      if cached.valid then
        local col_left    = reaper.ImGui_ColorConvertDouble4ToU32(0.831, 0.984, 0.475, 1.0)
        local col_right   = reaper.ImGui_ColorConvertDouble4ToU32(1.0, 0.494, 0.475, 1.0)
        local col_stereo  = reaper.ImGui_ColorConvertDouble4ToU32(0.90, 0.90, 0.90, 1.0)
        local col_mid     = reaper.ImGui_ColorConvertDouble4ToU32(1.0, 0.85, 0.35, 1.0)
        local col_side    = reaper.ImGui_ColorConvertDouble4ToU32(0.35, 0.95, 0.95, 1.0)

        if show_left then
          draw_curve(draw_list, smooth_left, cached.fft_size, cached.sr, cached.nbins,
            plot_x, plot_y, plot_w, plot_h, minv, maxv, col_left, 2.0, true)
        end

        if show_right then
          draw_curve(draw_list, smooth_right, cached.fft_size, cached.sr, cached.nbins,
            plot_x, plot_y, plot_w, plot_h, minv, maxv, col_right, 2.0, true)
        end

        if show_stereo then
          draw_curve(draw_list, smooth_stereo, cached.fft_size, cached.sr, cached.nbins,
            plot_x, plot_y, plot_w, plot_h, minv, maxv, col_stereo, 2.0, true)
        end

        if show_mid then
          draw_curve(draw_list, smooth_mid, cached.fft_size, cached.sr, cached.nbins,
            plot_x, plot_y, plot_w, plot_h, minv, maxv, col_mid, 2.0, true)
        end

        if show_side then
          draw_curve(draw_list, smooth_side, cached.fft_size, cached.sr, cached.nbins,
            plot_x, plot_y, plot_w, plot_h, minv, maxv, col_side, 2.0, true)
        end
      end

      draw_tabs(content_x, content_y)

      local rv
      local col_chk_bg      = reaper.ImGui_ColorConvertDouble4ToU32(0.6, 0.6, 0.6, 0.25)
      local col_chk_hover   = reaper.ImGui_ColorConvertDouble4ToU32(0.7, 0.7, 0.7, 0.35)
      local col_chk_active  = reaper.ImGui_ColorConvertDouble4ToU32(0.8, 0.8, 0.8, 0.45)
      local col_chk_mark    = reaper.ImGui_ColorConvertDouble4ToU32(1.0, 1.0, 1.0, 1.0)

      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        col_chk_bg)
	      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), col_chk_hover)
	      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  col_chk_active)
	      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(),      col_chk_mark)

	      reaper.ImGui_SetCursorScreenPos(ctx, controls_x, content_y + 38)
	      rv, show_left = reaper.ImGui_Checkbox(ctx, "L", show_left)
	      reaper.ImGui_SetCursorScreenPos(ctx, controls_x2, content_y + 38)
	      rv, show_right = reaper.ImGui_Checkbox(ctx, "R", show_right)
	      reaper.ImGui_SetCursorScreenPos(ctx, controls_x3, content_y + 38)
	      rv, show_stereo = reaper.ImGui_Checkbox(ctx, "LR", show_stereo)

	      reaper.ImGui_SetCursorScreenPos(ctx, controls_x, content_y + 68)
	      rv, show_mid = reaper.ImGui_Checkbox(ctx, "M", show_mid)
	      reaper.ImGui_SetCursorScreenPos(ctx, controls_x2, content_y + 68)
	      rv, show_side = reaper.ImGui_Checkbox(ctx, "S", show_side)

	      reaper.ImGui_SetCursorScreenPos(ctx, controls_x, content_y + 98)
	      reaper.ImGui_PushItemWidth(ctx, 52)

      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        0x505050FF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x5A5A5AFF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  0x646464FF)

      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),         0x505050FF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),  0x5A5A5AFF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),   0x646464FF)

      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(),        0x4A4A4AFF)

      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),         0x6A6A6AFF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(),  0x747474FF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),   0x7E7E7EFF)

      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),           0xF0F0F0FF)

	      reaper.ImGui_PushFont(ctx, font_ui, UI_FONT_SIZE)
	      if reaper.ImGui_BeginCombo(ctx, "##slope", format_slope_value(slope_choice)) then
	        reaper.ImGui_PushFont(ctx, font_menu, FONT_SIZE)
	        for i, value in ipairs(slope_values) do
	          local idx = i - 1
	          local is_selected = slope_choice == idx
	          if reaper.ImGui_Selectable(ctx, string.format("%.1f", value), is_selected) then
	            slope_choice = idx
	            SLOPE_DB_PER_OCT = value
	          end
	          if is_selected then
	            reaper.ImGui_SetItemDefaultFocus(ctx)
	          end
	        end
	        reaper.ImGui_PopFont(ctx)
	        reaper.ImGui_EndCombo(ctx)
	      end
	      reaper.ImGui_PopFont(ctx)

      reaper.ImGui_PopStyleColor(ctx, 11)
      reaper.ImGui_PopItemWidth(ctx)

      reaper.ImGui_PopStyleColor(ctx, 4)

      if cached.valid then
        local label = format_status(cached.diff_r_db, cached.total_corr)
        local text_col = reaper.ImGui_ColorConvertDouble4ToU32(0.95, 0.95, 0.95, 1.0)
        local bg_col = reaper.ImGui_ColorConvertDouble4ToU32(0.0, 0.0, 0.0, 0.0)

        local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
        local tx = content_x + 176
        local ty = content_y + 8

        draw_rect_filled(draw_list, tx - 4, ty - 2, tx + tw + 4, ty + th + 2, bg_col)
        reaper.ImGui_DrawList_AddText(draw_list, tx, ty, text_col, label)
      end

      reaper.ImGui_SetCursorScreenPos(ctx, plot_x, plot_y)
      reaper.ImGui_InvisibleButton(ctx, "plot_mouse_zone_spectrum", plot_w, plot_h)

      local mx, my = reaper.ImGui_GetMousePos(ctx)
      local inside = mx >= plot_x and mx <= plot_x + plot_w
        and my >= plot_y and my <= plot_y + plot_h

      if inside then
        local wheel = reaper.ImGui_GetMouseWheel(ctx)
        if wheel ~= 0.0 then
          SPEC_FLOOR_DB = clamp(
            SPEC_FLOOR_DB + wheel * FLOOR_SCROLL_STEP,
            SPEC_FLOOR_MIN,
            SPEC_FLOOR_MAX
          )
        end
      end

      if inside and cached.valid then
        draw_line(draw_list, mx, plot_y, mx, plot_y + plot_h, col_cross, 1.0)
        draw_line(draw_list, plot_x, my, plot_x + plot_w, my, col_cross, 1.0)
      end

      if cached.valid and inside then
        local freq = freq_from_plot_x(mx, plot_x, plot_w, cached.sr)
        local freq_text = format_freq_text(freq)

        local text_col = reaper.ImGui_ColorConvertDouble4ToU32(0.95, 0.95, 0.95, 1.0)
        local bg_col = reaper.ImGui_ColorConvertDouble4ToU32(0.0, 0.0, 0.0, 0.0)

        local tw, th = reaper.ImGui_CalcTextSize(ctx, freq_text)
        local tx = plot_x + 10
        local ty = plot_y + plot_h - th - 10

        draw_rect_filled(draw_list, tx - 4, ty - 2, tx + tw + 4, ty + th + 2, bg_col)
        reaper.ImGui_DrawList_AddText(draw_list, tx, ty, text_col, freq_text)
      end

    elseif active_tab == 1 then
      draw_grid(draw_list, plot_x, plot_y, plot_w, plot_h, true)

      if cached.valid then
        local col_corr = reaper.ImGui_ColorConvertDouble4ToU32(0.6, 0.6, 1.0, 1.0)
        draw_corr_curve(draw_list, smooth_corr, cached.fft_size, cached.sr, cached.nbins,
          plot_x, plot_y, plot_w, plot_h, col_corr, 2.0)

        local label = format_status(cached.diff_r_db, cached.total_corr)
        local text_col = reaper.ImGui_ColorConvertDouble4ToU32(0.95, 0.95, 0.95, 1.0)
        local bg_col = reaper.ImGui_ColorConvertDouble4ToU32(0.0, 0.0, 0.0, 0.0)

        local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
        local tx = content_x + 176
        local ty = content_y + 8

        draw_rect_filled(draw_list, tx - 4, ty - 2, tx + tw + 4, ty + th + 2, bg_col)
        reaper.ImGui_DrawList_AddText(draw_list, tx, ty, text_col, label)
      end

      draw_tabs(content_x, content_y)

      reaper.ImGui_SetCursorScreenPos(ctx, plot_x, plot_y)
      reaper.ImGui_InvisibleButton(ctx, "plot_mouse_zone_corr", plot_w, plot_h)

      local mx, my = reaper.ImGui_GetMousePos(ctx)
      local inside = mx >= plot_x and mx <= plot_x + plot_w
        and my >= plot_y and my <= plot_y + plot_h

      if inside then
        local wheel = reaper.ImGui_GetMouseWheel(ctx)
        if wheel ~= 0.0 then
          CORR_BOTTOM = clamp(
            CORR_BOTTOM + wheel * CORR_SCROLL_STEP,
            CORR_BOTTOM_MIN,
            CORR_BOTTOM_MAX
          )
        end
      end

      if inside and cached.valid then
        draw_line(draw_list, mx, plot_y, mx, plot_y + plot_h, col_cross, 1.0)
        draw_line(draw_list, plot_x, my, plot_x + plot_w, my, col_cross, 1.0)
      end

      if cached.valid and inside then
        local freq = freq_from_plot_x(mx, plot_x, plot_w, cached.sr)
        local freq_text = format_freq_text(freq)

        local text_col = reaper.ImGui_ColorConvertDouble4ToU32(0.95, 0.95, 0.95, 1.0)
        local bg_col = reaper.ImGui_ColorConvertDouble4ToU32(0.0, 0.0, 0.0, 0.0)

        local tw, th = reaper.ImGui_CalcTextSize(ctx, freq_text)
        local tx = plot_x + 10
        local ty = plot_y + plot_h - th - 10

        draw_rect_filled(draw_list, tx - 4, ty - 2, tx + tw + 4, ty + th + 2, bg_col)
        reaper.ImGui_DrawList_AddText(draw_list, tx, ty, text_col, freq_text)
      end

    else
      local bg = reaper.ImGui_ColorConvertDouble4ToU32(0.2, 0.2, 0.2, 1.0)
      local border = reaper.ImGui_ColorConvertDouble4ToU32(0.18, 0.18, 0.20, 1.0)

      draw_rect_filled(draw_list, plot_x, plot_y, plot_x + plot_w, plot_y + plot_h, bg)
      draw_rect(draw_list, plot_x, plot_y, plot_x + plot_w, plot_y + plot_h, border)

      draw_tabs(content_x, content_y)

      local panel_x = plot_x + 18
      local panel_y = plot_y + 52

      if cached.valid then
        local label_col = reaper.ImGui_ColorConvertDouble4ToU32(0.75, 0.75, 0.80, 1.0)

        local col_w = 200
        local x1 = panel_x + 20
        local x2 = x1 + col_w
        local x3 = x2 + col_w
        local x4 = x3 + col_w

        local y1 = panel_y + 20
        local y2 = y1 + 40

        local function row(x, y, label, value)
          reaper.ImGui_DrawList_AddText(draw_list, x, y, label_col, label)
          draw_value_pill(draw_list, x + 80, y - 4, value)
        end

        row(x1, y1, "rms-L",   string.format("%+06.2f", cached.rmsL_db   or 0.0))
        row(x1, y2, "rms-R",   string.format("%+06.2f", cached.rmsR_db   or 0.0))

        row(x2, y1, "peak-L",  string.format("%+06.2f", cached.peakL_db  or 0.0))
        row(x2, y2, "peak-R",  string.format("%+06.2f", cached.peakR_db  or 0.0))

        row(x3, y1, "crest-L", string.format("%+06.2f", cached.crestL_db or 0.0))
        row(x3, y2, "crest-R", string.format("%+06.2f", cached.crestR_db or 0.0))

        row(x4, y1, "rms-d-R", string.format("%+06.2f", cached.diff_r_db or 0.0))
      end
    end

    draw_token_dot(draw_list, win_x, win_y, win_w, win_h)

    reaper.ImGui_PopFont(ctx)
    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopStyleVar(ctx, 4)

  if open then
    reaper.defer(loop)
  else
    reaper.ImGui_DestroyContext(ctx)
  end
end

reaper.defer(loop)
