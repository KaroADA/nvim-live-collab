local M = {}
local uv = vim.loop

M.client = nil
M.on_message = nil

function M.connect(host, port, on_message_callback)
  M.client = uv.new_tcp()
  M.on_message = on_message_callback

  M.client:connect(host, port, function(err)
    if err then
      vim.schedule(function()
        vim.notify("Collab: Connection error: " .. err, vim.log.levels.ERROR)
      end)
      return
    end

    vim.schedule(function()
      vim.notify("Collab: Connected to " .. host .. ":" .. port, vim.log.levels.INFO)
    end)

    local buffer = ""
    
    M.client:read_start(function(read_err, chunk)
      if read_err then return end
      if chunk then
        buffer = buffer .. chunk
        -- Zakładamy, że wiadomości są oddzielone nową linią (NDJSON)
        -- W produkcji warto użyć length-prefixed protocol
        while true do
          local line_end = string.find(buffer, "\n")
          if not line_end then break end
          
          local line = string.sub(buffer, 1, line_end - 1)
          buffer = string.sub(buffer, line_end + 1)

          vim.schedule(function()
            local ok, decoded = pcall(vim.json.decode, line)
            if ok then
              M.on_message(decoded)
            else
              vim.notify("Collab: JSON Decode Error", vim.log.levels.ERROR)
            end
          end)
        end
      else
        -- EOF
        M.client:close()
        vim.schedule(function()
          vim.notify("Collab: Disconnected (EOF)", vim.log.levels.WARN)
          -- Trigger USER_LEFT logic logic locally or cleanup
          require("collab.handlers").handle_disconnect()
        end)
      end
    end)
  end)
end

function M.send(payload)
  if not M.client then return end
  local ok, encoded = pcall(vim.json.encode, payload)
  if ok then
    M.client:write(encoded .. "\n")
  end
end

return M
