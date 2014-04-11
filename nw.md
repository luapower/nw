---
project:   nw
tagline:   native widgets
platforms: mingw32, mingw64
---

#### NOTE: work-in-progress (to-be-released soon)

## `local nw = require'nw'`

Cross-platform library for displaying native windows, drawing in their client area using [cairo] or [opengl],
and accessing keyboard, mouse and touchpad events in a consistent manner across Windows, Linux and OS X.

-------------------------------------------- -----------------------------------------------------------------------------
__application__
`nw:app() -> app`										create/return the application object (singleton)
`app:run()`												run the application main loop; returns after the last window is destroyed.
`app:quit()`											close all windows and end the application main loop
`app:screen_rect() -> x, y, w, h`				screen rectangle
`app:client_rect() -> x, y, w, h`				screen client rectangle (without taskbar)
`app:time() -> time`									get an opaque time object representing a hi-resolution timestamp
`app:timediff(time1, time2) -> ms`				get the difference between two time objects
__windows__
`app:window(options_t) -> win`					create a window
__options_t__
x, y, w, h (required)								window's frame (i.e. outside) rectangle
visible (true)											window is visible
state ('normal')										window state: 'normal', 'maximized', 'minimized'
fullscreen (false)									fullscreen mode
title (empty) 											window title
topmost (false)										always stays on top of other windows
frame (true)											the window has a frame border and title bar
allow_minimize (true)								show/enable the minimize button and allow the window to be minimized
allow_maximize (true)								show/enable the maximize button and allow the window to be maximized
allow_close (true)									show/enable the close button and allow the window to be closed
allow_resize (true)									the window is resizeable
transparent (false)									the window is transparent
__lifetime__
`app:windows() -> iter() -> win`					iterate app's windows
`win:free()`											close the window and destroy it
`win:dead() -> true|false`							check if the window was destroyed
`win:closing()`										event: window is closing; return false to prevent it
`win:closed()`											event: window was closed (but not yet freed and its children are alive)
__focus__
`app:active_window() -> win|nil`					get the active window, if any
`win:activate()`										activate the window
`win:active() -> true|false`						check if the window is active
`win:activated()`										event: window was activated
`win:deactivated()` 									event: window was deactivated
__state__
`win:show([state])`									show it, in its current state or in a new state
`win:hide()`											hide it (state is preserved and can be changed while the window is hidden)
`win:visible() -> true|false`						check if the window is visible
`win:state([state]) -> state`						get/set window state: 'normal', 'maximized', 'minimized'
`win:fullscreen([on]) -> true|false`			get/set fullscreen state
`win:state_changed()`								event: window state has changed
`win:client_rect() -> x, y, w, h`				get the client area rectangle
`win:frame_rect([x, y, w, h]) -> x, y, w, h`	get/set the frame rectangle
`win:frame_changing(how, x, y, w, h)`			event: frame rect is changing: 'move', 'left', 'right', 'top', 'bottom', 'topleft', 'topright', 'bottomleft', 'bottomright'
`win:moved()`											event: window was moved
`win:resized()`										event: window was resized
__frame__
`win:title([title]) -> title`						get/set the window's title
`win:frame(flag, [value]) -> value`				get/set frame flags: 'frame', 'topmost', 'allow_minimize', 'allow_maximize', 'allow_close', 'allow_resize'
__keyboard__
`win:key(keyname) -> down[, toggled]`			key and toggle state (see source for key names)
`win:key_down(key)`									event: a key was pressed
`win:key_up(key)`										event: a key was depressed
`win:key_press(key)`									event: sent on each key down, including repeats
`win:key_char(char)`									event: sent after key_press for displayable characters; char is utf-8
__mouse events__
`win:mouse_move(x, y)`								event: mouse move
`win:mouse_enter()`									event: mouse entered the client area of the window
`win:mouse_leave()`									event: mouse left the client area of the window
`win:mouse_down(button)`							event: a mouse button was pressed: 'left', 'right', 'middle', 'xbutton1', 'xbutton2'
`win:mouse_up(button)`								event: a mouse button was depressed
`win:mouse_click(button, count)`					event: a mouse button was clicked (see notes for double-click)
`win:mouse_wheel(delta)`							event: mouse wheel
`win:mouse_hwheel(delta)`							event: mouse horizontal wheel
__mouse state__
`win.mouse`												a table with fields: x, y, left, right, middle, xbutton1, xbutton2, inside
__rendering__
`win:render()`											event: draw the window contents
`win:invalidate()`									request window redrawing
-------------------------------------------- -----------------------------------------------------------------------------

## Features

  * consistent behavior accross Windows, Linux and OS X
  * magnetized windows
  * transparent windows
  * full screen mode
  * complete access to the US keyboard
  * triple-click and multi-click events
  * utf-8 strings

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

