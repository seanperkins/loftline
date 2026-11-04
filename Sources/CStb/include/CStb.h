// C wrapper over the vendored stb headers (Vendor/stb, never edited). Built only off the Mac: there ImageIO and CoreText do this.
#ifndef CSTB_H
#define CSTB_H

#ifdef __cplusplus
extern "C" {
#endif

// Images. Both results are freed with cstb_free.
/// RGBA, 8 bits a channel, top row first; NULL when the data cannot be decoded.
unsigned char *cstb_image_load(const unsigned char *data, int length, int *width, int *height);
/// A PNG of RGBA pixels; NULL on failure.
unsigned char *cstb_png_encode(const unsigned char *rgba, int width, int height, int *length);
void cstb_free(void *pointer);

// Fonts. A font keeps a pointer to `data`, which must outlive it.
typedef struct cstb_font cstb_font;
int cstb_font_count(const unsigned char *data);
/// The `index`-th font of a file (0 for a plain .ttf or .otf); NULL when it cannot be read.
cstb_font *cstb_font_open(const unsigned char *data, int index);
void cstb_font_close(cstb_font *font);
/// Raw bytes of a name-table string (`*utf16be` = 1: UTF-16 big endian, 0: Mac Roman), or NULL. Points into the font data.
const char *cstb_font_name(const cstb_font *font, int name_id, int *length, int *utf16be);
/// Font units in one em.
double cstb_font_units_per_em(const cstb_font *font);
void cstb_font_vmetrics(const cstb_font *font, int *ascent, int *descent, int *line_gap);
int cstb_font_glyph_index(const cstb_font *font, int unicode);
int cstb_font_advance(const cstb_font *font, int glyph);
int cstb_font_kern(const cstb_font *font, int glyph1, int glyph2);
/// The glyph's box; 0 when it has no outline.
int cstb_font_glyph_box(const cstb_font *font, int glyph, int *x0, int *y0, int *x1, int *y1);

/// kind: 1 move, 2 line, 3 quadratic (one control point), 4 cubic (two control points). Font units.
typedef struct {
    int kind;
    int x, y, cx, cy, cx1, cy1;
} cstb_vertex;
/// The glyph's outline; the result is freed with cstb_free. *count is 0 for a blank glyph.
cstb_vertex *cstb_font_outline(const cstb_font *font, int glyph, int *count);

#ifdef __cplusplus
}
#endif
#endif
