-- Run: luajit tests/smoke_render.lua [gpus] [sockets]   draws one frame of the widget with stubbed cairo/conky over fake hardware, and prints the rows it drew
local NGPU, NSOCK = tonumber(arg[1]) or 8, tonumber(arg[2]) or 2
-- Lua 5.3/5.4 (conky 1.24) raises an error for string.format('%d', 93.5); LuaJIT silently truncates. Make this run as strict as 5.4.
local real_format = string.format
string.format = function(fmt, ...)
  local args, i = { ... }, 0
  for spec in fmt:gsub('%%%%', ''):gmatch('%%[%-%+ #0]*%d*%.?%d*([%a])') do
    i = i + 1
    if (spec == 'd' or spec == 'i') and type(args[i]) == 'number' and math.floor(args[i]) ~= args[i] then
      error("bad argument #" .. (i + 1) .. " to 'format' (number has no integer representation): " .. fmt, 2)
    end
  end
  return real_format(fmt, ...)
end
package.preload.cairo = function() end
package.preload.cairo_xlib = function() end
local drawn = {}
setmetatable(_G, { __index = function(_, k) if type(k) == 'string' and k:match('^cairo_') then return function() return nil end end end })
CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD, CAIRO_FONT_WEIGHT_NORMAL, CAIRO_LINE_CAP_ROUND = 0, 1, 0, 1
cairo_text_extents_t = { create = function() return { width = 10, x_bearing = 0 } end }
cairo_show_text = function(_, s) drawn[#drawn + 1] = s end
conky_window = { display = 0, drawable = 0, visual = 0, width = 320, height = 800 }
conky_parse = function(s)
  if s:match('^%${updates}') then return '1' end
  if s:match('^%${cpu}') then return '37.5' end
  if s:match('^%${memperc}') then return '41' end
  if s:match('^%${fs_used_perc') then return '55' end
  return 'x'
end
local files = {}
local cpuinfo, stat = {}, {}
local per = 8
for p = 0, NSOCK * per - 1 do
  cpuinfo[#cpuinfo + 1] = 'processor\t: ' .. p; cpuinfo[#cpuinfo + 1] = 'model name\t: AMD EPYC 9654 96-Core Processor'; cpuinfo[#cpuinfo + 1] = 'physical id\t: ' .. (p % NSOCK)
end
files['/proc/cpuinfo'] = table.concat(cpuinfo, '\n') .. '\n'
local tick = 0
local function statfile() tick = tick + 1; local t = { 'cpu  1 1 1 1 1 1 1 1' }; for p = 0, NSOCK * per - 1 do t[#t + 1] = string.format('cpu%d %d 0 %d %d 0 0 0 0', p, 100 * tick, 50 * tick, 100 * tick) end; return table.concat(t, '\n') .. '\n' end
for i = 0, NSOCK - 1 do
  local d = '/sys/class/hwmon/hwmon' .. i
  files[d .. '/name'] = 'k10temp\n'; files[d .. '/temp1_input'] = (60000 + i * 9000) .. '\n'; files[d .. '/temp1_label'] = 'Tctl\n'
  local r = '/sys/class/powercap/intel-rapl:' .. i
  files[r .. '/name'] = 'package-' .. i .. '\n'; files[r .. '/max_energy_range_uj'] = '262143328850\n'
end
local rapl_t = 0
local real_open, real_popen = io.open, io.popen
local function fake(content) local pos = 1; return { read = function(_, m) if m == '*a' then return content end local l = content:match('^[^\n]*', pos); if pos > #content then return nil end pos = pos + #l + 1; return l end, lines = function() local p = 1; return function() if p > #content then return nil end local l = content:match('^[^\n]*', p); p = p + #l + 1; return l end end, close = function() end } end
io.open = function(path, mode)
  if path == '/proc/stat' then return fake(statfile()) end
  if path:match('energy_uj$') then rapl_t = rapl_t + 1; return fake((rapl_t * 50000000) .. '\n') end
  if files[path] then return fake(files[path]) end
  if path:match('^/proc/') or path:match('^/sys/') or path:match('^/etc/os%-release') then return nil end
  return real_open(path, mode)
end
io.popen = function(cmd)
  if cmd:match('nvidia%-smi %-%-query%-gpu=name') then local t = {}; for i = 1, NGPU do t[i] = 'NVIDIA B200' end; return fake(NGPU > 0 and table.concat(t, '\n') .. '\n' or '') end
  if cmd:match('nvidia%-smi') then local t = {}; for i = 0, NGPU - 1 do t[#t + 1] = string.format('%d, %d, %d, 20000, 183359, 650.0, 1000', i, 99 - i, 60 + i * 3) end; return fake(table.concat(t, '\n') .. '\n') end
  return fake('')
end
os.execute = function() return 1 end
dofile('src/rings.lua')
os.getenv = (function(g) return function(k) if k == 'HOME' then return '/tmp/polaris-test-home' end return g(k) end end)(os.getenv)
os.execute('mkdir -p /tmp/polaris-test-home/.config/polaris')
for frame = 1, 3 do drawn = {}; conky_main() end
local out = table.concat(drawn, ' | ')
-- power needs a second RAPL reading, which one second of stubs cannot give without a GPU
for _, w in ipairs(NGPU > 0 and { 'USAGE', 'POWER', 'THERMALS' } or { 'USAGE', 'THERMALS' }) do local ok = out:find(w:gsub('.', '%0 '):gsub(' $', ''), 1, true); assert(ok, 'section missing: ' .. w) end
for _, line in ipairs(drawn) do if line:match('^GPU') or line:match('^CPU') or line:match('threads$') or line:match('B200') or line:match('Busiest') or line:match('is hot') or line:match('warm') or line:match('Act now') or line:match('Needs') then print(line) end end
print('OK ' .. #drawn .. ' strings')
