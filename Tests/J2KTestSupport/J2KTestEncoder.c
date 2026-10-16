// J2KTestEncoder.c
// OpenDicomViewer Tests
//
// Test-only JPEG 2000 encoder: OpenJPEG writing a J2K codestream into a
// growable memory buffer.
// Licensed under the MIT License. See LICENSE for details.

#include "J2KTestEncoder.h"

#include <stdlib.h>
#include <string.h>
#include <openjpeg.h>

typedef struct {
  uint8_t *data;
  size_t length;    // bytes written (high-water mark)
  size_t capacity;
  size_t offset;    // current position
} OutputBuffer;

static OPJ_SIZE_T buffer_write(void *src, OPJ_SIZE_T count, void *user) {
  OutputBuffer *b = (OutputBuffer *)user;
  size_t end = b->offset + count;
  if (end > b->capacity) {
    size_t cap = b->capacity ? b->capacity : 4096;
    while (cap < end) cap *= 2;
    uint8_t *grown = (uint8_t *)realloc(b->data, cap);
    if (!grown) return (OPJ_SIZE_T)-1;
    b->data = grown;
    b->capacity = cap;
  }
  memcpy(b->data + b->offset, src, count);
  b->offset = end;
  if (end > b->length) b->length = end;
  return count;
}

static OPJ_OFF_T buffer_skip(OPJ_OFF_T count, void *user) {
  OutputBuffer *b = (OutputBuffer *)user;
  OPJ_OFF_T target = (OPJ_OFF_T)b->offset + count;
  if (target < 0) return -1;
  b->offset = (size_t)target;
  return count;
}

static OPJ_BOOL buffer_seek(OPJ_OFF_T position, void *user) {
  OutputBuffer *b = (OutputBuffer *)user;
  if (position < 0) return OPJ_FALSE;
  b->offset = (size_t)position;
  return OPJ_TRUE;
}

static void quiet(const char *msg, void *client) { (void)msg; (void)client; }

int j2k_test_encode_gray(const int32_t *pixels, int width, int height,
                         int precision, int isSigned,
                         uint8_t **outBytes, size_t *outLength) {
  if (!pixels || width <= 0 || height <= 0 || precision <= 0 || precision > 16 ||
      !outBytes || !outLength)
    return 0;

  opj_cparameters_t params;
  opj_set_default_encoder_parameters(&params);
  params.tcp_numlayers = 1;
  params.tcp_rates[0] = 0;   // lossless
  params.cp_disto_alloc = 1;
  params.irreversible = 0;   // reversible 5-3 wavelet
  // Few resolution levels so tiny test images are valid
  int levels = 1;
  while (levels < 6 && (width >> levels) >= 1 && (height >> levels) >= 1) levels++;
  params.numresolution = levels;

  opj_image_cmptparm_t comp;
  memset(&comp, 0, sizeof(comp));
  comp.dx = comp.dy = 1;
  comp.w = (OPJ_UINT32)width;
  comp.h = (OPJ_UINT32)height;
  comp.prec = (OPJ_UINT32)precision;
  comp.sgnd = isSigned ? 1 : 0;

  opj_image_t *image = opj_image_create(1, &comp, OPJ_CLRSPC_GRAY);
  if (!image) return 0;
  image->x0 = image->y0 = 0;
  image->x1 = (OPJ_UINT32)width;
  image->y1 = (OPJ_UINT32)height;
  memcpy(image->comps[0].data, pixels, (size_t)width * (size_t)height * sizeof(int32_t));

  int ok = 0;
  OutputBuffer out = {0};
  opj_codec_t *codec = opj_create_compress(OPJ_CODEC_J2K);
  opj_stream_t *stream = NULL;
  if (!codec) goto done;
  opj_set_error_handler(codec, quiet, NULL);
  opj_set_warning_handler(codec, quiet, NULL);
  opj_set_info_handler(codec, quiet, NULL);
  if (!opj_setup_encoder(codec, &params, image)) goto done;

  stream = opj_stream_create(OPJ_J2K_STREAM_CHUNK_SIZE, OPJ_FALSE);
  if (!stream) goto done;
  opj_stream_set_user_data(stream, &out, NULL);
  opj_stream_set_write_function(stream, buffer_write);
  opj_stream_set_skip_function(stream, buffer_skip);
  opj_stream_set_seek_function(stream, buffer_seek);

  if (opj_start_compress(codec, image, stream) && opj_encode(codec, stream) &&
      opj_end_compress(codec, stream))
    ok = 1;

done:
  if (stream) opj_stream_destroy(stream);  // flushes pending writes
  if (codec) opj_destroy_codec(codec);
  opj_image_destroy(image);
  if (ok && out.length > 0) {
    *outBytes = out.data;
    *outLength = out.length;
    return 1;
  }
  free(out.data);
  return 0;
}

void j2k_test_free(uint8_t *bytes) { free(bytes); }
