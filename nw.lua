--native widgets (Cosmin Apreutesei, public domain).
local glue = require'glue'
local ffi = require'ffi'
local box2d = require'box2d'

local nw = {}

--default backends for each OS
nw.backends = {
	Windows = 'nw_winapi',
	OSX = 'nw_cocoa',
}

--return the singleton app object.
--load a default backend on the first call if no backend was set by the user.
function nw:app()
	if not self._app then
		if not self.backend then
			self.backend = require(assert(self.backends[ffi.os], 'NYI'))
		end
		self._app = self.app_class:_new(self)
	end
	return self._app
end

--base class

local object = {}

--poor man's overriding sugar. example:
--		win:override('mousemove', function(self, inherited, x, y)
--			inherited(self, x, y)
--		end)
function object:override(name, func)
	local inherited = self[name]
	self[name] = function(...)
		return func(inherited, ...)
	end
end

--register an observer to be called for a specific event
function object:observe(event, func)
	self.observers = self.observers or {} --{event = {func = true, ...}}
	self.observers[event] = self.observers[event] or {}
	self.observers[event][func] = true
end

--handle a query event by calling its event handler
function object:_handle(event, ...)
	if not self[event] then return end
	return self[event](self, ...)
end

--fire an event, i.e. call observers and create a meta event 'event'
function object:_fire(event, ...)
	--call any observers
	if self.observers and self.observers[event] then
		for obs in pairs(self.observers[event]) do
			obs(self, ...)
		end
	end
	--fire the meta-event 'event'
	if event ~= 'event' then
		self:_event('event', event, ...)
	end
end

--handle and fire a non-query event
function object:_event(event, ...)
	self:_handle(event, ...)
	self:_fire(event, ...)
end

--app class

local app = glue.update({}, object)
nw.app_class = app

function app:_new(nw)
	self = glue.inherit({nw = nw}, self)
	self._windows = {} --{window1 = true, ...}
	self._window_count = 0
	self.backend = self.nw.backend:app(self)
	return self
end

--run/quit

--start the main loop. calling this while running or without any windows created is a no op.
function app:run()
	if self._running then return end --ignore if already running
	if self._window_count == 0 then return end --ignore if there are no windows
	self._running = true
	self.backend:run()
	assert(false) --can't reach here
end

function app:running()
	return self._running
end

function app:check()
	assert(self:running(), 'app not running')
end

--quit the app and process, closing all windows first, in unspecified order, without asking for confirmation.
--the reason for not asking for confirmation is because clicking Quit from the Dock on OSX doesn't ask either,
--so since the user can do that, the app must handle this.
function app:quit()
	if not self:running() then return end --ignore if not running
	self.backend:quit()
end

function app:_backend_quitting()
	--close all windows
	for win in self:windows() do
		win:close()
	end
	--if there are no more windows, the app can be terminated
	return self._window_count == 0
end

function app:_backend_exit()
	local exit_code = self:_handle'exit' or 0
	self:_fire('exit', exit_code)
	return exit_code
end

--activation

function app:_backend_activated()
	self:_event'activated'
end

function app:_backend_deactivated()
	self:_event'deactivated'
end

--displays

local display = {}
app.display_class = display

function display:_new(t)
	return glue.inherit(t, self)
end

function display:rect()
	return self.x, self.y, self.w, self.h
end

function display:client_rect()
	return self.client_x, self.client_y, self.client_w, self.client_h
end

function app:displays()
	local displays = self.backend:displays()
	local i = 0
	return function()
		i = i + 1
		local display = displays[i]
		if not display then return end
		return self.display_class:_new(display)
	end
end

function app:main_display()
	return self.display_class:_new(self.backend:main_display())
end

function app:_backend_displays_changed()
	self:_event'displays_changed'
end

--time

function app:time()
	return self.backend:time()
end

function app:timediff(start_time, end_time)
	return self.backend:timediff(start_time, end_time or self:time())
end

--windows

--iterate existing windows in unspecified order with a stable iterator.
function app:windows()
	local windows = glue.update({}, self._windows) --take a snapshot
	local win
	return function()
		win = next(windows, win)
		return win
	end
end

function app:window_count()
	return self._window_count
end

function app:active_window()
	if self._active_window then
		assert(self._active_window:active())
	end
	return self._active_window
end

--window protocol

function app:_window_created(win)
	self._windows[win] = true
	self._window_count = self._window_count + 1

	self:_event('window_created', win)
end

function app:_window_closed(win)
	self:_event('window_closed', win)

	self._windows[win] = nil
	self._window_count = self._window_count - 1

	if self._window_count == 0 then
		self:quit()
	end
end

function app:_window_activated(win)
	self._active_window = win
end

function app:_window_deactivated(win)
	self._active_window = nil
end

--window class

function app:window(t)
	return self.window_class:_new(self, t)
end

local window = glue.update({}, object)
app.window_class = window

window.defaults = {
	--state
	visible = true,
	minimized = false,
	fullscreen = false,
	maximized = false,
	--frame
	title = '',
	frame = 'normal', --normal, none, transparent
	--behavior
	topmost = false,
	minimizable = true,
	maximizable = true,
	closeable = true,
	resizeable = true,
}

function window:_new(app, t)
	t = glue.update({}, self.defaults, t)
	self = glue.inherit({app = app}, self)

	self.mouse = {}
	self._down = {}

	self.backend = self.app.backend:window(self, {
		--state
		x = t.x,
		y = t.y,
		w = t.w,
		h = t.h,
		minimized = t.minimized,
		fullscreen = t.fullscreen,
		maximized = t.maximized,
		--frame
		title = t.title,
		frame = t.frame,
		--behavior
		topmost = t.topmost,
		minimizable = t.minimizable,
		maximizable = t.maximizable,
		closeable = t.closeable,
		resizeable = t.resizeable,
	})

	--r/o properties
	self._frame = t.frame
	self._minimizable = t.minimizable
	self._maximizable = t.maximizable
	self._closeable = t.closeable
	self._resizeable = t.resizeable

	app:_window_created(self)
	self:_event'created'

	--windows are created hidden
	if t.visible then
		self:show()
	end

	return self
end

--lifetime

function window:close()
	if self:dead() then return end
	self.backend:close()
end

function window:dead()
	return self.backend:dead()
end

function window:check()
	assert(not self:dead(), 'dead window')
end

function window:_backend_closing()
	local allow = self:_handle'closing' ~= false
	self:_fire('closing', allow)
	return allow
end

function window:_backend_closed()
	self:_event'closed'
	self.app:_window_closed(self)
end

--focus

function window:activate()
	self:check()
	if not self:visible() then return end
	self.backend:activate()
end

function window:active()
	self:check()
	return self.backend:active()
end

function window:_backend_activated()
	self.app:_window_activated(self)
	self:_event'activated'
end

function window:_backend_deactivated()
	self:_event'deactivated'
	self.app:_window_deactivated(self)
end

--visibility

function window:visible()
	self:check()
	return self.backend:visible()
end

function window:show()
	self:check()
	self.backend:show()
end

function window:hide()
	self:check()
	self.backend:hide()
end

--state

function window:minimized()
	self:check()
	return self.backend:minimized()
end

function window:maximized()
	self:check()
	return self.backend:maximized()
end

function window:minimize()
	self:check()
	self.backend:minimize()
end

function window:maximize()
	self:check()
	self.backend:maximize()
end

function window:restore()
	self:check()
	self.backend:restore()
end

function window:shownormal()
	self:check()
	self.backend:shownormal()
end

function window:fullscreen(fullscreen)
	self:check()
	return self.backend:fullscreen(fullscreen)
end

function window:_backend_maximized()
	self:_event'maximized'
end

function window:_backend_minimized()
	self:_event'minimized'
end

--positioning

function window:frame_rect(x, y, w, h) --x, y, w, h
	self:check()
	return self.backend:frame_rect(x, y, w, h)
end

function window:client_rect() --x, y, w, h
	self:check()
	return self.backend:client_rect()
end

function window:_backend_resizing(how, x, y, w, h)
	local x1, y1, w1, h1 = x, y, w, h
	if self.resizing then
		x1, y1, w1, h1 = self:_handle('resizing', how, x, y, w, h)
	end
	self:_fire('resizing', how, x, y, w, h, x1, y1, w1, h1)
	return x1, y1, w1, h1
end

function window:_backend_resized()
	self:_event'resized'
end

function window:display()
	self:check()
	return self.display_class:_new(self.backend:display())
end

--frame, behavior

function window:title(newtitle)
	self:check()
	return self.backend:title(newtitle)
end

function window:topmost(topmost)
	self:check()
	return self.backend:topmost(topmost)
end

function window:frame() self:check(); return self._frame end
function window:minimizable() self:check(); return self._minimizable end
function window:maximizable() self:check(); return self._maximizable end
function window:closeable() self:check(); return self._closeable end
function window:resizeable() self:check(); return self._resizeable end

--keyboard

function window:key(key) --down[, toggled]
	self:check()
	return self.backend:key(key)
end

function window:_backend_keydown(key)
	self:_event('keydown', key)
end

function window:_backend_keypress(key)
	self:_event('keypress', key)
end

function window:_backend_keyup(key)
	self:_event('keyup', key)
end

function window:_backend_keydown(key)
	self:_event('keydown', key)
end

function window:_backend_keychar(char)
	self:_event('keychar', char)
end

--mouse

function window:_backend_mousedown(button)
	local t = self._down[button]
	if not t then
		t = {count = 0}
		self._down[button] = t
	end

	if t.count > 0
		and self.app:timediff(t.time) < t.interval
		and box2d.hit(self.mouse.x, self.mouse.y, t.x, t.y, t.w, t.h)
	then
		t.count = t.count + 1
		t.time = self.app:time()
	else
		t.count = 1
		t.time = self.app:time()
		t.interval = self.app.backend:double_click_time()
		t.w, t.h = self.app.backend:double_click_target_area()
		t.x = self.mouse.x - t.w / 2
		t.y = self.mouse.y - t.h / 2
	end

	self:_event('mousedown', button)

	local reset = false
	if self.click then
		reset = self:click(button, t.count)
	end
	self:_fire('click', button, t.count, reset)
	if reset then
		t.count = 0
	end
end

function window:_backend_mouseup(button)
	self:_event('mouseup', button)
end

function window:_backend_mouseenter()
	self:_event('mouseenter')
end

function window:_backend_mouseleave()
	self:_event('mouseleave')
end

function window:_backend_mousemove(x, y)
	self:_event('mousemove', x, y)
end

--rendering

function window:invalidate()
	self:check()
	self.backend:invalidate()
end

function window:_backend_render(cr)
	self:_event('render', cr)
end

if not ... then require'nw_demo' end

return nw
