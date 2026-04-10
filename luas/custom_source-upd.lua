item = reaper.GetSelectedMediaItem(0,0)
take = reaper.GetActiveTake(item)

src = reaper.GetMediaItemTake_Source(take)
reaper.SetMediaItemTake_Source(take, src)

reaper.UpdateArrange()
