// DCMTKHelper.mm
// OpenDicomViewer
//
// Objective-C++ bridge to the DCMTK library. Provides two interfaces:
//
// 1. DCMTKHelper (class methods):
//    - convertDICOMToNSImage: Full DICOM-to-NSImage conversion
//    - getRawPixelData: Extract raw pixel buffer with metadata
//    - decodeJPEG2000DICOM: OpenJPEG fallback for JPEG 2000 transfer syntaxes
//    - lastErrorForPath: Human-readable error for failed loads
//
// 2. DCMTKImageObject (instance, retains decoded state):
//    - Keeps the decoded DCMTK image in memory for efficient re-rendering
//      at different window/level values without re-parsing the file
//    - Used for interactive W/L adjustment
//
// Supports standard DICOM transfer syntaxes including JPEG, JPEG-LS,
// and JPEG 2000 (via OpenJPEG). Handles both 8-bit and 16-bit pixel data,
// signed/unsigned, and Monochrome1/Monochrome2 photometric interpretations.
// Licensed under the MIT License. See LICENSE for details.

#import "DCMTKHelper.h"

// DCMTK Headers
#include "dcmtk/config/osconfig.h"
#include "dcmtk/dcmdata/dctk.h"
#include "dcmtk/dcmdata/dcpixel.h"     // DcmPixelData
#include "dcmtk/dcmdata/dcpixseq.h"    // DcmPixelSequence
#include "dcmtk/dcmdata/dcpxitem.h"    // DcmPixelItem
#include "dcmtk/dcmdata/dcrledrg.h"    // RLE decoder registration
#include "dcmtk/dcmimgle/dcmimage.h"
#include "dcmtk/dcmimage/diregist.h" // registers color (RGB/YBR/...) support for DicomImage
#include "dcmtk/dcmjpeg/djdecode.h"    // JPEG decoder registration
#include "dcmtk/dcmjpls/djdecode.h"    // JPEG-LS decoder registration

// OpenJPEG for JPEG2000 fallback (no dcmjp2k in DCMTK 3.6.8)
#include "openjpeg.h"

// Shared initialization — must run before ANY DCMTK usage from either class
static void ensureDCMTKInitialized(void) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    // Set DCMDICTPATH to the bundled dicom.dic
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *dicPath = [mainBundle pathForResource:@"dicom" ofType:@"dic"];

    // Development fallback (swift run / swift test): the dictionary shipped
    // in the source tree's libs/, located relative to this source file.
    if (!dicPath && !getenv("DCMDICTPATH")) {
      NSString *src = [NSString stringWithUTF8String:__FILE__];
      NSString *repo = [[[src stringByDeletingLastPathComponent]
          stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
      NSString *candidate = [repo
          stringByAppendingPathComponent:@"libs/dcmtk/share/dcmtk-3.6.8/dicom.dic"];
      if ([[NSFileManager defaultManager] fileExistsAtPath:candidate])
        dicPath = candidate;
    }

    if (dicPath) {
      setenv("DCMDICTPATH", [dicPath UTF8String], 1);
    } else if (!getenv("DCMDICTPATH")) {
      NSLog(@"[DCMTKHelper] WARNING: dicom.dic not found in application bundle!");
    }

    // Register ALL available decoders globally
    DJDecoderRegistration::registerCodecs();      // JPEG (baseline, lossless)
    DJLSDecoderRegistration::registerCodecs();    // JPEG-LS (common in Korean equipment)
    DcmRLEDecoderRegistration::registerCodecs();  // RLE Lossless
    // Note: JPEG2000 handled via OpenJPEG fallback (no dcmjp2k in DCMTK 3.6.8)
  });
}

// Extract pixel values after the Modality LUT (rescale) but before VOI.
// Monochrome: the inter data is one contiguous plane. Color: DiColorPixel's
// getData() returns an array of plane pointers, not pixel bytes, so copying
// count*elementSize from it over-reads. Color images are returned as 8-bit
// interleaved RGB from the rendered output (no VOI applies to color).
static NSData *copyModalityPixels(DicomImage *image, NSInteger *bitDepth,
                                  NSInteger *samples, BOOL *isSigned) {
  if (!image)
    return nil;

  if (!image->isMonochrome()) {
    unsigned long size = image->getOutputDataSize(8);
    if (size == 0)
      return nil;
    NSMutableData *rgb = [NSMutableData dataWithLength:size];
    // planar = 0 -> interleaved RGBRGB...
    if (!image->getOutputData(rgb.mutableBytes, size, 8, 0, 0))
      return nil;
    *bitDepth = 8;
    *samples = 3;
    *isSigned = NO;
    return rgb;
  }

  *samples = 1;
  const DiPixel *interData = image->getInterData();
  if (!interData)
    return nil;

  unsigned long count = interData->getCount();
  EP_Representation rep = interData->getRepresentation();

  size_t elementSize = 0;
  switch (rep) {
  case EPR_Uint8:
  case EPR_Sint8:
    elementSize = 1;
    *bitDepth = 8;
    break;
  case EPR_Uint16:
  case EPR_Sint16:
    elementSize = 2;
    *bitDepth = 16;
    break;
  case EPR_Uint32:
  case EPR_Sint32:
    elementSize = 4;
    *bitDepth = 32;
    break;
  default:
    return nil;
  }

  *isSigned = (rep == EPR_Sint8 || rep == EPR_Sint16 || rep == EPR_Sint32);

  // Inter data may hold several frames; return the first.
  unsigned long frameCount = image->getFrameCount();
  unsigned long pixelsPerFrame =
      (unsigned long)image->getWidth() * (unsigned long)image->getHeight();
  if (frameCount > 1 && pixelsPerFrame > 0 && pixelsPerFrame < count)
    count = pixelsPerFrame;

  unsigned long totalSize;
  if (__builtin_mul_overflow(count, elementSize, &totalSize))
    return nil;

  const void *pixelPtr = interData->getData();
  if (!pixelPtr)
    return nil;

  return [NSData dataWithBytes:pixelPtr length:totalSize];
}

// Read the file's first stored VOI window (WindowCenter/WindowWidth), in
// modality units. Returns NO when the dataset has none.
static BOOL storedWindow(DicomImage *image, double *center, double *width) {
  if (!image || !image->isMonochrome())
    return NO;
  double c = 0, w = 0;
  if (image->getWindow(c, w) && w > 0) {
    *center = c;
    *width = w;
    return YES;
  }
  if (image->getWindowCount() > 0 && image->setWindow(0) &&
      image->getWindow(c, w) && w > 0) {
    *center = c;
    *width = w;
    return YES;
  }
  return NO;
}

// Pack rescaled monochrome values into the narrowest integer representation
// that holds them, mirroring DCMTK's choice for its inter data.
static NSData *packModalityValues(const double *values, size_t count,
                                  NSInteger *bitDepth, BOOL *isSigned) {
  double lo = 0, hi = 0;
  for (size_t i = 0; i < count; i++) {
    double v = values[i];
    if (i == 0 || v < lo) lo = v;
    if (i == 0 || v > hi) hi = v;
  }
  if (lo >= 0 && hi <= 255) {
    NSMutableData *d = [NSMutableData dataWithLength:count];
    uint8_t *p = (uint8_t *)d.mutableBytes;
    for (size_t i = 0; i < count; i++) p[i] = (uint8_t)lround(values[i]);
    *bitDepth = 8; *isSigned = NO;
    return d;
  }
  if (lo >= -32768 && hi <= 32767) {
    NSMutableData *d = [NSMutableData dataWithLength:count * 2];
    int16_t *p = (int16_t *)d.mutableBytes;
    for (size_t i = 0; i < count; i++) p[i] = (int16_t)lround(values[i]);
    *bitDepth = 16; *isSigned = YES;
    return d;
  }
  if (lo >= 0 && hi <= 65535) {
    NSMutableData *d = [NSMutableData dataWithLength:count * 2];
    uint16_t *p = (uint16_t *)d.mutableBytes;
    for (size_t i = 0; i < count; i++) p[i] = (uint16_t)lround(values[i]);
    *bitDepth = 16; *isSigned = NO;
    return d;
  }
  NSMutableData *d = [NSMutableData dataWithLength:count * 4];
  int32_t *p = (int32_t *)d.mutableBytes;
  for (size_t i = 0; i < count; i++) {
    double v = values[i];
    if (v > 2147483647.0) v = 2147483647.0;
    if (v < -2147483648.0) v = -2147483648.0;
    p[i] = (int32_t)llround(v);
  }
  *bitDepth = 32; *isSigned = YES;
  return d;
}

@implementation DCMTKHelper

+ (void)initialize {
  ensureDCMTKInitialized();
}

+ (NSImage *)convertDICOMToNSImage:(NSString *)path {
  if (!path)
    return nil;

  DicomImage *image = new DicomImage([path UTF8String]);
  if (image == NULL)
    return nil;
  if (image->getStatus() != EIS_Normal) {
    delete image;
    return nil;
  }

  unsigned long width = image->getWidth();
  unsigned long height = image->getHeight();
  int samples = image->isMonochrome() ? 1 : 3;

  // Force 8-bit output for display
  unsigned long size = image->getOutputDataSize(8);
  if (size == 0) {
    delete image;
    return nil;
  }

  uint8_t *buffer = (uint8_t *)malloc(size);
  if (image->getOutputData(buffer, size, 8)) {
    CGColorSpaceRef colorSpace = image->isMonochrome()
                                     ? CGColorSpaceCreateDeviceGray()
                                     : CGColorSpaceCreateDeviceRGB();

    // CFData takes ownership of buffer if we use kCFAllocatorMalloc?
    // No, CFDataCreateWithBytesNoCopy with kCFAllocatorMalloc means CFData will
    // call free() on release.
    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, buffer,
                                                 size, kCFAllocatorMalloc);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);

    CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault | kCGImageAlphaNone;

    CGImageRef cgImage = CGImageCreate(
        width, height, 8, 8 * samples, width * samples, colorSpace, bitmapInfo,
        provider, NULL, false, kCGRenderingIntentDefault);

    NSImage *nsImage =
        [[NSImage alloc] initWithCGImage:cgImage
                                    size:NSMakeSize(width, height)];

    CGImageRelease(cgImage);
    CGDataProviderRelease(provider);
    CFRelease(data);
    CGColorSpaceRelease(colorSpace);

    delete image;
    return nsImage;
  }

  free(buffer);
  delete image;
  return nil;
}

+ (NSData *)getRawPixelData:(NSString *)path
                      width:(NSInteger *)width
                     height:(NSInteger *)height
                   bitDepth:(NSInteger *)bitDepth
                    samples:(NSInteger *)samples
                   isSigned:(BOOL *)isSigned {
  if (!path)
    return nil;

  // We use DicomImage to handle decompression and Modality LUT (Rescale)
  // CIF_DecompressCompletePixelData ensures compressed images (JPEG2000) are
  // fully decoded
  DicomImage *image =
      new DicomImage([path UTF8String], CIF_DecompressCompletePixelData);
  if (image == NULL)
    return nil;
  if (image->getStatus() != EIS_Normal) {
    delete image;
    return nil;
  }

  *width = image->getWidth();
  *height = image->getHeight();

  // Values after Modality LUT (e.g. Hounsfield Units), before VOI LUT.
  NSData *data = copyModalityPixels(image, bitDepth, samples, isSigned);
  delete image;
  return data;
}

+ (NSString *)lastErrorForPath:(NSString *)path {
  if (!path)
    return @"No path provided";

  DcmFileFormat fileformat;
  OFCondition status = fileformat.loadFile([path UTF8String]);
  if (status.bad()) {
    return [NSString
        stringWithFormat:@"Cannot read DICOM file: %s", status.text()];
  }

  // Try to create DicomImage to get its specific error
  DicomImage *image =
      new DicomImage([path UTF8String], CIF_DecompressCompletePixelData);
  if (image == NULL) {
    return @"Failed to allocate DicomImage";
  }

  EI_Status imgStatus = image->getStatus();
  NSString *errorStr = nil;
  if (imgStatus != EIS_Normal) {
    // Map common status codes to readable messages
    switch (imgStatus) {
    case EIS_NoDataDictionary:
      errorStr = @"DCMTK data dictionary not found (dicom.dic missing)";
      break;
    case EIS_InvalidDocument:
      errorStr = @"Invalid DICOM document";
      break;
    case EIS_MissingAttribute:
      errorStr = @"Missing required DICOM attribute";
      break;
    case EIS_InvalidValue:
      errorStr = @"Invalid DICOM attribute value";
      break;
    case EIS_InvalidImage:
      errorStr = @"Invalid image data";
      break;
    case EIS_NotSupportedValue:
      errorStr = @"Unsupported pixel value representation";
      break;
    default:
      errorStr =
          [NSString stringWithFormat:@"DicomImage error (status: %d)",
                                     (int)imgStatus];
      break;
    }
  }

  delete image;
  return errorStr;
}

// OpenJPEG callbacks for memory-based stream
struct MemoryStreamState {
  const uint8_t *data;
  OPJ_SIZE_T size;
  OPJ_SIZE_T offset;
};

static OPJ_SIZE_T opj_mem_read(void *p_buffer, OPJ_SIZE_T p_nb_bytes,
                                void *p_user_data) {
  MemoryStreamState *state = (MemoryStreamState *)p_user_data;
  OPJ_SIZE_T remaining = state->size - state->offset;
  if (remaining == 0)
    return (OPJ_SIZE_T)-1;
  OPJ_SIZE_T toRead = (p_nb_bytes < remaining) ? p_nb_bytes : remaining;
  memcpy(p_buffer, state->data + state->offset, toRead);
  state->offset += toRead;
  return toRead;
}

static OPJ_OFF_T opj_mem_skip(OPJ_OFF_T p_nb_bytes, void *p_user_data) {
  MemoryStreamState *state = (MemoryStreamState *)p_user_data;
  if (p_nb_bytes < 0) {
    // Backward skip
    if ((OPJ_SIZE_T)(-p_nb_bytes) > state->offset)
      state->offset = 0;
    else
      state->offset -= (OPJ_SIZE_T)(-p_nb_bytes);
  } else {
    OPJ_SIZE_T newOffset = state->offset + (OPJ_SIZE_T)p_nb_bytes;
    state->offset = (newOffset > state->size) ? state->size : newOffset;
  }
  return (OPJ_OFF_T)state->offset;
}

static OPJ_BOOL opj_mem_seek(OPJ_OFF_T p_nb_bytes, void *p_user_data) {
  MemoryStreamState *state = (MemoryStreamState *)p_user_data;
  if (p_nb_bytes < 0 || (OPJ_SIZE_T)p_nb_bytes > state->size)
    return OPJ_FALSE;
  state->offset = (OPJ_SIZE_T)p_nb_bytes;
  return OPJ_TRUE;
}

static void opj_error_callback(const char *msg, void *client_data) {
  NSLog(@"[OpenJPEG ERROR] %s", msg);
}
static void opj_warning_callback(const char *msg, void *client_data) {
  // Suppress warnings for cleaner logs
}
static void opj_info_callback(const char *msg, void *client_data) {
  // Suppress info for cleaner logs
}

+ (NSData *)decodeJPEG2000DICOM:(NSString *)path
                          width:(NSInteger *)width
                         height:(NSInteger *)height
                       bitDepth:(NSInteger *)bitDepth
                        samples:(NSInteger *)samples
                       isSigned:(BOOL *)isSigned {
  if (!path)
    return nil;

  // 1. Load DICOM dataset
  DcmFileFormat fileformat;
  OFCondition status = fileformat.loadFile([path UTF8String]);
  if (status.bad()) {
    NSLog(@"[J2K] Cannot load DICOM: %s", status.text());
    return nil;
  }

  DcmDataset *dataset = fileformat.getDataset();
  if (!dataset) {
    NSLog(@"[J2K] No dataset");
    return nil;
  }

  // 2. Check transfer syntax for JPEG2000
  OFString tsUID;
  fileformat.getMetaInfo()->findAndGetOFString(DCM_TransferSyntaxUID, tsUID);
  NSString *transferSyntax =
      [NSString stringWithUTF8String:tsUID.c_str()];

  BOOL isJPEG2000 =
      [transferSyntax isEqualToString:@"1.2.840.10008.1.2.4.90"] || // Lossless
      [transferSyntax isEqualToString:@"1.2.840.10008.1.2.4.91"];   // Lossy

  if (!isJPEG2000) {
    NSLog(@"[J2K] Not JPEG2000 transfer syntax: %@", transferSyntax);
    return nil;
  }

  // 3. Get image dimensions from DICOM tags
  Uint16 dcmRows = 0, dcmCols = 0, dcmBitsAlloc = 0, dcmBitsStored = 0;
  Uint16 dcmSamplesPerPixel = 0, dcmPixelRep = 0;
  dataset->findAndGetUint16(DCM_Rows, dcmRows);
  dataset->findAndGetUint16(DCM_Columns, dcmCols);
  dataset->findAndGetUint16(DCM_BitsAllocated, dcmBitsAlloc);
  dataset->findAndGetUint16(DCM_BitsStored, dcmBitsStored);
  dataset->findAndGetUint16(DCM_SamplesPerPixel, dcmSamplesPerPixel);
  dataset->findAndGetUint16(DCM_PixelRepresentation, dcmPixelRep);

  if (dcmRows == 0 || dcmCols == 0) {
    NSLog(@"[J2K] Invalid dimensions: %dx%d", dcmCols, dcmRows);
    return nil;
  }

  // 4. Extract encapsulated pixel data
  DcmElement *pixelElement = NULL;
  status = dataset->findAndGetElement(DCM_PixelData, pixelElement);
  if (status.bad() || !pixelElement) {
    NSLog(@"[J2K] No pixel data element");
    return nil;
  }

  DcmPixelData *pixelData = OFstatic_cast(DcmPixelData *, pixelElement);
  DcmPixelSequence *pixelSeq = NULL;
  E_TransferSyntax xfer = dataset->getOriginalXfer();
  status = pixelData->getEncapsulatedRepresentation(xfer, NULL, pixelSeq);
  if (status.bad() || !pixelSeq) {
    NSLog(@"[J2K] Cannot get encapsulated representation");
    return nil;
  }

  // Skip offset table (first item), get first actual frame
  DcmPixelItem *pixelItem = NULL;
  // Item 0 is the offset table, item 1+ are actual frames
  Uint32 numItems = pixelSeq->card();
  if (numItems < 2) {
    NSLog(@"[J2K] No frame data items (only %d items)", numItems);
    return nil;
  }

  // Collect the first frame's fragments. A frame may span several items;
  // the next frame starts with a new codestream (J2K SOC+SIZ marker
  // FF4F FF51) or JP2 signature box.
  NSMutableData *j2kData = [NSMutableData data];
  for (Uint32 i = 1; i < numItems; i++) {
    status = pixelSeq->getItem(pixelItem, i);
    if (status.bad() || !pixelItem)
      break;
    Uint8 *fragData = NULL;
    status = pixelItem->getUint8Array(fragData);
    if (status.good() && fragData) {
      Uint32 fragLen = pixelItem->getLength();
      BOOL startsCodestream =
          (fragLen >= 4 && fragData[0] == 0xFF && fragData[1] == 0x4F &&
           fragData[2] == 0xFF && fragData[3] == 0x51) ||
          (fragLen >= 12 && fragData[4] == 'j' && fragData[5] == 'P');
      if (j2kData.length > 0 && startsCodestream)
        break;
      [j2kData appendBytes:fragData length:fragLen];
    }
  }

  if (j2kData.length == 0) {
    NSLog(@"[J2K] No compressed data extracted");
    return nil;
  }

  // 5. Decode with OpenJPEG
  opj_dparameters_t parameters;
  opj_set_default_decoder_parameters(&parameters);

  // Detect codec type from stream header
  opj_codec_t *codec = NULL;
  const uint8_t *j2kBytes = (const uint8_t *)j2kData.bytes;

  // JP2 format starts with 0x0000000C (box header)
  // J2K codestream starts with 0xFF4F (SOC marker)
  if (j2kData.length >= 4 && j2kBytes[0] == 0xFF && j2kBytes[1] == 0x4F) {
    codec = opj_create_decompress(OPJ_CODEC_J2K);
  } else {
    codec = opj_create_decompress(OPJ_CODEC_JP2);
  }

  if (!codec) {
    NSLog(@"[J2K] Failed to create OpenJPEG decoder");
    return nil;
  }

  opj_set_error_handler(codec, opj_error_callback, NULL);
  opj_set_warning_handler(codec, opj_warning_callback, NULL);
  opj_set_info_handler(codec, opj_info_callback, NULL);

  if (!opj_setup_decoder(codec, &parameters)) {
    NSLog(@"[J2K] Failed to setup decoder");
    opj_destroy_codec(codec);
    return nil;
  }

  // Create memory-based stream using custom callbacks
  MemoryStreamState *streamState = new MemoryStreamState();
  streamState->data = (const uint8_t *)j2kData.bytes;
  streamState->size = j2kData.length;
  streamState->offset = 0;

  opj_stream_t *stream = opj_stream_create(OPJ_J2K_STREAM_CHUNK_SIZE, OPJ_TRUE);
  if (!stream) {
    NSLog(@"[J2K] Failed to create stream");
    delete streamState;
    opj_destroy_codec(codec);
    return nil;
  }

  opj_stream_set_user_data(stream, streamState, NULL);
  opj_stream_set_user_data_length(stream, j2kData.length);
  opj_stream_set_read_function(stream, opj_mem_read);
  opj_stream_set_skip_function(stream, opj_mem_skip);
  opj_stream_set_seek_function(stream, opj_mem_seek);

  opj_image_t *image = NULL;
  if (!opj_read_header(stream, codec, &image)) {
    NSLog(@"[J2K] Failed to read JPEG2000 header");
    opj_stream_destroy(stream);
    opj_destroy_codec(codec);
    delete streamState;
    return nil;
  }

  if (!opj_decode(codec, stream, image)) {
    NSLog(@"[J2K] Failed to decode JPEG2000 data");
    opj_image_destroy(image);
    opj_stream_destroy(stream);
    opj_destroy_codec(codec);
    delete streamState;
    return nil;
  }

  opj_stream_destroy(stream);
  opj_destroy_codec(codec);
  delete streamState;

  // 6. Convert OpenJPEG image to raw pixel data
  if (!image || image->numcomps == 0) {
    NSLog(@"[J2K] Decoded image has no components");
    if (image)
      opj_image_destroy(image);
    return nil;
  }

  OPJ_UINT32 imgWidth = image->comps[0].w;
  OPJ_UINT32 imgHeight = image->comps[0].h;
  OPJ_UINT32 numComps = image->numcomps;
  OPJ_UINT32 prec = image->comps[0].prec;
  BOOL sgnd = image->comps[0].sgnd;

  // Validate decoded image dimensions
  if (imgWidth == 0 || imgHeight == 0 || imgWidth > 65535 || imgHeight > 65535) {
    NSLog(@"[J2K] Invalid decoded dimensions: %ux%u", imgWidth, imgHeight);
    opj_image_destroy(image);
    return nil;
  }

  *width = imgWidth;
  *height = imgHeight;

  size_t pixelCount;
  if (__builtin_mul_overflow((size_t)imgWidth, (size_t)imgHeight, &pixelCount) ||
      pixelCount > (size_t)512 * 1024 * 1024) {
    NSLog(@"[J2K] Image too large");
    opj_image_destroy(image);
    return nil;
  }

  NSData *result = nil;

  if (numComps >= 3) {
    // Color: 8-bit interleaved RGB (down-shift higher precisions)
    for (OPJ_UINT32 c = 0; c < 3; c++) {
      if (!image->comps[c].data || image->comps[c].w != imgWidth ||
          image->comps[c].h != imgHeight) {
        NSLog(@"[J2K] Subsampled or missing color components not supported");
        opj_image_destroy(image);
        return nil;
      }
    }
    NSMutableData *rgb = [NSMutableData dataWithLength:pixelCount * 3];
    uint8_t *out = (uint8_t *)rgb.mutableBytes;
    for (OPJ_UINT32 c = 0; c < 3; c++) {
      OPJ_UINT32 cprec = image->comps[c].prec;
      int shift = cprec > 8 ? (int)(cprec - 8) : 0;
      int offset = image->comps[c].sgnd ? (1 << (cprec - 1)) : 0;
      const OPJ_INT32 *src = image->comps[c].data;
      for (size_t i = 0; i < pixelCount; i++) {
        int v = (src[i] + offset) >> shift;
        out[i * 3 + c] = (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
      }
    }
    *samples = 3;
    *bitDepth = 8;
    *isSigned = NO;
    result = rgb;
  } else {
    // Monochrome: stored values -> modality values via RescaleSlope/Intercept,
    // matching DCMTK's getInterData() so all decode paths share units.
    const OPJ_INT32 *src = image->comps[0].data;
    if (!src) {
      opj_image_destroy(image);
      return nil;
    }
    Float64 slope = 1.0, intercept = 0.0;
    if (dataset->findAndGetFloat64(DCM_RescaleSlope, slope).bad() || slope == 0)
      slope = 1.0;
    if (dataset->findAndGetFloat64(DCM_RescaleIntercept, intercept).bad())
      intercept = 0.0;

    // Some encoders store signed data with the J2K component marked
    // unsigned; sign-extend from the stored precision in that case.
    BOOL signExtend = (dcmPixelRep == 1) && !sgnd && prec > 0 && prec < 32;
    double *values = (double *)malloc(pixelCount * sizeof(double));
    if (!values) {
      opj_image_destroy(image);
      return nil;
    }
    for (size_t i = 0; i < pixelCount; i++) {
      int64_t v = src[i];
      if (signExtend && (v & ((int64_t)1 << (prec - 1))))
        v -= ((int64_t)1 << prec);
      values[i] = (double)v * slope + intercept;
    }
    *samples = 1;
    result = packModalityValues(values, pixelCount, bitDepth, isSigned);
    free(values);
  }

  opj_image_destroy(image);

  NSLog(@"[J2K] Successfully decoded %ldx%ld %ldbit %ldch",
        (long)*width, (long)*height, (long)*bitDepth, (long)*samples);
  return result;
}

@end

@implementation DCMTKImageObject {
  DicomImage *_image;
}

+ (void)initialize {
  ensureDCMTKInitialized();
}

- (instancetype)initWithPath:(NSString *)path {
  self = [super init];
  if (self) {
    _image = new DicomImage([path UTF8String], CIF_DecompressCompletePixelData);
    if (_image == NULL || _image->getStatus() != EIS_Normal) {
      if (_image)
        delete _image;
      _image = NULL;
      return nil;
    }
  }
  return self;
}

- (void)dealloc {
  if (_image) {
    delete _image;
    _image = NULL;
  }
}

- (NSImage *)renderImageWithWidth:(NSInteger)width
                           height:(NSInteger)height
                               ww:(double)ww
                               wc:(double)wc {
  if (!_image)
    return nil;

  // Set Window/Level
  // Note: DicomImage::setWindow takes center, width
  if (ww > 0) {
    _image->setWindow(wc, ww);
  }

  // Output 8-bit for display
  unsigned long size = _image->getOutputDataSize(8);
  if (size == 0)
    return nil;

  uint8_t *buffer = (uint8_t *)malloc(size);
  if (_image->getOutputData(buffer, size, 8)) {
    CGColorSpaceRef colorSpace = _image->isMonochrome()
                                     ? CGColorSpaceCreateDeviceGray()
                                     : CGColorSpaceCreateDeviceRGB();

    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, buffer,
                                                 size, kCFAllocatorMalloc);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);

    int samples = _image->isMonochrome() ? 1 : 3;
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault | kCGImageAlphaNone;

    CGImageRef cgImage =
        CGImageCreate(_image->getWidth(), _image->getHeight(), 8, 8 * samples,
                      _image->getWidth() * samples, colorSpace, bitmapInfo,
                      provider, NULL, false, kCGRenderingIntentDefault);

    // Use actual image dimensions when caller passes 0
    NSInteger finalWidth = (width > 0) ? width : (NSInteger)_image->getWidth();
    NSInteger finalHeight = (height > 0) ? height : (NSInteger)_image->getHeight();

    NSImage *nsImage =
        [[NSImage alloc] initWithCGImage:cgImage
                                    size:NSMakeSize(finalWidth, finalHeight)];

    CGImageRelease(cgImage);
    CGDataProviderRelease(provider);
    CFRelease(data);
    CGColorSpaceRelease(colorSpace);

    return nsImage;
  }

  free(buffer);
  return nil;
}

- (NSData *)getRawDataWidth:(NSInteger *)width
                     height:(NSInteger *)height
                   bitDepth:(NSInteger *)bitDepth
                    samples:(NSInteger *)samples
                   isSigned:(BOOL *)isSigned {
  if (!_image)
    return nil;

  *width = _image->getWidth();
  *height = _image->getHeight();
  return copyModalityPixels(_image, bitDepth, samples, isSigned);
}

- (double)getWindowWidth {
  double c = 0, w = 0;
  return storedWindow(_image, &c, &w) ? w : 0;
}

- (double)getWindowCenter {
  double c = 0, w = 0;
  return storedWindow(_image, &c, &w) ? c : 0;
}

- (BOOL)isMonochrome1 {
  return _image && _image->getPhotometricInterpretation() == EPI_Monochrome1;
}

@end
