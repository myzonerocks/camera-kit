// The corpus decoder for hosts that do not link the beauty archive, which
// carries this implementation otherwise. Only the formats the pinned
// corpus uses.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#include "stb_image.h"
