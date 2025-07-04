local Path = require "obsidian.path"
local log = require "obsidian.log"
local run_job = require("obsidian.async").run_job
local api = require "obsidian.api"
local util = require "obsidian.util"

local M = {}

-- Image pasting adapted from https://github.com/ekickx/clipboard-image.nvim

---@return string
local function get_clip_check_command()
  local check_cmd
  local this_os = api.get_os()
  if this_os == api.OSType.Linux or this_os == api.OSType.FreeBSD then
    local display_server = os.getenv "XDG_SESSION_TYPE"
    if display_server == "x11" or display_server == "tty" then
      check_cmd = "xclip -selection clipboard -o -t TARGETS"
    elseif display_server == "wayland" then
      check_cmd = "wl-paste --list-types"
    end
  elseif this_os == api.OSType.Darwin then
    check_cmd = "pngpaste -b 2>&1"
  elseif this_os == api.OSType.Windows or this_os == api.OSType.Wsl then
    check_cmd = 'powershell.exe "Get-Clipboard -Format Image"'
  else
    error("image saving not implemented for OS '" .. this_os .. "'")
  end
  return check_cmd
end

--- Check if clipboard contains image data.
---
---@return boolean
local function clipboard_is_img()
  local check_cmd = get_clip_check_command()
  local result_string = vim.fn.system(check_cmd)
  local content = vim.split(result_string, "\n")

  local is_img = false
  -- See: [Data URI scheme](https://en.wikipedia.org/wiki/Data_URI_scheme)
  local this_os = api.get_os()
  if this_os == api.OSType.Linux or this_os == api.OSType.FreeBSD then
    if vim.tbl_contains(content, "image/png") then
      is_img = true
    elseif vim.tbl_contains(content, "text/uri-list") then
      local success =
        os.execute "wl-paste --type text/uri-list | sed 's|file://||' | head -n1 | tr -d '[:space:]' | xargs -I{} sh -c 'wl-copy < \"$1\"' _ {}"
      is_img = success == 0
    end
  elseif this_os == api.OSType.Darwin then
    is_img = string.sub(content[1], 1, 9) == "iVBORw0KG" -- Magic png number in base64
  elseif this_os == api.OSType.Windows or this_os == api.OSType.Wsl then
    is_img = content ~= nil
  else
    error("image saving not implemented for OS '" .. this_os .. "'")
  end
  return is_img
end

--- TODO: refactor with run_job?

--- Save image from clipboard to `path`.
---@param path string
---
---@return boolean|integer|? result
local function save_clipboard_image(path)
  local this_os = api.get_os()

  if this_os == api.OSType.Linux or this_os == api.OSType.FreeBSD then
    local cmd
    local display_server = os.getenv "XDG_SESSION_TYPE"
    if display_server == "x11" or display_server == "tty" then
      cmd = string.format("xclip -selection clipboard -t image/png -o > '%s'", path)
    elseif display_server == "wayland" then
      cmd = string.format("wl-paste --no-newline --type image/png > %s", vim.fn.shellescape(path))
      return run_job { "bash", "-c", cmd }
    end

    local result = os.execute(cmd)
    if type(result) == "number" and result > 0 then
      return false
    else
      return result
    end
  elseif this_os == api.OSType.Windows or this_os == api.OSType.Wsl then
    local cmd = 'powershell.exe -c "'
      .. string.format("(get-clipboard -format image).save('%s', 'png')", string.gsub(path, "/", "\\"))
      .. '"'
    return os.execute(cmd)
  elseif this_os == api.OSType.Darwin then
    return run_job { "pngpaste", path }
  else
    error("image saving not implemented for OS '" .. this_os .. "'")
  end
end

---@param opts { fname: string|?, default_dir: obsidian.Path|string|?, default_name: string|?, should_confirm: boolean|? }|? Options.
---
--- Options:
---  - `fname`: The filename.
---  - `default_dir`: The default directory to put the image file in.
---  - `default_name`: The default name to assign the image.
---  - `should_confirm`: Prompt to confirm before proceeding.
---
--- @return obsidian.Path|? image_path The absolute path to the image file.
M.paste_img = function(opts)
  opts = opts or {}

  local fname = opts.fname and vim.trim(opts.fname) or nil

  if not clipboard_is_img() then
    log.err "There is no image data in the clipboard"
    return
  end

  -- Get filename to save to.
  if fname == nil or fname == "" then
    if opts.default_name ~= nil and not opts.should_confirm then
      fname = opts.default_name
    else
      fname = api.input("Enter file name: ", { default = opts.default_name, completion = "file" })
      if fname == "" then
        fname = opts.default_name
      elseif not fname then
        log.warn "Paste aborted"
        return
      end
    end
  end

  assert(fname)
  fname = vim.trim(fname)

  -- Verify filename
  if util.contains_invalid_characters(fname) then
    log.warn "Links will not work with file names containing any of these characters in Obsidian: # ^ [ ] |"
  elseif fname == "" then
    log.err "Invalid file name"
    return
  end

  local path = Path.new(fname)

  -- Make sure fname ends with ".png"
  if not path.suffix then
    path = path:with_suffix ".png"
  elseif path.suffix ~= ".png" then
    log.err("invalid suffix for image name '%s', must be '.png'", path.suffix)
    return
  end

  -- Resolve absolute path to write image to.
  if path.name ~= path.filename then
    -- fname is a full path
    path = path:resolve()
  elseif opts.default_dir ~= nil then
    path = (Path.new(opts.default_dir) / path):resolve()
  else
    log.err "'default_dir' must be provided"
    return
  end

  if opts.should_confirm then
    -- Get confirmation from user.
    if not api.confirm("Saving image to '" .. tostring(path) .. "'. Do you want to continue?") then
      log.warn "Paste aborted"
      return
    end
  end

  -- Ensure parent directory exists.
  assert(path:parent()):mkdir { exist_ok = true, parents = true }

  -- Paste image.
  local result = save_clipboard_image(tostring(path))
  if result == false then
    log.err "Failed to save image"
    return
  end

  return path
end

return M
