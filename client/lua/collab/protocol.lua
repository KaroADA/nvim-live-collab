local M = {}

local function timestamp()
  return os.time() * 1000
end

function M.start_session(client_id, project_name)
  local files = {}
  local current_buf = vim.api.nvim_get_current_buf()

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not vim.api.nvim_buf_is_loaded(buf) then goto continue end
    if not vim.api.nvim_get_option_value('buflisted', { buf = buf }) then goto continue end
    if vim.api.nvim_get_option_value('buftype', { buf = buf }) ~= "" then goto continue end

    local path = vim.api.nvim_buf_get_name(buf)
    if path == "" then goto continue end

    path = vim.fn.fnamemodify(path, ":."):gsub("\\", "/")
    local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    local my_cursor = nil
    if current_buf == buf then
      local cursor = vim.api.nvim_win_get_cursor(0)
      my_cursor = { pos = { cursor[1] - 1, cursor[2] }, selection = nil }
    end

    table.insert(files, {
      path = path,
      content = content,
      is_writeable = vim.bo[buf].modifiable,
      my_cursor = my_cursor
    })

    ::continue::
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

function M.end_session(client_id)
  return {
    type = "END_SESSION",
    client_id = client_id,
    timestamp = timestamp(),
    payload = { reason = "Host ended session" }
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

function M.request_sync(client_id, path)
  return {
    type = "SYNC",
    client_id = client_id,
    timestamp = timestamp(),
    payload = {
      path = path
    }
  }
end

function M.edit(client_id, path, start_row, start_col, end_row, end_col, text_lines, revision)
  return {
    type = "EDIT",
    client_id = client_id,
    timestamp = timestamp(),
    payload = {
      path = path,
      revision = revision,
      op = {
        start = { row = start_row, col = start_col },
        ["end"] = { row = end_row, col = end_col },
        text = text_lines
      }
    }
  }
end

function M.cursor(client_id, path, line, col, selection)
  return {
    type = "CURSOR",
    client_id = client_id,
    timestamp = timestamp(),
    payload = {
      path = path,
      pos = { line, col },
      selection = selection
    }
  }
end

return M
