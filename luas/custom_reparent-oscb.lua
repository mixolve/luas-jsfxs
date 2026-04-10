-- @author mixolve&chatgpt
-- this is for solo plugin
-- implemented same host/anchor logic as in double plugin script
-- fixed width + fixed height

local TITLE = "oscb"
local FX_INDEX = 5 -- serial number of plugin minus one in monitoring fx chain
local DOCKSTATE = 1 | (2 << 8) -- second number is a docker number

local FIXED_WIDTH = 1000 -- fixed width
local FIXED_HEIGHT = 204 -- fixed height

local CROP_TOP = 28 -- crop preset line
local EXTRA_BOTTOM = 0 -- extra bottom compensation

local TINY_W = 20
local TINY_H = 20

if not reaper.JS_Window_SetParent then return end

local gfx_hwnd = nil
local host_hwnd = nil
local child_hwnd = nil

local last_w, last_h = -1, -1
local command_done = false
local zfix_done = false

local function ensure_gfx_and_host()
  if not gfx_hwnd or not reaper.JS_Window_IsWindow(gfx_hwnd) then
    gfx_hwnd = reaper.JS_Window_Find(TITLE, true)
    if not gfx_hwnd then return false end
  end

  if not host_hwnd or not reaper.JS_Window_IsWindow(host_hwnd) then
    host_hwnd = reaper.JS_Window_GetParent(gfx_hwnd)
    if not host_hwnd then return false end
  end

  return true
end

local function ensure_fx_window(track)
  local fx = 0x1000000 + FX_INDEX

  if not child_hwnd or not reaper.JS_Window_IsWindow(child_hwnd) then
    reaper.TrackFX_Show(track, fx, 3)
    child_hwnd = reaper.TrackFX_GetFloatingWindow(track, fx)

    if child_hwnd then
      pcall(function()
        reaper.JS_Window_SetStyle(child_hwnd, "CHILD,VISIBLE")
      end)
    end
  end
end

local function child_ready()
  return child_hwnd and reaper.JS_Window_IsWindow(child_hwnd)
end

local function attach_child_to_host()
  local current_parent = reaper.JS_Window_GetParent(child_hwnd)
  if current_parent ~= host_hwnd then
    reaper.JS_Window_SetParent(child_hwnd, host_hwnd)
    return true
  end
  return false
end

local function fix_z_order_once()
  if zfix_done then return end

  if gfx_hwnd and reaper.JS_Window_IsWindow(gfx_hwnd) then
    pcall(function()
      reaper.JS_Window_SetPosition(gfx_hwnd, 0, 0, 1, 1, "NOTOPMOST", "")
    end)
  end

  if child_hwnd and reaper.JS_Window_IsWindow(child_hwnd) then
    pcall(function()
      reaper.JS_Window_SetPosition(child_hwnd, 0, 0, 100, 100, "NOTOPMOST", "")
    end)
  end

  zfix_done = true
end

local function hide_gfx_anchor()
  if gfx_hwnd and reaper.JS_Window_IsWindow(gfx_hwnd) then
    reaper.JS_Window_SetPosition(gfx_hwnd, 0, 0, 1, 1, "", "")
  end
end

local function fit_child_to_host()
  if not child_hwnd or not host_hwnd then return end
  if not reaper.JS_Window_IsWindow(host_hwnd) then return end

  local fitted_w = FIXED_WIDTH
  local fitted_h = FIXED_HEIGHT + CROP_TOP + EXTRA_BOTTOM

  if fitted_w ~= last_w or fitted_h ~= last_h then
    last_w, last_h = fitted_w, fitted_h

    reaper.JS_Window_SetPosition(
      child_hwnd,
      0,
      -CROP_TOP,
      fitted_w,
      fitted_h,
      "",
      ""
    )
  end
end

local function run()
  local track = reaper.GetMasterTrack(0)
  if not track then
    reaper.defer(run)
    return
  end

  ensure_fx_window(track)

  if not child_ready() then
    reaper.defer(run)
    return
  end

  if not ensure_gfx_and_host() then
    reaper.defer(run)
    return
  end

  local reattached = attach_child_to_host()
  if reattached then
    zfix_done = false
  end

  fix_z_order_once()
  hide_gfx_anchor()
  fit_child_to_host()

  if not command_done then
    command_done = true
    reaper.Main_OnCommand(40239, 0)
    reaper.Main_OnCommand(40239, 0)
  end

  reaper.defer(run)
end

gfx.init(TITLE, TINY_W, TINY_H, DOCKSTATE)
reaper.defer(run)
