//
//  bcdec_impl.c
//  Open Wallpaper Engine
//
//  Single translation unit that instantiates the bcdec header-only library.
//  bcdec.h itself is #imported (declarations only) from the bridging header so
//  Swift can call bcdec_bc1/bc2/bc3; the implementation must be compiled exactly
//  once, which is what this file does.
//
//  bcdec is MIT-licensed (Sergii "iOrange" Kudlai). See the license block at the
//  bottom of bcdec.h.
//

#define BCDEC_IMPLEMENTATION
#include "bcdec.h"
