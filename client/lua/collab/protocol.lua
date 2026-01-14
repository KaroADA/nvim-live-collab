local M = {}

local function timestamp()
  return os.time() * 1000
end

function M.start_session(client_id, project_name)
  local files = {}
  -- Get all open files
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local path = vim.api.nvim_buf_get_name(buf)
      -- Relative path
      path = vim.fn.fnamemodify(path, ":.")

      local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      local cursor = vim.api.nvim_win_get_cursor(0)
      local is_current = (vim.api.nvim_get_current_buf() == buf)

      local my_cursor = nil
      if is_current then
        my_cursor = { pos = { cursor[1] - 1, cursor[2] }, selection = nil }
      end

      table.insert(files, {
        path = path,
        content = content,
        is_writeable = vim.bo[buf].modifiable,
        my_cursor = my_cursor
      })
    end
  end

  return {
    type = "START_SESSION",
    client_id = client_id,
    timestamp = timestamp(),
    payload = {
      project_name = project_name,
      files = files
    }
  }
end

function M.join(client_id, username)
  return {
    type = "JOIN",
    client_id = client_id,
    timestamp = timestamp(),
    payload = {
      username = username,
      client_version = "0.1.0"
    }
  }
end

function M.cursor(client_id, path, line, col)
  return {
    type = "CURSOR",
    client_id = client_id,
    timestamp = timestamp(),
    payload = {
      path = path,
      pos = { line, col },
      selection = nil
    }
  }
end

return M
