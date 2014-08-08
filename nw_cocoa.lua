
--native widgets - cococa backend.
--Written by Cosmin Apreutesei. Public domain.

local ffi = require'ffi'
local bit = require'bit'
local glue = require'glue'
local box2d = require'box2d'
local objc = require'objc'
local cbframe = require'cbframe'

local _cbframe = objc.debug.cbframe
objc.debug.cbframe = true --use cbframe for struct-by-val overrides.
objc.load'Foundation'
objc.load'AppKit'
objc.load'System' --for mach_absolute_time
objc.load'Carbon.HIToolbox' --for key codes
objc.load'ApplicationServices.CoreGraphics'
--objc.load'CoreGraphics' --for CGWindow*
objc.load'CoreFoundation' --for CFArray

local nw = {name = 'cocoa'}

--helpers --------------------------------------------------------------------

local function unpack_nsrect(r)
	return r.origin.x, r.origin.y, r.size.width, r.size.height
end

local function override_rect(x, y, w, h, x1, y1, w1, h1)
	return x1 or x, y1 or y, w1 or w, h1 or h
end

local function main_screen_h()
	return objc.NSScreen:mainScreen():frame().size.height
end

--convert rect from bottom-up relative-to-main-screen space to top-down relative-to-main-screen space
local function flip_screen_rect(main_h, x, y, w, h)
	main_h = main_h or main_screen_h()
	return x, main_h - h - y, w, h
end

--os version -----------------------------------------------------------------

function nw:os()
	local s = objc.tolua(objc.NSProcessInfo:processInfo():operatingSystemVersionString()) --OSX 10.2+
	return 'OSX '..(s:match'%d+%.%d+%.%d+')
end

--app object -----------------------------------------------------------------

local app = {}
nw.app = app

local App = objc.class('App', 'NSApplication <NSApplicationDelegate>')

function app:new(frontend)

	self = glue.inherit({frontend = frontend}, self)

	--create the default autorelease pool for small objects.
	self.pool = objc.NSAutoreleasePool:new()

	--TODO: we have to reference mainScreen() before using any of the the display functions,
	--or we will get NSRecursiveLock errors.
	objc.NSScreen:mainScreen()

	self.nsapp = App:sharedApplication()
	self.nsapp.frontend = frontend
	self.nsapp.backend = self

	self.nsapp:setDelegate(self.nsapp)

	--set it to be a normal app with dock and menu bar.
	self.nsapp:setActivationPolicy(objc.NSApplicationActivationPolicyRegular)

	--disable mouse coalescing so that mouse move events are not skipped.
	objc.NSEvent:setMouseCoalescingEnabled(false)

	--NOTE: the app's menu bar _and_ the app menu (the first menu item) must be created
	--before the app is activated, otherwise the app menu title will be replaced with
	--a little apple icon to your desperation!
	local menubar = objc.NSMenu:new()
	menubar:setAutoenablesItems(false)
	self.nsapp:setMainMenu(menubar)
	ffi.gc(menubar, nil)
	local appmenu = objc.NSMenu:new()
	local appmenuitem = objc.NSMenuItem:new()
	appmenuitem:setSubmenu(appmenu)
	ffi.gc(appmenu, nil)
	menubar:addItem(appmenuitem)
	ffi.gc(appmenuitem, nil)

	--activate the app before windows are created.
	self:activate()

	return self
end

--message loop ---------------------------------------------------------------

function app:run()
	self.nsapp:run()
end

function app:stop()
	self.nsapp:stop(nil)
	--post a dummy event to ensure the stopping
	local event = objc.NSEvent:
		otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2(
			objc.NSApplicationDefined, objc.NSMakePoint(0,0), 0, 0, 0, nil, 1, 1, 1)
	self.nsapp:postEvent_atStart(event, true)
end

--quitting -------------------------------------------------------------------

--NOTE: quitting the app from the app's Dock menu calls appShouldTerminate, then calls close()
--on all windows, thus without calling windowShouldClose(), but only windowWillClose().
--NOTE: there's no windowDidClose() event and so windowDidResignKey() comes after windowWillClose().
--NOTE: applicationWillTerminate() is never called.

function App:applicationShouldTerminate()
	self.frontend:_backend_quitting() --calls quit() which calls stop().
	--we never terminate the app, we just stop the loop instead.
	return false
end

--time -----------------------------------------------------------------------

function app:time()
	return objc.mach_absolute_time()
end

local timebase
function app:timediff(start_time, end_time)
	if not timebase then
		timebase = ffi.new'mach_timebase_info_data_t'
		objc.mach_timebase_info(timebase)
	end
	return tonumber(end_time - start_time) * timebase.numer / timebase.denom / 10^6
end

--timers ---------------------------------------------------------------------

objc.addmethod('App', 'nw_timerEvent', function(self, timer)
	if not timer.nw_func then return end
	if timer.nw_func() == false then
		timer:invalidate()
		timer.nw_func = nil
	end
end, 'v@:@')

function app:runevery(seconds, func)
	local timer = objc.NSTimer:scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
		seconds, self.nsapp, 'nw_timerEvent', nil, true)
	objc.NSRunLoop:currentRunLoop():addTimer_forMode(timer, objc.NSDefaultRunLoopMode)
	timer.nw_func = func
end

--windows --------------------------------------------------------------------

local window = {}
app.window = window

local nswin_map = {} --nswin->window

local Window = objc.class('Window', 'NSWindow <NSWindowDelegate>')

--NOTE: windows are created hidden by default.

function window:new(app, frontend, t)
	self = glue.inherit({app = app, frontend = frontend}, self)

	local framed = t.frame == 'normal'
	local transparent = t.frame == 'none-transparent'

	local style
	if framed then
		style = bit.bor(
			objc.NSTitledWindowMask,
			t.closeable and objc.NSClosableWindowMask or 0,
			t.minimizable and objc.NSMiniaturizableWindowMask or 0,
			t.resizeable and objc.NSResizableWindowMask or 0)
	else
		style = objc.NSBorderlessWindowMask
		--for borderless windows we have to handle maximization manually.
		self._borderless = true
		self._maximized = false
	end

	local frame_rect = objc.NSMakeRect(flip_screen_rect(nil, t.x, t.y, t.w, t.h))
	local content_rect = objc.NSWindow:contentRectForFrameRect_styleMask(frame_rect, style)

	self.nswin = Window:alloc():initWithContentRect_styleMask_backing_defer(
							content_rect, style, objc.NSBackingStoreBuffered, false)
	ffi.gc(self.nswin, nil) --disown, the user owns it now

	if transparent then
		self.nswin:setOpaque(false)
		self.nswin:setBackgroundColor(objc.NSColor:clearColor())
	end

	if t.parent then
		t.parent.backend.nswin:addChildWindow_ordered(self.nswin, objc.NSWindowAbove)
	end

	if t.edgesnapping then
		self.nswin:setMovable(false)
	end

	if t.fullscreenable and nw.frontend:os'OSX 10.7' then
		self.nswin:setCollectionBehavior(bit.bor(tonumber(self.nswin:collectionBehavior()),
			objc.NSWindowCollectionBehaviorFullScreenPrimary)) --OSX 10.7+
	end

	if not t.maximizable then
		if not t.minimizable then
			--hide the minimize and maximize buttons when they're both disabled
			--to emulate Windows behavior.
			self.nswin:standardWindowButton(objc.NSWindowZoomButton):setHidden(true)
			self.nswin:standardWindowButton(objc.NSWindowMiniaturizeButton):setHidden(true)
		else
			self.nswin:standardWindowButton(objc.NSWindowZoomButton):setEnabled(false)
		end
	end

	self.nswin:setTitle(t.title)

	self.nswin:reset_keystate()

	local opts = bit.bor(
		objc.NSTrackingActiveInKeyWindow,
		objc.NSTrackingInVisibleRect,
		objc.NSTrackingMouseEnteredAndExited,
		objc.NSTrackingMouseMoved,
		objc.NSTrackingCursorUpdate)
	local rect = self.nswin:contentView():bounds()
	local area = objc.NSTrackingArea:alloc():initWithRect_options_owner_userInfo(
		rect, opts, self.nswin:contentView(), nil)
	self.nswin:contentView():addTrackingArea(area)

	if t.maximized then
		self:_set_maximized()
	end

	--set drawable content view
	self:_set_content_view()

	--set window state
	self._visible = false

	--set back references
	self.nswin.frontend = frontend
	self.nswin.backend = self
	self.nswin.app = app

	--register window
	nswin_map[objc.nptr(self.nswin)] = self.frontend

	--set topmost
	if t.topmost then
		self:set_topmost(true)
	end

	--enable events
	self.nswin:setDelegate(self.nswin)

	return self
end

--closing --------------------------------------------------------------------

function window:forceclose()
	self.nswin:close() --doesn't call windowShouldClose
end

function Window:windowShouldClose()
	return self.frontend:_backend_closing() or false
end

function window:_close()
	self.frontend:_backend_closed()
	nswin_map[objc.nptr(self.nswin)] = nil
	self.nswin = nil
end

function Window:windowWillClose()
	--defer closing on deactivation so that 'deactivated' event is sent before the 'closed' event
	if self.backend:active() then
		self.nw_close_on_deactivate = true
	else
		self.backend:_close()
	end
end

--activation -----------------------------------------------------------------

function app:activate()
	--NOTE: windows created after calling activateIgnoringOtherApps(false) go behind the active app.
	--NOTE: windows created after calling activateIgnoringOtherApps(true) go in front of the active app.
	--NOTE: the first call to nsapp:activateIgnoringOtherApps() doesn't also activate the main menu.
	--but NSRunningApplication:currentApplication():activateWithOptions() does, so we use that instead!
	objc.NSRunningApplication:currentApplication():activateWithOptions(bit.bor(
		objc.NSApplicationActivateIgnoringOtherApps,
		objc.NSApplicationActivateAllWindows))
end

function app:active_window()
	return nswin_map[objc.nptr(self.nsapp:keyWindow())]
end

function app:active()
	return self.nsapp:isActive()
end

function App:applicationWillBecomeActive()
	self.frontend:_backend_activated()
end

--NOTE: applicationDidResignActive() is not sent on exit because the loop will be stopped at that time.
function App:applicationDidResignActive()
	self.frontend:_backend_deactivated()
end

function Window:windowDidBecomeKey()
	self:reset_keystate()
	self.frontend:_backend_activated()
end

function Window:windowDidResignKey()
	self.dragging = false
	self:reset_keystate()
	self.frontend:_backend_deactivated()

	--check for deferred close
	if self.nw_close_on_deactivate then
		self.backend:_close()
	end
end

function window:activate()
	--NOTE: makeKeyAndOrderFront() on an initially hidden window is ignored, but not on an orderOut() window.
	--NOTE: makeKeyWindow() and makeKeyAndOrderFront() do the same thing (both bring the window to front).
	--NOTE: makeKeyAndOrderFront() is deferred, if the app is not active, for when it becomes active.
	--Only windows activated while the app is inactive will move to front when the app is activated,
	--but other windows will not, unlike clicking the dock icon, which moves all the app's window in front.
	--So only the windows made key after the call to activateIgnoringOtherApps(true) are moved to front!
	--NOTE: makeKeyAndOrderFront() is deferred to after the message loop is started,
	--after which a single windowDidBecomeKey is triggered on the last window made key,
	--unlike Windows which activates/deactivates windows as it happens, without a message loop.
	self.nswin:makeKeyAndOrderFront(nil)
end

function window:active()
	return self.nswin:isKeyWindow()
end

function Window:canBecomeKeyWindow()
	--this is because windows with NSBorderlessWindowMask can't become key by default.
	return true
end

function Window:canBecomeMainWindow()
	--this is because windows with NSBorderlessWindowMask can't become main by default.
	return true
end

--state/visibility -----------------------------------------------------------

function window:visible()
	--can't use isVisible() because it also returns false when the window is minimized.
	return self._visible
end

function window:_set_visible(visible)
	if self._visible == visible then return end
	self._visible = visible
	if visible then
		self.frontend:_backend_shown()
	else
		self.frontend:_backend_hidden()
	end
	return true
end

function window:show()
	if not self:_set_visible(true) then return end
	if self._show_minimized then --was minimized before hiding
		self._show_minimized = false
		self.nswin:miniaturize(nil)
	elseif self:minimized() then --is minimized but hidden
		self:minimize()
	else
		self.nswin:makeKeyAndOrderFront(nil)
	end
end

function window:hide()
	if not self:_set_visible(false) then return end
	self._show_minimized = self.nswin:isMiniaturized()
	--TODO: orderOut() doesn't hide a window if it's the key window, instead it acts all weird:
	--it disables mouse on it making it appear frozen.
	self.nswin:orderOut(nil)
end

--state/minimization ---------------------------------------------------------

function window:minimized()
	return self._show_minimized or self.nswin:isMiniaturized()
end

function window:minimize()
	self:_set_visible(true)
	--miniaturize() in fullscreen mode is ignored.
	--miniaturize() shows the window if hidden.
	self.nswin:miniaturize(nil)
end

function Window:windowDidMiniaturize()
	self.frontend:_backend_minimized()
end

function Window:windowDidDeminiaturize()
	self.frontend:_backend_unminimized()
end

--state/maximization ---------------------------------------------------------

function window:maximized()
	if self._borderless or self:fullscreen() then
		--NSWindow:isZoomed() returns true for borderless windows.
		--NSWindow:isZoomed() returns true in fullscreen windows.
		return self._maximized
	else
		return self.nswin:isZoomed()
	end
end

--make a window maximized without showing it.
function window:_set_maximized()
	self._restore_rect = {self:get_normal_rect()}
	if self._borderless then
		self:set_normal_rect(self:display():client_rect())
		self._maximized = true
	elseif not self:maximized() then
		if self:minimized() then
			--zoom() on a minimized window is ignored completely.
			self:set_normal_rect(self:display():client_rect())
		else
			--zoom() on a hidden window does not show it, but does maximize it.
			--zoom() in fullscreen mode does nothing.
			self.nswin:zoom(nil)
		end
	end
end

function window:maximize()
	self:_start_frame_change()
	self:_set_maximized()
	if self:minimized() then
		self:restore()
	else
		self:show()
	end
	self:_end_frame_change()
end

function window:_start_frame_change()
	self._started_maximized = self:maximized()
end

function window:_end_frame_change()
	if self._started_maximized == self:maximized() then return end
	if self._started_maximized then
		self._started_maximized = false
		self.frontend:_backend_unmaximized()
	else
		self._started_maximized = true
		self.frontend:_backend_maximized()
	end
end

--state/restoration ----------------------------------------------------------

function window:restore()
	if self:minimized() then
		self:_set_visible(true)
		self._show_minimized = false
		--deminiaturize() shows the window if it's hidden.
		self.nswin:deminiaturize(nil)
	elseif self:maximized() then
		if self._borderless then
			self._maximized = false
			self:set_normal_rect(unpack(self._restore_rect))
			self._restore_rect = nil
			self:show()
		else
			self:_start_frame_change()
			self.nswin:zoom(nil)
			--zoom() on a hidden window does not show it.
			self:show()
			self:_end_frame_change()
		end
	elseif not self:visible() then
		self:show()
	end
end

function window:shownormal()
	if self:minimized() then
		if self:maximized() then
			self:_start_frame_change()
			self._maximized = false
			self:set_normal_rect(unpack(self._restore_rect))
			self:restore()
			self:_end_frame_change()
		else
			self:restore()
		end
	elseif self:maximized() then
		self:restore()
	end
	if not self:visible() then
		self:show()
	end
end

--state/fullscreen mode ------------------------------------------------------

function window:fullscreen()
	return bit.band(tonumber(self.nswin:styleMask()), objc.NSFullScreenWindowMask) == objc.NSFullScreenWindowMask
end

function window:enter_fullscreen()
	self.nswin:makeKeyAndOrderFront(nil)
	self.nswin:toggleFullScreen(nil)
end

function window:exit_fullscreen()
	if not self:visible() then
		self:show()
	end
	self.nswin:toggleFullScreen(nil)
end

function Window:windowWillEnterFullScreen()
	self.nw_stylemask = self:styleMask()
	self.nw_frame = self:frame()
	self:setStyleMask(bit.bor(
		objc.NSFullScreenWindowMask,
		objc.NSBorderlessWindowMask
	))
	self:setFrame_display(self:screen():frame(), true)
end

function Window:windowDidEnterFullScreen()
	self.frontend:_backend_entered_fullscreen()
end

function Window:windowWillExitFullScreen()
	self:setStyleMask(self.nw_stylemask)
	self:setFrame_display(self.nw_frame, true)
end

function Window:windowDidExitFullScreen()
	--window will exit fullscreen before closing. suppress that.
	if self.frontend:dead() then return end
	self.frontend:_backend_exited_fullscreen()
end

--positioning ----------------------------------------------------------------

--NOTE: no event is triggered while moving a window. frame() is not updated either.
--NOTE: there's no API to get the corner or side that window is dragged by when resized.

function window:get_frame_rect()
	return flip_screen_rect(nil, unpack_nsrect(self.nswin:frame()))
end

function window:get_normal_rect(x, y, w, h)
	if self._borderless and self._maximized then
		return unpack(self._restore_rect)
	else
		return flip_screen_rect(nil, unpack_nsrect(self.nswin:frame()))
	end
end

function window:set_normal_rect(x, y, w, h)
	if self._borderless and self._maximized then
		self._restore_rect = {x, y, w, h}
	else
		self.nswin:setFrame_display(objc.NSMakeRect(flip_screen_rect(nil, x, y, w, h)), true)
	end
end

function window:get_client_rect()
	return unpack_nsrect(self.nswin:contentView():bounds())
end

function window:magnets()
	local t = {} --{{x=, y=, w=, h=}, ...}

	local opt = bit.bor(
		objc.kCGWindowListOptionOnScreenOnly,
		objc.kCGWindowListExcludeDesktopElements)

	local nswin_number = tonumber(self.nswin:windowNumber())
	local list = objc.CGWindowListCopyWindowInfo(opt, nswin_number) --front-to-back order assured

	--a glimpse into the mind of a Cocoa (or Java, .Net, etc.) programmer...
	local bounds = ffi.new'CGRect[1]'
	for i = 0, tonumber(objc.CFArrayGetCount(list)-1) do
		local entry = ffi.cast('id', objc.CFArrayGetValueAtIndex(list, i)) --entry is NSDictionary
		local sharingState = entry:objectForKey(ffi.cast('id', objc.kCGWindowSharingState)):intValue()
		if sharingState ~= objc.kCGWindowSharingNone then --filter out windows we can't read from
			local layer = entry:objectForKey(ffi.cast('id', objc.kCGWindowLayer)):intValue()
			local number = entry:objectForKey(ffi.cast('id', objc.kCGWindowNumber)):intValue()
			if layer <= 0 and number ~= nswin_number then --ignore system menu, dock, etc.
				local boundsEntry = entry:objectForKey(ffi.cast('id', objc.kCGWindowBounds))
				objc.CGRectMakeWithDictionaryRepresentation(ffi.cast('CFDictionaryRef', boundsEntry), bounds)
				local x, y, w, h = unpack_nsrect(bounds[0]) --already flipped
				t[#t+1] = {x = x, y = y, w = w, h = h}
			end
		end
	end

	objc.CFRelease(ffi.cast('id', list))

	return t
end

function Window:nw_clientarea_hit(event)
	local mp = event:locationInWindow()
	local rc = self:contentView():bounds()
	return box2d.hit(mp.x, mp.y, unpack_nsrect(rc))
end

local buttons = {
	objc.NSWindowCloseButton,
	objc.NSWindowMiniaturizeButton,
	objc.NSWindowZoomButton,
	objc.NSWindowToolbarButton,
	objc.NSWindowDocumentIconButton,
	objc.NSWindowDocumentVersionsButton,
	objc.NSWindowFullScreenButton,
}
function Window:nw_titlebar_buttons_hit(event)
	for i,btn in ipairs(buttons) do
		local button = self:standardWindowButton(btn)
		if button then
			if button:hitTest(button:superview():convertPoint_fromView(event:locationInWindow(), nil)) then
				return true
			end
		end
	end
end

local function resize_area_hit(mx, my, w, h)
	local co = 15 --corner offset
	local mo = 4 --margin offset
	if box2d.hit(mx, my, box2d.offset(co, 0, 0, 0, 0)) then
		return 'bottomleft'
	elseif box2d.hit(mx, my, box2d.offset(co, w, 0, 0, 0)) then
		return 'bottomright'
	elseif box2d.hit(mx, my, box2d.offset(co, 0, h, 0, 0)) then
		return 'topleft'
	elseif box2d.hit(mx, my, box2d.offset(co, w, h, 0, 0)) then
		return 'topright'
	elseif box2d.hit(mx, my, box2d.offset(mo, 0, 0, w, 0)) then
		return 'bottom'
	elseif box2d.hit(mx, my, box2d.offset(mo, 0, h, w, 0)) then
		return 'top'
	elseif box2d.hit(mx, my, box2d.offset(mo, 0, 0, 0, h)) then
		return 'left'
	elseif box2d.hit(mx, my, box2d.offset(mo, w, 0, 0, h)) then
		return 'right'
	end
end

function Window:nw_resize_area_hit(event)
	local mp = event:locationInWindow()
	local _, _, w, h = unpack_nsrect(self:frame())
	return resize_area_hit(mp.x, mp.y, w, h)
end

function window:set_edgesnapping(snapping)
	self.nswin:setMovable(not snapping)
end

function Window:sendEvent(event)
	if self.frontend:edgesnapping() then
		--take over window dragging by the titlebar so that we can post moving events
		local etype = event:type()
		if self.dragging then
			if etype == objc.NSLeftMouseDragged then
				self:setmouse(event)
				local mx = self.frontend._mouse.x - self.dragpoint_x
				local my = self.frontend._mouse.y - self.dragpoint_y
				local x, y, w, h = flip_screen_rect(nil, unpack_nsrect(self:frame()))
				x = x + mx
				y = y + my
				local x1, y1, w1, h1 = self.frontend:_backend_resizing('move', x, y, w, h)
				if x1 or y1 or w1 or h1 then
					self:setFrame_display(objc.NSMakeRect(flip_screen_rect(nil,
						override_rect(x, y, w, h, x1, y1, w1, h1))), false)
				else
					self:setFrameOrigin(mp)
				end
				return
			elseif etype == objc.NSLeftMouseUp then
				self.dragging = false
				self.mousepos = nil
				self.frontend:_backend_end_resize'move'
				self.backend:_end_frame_change()
				return
			end
		elseif etype == objc.NSLeftMouseDown
			and not self:nw_clientarea_hit(event)
			and not self:nw_titlebar_buttons_hit(event)
			and not self:nw_resize_area_hit(event)
		then
			self.backend:_start_frame_change()
			self:setmouse(event)
			self:makeKeyAndOrderFront(nil)
			self.app:activate()
			self.dragging = true
			self.dragpoint_x = self.frontend._mouse.x
			self.dragpoint_y = self.frontend._mouse.y
			self.frontend:_backend_start_resize'move'
			return
		elseif etype == objc.NSLeftMouseDown then
			self:makeKeyAndOrderFront(nil)
			self.mousepos = event:locationInWindow() --for resizing
		end
	end
	objc.callsuper(self, 'sendEvent', event)
end

--also triggered on maximize.
function Window:windowWillStartLiveResize()
	self.backend:_start_frame_change()
	if not self.mousepos then
		self.mousepos = self:mouseLocationOutsideOfEventStream()
	end
	local mx, my = self.mousepos.x, self.mousepos.y
	local _, _, w, h = unpack_nsrect(self:frame())
	self.how = resize_area_hit(mx, my, w, h)
	self.frontend:_backend_start_resize(self.how)
end

--also triggered on maximize.
function Window:windowDidEndLiveResize()
	self.frontend:_backend_end_resize()
	self.backend:_end_frame_change()
end

function Window:nw_resizing(w_, h_)
	if not self.how then return w_, h_ end
	local x, y, w, h = flip_screen_rect(nil, unpack_nsrect(self:frame()))
	if self.how:find'top' then y, h = y + h - h_, h_ end
	if self.how:find'bottom' then h = h_ end
	if self.how:find'left' then x, w = x + w - w_, w_ end
	if self.how:find'right' then w = w_ end
	local x1, y1, w1, h1 = self.frontend:_backend_resizing(self.how, x, y, w, h)
	if x1 or y1 or w1 or h1 then
		x, y, w, h = flip_screen_rect(nil, override_rect(x, y, w, h, x1, y1, w1, h1))
	end
	return w, h
end

function Window.windowWillResize_toSize(cpu)
	if ffi.arch == 'x64' then
		--RDI = self, XMM0 = NSSize.x, XMM1 = NSSize.y
		local self = ffi.cast('id', cpu.RDI.p)
		local w = cpu.XMM[0].lo.f
		local h = cpu.XMM[1].lo.f
		w, h = self:nw_resizing(w, h)
		--return double-only structs <= 8 bytes in XMM0:XMM1
		cpu.XMM[0].lo.f = w
		cpu.XMM[1].lo.f = h
	else
		--ESP[1] = self, ESP[2] = selector, ESP[3] = sender, ESP[4] = NSSize.x, ESP[5] = NSSize.y
		local self = ffi.cast('id', cpu.ESP.dp[1].p)
		w = cpu.ESP.dp[4].f
		h = cpu.ESP.dp[5].f
		w, h = self:nw_resizing(w, h)
		--return values <= 8 bytes in EAX:EDX
		cpu.EAX.f = w
		cpu.EDX.f = h
	end
end

function Window:windowDidResize()
	self.frontend:_backend_resized()
end

function Window:windowWillMove()
	self.backend:_start_frame_change()
end

function Window:windowDidMove()
	self.backend:_end_frame_change()
end

--z-order --------------------------------------------------------------------

function window:get_topmost()
	return self.nswin:level() == objc.NSFloatingWindowLevel
end

function window:set_topmost(topmost)
	if topmost then
		self.nswin:setLevel(objc.NSFloatingWindowLevel)
	else
		self.nswin:setLevel(objc.NSNormalWindowLevel)
	end
end

local modes = {front = objc.NSWindowAbove, back = objc.NSWindowBelow}

function window:set_zorder(zorder, relto)
	self.nswin:orderWindow_relativeTo(modes[zorder], relto and relto.backend.nswin or 0)
end

--titlebar -------------------------------------------------------------------

function window:get_title(title)
	return objc.tolua(self.nswin:title())
end

function window:set_title(title)
	self.nswin:setTitle(title)
end

--displays -------------------------------------------------------------------

--NOTE: screen:visibleFrame() is in virtual screen coordinates just like winapi's MONITORINFO, which is what we want.
function app:_display(main_h, screen)
	local t = {}
	t.x, t.y, t.w, t.h = flip_screen_rect(main_h, unpack_nsrect(screen:frame()))
	t.client_x, t.client_y, t.client_w, t.client_h = flip_screen_rect(main_h, unpack_nsrect(screen:visibleFrame()))
	return self.frontend:_display(t)
end

function app:displays()
	local screens = objc.NSScreen:screens()

	--get main_h from the screens snapshot array
	local frame = screens:objectAtIndex(0):frame() --main screen always comes first
	assert(frame.origin.x == 0 and frame.origin.y == 0) --main screen alright
	local main_h = frame.size.height

	--build the list of display objects to return
	local displays = {}
	for i = 0, tonumber(screens:count()-1) do
		table.insert(displays, self:_display(main_h, screens:objectAtIndex(i)))
	end
	return displays
end

function app:main_display()
	local screen = objc.NSScreen:mainScreen()
	return self:_display(nil, screen)
end

function app:display_count()
	return objc.NSScreen:screens():count()
end

function window:display()
	return self.app:_display(nil, self.nswin:screen())
end

function App:applicationDidChangeScreenParameters()
	self.frontend:_backend_displays_changed()
end

--cursors --------------------------------------------------------------------

--NOTE: can't reference resizing cursors directly with constants, hence load_hicursor().

local cursors = {
	--pointers
	arrow = 'arrowCursor',
	ibeam = 'IBeamCursor',
	hand  = 'openHandCursor',
	cross = 'crosshairCursor',
	--app state
	busy  = 'busyButClickableCursor', --undocumented, whatever
}

local hi_cursors = {
	--pointers
	no    = 'notallowed',
	--move and resize
	nesw  = 'resizenortheastsouthwest',
	nwse  = 'resizenorthwestsoutheast',
	ew    = 'resizeeastwest',
	ns    = 'resizenorthsouth',
	move  = 'move',
}

local load_hicursor = objc.memoize(function(name)
	basepath = basepath or (objc.findframework'ApplicationServices.HIServices' .. '/Versions/Current/Resources/cursors')
	local curpath = string.format('%s/%s/cursor.pdf', basepath, name)
	local infopath = string.format('%s/%s/info.plist', basepath, name)
	local image = objc.NSImage:alloc():initByReferencingFile(curpath)
	local info = objc.NSDictionary:dictionaryWithContentsOfFile(infopath)
	local hotx = info:objectForKey('hotx'):doubleValue()
	local hoty = info:objectForKey('hoty'):doubleValue()
	return objc.NSCursor:alloc():initWithImage_hotSpot(image, objc.NSMakePoint(hotx, hoty))
end)

local function setcursor(name)
	if cursors[name] then
		objc.NSCursor[cursors[name]](objc.NSCursor):set()
	elseif hi_cursors[name] then
		load_hicursor(hi_cursors[name]):set()
	end
end

function window:cursor(name)
	if name ~= nil then
		if self._cursor == name then return end
		self._cursor = name
		self.nswin:invalidateCursorRectsForView(self.nswin:contentView()) --trigger cursorUpdate
	else
		return self._cursor
	end
end

function Window:cursorUpdate(event)
	if self:nw_clientarea_hit(event) then
		setcursor(self.backend._cursor)
	else
		objc.callsuper(self, 'cursorUpdate', event)
	end
end

--keyboard -------------------------------------------------------------------


--NOTE: there's no keyDown() for modifier keys, must use flagsChanged().
--NOTE: flagsChanged() returns undocumented, and possibly not portable bits to distinguish
--between left/right modifier keys. these bits are not given with NSEvent:modifierFlags(),
--so we can't get the initial state of specific modifier keys.
--NOTE: there's no keyDown() on the 'help' key (which is the 'insert' key on a win keyboard).
--NOTE: flagsChanged() can only get you so far in simulating keyDown/keyUp events for the modifier keys:
--  holding down these keys won't trigger repeated key events.
--  can't know when capslock is depressed, only when it is pressed.

local keynames = {

	[objc.kVK_ANSI_0] = '0',
	[objc.kVK_ANSI_1] = '1',
	[objc.kVK_ANSI_2] = '2',
	[objc.kVK_ANSI_3] = '3',
	[objc.kVK_ANSI_4] = '4',
	[objc.kVK_ANSI_5] = '5',
	[objc.kVK_ANSI_6] = '6',
	[objc.kVK_ANSI_7] = '7',
	[objc.kVK_ANSI_8] = '8',
	[objc.kVK_ANSI_9] = '9',

	[objc.kVK_ANSI_A] = 'A',
	[objc.kVK_ANSI_B] = 'B',
	[objc.kVK_ANSI_C] = 'C',
	[objc.kVK_ANSI_D] = 'D',
	[objc.kVK_ANSI_E] = 'E',
	[objc.kVK_ANSI_F] = 'F',
	[objc.kVK_ANSI_G] = 'G',
	[objc.kVK_ANSI_H] = 'H',
	[objc.kVK_ANSI_I] = 'I',
	[objc.kVK_ANSI_J] = 'J',
	[objc.kVK_ANSI_K] = 'K',
	[objc.kVK_ANSI_L] = 'L',
	[objc.kVK_ANSI_M] = 'M',
	[objc.kVK_ANSI_N] = 'N',
	[objc.kVK_ANSI_O] = 'O',
	[objc.kVK_ANSI_P] = 'P',
	[objc.kVK_ANSI_Q] = 'Q',
	[objc.kVK_ANSI_R] = 'R',
	[objc.kVK_ANSI_S] = 'S',
	[objc.kVK_ANSI_T] = 'T',
	[objc.kVK_ANSI_U] = 'U',
	[objc.kVK_ANSI_V] = 'V',
	[objc.kVK_ANSI_W] = 'W',
	[objc.kVK_ANSI_X] = 'X',
	[objc.kVK_ANSI_Y] = 'Y',
	[objc.kVK_ANSI_Z] = 'Z',

	[objc.kVK_ANSI_Semicolon]    = ';',
	[objc.kVK_ANSI_Equal]        = '=',
	[objc.kVK_ANSI_Comma]        = ',',
	[objc.kVK_ANSI_Minus]        = '-',
	[objc.kVK_ANSI_Period]       = '.',
	[objc.kVK_ANSI_Slash]        = '/',
	[objc.kVK_ANSI_Grave]        = '`',
	[objc.kVK_ANSI_LeftBracket]  = '[',
	[objc.kVK_ANSI_Backslash]    = '\\',
	[objc.kVK_ANSI_RightBracket] = ']',
	[objc.kVK_ANSI_Quote]        = '\'',

	[objc.kVK_Delete] = 'backspace',
	[objc.kVK_Tab]    = 'tab',
	[objc.kVK_Space]  = 'space',
	[objc.kVK_Escape] = 'esc',
	[objc.kVK_Return] = 'enter!',

	[objc.kVK_F1]  = 'F1',
	[objc.kVK_F2]  = 'F2',
	[objc.kVK_F3]  = 'F3',
	[objc.kVK_F4]  = 'F4',
	[objc.kVK_F5]  = 'F5',
	[objc.kVK_F6]  = 'F6',
	[objc.kVK_F7]  = 'F7',
	[objc.kVK_F8]  = 'F8',
	[objc.kVK_F9]  = 'F9',
	[objc.kVK_F10] = 'F10',
	[objc.kVK_F11] = 'F11', --taken on mac (show desktop)
	[objc.kVK_F12] = 'F12', --taken on mac (show dashboard)

	[objc.kVK_CapsLock] = 'capslock',

	[objc.kVK_LeftArrow]     = 'left!',
	[objc.kVK_UpArrow]       = 'up!',
	[objc.kVK_RightArrow]    = 'right!',
	[objc.kVK_DownArrow]     = 'down!',

	[objc.kVK_PageUp]        = 'pageup!',
	[objc.kVK_PageDown]      = 'pagedown!',
	[objc.kVK_Home]          = 'home!',
	[objc.kVK_End]           = 'end!',
	[objc.kVK_Help]          = 'help', --mac keyboard; 'insert!' key on win keyboard; no keydown, only keyup
	[objc.kVK_ForwardDelete] = 'delete!',

	[objc.kVK_ANSI_Keypad0] = 'num0',
	[objc.kVK_ANSI_Keypad1] = 'num1',
	[objc.kVK_ANSI_Keypad2] = 'num2',
	[objc.kVK_ANSI_Keypad3] = 'num3',
	[objc.kVK_ANSI_Keypad4] = 'num4',
	[objc.kVK_ANSI_Keypad5] = 'num5',
	[objc.kVK_ANSI_Keypad6] = 'num6',
	[objc.kVK_ANSI_Keypad7] = 'num7',
	[objc.kVK_ANSI_Keypad8] = 'num8',
	[objc.kVK_ANSI_Keypad9] = 'num9',
	[objc.kVK_ANSI_KeypadDecimal]  = 'num.',
	[objc.kVK_ANSI_KeypadMultiply] = 'num*',
	[objc.kVK_ANSI_KeypadPlus]     = 'num+',
	[objc.kVK_ANSI_KeypadMinus]    = 'num-',
	[objc.kVK_ANSI_KeypadDivide]   = 'num/',
	[objc.kVK_ANSI_KeypadEquals]   = 'num=',     --mac keyboard
	[objc.kVK_ANSI_KeypadEnter]    = 'numenter',
	[objc.kVK_ANSI_KeypadClear]    = 'numclear', --mac keyboard; 'numlock' key on win keyboard

	[objc.kVK_Mute]       = 'mute',
	[objc.kVK_VolumeDown] = 'volumedown',
	[objc.kVK_VolumeUp]   = 'volumeup',

	[110] = 'menu', --win keyboard

	[objc.kVK_F13] = 'F11', --taken (show desktop)
	[objc.kVK_F14] = 'F12', --taken (show the wachamacalit wall with the calendar and clock)
	[objc.kVK_F13] = 'F13', --mac keyboard; win keyboard 'printscreen' key
	[objc.kVK_F14] = 'F14', --mac keyboard; win keyboard 'scrolllock' key; taken (brightness down)
	[objc.kVK_F15] = 'F15', --mac keyboard; win keyboard 'break' key; taken (brightness up)
	[objc.kVK_F16] = 'F16', --mac keyboard
	[objc.kVK_F17] = 'F17', --mac keyboard
	[objc.kVK_F18] = 'F18', --mac keyboard
	[objc.kVK_F15] = 'F19', --mac keyboard
}

local keycodes = {}
for vk, name in pairs(keynames) do
	keycodes[name:lower()] = vk
end

local function modifier_flag(mask, flags)
	flags = flags or tonumber(objc.NSEvent:modifierFlags())
	return bit.band(flags, mask) ~= 0
end

local function capslock_state(flags)
	return modifier_flag(objc.NSAlphaShiftKeyMask, flags)
end

local keystate
local capsstate

function Window:reset_keystate()
	--note: platform-dependent flagbits are not given with NSEvent:modifierFlags() nor with GetKeys(),
	--so we can't get the initial state of specific modifier keys.
	keystate = {}
	capsstate = capslock_state()
end

local function keyname(event)
	local keycode = event:keyCode()
	return keynames[keycode]
end

function Window:keyDown(event)
	local key = keyname(event)
	if not key then return end
	if not event:isARepeat() then
		self.frontend:_backend_keydown(key)
	end
	self.frontend:_backend_keypress(key)
end

function Window:keyUp(event)
	local key = keyname(event)
	if not key then return end
	if key == 'help' then --simulate the missing keydown for the help/insert key
		self.frontend:_backend_keydown(key)
	end
	self.frontend:_backend_keyup(key)
end

local flagbits = {
	--undocumented bits tested on a macbook with US keyboard
	lctrl    = 2^0,
	lshift   = 2^1,
	rshift   = 2^2,
	lcommand = 2^3, --'lwin' key on PC keyboard
	rcommand = 2^4, --'rwin' key on PC keyboard; 'altgr' key on german PC keyboard
	lalt     = 2^5,
	ralt     = 2^6,
	--bits for PC keyboard
	rctrl    = 2^13,
}

function Window:flagsChanged(event)
	--simulate key pressing for capslock
	local newcaps = capslock_state()
	local oldcaps = capsstate
	if newcaps ~= oldcaps then
		capsstate = newcaps
		keystate.capslock = true
		self.frontend:_backend_keydown'capslock'
		keystate.capslock = false
		self.frontend:_backend_keyup'capslock'
	end

	--detect keydown/keyup state change for modifier keys
	local flags = tonumber(event:modifierFlags())
	for name, mask in pairs(flagbits) do
		local oldstate = keystate[name] or false
		local newstate = bit.band(flags, mask) ~= 0
		if oldstate ~= newstate then
			keystate[name] = newstate
			if newstate then
				self.frontend:_backend_keydown(name)
				self.frontend:_backend_keypress(name)
			else
				self.frontend:_backend_keyup(name)
			end
		end
	end
end

local alt_names = { --ambiguous keys that have a single physical key mapping on mac
	left     = 'left!',
	up       = 'up!',
	right    = 'right!',
	down     = 'down!',
	pageup   = 'pageup!',
	pagedown = 'pagedown!',
	['end']  = 'end!',
	home     = 'home!',
	insert   = 'insert!',
	delete   = 'delete!',
	enter    = 'enter!',
}

local keymap, pkeymap

function window:key(name)
	if name == '^capslock' then
		return capsstate
	elseif name == 'capslock' then
		return keystate.capslock
	elseif name == 'shift' then
		return keystate.lshift or keystate.rshift or false
	elseif name == 'ctrl' then
		return keystate.lctrl or keystate.rctrl or false
	elseif name == 'alt' then
		return keystate.lalt or keystate.ralt or false
	elseif name == 'command' then
		return keystate.lcommand or keystate.rcommand or false
	elseif flagbits[name] then --get modifier saved state
		return keystate[name] or false
	else --get normal key state
		local keycode = keycodes[name] or keycodes[alt_names[name]]
		if not keycode then return false end
		keymap  = keymap or ffi.new'unsigned char[16]'
		pkeymap = pkeymap or ffi.cast('void*', keymap)
		objc.GetKeys(pkeymap)
		return bit.band(bit.rshift(keymap[bit.rshift(keycode, 3)], bit.band(keycode, 7)), 1) ~= 0
	end
end

--mouse ----------------------------------------------------------------------

function app:double_click_time() --milliseconds
	return objc.NSEvent:doubleClickInterval() * 1000
end

function app:double_click_target_area()
	return 4, 4 --like in windows
end

function window:_flip_y(y)
	return self.nswin:contentView():frame().size.height - y --flip y around contentView's height
end

function Window:setmouse(event)
	local m = self.frontend._mouse
	local pos = event:locationInWindow()
	m.x = pos.x
	m.y = self.backend:_flip_y(pos.y)
	local btns = tonumber(event:pressedMouseButtons())
	m.left = bit.band(btns, 1) ~= 0
	m.right = bit.band(btns, 2) ~= 0
	m.middle = bit.band(btns, 4) ~= 0
	m.ex1 = bit.band(btns, 8) ~= 0
	m.ex2 = bit.band(btns, 16) ~= 0
	return m
end

function Window:mouseDown(event)
	local m = self:setmouse(event)
	self.frontend:_backend_mousedown('left', m.x, m.y)
end

function Window:mouseUp(event)
	local m = self:setmouse(event)
	self.frontend:_backend_mouseup('left', m.x, m.y)
end

function Window:rightMouseDown(event)
	local m = self:setmouse(event)
	self.frontend:_backend_mousedown('right', m.x, m.y)
end

function Window:rightMouseUp(event)
	local m = self:setmouse(event)
	self.frontend:_backend_mouseup('right', m.x, m.y)
end

local other_buttons = {'', 'middle', 'ex1', 'ex2'}

function Window:otherMouseDown(event)
	local btn = other_buttons[tonumber(event:buttonNumber())]
	if not btn then return end
	local m = self:setmouse(event)
	self.frontend:_backend_mousedown(btn, m.x, m.y)
end

function Window:otherMouseUp(event)
	local btn = other_buttons[tonumber(event:buttonNumber())]
	if not btn then return end
	local m = self:setmouse(event)
	self.frontend:_backend_mouseup(btn, m.x, m.y)
end

function Window:mouseMoved(event)
	local m = self:setmouse(event)
	self.frontend:_backend_mousemove(m.x, m.y)
end

function Window:mouseDragged(event)
	self:mouseMoved(event)
end

function Window:rightMouseDragged(event)
	self:mouseMoved(event)
end

function Window:otherMouseDragged(event)
	self:mouseMoved(event)
end

function Window:mouseEntered(event)
	self:setmouse(event)
	self.frontend:_backend_mouseenter()
end

function Window:mouseExited(event)
	self:setmouse(event)
	self.frontend:_backend_mouseleave()
end

function Window:scrollWheel(event)
	local m = self:setmouse(event)
	local x, y = m.x, m.y
	local dx = event:deltaX()
	if dx ~= 0 then
		self.frontend:_backend_mousehwheel(dx, x, y)
	end
	local dy = event:deltaY()
	if dy ~= 0 then
		self.frontend:_backend_mousewheel(dy, x, y)
	end
end

function window:mouse_pos()
	--return objc.NSEvent:
end

--rendering ------------------------------------------------------------------

ffi.cdef[[
void* malloc (size_t size);
void  free   (void*);
]]

local View = objc.class('View', 'NSView')

function View.drawRect(cpu)

	--get arg1 from the ABI guts.
	local self
	if ffi.arch == 'x64' then
		self = ffi.cast('id', cpu.RDI.p) --RDI = self
	else
		self = ffi.cast('id', cpu.ESP.dp[1].p) --ESP[1] = self
	end

	--let the user acquire the window's bitmap and draw on it.
	self.nw_frontend:_backend_repaint()

	--if bitmap acquired, paint it on the current graphics context.
	self.nw_backend:_paint_bitmap()
end

function window:_set_content_view()
	--create our custom view and set it as the content view.
	local bounds = self.nswin:contentView():bounds()
	self.nsview = View:alloc():initWithFrame(bounds)
	self.nswin:setContentView(self.nsview)
	self.nsview.nw_backend = self
	self.nsview.nw_frontend = self.frontend
end

function window:bitmap()

	local _, _, w, h = self.frontend:client_rect()

	--we can't create a zero-sized bitmap.
	if w <= 0 or h <= 0 then
		self:_free_bitmap()
		return
	end

	return self:_get_bitmap(w, h)
end

local function stub() end

function window:_get_bitmap(w, h)
	return self:_create_bitmap(w, h)
end

function window:_create_bitmap(w, h)

	local stride = w * 4
	local size = stride * h

	local data = ffi.C.malloc(size)
	assert(data ~= nil)

	local bitmap = {
		w = w,
		h = h,
		data = ffi.cast('uint32_t*', data), --set pixels with 0xAARRGGBB
		stride = stride,
		size = size,
	}

	local colorspace = objc.CGColorSpaceCreateDeviceRGB()
	local provider = objc.CGDataProviderCreateWithData(nil, data, size, nil)
	local info = bit.bor(
		ffi.abi'le' and
			objc.kCGBitmapByteOrder32Little or
			objc.kCGBitmapByteOrder32Big,      --native endianness
		objc.kCGImageAlphaPremultipliedFirst) --ARGB32
	local bounds = objc.NSMakeRect(0, 0, w, h)

	function self:_paint_bitmap()

		--CGImage expects the pixel buffer to be immutable, which is why
		--we create a new one every time. bummer.
		local image = objc.CGImageCreate(w, h,
			8,  --bpc
			32, --bpp
			stride,
			colorspace,
			info,
			provider,
			nil, --no decode
			false, --no interpolation
			objc.kCGRenderingIntentDefault)

		--get the current graphics context and draw our image on it.
		local context = objc.NSGraphicsContext:currentContext():graphicsPort()
		objc.CGContextDrawImage(context, bounds, image)

		objc.CGImageRelease(image)
	end

	function self:_free_bitmap()

		--trigger a free bitmap event.
		self.frontend:_backend_free_bitmap(bitmap)

		--free image args
		objc.CGColorSpaceRelease(colorspace)
		objc.CGDataProviderRelease(provider)

		--free the bitmap
		ffi.C.free(data)
		bitmap.data = nil
		bitmap = nil

		--restore stubs
		self._paint_bitmap = stub
		self._free_bitmap = stub
	end

	function self:_get_bitmap(w1, h1)

		--replace the bitmap if its size had changed.
		if w1 ~= w or h1 ~= h then
			self:_free_bitmap()
			return self:_create_bitmap(w1, h1)
		end

		return bitmap
	end

	return bitmap
end

window._paint_bitmap = stub
window._free_bitmap = stub

function window:invalidate()
	self.nswin:contentView():setNeedsDisplay(true)
end

--views ----------------------------------------------------------------------

--NOTE: you can't put a view in front of an OpenGL view. You can put a child NSWindow,
--which will follow the parent around, but it won't be clipped by the parent.

local view = {}
window.view = view

function view:new(window, frontend, t)
	local self = glue.inherit({
		window = window,
		app = window.app,
		frontend = frontend,
	}, self)

	self:_init(t)

	return self
end

glue.autoload(window, {
	cairoview = 'nw_cocoa_cairoview',
	glview    = 'nw_cocoa_glview',
})

function window:getcairoview()
	return self.cairoview
end

--menus ----------------------------------------------------------------------

local menu = {}
nw._menu_class = menu

function app:menu()
	local nsmenu = objc.NSMenu:new()
	nsmenu:setAutoenablesItems(false)
	return menu:_new(self, nsmenu)
end

function window:menubar()
	if not self.app._menu then
		local nsmenu = self.app.nsapp:mainMenu()
		self.app._menu = menu:_new(self.app, nsmenu)
		self.app._menu:remove(1) --remove the dummy app menu created on app startup
	end
	return self.app._menu
end

function menu:_new(app, nsmenu)
	local self = glue.inherit({app = app, nsmenu = nsmenu}, menu)
	nsmenu.nw_backend = self
	return self
end

objc.addmethod('App', 'nw_menuItemClicked', function(self, item)
	item.nw_action()
end, 'v@:@')

function menu:_setitem(item, args)
	if not item then
		if args.separator then
			item = objc.NSMenuItem:separatorItem()
		else
			item = objc.NSMenuItem:new()
		end
	end
	item:setTitle(args.text)
	item:setState(args.checked and objc.NSOnState or objc.NSOffState)
	item:setEnabled(args.enabled)
	item:setKeyEquivalent('G')
	item:setKeyEquivalentModifierMask(bit.bor(
		objc.NSShiftKeyMask,
		objc.NSAlternateKeyMask,
		objc.NSCommandKeyMask,
		objc.NSControlKeyMask))
	if args.submenu then
		local nsmenu = args.submenu.backend.nsmenu
		nsmenu:setTitle(args.text) --the menu item uses nenu's title!
		item:setSubmenu(nsmenu)
	elseif args.action then
		item:setTarget(self.app.nsapp)
		item:setAction'nw_menuItemClicked'
		item.nw_action = args.action
	end
	return item
end

local function dump_menuitem(item)
	return {
		text = objc.tolua(item:title()),
		action = item:submenu() and item:submenu().nw_backend.frontend or item.nw_action,
		checked = item:state() == objc.NSOnState,
		enabled = item:isEnabled(),
	}
end

function menu:add(index, args)
	local item = self:_setitem(nil, args)
	if index then
		self.nsmenu:insertItem_atIndex(item, index-1)
	else
		self.nsmenu:addItem(item)
		index = self.nsmenu:numberOfItems()
	end
	ffi.gc(item, nil) --disown, nsmenu owns it now
	return index
end

function menu:set(index, args)
	local item = self.nsmenu:itemAtIndex(index-1)
	self:_setitem(item, args)
end

function menu:get(index)
	return dump_menuitem(self.nsmenu:itemAtIndex(index-1))
end

function menu:item_count()
	return tonumber(self.nsmenu:numberOfItems())
end

function menu:remove(index)
	self.nsmenu:removeItemAtIndex(index-1)
end

function menu:get_checked(index)
	return self.nsmenu:itemAtIndex(index-1):state() == objc.NSOnState
end

function menu:set_checked(index, checked)
	self.nsmenu:itemAtIndex(index-1):setState(checked and objc.NSOnState or objc.NSOffState)
end

function menu:get_enabled(index)
	return self.nsmenu:itemAtIndex(index-1):isEnabled()
end

function menu:set_enabled(index, enabled)
	self.nsmenu:itemAtIndex(index-1):setEnabled(enabled)
end

function window:popup(menu, x, y)
	local p = objc.NSMakePoint(x, self:_flip_y(y))
	menu.backend.nsmenu:popUpMenuPositioningItem_atLocation_inView(nil, p, self.nswin:contentView())
end

--buttons --------------------------------------------------------------------



objc.debug.cbframe = _cbframe --restore cbframe setting.

if not ... then require'nw_test' end

return nw
