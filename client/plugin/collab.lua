if vim.g.loaded_collab == 1 then
  return
end
vim.g.loaded_collab = 1

local ok, _ = pcall(require, "collab")
if not ok then
  -- for development
  vim.opt.rtp:prepend(".")
  ok, _ = pcall(require, "collab")
  if not ok then
    vim.notify("Could not load 'collab' module.\n" ..
      "Ensure you're in the client directory.",
      vim.log.levels.ERROR)
    return
  end
end

vim.api.nvim_create_user_command("CollabHost", function(opts)
  require("collab").start_host(opts.args)
end, { nargs = "?" })

vim.api.nvim_create_user_command("CollabJoin", function(opts)
  require("collab").join_session(opts.args)
end, { nargs = "?" })

vim.api.nvim_create_user_command("CollabHide", function() require("collab.cursor").hide_all() end, {})
vim.api.nvim_create_user_command("CollabShow", function() require("collab.cursor").show_all() end, {})

vim.api.nvim_create_user_command("CollabReload", function()
  for k in pairs(package.loaded) do
    if k:match("^collab") then
      package.loaded[k] = nil
    end
  end
  pcall(require("collab.cursor").clear_all)

  vim.notify("Collab: Reloaded. Run :CollabHost or :CollabJoin again.", vim.log.levels.INFO)
end, {})
