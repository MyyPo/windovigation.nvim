local globals = require("windovigation.globals")
local history = require("windovigation.history")

local M = {}

---@param options WindovigationLayoutChangeOptions?
M.handle_layout_change = function(options)
  local is_restoring_state = options and options.is_restoring_state == true or false
  local wins = vim.api.nvim_list_wins()

  local state_before = globals.state
  local state_after = {} ---@type WindovigationState
  local window_panes_before = {} ---@type table<integer, integer>
  local tab_pages_before = {} ---@type table<integer, integer>

  -- Any history that remains in this table will be dropped at the end of this call.
  local histories_before = {} ---@type table<WindovigationKey, WindovigationHistory>
  local histories_before_update = {} ---@type table<WindovigationKey, string[] | nil> -- TODO: Remove this later, this is here only for backwards compatability.

  for _, entry in pairs(state_before) do
    local key = entry.page .. "_" .. entry.pane

    window_panes_before[entry.win] = entry.pane
    tab_pages_before[entry.tab] = entry.page
    histories_before[key] = entry.histories
    histories_before_update[key] = entry["history"]
  end

  local restored_file_buffers = {} ---@type table<string, integer>

  -- We need to prepare restored file buffers so we know which files
  -- in our history didn't get restored.
  if is_restoring_state then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local buf_name = vim.api.nvim_buf_get_name(buf)
      restored_file_buffers[buf_name] = buf
    end
  end

  for _, win in ipairs(wins) do
    local tab = vim.api.nvim_win_get_tabpage(win)
    local page = vim.api.nvim_tabpage_get_number(tab)
    local pane = vim.api.nvim_win_get_number(win)
    local key = page .. "_" .. pane
    local histories = { entered = {}, written = {} } ---@type WindovigationHistory
    local key_old = nil ---@type WindovigationKey?

    if not is_restoring_state then
      -- When not restoring state, get old state with window / tab ids.
      local pane_old = window_panes_before[win]
      local page_old = tab_pages_before[tab]

      if page_old ~= nil and pane_old ~= nil then
        key_old = page_old .. "_" .. pane_old
      end
    else
      -- State restored, assume panes and pages match their old positions.
      key_old = key
    end

    if key_old ~= nil then
      local entry_old = state_before[key_old] or nil ---@type WindovigationEntry?

      -- Reusing old histories if possible and removing it from
      -- histories_before, so it doesn't get dropped.
      if entry_old ~= nil and histories_before[key_old] ~= nil then
        histories = histories_before[key_old]
        histories_before[key_old] = nil
        histories_before[key_old] = nil
        histories_before_update[key_old] = nil
      elseif entry_old ~= nil and histories_before_update[key_old] ~= nil and is_restoring_state then
        -- Handle backwards compatibility with the old history list.
        --
        -- If state is already restored, assume the histories have been updated.
        histories = {
          written = histories_before_update[key_old] or {},
          entered = histories_before_update[key_old] or {},
        }

        histories_before[key_old] = nil
        histories_before_update[key_old] = nil
      end
    end

    -- Filter out buffer names that didn't get restored.
    --
    -- For example nvim session restore doesn't restore terminals.
    if is_restoring_state then
      local filter = function(value)
        return restored_file_buffers[value] ~= nil
      end

      histories = {
        entered = vim.tbl_filter(filter, histories.entered),
        written = vim.tbl_filter(filter, histories.written),
      }
    end

    --- @type WindovigationEntry
    state_after[key] = {
      tab = tab,
      page = page,
      win = win,
      pane = pane,
      histories = histories,
    }
  end

  globals.state = state_after

  -- HACK: The drop is delayed 1 second, to allow
  -- nvim to handle autocommands and update its layout.
  --
  -- So when the drop checks whether the buffer is still
  -- scoped somewhere, it can correctly check renamed files.
  --
  -- We don't care if the files are actually dropped, this
  -- is just a clean up utility for when they go out of scope.
  --
  -- If the user returns to a file that was marked for a drop,
  -- it won't be dropped because it'd be scoped back in already.
  vim.defer_fn(function()
    M.drop_histories(histories_before)
  end, 1000)
end

---@param histories_before table<WindovigationKey, WindovigationHistory>
M.drop_histories = function(histories_before)
  local files_dropped = {} ---@type table<string, boolean>
  for _, history_before in pairs(histories_before) do
    for _, file in ipairs(history_before.written or {}) do
      if files_dropped[file] ~= true then
        local did_close = history.maybe_close_buffer_for_file(file, true)
        if did_close then
          files_dropped[file] = true
        end
      end
    end
  end
end

return M
