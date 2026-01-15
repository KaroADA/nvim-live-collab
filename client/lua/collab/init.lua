local M = {}

local transport = require("collab.transport")
local protocol = require("collab.protocol")
local handlers = require("collab.handlers")
local state = require("collab.state")

local HOST = "127.0.0.1"
local PORT = 8080

local function enable_cursor_tracking()
  local group = vim.api.nvim_create_augroup("CollabActive", { clear = true })
  local timer = assert((vim.uv or vim.loop).new_timer())
  local THROTTLE_MS = 200
  local pending_update = false

  local function send_cursor_payload()
    if not transport.client then return end
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= "" then return end
    local path = vim.api.nvim_buf_get_name(buf)
    if path == "" then return end
    path = vim.fn.fnamemodify(path, ":.")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local msg = protocol.cursor(state.client_id, path, cursor[1] - 1, cursor[2])
    transport.send(msg)
  end

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function()
      if timer:is_active() then
        pending_update = true
        return
      end
      send_cursor_payload()
      timer:start(THROTTLE_MS, 0, vim.schedule_wrap(function()
        if pending_update then
          send_cursor_payload()
          pending_update = false
        end
      end))
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

  -- After 500ms check if connection was ok, then send StartSession
  vim.defer_fn(function()
    if transport.client then
      local msg = protocol.start_session(state.client_id, "MyProject")
      transport.send(msg)
      enable_cursor_tracking()
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
      enable_cursor_tracking()
      vim.notify("Collab: Join request sent.", vim.log.levels.INFO)
    end
  end, 500)
end

return M
