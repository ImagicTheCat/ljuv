-- https://github.com/ImagicTheCat/ljuv
-- MIT license (see LICENSE or src/ljuv.lua)

local ffi = require("ffi")
local api = require("ljuv.api")
local wrapper = require("ljuv.wrapper")

local refkey = api.refkey

local M = {}

local Channel = {}
local Channel_mt = {__index = Channel}
local function Channel_gc(self)
  wrapper.object_release(ffi.cast("ljuv_object*", self))
end

function M.new_channel()
  return ffi.gc(wrapper.channel_create(), Channel_gc)
end

ffi.metatype("ljuv_channel", Channel_mt)

return M
