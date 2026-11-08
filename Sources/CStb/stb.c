#include "CStb.h"
#include <stdlib.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_FAILURE_USERMSG
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

unsigned char *cstb_image_load(const unsigned char *data, int length, int *width, int *height) {
    int channels = 0;
    return stbi_load_from_memory(data, length, width, height, &channels, 4);
}

unsigned char *cstb_png_encode(const unsigned char *rgba, int width, int height, int *length) {
    return stbi_write_png_to_mem(rgba, width * 4, width, height, 4, length);
}

void cstb_free(void *pointer) { free(pointer); }

struct cstb_font { stbtt_fontinfo info; };

int cstb_font_count(const unsigned char *data) { return stbtt_GetNumberOfFonts(data); }

cstb_font *cstb_font_open(const unsigned char *data, int index) {
    int offset = stbtt_GetFontOffsetForIndex(data, index);
    if (offset < 0) return NULL;
    cstb_font *font = (cstb_font *)malloc(sizeof(cstb_font));
    if (!font) return NULL;
    if (!stbtt_InitFont(&font->info, data, offset)) { free(font); return NULL; }
    return font;
}

void cstb_font_close(cstb_font *font) { free(font); }

const char *cstb_font_name(const cstb_font *font, int name_id, int *length, int *utf16be) {
    // Windows Unicode in US English, then Windows Unicode full repertoire, then Unicode, then Mac Roman.
    static const int tries[][4] = {{3, 1, 0x409, 1}, {3, 10, 0x409, 1}, {0, 3, 0, 1}, {0, 4, 0, 1}, {1, 0, 0, 0}};
    for (unsigned i = 0; i < sizeof(tries) / sizeof(tries[0]); i++) {
        const char *s = stbtt_GetFontNameString(&font->info, length, tries[i][0], tries[i][1], tries[i][2], name_id);
        if (s) { *utf16be = tries[i][3]; return s; }
    }
    return NULL;
}

double cstb_font_units_per_em(const cstb_font *font) {
    return 1.0 / (double)stbtt_ScaleForMappingEmToPixels(&font->info, 1.0f);
}

void cstb_font_vmetrics(const cstb_font *font, int *ascent, int *descent, int *line_gap) {
    stbtt_GetFontVMetrics(&font->info, ascent, descent, line_gap);
}

int cstb_font_glyph_index(const cstb_font *font, int unicode) { return stbtt_FindGlyphIndex(&font->info, unicode); }

int cstb_font_advance(const cstb_font *font, int glyph) {
    int advance = 0, bearing = 0;
    stbtt_GetGlyphHMetrics(&font->info, glyph, &advance, &bearing);
    return advance;
}

int cstb_font_kern(const cstb_font *font, int glyph1, int glyph2) {
    return stbtt_GetGlyphKernAdvance(&font->info, glyph1, glyph2);
}

int cstb_font_glyph_box(const cstb_font *font, int glyph, int *x0, int *y0, int *x1, int *y1) {
    return stbtt_GetGlyphBox(&font->info, glyph, x0, y0, x1, y1);
}

cstb_vertex *cstb_font_outline(const cstb_font *font, int glyph, int *count) {
    stbtt_vertex *vertices = NULL;
    int n = stbtt_GetGlyphShape(&font->info, glyph, &vertices);
    *count = n;
    if (n <= 0) { *count = 0; return NULL; }
    cstb_vertex *out = (cstb_vertex *)malloc(sizeof(cstb_vertex) * (size_t)n);
    if (out) {
        for (int i = 0; i < n; i++) {
            out[i].kind = vertices[i].type == STBTT_vmove ? 1 : vertices[i].type == STBTT_vline ? 2
                        : vertices[i].type == STBTT_vcurve ? 3 : 4;
            out[i].x = vertices[i].x; out[i].y = vertices[i].y;
            out[i].cx = vertices[i].cx; out[i].cy = vertices[i].cy;
            out[i].cx1 = vertices[i].cx1; out[i].cy1 = vertices[i].cy1;
        }
    } else {
        *count = 0;
    }
    stbtt_FreeShape(&font->info, vertices);
    return out;
}
