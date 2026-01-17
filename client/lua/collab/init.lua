local M = {}

local transport = require("collab.transport")
local protocol = require("collab.protocol")
local handlers = require("collab.handlers")
local state = require("collab.state")

local HOST = "127.0.0.1"
local PORT = 8080

local function enable_cursor_tracking()
  local group = vim.api.nvim_create_augroup("CollabActive", { clear = true })
  local timer = assert((vim.uv or vim.loop).new_timer())
  local THROTTLE_MS = 200
  local pending_update = false

  local function send_cursor_payload()
    if not transport.client then return end
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= "" then return end
    local path = vim.b[buf].collab_path or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
    path = path:gsub("\\", "/")
    if path == "" then return end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local msg = protocol.cursor(state.client_id, path, cursor[1] - 1, cursor[2])
    transport.send(msg)
  end

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
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
      if transport.client and not state.is_host then
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

function M.start_host(username)
  state.is_host = true
  state.username = (username and username ~= "") and username or "Host"

  vim.notify("Collab: Connecting as Host...", vim.log.levels.INFO)

  transport.connect(HOST, PORT, function(msg)
    handlers.handle_message(msg)
  end)

  -- After 500ms check if connection was ok, then send StartSession
  vim.defer_fn(function()
    if transport.client then
      local msg = protocol.start_session(state.client_id, "MyProject")
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(buf)
        local buftype = vim.api.nvim_get_option_value('buftype', { buf = buf })

        if name ~= "" and buftype == "" and vim.api.nvim_buf_is_loaded(buf) then
          -- Tag it
          vim.b[buf].collab_enabled = true
          vim.b[buf].collab_path = vim.fn.fnamemodify(name, ":."):gsub("\\", "/")

          -- Register in state
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
end

function M.join_session(username)
  state.is_host = false
  state.username = (username and username ~= "") and username or "Guest"

  vim.notify("Collab: Connecting as Guest...", vim.log.levels.INFO)

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
end

return M
