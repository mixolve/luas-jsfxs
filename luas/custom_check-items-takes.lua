-- @author mixolve&chatgpt
-- put it in cycle actions start-up with reaper or manually enable ones per entering reaper

local _, _, section, cmd_id = reaper.get_action_context()

local prev_state = -1

function check_items()
  local has_multiple = false
  for i = 0, reaper.CountSelectedMediaItems(0)-1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    if reaper.CountTakes(item) > 1 then
      has_multiple = true
      break
    end
  end

  local state = has_multiple and 1 or 0
  if state ~= prev_state then
    reaper.SetToggleCommandState(section, cmd_id, state)
    reaper.RefreshToolbar2(section, cmd_id)
    prev_state = state
  end

  reaper.defer(check_items)
end

check_items()
