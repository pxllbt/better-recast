-- Usage: lua read-binds.lua [config.lua]
--
-- Prints every keybind in ~/.config/hypr/hyprland.lua (or the given file) as
-- modmask<TAB>description<TAB>key<TAB>dispatcher<TAB>arg, by running the config
-- under a stub `hl` table. `hyprctl binds -j` reports every Lua bind as
-- dispatcher "__lua", so this is the only way to see which command a bind runs.
--
-- Adapted from the Lua scanner in Omarchy's omarchy-menu-keybindings
-- (build_lua_bind_cache). Change from upstream: binds without a description
-- are printed too, so an undescribed `px-recast` bind is still found.

local modifiers = { SHIFT = 1, CTRL = 4, CONTROL = 4, ALT = 8, SUPER = 64 }

local function split_keys(keys)
  local modmask = 0
  local key = ""

  for part in string.gmatch(tostring(keys or ""), "[^+]+") do
    local value = part:gsub("^%s+", ""):gsub("%s+$", "")
    local modifier = modifiers[string.upper(value)]

    if modifier then
      modmask = modmask + modifier
    else
      key = value
    end
  end

  return modmask, key
end

local function lua_literal(value)
  local value_type = type(value)

  if value_type == "string" then
    return string.format("%q", value)
  elseif value_type == "number" or value_type == "boolean" then
    return tostring(value)
  elseif value_type == "table" then
    local parts = {}
    local keys = {}
    local array_length = #value

    for index = 1, array_length do
      parts[#parts + 1] = lua_literal(value[index])
    end

    for key in pairs(value) do
      if not (type(key) == "number" and key >= 1 and key <= array_length and math.floor(key) == key) then
        keys[#keys + 1] = key
      end
    end

    table.sort(keys, function(left, right)
      return tostring(left) < tostring(right)
    end)

    for _, key in ipairs(keys) do
      local key_prefix
      if type(key) == "string" and key:match("^[%a_][%w_]*$") then
        key_prefix = key .. " = "
      else
        key_prefix = "[" .. lua_literal(key) .. "] = "
      end

      parts[#parts + 1] = key_prefix .. lua_literal(value[key])
    end

    return "{ " .. table.concat(parts, ", ") .. " }"
  elseif value_type == "nil" then
    return "nil"
  else
    return "nil"
  end
end

local function call_expression(path, ...)
  local args = {}

  for index = 1, select("#", ...) do
    args[index] = lua_literal(select(index, ...))
  end

  return path .. "(" .. table.concat(args, ", ") .. ")"
end

local function dispatcher(kind, arg, expr)
  return {
    __omarchy_dispatcher = true,
    kind = kind or "",
    arg = arg or "",
    expr = expr or "",
  }
end

local function dsp_proxy(path)
  return setmetatable({ path = path }, {
    __index = function(self, key)
      return dsp_proxy(self.path .. "." .. tostring(key))
    end,
    __call = function(self, ...)
      local first_arg = ...
      local expr = call_expression(self.path, ...)

      if self.path == "hl.dsp.exec_cmd" and type(first_arg) == "string" then
        return dispatcher("exec", first_arg, expr)
      end

      return dispatcher("lua", expr, expr)
    end,
  })
end

local noop
noop = setmetatable({}, {
  __index = function()
    return noop
  end,
  __call = function()
    return noop
  end,
})

hl = setmetatable({
  dsp = dsp_proxy("hl.dsp"),
  bind = function(keys, bind_dispatcher, opts)
    opts = opts or {}

    do
      local modmask, key = split_keys(keys)
      local kind = ""
      local arg = ""

      if type(bind_dispatcher) == "table" and bind_dispatcher.__omarchy_dispatcher then
        kind = bind_dispatcher.kind or ""
        arg = bind_dispatcher.arg or bind_dispatcher.expr or ""
      elseif type(bind_dispatcher) == "string" and bind_dispatcher ~= "" then
        kind = "exec"
        arg = bind_dispatcher
      end

      print(table.concat({ tostring(modmask), opts.description or "", key, kind, arg }, "\t"))
    end

    return noop
  end,
  get_config = function()
    return nil
  end,
}, {
  __index = function()
    return noop
  end,
})

local config = (arg and arg[1]) or (os.getenv("HOME") .. "/.config/hypr/hyprland.lua")
local file = io.open(config, "r")

if file then
  file:close()
  local ok, err = pcall(dofile, config)
  if not ok and os.getenv("DEBUG") == "1" then
    io.stderr:write("[DEBUG] lua bind scan failed: " .. tostring(err) .. "\n")
  end
end
