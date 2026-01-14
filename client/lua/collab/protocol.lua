local M = {}

local function timestamp()
  return os.time() * 1000 -- Symulacja milisekund
end

-- HOST: START_SESSION
function M.start_session(client_id, project_name)
  local files = {}
  -- Pobierz wszystkie załadowane bufory
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local path = vim.api.nvim_buf_get_name(buf)
      -- Relatywna ścieżka (uproszczone)
      path = vim.fn.fnamemodify(path, ":.")

      local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      -- Pobierz pozycję kursora hosta
      local cursor = vim.api.nvim_win_get_cursor(0)
      local is_current = (vim.api.nvim_get_current_buf() == buf)

      local my_cursor = nil
      if is_current then
        -- API zwraca (row, col) 1-indexed row, protocol woli 0-indexed?
        -- Ustalmy: Protokół = 0-indexed (programistyczny standard)
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

-- GUEST: JOIN
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

-- SHARED: CURSOR
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
