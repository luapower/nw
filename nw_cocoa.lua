--native widgets cococa backend (Cosmin Apreutesei, public domain).

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

objc.load'Foundation'
objc.load'AppKit'
objc.load'System'
objc.load'CoreServices'

io.stdout:setvbuf'no'

local function unpack_rect(r)
	return r.origin.x, r.origin.y, r.size.width, r.size.height
end

local backend = {}

function backend:app(api)
	return self.app_class:new(api)
end

--app class

local app = {}
backend.app_class = app

--app init

local NSApp = objc.class('NSApp', 'NSApplication <NSApplicationDelegate>')

function NSApp:applicationShouldTerminate()
	self.api:_backend_quitting() --calls quit() which calls stop()
	return false
end

function NSApp:applicationDidChangeScreenParameters()
	self.api:_backend_displays_changed()
end

function app:new(api)

	self = glue.inherit({api = api}, self)

	self.pool = objc.NSAutoreleasePool:new()

	self.app = NSApp:sharedApplication()
	self.app.api = api

	self.app:setDelegate(self.app)
	--set it to be a normal app with dock and menu bar
	self.app:setActivationPolicy(objc.NSApplicationActivationPolicyRegular)
	self.app:setPresentationOptions(self.app:presentationOptions() + objc.NSApplicationPresentationFullScreen)

	return self
end

--run/quit

function app:run()
	self.app:run()
end

function app:stop()
	self.app:stop(nil)
	--post a dummy event to trigger the stopping
	local event = objc.NSEvent:
		otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2(
			objc.NSApplicationDefined, objc.NSMakePoint(0,0), 0, 0, 0, nil, 1, 1, 1)
	self.app:postEvent_atStart(event, true)
end

--app activation

function app:activate()
	self.app:activateIgnoringOtherApps(true)
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
	return objc.mach_absolute_time()
end

function app:timediff(start_time, end_time)
	if not self.timebase then
		self.timebase = ffi.new'mach_timebase_info_data_t'
		objc.mach_timebase_info(self.timebase)
	end
	return tonumber(end_time - start_time) * self.timebase.numer / self.timebase.denom / 10^6
end

function app:window(api, t)
	return self.window_class:new(self, api, t)
end

--window class

local window = {}
app.window_class = window

--window creation

local NWWindow = objc.class('NWWindow', 'NSWindow <NSWindowDelegate>')

function NWWindow:windowShouldClose()
	return self.api:_backend_closing() or false
end

function NWWindow:windowWillClose()
	--defer closing on deactivation so that 'deactivated' event is sent before the 'closed' event
	if self.win:active() then
		self._close_on_deactivate = true
	else
		self.api:_backend_closed()
	end
end

function NWWindow:windowDidBecomeKey()
	self.api:_backend_activated()
end

function NWWindow:windowDidResignKey()
	self.api:_backend_deactivated()

	--check for defered close
	if self._close_on_deactivate then
		self.api:_backend_closed()
	end
end

--fullscreen mode

function NWWindow:windowWillEnterFullScreen()
	print'enter fullscreen'
	--self.nswin:toggleFullScreen(nil)
	self.nswin:setStyleMask(self.nswin:styleMask() + objc.NSFullScreenWindowMask)
	--self.nswin:contentView():enterFullScreenMode_withOptions(objc.NSScreen:mainScreen(), nil)
end

function NWWindow:windowWillExitFullScreen()
	print'exit fullscreen'
end

function NWWindow:willUseFullScreenPresentationOptions(options)
	print('here1', options)
	return options
end

--TODO: hack
objc.override(NWWindow, 'willUseFullScreenContentSize', function(size)
	print('here2', size)
end, 'd@:@dd')

function NWWindow:customWindowsToEnterFullScreenForWindow()
	return {self}
end

function NWWindow:customWindowsToExitFullScreenForWindow()
	return {self}
end

function window:new(app, api, t)
	self = glue.inherit({app = app, api = api}, self)

	local style = t.frame == 'normal' and bit.bor(
							objc.NSTitledWindowMask,
							t.closeable and objc.NSClosableWindowMask or 0,
							t.minimizable and objc.NSMiniaturizableWindowMask or 0,
							t.resizeable and objc.NSResizableWindowMask or 0) or
						t.frame == 'none' and bit.bor(objc.NSBorderlessWindowMask) or
						t.frame == 'transparent' and bit.bor(objc.NSBorderlessWindowMask) --TODO

	local main_h = objc.NSScreen:mainScreen():frame().size.height
	local frame_rect = objc.NSMakeRect(flip_rect(main_h, t.x, t.y, t.w, t.h))
	local content_rect = objc.NSWindow:contentRectForFrameRect_styleMask(frame_rect, style)

	self.nswin = NWWindow:alloc():initWithContentRect_styleMask_backing_defer(
							content_rect, style, objc.NSBackingStoreBuffered, false)


	if t.fullscreenable then
		self.nswin:setCollectionBehavior(objc.NSWindowCollectionBehaviorFullScreenPrimary)
	end

	if t.parent then
		t.parent.backend.nswin:addChildWindow_ordered(self.nswin, objc.NSWindowAbove)
	end

	self.nswin:setAcceptsMouseMovedEvents(true)

	if not t.maximizable then

		--emulate windows behavior of hiding the minimize and maximize buttons when they're both disabled
		if not t.minimizable then
			self.nswin:standardWindowButton(objc.NSWindowZoomButton):setHidden(true)
			self.nswin:standardWindowButton(objc.NSWindowMiniaturizeButton):setHidden(true)
		else
			self.nswin:standardWindowButton(objc.NSWindowZoomButton):setEnabled(false)
		end
	end

	self.nswin:setTitle(t.title)

	if t.maximized then
		if not self:maximized() then
			self.nswin:zoom(nil) --doesn't show the window if it's not already visible
		end
	end

	--enable events
	self.nswin.api = api
	self.nswin.win = self
	self.nswin:setDelegate(self.nswin)

	self._show_minimized = t.minimized --minimize on the next show()
	self._show_fullscreen = t.fullscreen --fullscreen on the next show()
	self._visible = false

	return self
end

--closing

function window:close()
	self.nswin:close() --doesn't call windowShouldClose
end

--activation

function window:activate()
	if not self._visible then
		self.app:activate() --activate the app but leave the window hidden like in windows
	else
		self.nswin:makeKeyAndOrderFront(nil)
	end
end

function window:active()
	return self.nswin:isKeyWindow()
end

--visibility

function window:show()
	self._visible = true
	if self._show_minimized then
		self._show_minimized = nil
		if self._show_fullscreen then
			self:_enter_fullscreen(true)
		else
			self.nswin:miniaturize(nil)
		end
	else
		if self._show_fullscreen then
			self:_enter_fullscreen()
		else
			self.nswin:makeKeyAndOrderFront(nil)
		end
	end
end

function window:hide()
	self._visible = false
	self.nswin:orderOut(nil)
end

function window:visible()
	return self._visible
end

--state

function window:minimize()
	self._visible = true
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
	return self.nswin:isMiniaturized()
end

function window:maximized()
	return self.nswin:isZoomed()
end

function window:_enter_fullscreen(show_minimized)
	self._show_fullscreen = nil
	self.nswin:toggleFullScreen(nil)
	--self.nswin:setStyleMask(self.nswin:styleMask() + objc.NSFullScreenWindowMask)
	--self.nswin:contentView():enterFullScreenMode_withOptions(objc.NSScreen:mainScreen(), nil)
end

function window:_exit_fullscreen(show_maximized)
	self.nswin:toggleFullScreen(nil)
	--
end

function window:fullscreen(fullscreen)
	if fullscreen ~= nil then
		if fullscreen ~= self:fullscreen() then
			if fullscreen then
				self:_enter_fullscreen()
			else
				self:_exit_fullscreen()
			end
		end
	else
		return self._show_fullscreen or
			bit.band(tonumber(self.nswin:styleMask()), objc.NSFullScreenWindowMask) == objc.NSFullScreenWindowMask
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
