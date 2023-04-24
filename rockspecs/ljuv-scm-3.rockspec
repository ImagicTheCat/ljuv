rockspec_format = "3.0"
package = "ljuv"
version = "scm-3"
source = {
  url = "git://github.com/ImagicTheCat/ljuv",
}

description = {
  summary = "Module built on libuv and LuaJIT 2.1.",
  detailed = [[
A main event loop combined with coroutines can be a way to nicely parallelize and synchronize various operations; one of the computing problems.

Not only a binding to libuv, the module aims to expose different levels of abstraction and address problems like multi-threading.
  ]],
  homepage = "https://github.com/ImagicTheCat/ljuv",
  license = "MIT"
}

dependencies = {
  "lua == 5.1"
}

external_dependencies = {
  LIBUV = { header = "uv.h" }
}

build = {
  modules = {
    ljuv = "src/ljuv.lua",
    ["ljuv.libuv"] = "src/ljuv/libuv.lua",
    ["ljuv.wrapper"] = "src/ljuv/wrapper.lua",
    ["ljuv.wrapper_c"] = {
      sources = {"src/wrapper.c"},
      libraries = {"uv"}
    },
    ["ljuv.api"] = "src/ljuv/api.lua",
    ["ljuv.thread"] = "src/ljuv/thread.lua"
  }
}
