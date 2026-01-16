local M = {}
local state = require("collab.state")
local cursor_ui = require("collab.cursor")

function M.handle_message(msg)
  if not msg or not msg.type then return end

  if msg.type == "JOIN_GOOD" then
    M.on_join_good(msg.payload)
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
        local current_buf = vim.api.nvim_get_current_buf()
        if buf == current_buf then
          cursor_ui.setup_cursor(c.client_id, c.pos[1], c.pos[2])
        end
      end
    end
  end
end

function M.on_cursor(sender_id, payload)
  if sender_id == state.client_id then return end

  local path = payload.path
  local buf = state.get_buf_by_path(path)
  local current_buf = vim.api.nvim_get_current_buf()

  if buf and buf == current_buf then
    cursor_ui.setup_cursor(sender_id, payload.pos[1], payload.pos[2])
  else
    cursor_ui.remove_cursor(sender_id)
  end
end

function M.on_edit(sender_id, payload)
  if sender_id == state.client_id then return end

  local path = payload.path
  local buf = state.get_buf_by_path(path)

  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  -- Ignore edits if the buffer is not visible
  if vim.fn.bufwinnr(buf) == -1 then return end

  local op = payload.op
  local start_pos = op.start
  local end_pos = op["end"]
  local text = op.text

  state.is_applying_edit = true

  -- Apply the edit
  local ok, err = pcall(vim.api.nvim_buf_set_text, buf,
    start_pos.row,
    start_pos.col,
    end_pos.row,
    end_pos.col,
    text
  )

  if ok then
    -- Update our local revision to match the server
    if payload.revision then
      state.set_revision(path, payload.revision)
    end
  else
    vim.notify("Collab Apply Error: " .. tostring(err), vim.log.levels.ERROR)
    -- Maybe re-sync
  end
  state.is_applying_edit = false
end

function M.handle_disconnect()
  cursor_ui.clear_all()
end

return M
