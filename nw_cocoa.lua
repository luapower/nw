--native widgets cococa backend

--cocoa lessons:
--windows are created hidden by default.
--zoom()'ing a hidden window does not show it (but does change its maximized flag).
--orderOut() doesn't hide window if it's the key window (instead it disables mouse on it making it appear frozen).
--makeKeyWindow() and makeKeyAndOrderFront() do the same thing (both bring the window to front).
--isVisible() returns false both when the window is orderOut() and when it's minimized().
--activateIgnoringOtherApps(false) puts windows created after behind the active app.
--activateIgnoringOtherApps(true) puts windows created after in front of the active app.
--only the windows made key after the call to activateIgnoringOtherApps(true) are put in front of the active app!
--quitting the app from the app's Dock menu doesn't call windowShouldClose (but does call windowWillClose).
--there's no windowDidClose event so windowDidResignKey comes after windowWillClose.
--screen:visibleFrame() is in virtual screen coordinates just like winapi's MONITORINFO.
--applicationWillTerminate() is never called.

local ffi = require'ffi'
local glue = require'glue'
local objc = require'objc'
local bs = require'objc.BridgeSupport'
bs.loadFramework'Foundation'
bs.loadFramework'AppKit'
bs.loadFramework'System'
bs.loadFramework'CoreServices'

io.stdout:setvbuf'no'
--objc.debug = true

local function unpack_rect(r)
	return r.origin.x, r.origin.y, r.size.width, r.size.height
end

local backend = {}

function backend:app(delegate)
	return self.app_class:new(delegate)
end

--app class

local app = {}
backend.app_class = app

function app:new(delegate)
	self = glue.inherit({delegate = delegate}, self)

	self.pool = objc.NSAutoreleasePool:new()
	self.nsappclass = objc.createClass(objc.NSApplication, 'NSApp', {})
	self.nsapp = self.nsappclass:sharedApplication()
	self.nsapp.delegate = self.nsapp

	--set it to be a normal app with dock and menu bar
	self.nsapp:setActivationPolicy(bs.NSApplicationActivationPolicyRegular)

	objc.addMethod(self.nsappclass, objc.SEL'applicationShouldTerminate:', function(_, sel, app)
		if self.delegate:_backend_quitting() then
			os.exit(self.delegate:_backend_exit())
		end
		return 0
	end, 'i@:@')

	objc.addMethod(self.nsappclass, objc.SEL'applicationDidChangeScreenParameters:', function(_, sel, app)
		self.delegate:_backend_displays_changed()
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

--displays

--convert rect from bottom-up relative-to-main-screen space to top-down relative-to-main-screen space
local function flip_rect(main_h, x, y, w, h)
	return x,  main_h - h - y, w, h
end

local function display(main_h, screen)
	local t = {}
	t.x, t.y, t.w, t.h = flip_rect(main_h, unpack_rect(screen:frame()))
	t.client_x, t.client_y, t.client_w, t.client_h = flip_rect(main_h, unpack_rect(screen:visibleFrame()))
	return t
end

function app:displays()
	objc.NSScreen:mainScreen() --calling this before :screens() prevents a weird NSRecursiveLock error
	local screens = objc.NSScreen:screens()

	--find the main screen in the array (don't query it again because it might be different)
	local main_h
	for i = 0, screens:count()-1 do
		local screen = screens:objectAtIndex(i)
		local frame = screen:frame()
		if frame.origin.x == 0 and frame.origin.y == 0 then --main screen
			main_h = frame.size.height
		end
	end
	assert(main_h)

	--build the list of display objects to return
	local displays = {}
	for i = 0, screens:count()-1 do
		table.insert(displays, display(main_h, screens:objectAtIndex(i)))
	end
	return displays
end

function app:main_display()
	local screen = objc.NSScreen:mainScreen()
	return display(screen:frame().size.height, screen)
end

--double-clicking info

function app:double_click_time() --milliseconds
	return objc.NSEvent:doubleClickInterval() * 1000
end

function app:double_click_target_area()
	return 4, 4 --like in windows
end

--time

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

--window backend

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
		return self.delegate:_backend_closing() and 1 or 0
	end, 'B@:@')

	objc.addMethod(self.nswinclass, objc.SEL'windowWillClose:', function(nswin, sel, notification)
		self._closed = true

		--defer closing on deactivation so that 'deactivated' event is sent before the 'closed' event
		if self:active() then
			self._close_on_deactivate = true
		else
			self.delegate:_backend_closed()
			self._dead = true
		end
	end, 'v@:@')

	objc.addMethod(self.nswinclass, objc.SEL'windowDidBecomeKey:', function(nswin, sel, notification)
		self.delegate:_backend_activated()
	end, 'v@:@')

	objc.addMethod(self.nswinclass, objc.SEL'windowDidResignKey:', function(nswin, sel, notification)
		self.delegate:_backend_deactivated()

		--check for defered close
		if self._close_on_deactivate then
			self.delegate:_backend_closed()
			self._dead = true
		end

	end, 'v@:@')

	local style = t.frame == 'normal' and bit.bor(
							bs.NSTitledWindowMask,
							t.closeable and bs.NSClosableWindowMask or 0,
							t.minimizable and bs.NSMiniaturizableWindowMask or 0,
							t.resizeable and bs.NSResizableWindowMask or 0) or
						t.frame == 'none' and bit.bor(bs.NSBorderlessWindowMask) or
						t.frame == 'transparent' and bit.bor(bs.NSBorderlessWindowMask) --TODO

	local main_h = objc.NSScreen:mainScreen():frame().size.height
	local frame_rect = bs.NSMakeRect(flip_rect(main_h, t.x, t.y, t.w, t.h))
	local content_rect = objc.NSWindow:contentRectForFrameRect_styleMask(frame_rect, style)

	self.nswin = self.nswinclass:alloc():initWithContentRect_styleMask_backing_defer(
											content_rect, style, bs.NSBackingStoreBuffered, false)

	self.nswin:setAcceptsMouseMovedEvents(true)

	if not t.maximizable then

		--emulate windows behavior of hiding the minimize and maximize buttons when they're both disabled
		if not t.minimizable then
			self.nswin:standardWindowButton(bs.NSWindowZoomButton):setHidden(true)
			self.nswin:standardWindowButton(bs.NSWindowMiniaturizeButton):setHidden(true)
		else
			self.nswin:standardWindowButton(bs.NSWindowZoomButton):setEnabled(false)
		end
	end

	self.nswin:setTitle(objc.NSStr(t.title))

	if t.maximized then
		if not self:maximized() then
			self.nswin:zoom(nil) --doesn't show the window if it's not shown
		end
	end

	--enable events
	self.nswin.delegate = self.nswin

	--minimize on the next show()
	if t.minimized then
		self._minimize = true
	end

	return self
end

function window:dead()
	return self._dead
end

function window:close()
	if self._closed then return end
	--because windowShouldClose will not be called...
	if not self.delegate:_backend_closing() then
		return
	end
	self.nswin:close()
end

function window:activate()
	self.nswin:makeKeyAndOrderFront(nil)
end

function window:active()
	return self.nswin:isKeyWindow() ~= 0
end

function window:show()
	if self._minimize then
		self.nswin:miniaturize(nil)
		self._minimize = nil
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

return backend
