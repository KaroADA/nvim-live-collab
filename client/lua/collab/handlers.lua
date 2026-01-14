local M = {}
local state = require("collab.state")
local cursor_ui = require("collab.cursor") -- Nasz moduł z poprzedniego kroku!

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
  -- Zapisz listę userów w stanie
  for _, user in ipairs(payload.active_users) do
    state.users[user.id] = user
  end

  -- Jeśli nie jesteśmy hostem, możemy poprosić o pliki (SYNC) tutaj
  -- Ale protokół mówi, że dostajemy listę "available_files".
  -- UI mogłoby je wyświetlić.
end

function M.on_user_left(payload)
  local user_id = payload.user_id
  local name = payload.username or user_id

  vim.notify(name .. " left the session (" .. (payload.reason or "unknown") .. ")", vim.log.levels.INFO)

  -- Używamy naszego modułu UI do usunięcia kursora
  cursor_ui.remove_cursor(user_id)
  state.users[user_id] = nil
end

function M.on_sync(payload)
  local path = payload.path
  local content = payload.content

  -- 1. Zaktualizuj bufor
  local buf = state.register_file(path, content, true)

  -- 2. Zaktualizuj kursory w tym pliku (jeśli są w payloadzie)
  if payload.cursors then
    for _, c in ipairs(payload.cursors) do
      -- Pomijamy własny kursor
      if c.client_id ~= state.client_id then
        -- Sprawdzamy, czy ten user jest aktualnie w tym pliku co my
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

  -- Rysujemy kursor tylko jeśli patrzymy na ten sam plik
  if buf and buf == current_buf then
    -- payload.pos to [row, col] (0-indexed)
    cursor_ui.setup_cursor(sender_id, payload.pos[1], payload.pos[2])
  else
    -- Jeśli użytkownik przeszedł do innego pliku, usuwamy go z bieżącego widoku
    cursor_ui.remove_cursor(sender_id)
  end
end

function M.on_edit(sender_id, payload)
  if sender_id == state.client_id then return end
  -- To jest trudna część (Delta Edits).
  -- Dla uproszczenia w tym POC: zakładamy, że EDIT odświeża linię/plik
  -- W pełnej wersji: nvim_buf_set_text
end

function M.handle_disconnect()
  cursor_ui.clear_all()
end

return M
