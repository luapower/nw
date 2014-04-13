---
project:   nw
tagline:   native widgets
platforms: mingw32, mingw64
---

#### NOTE: work-in-progress (to-be-released soon)

## `local nw = require'nw'`

Cross-platform library for displaying native windows, drawing in their client area using [cairo] or [opengl],
and accessing keyboard, mouse and touchpad events in a consistent and well-specified
manner across Windows, Linux and OS X.

-------------------------------------------- -----------------------------------------------------------------------------
__application loop__
`nw:app() -> app`										create/return the application object (singleton)
`app:run()`												run the application main loop; returns after the last window is destroyed.
`app:quit()`											close all windows and end the application main loop
__monitors__
`app:monitors() -> count, primary`				number of monitors and the number of the primary monitor
`app:screen_rect(monitor) -> x, y, w, h`		screen rectangle, relative to the primary monitor top-left corner
`app:client_rect(monitor) -> x, y, w, h`		screen rectangle without taskbar
`app:frames() -> x, y, w, h`						get frame rectangles of all visible windows of all apps
__time__
`app:time() -> time`									get an opaque time object representing a hi-resolution timestamp
`app:timediff(time1, time2) -> ms`				get the difference between two time objects
__windows__
`app:windows() -> iter() -> win`					iterate app's windows. new windows created while iterating will not be iterated.
`app:active_window() -> win|nil`					get the active window, if any
`app:window(t) -> win`								create a window (fields of t below)
__state options__
t.x, t.y, t.w, t.h (required)						window's bounding rectangle
t.visible (true)										window is visible
t.title (empty) 										window title
t.state ('normal')									window state: 'normal', 'maximized', 'minimized' (orthogonal to visibility)
t.fullscreen (false)									fullscreen mode (orthogonal to state)
t.topmost (false)										always stay on top of all other windows
__frame options__
t.frame (true)											the window has a frame border and title bar
t.transparent (false)								the window is transparent, it has no frame and it's not directly resizeable
t.minimizable (true)									show/enable the minimize button and allow the window to be minimized
t.maximizable (true)									show/enable the maximize button and allow the window to be maximized
t.closeable (true)									show/enable the close button and allow the window to be closed
t.resizeable (true)									the window is user-resizeable
__window lifetime__
`win:free()`											close the window and destroy it
`win:dead() -> true|false`							check if the window was destroyed
`win:closing()`										event: window is closing; return false to prevent it
`win:closed()`											event: window was closed (but not yet freed and its children are alive)
__window focus__
`win:activate()`										activate the window
`win:active() -> true|false`						check if the window is active
`win:activated()`										event: window was activated
`win:deactivated()` 									event: window was deactivated
__window state__
`win:show([state])`									show it, in its current state or in a new state
`win:hide()`											hide it (state is preserved and can be changed while the window is hidden)
`win:visible([visible]) -> true|false`			get/set window's visibility
`win:state([state]) -> state`						get/set window state ('normal', 'maximized', 'minimized') independent of visibility
`win:topmost([true]) -> topmost`					get/set the window topmost flag
`win:fullscreen([on]) -> true|false`			get/set fullscreen state
`win:frame_rect([x, y, w, h]) -> x, y, w, h`	get/set the bounding rectangle of the 'normal' window state
`win:client_rect() -> x, y, w, h`				get the current client area rectangle, relative to itself
`win:frame_changing(how, x, y, w, h)`			event: moving (how = 'move'), or resizing (how = 'left', 'right', 'top', 'bottom', 'topleft', 'topright', 'bottomleft', 'bottomright'); return different x, y, w, h to adjust the rect
`win:frame_changed()`								event: window was either moved, resized, minimized, maximized or restored
`win:title([title]) -> title`						get/set the window's title
`win:monitor() -> monitor`							the monitor with largest area of intersection with the window's bounding rectangle
`win:save() -> t`										save a table t that can be passed to `app:window(t)` to recreate the window in its current state
`win:load(t)`											load a window's user-changeable state from a saved state
__window frame__
`win:frame(flag) -> value`							get frame flags: 'frame', 'transparent', 'minimizable', 'maximizable', 'closeable', 'resizeable'
__keyboard events__
`win:key(keyname) -> down[, toggled]`			get key and toggle state (see source for key names, or print keys on keydown)
`win:keydown(key)`									event: a key was pressed
`win:keyup(key)`										event: a key was depressed
`win:keypress(key)`									event: sent on each key down, including repeats
`win:keychar(char)`									event: sent after key_press for displayable characters; char is utf-8
__mouse events__
`win:hover()`											event: mouse entered the client area of the window
`win:leave()`											event: mouse left the client area of the window
`win:mousemove(x, y)`								event: mouse move
`win:mousedown(button)`								event: a mouse button was pressed: 'left', 'right', 'middle', 'xbutton1', 'xbutton2'
`win:mouseup(button)`								event: a mouse button was depressed
`win:click(button, count)`							event: a mouse button was pressed (see notes for double-click)
`win:wheel(delta)`									event: mouse wheel was moved
`win:hwheel(delta)`									event: mouse horizontal wheel was moved
__mouse state__
`win.mouse`												a table with fields: x, y, left, right, middle, xbutton1, xbutton2, inside
__rendering__
`win:render()`											event: draw the window contents
`win:invalidate()`									request window redrawing
`app:<event>(win, ...)`								window events are forwarded to the app object
__events__
`win:event(event, ...)`								post an event
`win:observe(event, func(...) end)`				observe an event i.e. call `func` when `event` happens
__extending__
`app.window_class`									the table that windows inherit from
`app.window_class.defaults`						default values for window creation arguments
`app.impl`												app implementation class
`app.window_class.impl`								window implementation class
-------------------------------------------- -----------------------------------------------------------------------------


## Features

  * frameless transparent windows
  * magnetic edges
  * full screen mode
  * multi-monitor support
  * complete access to the US keyboard
  * triple-click events
  * multi-touch gestures
  * unicode

## Goals & Characteristics

  * consistent and fully-specified behavior accross all supported platforms
  * no platform-specific features except for supporting platform idioms
  * unspecified behavior is a bug
  * unsupported parameter combination is an error
  * orthogonality of features to avoid unspecified states or behaviors


## Example

~~~{.lua}
local nw = require'nw'

local app = nw:app()

local win = app:window{x = 100, y = 100, w = 400, h = 200, title = 'hello'}

function win:mouse_click(button, count)
	if button == 'left' and count == 3 then --triple click
		app:quit()
	end
end

function win:key_down(key)
	if key == 'F11' then
		if self:state'fullscreen' then
			self:show'normal'
		else
			self:show'fullscreen'
		end
	end
end

app:run() --start the main loop

~~~

## Notes


### Multi-clicks

When the user clicks the mouse repeatedly, with a small enough interval between clicks and over the same target,
a counter is incremented. When the interval between two clicks is larger than the threshold or the mouse is moved
too far away from the initial target, the counter is reset (i.e. the click-chain is interrupted).
Returning true on the `mouse_click` event also resets the counter (i.e. interrupts the click chain).

This allows processing of double-clicks, triple-clicks, or multi-clicks by checking the `count` argument on
the `mouse_click` event. If your app doesn't need to process double-clicks or multi-clicks, you can just ignore
the `count` argument. If it does, you must return true after processing the multi-click event so that
the counter is reset.

For instance, if your app supports double-click over some target, you must return true when count is 2,
otherwise you might get a count of 3 on the next click sometimes, instead of 1 as expected. If your app
supports both double-click and triple-click over a target, you must return true when the count is 3
to break the click chain, but you must not return anything when the count is 2, or you'll never get
a count of 3.

### Closing windows

Closing a window destroys it by default. You can prevent that by returning false on the `closing` event.

~~~{.lua}
function win:closing()
	self:hide()
	return false --prevent destruction
end
~~~

### Closing the app

The `app:run()` call returns after the last window is destroyed.

