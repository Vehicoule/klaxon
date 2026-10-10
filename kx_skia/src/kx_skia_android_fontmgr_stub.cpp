// Stub for SkFontMgr_Android_Parser::GetSystemFontFamilies.
// The prebuilt Skia libs reference this symbol (from fontmgr_android_ndk.o)
// but SkFontMgr_android_parser.cpp is not compiled into libskia.a.
// A no-op stub is sufficient: Skia falls back to legacy font enumeration.
#include "src/ports/SkFontMgr_android_parser.h"

namespace SkFontMgr_Android_Parser {

void GetSystemFontFamilies(std::vector<std::unique_ptr<FontFamily>>& fontFamilies) {
    fontFamilies.clear();
}

} // namespace SkFontMgr_Android_Parser
