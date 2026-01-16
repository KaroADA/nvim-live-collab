local M = {}

M.client_id = "user-" .. tostring(math.random(1000, 9999))
M.username = "Unknown"
M.is_host = false

-- When TRUE, the on_bytes listener will ignore changes.
M.is_applying_edit = false

-- Map file path to buffer id
M.path_to_buf = {}

M.users = {}

function M.get_buf_by_path(path)
  if M.path_to_buf[path] and vim.api.nvim_buf_is_valid(M.path_to_buf[path]) then
    return M.path_to_buf[path]
  end

  local bufs = vim.api.nvim_list_bufs()
  for _, buf in ipairs(bufs) do
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
    if name == path then
      M.path_to_buf[path] = buf
      return buf
    end
  end

  return nil
end

function M.register_file(path, content, create_if_missing)
  local buf = M.get_buf_by_path(path)

  if not buf and create_if_missing then
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, path)
    M.path_to_buf[path] = buf
  end

  if buf and content then
    local was_applying = M.is_applying_edit
    M.is_applying_edit = true
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, content)
    M.is_applying_edit = was_applying
    vim.bo[buf].modifiable = true
  end

  return buf
end

return M
