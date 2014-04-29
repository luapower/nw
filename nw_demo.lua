local nw = require'nw'
local glue = require'glue'
io.stdout:setvbuf'no'

local app = nw:app()

--collecting and running tests

local tests = {}

local function add(name, f)
	table.insert(tests, f)
	tests[name] = f
	tests[f] = name
end

local function test(what, ...)
	if what then
		tests[what](...)
	else
		for i,f in ipairs(tests) do
			print()
			print(tests[f])
			print'========================='
			f(what, ...)
		end
	end
end

--system info

--double click time is sane
--target area is sane
add('double-click metrics', function()

	local t = app.impl:double_click_time()
	print('double_click_time', t)
	assert(t > 0 and t < 5000)

	local w, h = app.impl:double_click_target_area()
	print('double_click_target_area', w, h)
	assert(w > 0 and w < 100)
	assert(h > 0 and h < 100)
end)

--display info

--client rect is be fully enclosed in screen rect
local function test_display(display)

	local x, y, w, h = display:rect()
	print('rect',  x, y, w, h)

	local cx, cy, cw, ch = display:client_rect()
	print('client_rect', cx, cy, cw, ch)

	--client rect must be fully enclosed in screen rect
	assert(cx >= x)
	assert(cy >= y)
	assert(cw <= w)
	assert(ch <= h)
end

--there's at least one display and its values are sane
add('displays', function()
	local i = 0
	for display in app:displays() do
		i = i + 1
		test_display(display)
	end
	assert(i > 0) --there must be at least 1 display
end)

--main display is at (0, 0)
--main display has sane size
add('main display', function()
	local display = app:main_display()
	test_display(display)
	local x, y, w, h = display:rect()
	--main screen is at (0, 0)
	assert(x == 0)
	assert(y == 0)
	--sane size
	assert(w > 100)
	assert(h > 100)
end)

--time

--time and timediff values are sane
add('time', function()
	local t = app:time()
	print('time', t)
	assert(t > 0)

	local d = app:timediff(t)
	print('timediff', d)
	assert(d > 0 and d < 1000)
end)

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
	local t = {}
	local function record(...)
		t[#t+1] = {n = select('#', ...), ...}
	end
	--app:observe('event', record)
	return function(expected)
		--for
	end
end

--app running, quitting and window closing

--run() is a no-op until there are windows
--quit() is a no-op if not already running
--run() is a no-op if already running
--running() check works
--run() doesn't return
--closing() query works
--quitting after the last window is closed works
--close() from closed() event is a no-op
--dead() from closed() is false (window is not dead yet, we can still release any resources tied to it)
--exit() query works
--TODO: quit() from closed() event works
add('run', function()
	app:run() --no-op: there are no windows yet
	app:quit() --no-op: not running yet
	assert(not app:running())
	local win = app:window(winpos{title = 'win'})
	function win:closed()
		assert(app:running())
		app:run() --no-op: already running
		self:close() --no-op: already closed
		assert(not self:dead()) --but not dead yet
		print('closed')
	end
	local allow
	function win:closing()
		if not allow then --don't allow the first time
			print'not allowing'
			allow = true
			return false
		else --allow the second time
			print'allowing'
			return true
		end
	end
	function app:exit()
		print'exit'
		return -1
	end
	app:run()
	assert(false) --can't reach here
end)

test'run'

--window closing query

add('closing', function()
	local win = app:window(winpos{})
	local allow
	function win:closing()
		return allow
	end
	allow = false; win:close()
	assert(not win:dead())
	allow = true; win:close()
	--process didn't exit because app wasn't running
	print'still here'
	assert(win:dead())
	--TODO: segmentation fault !!!
end)

--test'closing'

--test'closing'

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

--test all combinations of window initial state flags and transitions to saved states

local function test_states(c, close_it)
	if close_it == nil then close_it = true end
	local function BS(b)
		return b and 'Y' or 'N'
	end
	local test = string.format(
		'vis: %s, min: %s, fs: %s, max: %s, @min: %s, @max: %s',
							BS(c.visible),
							BS(c.minimized),
							BS(c.fullscreen),
							BS(c.maximized),
							BS(c.minimizable),
							BS(c.maximizable))
	print(test)

	local win = app:window(winpos(c, close_it))

	assert(win:visible() == c.visible)
	assert(win:minimized() == c.minimized)
	assert(win:fullscreen() == c.fullscreen)
	assert(win:maximized() == c.maximized)

	--visible -> minimized | normal | maximized
	if not c.visible then
		win:show()
		assert(win:visible())
		assert(win:minimized() == c.minimized)
		assert(win:maximized() == c.maximized)
	end

	-- minimized -> normal | maximized
	if c.minimized then
		win:restore()
		assert(not win:minimized())
		assert(win:maximized() == c.maximized)
	end

	-- maximized -> normal
	if c.maximized then
		win:restore()
	end

	--normal
	assert(win:visible())
	assert(not win:minimized())
	assert(not win:maximized())

	--close
	if close_it then
		win:close()
		assert(win:dead())
	end
end

local flags = {
	'visible', 'minimized', 'fullscreen', 'maximized',
	'minimizable', 'maximizable', 'closeable', 'resizeable',
}

add('flags', function(close_win)
	for c in combinations(flags) do
		test_states(c, close_win)
	end
end)

--test state transitions

add('states', function()
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
end)

--test closeable

add('closeable', function()
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

--test('flags', true)
--test'states'
--test'frameless'
--test'transparent'

--app:run()

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

