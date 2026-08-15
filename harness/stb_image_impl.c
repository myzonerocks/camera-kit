// The corpus decoder: the vendored single-header image loader compiled
// once for the harness. Only the formats the pinned corpus uses.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#include "stb_image.h"
