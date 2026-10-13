// J2KTestEncoder.h
// OpenDicomViewer Tests
//
// Test-only JPEG 2000 encoder (OpenJPEG) for building synthetic
// JPEG 2000 DICOM files. Not linked into the app.
// Licensed under the MIT License. See LICENSE for details.

#ifndef J2K_TEST_ENCODER_H
#define J2K_TEST_ENCODER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Losslessly encode one grayscale image as a raw J2K codestream (starts
/// with the SOC marker FF4F, as DICOM JPEG 2000 frames do). `pixels` holds
/// width × height stored values, row-major; `precision` is BitsStored and
/// `isSigned` marks the component signed. On success returns 1 and a
/// malloc'd buffer in *outBytes (release with j2k_test_free); 0 on failure.
int j2k_test_encode_gray(const int32_t *pixels, int width, int height,
                         int precision, int isSigned,
                         uint8_t **outBytes, size_t *outLength);

void j2k_test_free(uint8_t *bytes);

#ifdef __cplusplus
}
#endif

#endif
