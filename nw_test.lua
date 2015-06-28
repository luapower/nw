io.stdout:setvbuf'no'
io.stderr:setvbuf'no'

local nw = require'nw'
local glue = require'glue'
local ffi = require'ffi'
local bit = require'bit'
local box2d = require'box2d'
local bitmap = require'bitmap'
local pp = require'pp'

--local objc = require'objc'
--objc.debug.logtopics.refcount = true

local app --global app object

--testing helpers ------------------------------------------------------------

--collecting and running tests

local tests = {} --{name = test} also {test1, ...} also {test = name}

--add a named test to the tests collection
local function add(name, test)
	table.insert(tests, name)
	tests[name] = test
end

local function run_test(name)
	app = app or nw:app()
	tests[name]()
end

--run all tests whose names match a pattern, in order
local function run_all_matching(patt)
	for i,name in ipairs(tests) do
		if name:match(patt) then
			print()
			print(name)
			print(('-'):rep(70))
			run_test(name)
		end
	end
end

--window position generators

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

local function cascadepos(t)
	x = x + 50
	y = y + 50
	return glue.update({x = x, y = y, w = 240, h = 190}, t)
end

--event recorder/checker

local function recorder()
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
		print'ok'
	end
	return function(e, ...)
		if type(e) == 'table' then
			check(e)
		else
			record(e, ...)
		end
	end
end

--add key bindings for window commands for interactive tests.

local function make_interactive(win)
	function win:keydown(key)
		if key == 'S' then
			self:show()
		elseif key == 'H' then
			self:hide()
		elseif key == 'R' then
			self:restore()
		elseif key == 'F' then
			self:fullscreen(true)
		elseif key == 'G' then
			self:fullscreen(false)
		elseif key == 'M' then
			self:maximize()
		elseif key == 'N' then
			self:minimize()
		else
			print[[
S    show
H    hide
R    restore
F    enter fullscreen
G    exit fullscreen
M    maximize
N    minimize
]]
		end
	end
end

--function wrapper that provides a sleep() function.

local function sleep(seconds)
	coroutine.yield(seconds)
end

local function process(func)
	return function(...)
		local proc = coroutine.wrap(function(...)
			local ok, res = xpcall(func, debug.traceback, ...)
			if not ok then error(res) end
			return res
		end)
		local function step(...)
			local seconds = proc(...)
			if not seconds then
				app:quit()
				return
			end
			app:runafter(seconds, step)
		end
		app:runafter(0, step)
		app:run()
	end
end

--os version -----------------------------------------------------------------

add('os', function()
	print(nw:os())
	assert(nw:os(nw:os():upper())) --perfect case-insensitive match
	assert(not nw:os'')
	assert(not nw:os'XXX')
	if ffi.os == 'OSX' then
		assert(nw:os'osx')
		assert(nw:os'OSX 1')
		assert(nw:os'OSX 10')
		assert(nw:os'OSX 10.2')
		assert(not nw:os'OSX ChubbyCheese')
		assert(not nw:os'OSX 55')
		assert(not nw:os'OS')
	elseif ffi.os == 'Windows' then
		assert(nw:os'windows')
		assert(nw:os'WINDOWS 1')
		assert(nw:os'WINDOWS 5')
		assert(nw:os'WINDOWS 5.0')
		assert(nw:os'WINDOWS 5.0.sp1')
		assert(not nw:os'WINDOWS 55.0.sp1')
		assert(not nw:os'Window')
	elseif ffi.os == 'Linux' then
		assert(nw:os'linux')
		assert(nw:os'Linux')
	end
	print'ok'
end)

--time -----------------------------------------------------------------------

--time values are sane.
add('time-time', function()
	local t = app:time()
	print('time    ', t)
	assert(t > 0)
end)

--timediff values are sane (less than 1ms between 2 calls but more than 0).
add('time-timediff', function()
	local d = app:timediff(app:time())
	print('timediff', d)
	assert(d > 0 and d < 1)
end)

--timers ---------------------------------------------------------------------

--runafter() works, i.e.:
--negative intervals are clamped.
--timers don't start before the loop starts.
--timer interval is respected more/less.
--timers don't fire more than once.
add('timer-runafter', function()
	local rec = recorder()
	app:runafter(-1, function() --clamped to 0
		rec(0)
	end)
	app:runafter(0.4, function()
		rec(4)
		app:quit()
	end)
	app:runafter(0.1, function()
		rec(1)
		app:runafter(0.2, function()
			rec(3)
		end)
		app:runafter(0.1, function()
			rec(2)
		end)
	end)
	rec'start' --timers start after run
	app:run()
	rec{'start', 0, 1, 2, 3, 4}
end)

--runevery() works, i.e.:
--negative intervals are clamped.
--timers don't start before the loop starts.
--timers fire continuously, but stop if false is returned.
add('timer-runevery', function()
	local rec = recorder()
	local i = 1
	app:runevery(0, function()
		rec(i)
		local stop = i == 3
		i = i + 1
		if stop then
			app:runafter(0.2, function()
				rec'quit'
				app:quit()
			end)
			rec'stop'
			return false
		end
	end)
	rec'start'
	app:run()
	rec{'start', 1, 2, 3, 'stop', 'quit'}
end)

--app running and stopping ---------------------------------------------------

--run() starts the loop even if there are no windows.
--run() is ignored while running.
--run() returns.
add('loop-run-stop', function()
	local rec = recorder()
	app:runafter(0, function()
		app:run() --ignored, already running
		app:stop()
		rec'after-stop'
	end)
	app:run() --not returning immediately, stopped by timer
	rec{'after-stop'}
end)

--running() is true while app is running.
--running() is true after app:stop() is called.
add('loop-running', function()
	local rec = recorder()
	app:runafter(0, function()
		assert(app:running())
		app:stop()
		assert(app:running())
		app:stop() --ignored if called a second time
		assert(app:running())
		rec'after-stop'
	end)
	assert(not app:running())
	app:run()
	assert(not app:running())
	rec{'after-stop'}
end)

--app quitting ---------------------------------------------------------------

--quit() is ignored if app not running.
--quit() stops the loop.
--quit() returns.
add('quit-quit', function()
	local rec = recorder()
	app:runafter(0, function()
		rec'before-quit'
		app:quit()
		rec'after-quit'
	end)
	app:quit() --ignored, not running
	app:run()
	rec{'before-quit', 'after-quit'}
end)

--quitting() event works, even if there are no windows
add('quit-quitting', function()
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
	app:autoquit(false)
	app:runafter(0, function()
		app:quit()
		app:quit()
	end)
	app:run()
	rec{'not allowing', 'allowing'}
end)

--quitting() comes before closing() on all windows.
--closing() called in creation order.
add('quit-quitting-before-closing', function()
	local rec = recorder()
	local win1 = app:window(winpos())
	local win2 = app:window(winpos())
	function app:quitting() rec'quitting' end
	function win1:closing() rec'closing1' end
	function win2:closing() rec'closing2' end
	app:autoquit(false)
	app:runafter(0, function() app:quit() end)
	app:run()
	rec{'quitting', 'closing1', 'closing2'}
end)

--quit() fails if windows are created while quitting.
add('quit-fails', function()
	local rec = recorder()
	local win = app:window(winpos())
	function win:closed()
		app:window(winpos())
	end
	app:autoquit(false)
	app:runafter(0, function()
		app:quit()
		rec(app:window_count())
		app:quit()
		rec(app:window_count())
	end)
	app:run()
	rec{1,0}
end)

--app:autoquit(true) works.
add('quit-autoquit-app', function()
	local rec = recorder()
	local win1 = app:window(winpos())
	local win2 = app:window(winpos())
	function app:quitting() rec'quitting' end
	function win1:closing() rec'closing1' end
	function win2:closing() rec'closing2' end
	app:autoquit(true)
	app:runafter(0, function()
		win1:close()
		win2:close()
	end)
	app:run()
	rec{'closing1', 'quitting', 'closing2'}
end)

--window:autoquit(true) works.
add('quit-autoquit-window', function()
	local rec = recorder()
	local win1 = app:window(winpos())
	local win2 = app:window(winpos())
	function app:quitting() rec'quitting' end
	function win1:closing() rec'closing1' end
	function win2:closing() rec'closing2' end
	app:autoquit(false)
	win2:autoquit(true)
	app:runafter(0, function()
		win2:close()
	end)
	app:run()
	rec{'quitting', 'closing1', 'closing2'}
end)

--closing() and closed() are splitted out.
add('quit-quitting-sequence', function()
	local rec = recorder()
	local win1 = app:window(winpos())
	local win2 = app:window(winpos())
	function app:quitting() rec'quitting' end
	function win1:closing() rec'closing1' end
	function win2:closing() rec'closing2' end
	function win1:closed() rec'closed1' end
	function win2:closed() rec'closed2' end
	app:autoquit(false)
	app:runafter(0, function()
		app:quit()
	end)
	app:run()
	rec{'quitting', 'closing1', 'closing2', 'closed1', 'closed2'}
end)

--quit() rejected because closing() rejected.
add('quit-quitting-closing-query', function()
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
	app:autoquit(false)
	app:runafter(0, function()
		app:quit() --not allowed
		app:quit() --allowed
	end)
	app:run()
	rec{'not allowing', 'allowing'}
end)

--quit() rejected while closing().
add('quit-quitting-while-closing', function()
	local rec = recorder()
	local allow
	local win = app:window(winpos())
	function win:closing()
		app:quit() --ignored because closing() is rejected
		rec'ignored'
	end
	app:autoquit(false)
	app:runafter(0, function()
		win:close()
		rec'closed'
		app:quit()
	end)
	app:run()
	rec{'ignored', 'closed'}
end)

--window default options -----------------------------------------------------

add('init-defaults', function()
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
	assert(not win:autoquit())
	assert(win:edgesnapping() == 'screen')
end)

--window closing -------------------------------------------------------------

--closed() event works, even before the app starts.
--dead() not yet true in the closed() event (we can still use the window).
add('close-closed-not-dead', function()
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
end)

--closing() event works, even before the app starts.
add('close-closing-query', function()
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
end)

--close() is ignored from closed().
add('close-while-closed', function()
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
end)

--close() is ignored from closing().
add('close-while-closing', function()
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
end)

--child can close its parent from closed() event.
add('close-parent-from-closed', function()
	app:autoquit(false)
	local win1 = app:window(winpos{title = 'win1'})
	local win2 = app:window(winpos{title = 'win2', parent = win1})
	function win1:closed()
		print'win1 closed'
	end
	function win2:closed()
		print'win2 closed'
		win1:close()
	end
	win2:close()
	assert(win1:dead())
	assert(win2:dead())
	print'ok'
end)

--children close too when parent closes.
add('close-children', function()
	app:autoquit(false)
	local win1 = app:window(winpos{title = 'win1'})
	local win2 = app:window(winpos{title = 'win2', parent = win1})
	function win1:closed() print'win1 closed' end
	function win2:closed() print'win2 closed' end
	win1:close()
	app:runafter(0, function()
		assert(win1:dead())
		assert(win2:dead())
		app:quit()
	end)
	app:run()
	print'ok'
end)

--ask children too when parent closes.
add('close-children-ask', function()
	app:autoquit(false)
	local win1 = app:window(winpos{title = 'win1'})
	local win2 = app:window(winpos{title = 'win2', parent = win1})
	function win2:closing() return false end
	win1:close()
	assert(not win1:dead())
	assert(not win2:dead())
	print'ok'
end)

--window & app activaton -----------------------------------------------------

--1. the OS activates the app when the first window is created.
--2. the app activation event comes before the win activation event.
--3. the OS deactivates the app when the last window is closed (Windows).
--4. the app deactivation event comes after the win deactivation event.
--5. activation events deferred for when the app starts, and then,
--a single app:activated() event is fired, followed by a single
--win:activated() event from the last window that was activated.
--6. app:active() is true all the way.
--7. only in Windows, after the last window is closed, the app is deactivated.
--8. app:active_window() works (gives the expected window).
add('activation-events', function()
	local rec = recorder()
	local win1 = app:window(winpos())
	local win2 = app:window(winpos())
	local win3 = app:window(winpos())
	function app:activated() rec'app-activated' end
	function app:deactivated() rec'app-deactivated' end
	function win1:activated() rec'win1-activated' end
	function win2:activated() rec'win2-activated' end
	function win3:activated() rec'win3-activated' end
	function win1:deactivated() rec'win1-deactivated' end
	function win2:deactivated() rec'win2-deactivated' end
	function win3:deactivated() rec'win3-deactivated' end
	app:runafter(0, function()
		rec'started'
		assert(app:active())
		win1:activate(); assert(app:active_window() == win1)
		win2:activate(); assert(app:active_window() == win2)
		win3:activate(); assert(app:active_window() == win3)
		win3:close();    assert(app:active_window() == win2)
		win2:close();    assert(app:active_window() == win1)
		assert(app:active())
		win1:close()
		assert(not app:active_window())
		if ffi.os == 'Windows' then
			--on Windows, the app is deactivated after the last windows is closed.
			assert(not app:active())
		else
			--on OSX, the app stays active (there's still the main menu and the dock icon).
			rec'app-deactivated' --fake entry
			assert(app:active())
		end
		rec'ended'
	end)
	rec'before-run'
	app:run()
	rec{
		'before-run',
		'app-activated',
		'win3-activated',
		'started',
		'win3-deactivated', 'win1-activated',
		'win1-deactivated', 'win2-activated',
		'win2-deactivated', 'win3-activated',
		'win3-deactivated', 'win2-activated',
		'win2-deactivated', 'win1-activated',
		'win1-deactivated',
		'app-deactivated', --not on OSX
		'ended',
	}
end)

--in Windows, app:activate() does not activate the window immediately.
--instead, it flashes the window on the taskbar waiting for the user
--to click on it (or alt-tab to it) and activate it.
--this is an interactive test: you must activate another app to see it.
add('activation-app-activate-flashing', function()
	local win = app:window(winpos())
	function win:activated() print'win-activated' end
	function app:activated() print'app-activated' end
	function win:deactivated() print'win-deactivated' end
	function app:deactivated()
		print'app-deactivated'
		app:runafter(1, function()
			app:activate()
		end)
	end
	app:run()
end)


--app:activate() works, activating the app continuously.
--this is an interactive test: you must activate another app to see it.
--note: on OSX, the app is not activated immediately but on the next message loop.
add('activation-app-activate', function()
	function app:activated() print'app-activated' end
	function app:deactivated() print'app-deactivated' end
	local win = app:window(winpos())
	function win:activated() print'win-activated' end
	function win:deactivated() print'win-deactivated' end
	app:runevery(0.1, function()
		app:activate()
		print('app:active() -> ', app:active(), 'app:active_window() -> ', app:active_window())
	end)
	app:run()
end)

--if there are no visible windows, in Windows, app:activate() is ignored
--(there's no concept of an app outside the concept of windows), while
--in OSX the app's main menu is activated.
--this is an interactive test: you must activate another app to see it.
add('activation-app-activate-no-windows', function()
	function app:activated() print'activated' end
	function app:deactivated() print'deactivated' end
	local win = app:window(winpos{visible = false})
	app:runevery(0.1, function()
		app:activate()
		print('app:active() -> ', app:active(), 'app:active_window() -> ', app:active_window())
	end)
	app:run()
end)

--app:active() works (returns true only if the app is active).
--app:active_window() works (always returns nil if the app is not active).
--this is an interactive test: you must activate another app to see it.
add('activation-app-active', function()
	local win = app:window(winpos())
	app:runevery(0.1, function()
		if app:active() then
			print('app is active', 'app:active_window() -> ', app:active_window())
		else
			print('app is not active', 'app:active_window() -> ', app:active_window())
		end
	end)
	app:run()
	print'ok'
end)

--when the app is inactive, window:activate() is deferred to when the app becomes active.
--this is an interactive test: you must activate win2 and then activate another app to see it.
add('activation-window-activate-defer', function()
	local win1 = app:window(winpos()); win1.name = 'w1'
	local win2 = app:window(winpos()); win2.name = 'w2'
	function win1:activated() print'win1-activated' end
	function win2:activated() print'win2-activated' end
	function app:activated() print'app-activated' end
	function app:deactivated()
		print'app-deactivated'
		win1:activate()
		app:runafter(1, function()
			app:activate()
		end)
	end
	local _activated
	app:runevery(0.2, function()
		if win1:dead() or win2:dead() then
			app:quit()
		else
			print(
				'app active?', app:active(),
				'active window:', app:active_window() and app:active_window().name,
				'win1 active?', win1:active(),
				'win2 active?', win2:active()
			)
		end
	end)
	app:run()
end)

--window:activate() doesn't do anything for hidden windows.
--when the window is finally shown, the app doesn't activate.
--this is an interactive test: you must activate another app to see it.
add('activation-window-activate-hidden', function()
	local rec = recorder()
	local win1 = app:window(winpos{visible = false})
	local win2 = app:window(winpos{visible = false})
	function win1:activated() rec'win1-activated' end
	function win2:activated() rec'win2-activated' end
	app:runafter(0, function()
		print'click on this terminal window now...'
		win1:activate()
		win2:activate()
		win1:activate()
		app:runafter(2, function()
			win2:show()
			app:runafter(1, function()
				app:quit()
			end)
		end)
	end)
	app:run()
	rec{}
end)

--activable flag works for child toolbox windows.
--this is an interactive test: move the child window and it doesn't activate.
add('activation-window-nonactivable', function()
	local win1 = app:window{x = 100, y = 100, w = 500, h = 200}
	local win2 = app:window{x = 200, y = 130, w = 200, h = 300,
		activable = false, frame = 'toolbox', parent = win1}
	app:run()
end)

--app visibility (OSX only) --------------------------------------------------

add('app-hide', process(function()
	local rec = recorder()
	function app:did_hide() rec'hide' end
	function app:did_unhide() rec'unhide' end
	assert(not app:hidden())
	app:hide()
	sleep(0.1)
	assert(app:hidden())
	app:unhide()
	sleep(0.1)
	assert(not app:hidden())
	rec{'hide', 'unhide'}
end))

--window states --------------------------------------------------------------

--check various state transitions.
--each entry in the table describes one test:
--		{command-list, flagcheck, command-list, flag-check}.
--these tests take some time, better disable window animations in the OS before running them.
--NOTE: fullscreen animations on OSX (the most annoying of all) cannot be disabled.
for i,test in ipairs({

	--transitions fron normal
	{{}, 'v', {'show'}, 'v'},
	{{}, 'v', {'hide'}, ''},
	{{}, 'v', {'maximize'}, 'vM'},
	{{}, 'v', {'minimize'}, 'vm'},
	{{}, 'v', {'restore'}, 'v'},
	{{}, 'v', {'shownormal'}, 'v'},
	--transitions fron hidden
	{{'hide'}, '', {'show'}, 'v'},
	{{'hide'}, '', {'hide'}, ''},
	{{'hide'}, '', {'maximize'}, 'vM'},
	{{'hide'}, '', {'minimize'}, 'vm'},
	{{'hide'}, '', {'restore'}, 'v'},
	{{'hide'}, '', {'shownormal'}, 'v'},
	--transitions fron minimized
	{{'minimize'}, 'vm', {'show'}, 'vm'},
	{{'minimize'}, 'vm', {'hide'}, 'm'},
	{{'minimize'}, 'vm', {'maximize'}, 'vM'},
	{{'minimize'}, 'vm', {'minimize'}, 'vm'},
	{{'minimize'}, 'vm', {'restore'}, 'v'},
	{{'minimize'}, 'vm', {'shownormal'}, 'v'},
	--transitions from maximized
	{{'maximize'}, 'vM', {'show'}, 'vM'},
	{{'maximize'}, 'vM', {'hide'}, 'M'},
	{{'maximize'}, 'vM', {'maximize'}, 'vM'},
	{{'maximize'}, 'vM', {'minimize'}, 'vmM'},
	{{'maximize'}, 'vM', {'restore'}, 'v'},
	{{'maximize'}, 'vM', {'shownormal'}, 'v'},
	--transitions from hidden minimized
	{{'minimize', 'hide'}, 'm', {'show'}, 'vm'},
	{{'minimize', 'hide'}, 'm', {'hide'}, 'm'},
	{{'minimize', 'hide'}, 'm', {'maximize'}, 'vM'},
	{{'minimize', 'hide'}, 'm', {'minimize'}, 'vm'},
	{{'minimize', 'hide'}, 'm', {'restore'}, 'v'},
	{{'minimize', 'hide'}, 'm', {'shownormal'}, 'v'},
	--transitions from hidden maximized
	{{'maximize', 'hide'}, 'M', {'show'}, 'vM'},
	{{'maximize', 'hide'}, 'M', {'hide'}, 'M'},
	{{'maximize', 'hide'}, 'M', {'maximize'}, 'vM'},
	{{'maximize', 'hide'}, 'M', {'minimize'}, 'vmM'},
	{{'maximize', 'hide'}, 'M', {'restore'}, 'v'},
	{{'maximize', 'hide'}, 'M', {'shownormal'}, 'v'},
	--transitions from minimized maximized
	{{'maximize', 'minimize'}, 'vmM', {'show'}, 'vmM'},
	{{'maximize', 'minimize'}, 'vmM', {'hide'}, 'mM'},
	{{'maximize', 'minimize'}, 'vmM', {'maximize'}, 'vM'},
	{{'maximize', 'minimize'}, 'vmM', {'minimize'}, 'vmM'},
	{{'maximize', 'minimize'}, 'vmM', {'restore'}, 'vM'},
	{{'maximize', 'minimize'}, 'vmM', {'shownormal'}, 'v'},
	--transitions from hidden minimized maximized
	{{'maximize', 'minimize', 'hide'}, 'mM', {'show'}, 'vmM'},
	{{'maximize', 'minimize', 'hide'}, 'mM', {'hide'}, 'mM'},
	{{'maximize', 'minimize', 'hide'}, 'mM', {'maximize'}, 'vM'},
	{{'maximize', 'minimize', 'hide'}, 'mM', {'minimize'}, 'vmM'},
	{{'maximize', 'minimize', 'hide'}, 'mM', {'restore'}, 'vM'},
	{{'maximize', 'minimize', 'hide'}, 'mM', {'shownormal'}, 'v'},

	--transitions from fullscreen
	{{'enter_fullscreen'}, 'vF', {'show'}, 'vF'},
	{{'enter_fullscreen'}, 'vF', {'hide'}, 'vF'},
	{{'enter_fullscreen'}, 'vF', {'maximize'}, 'vF'},
	{{'enter_fullscreen'}, 'vF', {'minimize'}, 'vF'},
	{{'enter_fullscreen'}, 'vF', {'restore'}, 'v'},
	{{'enter_fullscreen'}, 'vF', {'shownormal'}, 'vF'},
	--transitions from hidden fullscreen
	{{'enter_fullscreen', 'hide'}, 'vF', {'show'}, 'vF'},
	{{'enter_fullscreen', 'hide'}, 'vF', {'hide'}, 'vF'},
	{{'enter_fullscreen', 'hide'}, 'vF', {'maximize'}, 'vF'},
	{{'enter_fullscreen', 'hide'}, 'vF', {'minimize'}, 'vF'},
	{{'enter_fullscreen', 'hide'}, 'vF', {'restore'}, 'v'},
	{{'enter_fullscreen', 'hide'}, 'vF', {'shownormal'}, 'vF'},
	--transitions from maximized fullscreen
	{{'maximize', 'enter_fullscreen'}, 'vMF', {'show'}, 'vMF'},
	{{'maximize', 'enter_fullscreen'}, 'vMF', {'hide'}, 'vMF'},
	{{'maximize', 'enter_fullscreen'}, 'vMF', {'maximize'}, 'vMF'},
	{{'maximize', 'enter_fullscreen'}, 'vMF', {'minimize'}, 'vMF'},
	{{'maximize', 'enter_fullscreen'}, 'vMF', {'restore'}, 'vM'},
	{{'maximize', 'enter_fullscreen'}, 'vMF', {'shownormal'}, 'vMF'},
	--transitions from hidden maximized fullscreen
	{{'maximize', 'enter_fullscreen', 'hide'}, 'vMF', {'show'}, 'vMF'},
	{{'maximize', 'enter_fullscreen', 'hide'}, 'vMF', {'hide'}, 'vMF'},
	{{'maximize', 'enter_fullscreen', 'hide'}, 'vMF', {'maximize'}, 'vMF'},
	{{'maximize', 'enter_fullscreen', 'hide'}, 'vMF', {'minimize'}, 'vMF'},
	{{'maximize', 'enter_fullscreen', 'hide'}, 'vMF', {'restore'}, 'vM'},
	{{'maximize', 'enter_fullscreen', 'hide'}, 'vMF', {'shownormal'}, 'vMF'},
	--transitions to enter fullscreen
	{{}, 'v', {'enter_fullscreen'}, 'vF'},
	{{'hide'}, '', {'enter_fullscreen'}, 'vF'},
	{{'minimize'}, 'vm', {'enter_fullscreen'}, 'vF'},
	{{'maximize'}, 'vM', {'enter_fullscreen'}, 'vMF'},
	{{'minimize', 'hide'}, 'm', {'enter_fullscreen'}, 'vF'},
	{{'maximize', 'minimize'}, 'vmM', {'enter_fullscreen'}, 'vMF'},
	{{'maximize', 'minimize', 'hide'}, 'mM', {'enter_fullscreen'}, 'vMF'},
	{{'enter_fullscreen'}, 'vF', {'enter_fullscreen'}, 'vF'},
	{{'enter_fullscreen', 'hide'}, 'vF', {'enter_fullscreen'}, 'vF'},
	{{'maximize', 'enter_fullscreen'}, 'vMF', {'enter_fullscreen'}, 'vMF'},
	{{'maximize', 'enter_fullscreen', 'hide'}, 'vMF', {'enter_fullscreen'}, 'vMF'},
	--transitions to exit fullscreen
	{{}, 'v', {'exit_fullscreen'}, 'v'},
	{{'hide'}, '', {'exit_fullscreen'}, ''},
	{{'minimize'}, 'vm', {'exit_fullscreen'}, 'vm'},
	{{'maximize'}, 'vM', {'exit_fullscreen'}, 'vM'},
	{{'minimize', 'hide'}, 'm', {'exit_fullscreen'}, 'm'},
	{{'maximize', 'minimize'}, 'vmM', {'exit_fullscreen'}, 'vmM'},
	{{'maximize', 'minimize', 'hide'}, 'mM', {'exit_fullscreen'}, 'mM'},
	{{'enter_fullscreen'}, 'vF', {'exit_fullscreen'}, 'v'},
	{{'enter_fullscreen', 'hide'}, 'vF', {'exit_fullscreen'}, 'v'},
	{{'maximize', 'enter_fullscreen'}, 'vMF', {'exit_fullscreen'}, 'vM'},
	{{'maximize', 'enter_fullscreen', 'hide'}, 'vMF', {'exit_fullscreen'}, 'vM'},

}) do
	local commands1, check1, commands2, check2 = unpack(test)

	local function make_test(init_flags)

		--compose test name.
		local t = {}
		t[#t+1] = init_flags.visible == false and 'hidden' or nil
		t[#t+1] = init_flags.maximized and 'maximized' or nil
		glue.extend(t, commands1, commands2)
		glue.append(t, init_flags.frame == 'none' and 'noframe' or nil)
		local test_name = table.concat(t, '-')

		add('state-'..test_name, process(function()

			app:autoquit(false)
			local win = app:window(winpos(init_flags))
			local rec = recorder()

			local function flags_string()
				return
					(win:visible() and 'v' or '')..
					(win:minimized() and 'm' or '')..
					(win:maximized() and 'M' or '')..
					(win:fullscreen() and 'F' or '')
			end

			local changed = 0
			function win:event(e, ...)
				if e == 'changed' or e == 'closed' then
					print('> '..e, flags_string())
				end
				if e == 'changed' then
					changed = changed + 1
				end
			end

			local function run_commands(commands, expected_flags)

				--run a list of commands without args on a window object.
				for i, command in ipairs(commands) do

					local flags1 = flags_string()
					print(flags1, command)

					local fs = nw:os'OSX' and (win:fullscreen() or command == 'enter_fullscreen')
					if command == 'enter_fullscreen' then
						win:fullscreen(true)
					elseif command == 'exit_fullscreen' then
						win:fullscreen(false)
					else
						win[command](win)
					end
					if fs then
						sleep(1.5)
					end

					--check that at least one changed() event was fired if the flags changed.
					local flags2 = flags_string()
					if flags2 ~= flags1 then
						assert(changed > 0, 'no changed() event for '..flags1..'->'..flags2)
						if changed > 1 then
							print('! duplicate changed() event ('..changed..' times) for '..flags1..'->'..flags2)
						end
					end
					changed = 0

				end

				--check current state flags against a flag combination string.
				local actual_flags = flags_string()
				if actual_flags ~= expected_flags then
					error(actual_flags .. ', expected ' .. expected_flags)
				end
			end

			run_commands(commands1, check1)
			run_commands(commands2, check2)

			local was_fs = win:fullscreen() and nw:os'OSX'

			win:close()

			if was_fs then sleep(1.5) end

			assert(win:dead())
			--collectgarbage()

		end))
	end

	make_test{}
	make_test{frame = 'none'}
end

--state/enabled --------------------------------------------------------------

--interactive test showing modal operation based on `enabled` and `parent` properties.
add('enabled', function()
	local win1 = app:window(winpos{x = 100, y = 100, w = 500, h = 300, enabled = false})
	local win2 = app:window(winpos{x = 200, y = 150, w = 300, h = 200, parent = win1,
		minimizable = false, maximizable = false, resizeable = false})
	function win2:closing()
		win1:enabled(true)
	end
	function win1:event(...)
		print(...)
	end
	app:run()
end)

--positioning ----------------------------------------------------------------

--test that initial coordinates and size are set correctly.
--test that frame_rect() works in normal state.
--test that size() works and gives sane values.
add('pos-init', function()
	local x0, y0, w0, h0 = 51, 52, 201, 202
	local win = app:window{x = x0, y = y0, w = w0, h = h0}
	local x, y, w, h = win:frame_rect()
	assert(x == x0)
	assert(y == y0)
	assert(w == w0)
	assert(h == h0)
	local w, h = win:size()
	assert(w >= w0 - 50 and w <= w0)
	assert(h >= h0 - 50 and h <= h0)
	print'ok'
end)

--test if x,y,w,h mixed with cx,cy,cw,ch works.
--this is an eye-test for framed windows.
add('pos-init-mixed', function()
	app:window{cx = 200, cy = 200, cw = 200, ch = 200}
	app:window{x = 200, cy = 200, w = 200, ch = 200}
	app:window{cx = 200, y = 200, cw = 200, h = 200}
	app:window{x = 200, y = 200, w = 200, h = 200}
	app:run()
end)

--check that frame_rect() and initial client rect values match for frameless windows.
add('pos-init-client-noframe', function()
	local win = app:window{cx = 100, cy = 100, cw = 500, ch = 500, frame = 'none'}
	local x, y, w, h = win:frame_rect()
	assert(x == 100)
	assert(y == 100)
	assert(w == 500)
	assert(h == 500)
	print'ok'
end)

--check that the default window position is cascaded.
add('pos-init-cascade', function()
	for i = 1,30 do
		app:window{w = 500, h = 300}
	end
	app:run()
end)

--create a window off-screen. move a window off-screen.
--NOTE: Windows can create windows off-screen but can't move them off-screen.
--NOTE: OSX can create and move windows off-screen when hidden, but
--it repositions them on the next show().
--NOTE: X moves windows on-screen automatically.
--NOTE: OSX can always create/move frameless windows off-screen.
--These differences were not leveled out between platforms.
add('pos-out', function()

	local win = app:window(winpos{x = -5000, y = -5000})
	print(win:frame_rect())
	win:close()

	local win = app:window(winpos{visible = true})
	win:frame_rect(-5000, -5000)
	print(win:frame_rect())
	win:close()

	local win = app:window(winpos{visible = false})
	win:frame_rect(-5000, -5000)
	print(win:frame_rect())
	print(win:frame_rect())
	win:close()

	--frame = 'none' and initial off-screen position is the only way to
	--get cross-platform off-screen windows so that we can show that display()
	--is nil for them.
	local win = app:window(winpos{x = -5000, y = -5000, frame = 'none'})
	local x, y = win:frame_rect()
	assert(x == -5000)
	assert(y == -5000)
	print(win:frame_rect())
	win:close()

	local win = app:window(winpos{frame = 'none'})
	win:frame_rect(-5000, -5000)
	print(win:frame_rect())
	win:close()
end)

--resize the windows to see the constraints in effect.
add('pos-minmax', function()

	--check that initial constraints are set and the window size respects them.
	local win = app:window{w = 800, h = 800, min_cw = 200, min_ch = 200, max_cw = 400, max_ch = 400}

	local minw, minh = win:minsize()
	assert(minw == 200)
	assert(minh == 200)

	local maxw, maxh = win:maxsize()
	assert(maxw == 400)
	assert(maxh == 400)

	local w, h = win:size()
	assert(w == 400)
	assert(h == 400)

	win:close()

	--check that minsize() is set and that it resizes the window.
	local win = app:window{w = 100, h = 100}

	local rec = recorder()
	function win:resizing() rec'error' end
	function win:resized() rec'resized' end

	win:minsize(200, 200)

	rec{'resized'}

	local minw, minh = win:minsize()
	assert(minw == 200)
	assert(minh == 200)

	local w, h = win:size()
	assert(w == 200)
	assert(h == 200)

	win:close()

	--check that maxsize() is set and that it resizes the window.
	local win = app:window{w = 800, h = 800}

	local rec = recorder()
	function win:resizing() rec'error' end
	function win:resized() rec'resized' end

	win:maxsize(400, 400)

	rec{'resized'}

	local maxw, maxh = win:maxsize()
	assert(maxw == 400)
	assert(maxh == 400)

	local w, h = win:size()
	assert(w == 400)
	assert(h == 400)

	win:close()

	--check that initial partial constraints work too.
	local win = app:window{w = 800, h = 100, max_cw = 400, min_ch = 200}

	local minw, minh = win:minsize()
	assert(minw == nil)
	assert(minh == 200)

	local maxw, maxh = win:maxsize()
	assert(maxw == 400)
	assert(maxh == nil)

	local w, h = win:size()
	assert(w == 400)
	assert(h == 200)

	win:close()

	--check that runtime partial constraints work too.
	local win = app:window{w = 100, h = 800}

	win:minsize(200, nil)
	local minw, minh = win:minsize()
	assert(minw == 200)
	assert(minh == nil)

	win:maxsize(nil, 400)
	local maxw, maxh = win:maxsize()
	assert(maxw == nil)
	assert(maxh == 400)

	local w, h = win:size()
	assert(w == 200)
	assert(h == 400)

	win:close()

	--frame_rect() is constrained too.
	local win = app:window{w = 100, h = 100, min_cw = 200, max_cw = 500, min_ch = 200, max_ch = 500}

	win:frame_rect(nil, nil, 100, 100)
	local w, h = win:size()
	assert(w == 200)
	assert(h == 200)

	win:frame_rect(nil, nil, 600, 600)
	local w, h = win:size()
	assert(w == 500)
	assert(h == 500)

	win:close()

	--maximized state is constrained too (runtime).
	local win = app:window{w = 100, h = 100, min_cw = 200, min_ch = 200, max_cw = 500, max_ch = 500}
	win:maximize()

	local maxw, maxh = win:size()
	assert(maxw == 500)
	assert(maxh == 500)

	--maximized() responds true even when constrained.
	assert(win:maximized())

	win:close()

	--maximized state is constrained too (init).
	local win = app:window{w = 100, h = 100, min_cw = 200, min_ch = 200,
		max_cw = 500, max_ch = 500, maximized = true}

	local maxw, maxh = win:size()
	assert(maxw == 500)
	assert(maxh == 500)

	--maximized() responds true even when constrained.
	assert(win:maximized())

	win:close()

	--setting maxsize while maximized works: the window is resized.
	--TODO: the position is preserved.
	local win = app:window{x = 100, y = 100, w = 500, h = 500, maximized = true}
	print(win:frame_rect())
	win:maxsize(200, 200)
	print(win:frame_rect())

	local maxw, maxh = win:size()
	assert(maxw == 200)
	assert(maxh == 200)

	local w, h = win:size()
	assert(w == 200)
	assert(h == 200)

	app:run()

	--TODO: setting minsize/maxize inside resizing() event works.

	--TODO: minsize is itself constrained to previously set maxsize and viceversa.

end)

--setting maxsize > screen size constrains the window to screen size,
--but the window can be resized to larger than screen size manually.
add('pos-minmax-large-max', function()
	local win = app:window{x = 100, y = 100, w = 10000, h = 10000, max_cw = 10000, max_ch = 10000}
	app:run()
end)

--setting minsize > screen size works.
--it's buggy/slow on both Windows and OSX for very large sizes.
add('pos-minmax-large-min', function()
	local win = app:window{x = 100, y = 100, w = 10000, h = 10000, min_cw = 10000, min_ch = 10000}
	app:run()
end)

--constraints apply to fullscreen mode too
add('pos-minmax-fullscreen', function()
	local win = app:window(winpos{max_cw = 500, max_ch = 500})
	win:fullscreen(true)
	app:run()
end)

--normal_rect() -> x, y, w, h works.
--normal_rect(x, y, w, h) works.
add('pos-normal-rect', function()
	local x0, y0, w0, h0 = 51, 52, 201, 202
	local win = app:window{x = 0, y = 0, w = 0, h = 0}
	local function check()
		local x, y, w, h = win:normal_rect()
		assert(x == x0)
		assert(y == y0)
		assert(w == w0)
		assert(h == h0)
	end
	win:normal_rect(x0, y0, w0, h0); check()
	x0 = x0 + 10; win:normal_rect(x0); check()
	y0 = y0 + 10; win:normal_rect(nil, y0); check()
	w0 = w0 + 10; win:normal_rect(nil, nil, w0); check()
	h0 = h0 + 10; win:normal_rect(nil, nil, nil, h0); check()
	print'ok'
end)

--setting frame_rect() when minimized and maximized works.
add('pos-set-frame-rect', function()
	local win1 = app:window(winpos{minimized = true, maximized = true})
	local win2 = app:window(winpos{minimized = false, maximized = true})
	win1:frame_rect(800, 600, 500, 300)
	win2:frame_rect(600, 200, 500, 300)
	app:run()
end)

--check frame_rect() and size() values in minimized state.
add('pos-frame-rect-minimized', function()
	local function test(visible, minimized, maximized)
		local win = app:window{x = 100, y = 100, w = 500, h = 300,
			maximized = maximized, minimized = minimized, visible = visible}
		print((visible and 'v' or '')..(minimized and 'm' or '')..(maximized and 'M' or ''))
		assert(not win:frame_rect())
		local w, h = win:size()
		assert(w == 0)
		assert(h == 0)
	end
	test(true, true, true)
	test(true, true, false)
	test(false, true, false)
	test(false, true, true)
	print'ok'
end)

--setting client_rect() works (matches initial client coordinates).
add('pos-client-rect', function()
	local function test(init_flags)
		local win1 = app:window(glue.update({cx = 100, cy = 100, cw = 500, ch = 500}, init_flags))
		local win2 = app:window(winpos(glue.update({}, init_flags)))
		win2:client_rect(100, 100, 500, 500)
		local x1, y1, w1, h1 = win1:frame_rect()
		local x2, y2, w2, h2 = win2:frame_rect()
		print('win1', x1, y1, w1, h1)
		print('win2', x2, y2, w2, h2)
		assert(x1 == x2)
		assert(y1 == y2)
		assert(w1 == w2)
		assert(h1 == h2)
	end
	test{}
	test{frame = 'none'}
	test{frame = 'none-transparent'}
	print'ok'
end)

--normal_rect(x, y, w, h) generates only one ('resized', 'set') event.
add('pos-set-event', function()
	local rec = recorder()
	local win = app:window{x = 0, y = 0, w = 0, h = 0}
	function win:start_resize(how) rec('start_resize', how) end
	function win:end_resize() rec('end_resize') end
	function win:resizing(how, x, y, w, h) rec('resizing', how, x, y, w, h) end
	function win:resized(how) rec('resized', how) end
	win:normal_rect(1, 0, 0, 0)
	rec{'resized', 'set'}
end)

--interactive test showing resizing events.
add('pos-events', function()
	local win = app:window(winpos())
	function win:mousemove(x, y)
		--print('mousemove', x, y)
	end
	function win:start_resize(how) print('start_resize', how) end
	function win:end_resize() print('end_resize') end
	function win:resizing(how, x, y, w, h)
		print('resizing', how, x, y, w, h)
	end
	function win:resized()
		print('resized')
	end
	app:run()
end)

--to_screen() and to_client() conversions work.
add('pos-conversions', function()
	local win = app:window{x = 100, y = 100, w = 100, h = 100, visible = false}
	local x, y, w, h = win:to_screen(100, 100, 100, 100)
	print(x, y, w, h)
	assert(x >= 200 and x <= 250)
	assert(y >= 200 and y <= 250)
	assert(w == 100)
	assert(h == 100)
	local x, y, w, h = win:to_client(x, y, w, h)
	assert(x == 100)
	assert(y == 100)
	assert(w == 100)
	assert(h == 100)
	print'ok'
end)

add('pos-client-to-frame', function()
	local cx, cy, cw, ch = 100, 200, 300, 400

	local x, y, w, h = app:client_to_frame('normal', cx, cy, cw, ch)
	assert(x <= cx)
	assert(y <= cy)
	assert(w >= cw)
	assert(h >= ch)

	local x, y, w, h = app:client_to_frame('none', cx, cy, cw, ch)
	assert(x == cx)
	assert(y == cy)
	assert(w == cw)
	assert(h == ch)

	--the minimum frame rect for a zero-sized client rect is not entirely correct.
	--in practice there's a minimum width on the titlebar but we don't get that.
	local x, y, w, h = app:client_to_frame('normal', 0, 0, 0, 0)
	print('min. frame rect:   ', x, y, w, h)

	--if no frame, frame rect and client rect match, even at zero size.
	local x, y, w, h = app:client_to_frame('none', 0, 0, 0, 0)
	assert(x == 0)
	assert(y == 0)
	assert(w == 0)
	assert(h == 0)

	print'ok'
end)

add('pos-frame-to-client', function()
	local x, y, w, h = 100, 200, 300, 400

	local cx, cy, cw, ch = app:frame_to_client('normal', x, y, w, h)
	assert(x <= cx)
	assert(y <= cy)
	assert(w >= cw)
	assert(h >= ch)

	local cx, cy, cw, ch = app:frame_to_client('none', x, y, w, h)
	assert(x == cx)
	assert(y == cy)
	assert(w == cw)
	assert(h == ch)

	--the minimum client rect for a zero-sized frame rect is zero-sized (not negative).
	local cx, cy, cw, ch = app:frame_to_client('normal', 0, 0, 0, 0)
	assert(cw == 0)
	assert(ch == 0)

	--if no frame, frame rect and client rect match, even at zero size.
	local cx, cy, cw, ch = app:frame_to_client('none', 0, 0, 0, 0)
	assert(cx == 0)
	assert(cy == 0)
	assert(cw == 0)
	assert(ch == 0)

	print'ok'
end)

--edge snapping. interactive test: move and resize windows around.
add('pos-snap', function()
	app:window(winpos{w = 300, title = 'no snap', edgesnapping = false})
	app:window(winpos{w = 300, title = 'snap to: default'})
	app:window(winpos{w = 300, title = 'snap to: screen', edgesnapping = 'screen'})
	app:window(winpos{w = 300, title = 'snap to: app', edgesnapping = 'app'})
	app:window(winpos{w = 300, title = 'snap to: other', edgesnapping = 'other'}) --NYI
	app:window(winpos{w = 300, title = 'snap to: app screen', edgesnapping = 'app screen'})
	local win = app:window(winpos{w = 300, title = 'snap to: all', edgesnapping = 'all'})
	local child1 = app:window(winpos{w = 300, title = 'child1 snap to: parent', edgesnapping = 'parent', parent = win})
	local child2 = app:window(winpos{w = 300, title = 'child2 snap to: siblings', edgesnapping = 'siblings', parent = win})
	app:run()
end)

--children are sticky: they follow parent on move (but not on resize, maximize, etc).
--interactive test: move the parent to see child moving too.
add('pos-children', function()
	local win1 = app:window{x = 100, y = 100, w = 500, h = 200}
	local win2 = app:window{x = 200, y = 130, w = 200, h = 300, parent = win1}
	app:run()
end)

--title ----------------------------------------------------------------------

add('title', function()
	local win = app:window(winpos{title = 'with title'})
	assert(win:title() == 'with title')
	win:title'changed'
	assert(win:title() == 'changed')
	win:close()
end)

--z-order --------------------------------------------------------------------

--interactive test showing topmost.
add('topmost', function()
	local win = app:window(winpos{title = 'top1', x = 100, y = 100, topmost = true, autoquit = true})
	assert(win:topmost())
	win:topmost(false)
	assert(not win:topmost())
	win:topmost(true)
	assert(win:topmost())

	local win2 = app:window(winpos{title = 'top2', x = 120, y = 140, autoquit = true})
	win2:topmost(true)
	assert(win:topmost())

	local win3 = app:window(winpos{title = 'normal1', x = 40, y = 160, autoquit = true})
	local win4 = app:window(winpos{title = 'normal2', x = 160, y = 200, topmost = true, autoquit = true})
	win4:topmost(false)

	app:run()
end)

add('zorder', function()
	local ix, iy = x, y
	for i = 1,5 do
		app:window(cascadepos{title = 'window'..i})
	end
	x, y = ix + 500, iy
	for i = 1,5 do
		app:window(cascadepos{title = 'window'..i..'-top', topmost = true})
	end
	function app:activated()
		app:runafter(0.5, function()
			app:windows()[3]:zorder'front'; assert(not app:windows()[3]:topmost())
			app:windows()[5]:zorder'back' ; assert(not app:windows()[5]:topmost())
			app:windows()[8]:zorder'front'; assert(app:windows()[8]:topmost())
			app:windows()[10]:zorder'back'; assert(app:windows()[10]:topmost())
		end)
	end
	app:run()
end)

--displays -------------------------------------------------------------------

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

--there's at least one display and its values are sane.
--first display is the main display with (x, y) at (0, 0).
add('display-list', function()
	local n = 0
	for i,display in ipairs(app:displays()) do
		n = n + 1
		print(string.format('# display %d', i))
		test_display(display)
		if i == 1 then
			--main screen is first, and at (0, 0)
			local x, y = display:rect()
			assert(x == 0)
			assert(y == 0)
		end
	end
	assert(n > 0) --there must be at least 1 display
	assert(n == app:display_count())
end)

--active display returns a valid display.
add('display-active', function()
	local display = app:active_display()
	test_display(display)
end)

--display is available on a hidden (but with on-screen coordinates) window.
add('display-hidden', function()

	local win = app:window(winpos{visible = false})
	assert(win:display())
	win:close()

	local win = app:window(winpos{})
	win:hide()
	assert(win:display())
	win:close()

	print'ok'
end)

--display is nil on an off-screen window.
add('display-out', function()
	local win = app:window(winpos{x = -5000, y = -5000, frame = 'none'})
	local x, y = win:frame_rect()
	assert(x == -5000)
	assert(y == -5000)
	assert(not win:display())
	win:close()
	print'ok'
end)

--cursors --------------------------------------------------------------------

local cursors = {'arrow', 'ibeam', 'hand', 'cross', 'no', 'nwse', 'nesw', 'ew', 'ns', 'move', 'busy'}

add('cursors', function()
	local win = app:window(winpos{resizeable = true})
	function win:mousemove(x, y)
		local cursor = cursors[math.min(math.max(math.floor(x / 10), 1), #cursors)]
		win:cursor(cursor)
	end
	app:run()
end)

--frame flags ----------------------------------------------------------------

--closeable

add('closeable', function()
	local win = app:window(winpos{title = 'cannot close', closeable = false})
	assert(not win:closeable())
end)

--resizeable

add('resizeable', function()
	local win = app:window(winpos{title = 'fixed size', resizeable = false})
	assert(not win:resizeable())
end)

--frame types

add('frameless', function()
	local win = app:window(winpos{frame = 'none'})
	assert(win:frame() == 'none')
end)

add('transparent', function()
	local win = app:window(winpos{frame = 'none-transparent'})
	assert(win:frame() == 'none-transparent')
end)

--parent/child relationship --------------------------------------------------

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

--input events ---------------------------------------------------------------

--double click time is sane
add('input-click-time', function()
	local t = app.backend:double_click_time()
	print('double_click_time', t)
	assert(t > 0 and t < 5000)
end)

--target area is sane
add('input-click-area', function()
	local w, h = app.backend:double_click_target_area()
	print('double_click_target_area', w, h)
	assert(w > 0 and w < 100)
	assert(h > 0 and h < 100)
end)

--mousemove() event works inside the client area of the active window.
--mousemove() event continues outside the client area while at least one
--mouse button is held.
add('input-mousemove', function()
	local win1 = app:window{x = 100, y = 100, w = 300, h = 200}
	local win2 = app:window{x = 150, y = 150, w = 300, h = 200}
	function win1:mousemove(x, y)
		print('win1 mousemove', x, y)
	end
	function win2:mousemove(x, y)
		print('win2 mousemove', x, y)
	end
	app:run()
end)

--mouseenter() and mouseleave() events work.
--mouseenter() and mouseleave() events are muted while buttons are pressed.
--the order of events between windows is undefined.
add('input-mouseenter', function()
	local win1 = app:window{x = 100, y = 100, w = 300, h = 200}
	local win2 = app:window{x = 150, y = 150, w = 300, h = 200}
	function win1:mouseenter() print('win1 mouseenter') end
	function win1:mouseleave() print('win1 mouseleave') end
	function win2:mouseenter() print('win2 mouseenter') end
	function win2:mouseleave() print('win2 mouseleave') end
	app:run()
end)

add('input', function()
	local win1 = app:window(winpos())
	local win2 = app:window(winpos())

	--mouse
	function win1:mouseenter() print'mouseenter win1' end
	function win2:mouseenter() print'mouseenter win2' end
	function win1:mouseleave() print'mouseleave win1' end
	function win2:mouseleave() print'mouseleave win2' end
	function win1:mousemove() print('mousemove win1', self:mouse'x', self:mouse'y') end
	function win2:mousemove() print('mousemove win2', self:mouse'x', self:mouse'y') end
	function win1:mousedown(button) print('mousedown win1', button) end
	function win2:mousedown(button) print('mousedown win2', button) end
	function win1:mouseup(button) print('mouseup win1', button) end
	function win2:mouseup(button) print('mouseup win2', button) end
	function win1:click(button, click_count)
		print('click win1', button, click_count)
		if click_count == 2 then return true end
	end
	function win2:click(button, click_count)
		print('click win2', button, click_count)
		if click_count == 3 then return true end
	end
	function win1:mousewheel(delta) print('wheel win1', delta) end
	function win2:mousewheel(delta) print('wheel win2', delta) end

	--keyboard
	function win1:printkey(title, key, vkey)
		print(string.format('%-20s %-20s %-20s %-20s %-20s', title, key, vkey, self:key(key), self:key(vkey)))
	end
	win2.printkey = win1.printkey
	function win1:keydown(key, ...)
		if key == 'N' then
			app:ignore_numlock(not app:ignore_numlock())
		end
		self:printkey('keydown', key, ...)
		--print(self:key('ctrl+shift+F10'))
	end
	function win1:keypress(...)
		self:printkey('keypress', ...)
	end
	function win1:keyup(...)
		self:printkey('keyup', ...)
	end
	function win1:keychar(char)
		--print('keychar ', char)
	end
	win2.keydown = win1.keydown
	win2.keypress = win1.keypress
	win2.keyup = win1.keyup
	win2.keychar = win1.keychar

	--win2:close()

	app:run()
end)

--bitmap helpers -------------------------------------------------------------

--premultiply alpha for (r, g, b, a) in 0..1 range
local function premul(r, g, b, a)
	return r * a, g * a, b * a, a
end

--premultiplied (r, g, b, a) -> bgra8
local function bgra8(r, g, b, a)
	a = bit.band(a * 255, 255)
	r = bit.band(r * 255, 255)
	g = bit.band(g * 255, 255)
	b = bit.band(b * 255, 255)
	return bit.bor(bit.lshift(a, 24), bit.lshift(r, 16), bit.lshift(g, 8), b)
end

--fill a bitmap with a constant color.
local function bmp_pixel(bmp, r, g, b, a)
	local data = ffi.cast('int32_t*', bmp.data)
	local c = bgra8(premul(r, g, b, a))
	for y=0,bmp.h-1 do
		for x=0,bmp.w-1 do
			data[y * bmp.w + x] = c
		end
	end
end

--fill a bitmap with a constant color.
local function fill_bmp(bmp, r, g, b, a)
	local data = ffi.cast('int32_t*', bmp.data)
	local c = bgra8(premul(r, g, b, a))
	for y=0,bmp.h-1 do
		for x=0,bmp.w-1 do
			data[y * bmp.w + x] = c
		end
	end
end

local function lerp(v0, v1, t)
	return v0 + t*(v1-v0)
end

--fill a bitmap with a gradient color.
local function gradient_bmp(bmp, r1, g1, b1, a1, r2, g2, b2, a2)
	local data = ffi.cast('int32_t*', bmp.data)
	for y=0,bmp.h-1 do
		local t = y/(bmp.h-1)
		local r = lerp(r1, r2, t)
		local g = lerp(g1, g2, t)
		local b = lerp(b1, b2, t)
		local a = lerp(a1, a2, t)
		for x=0,bmp.w-1 do
			data[y * bmp.w + x] = bgra8(premul(r, g, b, a))
		end
	end
end

local i = 1
local function animate_bmp(bmp)
	i = (i + 1/30) % 1
	gradient_bmp(bmp, 1, 0, 0, i, 0, 0, 1, i)
end

local function checkerboard_bmp(bmp)
	local d = 32
	local h = d/2
	local _, setpixel = bitmap.pixel_interface(bmp)
	for y=0,bmp.h-1 do
		for x=0,bmp.w-1 do
			local dx = bit.band(x, d)
			local dy = bit.band(y, d)
			local r = ((dx > h and dy < h) or (dx < h and dy > h)) and 220 or 192
			setpixel(x, y, r, r, r, 255)
		end
	end
end

--window bitmap --------------------------------------------------------------

add('bitmap', function()
	local win = app:window{w = 500, h = 300, frame = 'none-transparent'}

	function win:event(...)
		print(...)
	end

	function win:repaint()
		local cairo = require'cairo'
		local bmp = win:bitmap()
		if not bmp then return end
		if not bmp.cr then
			bmp.surface = cairo.cairo_image_surface_create_for_data(bmp.data,
									cairo.CAIRO_FORMAT_ARGB32, bmp.w, bmp.h, bmp.stride)
			bmp.cr = bmp.surface:create_context()
			function bmp:free()
				self.cr:free()
				self.surface:free()
			end
		end
		local cr = bmp.cr

		--background
		cr:set_operator(cairo.CAIRO_OPERATOR_SOURCE)
		cr:set_source_rgba(0, 0, 0.1, 0.5)
		cr:paint()
		cr:set_operator(cairo.CAIRO_OPERATOR_OVER)

		--matrix
		cr:identity_matrix()
		cr:translate(.5, .5)

		--border
		cr:set_source_rgba(1, 0, 0, 1)
		cr:set_line_width(1)
		cr:rectangle(0, 0, bmp.w-1, bmp.h-1)
		cr:stroke()
	end

	local action, dx, dy

	function win:keypress(key)

		if key == 'space' then
			win:maximize()
		elseif key == 'esc' then
			win:restore()
		elseif key == 'F' then
			win:fullscreen(not win:fullscreen())
		elseif win:key'command f4' or win:key'command w' then
			win:close()
		end
	end

	app:runevery(1/60, function()

		local self = win
		local d = 10

		if self:key'left' then
			local x, y = win:normal_rect()
			win:normal_rect(x - d, y)
		end
		if self:key'right' then
			local x, y = win:normal_rect()
			win:normal_rect(x + d, y)
		end
		if self:key'up' then
			local x, y = win:normal_rect()
			win:normal_rect(x, y - d)
		end
		if self:key'down' then
			local x, y = win:normal_rect()
			win:normal_rect(x, y + d)
		end
	end)

	function win:mousedown(button, x, y)
		if self:fullscreen() then return end
		if button == 'left' then
			local _, _, w, h = win:normal_rect()
			if x >= w - 20 and x <= w and y >= h - 20 and y <= h then
				action = 'resize'
				dx = w - x
				dy = h - y
			else
				action = 'move'
				dx, dy = x, y
			end
		end
	end

	function win:mouseup(button)
		if button == 'left' and action then
			action = nil
		end
	end

	function win:mousemove(x, y)
		if action == 'move' then
			local fx, fy = win:normal_rect()
			win:normal_rect(fx + x - dx, fy + y - dy)
		elseif action == 'resize' then
			win:normal_rect(nil, nil, x + dx, y + dy)
		end
	end

	win:invalidate()
	app:run()
end)

--views ----------------------------------------------------------------------

local cairo = require'cairo'
local gl

if ffi.os == 'Windows' then
	gl = require'winapi.gl11'
elseif ffi.os == 'OSX' then
	gl = require'objc'
	gl.load'OpenGL'
end

local r = 30
local function cube(w)
	r = r + 1
	gl.glPushMatrix()
	gl.glTranslated(0,0,-4)
	gl.glScaled(w, w, 1)
	gl.glRotated(r,1,r,r)
	gl.glTranslated(0,0,2)
	local function face(c)
		gl.glBegin(gl.GL_QUADS)
		gl.glColor4d(c,0,0,.5)
		gl.glVertex3d(-1, -1, -1)
		gl.glColor4d(0,c,0,.5)
		gl.glVertex3d(1, -1, -1)
		gl.glColor4d(0,0,c,.5)
		gl.glVertex3d(1, 1, -1)
		gl.glColor4d(c,0,c,.5)
		gl.glVertex3d(-1, 1, -1)
		gl.glEnd()
	end
	gl.glTranslated(0,0,-2)
	face(1)
	gl.glTranslated(0,0,2)
	face(1)
	gl.glTranslated(0,0,-2)
	gl.glRotated(-90,0,1,0)
	face(1)
	gl.glTranslated(0,0,2)
	face(1)
	gl.glRotated(-90,1,0,0)
	gl.glTranslated(0,2,0)
	face(1)
	gl.glTranslated(0,0,2)
	face(1)
	gl.glPopMatrix()
end

add('view-cairo', function()
	local win = app:window{w = 500, h = 300}--, frame = 'none-transparent'}
	local fps = 60

	local x, y = 150, 10
	local w, h = 100, 250
	local cx, cy = w / 2, h / 2
	local step = 0.02 * 60 / fps
	local alpha, angle = 0, 0

	local view = win:cairoview{x = x, y = y, w = w, h = h}
	function view:render(cr)

		cr:identity_matrix()

		alpha = alpha + step; if alpha <= 0 or alpha >= 1 then step = -step end
		angle = angle + math.abs(step)
		cr:rectangle(0, 0, w, h)
		cr:set_source_rgba(0, 0, 1, 1)
		cr:stroke()
		cr:translate(cx, cy)
		cr:rotate(angle)
		cr:translate(-cx, -cy)
		cr:set_source_rgba(1, 0, 0, alpha)
		cr:rectangle(cx - 50, cy - 50, 100, 100)
		cr:fill()
	end

	local x, y = 150, 170
	local w, h = 300, 80

	local glview = win:glview{x = x, y = y, w = w, h = h}
	function glview:render()

		--set default viewport
		gl.glViewport(0, 0, w, h)
		gl.glMatrixMode(gl.GL_PROJECTION)
		gl.glLoadIdentity()
		gl.glFrustum(-1, 1, -1, 1, 1, 100) --so fov is 90 deg
		gl.glScaled(1, w/h, 1)

		gl.glClearColor(0, 0, 0, 1)
		gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
		gl.glEnable(gl.GL_BLEND)
		gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_SRC_ALPHA)
		gl.glDisable(gl.GL_DEPTH_TEST)
		gl.glDisable(gl.GL_CULL_FACE)
		gl.glDisable(gl.GL_LIGHTING)
		gl.glMatrixMode(gl.GL_MODELVIEW)
		gl.glLoadIdentity()
		gl.glTranslated(0,0,-1)
		cube(1)
	end

	local x, y = 230, 20
	local w, h = 80, 230
	local cx, cy = w / 2, h / 2
	local step = 0.02 * 60 / fps
	local alpha, angle = 0, 0

	local view2 = win:cairoview{x = x, y = y, w = w, h = h}
	function view2:render(cr)
		cr:identity_matrix()

		alpha = alpha + step; if alpha <= 0 or alpha >= 1 then step = -step end
		angle = angle - math.abs(step)
		cr:rectangle(0, 0, w, h)
		cr:set_source_rgba(0, 0, 1, 1)
		cr:stroke()
		cr:translate(cx, cy)
		cr:rotate(angle)
		cr:translate(-cx, -cy)
		cr:set_source_rgba(0, r, 0, alpha)
		cr:rectangle(cx - 50, cy - 50, 100, 100)
		cr:fill()
	end

	local win2 = app:window{x = 500, y = 400, w = 500, h = 300}

	local x, y = 100, 170
	local w, h = 300, 80

	local glview2 = win2:glview{x = x, y = y, w = w, h = h}
	function glview2:render()

		--set default viewport
		gl.glViewport(0, 0, w, h)
		gl.glMatrixMode(gl.GL_PROJECTION)
		gl.glLoadIdentity()
		gl.glFrustum(-1, 1, -1, 1, 1, 100) --so fov is 90 deg
		gl.glScaled(1, w/h, 1)

		gl.glClearColor(0, 0, 0, 1)
		gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
		gl.glEnable(gl.GL_BLEND)
		gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_SRC_ALPHA)
		gl.glDisable(gl.GL_DEPTH_TEST)
		gl.glDisable(gl.GL_CULL_FACE)
		gl.glDisable(gl.GL_LIGHTING)
		gl.glMatrixMode(gl.GL_MODELVIEW)
		gl.glLoadIdentity()
		gl.glTranslated(0,0,-1)
		cube(1)
	end

	app:runevery(1/fps, function()
		if not win:dead() then
			view:invalidate()
			view2:invalidate()
			glview:invalidate()
			--win:invalidate()
		end
		if not win2:dead() then
			glview2:invalidate()
		end
	end)
	app:run()
end)

--menus ----------------------------------------------------------------------

add('menu', function()

	local function setmenu()
		local win = app:window(winpos{w = 500, h = 300})
		local winmenu = nw:os'Windows' and win:menubar() or app:menubar()
		local menu1 = app:menu()
		menu1:add('Option1\tCtrl+G', function() print'Option1' end)
		menu1:add('Option2', function() print'Option2' end)
		menu1:set(2, 'Option2-changed', function() print'Option2-changed' end, {checked = true})
		menu1:add(2, 'Dead Option')
		menu1:remove(2)
		menu1:add(2, '') --separator
		menu1:checked(1, true)
		assert(menu1:checked(3))
		menu1:checked(3, false)
		assert(not menu1:checked(3))
		--assert(menu1:enabled(3))
		menu1:enabled(3, false)
		assert(not menu1:enabled(3))
		winmenu:add('Menu1', menu1)
		winmenu:add'---' --separator: not for menu bar items
		local menu2 = app:menu()
		winmenu:add('Menu2', menu2)
		local menu3 = app:menu()
		menu2:add('Menu3', menu3)
		local menu4 = app:menu()
		menu3:add('Menu4', menu4)
		menu4:add('Option41', function() print'Option41' end)
		menu4:add('Option42', function() print'Option42' end)
		local pmenu = app:menu()
		pmenu:add'Option1'
		pmenu:add'Option2'
		function win:mouseup(button, x, y)
			if button == 'right' then
				win:popup(pmenu, x, y)
			end
		end

		assert(winmenu:item_count() == 3)
		assert(winmenu:get(1).action == menu1)
		assert(winmenu:get(3, 'action') == menu2)
		assert(#winmenu:items() == 3)
		assert(winmenu:items()[3].action == menu2)
	end

	app:runafter(1, function()
		setmenu()
	end)

	app:run()
end)

--notification icons ---------------------------------------------------------

add('notify', function()
	local icon = app:notifyicon{text = 'hello', length = 80}

	local menu = app:menu()
	menu:add'Option1'
	menu:add'Option2'

	icon:tooltip'Hey imma tooltip'
	icon:menu(menu)

	print(icon:rect())

	--make one icon that increases alpha from 0% to 100% once per second.
	--do it inside repaint().

	local i = 1
	function icon:repaint()
		i = (i + 1/30) % 1
		local bmp = icon:bitmap()
		fill_bmp(bmp, 1, 0, 0, i)
	end

	app:runevery(1/30, function()
		icon:invalidate()
	end)

	--make a second icon that's yellow.
	--do it outside repaint().

	local icon2 = app:notifyicon()
	local bmp = icon2:bitmap()
	fill_bmp(bmp, 1, 1, 0, 1)
	icon2:invalidate()

	app:runafter(3, function()
		app:quit()
	end)

	app:run()
end)

--window icon (windows only) -------------------------------------------------

add('window-icon', function()
	local win = app:window(winpos{w = 500, h = 300, visible = false})

	--make the alt-tab icon yellow. do it in repaint().
	local bigicon = win:icon'big'
	function bigicon:repaint()
		local bmp = self:bitmap()
		fill_bmp(bmp, 1, 1, 0, 1)
	end
	bigicon:invalidate()

	--make the taskbar icon red. do it outside repaint().
	--note: if the small icon is not set explicitly, the normal icon will be
	--scaled down and used instead.
	local smallicon = win:icon'small'
	local bmp = smallicon:bitmap()
	fill_bmp(bmp, 1, 0, 0, 1)
	smallicon:invalidate()

	win:show()

	app:run()
end)

--dock icon (osx only) -------------------------------------------------------

add('dock-icon', function()
	local rec = recorder()
	local icon = app:dockicon()

	function icon:repaint()
		animate_bmp(icon:bitmap())
	end

	function icon:free_bitmap(bitmap)
		print(bitmap.w, bitmap.h)
		rec'free_bitmap'
	end

	app:runevery(1/30, function()
		icon:invalidate()
	end)

	app:runafter(5, function()
		app:quit()
	end)

	app:run()
	rec{'free_bitmap'}
end)

--file dialogs ---------------------------------------------------------------

add('dialog-open-default', function()
	print(app:opendialog())
end)

add('dialog-open-custom', function()
	--custom title, custom file types, default file type, multiselect.
	local paths = app:opendialog{
		title = 'What do you mean "open him up"?',
		filetypes = {'png', 'jpeg'}, --only if files = true
		multiselect = true,
	}
	pp(paths)
end)

add('dialog-save-default', function()
	print(app:savedialog())
end)

add('dialog-save-custom', function()
	--custom title, custom file types, default file type.
	local path = nw:os'OSX' and '/' or nw:os'Windows' and 'C:\\'
	local path = app:savedialog{
		title = 'Save time!',
		filetypes = {'png', 'jpeg'},
		filename = 'example',
		path = path,
	}
	print(path)
end)

--filetypes option can't be an empty list.
add('dialog-notypes', function()
	assert(not pcall(function() app:opendialog{filetypes = {}} end))
	assert(not pcall(function() app:savedialog{filetypes = {}} end))
end)

--clipboard ------------------------------------------------------------------

add('clipboard-text', function()
	local s = 'I am The Ocean'
	app:setclipboard(s)
	assert(#app:clipboard() == 1)
	assert(app:clipboard()[1] == 'text')
	assert(app:clipboard'text' == s)
	assert(not app:clipboard'files')
	print(app:clipboard'text')
end)

add('clipboard-files', function()
	local files =
		nw:os'OSX' and {'/home', '/na-file1', '/na-dir2/'} or
		nw:os'Windows' and {'C:\\Windows', 'Q:\\na-file1', 'O:\\na-dir2\\'}
	app:setclipboard(files, 'files')
	assert(#app:clipboard() == 1)
	assert(app:clipboard()[1] == 'files')
	assert(#app:clipboard('files') == #files)
	assert(app:clipboard('files')[1] == files[1])
	assert(app:clipboard('files')[2] == files[2])
	assert(not app:clipboard'text')
end)

add('clipboard-bitmap', function()
	local bmp = app:clipboard'bitmap'
	if bmp then
		app:setclipboard(bmp)
	end
end)

add('clipboard-inspect', function()

	for i,name in ipairs(app:clipboard()) do
		print(name)
		pp(app:clipboard(name))
	end

	local bmp = app:clipboard'bitmap'
	if bmp then
		local bitmap = require'bitmap'
		local margin = 50
		local win = app:window{cw = bmp.w + 2*margin, ch = bmp.h + 2*margin}
		local x, y = margin, margin
		function win:repaint()
			local wbmp = win:bitmap()
			checkerboard_bmp(wbmp)
			local x, y, w, h = box2d.clip(x, y, bmp.w, bmp.h, 0, 0, wbmp.w, wbmp.h)
			local src = bitmap.sub(bmp, 0, 0, w, h)
			local dst = bitmap.sub(wbmp, x, y, w, h)
			if src and dst then
				bitmap.blend(src, dst)
			end
		end
		win:invalidate()
		app:run()
	end

end)

--drag & drop ----------------------------------------------------------------

add('drop-files', function()
	local win = app:window(winpos())
	function win:dropfiles(x, y, files)
		pp(x, y, files)
	end
	app:run()
end)

add('dragging', function()
	local t = {'abort', 'none', 'copy', 'link'}
	local win = app:window(winpos{x = 100, y = 100, w = #t * 100, h = 100})
	function win:dragging(how, data, x, y)
		print(how, x, y)
		pp(data)
		if x then
			local ret = t[math.floor((x % (100 * #t)) / 100) + 1]
			print(ret)
			return ret
		end
		--return true
	end
	app:run()
end)

--xcb dev tests --------------------------------------------------------------

add('xcb', function()
	local win1 = app:window{w = 500, h = 300,
		title = 'Hello 1',}
	local win2 = app:window{x = -100, y = 100, w = 300, h = 400,
		title = 'Hello 2',}
	function win1:event(...) print('win1', ...) end
	function win2:event(...) print('win2', ...) end
	app:runevery(1, function() win1:activate() end)
	app:run()
end)


--run tests ------------------------------------------------------------------

local name = ...
--name = 'dragging'
if not name then
	print(string.format('Usage: %s name | prefix*', arg[0]))
	print'Available tests:'
	for i,name in ipairs(tests) do
		print('', name)
	end
elseif name:match'%*$' then
	run_all_matching('^'..glue.escape(name:gsub('%*', ''))..'.*')
elseif tests[name] then
	run_test(name)
else
	print'What test was that?'
end

