local M = {}

M.client_id = "user-" .. tostring(math.random(1000, 9999))
M.username = "Unknown"
M.is_host = false

-- When TRUE, the on_bytes listener will ignore changes.
M.is_applying_edit = false

-- Map file path to buffer id
M.path_to_buf = {}
M.file_revisions = {}
M.known_server_files = {}

M.users = {}

function M.get_buf_by_path(path)
  if M.path_to_buf[path] and vim.api.nvim_buf_is_valid(M.path_to_buf[path]) then
    return M.path_to_buf[path]
  end
  return nil
end

function M.get_revision(path)
  return M.file_revisions[path] or 0
end

function M.set_revision(path, rev)
  M.file_revisions[path] = rev
end

function M.register_file(path, content, create_if_missing)
  local buf = M.get_buf_by_path(path)

  if not buf and create_if_missing then
    -- BRANCHING LOGIC: HOST vs GUEST
    if M.is_host then
      -- HOST: Tries to find the REAL file on disk first
      -- If it's already open in Neovim, use it.
      buf = vim.fn.bufnr(path)
      if buf == -1 then
        buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, path)
      end
    else
      -- GUEST: Always creates a new SCRATCH buffer
      buf = vim.api.nvim_create_buf(true, false)

      -- Set name to "collab://src/main.rs" so it looks distinct
      -- and doesn't conflict with local files
      vim.api.nvim_buf_set_name(buf, "collab://" .. path)

      -- Set buftype to 'nofile' (The "Phantom" Buffer)
      vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
      vim.api.nvim_set_option_value("swapfile", false, { buf = buf })

      -- Auto-detect filetype for syntax highlighting
      local extension = vim.fn.fnamemodify(path, ":e")
      if extension ~= "" then
        vim.api.nvim_set_option_value("filetype", extension, { buf = buf })
        -- Or use: vim.filetype.match({ filename = path })
      end
    end

    -- UNIFICATION: Tag the buffer
    vim.b[buf].collab_enabled = true
    -- Store the relative path in the buffer for easy access later
    vim.b[buf].collab_path = path

    M.path_to_buf[path] = buf
    M.file_revisions[path] = 0
  end

  if buf and content then
    local was_applying = M.is_applying_edit
    M.is_applying_edit = true

    -- For guest scratch buffers, we must ensure they are modifiable before writing
    vim.bo[buf].modifiable = true
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, content)

    M.is_applying_edit = was_applying
  end

  return buf
end

return M
