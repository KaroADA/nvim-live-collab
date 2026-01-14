-- plugin/collab.lua

if vim.g.loaded_collab == 1 then
  return
end
vim.g.loaded_collab = 1

-- --- DX Fix: Robust Load ---
-- Jeśli uruchamiamy plugin lokalnie bez instalacji, dodaj CWD do rtp.
local function ensure_on_rtp()
  local ok, _ = pcall(require, "collab.init")
  if not ok then
    vim.opt.rtp:prepend(".")
  end
end
ensure_on_rtp()
-- ----------------------------

-- Komenda dla Hosta
vim.api.nvim_create_user_command("CollabHost", function(opts)
  -- Dopiero tutaj ładujemy ciężką logikę!
  require("collab").start_host(opts.args)
end, { nargs = "?" })

-- Komenda dla Gościa
vim.api.nvim_create_user_command("CollabJoin", function(opts)
  require("collab").join_session(opts.args)
end, { nargs = "?" })

-- Komendy Debugowe/UI (delegują do modułu)
vim.api.nvim_create_user_command("CollabHide", function() require("collab.cursor").hide_all() end, {})
vim.api.nvim_create_user_command("CollabShow", function() require("collab.cursor").show_all() end, {})

-- Przeładowanie (DX)
vim.api.nvim_create_user_command("CollabReload", function()
  -- Czyścimy cache Lua
  for k in pairs(package.loaded) do
    if k:match("^collab") then
      package.loaded[k] = nil
    end
  end
  -- Czyścimy UI
  pcall(require("collab.cursor").clear_all)

  vim.notify("Collab: Reloaded. Run :CollabHost or :CollabJoin again.", vim.log.levels.INFO)
end, {})
