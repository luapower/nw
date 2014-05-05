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
--quitting the app from the app's Dock menu (or calling terminate(nil)) calls appShouldTerminate, then calls close()
--on all windows, thus without calling windowShouldClose, but only windowWillClose.
--there's no windowDidClose event and so windowDidResignKey comes after windowWillClose.
--screen:visibleFrame() is in virtual screen coordinates just like winapi's MONITORINFO.
--applicationWillTerminate() is never called.
--terminate() doesn't return, unless applicationShouldTerminate returns false
--creating and closing a window and not starting the app loop at all segfaults on exit (is this TLC or cocoa?).

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

--app init

function app:new(delegate)
	self = glue.inherit({delegate = delegate}, self)

	self.pool = objc.NSAutoreleasePool:new()
	self.nsappclass = objc.createClass(objc.NSApplication, 'NSApp', {})
	self.nsapp = self.nsappclass:sharedApplication()
	self.nsapp.delegate = self.nsapp

	--set it to be a normal app with dock and menu bar
	self.nsapp:setActivationPolicy(bs.NSApplicationActivationPolicyRegular)

	objc.addMethod(self.nsappclass, objc.SEL'applicationShouldTerminate:', function(_, sel, app)
		self.delegate:_backend_quit() --calls quit() which exits the process or returns which means refusal to quit.
		return 0
	end, 'i@:@')

	objc.addMethod(self.nsappclass, objc.SEL'applicationDidChangeScreenParameters:', function(_, sel, app)
		self.delegate:_backend_displays_changed()
	end, 'v@:@')

	self.nsapp:setPresentationOptions(self.nsapp:presentationOptions() + bs.NSApplicationPresentationFullScreen)

	return self
end

--run/quit

function app:run()
	self.nsapp:run()
end

function app:quit()
	os.exit(self.delegate:_backend_exit())
end

--app activation

function app:activate()
	self.nsapp:activateIgnoringOtherApps(false)
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
	objc.NSScreen:mainScreen() --calling this before calling screens() prevents a weird NSRecursiveLock error
	local screens = objc.NSScreen:screens()

	--get main_h from the screens snapshot array
	local frame = screens:objectAtIndex(0):frame() --main screen always comes first
	assert(frame.origin.x == 0 and frame.origin.y == 0) --main screen alright
	local main_h = frame.size.height

	--build the list of display objects to return
	local displays = {}
	for i = 0, tonumber(screens:count()-1) do
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

--window class

local window = {}
app.window_class = window

--window creation

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
		--defer closing on deactivation so that 'deactivated' event is sent before the 'closed' event
		if self:active() then
			self._close_on_deactivate = true
		else
			self.delegate:_backend_closed()
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
		end
	end, 'v@:@')

	--fullscreen mode

	objc.addMethod(self.nswinclass, objc.SEL'windowWillEnterFullScreen:', function(nswin, sel, notification)
		print'enter fullscreen'
		--self.nswin:toggleFullScreen(nil)
		self.nswin:setStyleMask(self.nswin:styleMask() + bs.NSFullScreenWindowMask)
		--self.nswin:contentView():enterFullScreenMode_withOptions(objc.NSScreen:mainScreen(), nil)
	end, 'v@:@')

	objc.addMethod(self.nswinclass, objc.SEL'windowWillExitFullScreen:', function(nswin, sel, notification)
		print'exit fullscreen'
	end, 'v@:@')

	objc.addMethod(self.nswinclass, objc.SEL'willUseFullScreenPresentationOptions:', function(nswin, sel, options)
		print('here1', options)
		return options
	end, 'l@:@')

	objc.addMethod(self.nswinclass, objc.SEL'willUseFullScreenContentSize:', function(nswin, sel, size)
		print('here2', size)
	end, 'd@:@dd')

	objc.addMethod(self.nswinclass, objc.SEL'customWindowsToEnterFullScreenForWindow:', function(nswin, sel)
		return objc.NSArray:arrayWithObject(nswin)
	end, '@@:@')

	objc.addMethod(self.nswinclass, objc.SEL'customWindowsToExitFullScreenForWindow:', function(nswin, sel)
		return objc.NSArray:arrayWithObject(nswin)
	end, '@@:@')

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


	if t.fullscreenable then
		self.nswin:setCollectionBehavior(bs.NSWindowCollectionBehaviorFullScreenPrimary)
	end

	if t.parent then
		t.parent.backend.nswin:addChildWindow_ordered(self.nswin, bs.NSWindowAbove)
	end

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

--closing

function window:close()
	self.nswin:close() --doesn't call windowShouldClose
end

--activation

function window:activate()
	self.nswin:makeKeyAndOrderFront(nil)
end

function window:active()
	return self.nswin:isKeyWindow() ~= 0
end

--visibility

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

function window:visible()
	return self.nswin:isVisible() ~= 0
end

--state

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

function window:minimized()
	return self.nswin:isMiniaturized() ~= 0
end

function window:maximized()
	return self.nswin:isZoomed() ~= 0
end

function window:fullscreen(fullscreen)
	if fullscreen == nil then
		return bit.band(tonumber(self.nswin:styleMask()), bs.NSFullScreenWindowMask) == bs.NSFullScreenWindowMask
	else
		if fullscreen ~= self:fullscreen() then
			print'going fullscreen'
			--self.nswin:toggleFullScreen(nil)
			--self.nswin:setStyleMask(self.nswin:styleMask() + bs.NSFullScreenWindowMask)
			--self.nswin:contentView():enterFullScreenMode_withOptions(objc.NSScreen:mainScreen(), nil)
		end
	end
end

--frame

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

if not ... then require'nw_test' end

return backend
