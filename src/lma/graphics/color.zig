const lma = @import("../lma.zig");

pub const Color = packed struct(u24) {
    b: u8,
    g: u8,
    r: u8,
    // _pad: u8 = 0x00,

    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }
    pub fn fromHex(hex: u24) Color {
        return .{ .r = (hex & 0xFF0000) >> 16, .g = (hex & 0x00FF00) >> 8, .b = hex & 0x0000FF };
    }

    // Named colors from CSS
    // https://drafts.csswg.org/css-color-4/#named-colors

    /// CSS color aliceblue, hex: #F0F8FF, rgb: 240, 248, 255
    pub const aliceblue: Color = .fromHex(0xF0F8FF);
    /// CSS color antiquewhite, hex: #FAEBD7, rgb: 250, 235, 215
    pub const antiquewhite: Color = .fromHex(0xFAEBD7);
    /// CSS color aqua, hex: #00FFFF, rgb: 0, 255, 255
    pub const aqua: Color = .fromHex(0x00FFFF);
    /// CSS color aquamarine, hex: #7FFFD4, rgb: 127, 255, 212
    pub const aquamarine: Color = .fromHex(0x7FFFD4);
    /// CSS color azure, hex: #F0FFFF, rgb: 240, 255, 255
    pub const azure: Color = .fromHex(0xF0FFFF);
    /// CSS color beige, hex: #F5F5DC, rgb: 245, 245, 220
    pub const beige: Color = .fromHex(0xF5F5DC);
    /// CSS color bisque, hex: #FFE4C4, rgb: 255, 228, 196
    pub const bisque: Color = .fromHex(0xFFE4C4);
    /// CSS color black, hex: #000000, rgb: 0, 0, 0
    pub const black: Color = .fromHex(0x000000);
    /// CSS color blanchedalmond, hex: #FFEBCD, rgb: 255, 235, 205
    pub const blanchedalmond: Color = .fromHex(0xFFEBCD);
    /// CSS color blue, hex: #0000FF, rgb: 0, 0, 255
    pub const blue: Color = .fromHex(0x0000FF);
    /// CSS color blueviolet, hex: #8A2BE2, rgb: 138, 43, 226
    pub const blueviolet: Color = .fromHex(0x8A2BE2);
    /// CSS color brown, hex: #A52A2A, rgb: 165, 42, 42
    pub const brown: Color = .fromHex(0xA52A2A);
    /// CSS color burlywood, hex: #DEB887, rgb: 222, 184, 135
    pub const burlywood: Color = .fromHex(0xDEB887);
    /// CSS color cadetblue, hex: #5F9EA0, rgb: 95, 158, 160
    pub const cadetblue: Color = .fromHex(0x5F9EA0);
    /// CSS color chartreuse, hex: #7FFF00, rgb: 127, 255, 0
    pub const chartreuse: Color = .fromHex(0x7FFF00);
    /// CSS color chocolate, hex: #D2691E, rgb: 210, 105, 30
    pub const chocolate: Color = .fromHex(0xD2691E);
    /// CSS color coral, hex: #FF7F50, rgb: 255, 127, 80
    pub const coral: Color = .fromHex(0xFF7F50);
    /// CSS color cornflowerblue, hex: #6495ED, rgb: 100, 149, 237
    pub const cornflowerblue: Color = .fromHex(0x6495ED);
    /// CSS color cornsilk, hex: #FFF8DC, rgb: 255, 248, 220
    pub const cornsilk: Color = .fromHex(0xFFF8DC);
    /// CSS color crimson, hex: #DC143C, rgb: 220, 20, 60
    pub const crimson: Color = .fromHex(0xDC143C);
    /// CSS color cyan, hex: #00FFFF, rgb: 0, 255, 255
    pub const cyan: Color = .fromHex(0x00FFFF);
    /// CSS color darkblue, hex: #00008B, rgb: 0, 0, 139
    pub const darkblue: Color = .fromHex(0x00008B);
    /// CSS color darkcyan, hex: #008B8B, rgb: 0, 139, 139
    pub const darkcyan: Color = .fromHex(0x008B8B);
    /// CSS color darkgoldenrod, hex: #B8860B, rgb: 184, 134, 11
    pub const darkgoldenrod: Color = .fromHex(0xB8860B);
    /// CSS color darkgray, hex: #A9A9A9, rgb: 169, 169, 169
    pub const darkgray: Color = .fromHex(0xA9A9A9);
    /// CSS color darkgreen, hex: #006400, rgb: 0, 100, 0
    pub const darkgreen: Color = .fromHex(0x006400);
    /// CSS color darkgrey, hex: #A9A9A9, rgb: 169, 169, 169
    pub const darkgrey: Color = .fromHex(0xA9A9A9);
    /// CSS color darkkhaki, hex: #BDB76B, rgb: 189, 183, 107
    pub const darkkhaki: Color = .fromHex(0xBDB76B);
    /// CSS color darkmagenta, hex: #8B008B, rgb: 139, 0, 139
    pub const darkmagenta: Color = .fromHex(0x8B008B);
    /// CSS color darkolivegreen, hex: #556B2F, rgb: 85, 107, 47
    pub const darkolivegreen: Color = .fromHex(0x556B2F);
    /// CSS color darkorange, hex: #FF8C00, rgb: 255, 140, 0
    pub const darkorange: Color = .fromHex(0xFF8C00);
    /// CSS color darkorchid, hex: #9932CC, rgb: 153, 50, 204
    pub const darkorchid: Color = .fromHex(0x9932CC);
    /// CSS color darkred, hex: #8B0000, rgb: 139, 0, 0
    pub const darkred: Color = .fromHex(0x8B0000);
    /// CSS color darksalmon, hex: #E9967A, rgb: 233, 150, 122
    pub const darksalmon: Color = .fromHex(0xE9967A);
    /// CSS color darkseagreen, hex: #8FBC8F, rgb: 143, 188, 143
    pub const darkseagreen: Color = .fromHex(0x8FBC8F);
    /// CSS color darkslateblue, hex: #483D8B, rgb: 72, 61, 139
    pub const darkslateblue: Color = .fromHex(0x483D8B);
    /// CSS color darkslategray, hex: #2F4F4F, rgb: 47, 79, 79
    pub const darkslategray: Color = .fromHex(0x2F4F4F);
    /// CSS color darkslategrey, hex: #2F4F4F, rgb: 47, 79, 79
    pub const darkslategrey: Color = .fromHex(0x2F4F4F);
    /// CSS color darkturquoise, hex: #00CED1, rgb: 0, 206, 209
    pub const darkturquoise: Color = .fromHex(0x00CED1);
    /// CSS color darkviolet, hex: #9400D3, rgb: 148, 0, 211
    pub const darkviolet: Color = .fromHex(0x9400D3);
    /// CSS color deeppink, hex: #FF1493, rgb: 255, 20, 147
    pub const deeppink: Color = .fromHex(0xFF1493);
    /// CSS color deepskyblue, hex: #00BFFF, rgb: 0, 191, 255
    pub const deepskyblue: Color = .fromHex(0x00BFFF);
    /// CSS color dimgray, hex: #696969, rgb: 105, 105, 105
    pub const dimgray: Color = .fromHex(0x696969);
    /// CSS color dimgrey, hex: #696969, rgb: 105, 105, 105
    pub const dimgrey: Color = .fromHex(0x696969);
    /// CSS color dodgerblue, hex: #1E90FF, rgb: 30, 144, 255
    pub const dodgerblue: Color = .fromHex(0x1E90FF);
    /// CSS color firebrick, hex: #B22222, rgb: 178, 34, 34
    pub const firebrick: Color = .fromHex(0xB22222);
    /// CSS color floralwhite, hex: #FFFAF0, rgb: 255, 250, 240
    pub const floralwhite: Color = .fromHex(0xFFFAF0);
    /// CSS color forestgreen, hex: #228B22, rgb: 34, 139, 34
    pub const forestgreen: Color = .fromHex(0x228B22);
    /// CSS color fuchsia, hex: #FF00FF, rgb: 255, 0, 255
    pub const fuchsia: Color = .fromHex(0xFF00FF);
    /// CSS color gainsboro, hex: #DCDCDC, rgb: 220, 220, 220
    pub const gainsboro: Color = .fromHex(0xDCDCDC);
    /// CSS color ghostwhite, hex: #F8F8FF, rgb: 248, 248, 255
    pub const ghostwhite: Color = .fromHex(0xF8F8FF);
    /// CSS color gold, hex: #FFD700, rgb: 255, 215, 0
    pub const gold: Color = .fromHex(0xFFD700);
    /// CSS color goldenrod, hex: #DAA520, rgb: 218, 165, 32
    pub const goldenrod: Color = .fromHex(0xDAA520);
    /// CSS color gray, hex: #808080, rgb: 128, 128, 128
    pub const gray: Color = .fromHex(0x808080);
    /// CSS color green, hex: #008000, rgb: 0, 128, 0
    pub const green: Color = .fromHex(0x008000);
    /// CSS color greenyellow, hex: #ADFF2F, rgb: 173, 255, 47
    pub const greenyellow: Color = .fromHex(0xADFF2F);
    /// CSS color grey, hex: #808080, rgb: 128, 128, 128
    pub const grey: Color = .fromHex(0x808080);
    /// CSS color honeydew, hex: #F0FFF0, rgb: 240, 255, 240
    pub const honeydew: Color = .fromHex(0xF0FFF0);
    /// CSS color hotpink, hex: #FF69B4, rgb: 255, 105, 180
    pub const hotpink: Color = .fromHex(0xFF69B4);
    /// CSS color indianred, hex: #CD5C5C, rgb: 205, 92, 92
    pub const indianred: Color = .fromHex(0xCD5C5C);
    /// CSS color indigo, hex: #4B0082, rgb: 75, 0, 130
    pub const indigo: Color = .fromHex(0x4B0082);
    /// CSS color ivory, hex: #FFFFF0, rgb: 255, 255, 240
    pub const ivory: Color = .fromHex(0xFFFFF0);
    /// CSS color khaki, hex: #F0E68C, rgb: 240, 230, 140
    pub const khaki: Color = .fromHex(0xF0E68C);
    /// CSS color lavender, hex: #E6E6FA, rgb: 230, 230, 250
    pub const lavender: Color = .fromHex(0xE6E6FA);
    /// CSS color lavenderblush, hex: #FFF0F5, rgb: 255, 240, 245
    pub const lavenderblush: Color = .fromHex(0xFFF0F5);
    /// CSS color lawngreen, hex: #7CFC00, rgb: 124, 252, 0
    pub const lawngreen: Color = .fromHex(0x7CFC00);
    /// CSS color lemonchiffon, hex: #FFFACD, rgb: 255, 250, 205
    pub const lemonchiffon: Color = .fromHex(0xFFFACD);
    /// CSS color lightblue, hex: #ADD8E6, rgb: 173, 216, 230
    pub const lightblue: Color = .fromHex(0xADD8E6);
    /// CSS color lightcoral, hex: #F08080, rgb: 240, 128, 128
    pub const lightcoral: Color = .fromHex(0xF08080);
    /// CSS color lightcyan, hex: #E0FFFF, rgb: 224, 255, 255
    pub const lightcyan: Color = .fromHex(0xE0FFFF);
    /// CSS color lightgoldenrodyellow, hex: #FAFAD2, rgb: 250, 250, 210
    pub const lightgoldenrodyellow: Color = .fromHex(0xFAFAD2);
    /// CSS color lightgray, hex: #D3D3D3, rgb: 211, 211, 211
    pub const lightgray: Color = .fromHex(0xD3D3D3);
    /// CSS color lightgreen, hex: #90EE90, rgb: 144, 238, 144
    pub const lightgreen: Color = .fromHex(0x90EE90);
    /// CSS color lightgrey, hex: #D3D3D3, rgb: 211, 211, 211
    pub const lightgrey: Color = .fromHex(0xD3D3D3);
    /// CSS color lightpink, hex: #FFB6C1, rgb: 255, 182, 193
    pub const lightpink: Color = .fromHex(0xFFB6C1);
    /// CSS color lightsalmon, hex: #FFA07A, rgb: 255, 160, 122
    pub const lightsalmon: Color = .fromHex(0xFFA07A);
    /// CSS color lightseagreen, hex: #20B2AA, rgb: 32, 178, 170
    pub const lightseagreen: Color = .fromHex(0x20B2AA);
    /// CSS color lightskyblue, hex: #87CEFA, rgb: 135, 206, 250
    pub const lightskyblue: Color = .fromHex(0x87CEFA);
    /// CSS color lightslategray, hex: #778899, rgb: 119, 136, 153
    pub const lightslategray: Color = .fromHex(0x778899);
    /// CSS color lightslategrey, hex: #778899, rgb: 119, 136, 153
    pub const lightslategrey: Color = .fromHex(0x778899);
    /// CSS color lightsteelblue, hex: #B0C4DE, rgb: 176, 196, 222
    pub const lightsteelblue: Color = .fromHex(0xB0C4DE);
    /// CSS color lightyellow, hex: #FFFFE0, rgb: 255, 255, 224
    pub const lightyellow: Color = .fromHex(0xFFFFE0);
    /// CSS color lime, hex: #00FF00, rgb: 0, 255, 0
    pub const lime: Color = .fromHex(0x00FF00);
    /// CSS color limegreen, hex: #32CD32, rgb: 50, 205, 50
    pub const limegreen: Color = .fromHex(0x32CD32);
    /// CSS color linen, hex: #FAF0E6, rgb: 250, 240, 230
    pub const linen: Color = .fromHex(0xFAF0E6);
    /// CSS color magenta, hex: #FF00FF, rgb: 255, 0, 255
    pub const magenta: Color = .fromHex(0xFF00FF);
    /// CSS color maroon, hex: #800000, rgb: 128, 0, 0
    pub const maroon: Color = .fromHex(0x800000);
    /// CSS color mediumaquamarine, hex: #66CDAA, rgb: 102, 205, 170
    pub const mediumaquamarine: Color = .fromHex(0x66CDAA);
    /// CSS color mediumblue, hex: #0000CD, rgb: 0, 0, 205
    pub const mediumblue: Color = .fromHex(0x0000CD);
    /// CSS color mediumorchid, hex: #BA55D3, rgb: 186, 85, 211
    pub const mediumorchid: Color = .fromHex(0xBA55D3);
    /// CSS color mediumpurple, hex: #9370DB, rgb: 147, 112, 219
    pub const mediumpurple: Color = .fromHex(0x9370DB);
    /// CSS color mediumseagreen, hex: #3CB371, rgb: 60, 179, 113
    pub const mediumseagreen: Color = .fromHex(0x3CB371);
    /// CSS color mediumslateblue, hex: #7B68EE, rgb: 123, 104, 238
    pub const mediumslateblue: Color = .fromHex(0x7B68EE);
    /// CSS color mediumspringgreen, hex: #00FA9A, rgb: 0, 250, 154
    pub const mediumspringgreen: Color = .fromHex(0x00FA9A);
    /// CSS color mediumturquoise, hex: #48D1CC, rgb: 72, 209, 204
    pub const mediumturquoise: Color = .fromHex(0x48D1CC);
    /// CSS color mediumvioletred, hex: #C71585, rgb: 199, 21, 133
    pub const mediumvioletred: Color = .fromHex(0xC71585);
    /// CSS color midnightblue, hex: #191970, rgb: 25, 25, 112
    pub const midnightblue: Color = .fromHex(0x191970);
    /// CSS color mintcream, hex: #F5FFFA, rgb: 245, 255, 250
    pub const mintcream: Color = .fromHex(0xF5FFFA);
    /// CSS color mistyrose, hex: #FFE4E1, rgb: 255, 228, 225
    pub const mistyrose: Color = .fromHex(0xFFE4E1);
    /// CSS color moccasin, hex: #FFE4B5, rgb: 255, 228, 181
    pub const moccasin: Color = .fromHex(0xFFE4B5);
    /// CSS color navajowhite, hex: #FFDEAD, rgb: 255, 222, 173
    pub const navajowhite: Color = .fromHex(0xFFDEAD);
    /// CSS color navy, hex: #000080, rgb: 0, 0, 128
    pub const navy: Color = .fromHex(0x000080);
    /// CSS color oldlace, hex: #FDF5E6, rgb: 253, 245, 230
    pub const oldlace: Color = .fromHex(0xFDF5E6);
    /// CSS color olive, hex: #808000, rgb: 128, 128, 0
    pub const olive: Color = .fromHex(0x808000);
    /// CSS color olivedrab, hex: #6B8E23, rgb: 107, 142, 35
    pub const olivedrab: Color = .fromHex(0x6B8E23);
    /// CSS color orange, hex: #FFA500, rgb: 255, 165, 0
    pub const orange: Color = .fromHex(0xFFA500);
    /// CSS color orangered, hex: #FF4500, rgb: 255, 69, 0
    pub const orangered: Color = .fromHex(0xFF4500);
    /// CSS color orchid, hex: #DA70D6, rgb: 218, 112, 214
    pub const orchid: Color = .fromHex(0xDA70D6);
    /// CSS color palegoldenrod, hex: #EEE8AA, rgb: 238, 232, 170
    pub const palegoldenrod: Color = .fromHex(0xEEE8AA);
    /// CSS color palegreen, hex: #98FB98, rgb: 152, 251, 152
    pub const palegreen: Color = .fromHex(0x98FB98);
    /// CSS color paleturquoise, hex: #AFEEEE, rgb: 175, 238, 238
    pub const paleturquoise: Color = .fromHex(0xAFEEEE);
    /// CSS color palevioletred, hex: #DB7093, rgb: 219, 112, 147
    pub const palevioletred: Color = .fromHex(0xDB7093);
    /// CSS color papayawhip, hex: #FFEFD5, rgb: 255, 239, 213
    pub const papayawhip: Color = .fromHex(0xFFEFD5);
    /// CSS color peachpuff, hex: #FFDAB9, rgb: 255, 218, 185
    pub const peachpuff: Color = .fromHex(0xFFDAB9);
    /// CSS color peru, hex: #CD853F, rgb: 205, 133, 63
    pub const peru: Color = .fromHex(0xCD853F);
    /// CSS color pink, hex: #FFC0CB, rgb: 255, 192, 203
    pub const pink: Color = .fromHex(0xFFC0CB);
    /// CSS color plum, hex: #DDA0DD, rgb: 221, 160, 221
    pub const plum: Color = .fromHex(0xDDA0DD);
    /// CSS color powderblue, hex: #B0E0E6, rgb: 176, 224, 230
    pub const powderblue: Color = .fromHex(0xB0E0E6);
    /// CSS color purple, hex: #800080, rgb: 128, 0, 128
    pub const purple: Color = .fromHex(0x800080);
    /// CSS color rebeccapurple, hex: #663399, rgb: 102, 51, 153
    pub const rebeccapurple: Color = .fromHex(0x663399);
    /// CSS color red, hex: #FF0000, rgb: 255, 0, 0
    pub const red: Color = .fromHex(0xFF0000);
    /// CSS color rosybrown, hex: #BC8F8F, rgb: 188, 143, 143
    pub const rosybrown: Color = .fromHex(0xBC8F8F);
    /// CSS color royalblue, hex: #4169E1, rgb: 65, 105, 225
    pub const royalblue: Color = .fromHex(0x4169E1);
    /// CSS color saddlebrown, hex: #8B4513, rgb: 139, 69, 19
    pub const saddlebrown: Color = .fromHex(0x8B4513);
    /// CSS color salmon, hex: #FA8072, rgb: 250, 128, 114
    pub const salmon: Color = .fromHex(0xFA8072);
    /// CSS color sandybrown, hex: #F4A460, rgb: 244, 164, 96
    pub const sandybrown: Color = .fromHex(0xF4A460);
    /// CSS color seagreen, hex: #2E8B57, rgb: 46, 139, 87
    pub const seagreen: Color = .fromHex(0x2E8B57);
    /// CSS color seashell, hex: #FFF5EE, rgb: 255, 245, 238
    pub const seashell: Color = .fromHex(0xFFF5EE);
    /// CSS color sienna, hex: #A0522D, rgb: 160, 82, 45
    pub const sienna: Color = .fromHex(0xA0522D);
    /// CSS color silver, hex: #C0C0C0, rgb: 192, 192, 192
    pub const silver: Color = .fromHex(0xC0C0C0);
    /// CSS color skyblue, hex: #87CEEB, rgb: 135, 206, 235
    pub const skyblue: Color = .fromHex(0x87CEEB);
    /// CSS color slateblue, hex: #6A5ACD, rgb: 106, 90, 205
    pub const slateblue: Color = .fromHex(0x6A5ACD);
    /// CSS color slategray, hex: #708090, rgb: 112, 128, 144
    pub const slategray: Color = .fromHex(0x708090);
    /// CSS color slategrey, hex: #708090, rgb: 112, 128, 144
    pub const slategrey: Color = .fromHex(0x708090);
    /// CSS color snow, hex: #FFFAFA, rgb: 255, 250, 250
    pub const snow: Color = .fromHex(0xFFFAFA);
    /// CSS color springgreen, hex: #00FF7F, rgb: 0, 255, 127
    pub const springgreen: Color = .fromHex(0x00FF7F);
    /// CSS color steelblue, hex: #4682B4, rgb: 70, 130, 180
    pub const steelblue: Color = .fromHex(0x4682B4);
    /// CSS color tan, hex: #D2B48C, rgb: 210, 180, 140
    pub const tan: Color = .fromHex(0xD2B48C);
    /// CSS color teal, hex: #008080, rgb: 0, 128, 128
    pub const teal: Color = .fromHex(0x008080);
    /// CSS color thistle, hex: #D8BFD8, rgb: 216, 191, 216
    pub const thistle: Color = .fromHex(0xD8BFD8);
    /// CSS color tomato, hex: #FF6347, rgb: 255, 99, 71
    pub const tomato: Color = .fromHex(0xFF6347);
    /// CSS color turquoise, hex: #40E0D0, rgb: 64, 224, 208
    pub const turquoise: Color = .fromHex(0x40E0D0);
    /// CSS color violet, hex: #EE82EE, rgb: 238, 130, 238
    pub const violet: Color = .fromHex(0xEE82EE);
    /// CSS color wheat, hex: #F5DEB3, rgb: 245, 222, 179
    pub const wheat: Color = .fromHex(0xF5DEB3);
    /// CSS color white, hex: #FFFFFF, rgb: 255, 255, 255
    pub const white: Color = .fromHex(0xFFFFFF);
    /// CSS color whitesmoke, hex: #F5F5F5, rgb: 245, 245, 245
    pub const whitesmoke: Color = .fromHex(0xF5F5F5);
    /// CSS color yellow, hex: #FFFF00, rgb: 255, 255, 0
    pub const yellow: Color = .fromHex(0xFFFF00);
    /// CSS color yellowgreen, hex: #9ACD32, rgb: 154, 205, 50
    pub const yellowgreen: Color = .fromHex(0x9ACD32);
};

pub const ByteColor = packed struct(u8) {
    r: u3,
    g: u3,
    b: u2,

    pub fn fromColor(color: Color) ByteColor {
        return .{
            .r = @intCast(color.r / 0b00100100),
            .g = @intCast(color.g / 0b00100100),
            .b = @intCast(color.b / 0b01010101),
        };
    }

    pub fn asColor(self: ByteColor) Color {
        return .{
            .r = lma.cast.as(u8, self.r) * 0b00100100 + (self.r >> 1),
            .g = lma.cast.as(u8, self.g) * 0b00100100 + (self.g >> 1),
            .b = lma.cast.as(u8, self.b) * 0b01010101,
        };
    }
};
