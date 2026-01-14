local M = {}

M.client_id = "user-" .. tostring(math.random(1000, 9999)) -- Tymczasowe ID
M.username = "Unknown"
M.is_host = false

-- Mapowanie: "src/main.rs" -> Buffer ID
M.path_to_buf = {}

-- Przechowywanie informacji o użytkownikach (kolory itp.)
M.users = {}

function M.get_buf_by_path(path)
  -- 1. Sprawdź cache
  if M.path_to_buf[path] and vim.api.nvim_buf_is_valid(M.path_to_buf[path]) then
    return M.path_to_buf[path]
  end

  -- 2. Jeśli nie ma w cache, spróbuj znaleźć w Neovim
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
    -- Tworzymy nowy bufor, bo Gość go nie ma
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, path)
    M.path_to_buf[path] = buf
  end

  if buf and content then
    -- Wypełnij treścią (dla SYNC)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  end

  return buf
end

return M
