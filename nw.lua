--native windows (Cosmin Apreutesei, public domain)
local ffi = require'ffi'
local glue = require'glue'

local backends = {
	Windows = 'nw_win',
	OSX = 'nw_osx',
}

return require(assert(backends[ffi.os], 'NYI'))
