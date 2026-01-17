local M = {}
local state = require("collab.state")
local cursor_ui = require("collab.cursor")

function M.handle_message(msg)
  if not msg or not msg.type then return end

  if msg.type == "JOIN_GOOD" then
    M.on_join_good(msg.payload)
  elseif msg.type == "USER_JOINED" then
    M.on_user_joined(msg.payload)
  elseif msg.type == "USER_LEFT" then
    M.on_user_left(msg.payload)
  elseif msg.type == "SYNC" then
    M.on_sync(msg.payload)
  elseif msg.type == "CURSOR" then
    M.on_cursor(msg.client_id, msg.payload)
  elseif msg.type == "EDIT" then
    M.on_edit(msg.client_id, msg.payload)
  end
end

local function get_user_color(client_id)
  if state.users[client_id] and state.users[client_id].color then
    return state.users[client_id].color
  end
  return "#FFFFFF"
end

function M.on_join_good(payload)
  vim.notify("Joined session! Active users: " .. #payload.active_users, vim.log.levels.INFO)
  for _, user in ipairs(payload.active_users) do
    state.users[user.id] = user
  end

  state.known_server_files = {}
  if payload.available_files then
    for _, path in ipairs(payload.available_files) do
      state.known_server_files[path] = true

      -- Pre-register buffer
      if not state.is_host then
        state.register_file(path, nil, true)
      end
    end
    vim.notify("Server has " .. #payload.available_files .. " files available.", vim.log.levels.INFO)
  end
end

function M.on_user_joined(payload)
  local user = payload.user
  if not user then return end

  vim.notify(user.username .. " joined the session.", vim.log.levels.INFO)

  state.users[user.id] = user
end

function M.on_user_left(payload)
  local user_id = payload.user_id
  local name = payload.username or user_id

  vim.notify(name .. " left the session (" .. (payload.reason or "unknown") .. ")", vim.log.levels.INFO)

  cursor_ui.remove_cursor(user_id)
  state.users[user_id] = nil
end

function M.on_sync(payload)
  local path = payload.path
  local content = payload.content
  local revision = payload.revision

  -- Sync file
  local buf = state.register_file(path, content, true)

  -- Sync revision
  if revision then
    state.set_revision(path, revision)
  end

  -- Sync cursors
  if payload.cursors then
    for _, c in ipairs(payload.cursors) do
      if c.client_id ~= state.client_id then
        if not state.users[c.client_id] then
          state.users[c.client_id] = { id = c.client_id, username = c.client_id, color = "#FFFFFF" }
        end
        state.users[c.client_id].cursor = {
          path = path,
          line = c.pos[1],
          col = c.pos[2]
        }

        local current_buf = vim.api.nvim_get_current_buf()
        if buf == current_buf then
          cursor_ui.setup_cursor(
            c.client_id,
            c.pos[1],
            c.pos[2],
            c.selection,
            get_user_color(c.client_id)
          )
        end
      end
    end
  end
end

function M.on_cursor(sender_id, payload)
  if sender_id == state.client_id then return end

  if not state.users[sender_id] then
    state.users[sender_id] = { id = sender_id, username = sender_id, color = "#FFFFFF" }
  end

  state.users[sender_id].cursor = {
    path = payload.path,
    line = payload.pos[1],
    col = payload.pos[2]
  }

  local path = payload.path
  local buf = state.get_buf_by_path(path)
  local current_buf = vim.api.nvim_get_current_buf()

  if buf and buf == current_buf then
    cursor_ui.setup_cursor(
      sender_id,
      state.users[sender_id].username or sender_id,
      payload.pos[1],
      payload.pos[2],
      payload.selection,
      get_user_color(sender_id)
    )
  else
    cursor_ui.remove_cursor(sender_id)
  end
end

function M.on_edit(sender_id, payload)
  if sender_id == state.client_id then return end

  local path = payload.path
  local buf = state.get_buf_by_path(path)

  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if vim.fn.bufwinnr(buf) == -1 then return end

  local op = payload.op
  local s_row, s_col = op.start.row, op.start.col
  local e_row, e_col = op["end"].row, op["end"].col
  local text = op.text

  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count == 0 then return end

  -- Clamp Row/Col to valid text area
  local function clamp_pos(row, col)
    if row >= line_count then
      row = line_count - 1
      local lines = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
      col = lines[1] and #lines[1] or 0
    else
      local lines = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
      local len = lines[1] and #lines[1] or 0
      if col > len then col = len end
    end
    return row, col
  end
  s_row, s_col = clamp_pos(s_row, s_col)
  e_row, e_col = clamp_pos(e_row, e_col)
  if s_row > e_row or (s_row == e_row and s_col > e_col) then
    e_row, e_col = s_row, s_col
  end

  state.is_applying_edit = true

  local ok, err = pcall(vim.api.nvim_buf_set_text, buf,
    s_row, s_col,
    e_row, e_col,
    text
  )

  if ok then
    if payload.revision then
      state.set_revision(path, payload.revision)
    end
  else
    vim.notify(string.format(
      "Collab Apply Error: %s\nRange: (%d,%d) -> (%d,%d)\nLines: %d",
      tostring(err), s_row, s_col, e_row, e_col, line_count
    ), vim.log.levels.ERROR)
  end

  state.is_applying_edit = false
end

function M.handle_disconnect()
  cursor_ui.clear_all()
end

return M
