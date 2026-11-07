require 'cairo'
pcall(require, 'cairo_xlib')
local unpack = table.unpack or unpack

local function rd(p) local f = io.open(p, 'r'); if not f then return nil end; local v = f:read('*l'); f:close(); return v end
local hw, HWL, scanned = {}, {}, -1000
local FANS, IF = {}, 'lo'
local function exists(p) local f = io.open(p, 'r'); if f then f:close(); return true end return false end
local function scan(n)
  if n - scanned < 60 then return end
  scanned = n; hw = {}; HWL = {}; FANS = {}
  for i = 0, 63 do
    local d = '/sys/class/hwmon/hwmon' .. i; local nm = rd(d .. '/name')
    if nm then
      if not hw[nm] then hw[nm] = d end
      HWL[nm] = HWL[nm] or {}; HWL[nm][#HWL[nm] + 1] = d
      for k = 1, 16 do local fp = d .. '/fan' .. k .. '_input'; if exists(fp) then FANS[#FANS + 1] = fp end end
    end
  end
  local f = io.open('/proc/net/route', 'r')
  if f then
    f:read('*l')
    for l in f:lines() do local ifn, dest = l:match('^(%S+)%s+(%S+)'); if dest == '00000000' then IF = ifn; break end end
    f:close()
  end
end
local function tval(d, i) local v = d and tonumber(rd(d .. '/temp' .. i .. '_input')); return v and v / 1000 end
local function temp(name, idx) return tval(hw[name], idx) end
local function labeled_in(d, wants)
  if not d then return nil end
  for i = 1, 16 do
    local l = rd(d .. '/temp' .. i .. '_label')
    if l then for _, w in ipairs(wants) do if l:find(w, 1, true) then return tval(d, i) end end end
  end
end
local function cpu_temps()   -- one reading per CPU package, in hwmon order (the same order as the sockets)
  for _, nm in ipairs({ 'k10temp', 'coretemp', 'zenpower', 'cpu_thermal' }) do
    local out = {}
    for _, d in ipairs(HWL[nm] or {}) do
      local v = labeled_in(d, { 'Package', 'Tctl', 'Tdie' }) or tval(d, 1)
      if v then out[#out + 1] = v end
    end
    if #out > 0 then return out end
  end
  return {}
end
local function board_temp()
  for nm, d in pairs(hw) do
    if nm:match('^nct') or nm:match('^it8') or nm:match('^f71') or nm:match('^w83') or nm:match('^asus') then
      local v = labeled_in(d, { 'SYSTIN', 'Motherboard', 'System', 'Thermistor 5', 'MB' }); if v then return v end
    end
  end
end
local function nic_temp() return tval(hw[IF], 1) end
local function fan(i) return FANS[i] and tonumber(rd(FANS[i])) end

local function sh(cmd) local p = io.popen(cmd .. ' 2>/dev/null'); local s = p and p:read('*l'); if p then p:close() end; return s end
local HOST_OS = (function()
  local n, v = '', ''
  local f = io.open('/etc/os-release', 'r')
  if f then for l in f:lines() do n = l:match('^NAME="?([^"]+)"?') or n; v = l:match('^VERSION_ID="?([^"]+)"?') or v end; f:close() end
  return ((n:gsub(' Linux', '')) .. ' ' .. v):gsub('%s+$', '')
end)()
-- CPU sockets: logical CPU number -> socket index (1..N), from the "physical id" lines of /proc/cpuinfo
local function parse_topology(lines)
  local cur, names, order, seen, sock_of, count = nil, {}, {}, {}, {}, 0
  local model
  for l in lines do
    local p = l:match('^processor%s*:%s*(%d+)')
    if p then cur = tonumber(p); count = count + 1 end
    local m = l:match('^model name%s*:%s*(.+)'); if m then model = model or m end
    local id = l:match('^physical id%s*:%s*(%d+)')
    if id and cur then
      id = tonumber(id)
      if not seen[id] then seen[id] = true; order[#order + 1] = id end
      sock_of[cur] = id
    end
  end
  table.sort(order)
  local idx = {}; for i, id in ipairs(order) do idx[id] = i end
  local map, per = {}, {}
  for c, id in pairs(sock_of) do map[c] = idx[id]; per[idx[id]] = (per[idx[id]] or 0) + 1 end
  if #order == 0 then order = { 0 }; per = { count } end
  return { model = model, threads = count, sockets = #order, map = map, per = per }
end
local function cpuinfo_lines()
  local f = io.open('/proc/cpuinfo', 'r'); if not f then return function() return nil end end
  local all = {}; for l in f:lines() do all[#all + 1] = l end; f:close()
  local i = 0; return function() i = i + 1; return all[i] end
end
local TOPO = parse_topology(cpuinfo_lines())
local CPU_NAME, THREADS = (function()
  local name, n = TOPO.model, TOPO.threads
  name = (name or 'CPU'):gsub('%(R%)', ''):gsub('%(TM%)', ''):gsub(' Processor', ''):gsub(' CPU', ''):gsub('%s+@.*', ''):gsub('^AMD ', ''):gsub('^Intel ', ''):gsub('Ryzen ', ''):gsub('%s+%d+%-Cores?', ''):gsub('%s+', ' ')
  return name, n
end)()
local function grouped(names)   -- {"B200","B200"} -> "2x B200"; mixed cards are joined with " + "
  local order, n = {}, {}
  for _, x in ipairs(names) do if not n[x] then n[x] = 0; order[#order + 1] = x end; n[x] = n[x] + 1 end
  local out = {}
  for _, x in ipairs(order) do out[#out + 1] = (n[x] > 1 and (n[x] .. 'x ') or '') .. x end
  return #out > 0 and table.concat(out, ' + ') or nil
end
local GPU_NAME = (function()
  local p = io.popen('nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null'); if not p then return nil end
  local names = {}; for l in p:lines() do l = l:gsub('NVIDIA ', ''):gsub('GeForce ', ''):gsub('%s+$', ''); if l ~= '' then names[#names + 1] = l end end; p:close()
  return grouped(names)
end)()
local HAS_DNF = os.execute('command -v dnf >/dev/null 2>&1') == true or os.execute('command -v dnf >/dev/null 2>&1') == 0
local HAS_NVME = exists('/sys/class/nvme/nvme0/model')
local RUN = os.getenv('XDG_RUNTIME_DIR') or '/tmp'
local UPD = RUN .. '/polaris-upd'

local function parse_gpus(lines)   -- "index, util, temp, mem used, mem total, power, limit" per line; "[N/A]" fields become nil
  local list = {}
  for s in lines do
    local f, k = {}, 0; for x in (s .. ','):gmatch('%s*([^,]*),') do k = k + 1; f[k] = tonumber(x) end   -- by position: a nil field must not shift the next ones
    if f[1] and f[2] then list[#list + 1] = { idx = f[1], util = f[2], temp = f[3], used = f[4], total = f[5], watts = f[6], limit = f[7] } end
  end
  return list
end
local gpus, gpu_t = {}, 0
local function gpu_info()
  if os.time() - gpu_t >= 6 then
    gpu_t = os.time()
    local p = io.popen('nvidia-smi --query-gpu=index,utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw,power.limit --format=csv,noheader,nounits 2>/dev/null')
    if p then
      local list = parse_gpus(p:lines()); p:close()
      if #list > 0 then gpus = list end
    end
  end
  return gpus
end

-- CPU load per socket, from the change in /proc/stat between two frames
local STAT = { prev = nil, use = {} }
local function socket_use()
  local f = io.open('/proc/stat', 'r'); if not f then return STAT.use end
  local cur = {}
  for l in f:lines() do
    local c, rest = l:match('^cpu(%d+)%s+(.*)')
    if c then
      local v = {}; for x in rest:gmatch('%d+') do v[#v + 1] = tonumber(x) end
      local total = 0; for k = 1, math.min(#v, 8) do total = total + v[k] end
      local idle = (v[4] or 0) + (v[5] or 0)
      local sk = TOPO.map[tonumber(c)] or 1
      cur[sk] = cur[sk] or { 0, 0 }; cur[sk][1] = cur[sk][1] + total; cur[sk][2] = cur[sk][2] + idle
    end
  end
  f:close()
  if STAT.prev then
    for sk, v in pairs(cur) do
      local p = STAT.prev[sk]
      if p and v[1] > p[1] then STAT.use[sk] = 100 * (1 - (v[2] - p[2]) / (v[1] - p[1])) end
    end
  end
  STAT.prev = cur
  return STAT.use
end

-- CPU power: one RAPL package per socket (intel-rapl:0, intel-rapl:1 ...), summed for the total
local RAPL = { pk = {}, wh = 0, w = nil, t = nil, list = nil }
local function cpu_power()
  if not RAPL.list then
    RAPL.list = {}
    for i = 0, 15 do
      local d = '/sys/class/powercap/intel-rapl:' .. i
      if (rd(d .. '/name') or ''):match('^package') then RAPL.list[#RAPL.list + 1] = d end
    end
  end
  if #RAPL.list == 0 then return nil end
  local t = os.time()
  if RAPL.t and t - RAPL.t < 1 then return RAPL.w, RAPL.ws end
  local ws, total = {}, 0
  for i, d in ipairs(RAPL.list) do
    local e = tonumber(rd(d .. '/energy_uj'))
    local pk = RAPL.pk[i]
    if e and pk and RAPL.t then
      local dj = e - pk; if dj < 0 then dj = dj + (tonumber(rd(d .. '/max_energy_range_uj')) or 0) end
      ws[i] = dj / 1e6 / (t - RAPL.t); total = total + ws[i]; RAPL.wh = RAPL.wh + (dj / 1e6) / 3600
    end
    RAPL.pk[i] = e
  end
  if RAPL.t then RAPL.w, RAPL.ws = total, ws end
  RAPL.t = t
  return RAPL.w, RAPL.ws
end

local SYS = { t = 0, ft = 0, upd = nil, sec = nil, kern = nil, failed = 0, failed_names = '' }
local function sysinfo()
  local now = os.time()
  if now - SYS.t >= 3600 then
    SYS.t = now
    if HAS_DNF then os.execute([[(u=$(dnf -q check-update 2>/dev/null | grep -c '^[A-Za-z0-9]'); s=$(dnf -q check-update --security 2>/dev/null | grep -c '^[A-Za-z0-9]'); k=$(rpm -q kernel --last 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^kernel-//'); d=$(dnf history list 2>/dev/null | grep -E 'upgrade|update|daemon' | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}'); echo "$u $s $k $d" > ]] .. UPD .. [[.tmp && mv ]] .. UPD .. [[.tmp ]] .. UPD .. [[) >/dev/null 2>&1 &]]) end
  end
  if now - SYS.ft >= 20 then
    SYS.ft = now
    local f = io.open(UPD, 'r'); local s = f and f:read('*l'); if f then f:close() end
    if s then local u, sc, k, dd = s:match('^(%d+)%s+(%d+)%s*(%S*)%s*(%S*)'); if u then SYS.upd, SYS.sec, SYS.kern = tonumber(u), tonumber(sc), k; local yy, mm, d2 = (dd or ''):match('(%d+)-(%d+)-(%d+)'); SYS.upd_days = yy and math.floor((os.time() - os.time({ year = tonumber(yy), month = tonumber(mm), day = tonumber(d2), hour = 12 })) / 86400 + 0.5) or nil end end
    local p = io.popen("systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}'")
    local names = {}; if p then for l in p:lines() do names[#names + 1] = (l:gsub('%.service$', '')) end; p:close() end
    SYS.failed = #names; SYS.failed_names = table.concat(names, ', ')
    SYS.nvme = nil
    local sf = io.open('/run/polaris-smart', 'r')
    if sf then
      local txt = sf:read('*a'):lower():gsub('[ \t]+', '_'); sf:close()
      local function n(k) local v = txt:match(k .. '_*:_*([%d,%.]+)'); return v and tonumber((v:gsub(',', ''))) end
      SYS.nvme = { used = n('percentage_used'), spare = n('available_spare'), crit = n('critical_warning'), media = n('media_and_data_integrity_errors') or n('media_errors'), written = n('data_units_written'), hours = n('power_on_hours') }
    end
    local bf = io.popen('stat -c %Y ~/.last-backup 2>/dev/null'); local bt = bf and tonumber(bf:read('*l')); if bf then bf:close() end
    SYS.backup = bt
    local q = io.popen('uname -r'); SYS.running = q and q:read('*l'); if q then q:close() end
  end
  return SYS
end

local CFGDEF = { unit = 'C', show_power = 1, show_network = 1, show_storage = 1, show_thermals = 1, show_insights = 1, show_backup = 1,
  temp_warn = 75, temp_hot = 85, nvme_warn = 70, disk_warn = 80, disk_hot = 90, ram_warn = 80, ram_hot = 90, update_days = 30 }
local CFG = {}
local function loadcfg()
  for k, v in pairs(CFGDEF) do CFG[k] = v end
  local f = io.open(os.getenv('HOME') .. '/.config/polaris/settings.conf', 'r')
  if f then
    for l in f:lines() do local k, v = l:match('^([%w_]+)=(.*)$'); if k and CFGDEF[k] ~= nil then CFG[k] = tonumber(v) or v end end
    f:close()
  end
end

local WHITE, MUTED = { 1, 1, 1, 1 }, { 0.86, 0.88, 0.92, 1 }
local function heat(v, lo, hi) if not v then return MUTED end; if v < lo then return { 0.42, 0.80, 0.58, 1 } elseif v < hi then return { 0.95, 0.74, 0.30, 1 } else return { 0.93, 0.40, 0.38, 1 } end end

local function text(cr, s, x, y, size, bold, align, col)
  cairo_select_font_face(cr, 'Sans', CAIRO_FONT_SLANT_NORMAL, bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
  size = size < 13 and size + 1 or size; cairo_set_font_size(cr, size)
  local e = cairo_text_extents_t:create(); cairo_text_extents(cr, s, e)
  local px = x
  if align == 'center' then px = x - e.width / 2 - e.x_bearing elseif align == 'right' then px = x - e.width - e.x_bearing end
  cairo_set_source_rgba(cr, unpack(col or WHITE)); cairo_move_to(cr, px, y); cairo_show_text(cr, s); cairo_new_path(cr)
end
local function ring(cr, cx, cy, r, w, frac, col)
  frac = math.max(0, math.min(1, frac or 0))
  cairo_set_line_width(cr, w); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
  cairo_new_path(cr); cairo_set_source_rgba(cr, 1, 1, 1, 0.16); cairo_arc(cr, cx, cy, r, 0, 2 * math.pi); cairo_stroke(cr)
  if frac > 0.005 then cairo_new_path(cr); cairo_set_source_rgba(cr, unpack(col)); cairo_arc(cr, cx, cy, r, -math.pi / 2, -math.pi / 2 + frac * 2 * math.pi); cairo_stroke(cr) end
end
local function rrect(cr, x, y, w, h, r)
  cairo_new_sub_path(cr)
  cairo_arc(cr, x + w - r, y + r, r, -math.pi / 2, 0); cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
  cairo_arc(cr, x + r, y + h - r, r, math.pi / 2, math.pi); cairo_arc(cr, x + r, y + r, r, math.pi, 3 * math.pi / 2)
  cairo_close_path(cr)
end
local peaks, hist, hist_t = { cpu = 0, gpu = 0, nvme = 0 }, {}, 0
local function round(x) return math.floor(x + 0.5) end
local function P(s) return conky_parse(s) end
local function num(s) return tonumber((s or ''):match('[%d%.]+')) or 0 end

local function update_s() local f = io.open(os.getenv('HOME') .. '/.config/polaris/refresh', 'r'); local n = f and tonumber(f:read('*l')); if f then f:close() end; return n or 2 end

function conky_main()
  if conky_window == nil then return end
  local n = tonumber(P('${updates}')) or 0
  scan(n)
  loadcfg()
  local TW, TH, NW, DW, DH, RW, RH, UD = CFG.temp_warn, CFG.temp_hot, CFG.nvme_warn, CFG.disk_warn, CFG.disk_hot, CFG.ram_warn, CFG.ram_hot, CFG.update_days
  local F = CFG.unit == 'F'
  local function deg(v) return F and (v * 9 / 5 + 32) or v end
  local function ddeg(d) return F and (d * 9 / 5) or d end
  local U = F and 'F' or 'C'
  local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable, conky_window.visual, conky_window.width, conky_window.height)
  local cr = cairo_create(cs)
  do local f = io.open(os.getenv('HOME') .. '/.config/polaris/effective_scale', 'r'); local n = f and tonumber(f:read('*l')); if f then f:close() end
     n = (n and n >= 0.4 and n <= 2.5) and n or 1; cairo_scale(cr, n, n) end
  local W, M = 320, 20
  local y = 0
  local CORAL = { 1, 0.62, 0.54, 1 }
  local BLUE, PURP, TEAL, AMB, PINK = { 0.55, 0.72, 1, 1 }, { 0.72, 0.62, 1, 1 }, { 0.45, 0.85, 0.78, 1 }, { 0.95, 0.80, 0.45, 1 }, { 0.95, 0.60, 0.68, 1 }
  local function row(label, value, col, vcol)
    rrect(cr, M, y - 11, 3, 14, 1.5); cairo_set_source_rgba(cr, unpack(col)); cairo_fill(cr)
    text(cr, label, M + 12, y, 11, false, 'left')
    text(cr, value, W - M, y, 11, true, 'right', vcol)
    y = y + 23
  end
  local function spark(h, x, sy, w, hh, col, mx)
    if #h < 2 then return end
    cairo_new_path(cr); cairo_set_line_width(cr, 1.6); cairo_set_source_rgba(cr, unpack(col))
    for k, v in ipairs(h) do
      local px = x + (k - 1) * w / (#h - 1); local py = sy + hh - math.min(1, v / mx) * hh
      if k == 1 then cairo_move_to(cr, px, py) else cairo_line_to(cr, px, py) end
    end
    cairo_stroke(cr)
  end
  local function sec(t, col)
    y = y + 10
    cairo_new_path(cr); cairo_set_source_rgba(cr, unpack(col)); cairo_arc(cr, M + 4, y - 4, 4, 0, 2 * math.pi); cairo_fill(cr)
    local label = t:upper():gsub('.', '%0 '):gsub(' $', '')
    text(cr, label, M + 16, y, 10, true, 'left', { col[1] * 0.4 + 0.6, col[2] * 0.4 + 0.6, col[3] * 0.4 + 0.6, 1 })
    cairo_select_font_face(cr, 'Sans', CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD); cairo_set_font_size(cr, 11)
    local e = cairo_text_extents_t:create(); cairo_text_extents(cr, label, e)
    cairo_new_path(cr); cairo_set_line_width(cr, 1); cairo_set_source_rgba(cr, 1, 1, 1, 0.22); cairo_move_to(cr, M + 16 + e.width + 10, y - 4); cairo_line_to(cr, W - M, y - 4); cairo_stroke(cr)
    y = y + 22
  end
  local function kib(v) if v >= 1024 then return string.format('%.1f MiB/s', v / 1024) end return string.format('%d KiB/s', math.floor(v + 0.5)) end

  local G = gpu_info(); local NG = #G
  local NS = TOPO.sockets; local su = socket_use()
  local cpu = num(P('${cpu}')); local ram = num(P('${memperc}')); local disk = num(P('${fs_used_perc /}'))
  local cts = cpu_temps(); local cpuT, cpuTi
  for i, v in ipairs(cts) do if not cpuT or v > cpuT then cpuT, cpuTi = v, i end end   -- the hottest package drives the score
  local gpuT, gpuTi
  for _, x in ipairs(G) do if x.temp and (not gpuT or x.temp > gpuT) then gpuT, gpuTi = x.temp, x.idx end end   -- the hottest card
  local cpuLbl = #cts > 1 and ('CPU ' .. (cpuTi - 1)) or 'CPU'
  local gpuLbl = NG > 1 and ('GPU ' .. (gpuTi or 0)) or 'GPU'
  local boardT, nvmeT, nicT = board_temp(), temp('nvme', 1), nic_temp()
  local temps = {}
  local function addt(label, v, lo, hi) if v then temps[#temps + 1] = { label, v, lo, hi } end end
  for i, v in ipairs(cts) do addt(#cts > 1 and ('CPU ' .. (i - 1)) or 'CPU', v, TW - 5, TH) end
  if NG <= 8 then for _, x in ipairs(G) do addt(NG > 1 and ('GPU ' .. x.idx) or 'GPU', x.temp, TW - 5, TH) end
  else addt('GPU hottest of ' .. NG, gpuT, TW - 5, TH) end
  addt('Board', boardT, 50, 65); addt('NVMe', nvmeT, NW - 15, NW); addt('Network chip', nicT, TW - 5, TH)
  local fmin, fmax, stopped, fsum, fn = nil, nil, nil, 0, 0
  for i = 1, #FANS do local f = fan(i); if f then fmin = math.min(fmin or f, f); fmax = math.max(fmax or f, f); fsum = fsum + f; fn = fn + 1; if f == 0 then stopped = i end end end
  peaks.cpu = math.max(peaks.cpu, cpuT or 0); peaks.gpu = math.max(peaks.gpu, gpuT or 0); peaks.nvme = math.max(peaks.nvme, nvmeT or 0)
  local now = os.time()
  if now - hist_t >= 30 and cpuT then
    hist_t = now; hist[#hist + 1] = { now, cpuT }
    while #hist > 1 and now - hist[1][1] > 600 do table.remove(hist, 1) end
  end
  CH = CH or {}; CH[#CH + 1] = cpu; if #CH > 90 then table.remove(CH, 1) end
  NH = NH or { {}, {} }
  local sp = { num(P('${downspeedf ' .. IF .. '}')), num(P('${upspeedf ' .. IF .. '}')) }
  for i = 1, 2 do local h = NH[i]; h[#h + 1] = sp[i]; if #h > 60 then table.remove(h, 1) end end

  local sy = sysinfo()
  local reboot = sy.kern and sy.kern ~= '' and sy.running and sy.running ~= sy.kern
  local level, msg = 0, 'All normal'
  local score = 100
  local function flag(l, m) score = math.max(0, score - (l == 2 and 25 or 10)); if l > level then level, msg = l, m end end
  if stopped then flag(2, 'Fan ' .. stopped .. ' has stopped') end
  if cpuT and cpuT >= TH then flag(2, cpuLbl .. ' is hot at ' .. round(deg(cpuT)) .. '°') elseif cpuT and cpuT >= TW then flag(1, cpuLbl .. ' is running warm at ' .. round(deg(cpuT)) .. '°') end
  if gpuT and gpuT >= TH then flag(2, gpuLbl .. ' is hot at ' .. round(deg(gpuT)) .. '°') elseif gpuT and gpuT >= TW then flag(1, gpuLbl .. ' is running warm at ' .. round(deg(gpuT)) .. '°') end
  if nvmeT and nvmeT >= NW then flag(1, 'NVMe is warm at ' .. round(deg(nvmeT)) .. '°') end
  if disk >= DH then flag(2, 'Disk is almost full (' .. round(disk) .. '%)') elseif disk >= DW then flag(1, 'Disk is ' .. round(disk) .. '% full') end
  if ram >= RH then flag(2, 'Memory is nearly full') elseif ram >= RW then flag(1, 'Memory use is high') end
  if sy.failed > 0 then flag(2, sy.failed .. ' service' .. (sy.failed > 1 and 's' or '') .. ' failed') end
  if sy.sec and sy.sec > 0 then flag(1, sy.sec .. ' security update' .. (sy.sec > 1 and 's' or '') .. ' pending') end
  if reboot then flag(1, 'Reboot needed for new kernel') end
  local nv = sy.nvme
  if nv then
    if (nv.crit or 0) > 0 or (nv.media or 0) > 0 then flag(2, 'Disk reports errors') end
    if (nv.used or 0) >= 80 then flag(1, 'NVMe is ' .. nv.used .. '% worn') end
    if nv.spare and nv.spare < 20 then flag(1, 'NVMe spare capacity low') end
  end
  if sy.upd_days and sy.upd_days >= UD then flag(1, 'No update for ' .. sy.upd_days .. ' days') end
  local dot = level == 2 and { 0.93, 0.40, 0.38, 1 } or level == 1 and { 0.95, 0.74, 0.30, 1 } or { 0.42, 0.80, 0.58, 1 }

  y = 40
  text(cr, P('${nodename}'), M, y, 22, true, 'left')
  text(cr, P('${time %H:%M}'), W - M, y, 22, true, 'right')
  y = y + 18
  text(cr, HOST_OS .. '  ·  kernel ' .. (P('${kernel}'):gsub('%.fc.*', '')), M, y, 10, false, 'left', MUTED)
  text(cr, P('${time %a %d %b}'), W - M, y, 10, false, 'right', MUTED)
  y = y + 22
  text(cr, tostring(score), M, y + 26, 30, true, 'left', dot)
  text(cr, level == 0 and 'Healthy' or (level == 1 and 'Needs attention' or 'Act now'), M + 62, y + 12, 13, true, 'left')
  text(cr, level == 0 and 'Nothing needs attention' or msg, M + 62, y + 28, 10, false, 'left', MUTED)
  y = y + 52
  cairo_new_path(cr); cairo_set_line_width(cr, 1); cairo_set_source_rgba(cr, 1, 1, 1, 0.18); cairo_move_to(cr, M, y - 16); cairo_line_to(cr, W - M, y - 16); cairo_stroke(cr)
  text(cr, 'IP  ' .. P('${addr ' .. IF .. '}'), M, y + 4, 10, false, 'left', MUTED)
  text(cr, 'up ' .. P('${uptime_short}') .. '  ·  load ' .. P('${loadavg 1}'), W - M, y + 4, 10, false, 'right', MUTED)
  y = y + 34
  text(cr, string.format('CPU  %.0f%%', cpu), M, y, 10, true, 'left', BLUE)
  text(cr, 'last ' .. math.max(1, round(#CH * update_s() / 60)) .. ' min', W - M, y, 9, false, 'right', MUTED)
  y = y + 6
  local cm = 10; for _, v in ipairs(CH) do cm = math.max(cm, v) end
  local sh, sw = 26, W - 2 * M
  if #CH >= 2 then
    cairo_new_path(cr); cairo_move_to(cr, M, y + sh)
    for k, v in ipairs(CH) do cairo_line_to(cr, M + (k - 1) * sw / (#CH - 1), y + sh - math.min(1, v / cm) * sh) end
    cairo_line_to(cr, M + sw, y + sh); cairo_close_path(cr); cairo_set_source_rgba(cr, BLUE[1], BLUE[2], BLUE[3], 0.18); cairo_fill(cr)
    spark(CH, M, y, sw, sh, BLUE, cm)
  end
  y = y + sh + 12

  sec('USAGE', BLUE)
  row('CPU', string.format('%.1f%%  ·  %.1f GHz', cpu, num(P('${freq_g 1}'))), BLUE)
  if NS > 1 then
    for k = 1, NS do row('CPU ' .. (k - 1), string.format('%.1f%%  ·  %d threads', su[k] or 0, TOPO.per[k] or 0), BLUE) end
  end
  local function gmem(x) return x.used and x.total and string.format('%.1f / %.0f GB', x.used / 1024, x.total / 1024) or '-' end
  if NG == 1 then
    row('GPU', string.format('%d%%  ·  %s', G[1].util, gmem(G[1])), BLUE)
  elseif NG > 1 and NG <= 8 then
    for _, x in ipairs(G) do row('GPU ' .. x.idx, string.format('%d%%  ·  %s', x.util, gmem(x)), BLUE) end
  elseif NG > 8 then   -- too many cards for one row each: show the average load, the memory in use and the busiest card
    local us, mu, mt, top = 0, 0, 0, G[1]
    for _, x in ipairs(G) do us = us + x.util; mu = mu + (x.used or 0); mt = mt + (x.total or 0); if x.util > top.util then top = x end end
    row('GPUs ×' .. NG, string.format('%d%% avg  ·  %.0f / %.0f GB', us / NG, mu / 1024, mt / 1024), BLUE)
    row('Busiest GPU', string.format('GPU %d  ·  %d%%', top.idx, top.util), BLUE)
  end
  row('Memory', P('${mem}') .. ' / ' .. P('${memmax}') .. '  ·  ' .. round(ram) .. '%', BLUE)
  local cw, cws = cpu_power()
  local gw, glim = 0, 0
  for _, x in ipairs(G) do gw = gw + (x.watts or 0); glim = glim + (x.limit or 0) end
  if gw == 0 then gw = nil end
  if (cw or gw) and CFG.show_power == 1 then
    sec('POWER', AMB)
    if cw then
      if cws and #cws > 1 then for k = 1, #cws do row('CPU ' .. (k - 1), string.format('%.0f W', cws[k] or 0), AMB) end end
      row(cws and #cws > 1 and 'CPU total' or 'CPU', string.format('%.0f W', cw), AMB)
    end
    if gw then
      if NG > 1 and NG <= 4 then for _, x in ipairs(G) do if x.watts then row('GPU ' .. x.idx, string.format('%.0f W  /  %.0f W max', x.watts, x.limit or 0), AMB) end end end
      row(NG > 1 and 'GPU total' or 'GPU', string.format('%.0f W  /  %.0f W max', gw, glim), AMB)
    end
    if cw and gw then row('CPU + GPU', string.format('%.0f W', cw + gw), AMB, { 1, 1, 1, 1 }) end
    if cw then row('CPU energy', string.format('%.2f Wh since start', RAPL.wh + 0), AMB) end
  end
  if CFG.show_network == 1 then
  sec('NETWORK', PURP)
  local gx, gwd, gh = M + 52, W - 2 * M - 52, 50
  local mx = 8; for i = 1, 2 do for _, v in ipairs(NH[i]) do mx = math.max(mx, v) end end
  text(cr, kib(mx), M, y + 6, 9, false, 'left', MUTED)
  text(cr, kib(mx / 2), M, y + gh / 2 + 4, 9, false, 'left', MUTED)
  text(cr, '0', M, y + gh + 2, 9, false, 'left', MUTED)
  cairo_new_path(cr); cairo_set_line_width(cr, 1); cairo_set_source_rgba(cr, 1, 1, 1, 0.18)
  for k = 0, 2 do cairo_move_to(cr, gx, y + k * gh / 2); cairo_line_to(cr, gx + gwd, y + k * gh / 2) end; cairo_stroke(cr)
  spark(NH[1], gx, y, gwd, gh, BLUE, mx); spark(NH[2], gx, y, gwd, gh, PURP, mx)
  y = y + gh + 24
  row('Download Rate', P('${downspeed ' .. IF .. '}'), BLUE)
  row('Upload Rate', P('${upspeed ' .. IF .. '}'), PURP)
  row('Total', 'Down ' .. P('${totaldown ' .. IF .. '}') .. '  Up ' .. P('${totalup ' .. IF .. '}'), PURP)
  end
  if CFG.show_storage == 1 then
  sec('STORAGE', TEAL)

  rrect(cr, M, y - 4, W - 2 * M, 9, 4.5); cairo_set_source_rgba(cr, 1, 1, 1, 0.20); cairo_fill(cr)
  rrect(cr, M, y - 4, math.max(9, (W - 2 * M) * disk / 100), 9, 4.5); cairo_set_source_rgba(cr, unpack(heat(disk, DW, DH))); cairo_fill(cr)
  y = y + 24
  row('Disk Used', string.format('%s  (%d%%)', P('${fs_used /}'), round(disk)), TEAL)
  row('Disk Free', P('${fs_free /}') .. ' of ' .. P('${fs_size /}'), TEAL)
  end
  if CFG.show_thermals == 1 then
  sec('THERMALS', CORAL)

  for _, t in ipairs(temps) do
    row(t[1], t[2] and string.format('%d °%s', round(deg(t[2])), U) or '-', heat(t[2], t[3], t[4]), heat(t[2], t[3], t[4]))
  end
  if #FANS > 0 then row('Fans', fn > 0 and string.format('%d of %d  ·  %d–%d RPM', fn, #FANS, fmin, fmax) or '-', AMB, stopped and heat(99, 1, 2) or nil) end
  end
  if CFG.show_insights == 1 then
  sec('INSIGHTS', PINK)

  local function procs(kind)
    local nm = P('${' .. kind .. ' name 1}'):gsub('^%s+', ''):gsub('%s+$', '')
    local v = num(P('${' .. kind .. (kind == 'top' and ' cpu 1}' or ' mem 1}')))
    return nm ~= '' and (nm .. '  ' .. (v >= 10 and tostring(round(v)) or string.format('%.1f', v)) .. '%') or '-'
  end
  local trend = 'collecting'
  if #hist >= 2 and cpuT then
    local d = round(ddeg(cpuT - hist[1][2])); local mins = math.max(1, round((now - hist[1][1]) / 60))
    trend = (d > 0 and '+' or d < 0 and '−' or '±') .. math.abs(d) .. '° in ' .. mins .. ' min'
  end
  local RED, YEL = { 0.93, 0.40, 0.38, 1 }, { 0.95, 0.74, 0.30, 1 }
  if HAS_DNF then
    row('Updates', sy.upd == nil and 'checking...' or (sy.upd == 0 and 'up to date' or (sy.upd .. ' pending' .. (sy.sec > 0 and ('  ·  ' .. sy.sec .. ' security') or ''))), PINK, sy.upd and sy.upd > 0 and (sy.sec > 0 and RED or YEL) or nil)
    row('Last update', sy.upd_days == nil and '-' or (sy.upd_days <= 0 and 'today' or (sy.upd_days == 1 and 'yesterday' or (sy.upd_days .. ' days ago'))), PINK, sy.upd_days and sy.upd_days >= UD and YEL or nil)
    row('Reboot', reboot and ('needed  ·  ' .. sy.kern:gsub('%.fc.*', '')) or 'not needed', PINK, reboot and YEL or nil)
  end
  row('Services', sy.failed == 0 and 'all running' or (sy.failed .. ' failed' .. (sy.failed_names ~= '' and (': ' .. sy.failed_names:sub(1, 22)) or '')), PINK, sy.failed > 0 and RED or nil)
  if HAS_NVME and nv then
    local bad = (nv.crit or 0) > 0 or (nv.media or 0) > 0
    row('Disk health', bad and 'errors reported' or ('healthy  ·  ' .. (nv.hours and (math.floor(nv.hours / 24) .. ' days on') or 'ok')), PINK, bad and RED or nil)
    row('NVMe wear', string.format('%s%% used  ·  %s%% spare%s', nv.used or '?', nv.spare or '?', nv.written and string.format('  ·  %.0f TB', nv.written * 512000 / 1e12) or ''), PINK, (nv.used or 0) >= 80 and YEL or nil)
  elseif HAS_NVME then
    row('Disk health', 'set up in Polaris settings', PINK, MUTED)
  end
  if CFG.show_backup ~= 1 then
  elseif sy.backup then
    local dd = math.floor((os.time() - sy.backup) / 86400)
    row('Last backup', dd <= 0 and 'today' or (dd .. ' days ago'), PINK, dd >= 7 and YEL or nil)
  else
    row('Last backup', 'none recorded', PINK, MUTED)
  end
  row('Headroom', cpuT and ('CPU ' .. round(ddeg(TH - cpuT)) .. '° below limit') or '-', PINK)
  row('Busiest', procs('top'), PINK)
  row('Top memory', procs('top_mem'), PINK)
  row('CPU Trend', trend, PINK)
  row('Peak temps', 'CPU ' .. round(deg(peaks.cpu)) .. '°' .. (NG > 0 and ('  GPU ' .. round(deg(peaks.gpu)) .. '°') or ''), PINK)
  end
  y = y + 6
  text(cr, (NS > 1 and (NS .. 'x ') or '') .. CPU_NAME .. '  ·  ' .. THREADS .. ' threads' .. (GPU_NAME and ('  ·  ' .. GPU_NAME) or ''), W / 2, y, 9.5, false, 'center', MUTED)

  local need = math.ceil(y + 24)
  if math.abs(need - (LASTH or 0)) > 4 then
    LASTH = need
    local hf = io.open(os.getenv('HOME') .. '/.config/polaris/height', 'w'); if hf then hf:write(need .. '\n'); hf:close() end
  end

  cairo_destroy(cr); cairo_surface_destroy(cs)
end
