local M = {}

local ns_id = vim.api.nvim_create_namespace("collab_cursors")
local active_cursors = {}
local is_visible = true

local palette = { "Identifier", "String", "Constant", "Statement", "PreProc", "Type" }

function M.get_users()
  local users = {}
  for name, _ in pairs(active_cursors) do
    table.insert(users, name)
  end
  return users
end

function M.setup_cursor(user, line, col)
  M.remove_cursor_ui(user)
  local color_idx = (#user % #palette) + 1
  local base_hl = palette[color_idx]
  local hl_data = vim.api.nvim_get_hl(0, { name = base_hl, link = false })
  local color = hl_data.fg or 0xFFFFFF

  local user_hl = "CollabUser_" .. user
  local block_hl = "CollabBlock_" .. user
  vim.api.nvim_set_hl(0, user_hl, { fg = color, italic = true })
  vim.api.nvim_set_hl(0, block_hl, { bg = color, fg = 0 })

  local mark_id = nil
  if is_visible then
    mark_id = vim.api.nvim_buf_set_extmark(0, ns_id, line, col, {
      virt_text = { { " ", block_hl }, { " " .. user, user_hl } },
      virt_text_pos = "overlay",
    })
  end

  active_cursors[user] = { mark_id = mark_id, last_pos = { line, col } }
end

function M.remove_cursor_ui(user)
  if active_cursors[user] and active_cursors[user].mark_id then
    pcall(vim.api.nvim_buf_del_extmark, 0, ns_id, active_cursors[user].mark_id)
    active_cursors[user].mark_id = nil
  end
end

function M.hide_all()
  if not is_visible then return end
  for user, data in pairs(active_cursors) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(0, ns_id, data.mark_id, {})
    if pos and #pos > 0 then data.last_pos = pos end
    M.remove_cursor_ui(user)
  end
  is_visible = false
  print("Collab: Cursors hidden")
end

function M.show_all()
  if is_visible then return end
  is_visible = true
  for user, data in pairs(active_cursors) do
    M.setup_cursor(user, data.last_pos[1], data.last_pos[2])
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
