// DCMTKHelper.h
// OpenDicomViewer
//
// Public Objective-C interface for the DCMTK wrapper. Exposes DICOM image
// decoding functionality to Swift via two classes:
//   - DCMTKHelper: Stateless class methods for one-shot decoding
//   - DCMTKImageObject: Retains decoded image state for efficient re-rendering
// Licensed under the MIT License. See LICENSE for details.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@interface DCMTKHelper : NSObject

+ (NSImage *)convertDICOMToNSImage:(NSString *)path;
+ (NSData *)getRawPixelData:(NSString *)path
                      width:(NSInteger *)width
                     height:(NSInteger *)height
                   bitDepth:(NSInteger *)bitDepth
                    samples:(NSInteger *)samples
                   isSigned:(BOOL *)isSigned;

/// Returns a human-readable error string for the last failed DICOM load, or nil if no error.
+ (NSString *)lastErrorForPath:(NSString *)path;

/// Attempts to decode a JPEG2000-compressed DICOM file using OpenJPEG.
/// Returns the first frame's pixel data, or nil on failure. Monochrome data
/// has RescaleSlope/Intercept applied (modality units, matching the DCMTK
/// paths); color data is returned as 8-bit interleaved RGB.
+ (NSData *)decodeJPEG2000DICOM:(NSString *)path
                          width:(NSInteger *)width
                         height:(NSInteger *)height
                       bitDepth:(NSInteger *)bitDepth
                        samples:(NSInteger *)samples
                       isSigned:(BOOL *)isSigned;

@end

@interface DCMTKImageObject : NSObject

- (instancetype)initWithPath:(NSString *)path;
- (NSImage *)renderImageWithWidth:(NSInteger)width
                           height:(NSInteger)height
                               ww:(double)ww
                               wc:(double)wc;
- (NSData *)getRawDataWidth:(NSInteger *)width
                     height:(NSInteger *)height
                   bitDepth:(NSInteger *)bitDepth
                    samples:(NSInteger *)samples
                   isSigned:(BOOL *)isSigned;
/// File's stored WindowWidth/WindowCenter (first window, modality units), or 0 when absent.
- (double)getWindowWidth;
- (double)getWindowCenter;
/// YES when PhotometricInterpretation is MONOCHROME1 (min value displays white).
- (BOOL)isMonochrome1;

@end

/// Decodes individual frames of a multi-frame file through DCMTK (all
/// transfer syntaxes DCMTK has codecs for: JPEG baseline/extended/lossless,
/// JPEG-LS, RLE, uncompressed). The dataset is loaded once; pixel data is
/// read per frame with partial access. Thread-safe.
@interface DCMTKFrameDecoder : NSObject

- (instancetype)initWithPath:(NSString *)path;
@property(nonatomic, readonly) NSInteger frameCount;
/// Render one frame to 8-bit with the given window (modality units).
/// ww <= 0 uses DCMTK's min/max window for that frame.
- (CGImageRef)copyFrameImage:(NSInteger)frame ww:(double)ww wc:(double)wc CF_RETURNS_RETAINED;
/// Modality-unit min/max of one frame. Returns NO on failure.
- (BOOL)getMinMaxOfFrame:(NSInteger)frame min:(double *)minValue max:(double *)maxValue;
/// First stored window (modality units). Returns NO when the file has none.
- (BOOL)getStoredWindowCenter:(double *)center width:(double *)width;

@end
