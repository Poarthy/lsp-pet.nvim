-- lsp-pet.nvim: a Ferris-style crab that scuttles along a track while an LSP server boots / indexes.
--
--   ~~~~~~~~V(o_o)V...........@        the crab walks home to its shell: position = progress %
--   42% rust_analyzer: Indexing 120/300 (no % reported -> it scuttles back and forth)
--
-- Cost model (this is the whole point of the design):
--   * Idle  : zero. No timer, no window, no buffer. The only standing cost is one LspProgress
--     autocmd whose handler is O(1) table bookkeeping (no rendering, no API calls), plus a
--     FileType autocmd that schedules a check which returns immediately unless vim.lsp is loaded.
--   * Active: one libuv timer at ~8 fps. A tick = one scan of vim.lsp.get_clients() (1-2
--     entries) + one nvim_buf_set_lines + one extmark on a 2-row float. Animation phase is
--     derived from the wall clock, and at most one tick is ever queued, so a busy main loop
--     can never build up a backlog.
--   * Fast servers: nothing is drawn unless the server is still busy after `show_delay` ms.
--   * Fail-safe: any error inside a tick shuts the pet down for the rest of the session.
--
-- Disable entirely with `vim.g.lsp_pet = false` or `setup({ enabled = false })`.
-- Try it anywhere: `:LspPetDemo [spin|dead]`.
local api = vim.api
local uv = vim.uv or vim.loop
local M = {}

---@class LspPet.Config
---@field enabled boolean       master switch
---@field width integer         float width in columns (shrinks on narrow terminals)
---@field frame_ms integer      animation interval
---@field show_delay integer    draw nothing for servers that are ready sooner than this
---@field grace_ms integer      keep the "working" look across gaps between consecutive progress tokens
---@field done_ms integer       how long the happy crab stays
---@field dead_ms integer       how long the dead crab stays
---@field max_ms integer        give up (hide) after this long; a new `begin` token brings it back
---@field zindex integer        float z-index
---@field highlights table<"track"|"crab"|"sleep"|"done"|"dead", vim.api.keyset.highlight> per-group overrides
local defaults = {
  enabled = true,
  width = 44,
  frame_ms = 120,
  show_delay = 300,
  grace_ms = 700,
  done_ms = 1400,
  dead_ms = 2500,
  max_ms = 120000,
  zindex = 40,
  highlights = {},
}

local CFG = vim.deepcopy(defaults)

local NS = api.nvim_create_namespace("lsp_pet")
local SPRITE_W = 7 -- every sprite is exactly 7 ASCII columns (no emoji: width-safe everywhere)

local S = {
  active = false, queued = false, timer = nil, broken = false, did_setup = false,
  buf = nil, win = nil, W = 0, span = 0, waves = "", dots = "",
  prog = {}, nprog = 0, names = {}, -- prog[client_id][token] = entry
  t0 = 0, x = 0, phase = nil, idle_since = nil, done_at = nil, done_name = nil, elapsed = 0,
  dead_until = nil, dead_name = nil, surprise = -1, raw = nil, last_name = nil, last_e = nil, fake_start = false,
}

local function now_ms() return uv.hrtime() / 1e6 end

local function disabled() return vim.g.lsp_pet == false or CFG.enabled == false end

-- ---------------------------------------------------------------- window ------------------

local function geometry()
  local cols = vim.o.columns
  local w = math.min(CFG.width, cols - 2)
  if w < 24 then return nil end
  -- first row below the text area: the global statusline (laststatus) and cmdline sit under it
  local bottom = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0)
  return w, bottom - 2, cols - w - 1
end

local HL = {
  track = "LspPetTrack",
  crab = "LspPetCrab",
  sleep = "LspPetCrabSleep",
  done = "LspPetCrabDone",
  dead = "LspPetCrabDead",
}

-- Colours follow the live colorscheme ("Ferris" palette): sleeping = Grey, working = Orange,
-- done = Green (cargo's "Finished"), dead = Red. Override any group via `highlights` in setup().
local function set_highlights()
  local function hl(name) return api.nvim_get_hl(0, { name = name, link = false }) end
  local function fg(...) -- first group that actually has a foreground colour
    for _, name in ipairs({ ... }) do
      local c = hl(name).fg
      if c then return c end
    end
  end
  local bg = hl("NormalFloat").bg or hl("Normal").bg
  local derived = {
    track = { fg = hl("Comment").fg, bg = bg },
    -- fg only: the crab inherits the float's background
    crab = { fg = fg("Orange", "DiagnosticWarn", "WarningMsg"), bold = true },
    sleep = { fg = fg("Grey", "Comment"), bold = true },
    done = { fg = fg("Green", "DiagnosticOk", "String"), bold = true },
    dead = { fg = fg("Red", "DiagnosticError", "ErrorMsg"), bold = true },
  }
  for key, group in pairs(HL) do
    api.nvim_set_hl(0, group, CFG.highlights[key] or derived[key])
  end
end

local function open()
  local w, row, col = geometry()
  if not w then return false end
  S.W, S.span = w, w - SPRITE_W - 2
  S.waves, S.dots = ("~"):rep(S.span), ("."):rep(S.span)
  set_highlights()
  S.buf = api.nvim_create_buf(false, true)
  vim.bo[S.buf].bufhidden = "wipe"
  vim.bo[S.buf].undolevels = -1 -- a redrawn-8x-a-second buffer must not grow an undo tree
  api.nvim_buf_set_lines(S.buf, 0, -1, false, { "", "" })
  local win_cfg = {
    relative = "editor", row = row, col = col, width = w, height = 2,
    style = "minimal", border = "none", focusable = false, mouse = false,
    noautocmd = true, zindex = CFG.zindex,
  }
  local ok, win = pcall(api.nvim_open_win, S.buf, false, win_cfg)
  if not ok then -- older Neovim without the `mouse` window option
    win_cfg.mouse = nil
    win = api.nvim_open_win(S.buf, false, win_cfg)
  end
  S.win = win
  api.nvim_set_option_value("winhighlight", "NormalFloat:" .. HL.track, { win = S.win })
  S.raw = nil
  return true
end

local function close_win()
  if S.win and api.nvim_win_is_valid(S.win) then pcall(api.nvim_win_close, S.win, true) end
  if S.buf and api.nvim_buf_is_valid(S.buf) then pcall(api.nvim_buf_delete, S.buf, { force = true }) end
  S.win, S.buf, S.raw = nil, nil, nil
end

-- ---------------------------------------------------------------- state -------------------

local function purge(cid)
  local tokens = S.prog[cid]
  if not tokens then return end
  for _, e in pairs(tokens) do e.ended = true; S.nprog = S.nprog - 1 end
  S.prog[cid] = nil
end

-- Drop progress entries of clients that died while the pet was asleep (scan() only runs while
-- active), otherwise a stale entry keeps the crab "working" for the next session.
-- Negative ids belong to the demo's fake client.
local function reap()
  for cid in pairs(S.prog) do
    if cid >= 0 and not vim.lsp.get_client_by_id(cid) then purge(cid) end
  end
end

-- One pass over the (1-2) live clients: who is still starting, and who vanished since last tick.
local function scan()
  local starting, sname, lost
  local seen = {}
  -- `_uninitialized` is Neovim-internal: without it get_clients() hides clients that are still
  -- booting, which is exactly the phase we want to show. Neovim versions that ignore the key
  -- just lose the "sleeping" pose; nothing else depends on it.
  for _, c in ipairs(vim.lsp.get_clients({ _uninitialized = true })) do
    seen[c.id] = true
    if not S.names[c.id] then S.names[c.id] = c.name end
    if not c.initialized then starting, sname = true, c.name end
  end
  for id, name in pairs(S.names) do
    if not seen[id] then
      S.names[id] = nil
      purge(id)
      lost = name
    end
  end
  return starting, sname, lost
end

local function stop()
  S.active = false
  if S.timer then S.timer:stop(); S.timer:close(); S.timer = nil end
  close_win()
  S.names, S.phase, S.idle_since, S.done_at, S.dead_until, S.fake_start, S.last_e = {}, nil, nil, nil, nil, false, nil
end

-- ---------------------------------------------------------------- frames ------------------

local PHASE_HL = { work = HL.crab, wake = HL.sleep, done = HL.done, dead = HL.dead }
local ZZ = { "  ", " z", " zZ", " zZz" }
local DOTS = { ".", "..", "..." }

local function sprite(phase, f)
  if phase == "done" then return (f % 2 == 0) and "\\(^_^)/" or "/(^_^)\\" end
  if phase == "dead" then return "x(x_x)x" end
  if phase == "wake" then return "v(-_-)v" end
  local eyes = (f <= S.surprise) and "O_O" or ((f % 28 >= 26) and "-_-" or "o_o")
  local claw = (f % 2 == 0) and "V" or "v" -- snip, snip
  return claw .. "(" .. eyes .. ")" .. claw
end

-- the entry that last reported; if it has ended, any other live one
local function current()
  local e = S.last_e
  if e and not e.ended then return e end
  for _, tokens in pairs(S.prog) do
    for _, other in pairs(tokens) do return other end
  end
end

local function fit(s, w)
  s = s:gsub("%c+", " ")
  if vim.fn.strdisplaywidth(s) <= w then return s end
  return vim.fn.strcharpart(s, 0, w - 2) .. ".."
end

local function tick()
  if not S.active then return end
  local now = now_ms()
  local starting, sname, lost = scan()
  if S.fake_start then starting, sname = true, sname or "rust_analyzer" end
  if lost and not (S.dead_until and now < S.dead_until) then
    S.dead_until, S.dead_name = now + CFG.dead_ms, lost
  end

  local working = S.nprog > 0
  local busy = working or starting
  local phase
  if S.dead_until and now < S.dead_until then
    phase = "dead"
  elseif busy then
    phase = working and "work" or "wake"
    S.idle_since, S.done_at = nil, nil
  else
    S.idle_since = S.idle_since or now
    if S.phase == "dead" then return stop() end -- crash display over: nothing left to show
    -- brief gaps between tokens (Fetching -> Roots Scanned -> Indexing) keep the old pose
    if S.phase and S.phase ~= "done" and now - S.idle_since < CFG.grace_ms then phase = S.phase else phase = "done" end
  end

  if phase == "done" then
    if not S.win then return stop() end -- server was fast: the pet never appeared, stay silent
    if not S.done_at then S.done_at, S.elapsed = now, (now - S.t0) / 1000 end
    if now - S.done_at > CFG.done_ms then return stop() end
  elseif now - S.t0 > CFG.max_ms then
    return stop()
  end
  if not S.win and not open() then return stop() end

  local f = math.floor((now - S.t0) / CFG.frame_ms)
  local f4 = math.floor(f / 4)
  if S.phase == "wake" and phase == "work" then S.surprise = f + 5 end -- "!" when it wakes up
  S.phase = phase

  -- where is the crab? progress known -> proportional; unknown -> scuttle back and forth
  local span, target = S.span, 0
  local e
  if phase == "work" then
    e = current()
    if e then S.last_e = e else e = S.last_e or {} end -- grace gap: tokens just ended, keep the last pose
  end
  if phase == "done" then
    target = span
  elseif phase == "dead" then
    target = S.x
  elseif e and e.pct then
    target = math.max(0, math.min(e.pct, 100)) / 100 * span
  elseif phase == "work" then
    local period = 2 * span
    local m = f % period
    target = m <= span and m or period - m
  end
  -- clamp: after a terminal resize the track may be shorter than where the crab was standing
  S.x = math.max(0, math.min(S.x + (target - S.x) * 0.5, span))
  local x = math.floor(S.x + 0.5)

  local trail = S.dots:sub(1, span - x)
  local bubble = (phase == "wake") and ZZ[f4 % 4 + 1] or (f <= S.surprise and " !" or "")
  if bubble ~= "" then trail = bubble .. trail:sub(#bubble + 1) end
  local line = " " .. S.waves:sub(1, x) .. sprite(phase, f) .. trail .. "@"
  api.nvim_buf_set_lines(S.buf, 0, 1, false, { line })
  -- from col 1: the walked path + the crab share the phase colour (a progress-bar fill)
  api.nvim_buf_set_extmark(S.buf, NS, 0, 1, {
    id = 1, end_col = 1 + x + SPRITE_W, hl_group = PHASE_HL[phase], strict = false,
  })

  -- status row: rebuilt every frame as a cheap string, written only when it changed
  local raw
  if phase == "wake" then
    if sname then S.last_name = sname end
    raw = "waking up " .. (S.last_name or "lsp") .. DOTS[f4 % 3 + 1]
  elseif phase == "work" then
    S.last_name = e.name
    raw = (e.pct and ("%d%% "):format(e.pct) or "") .. (e.name or "lsp") .. ": " .. (e.title or "") ..
      (e.msg and (" " .. e.msg) or "")
  elseif phase == "done" then
    raw = ("%s ready (%.1fs)"):format(S.last_name or "lsp", S.elapsed)
  else
    raw = (S.dead_name or "lsp") .. " stopped"
  end
  if raw ~= S.raw then
    S.raw = raw
    api.nvim_buf_set_lines(S.buf, 1, 2, false, { " " .. fit(raw, S.W - 2) })
  end
end

local function fire()
  if S.queued then return end -- never stack ticks if the main loop was busy
  S.queued = true
  vim.schedule(function()
    S.queued = false
    local ok, err = pcall(tick)
    if not ok then
      S.broken = true
      pcall(stop)
      vim.notify("lsp-pet disabled: " .. tostring(err), vim.log.levels.WARN)
    end
  end)
end

local function start()
  if S.active or S.broken or disabled() then return end
  reap()
  S.active = true
  S.t0, S.x, S.phase, S.surprise = now_ms(), 0, nil, -1
  S.idle_since, S.done_at, S.dead_until = nil, nil, nil
  S.timer = uv.new_timer()
  S.timer:start(CFG.show_delay, CFG.frame_ms, fire)
end

-- ---------------------------------------------------------------- events ------------------

-- Hot path: rust-analyzer can send thousands of reports while indexing. Bookkeeping only.
local function on_progress(ev)
  local d = ev.data
  local p = d and d.params
  local v = p and p.value
  if type(v) ~= "table" then return end
  local cid, token = d.client_id, p.token
  local tokens = S.prog[cid]
  local e = tokens and tokens[token]
  if v.kind == "end" then
    if e then
      e.ended, tokens[token] = true, nil
      S.nprog = S.nprog - 1
    end
    return
  end
  if not e then
    local c = vim.lsp.get_client_by_id(cid)
    e = { name = (c and c.name) or d.name or "lsp" }
    if not tokens then tokens = {}; S.prog[cid] = tokens end
    tokens[token] = e
    S.nprog = S.nprog + 1
    if c then S.names[cid] = c.name end
  end
  if v.title then e.title = v.title end
  if v.message then e.msg = v.message end
  if v.percentage then e.pct = v.percentage end
  S.last_e = e
  if not S.active and v.kind == "begin" then start() end
end

-- Catch the spawn -> initialize gap ("sleeping" crab). Cheap by construction: if vim.lsp has
-- not been loaded yet, no server can be booting, so we do not even touch it.
local function arm()
  vim.schedule(function()
    if S.active or S.broken or disabled() or not package.loaded["vim.lsp"] then return end
    for _, c in ipairs(vim.lsp.get_clients({ _uninitialized = true })) do
      if not c.initialized then return start() end
    end
  end)
end

---@param opts? table  partial LspPet.Config
function M.setup(opts)
  if opts then CFG = vim.tbl_deep_extend("force", CFG, opts) end
  if S.did_setup or disabled() then return end
  S.did_setup = true
  local g = api.nvim_create_augroup("lsp_pet", { clear = true })
  api.nvim_create_autocmd("LspProgress", { group = g, callback = on_progress })
  -- the window is placed once; after a resize just drop it, the next tick re-opens it in place
  api.nvim_create_autocmd("VimResized", { group = g, callback = function() if S.win then close_win() end end })
  -- a colorscheme change wipes our highlight groups: re-derive them if the pet is on screen
  api.nvim_create_autocmd("ColorScheme", { group = g, callback = function() if S.win then set_highlights() end end })
  -- servers are normally started from a FileType autocmd (vim.lsp.enable / vim.lsp.start)
  api.nvim_create_autocmd("FileType", { group = g, callback = arm })
  arm() -- setup() may run after the first buffer's FileType already fired
end

-- ---------------------------------------------------------------- demo --------------------

--- Fake a boot sequence so you can watch the pet without opening a Rust/TS project.
---@param kind? "spin"|"dead"  spin = server never reports percentages; dead = server dies
function M.demo(kind)
  if disabled() then
    vim.notify("lsp-pet is disabled (vim.g.lsp_pet = false or enabled = false)", vim.log.levels.INFO)
    return
  end
  S.broken = false
  M.setup()
  local function emit(token, k, extra)
    local v = vim.tbl_extend("force", { kind = k }, extra or {})
    on_progress({ data = { client_id = -1, name = "rust_analyzer", params = { token = token, value = v } } })
  end
  S.fake_start = true
  start()
  local t0, step = now_ms(), 0
  local timer = uv.new_timer()
  timer:start(100, 100, vim.schedule_wrap(function()
    local t = (now_ms() - t0) / 1000
    local function pct(from, len) return math.max(0, math.min(100, math.floor((t - from) / len * 100))) end
    local finished
    if kind == "dead" then
      if t > 2 then
        S.fake_start, S.dead_until, S.dead_name = false, now_ms() + CFG.dead_ms, "rust_analyzer"
        finished = true
      end
    elseif kind == "spin" then
      if t > 1.5 and step == 0 then step = 1; S.fake_start = false; emit("a", "begin", { title = "Indexing" }) end
      if t > 7.5 then emit("a", "end"); finished = true end
    else
      if t > 1.5 and step == 0 then step = 1; S.fake_start = false; emit("a", "begin", { title = "Fetching" }) end
      if t > 3 and step == 1 then step = 2; emit("a", "end"); emit("b", "begin", { title = "Roots Scanned", percentage = 0 }) end
      if step == 2 then emit("b", "report", { percentage = pct(3, 3), message = ("%d/40"):format(math.floor(pct(3, 3) * 0.4)) }) end
      if t > 6 and step == 2 then step = 3; emit("b", "end"); emit("c", "begin", { title = "Indexing", percentage = 0 }) end
      if step == 3 then emit("c", "report", { percentage = pct(6, 3.5), message = ("%d/312 crates"):format(math.floor(pct(6, 3.5) * 3.12)) }) end
      if t > 9.5 then emit("c", "end"); finished = true end
    end
    if finished then timer:stop(); timer:close() end
  end))
end

return M
