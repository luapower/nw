local nw = require'nw'
local glue = require'glue'
local ffi = require'ffi'
local bit = require'bit'

local objc = require'objc'
--objc.debug.logtopics.refcount = true

io.stdout:setvbuf'no'

jit.off()

local app

--testing helpers --------------------------------------------------------------------------------------------------------

--collecting and running tests

local tests = {} --{name = test} also {test1, ...} also {test = name}
local subproc = {} --{name = expected_exitcode}

local function parsename(name) --prefix, name
	return name:match'^(%@?)(.*)'
end

--add a named test to the tests collection
local function add(name, f, expected_exitcode)
	local prefix, name = parsename(name)
	if prefix == '@' then --must run in subprocess
		subproc[name] = expected_exitcode or 0
	end
	if type(f) == 'string' then f = tests[f] end --make an alias
	table.insert(tests, f)
	tests[name] = f
	tests[f] = name
end

--run a test in a subprocess and expect an exit code
local function subprocess(name)
	local exitcode = subproc[name] or 0
	local cmd = string.format('%sluajit %s @%s', ffi.os == 'Windows' and '' or './', arg[0], name)
	local ret = os.execute(cmd)
	if ret > 255 then --system() on unix returns the exit status in the high byte
		ret = bit.rshift(ret, 8)
	end
	assert(ret == exitcode, string.format('%s: [%d]', cmd, ret))
	print(string.format('exit code: %d', exitcode))
end

--run a test, possibly in a subprocess if it's a '@'-marked test and not marked '@' for running.
local function test(name)
	local prefix, name = parsename(name)
	if prefix == '' and subproc[name] then
		subprocess(name)
	else
		app = app or nw:app()
		tests[name]()
	end
end

--run all tests whose names match a pattern, in order
local function test_all_matching(patt)
	for i,f in ipairs(tests) do
		local name = tests[f]
		if name:match(patt) then
			print()
			print(name)
			print'========================='
			test(name)
		end
	end
end

--command line user interface
local function testui(name)
	if not name then
		print(string.format('Usage: %s <name> | <name>*', arg[0]))
		print'Available tests:'
		for i,test in ipairs(tests) do
			print('', tests[test])
		end
	elseif name:match'%*$' then
		test_all_matching('^'..glue.escape(name:gsub('%*', ''))..'.*')
	elseif tests[select(2, parsename(name))] then
		test(name)
	else
		print'What test was that?'
		testui()
	end
end

--window position generator

local x = 100
local y = 100
local function winpos(t, same_pos)
	if not same_pos then
		if y > 600 then
			x = x + 150
			y = 100
		else
			y = y + 100
		end
	end
	return glue.update({x = x, y = y, w = 140, h = 90}, t)
end

--event recorder/checker

local function recorder(app)
	local t = {n = 0}
	local function record(...)
		print(...)
		for i = 1, select('#', ...) do
			t[t.n + i] = select(i, ...)
		end
		t.n = t.n + select('#', ...)
	end
	local function check(expected)
		assert(t.n == (expected.n or #expected))
		for i=1,t.n do
			assert(t[i] == expected[i])
		end
	end
	return function(e, ...)
		if type(e) == 'table' then
			check(e)
		else
			record(e, ...)
		end
	end
end

--generate value combinations for sets of binary flags

local function base2(x, digits)
	local s = ''
	while x > 0 do
		 s = '' ..  (x % 2) .. s
		 x = math.floor(x / 2)
	end
	return ('0'):rep(digits - #s) .. s
end

local function combination(flags, x)
	local s = base2(x, #flags)
	local t = {}
	for i, flag in ipairs(flags) do
		t[flag] = s:sub(i,i) == '1'
	end
	return t
end

local function combinations(flags)
	return coroutine.wrap(function()
		for i = 0, 2^#flags-1 do
			coroutine.yield(combination(flags, i))
		end
	end)
end

--system info ------------------------------------------------------------------------------------------------------------

--double click time is sane
add('info-click-time', function()
	local t = app.backend:double_click_time()
	print('double_click_time', t)
	assert(t > 0 and t < 5000)
end)

--target area is sane
add('info-click-area', function()
	local w, h = app.backend:double_click_target_area()
	print('double_click_target_area', w, h)
	assert(w > 0 and w < 100)
	assert(h > 0 and h < 100)
end)

--displays ---------------------------------------------------------------------------------------------------------------

--client rect is fully enclosed in screen rect and has a sane size
--client rect has a sane size
local function test_display(display)

	local x, y, w, h = display:rect()
	print('rect       ',  x, y, w, h)

	local cx, cy, cw, ch = display:client_rect()
	print('client_rect', cx, cy, cw, ch)

	--client rect has a sane size
	assert(cw > 100)
	assert(ch > 100)

	--client rect must be fully enclosed in screen rect
	assert(cx >= x)
	assert(cy >= y)
	assert(cw <= w)
	assert(ch <= h)
end

--there's at least one display and its values are sane
add('info-displays', function()
	local i = 0
	for display in app:displays() do
		i = i + 1
		print(string.format('# display %d', i))
		test_display(display)
	end
	assert(i > 0) --there must be at least 1 display
end)

--main display is at (0, 0)
add('info-main-display', function()
	local display = app:main_display()
	test_display(display)
	local x, y, w, h = display:rect()
	--main screen is at (0, 0)
	assert(x == 0)
	assert(y == 0)
end)

--time -------------------------------------------------------------------------------------------------------------------

--time values are sane
add('info-time', function()
	local t = app:time()
	print('time    ', t)
	assert(t > 0)
end)

--timediff values are sane (less than 1ms between 2 calls but more than 0)
add('info-timediff', function()
	local d = app:timediff(app:time())
	print('timediff', d)
	assert(d > 0 and d < 1)
end)

--app running ------------------------------------------------------------------------------------------------------------

--run() is ignored if there are no windows
add('@run-no-windows', function()
	assert(not app:running())
	app:run() --no-op: no windows
	assert(not app:running())
	os.exit(123)
end, 123)

--running() works
--run() is ignored while running
--run() returns
add('@run', function()
	local rec = recorder()
	app:activate()
	local win = app:window(winpos())
	function win:closed()
		assert(app:running())
		app:run() --ignored, already running
		rec'closed'
	end
	assert(not app:running())
	app:run()
	assert(not app:running())
	rec{'closed'}
	os.exit(123)
end, 123)

--app quitting -----------------------------------------------------------------------------------------------------------

--quit() works is ignored not running
add('@quit-not-running', function()
	app:quit()
	os.exit(123)
end, 123)

--exit() query works
add('@quit-exit', function()
	function app:exit() return 123 end
	app:quit()
end, 123)

--quitting() event works
add('@quit-quitting', function()
	local rec = recorder()
	local allow
	function app:quitting()
		if not allow then --don't allow the first time
			allow = true
			rec'not allowing'
			return false
		else --allow the second time
			rec'allowing'
		end
	end
	function app:exit()
		rec{'not allowing', 'allowing'}
		return 1
	end
	app:quit() --not allowed
	app:quit() --allowed
	assert(false) --can't reach here
end, 1)

--quitting() comes before closing()
add('@quit-quitting-before-closing', function()
	local rec = recorder()
	local win1 = app:window(winpos())
	local win2 = app:window(winpos())
	function app:quitting() rec'quitting' end
	function win1:closing() rec'closing' end
	function win2:closing() rec'closing' end
	function app:exit()
		rec{'quitting', 'closing', 'closing'}
		return 1
	end
	app:autoquit(false)
	app:quit()
end, 1)

--quit() fails if windows are created while quitting
add('@quit-fails', function()
	local rec = recorder()
	local win = app:window(winpos())
	function win:closed()
		app:window(winpos())
	end
	function app:exit()
		rec{'failed'}
		return 1
	end
	app:autoquit(false)
	app:quit() --fails
	rec'failed'
	app:quit()
end, 1)

--app:autoquit(true) works
add('@quit-autoquit-app', function()
	local rec = recorder()
	local win1 = app:window(winpos())
	local win2 = app:window(winpos())
	function app:quitting() rec'quitting' end
	function win1:closing() rec'closing1' end
	function win2:closing() rec'closing2' end
	function app:exit()
		rec{'closing1', 'quitting', 'closing2'}
		return 1
	end
	app:autoquit(true)
	win1:close()
	win2:close()
	assert(false) --can't reach here
end, 1)

--window:autoquit(true) works
add('@quit-autoquit-window', function()
	local rec = recorder()
	local win1 = app:window(winpos())
	local win2 = app:window(winpos())
	function app:quitting() rec'quitting' end
	function win1:closing() rec'closing1' end
	function win2:closing() rec'closing2' end
	function app:exit()
		rec{'quitting', 'closing1', 'closing2'}
		return 1
	end
	app:autoquit(false)
	win2:autoquit(true)
	win2:close()
	assert(false) --can't reach here
end, 1)

--closing() and closed() are splitted out
add('@quit-quitting-sequence', function()
	local rec = recorder()
	local win1 = app:window(winpos())
	local win2 = app:window(winpos())
	function app:quitting() rec'quitting' end
	function win1:closing() rec'closing1' end
	function win2:closing() rec'closing2' end
	function win1:closed() rec'closed1' end
	function win2:closed() rec'closed2' end
	function app:exit()
		rec{'quitting', 'closing1', 'closing2', 'closed1', 'closed2'}
		return 1
	end
	app:autoquit(false)
	app:quit()
end, 1)

--quit() rejected because closing() rejected
add('@quit-quitting-closing-query', function()
	local rec = recorder()
	local allow
	local win = app:window(winpos())
	function win:closing()
		if not allow then --don't allow the first time
			allow = true
			rec'not allowing'
			return false
		else --allow the second time
			rec'allowing'
		end
	end
	function app:exit()
		rec{'not allowing', 'allowing'}
		return 1
	end
	app:autoquit(false)
	app:quit() --not allowed
	app:quit() --allowed
	assert(false) --can't reach here
end, 1)

--quit() rejected while closing()
add('@quit-quitting-while-closing', function()
	local rec = recorder()
	local allow
	local win = app:window(winpos())
	function win:closing()
		app:quit() --ignored because closing() is rejected
		rec'ignored'
	end
	function app:exit()
		rec{'ignored', 'closed'}
		return 1
	end
	app:autoquit(false)
	win:close()
	rec'closed'
	app:quit()
	assert(false) --can't reach here
end, 1)

--window closing ---------------------------------------------------------------------------------------------------------

--closed() event works
--dead() not yet true in the closed() event (we can still use the window)
add('@close-closed-not-dead', function()
	local rec = recorder()
	local win = app:window(winpos())
	function win:closed()
		assert(not self:dead()) --not dead yet
		rec'closed'
	end
	app:autoquit(false)
	assert(not win:dead())
	win:close()
	assert(win:dead()) --dead now
	rec{'closed'}
	os.exit(1)
end, 1)

--closing() event works
add('@close-closing-query', function()
	local rec = recorder()
	local win = app:window(winpos())
	local allow
	function win:closing()
		if not allow then --don't allow the first time
			rec'not allowing'
			allow = true
			return false
		else --allow the second time
			rec'allowing'
			return true
		end
	end
	app:autoquit(false)
	win:close() --not allowed
	assert(not win:dead())
	win:close() --allowed
	rec{'not allowing', 'allowing'}
	os.exit(1)
end, 1)

--close() is ignored from closed()
add('@close-while-closed', function()
	local rec = recorder()
	local win = app:window(winpos())
	function win:closed()
		self:close() --ignored because not dead yet
		assert(not self:dead()) --still not dead
		rec'closed'
	end
	app:autoquit(false)
	win:close()
	assert(win:dead())
	rec{'closed'}
	os.exit(1)
end, 1)

--close() is ignored from closing()
add('@close-while-closing', function()
	local rec = recorder()
	local win = app:window(winpos())
	function win:closing()
		self:close() --ignored
		assert(not self:dead())
		rec'closing'
	end
	app:autoquit(false)
	win:close()
	assert(win:dead())
	rec{'closing'}
	os.exit(1)
end, 1)

--window activaton -------------------------------------------------------------------------------------------------------




--window initial state flags  --------------------------------------------------------------------------------------------

local flag_list = {
	'visible', 'minimized', 'maximized', 'fullscreen',
}

--generate a name for a test given a combination of flags
local function test_name_for_flags(flags, name_prefix)
	local t = {}
	for i,flag in ipairs(flag_list) do
		if flags[flag] then t[#t+1] = flag end
	end
	return name_prefix .. '-' .. table.concat(t, '-')
end

--test that initial state flags are all set
local function test_init_flags(flags)
	local win = app:window(winpos(glue.update({w = 500, h = 200}, flags)))
	for i,flag in ipairs(flag_list) do
		assert(win[flag](win) == flags[flag], flag)
	end
	return win
end

--generate interactive tests for all combinations of initial state flags
for flags in combinations(flag_list) do
	add(test_name_for_flags(flags, '@states-init'), function()
		local win = test_init_flags(flags)
		function win:keydown(key)
			if key == 'F10' then
				self:restore()
			elseif key == 'F11' then
				self:fullscreen(not self:fullscreen())
			elseif key == 'F12' then
				self:maximize()
			elseif key == 'F9' then
				self:minimize()
			end
		end
		app:run()
	end)
end

--run the same non-interactive test each time on a window with different initial state flags
function test_combinations(test)
	app:autoquit(false)
	for flags in combinations(flag_list) do
		print(test_name_for_flags(flags, ''))
		local win = test_init_flags(flags)
		test(win, flags)
		win:close()
	end
end

--all initial (visible, minimized, maximized, fullscreen) combinations
--show() only changes visibility
--restore() to the correct state
add('@states-transitions', function()
	app:autoquit(false)
	test_combinations(function(win, c)
		--visible -> minimized | normal | maximized | fullscreen
		if not c.visible then
			win:show()
			assert(win:visible())
			assert(win:minimized() == c.minimized)
			assert(win:maximized() == c.maximized)
			assert(win:fullscreen() == c.fullscreen)
		end

		-- minimized -> normal | maximized | fullscreen
		if c.minimized then
			win:restore()
			assert(not win:minimized())
			assert(win:maximized() == c.maximized)
			assert(win:fullscreen() == c.fullscreen)
		end

		-- fullscreen -> normal | maximized
		if c.fullscreen then
			win:restore()
			assert(not win:fullscreen())
			assert(win:maximized() == c.maximized)
		end

		-- maximized -> normal
		if c.maximized then
			win:restore()
			assert(not win:maximized())
		end

		--normal
		assert(win:visible())
		assert(not win:minimized())
		assert(not win:maximized())
		assert(not win:fullscreen())
	end)
	os.exit(1)
end, 1)

--parent/child relationship

add('parent', function()
	local w1 = app:window(winpos{x = 100, y = 100, w = 500, h = 300})
	local w2 = app:window(winpos{x = 200, y = 200, w = 500, h = 300, parent = w1})
	function w2:closing()
		print'w2 closing'
	end
	function w1:closed()
		--w2:show()
		--w2.backend.nswin:makeKeyAndOrderFront(nil)
		print(w2:visible())
	end
	app:run()
end)

--test state transitions

add('@states', function()
	local win = app:window{x = 100, y = 100, w = 300, h = 100}

	local function check(s)
		assert(win:visible() == (s:match'v' ~= nil))
		assert(win:minimized() == (s:match'm' ~= nil))
		assert(win:maximized() == (s:match'M' ~= nil))
	end

	print('>', win:visible(), win:minimized(), win:maximized())
	win:maximize()
	win:minimize()
	print('>', win:visible(), win:minimized(), win:maximized())

	os.exit(1)

	--restore to maximized from minimized
	win:shownormal()
	win:maximize()
	win:minimize(); check'vmM'
	win:restore(); check'vM'

	--restore to normal from minimized
	win:shownormal()
	win:minimize(); check'vm'
	win:restore(); check'v'

	--restore to normal from maximized
	win:shownormal()
	win:maximize(); check'vM'
	win:restore(); check'v'

	--maximize from minimized
	win:shownormal()
	win:minimize(); check'vm'
	win:maximize(); check'vM'

	--show normal from minimized
	win:shownormal()
	win:maximize()
	win:minimize(); check'vmM'
	win:shownormal(); check'v'

	--minimize from hidden
	win:shownormal()
	win:hide(); check''
	win:minimize(); check'vm'

	--shownormal from hidden
	win:shownormal()
	win:hide(); check''
	win:shownormal(); check'v'

	--show from hidden
	win:shownormal()
	win:hide(); check''
	win:show(); check'v'

	--maximize from hidden
	win:shownormal()
	win:hide(); check''
	win:maximize(); check'vM'

	--restore to normal from hidden
	win:shownormal()
	win:hide(); check''
	win:restore(); check'v'

	--restore to normal from hidden/maximized
	win:shownormal()
	win:maximized()
	win:hide(); check''
	win:restore(); check'v'

	--restore to maximized from hidden/minimized
	win:maximize()
	win:minimize()
	win:hide(); check'mM'
	win:restore(); check'vM'

	--show minimized and then restore to normal from hidden
	win:shownormal()
	win:minimize()
	win:hide(); check'm'
	win:show(); check'vm'
	win:restore(); check'v'

	--show minimized and then restore to maximized from hidden
	win:maximize()
	win:minimize()
	win:hide(); check'mM'
	win:show(); check'vmM'
	win:restore(); check'vM'

	win:close()
end)

--test default flags

add('defaults', function()
	local win = app:window(winpos())
	assert(win:visible())
	assert(not win:minimized())
	assert(not win:fullscreen())
	assert(not win:maximized())
	assert(win:title() == '')
	assert(win:frame() == 'normal')
	assert(not win:topmost())
	assert(win:minimizable())
	assert(win:maximizable())
	assert(win:closeable())
	assert(win:resizeable())
	assert(win:fullscreenable())
end)

--test closeable

add('@closeable', function()
	local win = app:window(winpos{title = 'cannot close', closeable = false})
	assert(not win:closeable())
end)

--test resizeable

add('resizeable', function()
	local win = app:window(winpos{title = 'fixed size', resizeable = false})
	assert(not win:resizeable())
end)

--test get/set title

add('title', function()
	local win = app:window(winpos{title = 'with title'})
	assert(win:title() == 'with title')
	win:title'changed'
	assert(win:title() == 'changed')
	win:close()
end)

--test get/set topmost

add('topmost', function()
	local win = app:window(winpos{topmost = true})
	assert(win:topmost())
	win:topmost(false)
	assert(not win:topmost())
	win:topmost(true)
	assert(win:topmost())
	win:close()
end)

--frame types

add('frameless', function()
	local win = app:window(winpos{frame = 'none'})
	assert(win:frame() == 'none')
end)

add('transparent', function()
	local win = app:window(winpos{frame = 'transparent'})
	assert(win:frame() == 'transparent')
end)

--[[

local win1 = app:window{x = 100, y = 100, w = 800, h = 400, title = 'win1', visible = false,
								frame = 'transparent'}
local win2 = app:window{x = 200, y = 400, w = 600, h = 200, title = 'win2', visible = false,
								frame = 'none', resizeable = false, minimizable = false, maximizable = false,
								closeable = true}

assert(win1:display() == win2:display())
assert(win1:display() == app:main_display())

for win in app:windows() do
	win:title('[' .. win:title() .. ']')
	print('title', win:title())
end

function app:closed(win) print('closed', win:title()) end

function win1:closing() print'closing win1' end
function win2:closing() print'closing win2' end
function win1:closed() print'closed win1' end
function win2:closed() print'closed win2' end
function win1:activated() print'activated win1' end
function win2:activated() print'activated win2' end
function win1:deactivated() print'deactivated win1' end
function win2:deactivated() print'deactivated win2' end
function win1:frame_changing(how, x, y, w, h)
	print'frame_changing win1'
	if how == 'move' then
		x = math.min(math.max(x, 50), 250)
		y = math.min(math.max(y, 50), 250)
	end
	return x, y, w, h
end
function win1:frame_changed()
	print'frame_changed win1'
	self:invalidate()
end
function win2:frame_changed()
	print'frame_changed win2'
	self:invalidate()
end

function win1:render(cr)
	local w, h = select(3, self:frame_rect())
	cr:rectangle(0, 0, w, h)
	cr:set_source_rgba(1, 1, 1, 0.5)
	cr:set_line_width(10)
	cr:stroke()
	cr:rectangle(50, 50, 100, 100)
	cr:set_source_rgba(1, 0, 0, 0.5)
	cr:fill()
end

win2.render = win1.render

function win1:hover() print'hover win1' end
function win2:hover() print'hover win2' end
function win1:leave() print'leave win1' end
function win2:leave() print'leave win2' end
function win1:mousemove() print('mousemove win1', win1.mouse.x, win1.mouse.y) end
function win2:mousemove() print('mousemove win2', win2.mouse.x, win2.mouse.y) end
function win1:mousedown(button, click_count) print('mousedown win1', button) end
function win2:mousedown(button, click_count) print('mousedown win2', button) end
function win1:mouseup(button, click_count) print('mouseup win1', button) end
function win2:mouseup(button, click_count) print('mouseup win2', button) end
function win1:click(button, click_count)
	print('click win1', button, click_count)
	if click_count == 2 then return true end
end
function win2:click(button, click_count)
	print('click win2', button, click_count)
	if click_count == 3 then return true end
end
function win1:wheel(delta) print('wheel win1', delta) end
function win2:wheel(delta) print('wheel win2', delta) end

local commands = {
	Q = function(self) if win1:maximized() then win1:restore() else win1:maximize() end end,
	W = function(self) win1:maximize() end,
	E = function(self) if win1:visible() then win1:hide() else win1:show() end end,
	R = function(self) self:frame('allow_resize', not self:frame'allow_resize') end,

	F11 = function(self)
		self:fullscreen(not self:fullscreen())
	end,

	left = function(self) local x, y, w, h = self:frame_rect(); x = x - 100; self:frame_rect(x, y, w, h) end,
	right = function(self) local x, y, w, h = self:frame_rect(); x = x + 100; self:frame_rect(x, y, w, h) end,
	up = function(self) local x, y, w, h = self:frame_rect(); y = y - 100; self:frame_rect(x, y, w, h) end,
	down = function(self) local x, y, w, h = self:frame_rect(); y = y + 100; self:frame_rect(x, y, w, h) end,

	space = function(self)
		local state = self:state()
		if self:state() == 'maximized' then
			self:show'normal'
		elseif self:state() == 'normal' then
			self:show'minimized'
		elseif self:state() == 'minimized' then
			self:show'maximized'
		end
		print('state', state, '->', self:state())
	end,
	esc = function(self)
		if win2:active() then
			win1:activate()
		elseif win1:active() then
			win2:activate()
		end
	end,
	H = function(self)
		if self:visible() then
			self:hide()
		else
			self:show()
		end
	end,
	M = function(self)
		app:window{x = 200, y = 200, w = 200, h = 200, title = 'temp', visible = true, state = 'minimized'}
	end,
	shift = function(self)
		print('shift-key', self:key'lshift' and 'left' or 'right')
	end,
	alt = function(self)
		print('alt-key', self:key'lalt' and 'left' or 'right')
	end,
	ctrl = function(self)
		print('ctrl-key', self:key'lctrl' and 'left' or 'right')
	end,
}

function win2:keypress(key)
	print('keypress', key, self:key(key))
	if commands[key] then
		commands[key](self)
	end
end

function win2:keydown(key)
	print('keydown', key, self:key(key))
end

win1.keydown = win2.keydown
win1.keypress = win2.keypress

function win2:keyup(key)
	print('keyup', key, self:key(key))
end

function win2:keychar(char) print('keychar', char) end

win1:show()
win2:show()

assert(win1:dead())
assert(win2:dead())

win1:close() --ignored
win2:close() --ignored

]]

testui(...)

