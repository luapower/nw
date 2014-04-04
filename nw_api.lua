--native widgets api class. needs an impl instance to function.
local glue = require'glue'

local nw = {}

function nw:app()
	local app = glue.inherit({}, self.app_class)
	app.impl = self.impl:app()
	app._windows = {}
	return app
end

--app

local app = {}
nw.app_class = app

function app:run()
	if self._running then return end --ignore if already running
	self._running = true
	self.impl:run()
	self._running = nil
end

--close all windows and quit the main loop; abort on the first window that refuses to close
function app:quit()
	for win in self:windows() do
		win:free()
		if not win:dead() then
			break
		end
	end
	self.impl:quit()
end

--monitors

function app:screen_rect()
	return self.impl:screen_rect()
end

function app:client_rect()
	return self.impl:client_rect()
end

--windows

function app:window(t)
	local win = glue.inherit({app = self}, self.window_class)
	win.observers = {}
	win.impl = self.impl:window{
		title = t.title,
		state = t.state,
		x = t.x,
		y = t.y,
		w = t.w,
		h = t.h,
		delegate = win,
	}
	self._windows[win] = true
	--TODO: self._winimpl[win.impl] = win
	if t.visible then
		win:show()
	end
	return win
end

function app:windows()
	return pairs(self._windows)
end

function app:closed(window) end

function app:active_window()
	return self._active_window
end

function app:active()
	self.impl:active()
end

--window

local window = {}
app.window_class = window

--delegate

function window:event(event, ...)
	if event == 'closed' then
		self.app:closed(self)
		self.app._windows[self] = nil
		if not next(self.app._windows) then
			self.app:quit()
		end
	elseif event == 'activated' then
		self.app._active_window = self
	elseif event == 'deactivated' then
		self.app._active_window = nil
	end
	if self.observers[event] then
		for obs in pairs(self.observers[event]) do
			obs(event, ...)
		end
	end
	return self[event](self, ...)
end

--lifetime

function window:free()
	if self:dead() then return end
	self.impl:free()
end

function window:dead()
	return self.app._windows[self] == nil
end

function window:closing() end --return false to prevent closing
function window:closed() end --right before freeing the children

--activation

function window:activate() self.impl:activate() end
function window:active() return self.impl:active() end --true|false
function window:activated() end
function window:deactivated() end

--state

function window:show(state) self.impl:show(state) end --'maximized'|'minimized'|'normal'|'fullscreen'
function window:hide() self.impl:hide() end
function window:visible() return self.impl:visible() end --true|false

function window:state(state)
	if state then
		return self.impl:state() == state
	else
		return self.impl:state()
	end
end --'maximized'|'minimized'|'normal'|'fullscreen'

function window:state_changed() end

--positioning

function window:frame_rect(x, y, w, h) return self.impl:frame_rect(x, y, w, h) end --x, y, w, h
function window:client_rect() return self.impl:client_rect() end --x, y, w, h
function window:frame_changing(how, x, y, w, h) end --move|left|right|top|bottom|topleft|topright|bottomleft|bottomright
function window:moved() end --also called when maximizing/restoring
function window:resized() end --also called when maximizing/restoring

--frame

function window:title(newtitle) return self.impl:title(newtitle) end

--keyboard

function window:key_down(key) end
function window:key_up(key) end
function window:key_press(key) end
function window:key_char(char) end

--mouse

function window:mouse_move(x, y) end
function window:mouse_over() end
function window:mouse_leave() end
function window:mouse_up(button) end
function window:mouse_down(button) end
function window:click(button) end
function window:double_click(button) end
function window:triple_click(button) end
function window:mouse_wheel(delta) end

--trackpad

--

--function window:

--rendering
function window:render() end
function window:invalidate() self.impl:invalidate() end

if not ... then require'nw_demo' end

return nw
