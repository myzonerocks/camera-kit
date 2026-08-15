// On the web target a pair of generated converter kernels name this header
// while using only the web simd intrinsics; the compiler the runtime
// usually builds with ships a translation header under this name. The web
// intrinsics are all these kernels actually reach for.
#pragma once
#include <wasm_simd128.h>
