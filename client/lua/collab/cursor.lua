local M = {}

local ns_id = vim.api.nvim_create_namespace("collab_cursors")
local active_cursors = {}
local is_visible = true

function M.get_users()
  local users = {}
  for _, data in pairs(active_cursors) do
    table.insert(users, data.username)
  end
  return users
end

local function ensure_hl_groups(client_id, color_hex)
  local safe_user = client_id:gsub("%W", "_")
  local user_hl = "CollabUser_" .. safe_user
  local block_hl = "CollabBlock_" .. safe_user
  vim.api.nvim_set_hl(0, user_hl, { fg = color_hex, italic = true, default = false })
  vim.api.nvim_set_hl(0, block_hl, { bg = color_hex, fg = "#000000", default = false })
  return user_hl, block_hl
end

function M.setup_cursor(client_id, username, line, col, selection, color_hex)
  M.remove_cursor_ui(client_id)
  color_hex = color_hex or "#FFFFFF"
  local user_hl, block_hl = ensure_hl_groups(client_id, color_hex)

  local mark_id = nil
  local label_id = nil
  local selection_id = nil

  if is_visible then
    local line_count = vim.api.nvim_buf_line_count(0)
    if selection and selection ~= vim.NIL and selection.start then
      local s_row, s_col = selection.start[1], selection.start[2]
      local e_row, e_col = selection["end"][1], selection["end"][2]
      if s_row < line_count and e_row < line_count then
        local lines = vim.api.nvim_buf_get_lines(0, e_row, e_row + 1, false)
        local end_line_len = lines[1] and #lines[1] or 0
        if e_col > end_line_len then e_col = end_line_len end
        _, selection_id = pcall(vim.api.nvim_buf_set_extmark, 0, ns_id, s_row, s_col, {
          end_row = e_row,
          end_col = e_col,
          hl_group = "Visual",
          priority = 90,
        })
      end
    end
    if not line or line == vim.NIL then line = 0 end
    if not col or col == vim.NIL then col = 0 end
    if line >= line_count then
      line = line_count - 1
    end
    local lines = vim.api.nvim_buf_get_lines(0, line, line + 1, false)
    local end_line_len = lines[1] and #lines[1] or 0
    if col > end_line_len then
      col = end_line_len
    end
    mark_id = vim.api.nvim_buf_set_extmark(0, ns_id, line, col, {
      virt_text = { { " ", block_hl } },
      virt_text_pos = "overlay",
      priority = 100,
    })

    label_id = vim.api.nvim_buf_set_extmark(0, ns_id, line, 0, {
      virt_text = { { " " .. username, user_hl } },
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
  end

  active_cursors[client_id] = {
    mark_id = mark_id,
    label_id = label_id,
    selection_id = selection_id,
    last_pos = { line, col }
  }
end

function M.remove_cursor_ui(client_id)
  if active_cursors[client_id] and active_cursors[client_id].mark_id then
    pcall(vim.api.nvim_buf_del_extmark, 0, ns_id, active_cursors[client_id].mark_id)
    pcall(vim.api.nvim_buf_del_extmark, 0, ns_id, active_cursors[client_id].label_id)
    pcall(vim.api.nvim_buf_del_extmark, 0, ns_id, active_cursors[client_id].selection_id)
    active_cursors[client_id].mark_id = nil
    active_cursors[client_id].label_id = nil
    active_cursors[client_id].selection_id = nil
  end
end

function M.hide_all()
  if not is_visible then return end
  for client_id, data in pairs(active_cursors) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(0, ns_id, data.mark_id, {})
    if pos and #pos > 0 then data.last_pos = pos end
    M.remove_cursor_ui(client_id)
  end
  is_visible = false
  print("Collab: Cursors hidden")
end

function M.show_all()
  if is_visible then return end
  is_visible = true
  for client_id, data in pairs(active_cursors) do
    M.setup_cursor(client_id, data.username, data.last_pos[1], data.last_pos[2])
  end
  print("Collab: Cursors shown")
end

function M.jump_to_user(user)
  local data = active_cursors[user]
  if not data then return vim.notify("User " .. user .. " not found.", vim.log.levels.ERROR) end
  local row, col
  if is_visible and data.mark_id then
    local pos = vim.api.nvim_buf_get_extmark_by_id(0, ns_id, data.mark_id, {})
    row, col = pos[1], pos[2]
  else
    row, col = data.last_pos[1], data.last_pos[2]
  end
  vim.api.nvim_win_set_cursor(0, { row + 1, col })
end

function M.remove_cursor(user)
  M.remove_cursor_ui(user)
  active_cursors[user] = nil
end

function M.clear_all()
  vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
  active_cursors = {}
  is_visible = true
end

return M
