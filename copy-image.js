// Puts the image file argv[0] on the macOS clipboard, as PNG and as TIFF, so
// that apps which read either one can paste it.
//
//   /usr/bin/osascript -l JavaScript copy-image.js FILE
//
// A PNG file goes on the clipboard byte for byte; any other format AppKit reads
// (JPEG, GIF, WebP) is converted to PNG first. Exits non-zero, with a line on
// stderr, when the file is not an image. serve.pl runs it for the Copy button.
ObjC.import("AppKit");

function run(argv) {
	if (argv.length !== 1) {
		throw new Error("usage: copy-image.js FILE");
	}
	const path = argv[0];
	const image = $.NSImage.alloc.initWithContentsOfFile(path);
	if (image.isNil() || image.representations.count === 0) {
		throw new Error("not an image");
	}
	const tiff = image.TIFFRepresentation;
	let png;
	if (/\.png$/i.test(path)) {
		png = $.NSData.dataWithContentsOfFile(path);
	} else {
		const rep = $.NSBitmapImageRep.imageRepWithData(tiff);
		png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $({}));
	}
	if (png.isNil() || tiff.isNil()) {
		throw new Error("could not encode the image");
	}
	const board = $.NSPasteboard.generalPasteboard;
	board.clearContents;
	if (!board.setDataForType(png, $.NSPasteboardTypePNG) || !board.setDataForType(tiff, $.NSPasteboardTypeTIFF)) {
		throw new Error("the clipboard refused the image");
	}
}
