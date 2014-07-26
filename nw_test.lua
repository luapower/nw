io.stdout:setvbuf'no'
io.stderr:setvbuf'no'

local nw = require'nw'
local glue = require'glue'
local ffi = require'ffi'
local bit = require'bit'

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

--window activaton -----------------------------------------------------------

--1. the OS activates the app when the first window is created.
--2. the app activation event comes before the win activation event.
--3. the OS deactivates the app when the last window is closed (Windows).
--4. the app deactivation event comes after the win deactivation event.
--5. activation events deferred for when the app starts, and then,
--a single app:activated() event is fired, followed by a single
--win:activated() event from the last window that was activated.
--6. app:active() is true all the way, until after the last window is closed (Windows only).
--7. app:active_window() works (gives the expected window).
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
--when the window is shown, the app doesn't activate.
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
			app:runafter(2, function()
				app:quit()
			end)
		end)
	end)
	app:run()
	rec{}
end)

--window state flags  --------------------------------------------------------

add('fullscreen', function()
	local win = app:window{w = 500, h = 300, fullscreen = false}
	function win:keydown(key)
		if key == 'space' then
			win:fullscreen(not win:fullscreen())
		end
	end
	app:run()
end)

local flag_list = {
	'visible', 'minimized', 'maximized', 'fullscreen',
}

--generate a name for a test given a combination of flags.
local function test_name_for_flags(flags, name_prefix)
	local t = {}
	for i,flag in ipairs(flag_list) do
		if flags[flag] then t[#t+1] = flag end
	end
	return name_prefix .. '-' .. table.concat(t, '-')
end

--create a window with a certain combination of flags,
--and with key bindings for interactive state transitioning.
local function window_with_flags(flags)

	local win = app:window(winpos(glue.update({w = 500, h = 200}, flags)))

	function win:keydown(key)
		if key == 'F8' or key == 'S' then
			self:show()
		elseif key == 'F7' or key == 'H' then
			self:hide()
		elseif key == 'F10' or key == 'R' then
			self:restore()
		elseif key == 'F11' or key == 'F' then
			self:fullscreen(not self:fullscreen())
		elseif key == 'F12' or key == 'M' then
			self:maximize()
		elseif key == 'F9' or key == 'N' then
			self:minimize()
		else
			print[[
F8    S    show
F7    H    hide
F10   R    restore
F11   F    fullscreen on/off
F12   M    maximize
F9    N    minimize
]]
		end
	end

	return win
end

--test that the initial flags were all set correctly.
--also, create key bindings for interactive use.
local function test_initial_flags(win, flags)
	for i,flag in ipairs(flag_list) do
		assert(win[flag](win) == flags[flag], flag)
	end
end

--test transitions to normal state.
local function test_flags_to_normal(win, flags, after_test)

	local nfs = 0
	local fs = nw:os'osx' and 1.5 or nfs --fullscreen animation duration (seconds)
	local go1, go2, go3, go4, go5

	function go1()
		--visible -> minimized | normal | maximized | fullscreen
		if not flags.visible then
			win:show()
			app:runafter(flags.fullscreen and not flags.minimized and fs or nfs, go2)
		else
			go2()
		end
	end
	function go2()
		assert(win:visible())
		assert(win:minimized() == flags.minimized)
		--print(win:maximized(), flags.maximized)
		assert(win:maximized() == flags.maximized)
		assert(win:fullscreen() == flags.fullscreen)

		-- minimized -> normal | maximized | fullscreen
		if flags.minimized then
			win:restore()
			app:runafter(flags.fullscreen and fs or nfs, go3)
		else
			go3()
		end
	end
	function go3()
		assert(not win:minimized())
		assert(win:maximized() == flags.maximized)
		assert(win:fullscreen() == flags.fullscreen)

		-- fullscreen -> normal | maximized
		if flags.fullscreen then
			win:restore()
			app:runafter(fs, go4)
		else
			go4()
		end
	end
	function go4()
		assert(not win:fullscreen())
		assert(win:maximized() == flags.maximized)

		-- maximized -> normal
		if flags.maximized then
			win:restore()
			app:runafter(nfs, go5)
		else
			go5()
		end
	end
	function go5()
		assert(not win:maximized())

		--normal
		assert(win:visible())
		assert(not win:minimized())
		assert(not win:maximized())
		assert(not win:fullscreen())

		if after_test then
			after_test()
		else
			win:close()
		end
	end

	go1()
end

--generate interactive tests for testing all combinations of initial flags
--and the transitions to normal state.
for flags in combinations(flag_list) do
	add(test_name_for_flags(flags, 'states-init'), function()
		local win = window_with_flags(flags)
		test_initial_flags(win, flags)
		test_flags_to_normal(win, flags)
		app:run()
	end)
end

add('states-init-all', function()
	app:autoquit(false)
	local t = {}
	for flags in combinations(flag_list) do
		t[#t+1] = flags
	end
	local i = 0
	local function next_test()
		i = i + 1
		local flags = t[i]
		if not flags then
			app:quit()
			return
		end
		print(test_name_for_flags(flags, ''))
		local win = window_with_flags(flags)
		test_initial_flags(win, flags)
		test_flags_to_normal(win, flags, function()
			win:close()
			next_test()
		end)
	end
	app:runafter(0, next_test)
	app:run()
end)

--test transitions between various states.
add('states', function()
	local win = app:window{x = 100, y = 100, w = 300, h = 100}

	local function check(s)
		assert(win:visible() == (s:match'v' ~= nil))
		assert(win:minimized() == (s:match'm' ~= nil))
		assert(win:maximized() == (s:match'M' ~= nil))
		assert(win:fullscreen() == (s:match'F' ~= nil))
	end

	win:maximize()
	win:minimize()

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

--default flags

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

--positioning ----------------------------------------------------------------

add('size', function()
	local win = app:window(winpos())
	function win:mousemove(x, y)
		--print('mousemove', x, y)
	end
	function win:start_resize() print'start_resize' end
	function win:end_resize() print'end_resize' end
	function win:resizing(how, x, y, w, h)
		print('resizing', how, x, y, w, h)
	end
	function win:resized()
		print('resized')
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

--there's at least one display and its values are sane
add('display-list', function()
	local n = 0
	for i,display in ipairs(app:displays()) do
		n = n + 1
		print(string.format('# display %d', i))
		test_display(display)
	end
	assert(n > 0) --there must be at least 1 display
	--assert(n == app:display_count())
end)

--main display is at (0, 0)
add('display-main', function()
	local display = app:main_display()
	test_display(display)
	local x, y, w, h = display:rect()
	--main screen is at (0, 0)
	assert(x == 0)
	assert(y == 0)
end)

--edge snapping --------------------------------------------------------------

add('snap', function()
	local win = app:window(winpos())
	local win2 = app:window(winpos())
	app:run()
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

--menus ----------------------------------------------------------------------

local function setmenu_osx(nsapp)
	local objc = require'objc'
	local mb = objc.NSMenu:new(); ffi.gc(mb, nil)
	local ami = objc.NSMenuItem:new(); ffi.gc(ami, nil)
	mb:addItem(ami)
	nsapp:setMainMenu(mb)
	local am = objc.NSMenu:new(); ffi.gc(am, nil)
	local qmi = objc.NSMenuItem:alloc():initWithTitle_action_keyEquivalent('Quit', 'terminate:', 'q'); ffi.gc(qmi, nil)
	am:addItem(qmi)
	ami:setSubmenu(am)
end

add('menu', function()
	local win = app:window{w = 500, h = 300}
	local winmenu = win:menu()
	local menu1 = app:menu()
	menu1:add('Option1', function() print'Option1' end)
	menu1:add('Option2', function() print'Option2' end)
	menu1:set(2, 'Option2-changed', function() print'Option2-changed' end, {checked = true})
	menu1:add(2, 'Dead Option')
	menu1:remove(2)
	menu1:add(2, '') --separator
	menu1:checked(1, true)
	assert(menu1:checked(3))
	menu1:checked(3, false)
	assert(not menu1:checked(3))
	assert(menu1:enabled(3))
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
	app:run()
end)

--run tests ------------------------------------------------------------------

local name = ...
if not name then
	print(string.format('Usage: %s <name> | <name>*', arg[0]))
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

