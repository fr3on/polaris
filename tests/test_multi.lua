-- Run: luajit tests/test_multi.lua   (checks the parsers in src/rings.lua with made-up hardware)
local src = io.open('src/rings.lua'):read('*a')
local function grab(name)   -- the text of `local function <name>(...) ... end` up to the next top-level `end`
  local a = src:find('local function ' .. name .. '%(')
  local b = select(2, src:find('\nend\n', a, true))
  return src:sub(a, b)
end
local env = setmetatable({}, { __index = _G })
local chunk = grab('parse_topology') .. grab('parse_gpus') .. grab('grouped') .. 'return parse_topology, parse_gpus, grouped'
local pt, pg, gr = assert(load(chunk, 'rings', 't', env))()
local function it(t) local i = 0; return function() i = i + 1; return t[i] end end
local fails = 0
local function eq(a, b, m) if a ~= b then fails = fails + 1; print('FAIL ' .. m .. ': got ' .. tostring(a) .. ', want ' .. tostring(b)) end end

-- two sockets, 4 logical CPUs each, ids 0 and 1 (processors interleaved)
local lines = {}
for p = 0, 7 do
  lines[#lines + 1] = 'processor\t: ' .. p
  lines[#lines + 1] = 'model name\t: AMD EPYC 9654 96-Core Processor'
  lines[#lines + 1] = 'physical id\t: ' .. (p % 2)
end
local t = pt(it(lines))
eq(t.sockets, 2, 'sockets'); eq(t.threads, 8, 'threads'); eq(t.per[1], 4, 'threads on socket 1'); eq(t.per[2], 4, 'threads on socket 2')
eq(t.map[0], 1, 'cpu0 on socket 1'); eq(t.map[1], 2, 'cpu1 on socket 2')
-- no physical id lines (some ARM and virtual machines): one socket
local t2 = pt(it({ 'processor : 0', 'model name : X', 'processor : 1' }))
eq(t2.sockets, 1, 'single socket'); eq(t2.per[1], 2, 'all threads on it')
-- sockets that start at id 1 are still numbered from 1
local t3 = pt(it({ 'processor : 0', 'physical id : 4', 'processor : 1', 'physical id : 2' }))
eq(t3.sockets, 2, 'two ids'); eq(t3.map[1], 1, 'id 2 is socket 1'); eq(t3.map[0], 2, 'id 4 is socket 2')

-- eight GPUs, one with power not readable
local g = {}
for i = 0, 7 do g[#g + 1] = string.format('%d, %d, %d, 1200, 183359, %s, 1000', i, 90 + i % 3, 50 + i, i == 5 and '[N/A]' or '700.5') end
local gl = pg(it(g))
eq(#gl, 8, 'eight gpus'); eq(gl[8].idx, 7, 'index'); eq(gl[6].watts, nil, 'N/A power is nil'); eq(gl[6].limit, 1000, 'limit still read'); eq(gl[1].total, 183359, 'memory')
eq(#pg(it({ '', 'garbage', 'No devices were found' })), 0, 'no gpus')
eq(#pg(it({ '0, 12, [N/A], [N/A], [N/A], [N/A], [N/A]' })), 1, 'laptop gpu with n/a fields kept')

eq(gr({ 'B200', 'B200', 'B200' }), '3x B200', 'same cards grouped')
eq(gr({ 'A100', 'H100' }), 'A100 + H100', 'mixed cards')
eq(gr({}), nil, 'none')
print(fails == 0 and 'all passed' or (fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
