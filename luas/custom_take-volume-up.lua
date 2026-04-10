reaper.PreventUIRefresh(1)

local itemCount = reaper.CountSelectedMediaItems(0)
for i = 0, itemCount - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  if item then
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local vol = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
      local new_vol = vol * 10^(0.5 / 20) -- here 0.5 is the step of changing
      reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", new_vol)
    end
  end
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.defer(function() end) 