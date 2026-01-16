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
    local path = vim.api.nvim_buf_get_name(buf)
    if path == "" then return end
    path = vim.fn.fnamemodify(path, ":.")
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

local attached_buffers = {}
local function attach_to_buffer(buf)
  if attached_buffers[buf] then return end
  if not vim.api.nvim_buf_is_loaded(buf) then return end
  if vim.api.nvim_get_option_value('buftype', { buf = buf }) ~= "" then return end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then return end

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
      if new_end_row >= line_count then
        new_end_row = line_count - 1
        local last_line = vim.api.nvim_buf_get_lines(buf_handle, new_end_row, new_end_row + 1, false)[1] or ""
        new_end_col = #last_line
      end

      local ok, new_text = pcall(vim.api.nvim_buf_get_text,
        buf_handle,
        start_row,
        start_col,
        new_end_row,
        new_end_col,
        {}
      )

      if ok then
        local relative_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf_handle), ":.")
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
          tick
        )
        transport.send(msg)
      else
        vim.notify(string.format(
          "Collab Sync Error!\nRange: (%d,%d) -> (%d,%d)\nBuffer Lines: %d\nError: %s",
          start_row, start_col, new_end_row, new_end_col, line_count, result
        ), vim.log.levels.ERROR)
      end
    end,

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

  -- Attach to all currently open valid buffers
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    attach_to_buffer(buf)
  end

  -- Listen for new buffers opening or reading
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    callback = function(args)
      attach_to_buffer(args.buf)
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
