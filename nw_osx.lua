--native widgets osx backend

--cocoa lessons:
--windows are created hidden by default.
--zoom()'ing a hidden window does not show it (but does change its maximized flag).
--orderOut() doesn't hide window if it's the key window (instead it disables mouse on it making it appear frozen).
--makeKeyWindow() and makeKeyAndOrderFront() do the same thing (both bring the window to front).
--isVisible() returns false both when the window is orderOut() and when it's minimized().
--activateIgnoringOtherApps(false) puts windows behind the active app.
--activateIgnoringOtherApps(true) puts windows in front of the active app.
--only the windows made key after the call to activateIgnoringOtherApps(true) are put in front of the active app!
--quitting the app from the app's Dock menu doesn't call windowShouldClose (but does call windowWillClose).
--there's no windowDidClose event so windowDidResignKey comes after windowWillClose.

io.stdout:setvbuf'no'
local glue = require'glue'
local ffi = require'ffi'
assert(ffi.abi'32bit', 'use luajit32 with this')
local objc = require'objc'
--objc.debug = true
local bs = require'objc.BridgeSupport'
bs.loadFramework'Foundation'
bs.loadFramework'AppKit'
bs.loadFramework'System'
bs.loadFramework'CoreServices'

ffi.cdef[[
typedef uint32_t CGDirectDisplayID;
]]

local function unpack_rect(r)
	return r.origin.x, r.origin.y, r.size.width, r.size.height
end

local nw = {}

function nw:app(delegate)
	return self.app_class:new(delegate)
end

--app impl

local app = {}
nw.app_class = app

function app:new(delegate)
	self = glue.inherit({delegate = delegate}, self)

	self.pool = objc.NSAutoreleasePool:new()
	self.nsappclass = objc.createClass(objc.NSApplication, 'NSApp', {})
	self.nsapp = self.nsappclass:sharedApplication()
	self.nsapp.delegate = self.nsapp

	--set it to be a normal app with dock and menu bar
	self.nsapp:setActivationPolicy(bs.NSApplicationActivationPolicyRegular)

	objc.addMethod(self.nsappclass, objc.SEL'applicationShouldTerminate:', function(_, sel, app)
		return self.delegate:event'terminating' ~= false
	end, 'i@:@')

	objc.addMethod(self.nsappclass, objc.SEL'applicationWillTerminate:', function(_, sel, app)
		self.delegate:event'terminated'
	end, 'v@:@')

	return self
end

function app:run()
	self.nsapp:run()
end

function app:activate()
	self.nsapp:activateIgnoringOtherApps(false)
end

function app:quit()
	self.nsapp:terminate(nil)
end

function app:displays()
	local screens = objc.NSScreen:screens()
	local n = screens:count()
	local i = 0
	return function()
		i = i + 1
		if i > n then return end
		return screens:objectAtIndex(i-1)
	end
end

function app:main_display()
	return objc.NSScreen:mainScreen()
end

function app:screen_rect(display)
	return unpack_rect(display:frame())
end

function app:desktop_rect(display)
	return unpack_rect(display:visibleFrame())
end

function app:double_click_time() --milliseconds
	return objc.NSEvent:doubleClickInterval() * 1000
end

function app:double_click_target_area()
	return 4, 4 --like in windows
end

function app:time()
	return bs.mach_absolute_time()
end

function app:timediff(start_time, end_time)
	if not self.timebase then
		self.timebase = ffi.new'mach_timebase_info_data_t'
		bs.mach_timebase_info(self.timebase)
	end
	return tonumber(end_time - start_time) * self.timebase.numer / self.timebase.denom / 10^6
end

function app:window(delegate, t)
	return self.window_class:new(self, delegate, t)
end

--window impl

local window = {}
app.window_class = window

local function name_generator(format)
	local n = 0
	return function()
		n = n + 1
		return string.format(format, n)
	end
end
local gen_classname = name_generator'NSWindow%d'

function window:new(app, delegate, t)
	self = glue.inherit({app = app, delegate = delegate}, self)

	--create the window class which will also be used as the window's delegate

	self.nswinclass = objc.createClass(objc.NSWindow, gen_classname(), {})

	objc.addMethod(self.nswinclass, objc.SEL'windowShouldClose:', function(nswin, sel, sender)
		return self.delegate:event'closing' ~= false
	end, 'B@:@')

	objc.addMethod(self.nswinclass, objc.SEL'windowWillClose:', function(nswin, sel, notification)

		--windowWillClose is sent again if calling app:terminate() in a 'closed' event
		if self._closed then
			return
		end

		--defer closing on deactivation so that 'deactivated' event is sent before it
		if self:active() then
			self._close_on_deactivate = true
		else
			self._closed = true
			self.delegate:event'closed'
			self._dead = true
		end
	end, 'v@:@')

	objc.addMethod(self.nswinclass, objc.SEL'windowDidBecomeKey:', function(nswin, sel, notification)
		self.delegate:event'activated'
	end, 'v@:@')

	objc.addMethod(self.nswinclass, objc.SEL'windowDidResignKey:', function(nswin, sel, notification)
		self.delegate:event'deactivated'

		--check for defered close
		if self._close_on_deactivate then
			self._closed = true
			self.delegate:event'closed'
			self._dead = true
		end

	end, 'v@:@')

	self.nswin = self.nswinclass:alloc():initWithContentRect_styleMask_backing_defer(
						{{t.x, t.y}, {t.w, t.h}},
						t.frame == 'normal' and bit.bor(
							bs.NSTitledWindowMask,
							t.closeable and bs.NSClosableWindowMask or 0,
							t.minimizable and bs.NSMiniaturizableWindowMask or 0,
							t.resizeable and bs.NSResizableWindowMask or 0) or
						t.frame == 'none' and bit.bor(bs.NSBorderlessWindowMask) or
						t.frame == 'transparent' and bit.bor(bs.NSBorderlessWindowMask), --TODO
						bs.NSBackingStoreBuffered,
						false)

	self.nswin.delegate = self.nswin

	self.nswin:setTitle(objc.NSStr(t.title))

	if t.maximized then
		if not self:maximized() then
			self.nswin:zoom(nil) --doesn't show the window if it's not shown
		end
	end

	if t.minimized then
		self._showminimized = true
	end

	return self
end

function window:dead()
	return self._dead
end

function window:close(force)
	if not force then
		if self.delegate:event'closing' ~= false then
			return
		end
	end
	self.nswin:close() --windowShouldClose is not sent here
end

function window:activate()
	self.nswin:makeKeyAndOrderFront(nil)
end

function window:active()
	return self.nswin:isKeyWindow() ~= 0
end

function window:show()
	if self._showminimized then
		self.nswin:miniaturize(nil)
		self._showminimized = nil
		return
	end
	self.nswin:makeKeyAndOrderFront(nil)
end

function window:hide()
	self.nswin:orderOut(nil)
end

function window:minimize()
	self.nswin:miniaturize(nil)
end

function window:maximize()
	if not self:maximized() then
		self.nswin:zoom(nil)
	end
	self:show()
end

function window:restore()
	if self:maximized() then
		self.nswin:zoom(nil)
	elseif self:minimized() then
		self.nswin:deminiaturize()
	end
end

function window:shownormal()
	if self:maximized() then
		self:restore()
	end
	if not self:visible() then
		self:show()
	end
end

function window:visible()
	return self.nswin:isVisible() ~= 0
end

function window:minimized()
	return self.nswin:isMiniaturized() ~= 0
end

function window:maximized()
	return self.nswin:isZoomed() ~= 0
end

function window:display()
	return self.nswin:screen()
end

function window:title(title)
	if title then
		self.nswin:setTitle(NSStr(title))
	else
		return self.nswin:title()
	end
end

--set the api impl and return it

local api = require'nw_api'
api.impl = nw
return api
