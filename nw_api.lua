--native widgets api class. needs an impl instance to function.
local glue = require'glue'
local box2d = require'box2d'

local nw = {}

--return the singleton app object
function nw:app()
	self._app = self._app or self.app_class:new(self)
	return self._app
end

--app

local app = {}
nw.app_class = app

function app:new(nw)
	self = glue.inherit({nw = nw}, self)
	self._windows = {} --{window1 = true, ...}
	self._window_count = 0
	self.observers = {}
	self.impl = nw.impl:app(self)
	return self
end

--app main loop

--start the main loop. calling this while running or without any windows created is a no op.
function app:run()
	if self._running then return end --ignore if already running
	if self._window_count == 0 then return end --ignore if there are no windows
	self._running = true
	self.impl:run()
	self._running = nil
end

--quit the app and process, closing all the windows first, in unspecified order.
--abort on the first window that refuses to close (unless force == true in which case it doesn't ask).
function app:quit()
	self.impl:quit()
end

--events

local _event = {}

function app:event(event, ...)
	if _event[event] then
		return _event[event](self, ...)
	else
		return self:_dispatch(event, ...)
	end
end

function app:_dispatch(event, ...)
	if self.observers[event] then
		for obs in pairs(self.observers[event]) do
			obs(event, ...)
		end
	end
	if self[event] then
		return self[event](self, ...)
	end
end

--displays

function app:displays()
	return self.impl:displays()
end

function app:main_display()
	return self.impl:main_display()
end

function app:screen_rect(display)
	return self.impl:screen_rect(display)
end

function app:desktop_rect(display)
	return self.impl:desktop_rect(display)
end

--time

function app:time()
	return self.impl:time()
end

function app:timediff(start_time, end_time)
	return self.impl:timediff(start_time, end_time or self:time())
end

--windows

function app:window(t)
	return self.window_class:new(self, t)
end

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
	return self._active_window
end

function app:_add_window(win)
	self._windows[win] = true
	self._window_count = self._window_count + 1
end

function app:_remove_window(win)
	self._windows[win] = nil
	self._window_count = self._window_count - 1
	if self._window_count == 0 then
		self:quit()
	end
end

--window

local window = {}
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

function window:new(app, t)
	t = glue.update({}, self.defaults, t)
	local self = glue.inherit({app = app}, self)

	self.observers = {}
	self.mouse = {}
	self._down = {}

	self.impl = app.impl:window(self, {
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

	self._frame = t.frame
	self._minimizable = t.minimizable
	self._maximizable = t.maximizable
	self._closeable = t.closeable
	self._resizeable = t.resizeable

	app:_add_window(self)

	if t.visible then
		self:show()
	end

	return self
end

--events

local _event = {}

function window:event(event, ...)
	if _event[event] then
		return _event[event](self, ...)
	else
		return self:_dispatch(event, ...)
	end
end

function window:_dispatch(event, ...)
	if self.observers[event] then
		for obs in pairs(self.observers[event]) do
			obs(event, ...)
		end
	end
	if self.app[event] then --TODO: why in this order? why can't app respond to an event with a return value?
		self.app[event](self.app, self, ...)
	end
	if self[event] then
		return self[event](self, ...)
	end
end

--lifetime

function window:close(force)
	if self:dead() then return end
	self.impl:close(force)
end

function window:dead()
	return self.impl:dead()
end

function window:check()
	assert(not self:dead(), 'dead window')
end

function _event:closed()
	self:_dispatch'closed'
	self.app:_remove_window(self)
end

--focus

function window:activate()
	self:check()
	if not self:visible() then return end
	self.impl:activate()
end

function window:active()
	self:check()
	return self.impl:active()
end

function _event:activated()
	self.app._active_window = self
	self:_dispatch'activated'
end

function _event:deactivated()
	self.app._active_window = nil
	self:_dispatch'deactivated'
end

--visibility

function window:visible()
	self:check()
	return self.impl:visible()
end

function window:show()
	self:check()
	self.impl:show()
end

function window:hide()
	self:check()
	self.impl:hide()
end

--minimized/maximized state

function window:minimized()
	self:check()
	return self.impl:minimized()
end

function window:maximized()
	self:check()
	return self.impl:maximized()
end

function window:minimize()
	self:check()
	self.impl:minimize()
end

function window:maximize()
	self:check()
	self.impl:maximize()
end

function window:restore()
	self:check()
	self.impl:restore()
end

function window:shownormal()
	self:check()
	self.impl:shownormal()
end

--fullscreen mode

function window:fullscreen(fullscreen)
	self:check()
	return self.impl:fullscreen(fullscreen)
end

--positioning

function window:frame_rect(x, y, w, h) --x, y, w, h
	self:check()
	return self.impl:frame_rect(x, y, w, h)
end

function window:client_rect() --x, y, w, h
	self:check()
	return self.impl:client_rect()
end

--frame, behavior

function window:title(newtitle)
	self:check()
	return self.impl:title(newtitle)
end

function window:topmost(topmost)
	self:check()
	return self.impl:topmost(topmost)
end

function window:frame() self:check(); return self._frame end
function window:minimizable() self:check(); return self._minimizable end
function window:maximizable() self:check(); return self._maximizable end
function window:closeable() self:check(); return self._closeable end
function window:resizeable() self:check(); return self._resizeable end

--displays

function window:display()
	self:check()
	return self.impl:display()
end

function window:screen_rect()
	self:check()
	return self.app:screen_rect(self:display())
end

function window:desktop_rect()
	self:check()
	return self.app:desktop_rect(self:display())
end

--keyboard

function window:key(key) --down[, toggled]
	self:check()
	return self.impl:key(key)
end

--mouse

function _event:mousedown(button)
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
		t.interval = self.app.impl:double_click_time()
		t.w, t.h = self.app.impl:double_click_target_area()
		t.x = self.mouse.x - t.w / 2
		t.y = self.mouse.y - t.h / 2
	end

	self:_dispatch('mousedown', button)

	if self:event('click', button, t.count) then
		t.count = 0
	end
end

--rendering

function window:invalidate()
	self:check()
	self.impl:invalidate()
end


if not ... then require'nw_demo' end

return nw
