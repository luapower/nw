io.stdout:setvbuf'no'
io.stderr:setvbuf'no'

require'strict'
local nw = require'nw'
local glue = require'glue'
local ffi = require'ffi'
local bit = require'bit'
local box2d = require'box2d'
local bitmap = require'bitmap'
local pp = require'pp'
local time = require'time'
local sleep = time.sleep

--local objc = require'objc'
--objc.debug.logtopics.refcount = true

local app --global app object
local seetime = 1
local dotime = 5

--helpers / collecting and running tests -------------------------------------

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

--helpers / window position generators ---------------------------------------

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

--helpers / event recorder/checker -------------------------------------------

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

--helpers / rendering --------------------------------------------------------

function whiteband_animation()
	local i = 0
	return function(bmp)
		local _, setpixel = bitmap.pixel_interface(bmp)
		for y = 0, bmp.h-1 do
			for x = 0, bmp.w-1 do
				local i = (i % bmp.w)
				local c = x >= i and x <= i + 50 and 255 or 100
				if x <= 10 or x >= bmp.w - 10 or y <= 10 or y >= bmp.h - 10 then
					c = 20
				end
				setpixel(x, y, c, c, c, 255)
			end
		end
		i = i + 5
	end
end

function arrows_animation()
	local r = 0
	return function(cr, w, h)
		local cairo = require'cairo'
		cr:rgba(0,0,0,1)
		cr:paint()

		cr:identity_matrix()
		cr:translate(w/2, h/2)
		cr:rotate_around(0, 0, r)
		cr:translate(-128, -128)
		r = r + 0.02

		cr:rgba(0,0.7,0,1)

		cr:line_width(40.96)
		cr:move_to(76.8, 84.48)
		cr:rel_line_to(51.2, -51.2)
		cr:rel_line_to(51.2, 51.2)
		cr:line_join'miter'
		cr:stroke()

		cr:move_to(76.8, 161.28)
		cr:rel_line_to(51.2, -51.2)
		cr:rel_line_to(51.2, 51.2)
		cr:line_join'bevel'
		cr:stroke()

		cr:move_to(76.8, 238.08)
		cr:rel_line_to(51.2, -51.2)
		cr:rel_line_to(51.2, 51.2)
		cr:line_join'round'
		cr:stroke()
	end
end

local function cube_animation()
	local r = 30
	return function(gl, w, h)
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

		r = r + 1
		gl.glPushMatrix()
		gl.glTranslated(0,0,-3)
		gl.glScaled(1, 1, 1)
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
end

--version checks -------------------------------------------------------------

add('ver', function()
	assert(app:ver(ffi.os:upper())) --case-insensitive match
	assert(not app:ver'XXX')
	if ffi.os == 'OSX' then
		assert(app:ver'osx')
		assert(app:ver'OSX 1')
		assert(app:ver'OSX 10')
		assert(app:ver'OSX 10.2')
		assert(not app:ver'OSX 55')
		assert(not app:ver'OS')
	elseif ffi.os == 'Windows' then
		assert(app:ver'windows')
		assert(app:ver'WINDOWS 1')
		assert(app:ver'WINDOWS 5')
		assert(app:ver'WINDOWS 5.0')
		assert(app:ver'WINDOWS 5.0.1')
		assert(not app:ver'WINDOWS 55.0.1')
		assert(not app:ver'Window')
	elseif ffi.os == 'Linux' then
		assert(app:ver'X 11')
		assert(app:ver'linux')
		assert(app:ver'Linux')
		print(app:ver'linux')
	end
	print'ok'
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

--ensure that timers that are too fast don't starve the loop
add('timer-fast', function()
	local rec = recorder()
	local i = 1
	app:runevery(0, function()
		rec(i)
		i = i + 1
		if i > 3 then
			--stopping is done on the next loop. if the app stops
			--then it means that it reached the top of the loop.
			app:stop()
			return false
		end
	end)
	app:run()
	rec{1, 2, 3}
end)

--timers stop when the loop is stopped, and resume after the loop is resumed.
add('timer-resume', function()
	local rec = recorder()
	local i, j = 1, 1
	app:runevery(0, function()
		rec(i)
		i = i + 1
		if i > 3 then
			app:stop()
			j = j + 1
			return j < 3 --remove the timer on the second app run.
		end
	end)
	app:run()
	i = 1
	app:run()
	rec{1, 2, 3, 1, 2, 3}
end)

--app:sleep() works with an async func.
add('timer-sleep', function()
	local rec = recorder()
	app:run(function()
		for i=1,5 do
			rec(i)
			local t0 = time.clock()
			local d = i/10 -- 0.1s -> 1s
			app:sleep(d)
			print(string.format('deviation: %d%%', (time.clock() - t0 - d) / d * 100))
		end
	end)
	rec{1, 2, 3, 4, 5}
end)

add('timer-sleep-forever', function()
	local rec = recorder()
	app:runafter(0.2, function()
		app:stop()
		rec'stopped'
	end)
	app:run(function()
		rec'forever'
		app:sleep()
		error'never here'
	end)
	rec{'forever', 'stopped'}
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

--stop() works after running a second time.
add('loop-run-stop-run', function()
	local rec = recorder()
	app:runafter(0, function()
		rec'run1'
		app:stop()
	end)
	app:run()
	app:runafter(0, function()
		rec'run2'
		app:stop()
	end)
	app:run()
	rec{'run1', 'run2'}
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
--closed() happen in reverse creation order.
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
	rec{'quitting', 'closing1', 'closing2', 'closed2', 'closed1'}
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

--the app is activated if a window is shown.
add('activation-app-activated', function()
	local rec = recorder()
	function app:activated() rec'app-activated' end
	local win = app:window(winpos())
	app:run(function()
		app:sleep(0.1)
	end)
	rec{'app-activated'}
end)

--the app is dactivated after the last window is hidden.
--this is an interactive test because you have to start the app with it.
add('demo-activation-app-deactivated', function()
	local rec = recorder()
	function app:deactivated() rec'app-deactivated' end
	local win = app:window(winpos())
	app:run(function()
		app:sleep(0.2)
		win:hide()
		app:sleep(0.1)
	end)
	rec{'app-deactivated'}
end)

--app:active() works (returns true only if the app is active).
--app:active_window() works (always returns nil if the app is not active).
--this is an interactive test: you must activate another app to see it.
add('demo-activation-app-active', function()
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

--in Windows, app:activate() does not activate the window immediately.
--instead, it flashes the window on the taskbar waiting for the user
--to click on it (or alt-tab to it) and activate it.
--Likewise in OSX it flashes the dock icon.
--In Linux it does nothing (only activate'force' works).
--this is an interactive test: you must activate another app to see it.
local function activation_test(mode)
	return function()
		local win = app:window(winpos())
		function app:activated() print'app-activated' end
		function app:deactivated()
			print'app-deactivated'
			app:runafter(1, function()
				app:activate(mode)
				--check that the window is not considered active until the user
				--clicks on the flashing taskbar button.
				app:runevery(0.1, function()
					print('window is active:', win:active(), 'active window:', app:active_window())
					if win:active() then
						--user clicked on the taskbar button
						app:stop()
						return false
					end
				end)
			end)
		end
		app:run()
	end
end
add('demo-activation-app-alert', activation_test())
add('demo-activation-app-info', activation_test'info')
add('demo-activation-app-force', activation_test'force')

--In Windows the app can be activated programatically even if there are no
--visible windows, but there must be at least one (hidden) window.
--In OSX the app can always be activated even without windows (the main
--menu is activated anyway).
--In Linux the app can't be activated if there isn't at least one visible
--window (because there's no concept of apps in X really).
--this is an interactive test: you must activate another app to see it.
add('demo-activation-app-activate-no-windows', function()
	function app:activated() print'activated' end
	function app:deactivated() print'deactivated' end
	local win = app:window(winpos{visible = false})
	app:runevery(1, function()
		print('app:active() -> ', app:active(), 'app:active_window() -> ', app:active_window())
		app:activate'force'
	end)
	app:run()
end)

--when the first window is shown, it is not activated if another app
--was activated in the meantime (Windows, OSX, not Linux).
--this is an interactive test: you must activate another app to see it.
add('demo-activation-window-activate-hidden', function()
	local rec = recorder()
	local win = app:window(winpos{visible = false})
	function win:activated() rec'win-activated' end
	app:runafter(0, function()
		win:activate() --ignored
		print'Right-click on this terminal window NOW! You have 2 SECONDS!'
		app:runafter(2, function()
			win:show()
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
add('demo-activation-window-non-activable', function()
	local win1 = app:window{x = 100, y = 100, w = 500, h = 200}
	local win2 = app:window{x = 200, y = 130, w = 200, h = 300,
		activable = false, frame = 'toolbox', parent = win1}
	function win1:activated() rec'win1-activated' end
	function win1:deactivated() rec'win1-deactivated' end
	function win2:activated() rec'win2-activated' end
	function win2:deactivated() rec'win2-deactivated' end
	app:runevery(0.1, function() print('win1 active', win1:active()) end)
	app:run()
end)

--app visibility (OSX only) --------------------------------------------------

add('app-hide', function()
	local rec = recorder()
	function app:hidden() rec'hide' end
	function app:unhidden() rec'unhide' end
	assert(app:visible())
	app:run(function()
		app:sleep(0.2)
		app:hide()
		app:sleep(0.2)
		if app:ver'OSX' then
			assert(not app:visible())
		end
		app:unhide()
		app:sleep(0.2)
		assert(app:visible())
		if app:ver'OSX' then
			rec{'hide', 'unhide'}
		end
	end)
end)

--default initial properties -------------------------------------------------

add('init-defaults', function()
	local win = app:window(winpos())
	app:runafter(0.2, function()
		assert(win:visible())
		assert(not win:isminimized())
		assert(not win:fullscreen())
		assert(not win:ismaximized())
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
		app:quit()
	end)
	app:run()
end)

--interactive tests ----------------------------------------------------------

--[[
What you should know about window states:
- there are five state flags making up the window state:
	- v (visible)
	- m (minimized)
	- M (maximized)
	- F (fullscreen)
	- A (active)
- a window can be created with any combination of (v, m, M) but not F.
- you can't change v, m or M from F (you can only restore from fullscreen).
- state-changing methods can change one or more of the state flags at once
  depending on the initial state and the method.
- state-changing methods can behave synchronously or asynchronously.
- some state-changing methods may not always succeed in changing the state.
- state changes trigger specific state-changing events, and can also trigger:
	- window activation and/or deactivation.
	- window moving and/or resizing.
]]

local function state_string(win)
	if win:dead() then return 'x' end
	local w,h = win:client_size()
	local fx,fy,fw,fh = win:frame_rect()
	local nx,ny,nw,nh = win:normal_frame_rect()
	return
		(app:visible() and ' ' or 'h')..
		(win:visible() and 'v' or ' ')..
		(win:isminimized() and 'm' or ' ')..
		(win:ismaximized() and 'M' or ' ')..
		(win:fullscreen() and 'F' or ' ')..
		(win:active() and 'A' or ' ')..' | '..
		(app:active() and 'a' or ' ')..' | '..
		(string.format('  (%4s x%4s)',w,h))..
		(string.format('  (%4s, %4s :%4s x%4s)',fx,fy,fw,fh))..
		(string.format('  (%4s, %4s :%4s x%4s)',nx,ny,nw,nh))
end

local function mkdemo(t, child)
	return function()

		local function help()
			print[[

	F1       help
	H        hide
	S        show
	N        minimize
	M        maximize
	F        fullscreen toggle
	G        fullscreen on
	shift+G  fullscreen off
	esc      restore
	D        shownormal
	A        activate cwin
	B        activate win
	F9       activate app after 2s
	Z        resize+
	X        resize-
	shift+Z  resize+ (normal rect)
	shift+X  resize- (normal rect)
	arrows   move
	4        toggle minsize
	5        toggle maxsize
	1        toggle enabled
	2        toggle allow close
	3        toggle autoquit
	[        lower
	]        raise
	<        lower relative to win1
	>        raise relative to win1
	T        set title
	C        close / create
	Q        quit
	0        app hide (OSX)
	9        app hide and unhide after 1s (OSX)
	enter    print state
			]]
		end

		help()

		app:autoquit(true)

		local cwin, win

		local function print_state(s, ...)
			if not win or win:dead() then return end
			print(string.format('%-16s', s), state_string(win), ...)
		end

		function app:quitting()              print_state'quitting'; return true end
		function app:window_created(win)
			print(string.format('%-16s', 'window_created'), state_string(win)) end
		function app:window_closed(win)
			print(string.format('%-16s', 'window_closed'), state_string(win))
		end
		function app:unhidden()          print_state'app unhidden' end
		function app:hidden()            print_state'app hidden' end
		function app:displays_changed()      print_state'displays_changed' end
		function app:deactivated()           print_state'    app deactivated' end
		function app:activated()             print_state'    app activated' end
		function app:changed(old, new)       print_state('app changed', old..' -> '..new) end

		--make a control window that receives key presses when win gets hidden
		cwin = app:window(winpos{w = 200, h = 50, title = 'cwin'})
		cwin.name = 'cwin'

		t.parent = child and cwin or nil
		t.cx = 500
		t.cy = 300
		t.cw = 700
		t.ch = 300
		--t.edgesnapping = false
		t.autoquit = true
		t.title = 'win'

		local function create()

			win = app:window(t)
			win.name = 'win'

			function cwin:keypress(key)
				win:keypress(key)
			end

			local function short(s)
				return s:gsub('%w+', {visible = 'v', minimized = 'm',
				maximized = 'M', fullscreen = 'F', active = 'A'}):gsub(' ', '')
			end
			function win:changed(old, new)    print_state('changed', short(old)..' -> '..short(new)) end

			--synthetic changed events
			function win:minimized()      print_state'  minimized' end
			function win:maximized()      print_state'  maximized' end
			function win:unminimized()    print_state'  unminimized' end
			function win:unmaximized()    print_state'  unmaximized' end
			function win:entered_fullscreen() print_state'  entered_fullscreen' end
			function win:exited_fullscreen()  print_state'  exited_fullscreen' end
			function win:shown()              print_state'  shown' end
			function win:hidden()             print_state'  hidden' end
			function win:activated()          print_state'    activated' end
			function win:deactivated()        print_state'    deactivated' end
			function win:frame_resized(...)   print_state('      frame_resized', ...) end
			function win:frame_moved(...)     print_state('      frame_moved', ...) end
			function win:client_resized(...)  print_state('      client_resized', ...) end
			function win:client_moved(...)    print_state('      client_moved', ...) end

			function win:closed()             print_state'closed' end
			function win:sizing(...)          print_state('  sizing', ...) end

			local allow_close = true

			local function next_cursor()
				return cursors[i]
			end

			function win:keypress(key)
				if key == 'H' then
					self:hide()
				elseif key == 'S' then
					self:show()
				elseif key == 'D' then
					self:shownormal()
				elseif key == 'esc' then
					self:restore()
				elseif key == 'F' then
					local fs = not self:fullscreen()
					self:fullscreen(fs)
					if app:key'shift' then --toggle it back immediately
						self:fullscreen(not fs)
					end
					if app:key'ctrl' then --now toggle it back again
						self:fullscreen(fs)
					end
				elseif key == 'G' then
					self:fullscreen(not app:key'shift')
				elseif key == 'M' then
					self:maximize()
				elseif key == 'N' then
					self:minimize()
				elseif key == 'A' then
					cwin:activate()
				elseif key == 'B' then
					self:activate()
				elseif key == 'F9' then
					app:runafter(2, function()
						app:activate()
					end)
				elseif key == 'X' or key == 'Z' then
					local ofs = key == 'Z' and 10 or -10
					if self.app:key'shift' then
						if not win:client_rect() then return end
						win:client_rect(box2d.offset(ofs, win:client_rect()))
					else
						if not win:frame_rect() then return end
						win:frame_rect(box2d.offset(ofs, win:frame_rect()))
					end
				elseif key == 'left' or key == 'right' or key == 'up' or key == 'down' then
					if app:key'shift' then
						local x, y = win:client_rect()
						if not x then return end
						win:client_rect(
							x + (key == 'left' and -10 or key == 'right' and 10 or 0),
							y + (key == 'up'   and -10 or key == 'down'  and 10 or 0))
					else
						local x, y = win:frame_rect()
						if not x then return end
						win:frame_rect(
							x + (key == 'left' and -10 or key == 'right' and 10 or 0),
							y + (key == 'up'   and -10 or key == 'down'  and 10 or 0))
					end
				elseif key == '1' then
					win:enabled(not win:enabled())
				elseif key == 'C' then
					if self:dead() then
						create()
					else
						self:close()
					end
				elseif key == '2' then
					allow_close = not allow_close
				elseif key == '3' then
					win:autoquit(not win:autoquit())
				elseif key == '4' then
					if win:minsize() then
						win:minsize(false)
					else
						win:minsize(200, 200)
					end
				elseif key == '5' then
					if win:maxsize() then
						win:maxsize(false)
					else
						win:maxsize(400, 400)
					end
				elseif key == ',' then
					win:lower(cwin)
				elseif key == '.' then
					win:raise(cwin)
				elseif key == '[' then
					win:lower()
				elseif key == ']' then
					win:raise()
				elseif key == 'T' then
					win:title(win:title() .. '!')
				elseif key == 'tab' then
					win:cursor(next_cursor())
				elseif key == 'Q' then
					self.app:quit()
				elseif key == '0' then
					self.app:hide()
				elseif key == '9' then
					self.app:hide()
					self.app:runafter(1, function()
						self.app:show()
					end)
				elseif key == 'F1' then
					help()
				elseif key == 'enter' then
					print(('-'):rep(100))
					print('state             ', state_string(win))
					print''
					print('active            ', win:active())
					print('active window     ', app:active_window() and app:active_window().name)
					print('enabled           ', win:enabled())
					print('sticky            ', win:sticky())
					print('frame_rect        ', win:frame_rect())
					print('client_rect       ', win:client_rect())
					--TODO: implement this
					--print('normal_client_rect', win:normal_client_rect())
					print('normal_frame_rect ', win:normal_frame_rect())
					print('client_size       ', win:client_size())
					print('minsize           ', win:minsize())
					print('maxsize           ', win:maxsize())
					print('cursor            ', win:cursor())
					print('edgesnapping      ', win:edgesnapping())
					print('autoquit          ', win:autoquit())
					print''
					print('app active        ', app:active())
					print('app visible       ', app:visible())
					print('app autoquit      ', app:autoquit())
					print''
					print('display           ', pp.format(win:display()))
					print('displays"#"       ', app:displays'#')
					print('main_display      ', pp.format(app:main_display()))
					print('active_display    ', pp.format(app:active_display()))
					print(('-'):rep(100))
				end
			end

			function win:closing(...)
				print_state('closing', ...)
				return allow_close
			end
		end
		create()
		app:run()
	end
end

--initial states
add('demo', mkdemo{})
add('demo-hidden', mkdemo{visible = false})
add('demo-minimized', mkdemo{visible = true, minimized = true})
add('demo-maximized', mkdemo{visible = true, maximized = true})
add('demo-minimized-maximized', mkdemo{visible = true, minimized = true, maximized = true})
add('demo-hidden-minimized', mkdemo{visible = false, minimized = true})
add('demo-hidden-maximized', mkdemo{visible = false, maximized = true})
add('demo-hidden-minimized-maximized', mkdemo{visible = false, minimized = true, maximized = true})
add('demo-disabled', mkdemo({enabled = false}))

--restrictions
add('demo-non-minimizable', mkdemo{minimizable = false})
add('demo-non-maximizable', mkdemo{maximizable = false})
add('demo-non-closeable', mkdemo{closeable = false})
add('demo-non-resizeable', mkdemo{resizeable = false}) --implies non-maximizable non-fullscreenable
add('demo-non-activable', mkdemo({activable = false, frame = 'toolbox'}, true))
--this combination makes disabled buttons hidden rather than disabled
add('demo-non-minimizable-non-maximizable', mkdemo{minimizable = false, maximizable = false})
--this combination shows no buttons
add('demo-non-minimizable-non-maximizable-non-closeable', mkdemo{minimizable = false, maximizable = false})
--this combination allows maxsize()
add('demo-non-maximizable-non-fullscreenable', mkdemo{maximizable = false, fullscreenable = false})

--other read-only properties
add('demo-topmost', mkdemo({topmost = true}))
add('demo-parent', mkdemo({}, true))
add('demo-parent-non-sticky', mkdemo({sticky = false}, true))
add('demo-frame=none', mkdemo({frame = 'none'}))
add('demo-frame=toolbox', mkdemo({frame = 'toolbox'}, true))
add('demo-frame=toolbox-non-activable', mkdemo({frame = 'toolbox', activable = false}, true))
add('demo-frame=none-transparent', mkdemo({frame = 'none', transparent = true}, true))
add('demo-round-corners', mkdemo({corner_radius = 20}))
add('demo-frame=none-round-corners', mkdemo({frame = 'none', resizeable = true, corner_radius = 20}))

--state automated tests ------------------------------------------------------

local checkactive = true --test the active flag too!

local function parse_initial_state_string(s)
	local visible
	if s:match'h' then visible = false elseif s:match'v' then visible = true end
	return {
		visible = visible,
		minimized = s:match'm' and true or nil,
		maximized = s:match'M' and true or nil,
		fullscreen = s:match'F' and true or nil,
		active = checkactive and s:match'A' and true or nil,
	}
end

local function state_string(win)
	if win:dead() then return 'x' end
	return
		(win:visible() and 'v' or 'h')..
		(win:isminimized() and 'm' or '')..
		(win:ismaximized() and 'M' or '')..
		(win:fullscreen() and 'F' or '')..
		(checkactive and win:active() and 'A' or '')
end

--wait for a predicate on a timeout.
--uses app:sleep() instead of time.sleep() so that events can be recorded while waiting.
local function waitfor(func, timeout)
	timeout = timeout or 5 --seconds to wait for animations to complete
	local t0 = time.clock()
	while not func() do
		if time.clock() - t0 > timeout then return end --give up after timeout
		app:sleep(0.1)
	end
	return true
end

--make a state-changing test from a test spec which has the form:
--		{initial_state, actions, expected_state, actions, expected_state, ...}
local function state_test(t)
	return function()
		app:run(function()

			local t0 = time.clock()

			--parse initial state string
			local initial_state
			if type(t[1]) == 'string' then
				initial_state = parse_initial_state_string(t[1])
			else
				initial_state = glue.update(parse_initial_state_string(t[1][1] or ''), t[1])
			end

			--create a window
			local win = app:window(winpos(initial_state))

			--catch events
			local events = {}
			function win:event(event_name)
				local t1 = time.clock()
				print(string.format('   %4dms | %-5s | EVENT: %s', (t1 - t0) * 1000, state_string(self), event_name))
				t0 = t1
				events[#events+1] = event_name
				events[event_name] = (events[event_name] or 0) + 1
			end

			--wait for the window to get to its initial state
			waitfor(function()

				--previous test might have left the app inactive. fix that.
				if not win:isminimized() and win:visible() and not app:active() then
					app:activate()
				end

				return
					    (initial_state.visible ~= nil or win:visible())
					and (initial_state.visible ~= true or win:visible())
					and (initial_state.visible ~= false or not win:visible())
					and (not not initial_state.minimized == win:isminimized())
					and (not not initial_state.maximized == win:ismaximized())
					and (not not initial_state.fullscreen == win:fullscreen())
					and (not checkactive or (not not initial_state.active == win:active()))
			end)

			app:sleep(0.1)

			--run the actions
			for i=2,#t,2 do
				local actions = t[i] --actions: 'action1 action2 ...'
				local state = t[i+1] --state: '[vmMf] event1 event2...'
				local expected_state = state:match'^[hvmMFA]*'
				if not checkactive then
					expected_state = expected_state:gsub('A', '')
				end
				local expected_events = state:match'%s+(.*)' or ''
				print(state_string(win)..' -> '..actions..' -> '..expected_state..
					(expected_events ~= '' and ' ('..expected_events..')' or ''))

				--perform all the actions and record all events
				events = {}
				for action in glue.gsplit(actions, ' ') do
					local t1 = time.clock()
					print(string.format('   %4dms | %-5s | ACTION: %s', (t1 - t0) * 1000, state_string(win), action))
					t0 = t1
					if action == 'enter_fullscreen' then
						win:fullscreen(true)
					elseif action == 'exit_fullscreen' then
						win:fullscreen(false)
					else
						win[action](win)
					end

					if app:ver'Linux' then
						--Linux backend does not have proper semantics for queued async operations
						app:sleep(0.1)
					end
				end

				--poll the window until it reaches the expected state or a timeout expires.
				waitfor(function()
					--print('', state_string(win), expected_state)
					return state_string(win) == expected_state
				end)

				--wait a little more so that events announcing the state change can fire.
				app:sleep(0.1)

				--check that it did reach expected state.
				if state_string(win) ~= expected_state then
					error(state_string(win) .. ', expected ' .. expected_state .. ' after ' .. actions)
				end

				--check that all expected events were fired.
				local i = 0
				for event in glue.gsplit(expected_events, ' ') do
					if event ~= '' then
						i = i + 1
						if not events[event] then
							error(table.concat(events, ' ') .. ', expected ' .. expected_events .. ', missing '..event)
						end
						if events[event] > 1 then
							--TODO: fix these problems in the Linux backend
							if app:ver'Linux' then
								print('\n\n\n\nWARNING multiple '..event..'\n\n\n\n')
							else
								error('multiple '..event)
							end
						end
					end
				end
			end

			--close the window
			app:autoquit(false) --but don't exit the loop!
			win:close()

			--wait for it to be closed
			assert(waitfor(function() return win:dead() end), 'window not dead')

			print'  --------+---------------------------------'
		end)
	end
end

for i,t in ipairs{

	--basic check: check single transitions fron initial hidden state
	{'h', 'show', 'vA shown activated'},
	{'h', 'hide', 'h'},
	{'h', 'maximize', 'vMA shown maximized activated'},
	{'h', 'minimize', 'vm minimized'},
	{'h', 'restore', 'vA shown activated'},
	{'h', 'shownormal', 'vA shown activated'},

	--basic check: check single transitions fron initial normal state
	{'vA', 'show', 'vA'},
	{'vA', 'hide', 'h hidden deactivated'},
	{'vA', 'maximize', 'vMA maximized'},
	{'vA', 'minimize', 'vm minimized deactivated'},
	{'vA', 'restore', 'vA'},
	{'vA', 'shownormal', 'vA'},

	--basic check: check single transitions fron initial minimized state
	{'vm', 'show', 'vm'},
	{'vm', 'hide', 'hm hidden'},
	{'vm', 'maximize', 'vMA unminimized maximized activated'},
	{'vm', 'minimize', 'vm'},
	{'vm', 'restore', 'vA unminimized activated'},
	{'vm', 'shownormal', 'vA unminimized activated'},

	--basic check: check single transitions fron initial hidden minimized state
	{'hm', 'show', 'vm shown'},
	{'hm', 'hide', 'hm'},
	{'hm', 'maximize', 'vMA shown unminimized maximized activated'},
	{'hm', 'minimize', 'vm shown'},
	{'hm', 'restore', 'vA shown unminimized activated'},
	{'hm', 'shownormal', 'vA shown unminimized activated'},

	--basic check: check single transitions fron initial maximized state
	{'vMA', 'show', 'vMA'},
	{'vMA', 'hide', 'hM hidden deactivated'},
	{'vMA', 'maximize', 'vMA'},
	{'vMA', 'minimize', 'vmM minimized deactivated'},
	{'vMA', 'restore', 'vA unmaximized'},
	{'vMA', 'shownormal', 'vA unmaximized'},

	--basic check: check single transitions fron initial hidden maximized state
	{'hM', 'show', 'vMA shown activated'},
	{'hM', 'hide', 'hM'},
	{'hM', 'maximize', 'vMA shown activated'},
	{'hM', 'minimize', 'vmM minimized'},
	{'hM', 'restore', 'vA unmaximized'},
	{'hM', 'shownormal', 'vA unmaximized'},

	--basic check: check single transitions fron initial minimized maximized state
	{'vmM', 'show', 'vmM'},
	{'vmM', 'hide', 'hmM hidden'},
	{'vmM', 'maximize', 'vMA unminimized'},
	{'vmM', 'minimize', 'vmM'},
	{'vmM', 'restore', 'vMA unminimized'},
	{'vmM', 'shownormal', 'vA unminimized unmaximized'},

	--basic check: check single transitions fron initial hidden minimized maximized state
	{'hmM', 'show', 'vmM shown'},
	{'hmM', 'hide', 'hmM'},
	{'hmM', 'maximize', 'vMA unminimized activated'},
	{'hmM', 'minimize', 'vmM shown'},
	{'hmM', 'restore', 'vMA unminimized activated'},
	{'hmM', 'shownormal', 'vA unminimized unmaximized activated'},

	--basic check: transitions from fullscreen
	{'vA', 'enter_fullscreen', 'vFA', 'show', 'vFA'},
	{'vA', 'enter_fullscreen', 'vFA', 'hide', 'vFA'},
	{'vA', 'enter_fullscreen', 'vFA', 'maximize', 'vFA'},
	{'vA', 'enter_fullscreen', 'vFA', 'minimize', 'vFA'},
	{'vA', 'enter_fullscreen', 'vFA', 'restore', 'vA'},
	{'vA', 'enter_fullscreen', 'vFA', 'shownormal', 'vFA'},

	--combined checks: check sequences of commands because some commands perform
	--asynchronously which may reveal bad assumptions made by other commands
	--that look at the current state to decide how to perform the operation.
	--1. check that calls are not merged (i.e. that all relevant events fire).
	--2. check that subsequent commands are not ignored while other commands perform.
	--3. check that the final state is correct.

	--basic check: duplicate commands
	{'vA',  'hide hide hide', 'h hidden'},
	{'h',   'show show show', 'vA shown'},
	{'vA',  'maximize maximize maximize', 'vMA maximized'},
	{'vA',  'minimize minimize minimize', 'vm minimized'},
	{'vm',  'restore restore restore', 'vA unminimized'},
	{'vMA', 'restore restore restore', 'vA unmaximized'},
	{'vMA', 'shownormal shownormal shownormal', 'vA unmaximized'},
	{'vm',  'shownormal shownormal shownormal', 'vA unminimized'},
	{'vmM', 'shownormal shownormal shownormal', 'vA unminimized unmaximized'},

	--combined check: check more complex combinations
	{'vA',  'hide show', 'vA hidden shown'},
	{'h',   'show hide', 'h shown hidden'},
	{'vA',  'maximize restore', 'vA maximized unmaximized'},
	{'vA',  'minimize restore', 'vA minimized deactivated unminimized activated'},
	{'vA',  'maximize minimize restore', 'vMA maximized minimized deactivated unminimized activated'},
	{'vA',  'maximize minimize restore restore', 'vA maximized minimized deactivated unminimized unmaximized activated'},
	{'vA',  'maximize hide', 'hM maximized hidden'},
	{'vA',  'minimize hide', 'hm minimized hidden'},
	{'vA',  'maximize minimize hide', 'hmM maximized minimized deactivated hidden'},

	--even more complex combinations (particularly minimized->hide->shownormal doesn't activate the window on Windows)
	{'vA',  'maximize hide restore',    'vA maximized deactivated hidden unmaximized'},
	{'vA',  'maximize hide shownormal', 'vA maximized deactivated hidden unmaximized'},

	{'vA',  'minimize hide show',       'vm minimized deactivated hidden shown'},
	{'vA',  'minimize hide restore',    'vA minimized deactivated hidden shown unminimized activated'},
	{'vA',  'minimize hide shownormal', 'vA minimized deactivated hidden shown unminimized activated'},
	{'vA',  'maximize minimize hide show',           'vmM maximized minimized deactivated hidden shown'},
	{'vA',  'maximize minimize hide restore',        'vMA maximized minimized deactivated hidden shown unminimized activated'},
	{'vA',  'maximize minimize hide shownormal',      'vA maximized minimized deactivated hidden shown unminimized unmaximized activated'},
	{'vA',  'maximize minimize hide restore restore', 'vA maximized minimized deactivated hidden shown unminimized unmaximized activated'},
	{'hM',  'restore',         'vA shown unmaximized activated'},
	{'hm',  'restore',         'vA shown unminimized activated'},
	{'hmM', 'restore',        'vMA shown unminimized activated'},
	{'hmM', 'restore restore', 'vA shown unminimized activated unmaximized'},

	--transtions in and out of fullscreen

	--transitions from maximized fullscreen
	{'vA', 'maximize enter_fullscreen', 'vMFA', 'show', 'vMFA'},
	{'vA', 'maximize enter_fullscreen', 'vMFA', 'hide', 'vMFA'},
	{'vA', 'maximize enter_fullscreen', 'vMFA', 'maximize', 'vMFA'},
	{'vA', 'maximize enter_fullscreen', 'vMFA', 'minimize', 'vMFA'},
	{'vA', 'maximize enter_fullscreen', 'vMFA', 'restore', 'vMA exited_fullscreen'},
	{'vA', 'maximize enter_fullscreen', 'vMFA', 'shownormal', 'vMFA'},

	--transitions to fullscreen
	{'vA',  'enter_fullscreen', 'vFA entered_fullscreen'},
	{'h',   'enter_fullscreen', 'vFA shown entered_fullscreen activated'},
	{'vm',  'enter_fullscreen', 'vFA unminimized entered_fullscreen activated'},
	{'vMA', 'enter_fullscreen', 'vMFA entered_fullscreen'},
	{'hm',  'enter_fullscreen', 'vFA shown unminimized activated entered_fullscreen'},
	{'vmM', 'enter_fullscreen', 'vMFA unminimized entered_fullscreen activated'},
	{'hmM', 'enter_fullscreen', 'vMFA shown unminimized entered_fullscreen activated'},
	{'vA',  'enter_fullscreen', 'vFA', 'enter_fullscreen', 'vFA'},
	{'vMA', 'enter_fullscreen', 'vMFA', 'enter_fullscreen', 'vMFA'},

	--transitions to exit fullscreen
	{'vA',  'exit_fullscreen', 'vA'},
	{'h',   'exit_fullscreen', 'h'},
	{'vm',  'exit_fullscreen', 'vm'},
	{'vMA', 'exit_fullscreen', 'vMA'},
	{'hm',  'exit_fullscreen', 'hm'},
	{'vmM', 'exit_fullscreen', 'vmM'},
	{'hmM', 'exit_fullscreen', 'hmM'},
	{'vA',  'enter_fullscreen', 'vFA', 'exit_fullscreen', 'vA exited_fullscreen'},
	{'vMA', 'enter_fullscreen', 'vMFA', 'exit_fullscreen', 'vMA exited_fullscreen'},

} do

	--make up a name for the test
	local nt = {}
	for i = 2, #t, 2 do
		glue.append(nt, t[i] and t[i]:gsub(' ', '-'))
	end
	local test_name = (t[1] == 'vA' and '' or t[1]..'-')..table.concat(nt, '-')

	add('state-'..test_name, state_test(t))
end

--parent/child relationship --------------------------------------------------

add('demo-children', function()
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

--hiding the parent ----------------------------------------------------------

--check that a hidden parent results in a visible window that doesn't show on taskbar.
--bonus: check that autoquit works on child windows.
add('demo-parent-hidden', function()
	local win1 = app:window(winpos{visible = false})
	local win2 = app:window(winpos{parent = win1, autoquit = true})
	app:run()
end)

--check that hiding the parent results in a visible window that doesn't show on taskbar.
add('demo-parent-hide', function()
	local win1 = app:window(winpos())
	local win2 = app:window(winpos{parent = win1, autoquit = true})
	app:run(function()
		app:sleep(0.1) --for Linux
		win1:hide()
		app:sleep(true)
	end)
end)

--check that showing back the parent preserves the parent-child relationship.
add('demo-parent-hide-show', function()
	local win1 = app:window(winpos())
	local x, y = win1:client_rect()
	local win2 = app:window(winpos{x = x + 20, y = y + 20, parent = win1, autoquit = true})
	app:run(function()
		app:sleep(0.5)
		win1:hide()
		app:sleep(0.5)
		win1:show()
		app:sleep(true)
	end)
end)

--sticky children ------------------------------------------------------------

--children are sticky: they follow parent on move (but not on resize, maximize, etc).
--interactive test: move the parent to see child moving too.
add('demo-children-sticky', function()
	local win1 = app:window{x = 100, y = 100, w = 500, h = 200}
	local win2 = app:window{x = 200, y = 130, w = 200, h = 300, parent = win1, sticky = true}
	app:run()
end)

--children are not sticky: they don't follow parent on move or resize or maximize.
--interactive test: move the parent to see child moving too.
add('demo-children-non-sticky', function()
	local win1 = app:window{x = 100, y = 100, w = 500, h = 200}
	local win2 = app:window{x = 200, y = 130, w = 200, h = 300, parent = win1, sticky = false}
	app:run()
end)

--state/enabled --------------------------------------------------------------

--interactive test showing modal operation based on `enabled` and `parent` properties.
add('demo-enabled', function()
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

--positioning/app-level frame-client conversions -----------------------------

add('pos-client-to-frame', function()
	local function test_frame(frame, has_menu)
		local cx, cy, cw, ch = 100, 200, 300, 400
		local x, y, w, h = app:client_to_frame(frame, has_menu, cx, cy, cw, ch)
		assert(x <= cx)
		assert(y <= cy)
		assert(w >= cw)
		assert(h >= ch)
		print(frame, has_menu, '', cx, cy, cw, ch, '->', x, y, w, h)
	end
	for _,frame in ipairs{'normal', 'toolbox', 'none'} do
		test_frame(frame, false)
		test_frame(frame, true)
	end
end)

add('pos-frame-to-client', function()
	local x, y, w, h = 100, 200, 300, 400

	local cx, cy, cw, ch = app:frame_to_client('normal', false, x, y, w, h)
	assert(x <= cx)
	assert(y <= cy)
	assert(w >= cw)
	assert(h >= ch)

	--the minimum client rect for a zero-sized frame rect is 1.
	local cx, cy, cw, ch = app:frame_to_client('normal', false, 0, 0, 0, 0)
	assert(cw == 1)
	assert(ch == 1)

	--if no frame, frame rect and client rect match, even at size 1.
	local cx, cy, cw, ch = app:frame_to_client('none', false, 0, 0, 0, 0)
	assert(cx == 0)
	assert(cy == 0)
	assert(cw == 1)
	assert(ch == 1)

	print'ok'
end)

--positioning/initial values -------------------------------------------------

--check that a window is spanning the entire workspace -2px on all sides.
add('demo-pos-init-client', function()
	local sx, sy, sw, sh = app:main_display():desktop_rect()
	local fw1, fh1, fw2, fh2 = app:frame_extents'normal'
	local b = 2
	local win = app:window{
		cx = sx + fw1 + b,
		cy = sy + fh1 + b,
		cw = sw - fw1 - fw2 - 2*b,
		ch = sh - fh1 - fh2 - 2*b,
	}
	app:run()
end)

--check that a window spanning the entire workspace -2px on all sides.
add('demo-pos-init-frame', function()
	local sx, sy, sw, sh = app:main_display():desktop_rect()
	local b = 2
	local win = app:window{
		x = sx + b,
		y = sy + b,
		w = sw - 2*b,
		h = sh - 2*b,
	}
	app:run()
end)

--test if x,y,w,h mixed with cx,cy,cw,ch works.
--this is an eye-test for framed windows.
add('demo-pos-init-mixed', function()
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
add('demo-pos-init-cascade', function()
	for i = 1,30 do
		app:window{w = 500, h = 300}
	end
	app:run()
end)

--check that negative sizes are accepted (and are clamped to (1,1)).
add('pos-init-neg-size', function()
	app:run(function()
		local win = app:window({cw = -1, ch = -1})
		app:sleep(0.1)
		local cw, ch = win:client_size()
		assert(cw >= 1)
		assert(ch >= 1)
	end)
end)

--positioning/screen-client conversions --------------------------------------

--to_screen() and to_screen() conversions work.
local function pos_conv_test(visible)
	return function()
		app:run(function()
			local win = app:window{cx = 100, cy = 100, cw = 400, ch = 400, visible = visible}
			app:sleep(0.1)
			local x, y = win:to_screen(100, 100)
			assert(x == 200)
			assert(y == 200)
			local x, y = win:to_client(x, y)
			assert(x == 100)
			assert(y == 100)
			print'ok'
		end)
	end
end
add('pos-conversions', pos_conv_test(true))
add('pos-conversions-hidden', pos_conv_test(false))

--positioning/window states --------------------------------------------------

--TODO: check that frame_rect() and client_rect() return nil in hidden
--and minimized states; check that setting them is ignored in all but
--normal state.

--TODO: check that {client|frame}_{changed|moved|resized} events are triggered,
--including on state changes; check for nil args on `minimized` and `hidden` events.

--normal_frame_rect ----------------------------------------------------------

--TODO: check that normal_frame_rect() returns correct values in the following cases:
--		initial normal state
--		initial maximized state
--		after maximized
--		after fullscreen
--		after minimized
--		after maximized and minimized

--edge snapping --------------------------------------------------------------

--interactive test: move and resize windows around.
add('demo-pos-snap', function()
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

--size constraints -----------------------------------------------------------

--resize the windows to see the constraints in effect.
add('pos-minmax', function()
app:run(function()

	app:autoquit(false)

	--check that initial constraints are set and the window size respects them.
	local win = app:window{w = 800, h = 800, min_cw = 200, min_ch = 200, max_cw = 400, max_ch = 400,
		maximizable = false, fullscreenable = false}

	app:sleep(0.1)

	local minw, minh = win:minsize()
	assert(minw == 200)
	assert(minh == 200)

	local maxw, maxh = win:maxsize()
	assert(maxw == 400)
	assert(maxh == 400)

	local w, h = win:client_size()
	assert(w == 400)
	assert(h == 400)

	win:close()

	--check that minsize() is set and that it resizes the window.
	local win = app:window{w = 100, h = 100}

	local rec = recorder()
	function win:sizing() rec'error' end
	function win:frame_resized() rec'resized' end

	win:minsize(200, 200)
	app:sleep(0.1)

	rec{'resized'}

	local minw, minh = win:minsize()
	assert(minw == 200)
	assert(minh == 200)

	local w, h = win:client_size()
	assert(w == 200)
	assert(h == 200)

	win:close()

	--check that maxsize() is set and that it resizes the window.
	local win = app:window{w = 800, h = 800, maximizable = false, fullscreenable = false}
	app:sleep(0.1)

	local rec = recorder()
	function win:sizing() rec'error' end
	function win:frame_resized() rec'resized' end

	win:maxsize(400, 400)
	app:sleep(0.1)

	rec{'resized'}

	local maxw, maxh = win:maxsize()
	assert(maxw == 400)
	assert(maxh == 400)

	local w, h = win:client_size()
	assert(w == 400)
	assert(h == 400)

	win:close()

	--check that initial partial constraints work too.
	local win = app:window{w = 800, h = 100, max_cw = 400, min_ch = 200,
		maximizable = false, fullscreenable = false}
	app:sleep(0.1)

	local minw, minh = win:minsize()
	assert(minw == 1)
	assert(minh == 200)

	local maxw, maxh = win:maxsize()
	assert(maxw == 400)
	assert(maxh == nil)

	local w, h = win:client_size()
	assert(w == 400)
	assert(h == 200)

	win:close()

	--check that runtime partial constraints work too.
	local win = app:window{w = 100, h = 800, maximizable = false, fullscreenable = false}

	win:minsize(200, nil)
	app:sleep(0.1)
	local minw, minh = win:minsize()
	assert(minw == 200)
	assert(minh == 1)

	win:maxsize(nil, 400)
	app:sleep(0.1)
	local maxw, maxh = win:maxsize()
	assert(maxw == nil)
	assert(maxh == 400)

	local w, h = win:client_size()
	assert(w == 200)
	assert(h == 400)

	win:close()

	--frame_rect() is constrained too.
	local win = app:window{w = 100, h = 100, min_cw = 200, max_cw = 500, min_ch = 200, max_ch = 500,
		maximizable = false, fullscreenable = false}

	win:frame_rect(nil, nil, 100, 100)
	app:sleep(0.1)
	local w, h = win:client_size()
	assert(w == 200)
	assert(h == 200)

	win:frame_rect(nil, nil, 600, 600)
	app:sleep(0.1)
	local w, h = win:client_size()
	assert(w == 500)
	assert(h == 500)

	win:close()
	--TODO: check that setting minsize/maxize inside sizing() event works.
	--TODO: check that minsize is itself constrained to previously set maxsize and viceversa.
end) --app:run()
end)

--setting maxsize > screen size constrains the window to screen size,
--but the window can be resized to larger than screen size manually.
add('demo-pos-minmax-large-max', function()
	local win = app:window{x = 100, y = 100, w = 10000, h = 10000, max_cw = 10000, max_ch = 10000,
		maximizable = false, fullscreenable = false}
	app:run()
end)

--setting minsize > screen size works.
--it's buggy/slow on both Windows and OSX for very large sizes.
add('demo-pos-minmax-large-min', function()
	local win = app:window{x = 100, y = 100, w = 10000, h = 10000, min_cw = 10000, min_ch = 10000}
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
add('demo-topmost', function()
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
			app:windows()[3]:raise(); assert(not app:windows()[3]:topmost())
			app:windows()[5]:lower(); assert(not app:windows()[5]:topmost())
			app:windows()[8]:raise(); assert(app:windows()[8]:topmost())
			app:windows()[10]:lower(); assert(app:windows()[10]:topmost())
		end)
	end
	app:run()
end)

--displays -------------------------------------------------------------------

--client rect is fully enclosed in screen rect and has a sane size
--client rect has a sane size
local function test_display(display)

	local x, y, w, h = display:screen_rect()
	print('screen_rect ',  x, y, w, h)

	local cx, cy, cw, ch = display:desktop_rect()
	print('desktop_rect', cx, cy, cw, ch)

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
			local x, y = display:screen_rect()
			assert(x == 0)
			assert(y == 0)
		end
	end
	assert(n > 0) --there must be at least 1 display
	assert(n == app:displays'#')
end)

--main_display() returns a valid display.
add('display-main', function()
	local display = app:main_display()
	test_display(display)
end)

--active_display() returns a valid display.
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
	local d = win:display()
	assert(d)
	win:close()

	print'ok'
end)

--display is nil on an off-screen window.
--NOTE: visible=false is because X11 moves off-screen windows back on screen.
add('display-out', function()
	local win = app:window(winpos{x = -5000, y = -5000, frame = 'none', visible = false})
	local x, y = win:frame_rect()
	assert(x == -5000)
	assert(y == -5000)
	assert(not win:display())
	win:close()
	print'ok'
end)

local function test_autoscaling(scaling)
	app:autoscaling(scaling)
	print('wanted autoscaling: ', scaling and 'on' or 'off')
	print('actual autoscaling: ', app:autoscaling() and 'on' or 'off',
		app:autoscaling() ~= scaling and '(failed)' or '')

	for i,d in ipairs(app:displays()) do

		print(string.format('display %d scaling factor:', i), d.scalingfactor)
		print(string.format('display %d rectangle:     ', i), d:screen_rect())

		--create a window on this display and check its dimensions
		local x = d.x + 100
		local y = d.y + 100
		local cw0, ch0 = 300, 200
		local win = app:window{x = x, y = y, cw = cw0, ch = ch0, visible = false}

		--check that the window was indeed created on that monitor even if hidden.
		local d1 = win:display()
		assert(d1.x == d.x)
		assert(d1.y == d.y)

		--check that autoscaling does not affect window's client size.
		local cw, ch = win:client_size()
		assert(cw == cw0)
		assert(ch == ch0)
		print(string.format('window at (%d,%d):', x, y))
		print('', 'display:    ', d:screen_rect())
		print('', 'client size:', win:client_size())

		win:close()
	end
end

add('display-autoscaling-off', function() test_autoscaling(false) end)
add('display-autoscaling-on', function() test_autoscaling(true) end)

--move the window between screens with different scaling factors to see the event.
add('demo-display-scalingfactor-changed', function()
	app:autoscaling(false)
	local win = app:window{cw = 300, ch = 200}
	function win:scalingfactor_changed(factor)
		print('scalingfactor_changed', factor)
	end
	app:runevery(1, function()
		print(string.format('scaling factor: %d, client size: %d x %d', win:display().scalingfactor, win:client_size()))
	end)
	app:run()
end)

--cursors --------------------------------------------------------------------

local cursors = {'arrow', 'text', 'hand', 'cross', 'forbidden', 'size_diag1',
	'size_diag2', 'size_v', 'size_h', 'move', 'busy_arrow'}

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
	local win = app:window(winpos{frame = 'none', transparent = true})
	assert(win:frame() == 'none')
	assert(win:transparent())
end)

--mouse ----------------------------------------------------------------------

--double click time is sane
add('mouse-click-time', function()
	local t = app.backend:double_click_time()
	print('double_click_time', t)
	assert(t > 0 and t < 5)
end)

--target area is sane
add('mouse-click-area', function()
	local w, h = app.backend:double_click_target_area()
	print('double_click_target_area', w, h)
	assert(w > 0 and w < 100)
	assert(h > 0 and h < 100)
end)

local function checkmouse_funcs(win, name)
	function win:mouseenter(x, y)        print(string.format('mouseenter %-10s', name), x, y) end
	function win:mouseleave()            print(string.format('mouseleave %-10s', name)) end
	function win:mousemove(x, y)         print(string.format('mousemove  %-10s', name), x, y) end
	function win:mousedown(button, x, y) print(string.format('mousedown  %-10s', name), button, x, y) end
	function win:mouseup(button, x, y)   print(string.format('mouseup    %-10s', name), button, x, y) end
	function win:click(button, click_count, x, y)
		print(string.format('click      %-10s', name), button, click_count, x, y)
		if click_count == 2 then return true end
	end
	function win:mousewheel(delta, x, y) print('wheel '..name, delta, x, y) end
end

--check that mousemove() event is triggered inside the client area of the active window.
--check that mousemove() event continues outside the client area while at least one mouse button is held.
--check that mouseenter() and mouseleave() events are muted while mouse buttons are pressed.
--[the order of events when moving the mouse between windows is undefined.]
--check that mouseenter() is triggered if the mouse was over the window when the window is shown.
--check that mouseleave() is triggered if the mouse was over the window when the window is hidden.
add('demo-mouse', function()
	local win1 = app:window{x = 100, y = 100, w = 300, h = 200}
	local win2 = app:window{x = 150, y = 150, w = 300, h = 200}
	checkmouse_funcs(win1, 'win1')
	checkmouse_funcs(win2, 'win2')
	app:run()
end)

add('demo-mouse-view', function()
	local function mkwin(name)
		local cw, ch = 400, 200
		local win = app:window{cw=cw, ch=ch}
		local view = win:view{
			x = 10, y = 10,
			w = cw - 20,
			h = ch - 20,
		}
		view:bitmap()
		checkmouse_funcs(win, name)
		checkmouse_funcs(view, name..'.view')
	end
	mkwin'win1'
	mkwin'win2'
	app:run()
end)

--keyboard -------------------------------------------------------------------


add('demo-input', function()
	local win1 = app:window(winpos())
	local win2 = app:window(winpos())

	--mouse
	checkmouse_funcs(win1, 'win1')
	checkmouse_funcs(win2, 'win2')

	--keyboard
	function win1:printkey(title, key, vkey)
		print(string.format('%-16s %-16s %-16s %-16s %-16s',
			title, key, vkey, app:key(key), app:key(vkey)))
	end
	win2.printkey = win1.printkey
	function win1:keydown(key, ...)
		if key == 'N' then
			app:ignore_numlock(not app:ignore_numlock())
		elseif key == 'enter' then
			print(string.format('keyboard state: capslock: %s, numlock: %s, scrolllock: %s',
				tostring(app:key'^capslock'),
				tostring(app:key'^numlock'),
				tostring(app:key'^scrolllock')))
		end
		self:printkey('keydown', key, ...)
		--print(app:key('ctrl+shift+F10'))
	end
	function win1:keypress(...)
		self:printkey('   keypress', ...)
	end
	function win1:keyup(...)
		self:printkey('keyup', ...)
	end
	function win1:keychar(s)
		print(string.format('%-16s %s', '      keychar', s))
	end
	win2.keydown = win1.keydown
	win2.keypress = win1.keypress
	win2.keyup = win1.keyup
	win2.keychar = win1.keychar

	--win2:close()

	app:run()
end)

--views ----------------------------------------------------------------------

add('demo-view-mouse', function()
	local win = app:window{cw = 700, ch = 500}
	local view = win:view{x = 50, y = 50, w = 600, h = 400, anchors = 'ltrb', visible = false}
	function view:repaint()
		view:bitmap():clear()
	end
	view:show()
	function view:event(...)
		print(...)
	end
	app:run()
end)

--NOTE: this indirectly checks get/set rect() too when resizing the window.
add('demo-view-anchors', function()
	local win = app:window{cw = 340, ch = 340, min_cw = 150, min_ch = 150, max_cw = 450, max_ch = 450,
		maximizable = false, fullscreenable = false}
	win:view{x = 10, y = 10, w = 100, h = 100,   anchors = 'tl'}
	win:view{x = 120, y = 10, w = 100, h = 100,  anchors = 'tlr'}
	win:view{x = 230, y = 10, w = 100, h = 100,  anchors = 'tr'}
	win:view{x = 10, y = 120, w = 100, h = 100,  anchors = 'tlb'}
	win:view{x = 120, y = 120, w = 100, h = 100, anchors = 'tlrb'}
	win:view{x = 230, y = 120, w = 100, h = 100, anchors = 'trb'}
	win:view{x = 10, y = 230, w = 100, h = 100,  anchors = 'lb'}
	win:view{x = 120, y = 230, w = 100, h = 100, anchors = 'lrb'}
	win:view{x = 230, y = 230, w = 100, h = 100, anchors = 'br'}
	for i,v in ipairs(win:views()) do
		function v:repaint() self:bitmap():clear() end
	end
	app:run()
end)

--to_screen() and to_screen() conversions work.
local function pos_conv_test(visible)
	return function()
		app:run(function()
			local win = app:window{cx = 100, cy = 100, cw = 400, ch = 400, visible = visible}
			local view = win:view{x = 100, y = 100, w = 200, h = 200}
			app:sleep(0.1)
			local x, y = view:to_screen(100, 100)
			assert(x == 300)
			assert(y == 300)
			local x, y = view:to_client(x, y)
			assert(x == 100)
			assert(y == 100)
			print'ok'
		end)
	end
end
add('pos-view-conversions', pos_conv_test(true))
add('pos-view-conversions-hidden', pos_conv_test(false))

--check that negative sizes are accepted (don't crash)
add('pos-view-init-neg-size', function()
	app:run(function()
		local win = app:window{w = 100, h = 100, visible = false}
		local view = win:view{x = 0, y = 0, w = -1, h = -1}
		app:sleep(0.1)
		print(select(3, view:rect()))
	end)
end)

--rendering ------------------------------------------------------------------

add('demo-render-window-bitmap', function()
	local whiteband = whiteband_animation()
	local win = app:window{x = 200, y = 200, w = 600, h = 300}
	function win:repaint() whiteband(self:bitmap()) end
	app:runevery(1/30, function() win:invalidate() end)
	app:run()
end)

add('demo-render-window-cairo', function()
	local arrows = arrows_animation()
	local win = app:window{x = 200, y = 200, w = 600, h = 300}
	function win:repaint() arrows(self:bitmap():cairo(), self:client_size()) end
	app:runevery(1/30, function() win:invalidate() end)
	app:run()
end)

add('demo-render-window-gl', function()
	local cube = cube_animation()
	local win = app:window{x = 200, y = 200, w = 600, h = 300,
		opengl = {antialiasing = 'multisample', samples = 16}}
	function win:repaint() cube(self:gl(), self:client_size()) end
	app:runevery(1/30, function() win:invalidate() end)
	app:run()
end)

local function render_view_test(gen_view, opengl)
	local cw, ch, q = 600, 600, 300
	local win = app:window{cw = cw, ch = ch, opengl = opengl}
	for y = 0,cw-1,q do
		for x = 0,ch-1,q do
			local r = x == cw-q and 'r' or ''
			local b = y == ch-q and 'b' or ''
			local repaint, opengl = gen_view()
			local view = win:view{x = x, y = y, w = q, h = q, anchors = 'lt'..r..b, opengl = opengl}
			view.repaint = repaint
		end
	end
	app:runevery(1/30, function()
		for i,view in ipairs(win:views()) do
			view:invalidate()
		end
	end)
	app:run()
end

add('demo-render-view-bitmap', function()
	render_view_test(function()
		local whiteband = whiteband_animation()
		return function(self) whiteband(self:bitmap()) end
	end)
end)

add('demo-render-view-cairo', function()
	render_view_test(function()
		local arrows = arrows_animation()
		return function(self) arrows(self:bitmap():cairo(), self:size()) end
	end)
end)

add('demo-render-view-gl', function()
	render_view_test(function()
		local cube = cube_animation()
		return function(self) cube(self:gl(), self:size()) end, true
	end)
end)

add('demo-render-view-mixed', function()
	local i = 0
	render_view_test(function()
		i = i + 1
		if i == 1 then
			local whiteband = whiteband_animation()
			return function(self) whiteband(self:bitmap()) end
		elseif i == 2 then
			local arrows = arrows_animation()
			return function(self) arrows(self:bitmap():cairo(), self:size()) end
		elseif i == 3 then
			local cube = cube_animation()
			return function(self) cube(self:gl(), self:size()) end, true
		end
	end)
end)

--menus ----------------------------------------------------------------------

add('menu', function()

	local function setmenu()
		local win = app:window(winpos{w = 500, h = 300})
		local winmenu = app:ver'Windows' and win:menubar() or app:menubar()
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

		assert(winmenu:items'#' == 3)
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
	local path = app:ver'OSX' and '/' or app:ver'Windows' and 'C:\\'
	local paths = app:opendialog{
		title = 'What do you mean "open him up"?',
		filetypes = {'png', 'jpeg'}, --only if files = true
		multiselect = true,
		path = path,
	}
	pp(paths)
end)

add('dialog-save-default', function()
	print(app:savedialog())
end)

add('dialog-save-custom', function()
	--custom title, custom file types, default file type.
	local path = app:ver'OSX' and '/' or app:ver'Windows' and 'C:\\'
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
		app:ver'OSX' and {'/home', '/na-file1', '/na-dir2/'} or
		app:ver'Windows' and {'C:\\Windows', 'Q:\\na-file1', 'O:\\na-dir2\\'}
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

--run tests ------------------------------------------------------------------

local name = ...
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

