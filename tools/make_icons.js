// ==========================================================================
// PROJECT: Natural Calculator (Alfred workflow)
//
// FILE: make_icons.js
//
// AUTHOR: AS
//
// START DATE: 11/23/2026
//
// LAST UPDATE: 11/23/2026
//
// --------------------------------------------------------------------------
// OVERVIEW:
//   Draws the history kind icons from SF Symbols so they can be
//   regenerated instead of hand-edited. Run from the project root:
//     osascript -l JavaScript tools/make_icons.js "$PWD/Workflow"
//   Output: icons/math.png, icons/conversion.png, icons/time.png
//   The workflow icon (Workflow/icon.png) is hand-made, not generated here.
// --------------------------------------------------------------------------
// FUNCTIONS:
//   drawSymbol -- Render one SF Symbol in a flat colour
//   run        -- Entry point
// ==========================================================================

ObjC.import('AppKit');

// User-editable settings
const KIND_SIZE = 128;
const GREY = [0.56, 0.56, 0.58];
const KIND_SYMBOLS = {
    math: 'plus.forwardslash.minus',
    conversion: 'arrow.left.arrow.right',
    time: 'clock'
};


// --------------------------------------------------------------------------
// drawSymbol -- Render one SF Symbol in a flat colour on transparency
// --------------------------------------------------------------------------
function drawSymbol(path, symbolName, size, colour)
{
    const rep = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
        null, size, size, 8, 4, true, false, $.NSDeviceRGBColorSpace, 0, 0);
    $.NSGraphicsContext.saveGraphicsState;
    $.NSGraphicsContext.setCurrentContext(
        $.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep));

    // Weight 0.4 is NSFontWeightSemibold; scale 3 is large.
    const config = $.NSImageSymbolConfiguration
        .configurationWithPointSizeWeightScale(size * 0.55, 0.4, 3);
    const symbol = $.NSImage
        .imageWithSystemSymbolNameAccessibilityDescription(symbolName, symbolName)
        .imageWithSymbolConfiguration(config);
    const w = symbol.size.width;
    const h = symbol.size.height;

    // Symbols draw black; fill over them with sourceAtop to recolour.
    const tinted = $.NSImage.alloc.initWithSize(symbol.size);
    tinted.lockFocus;
    symbol.drawInRectFromRectOperationFraction($.NSMakeRect(0, 0, w, h), $.NSZeroRect, 2, 1);
    $.NSColor.colorWithSRGBRedGreenBlueAlpha(colour[0], colour[1], colour[2], 1).set;
    $.NSRectFillUsingOperation($.NSMakeRect(0, 0, w, h), 3);
    tinted.unlockFocus;

    tinted.drawInRectFromRectOperationFraction(
        $.NSMakeRect((size - w) / 2, (size - h) / 2, w, h), $.NSZeroRect, 2, 1);
    $.NSGraphicsContext.restoreGraphicsState;

    rep.representationUsingTypeProperties(4, $()).writeToFileAtomically(path, true);
}


function run(argv)
{
    const outDir = argv[0];
    if (!outDir) throw new Error('Usage: osascript -l JavaScript make_icons.js <assets dir>');

    $.NSFileManager.defaultManager
        .createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
            `${outDir}/icons`, true, $(), $());

    for (const kind of Object.keys(KIND_SYMBOLS))
    {
        drawSymbol(`${outDir}/icons/${kind}.png`, KIND_SYMBOLS[kind], KIND_SIZE, GREY);
    }
}
