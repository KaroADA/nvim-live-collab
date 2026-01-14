-- lua/collab/init.lua

local M = {}

-- Moduły ładujemy tutaj, na górze pliku.
-- Zostaną wczytane dopiero, gdy plugin/collab.lua wywoła funkcję z tego pliku.
local transport = require("collab.transport")
local protocol = require("collab.protocol")
local handlers = require("collab.handlers")
local state = require("collab.state")

-- Hardcoded config na potrzeby POC
local HOST = "127.0.0.1"
local PORT = 8080

-- Funkcja pomocnicza: włącza śledzenie kursora dopiero po starcie sesji
local function enable_tracking()
  local group = vim.api.nvim_create_augroup("CollabActive", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function()
      -- Jeśli nie jesteśmy połączeni, nie rób nic
      if not transport.client then return end

      local buf = vim.api.nvim_get_current_buf()
      -- Ignoruj bufory, które nie są plikami (np. NvimTree, Telescope)
      if vim.bo[buf].buftype ~= "" then return end

      local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
      local cursor = vim.api.nvim_win_get_cursor(0) -- (1-indexed row, 0-indexed col)

      -- Konwersja na 0-indexed row dla protokołu
      local msg = protocol.cursor(state.client_id, path, cursor[1] - 1, cursor[2])
      transport.send(msg)
    end
  })
end

function M.start_host(username)
  state.is_host = true
  state.username = (username and username ~= "") and username or "Host"

  vim.notify("Collab: Connecting as Host...", vim.log.levels.INFO)

  transport.connect(HOST, PORT, function(msg)
    handlers.handle_message(msg)
  end)

  -- Gdy (i jeśli) TCP połączy, wyślij START_SESSION
  -- W idealnym świecie transport.connect przyjmowałby callback `on_connect`
  -- Tutaj używamy timera dla uproszczenia w POC
  vim.defer_fn(function()
    if transport.client then
      local msg = protocol.start_session(state.client_id, "MyProject")
      transport.send(msg)
      enable_tracking() -- Włączamy śledzenie kursora
      vim.notify("Collab: Session initialized.", vim.log.levels.INFO)
    end
  end, 500)
end

function M.join_session(username)
  state.is_host = false
  state.username = (username and username ~= "") and username or "Guest"

  vim.notify("Collab: Connecting as Guest...", vim.log.levels.INFO)

  transport.connect(HOST, PORT, function(msg)
    handlers.handle_message(msg)
  end)

  vim.defer_fn(function()
    if transport.client then
      local msg = protocol.join(state.client_id, state.username)
      transport.send(msg)
      enable_tracking() -- Włączamy śledzenie kursora
      vim.notify("Collab: Join request sent.", vim.log.levels.INFO)
    end
  end, 500)
end

return M
