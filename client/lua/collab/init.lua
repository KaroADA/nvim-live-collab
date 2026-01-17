local M = {}

local transport = require("collab.transport")
local protocol = require("collab.protocol")
local handlers = require("collab.handlers")
local state = require("collab.state")

local HOST = "127.0.0.1"
local PORT = 8080

local function resolve_username(input_arg, callback)
  -- If argument provided, use it and save it
  if input_arg and input_arg ~= "" then
    state.save_username_to_disk(input_arg)
    callback(input_arg)
    return
  end

  -- Try loading from disk
  local stored = state.load_username_from_disk()
  if stored and stored ~= "" then
    callback(stored)
    return
  end

  -- Prompt the user
  vim.ui.input({ prompt = "Enter your username for Collab: " }, function(input)
    if not input or input == "" then
      vim.notify("Username required to join session.", vim.log.levels.ERROR)
      return
    end
    state.save_username_to_disk(input)
    callback(input)
  end)
end

function M.get_user_completion(arg_lead)
  local matches = {}
  for _, user in pairs(state.users) do
    if user.username and user.username:find(arg_lead, 1, true) then
      table.insert(matches, user.username)
    end
  end
  return matches
end

function M.jump_to_user(username)
  local target_user = nil

  -- Find user by name
  for _, user in pairs(state.users) do
    if user.username == username then
      target_user = user
      break
    end
  end

  if not target_user then
    vim.notify("User '" .. username .. "' not found.", vim.log.levels.WARN)
    return
  end

  if not target_user.cursor then
    vim.notify("User '" .. username .. "' has not moved yet.", vim.log.levels.WARN)
    return
  end

  local cursor = target_user.cursor
  local buf = state.register_file(cursor.path, nil, true)

  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_set_current_buf(buf)

    local line_count = vim.api.nvim_buf_line_count(buf)
    local target_row = cursor.line + 1
    if target_row > line_count then target_row = line_count end

    vim.api.nvim_win_set_cursor(0, { target_row, cursor.col })
    vim.cmd("normal! zz") -- Center screen
    vim.notify("Jumped to " .. username, vim.log.levels.INFO)
  else
    vim.notify("Could not open buffer for path: " .. cursor.path, vim.log.levels.ERROR)
  end
end

local function enable_cursor_tracking()
  local group = vim.api.nvim_create_augroup("CollabActive", { clear = true })
  local timer = assert((vim.uv or vim.loop).new_timer())
  local THROTTLE_MS = 100
  local pending_update = false

  local function send_cursor_payload()
    if not transport.client then return end
    local buf = vim.api.nvim_get_current_buf()
    if not vim.b[buf].collab_enabled then return end
    local path = vim.b[buf].collab_path or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
    path = path:gsub("\\", "/")
    if path == "" then return end
    local cursor = vim.api.nvim_win_get_cursor(0)

    local selection = nil
    local mode = vim.api.nvim_get_mode().mode
    if mode == "v" or mode == "V" or mode == "\22" then
      local v_start = vim.fn.getpos("v")
      local v_end = vim.fn.getpos(".")
      local start_row = v_start[2] - 1
      local start_col = v_start[3] - 1
      local end_row = v_end[2] - 1
      local end_col = v_end[3] - 1
      if start_row > end_row or (start_row == end_row and start_col > end_col) then
        start_row, start_col, end_row, end_col = end_row, end_col, start_row, start_col
      end
      if mode == "V" then
        start_col = 0
        end_col = 2147483647
      end
      selection = {
        start = { start_row, start_col },
        ["end"] = { end_row, end_col }
      }
    end

    local msg = protocol.cursor(state.client_id, path, cursor[1] - 1, cursor[2], selection)
    transport.send(msg)
  end

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "ModeChanged" }, {
    group = group,
    callback = function()
      if timer:is_active() then
        pending_update = true
        return
      end
      send_cursor_payload()
      timer:start(THROTTLE_MS, 0, vim.schedule_wrap(function()
        if pending_update then
          send_cursor_payload()
          pending_update = false
        end
      end))
    end
  })
end

local function get_relative_path(buf)
  local path
  if vim.b[buf].collab_path then
    path = vim.b[buf].collab_path
  else
    path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
  end
  return path:gsub("\\", "/")
end

local attached_buffers = {}
local function attach_to_buffer(buf)
  if attached_buffers[buf] then return end
  if not vim.api.nvim_buf_is_loaded(buf) then return end

  local is_collab = vim.b[buf].collab_enabled
  if not is_collab then return end

  local success = vim.api.nvim_buf_attach(buf, false, {
    on_bytes = function(_, buf_handle, tick, start_row, start_col, _, old_end_row_offset, old_end_col_offset, _,
                        new_end_row_offset, new_end_col_offset, _)
      if state.is_applying_edit then return end
      if not transport.client then return end
      if not buf_handle or not vim.api.nvim_buf_is_valid(buf_handle) then return end

      local old_end_row = start_row + old_end_row_offset
      local old_end_col
      if old_end_row_offset == 0 then
        old_end_col = start_col + old_end_col_offset
      else
        old_end_col = old_end_col_offset
      end
      local new_end_row = start_row + new_end_row_offset
      local new_end_col
      if new_end_row_offset == 0 then
        new_end_col = start_col + new_end_col_offset
      else
        new_end_col = new_end_col_offset
      end
      -- When pasting/restoring, new_end_row might equal line_count.
      local line_count = vim.api.nvim_buf_line_count(buf_handle)
      local new_text = {}
      if start_row < line_count then
        -- Standard Clamp: Ensure we don't read past EOF for normal edits
        if new_end_row >= line_count then
          new_end_row = line_count - 1
          local last_line_content = vim.api.nvim_buf_get_lines(buf_handle, new_end_row, new_end_row + 1, false)[1] or ""
          new_end_col = #last_line_content
        end

        local ok, result = pcall(vim.api.nvim_buf_get_text, buf_handle, start_row, start_col, new_end_row, new_end_col,
          {})
        if ok then
          new_text = result
        else
          vim.notify(string.format(
            "Collab Sync Error!\nRange: (%d,%d) -> (%d,%d)\nBuffer Lines: %d",
            start_row, start_col, new_end_row, new_end_col, line_count
          ), vim.log.levels.ERROR)
          return
        end
      end

      local relative_path = get_relative_path(buf_handle)
      local is_range_empty = (start_row == old_end_row) and (start_col == old_end_col)
      local is_text_empty = (#new_text == 1) and (new_text[1] == "")
      if is_range_empty and is_text_empty then
        return
      end
      local msg = protocol.edit(
        state.client_id,
        relative_path,
        start_row,
        start_col,
        old_end_row,
        old_end_col,
        new_text,
        state.get_revision(relative_path)
      )
      transport.send(msg)
    end
    ,

    on_detach = function()
      attached_buffers[buf] = nil
    end
  })

  if success then
    attached_buffers[buf] = true
  end
end

local function enable_file_tracking()
  local group = vim.api.nvim_create_augroup("CollabEdit", { clear = true })

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    attach_to_buffer(buf)
  end

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, {
    group = group,
    callback = function(args)
      local buf = args.buf

      -- on_bytes listener
      attach_to_buffer(buf)

      -- Try to sync with server
      if transport.client then
        if vim.b[buf].collab_enabled then
          local path = get_relative_path(buf)
          vim.notify(path)

          if path and state.known_server_files[path] then
            vim.notify("Syncing: " .. path, vim.log.levels.INFO)
            local msg = protocol.request_sync(state.client_id, path)
            transport.send(msg)
          end
        end
      end
    end
  })
end

function M.start_host(input_arg)
  resolve_username(input_arg, function(username)
    state.is_host = true
    state.username = username
    state.is_applying_edit = false

    state.users[state.client_id] = {
      id = state.client_id,
      username = username,
      color = "#FFFFFF" -- Will be updated if server sends it back
    }

    vim.notify("Collab: Connecting as Host (" .. username .. ")...", vim.log.levels.INFO)

    transport.connect(HOST, PORT, function(msg)
      handlers.handle_message(msg)
    end)

    vim.defer_fn(function()
      if transport.client then
        local msg = protocol.start_session(state.client_id, "MyProject", username)
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          local name = vim.api.nvim_buf_get_name(buf)
          local buftype = vim.api.nvim_get_option_value('buftype', { buf = buf })
          if name ~= "" and buftype == "" and vim.api.nvim_buf_is_loaded(buf) then
            vim.b[buf].collab_enabled = true
            vim.b[buf].collab_path = vim.fn.fnamemodify(name, ":."):gsub("\\", "/")
            state.path_to_buf[vim.b[buf].collab_path] = buf
            state.file_revisions[vim.b[buf].collab_path] = 0
          end
        end

        transport.send(msg)
        enable_cursor_tracking()
        enable_file_tracking()
        vim.notify("Collab: Session initialized.", vim.log.levels.INFO)
      end
    end, 500)
  end)
end

function M.join_session(input_arg)
  resolve_username(input_arg, function(username)
    state.is_host = false
    state.username = username
    state.is_applying_edit = false

    vim.notify("Collab: Connecting as Guest (" .. username .. ")...", vim.log.levels.INFO)

    transport.connect(HOST, PORT, function(msg)
      handlers.handle_message(msg)
    end)

    vim.defer_fn(function()
      if transport.client then
        local msg = protocol.join(state.client_id, state.username)
        transport.send(msg)

        enable_cursor_tracking()
        enable_file_tracking()
        vim.notify("Collab: Join request sent.", vim.log.levels.INFO)
      end
    end, 500)
  end)
end

function M.change_username(new_name)
  if new_name and new_name ~= "" then
    state.save_username_to_disk(new_name)
    state.username = new_name
    vim.notify("Collab: Username updated to '" .. new_name .. "'", vim.log.levels.INFO)
  else
    vim.ui.input({ prompt = "New Username: ", default = state.username }, function(input)
      if input and input ~= "" then
        state.save_username_to_disk(input)
        state.username = input
        vim.notify("Collab: Username updated to '" .. input .. "'", vim.log.levels.INFO)
      end
    end)
  end
end

return M
