# checkpoint_convert.py
# OpenDicomViewer
#
# Converts Meta's single-file SAM 3 checkpoint (`sam3.pt`, the file the store
# asks the user to place) into the Hugging Face layout `transformers` loads.
#
# The key mapping between the two below `# fmt: off` is vendored verbatim from
# transformers' `models/sam3_video/convert_sam3_video_to_hf.py` (Apache-2.0,
# copyright 2025 The Meta AI Authors and The HuggingFace Inc. team), which is
# not shipped in the transformers wheel. That script reads Meta's internal
# checkpoint layout (`sam3_model.*` / `sam2_predictor.model.*`); the public
# `sam3.pt` stores the same tensors as `detector.*` / `tracker.*` (see Meta's
# `sam3.model_builder._load_checkpoint`), so `convert_state_dict` renames
# those two prefixes first and then applies the upstream mapping unchanged.
#
# VERIFIED STRUCTURALLY, NOT AGAINST THE REAL WEIGHTS: the checkpoint itself is
# gated behind Meta's licence. `plugins/sam3/tests/test_checkpoint_convert.py`
# (opt-in, needs torch, transformers and Meta's `sam3` package) builds Meta's
# model with random weights, takes its state-dict names and shapes, runs them
# through this conversion, and requires `Sam3TrackerModel` to load the result
# with no missing or mismatched tensors and to decode a mask. Whether the
# released file has exactly those names is what that cannot prove; a mismatch
# shows up as a load error naming the missing keys, not as silent garbage,
# because loading is strict about the tracker's tensors.
#
# Licensed under the MIT License (this file's own code) and Apache-2.0 (the
# vendored mapping). See LICENSE and THIRD_PARTY_LICENSES.md for details.
"""Single-file SAM 3 checkpoint -> Hugging Face directory."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any, Callable

# The prefixes of the public checkpoint and the internal layout the upstream
# mapping was written against.
PUBLIC_TO_INTERNAL_PREFIX = {
    "detector.": "sam3_model.",
    "tracker.": "sam2_predictor.model.",
}

# Written beside the converted files; records which source it was made from so
# a replaced sam3.pt is converted again rather than shadowed by a stale copy.
SOURCE_STAMP = ".odv-converted-from.json"

# fmt: off
ORIGINAL_TO_CONVERTED_KEY_MAPPING = {
    r"^sam3_model\.": r"detector_model.",
    r"^sam2_predictor\.model\.": r"tracker_model.",

    # ============================================================================
    # Vision Encoder - ViT Backbone
    # ============================================================================
    r"backbone\.vision_backbone\.trunk\.":                                 r"vision_encoder.backbone.",
    r"vision_encoder\.backbone\.pos_embed":                                r"vision_encoder.backbone.embeddings.position_embeddings",
    r"vision_encoder\.backbone\.patch_embed\.proj\.":                      r"vision_encoder.backbone.embeddings.patch_embeddings.projection.",
    r"vision_encoder\.backbone\.ln_pre\.":                                 r"vision_encoder.backbone.layer_norm.",
    r"vision_encoder\.backbone\.blocks\.(\d+)\.norm1\.":                   r"vision_encoder.backbone.layers.\1.layer_norm1.",
    r"vision_encoder\.backbone\.blocks\.(\d+)\.norm2\.":                   r"vision_encoder.backbone.layers.\1.layer_norm2.",
    r"vision_encoder\.backbone\.blocks\.(\d+)\.attn\.qkv\.":               r"vision_encoder.backbone.layers.\1.attention.qkv.",
    r"vision_encoder\.backbone\.blocks\.(\d+)\.attn\.proj\.":              r"vision_encoder.backbone.layers.\1.attention.o_proj.",
    r"vision_encoder\.backbone\.blocks\.(\d+)\.attn\.freqs_cis":           r"vision_encoder.backbone.layers.\1.rotary_emb.rope_embeddings",
    r"vision_encoder\.backbone\.blocks\.(\d+)\.mlp\.fc1\.":                r"vision_encoder.backbone.layers.\1.mlp.fc1.",
    r"vision_encoder\.backbone\.blocks\.(\d+)\.mlp\.fc2\.":                r"vision_encoder.backbone.layers.\1.mlp.fc2.",

    # ision Encoder - FPN Neck
    r"backbone\.vision_backbone\.neck\.fpn\.(\d+)\.":                      r"vision_encoder.neck.fpn_layers.\1.",
    r"backbone\.vision_backbone\.convs\.(\d+)\.dconv_2x2_0\.":             r"vision_encoder.neck.fpn_layers.\1.scale_layers.0.",
    r"backbone\.vision_backbone\.convs\.(\d+)\.dconv_2x2_1\.":             r"vision_encoder.neck.fpn_layers.\1.scale_layers.2.",
    r"backbone\.vision_backbone\.convs\.(\d+)\.dconv_2x2\.":               r"vision_encoder.neck.fpn_layers.\1.scale_layers.0.",
    r"backbone\.vision_backbone\.convs\.(\d+)\.maxpool_2x2\.":             r"vision_encoder.neck.fpn_layers.\1.scale_layers.0.",
    r"backbone\.vision_backbone\.convs\.(\d+)\.conv_1x1\.":                r"vision_encoder.neck.fpn_layers.\1.proj1.",
    r"backbone\.vision_backbone\.convs\.(\d+)\.conv_3x3\.":                r"vision_encoder.neck.fpn_layers.\1.proj2.",

    # ision Encoder - Tracker FPN Neck
    r"backbone\.vision_backbone\.sam2_convs\.(\d+)\.dconv_2x2_0\.":             r"vision_encoder.tracker_neck.fpn_layers.\1.scale_layers.0.",
    r"backbone\.vision_backbone\.sam2_convs\.(\d+)\.dconv_2x2_1\.":             r"vision_encoder.tracker_neck.fpn_layers.\1.scale_layers.2.",
    r"backbone\.vision_backbone\.sam2_convs\.(\d+)\.dconv_2x2\.":               r"vision_encoder.tracker_neck.fpn_layers.\1.scale_layers.0.",
    r"backbone\.vision_backbone\.sam2_convs\.(\d+)\.maxpool_2x2\.":             r"vision_encoder.tracker_neck.fpn_layers.\1.scale_layers.0.",
    r"backbone\.vision_backbone\.sam2_convs\.(\d+)\.conv_1x1\.":                r"vision_encoder.tracker_neck.fpn_layers.\1.proj1.",
    r"backbone\.vision_backbone\.sam2_convs\.(\d+)\.conv_3x3\.":                r"vision_encoder.tracker_neck.fpn_layers.\1.proj2.",

    # ===========================================================================
    # ext Encoder (CLIP)
    # ===========================================================================
    r"backbone\.language_backbone\.encoder\.":                             r"text_encoder.",
    r"text_encoder\.token_embedding\.":                                    r"text_encoder.text_model.embeddings.token_embedding.",
    r"text_encoder\.positional_embedding":                                 r"text_encoder.text_model.embeddings.position_embedding.weight",
    r"text_encoder\.ln_final\.":                                           r"text_encoder.text_model.final_layer_norm.",
    r"text_encoder\.text_projection":                                      r"text_encoder.text_projection.weight",
    r"text_encoder\.transformer\.resblocks\.(\d+)\.attn\.in_proj_":       r"text_encoder.text_model.encoder.layers.\1.self_attn.in_proj_",
    r"text_encoder\.transformer\.resblocks\.(\d+)\.attn\.out_proj\.":     r"text_encoder.text_model.encoder.layers.\1.self_attn.out_proj.",
    r"text_encoder\.transformer\.resblocks\.(\d+)\.ln_1\.":               r"text_encoder.text_model.encoder.layers.\1.layer_norm1.",
    r"text_encoder\.transformer\.resblocks\.(\d+)\.ln_2\.":               r"text_encoder.text_model.encoder.layers.\1.layer_norm2.",
    r"text_encoder\.transformer\.resblocks\.(\d+)\.mlp\.c_fc\.":          r"text_encoder.text_model.encoder.layers.\1.mlp.fc1.",
    r"text_encoder\.transformer\.resblocks\.(\d+)\.mlp\.c_proj\.":        r"text_encoder.text_model.encoder.layers.\1.mlp.fc2.",
    r"backbone\.language_backbone\.resizer\.":                             r"text_projection.",

    # ===========================================================================
    # eometry Encoder
    # ===========================================================================
    r"geometry_encoder\.encode\.(\d+)\.cross_attn_image\.out_proj\.":     r"geometry_encoder.layers.\1.cross_attn.o_proj.",
    r"geometry_encoder\.encode\.(\d+)\.cross_attn_image\.":               r"geometry_encoder.layers.\1.cross_attn.",
    r"geometry_encoder\.encode\.(\d+)\.self_attn\.out_proj\.":            r"geometry_encoder.layers.\1.self_attn.o_proj.",
    r"geometry_encoder\.encode\.(\d+)\.self_attn\.":                      r"geometry_encoder.layers.\1.self_attn.",
    r"geometry_encoder\.encode\.(\d+)\.linear1\.":                        r"geometry_encoder.layers.\1.mlp.fc1.",
    r"geometry_encoder\.encode\.(\d+)\.linear2\.":                        r"geometry_encoder.layers.\1.mlp.fc2.",
    r"geometry_encoder\.encode\.(\d+)\.norm1\.":                          r"geometry_encoder.layers.\1.layer_norm1.",
    r"geometry_encoder\.encode\.(\d+)\.norm2\.":                          r"geometry_encoder.layers.\1.layer_norm2.",
    r"geometry_encoder\.encode\.(\d+)\.norm3\.":                          r"geometry_encoder.layers.\1.layer_norm3.",
    r"geometry_encoder\.img_pre_norm\.":                                   r"geometry_encoder.vision_layer_norm.",
    r"geometry_encoder\.norm\.":                                           r"geometry_encoder.prompt_layer_norm.",
    r"geometry_encoder\.encode_norm\.":                                    r"geometry_encoder.output_layer_norm.",

    # ===========================================================================
    # ETR Encoder
    # ===========================================================================
    r"detector_model.transformer\.encoder\.layers\.(\d+)\.cross_attn_image\.out_proj\.":  r"detector_model.detr_encoder.layers.\1.cross_attn.o_proj.",
    r"detector_model.transformer\.encoder\.layers\.(\d+)\.cross_attn_image\.":            r"detector_model.detr_encoder.layers.\1.cross_attn.",
    r"detector_model.transformer\.encoder\.layers\.(\d+)\.self_attn\.out_proj\.":         r"detector_model.detr_encoder.layers.\1.self_attn.o_proj.",
    r"detector_model.transformer\.encoder\.layers\.(\d+)\.self_attn\.":                   r"detector_model.detr_encoder.layers.\1.self_attn.",
    r"detector_model.transformer\.encoder\.layers\.(\d+)\.cross_attn\.out_proj\.":        r"detector_model.detr_encoder.layers.\1.cross_attn.o_proj.",
    r"detector_model.transformer\.encoder\.layers\.(\d+)\.cross_attn\.":                  r"detector_model.detr_encoder.layers.\1.cross_attn.",
    r"detector_model.transformer\.encoder\.layers\.(\d+)\.linear1\.":                     r"detector_model.detr_encoder.layers.\1.mlp.fc1.",
    r"detector_model.transformer\.encoder\.layers\.(\d+)\.linear2\.":                     r"detector_model.detr_encoder.layers.\1.mlp.fc2.",
    r"detector_model.transformer\.encoder\.layers\.(\d+)\.norm1\.":                       r"detector_model.detr_encoder.layers.\1.layer_norm1.",
    r"detector_model.transformer\.encoder\.layers\.(\d+)\.norm2\.":                       r"detector_model.detr_encoder.layers.\1.layer_norm2.",
    r"detector_model.transformer\.encoder\.layers\.(\d+)\.norm3\.":                       r"detector_model.detr_encoder.layers.\1.layer_norm3.",

    # ===========================================================================
    # ETR Decoder
    # ===========================================================================
    r"transformer\.decoder\.query_embed\.":                                r"detr_decoder.query_embed.",
    r"transformer\.decoder\.reference_points\.":                           r"detr_decoder.reference_points.",
    r"transformer\.decoder\.instance_query_embed\.":                       r"detr_decoder.instance_query_embed.",
    r"transformer\.decoder\.instance_reference_points\.":                  r"detr_decoder.instance_reference_points.",
    r"transformer\.decoder\.presence_token\.":                             r"detr_decoder.presence_token.",
    r"transformer\.decoder\.presence_token_head\.layers\.0\.":             r"detr_decoder.presence_head.layer1.",
    r"transformer\.decoder\.presence_token_head\.layers\.1\.":             r"detr_decoder.presence_head.layer2.",
    r"transformer\.decoder\.presence_token_head\.layers\.2\.":             r"detr_decoder.presence_head.layer3.",
    r"transformer\.decoder\.presence_token_out_norm\.":                    r"detr_decoder.presence_layer_norm.",
    r"transformer\.decoder\.norm\.":                                       r"detr_decoder.output_layer_norm.",
    r"transformer\.decoder\.bbox_embed\.layers\.0\.":                      r"detr_decoder.box_head.layer1.",
    r"transformer\.decoder\.bbox_embed\.layers\.1\.":                      r"detr_decoder.box_head.layer2.",
    r"transformer\.decoder\.bbox_embed\.layers\.2\.":                      r"detr_decoder.box_head.layer3.",
    r"transformer\.decoder\.instance_bbox_embed\.layers\.0\.":             r"detr_decoder.instance_box_head.layer1.",
    r"transformer\.decoder\.instance_bbox_embed\.layers\.1\.":             r"detr_decoder.instance_box_head.layer2.",
    r"transformer\.decoder\.instance_bbox_embed\.layers\.2\.":             r"detr_decoder.instance_box_head.layer3.",
    r"transformer\.decoder\.ref_point_head\.layers\.0\.":                  r"detr_decoder.ref_point_head.layer1.",
    r"transformer\.decoder\.ref_point_head\.layers\.1\.":                  r"detr_decoder.ref_point_head.layer2.",
    r"transformer\.decoder\.boxRPB_embed_x\.layers\.0\.":                  r"detr_decoder.box_rpb_embed_x.layer1.",
    r"transformer\.decoder\.boxRPB_embed_x\.layers\.1\.":                  r"detr_decoder.box_rpb_embed_x.layer2.",
    r"transformer\.decoder\.boxRPB_embed_y\.layers\.0\.":                  r"detr_decoder.box_rpb_embed_y.layer1.",
    r"transformer\.decoder\.boxRPB_embed_y\.layers\.1\.":                  r"detr_decoder.box_rpb_embed_y.layer2.",
    r"transformer\.decoder\.layers\.(\d+)\.self_attn\.out_proj\.":         r"detr_decoder.layers.\1.self_attn.o_proj.",
    r"transformer\.decoder\.layers\.(\d+)\.self_attn\.":                   r"detr_decoder.layers.\1.self_attn.",
    r"transformer\.decoder\.layers\.(\d+)\.ca_text\.out_proj\.":           r"detr_decoder.layers.\1.text_cross_attn.o_proj.",
    r"transformer\.decoder\.layers\.(\d+)\.ca_text\.":                     r"detr_decoder.layers.\1.text_cross_attn.",
    r"transformer\.decoder\.layers\.(\d+)\.cross_attn\.out_proj\.":        r"detr_decoder.layers.\1.vision_cross_attn.o_proj.",
    r"transformer\.decoder\.layers\.(\d+)\.cross_attn\.":                  r"detr_decoder.layers.\1.vision_cross_attn.",
    r"transformer\.decoder\.layers\.(\d+)\.linear1\.":                     r"detr_decoder.layers.\1.mlp.fc1.",
    r"transformer\.decoder\.layers\.(\d+)\.linear2\.":                     r"detr_decoder.layers.\1.mlp.fc2.",
    r"transformer\.decoder\.layers\.(\d+)\.norm1\.":                       r"detr_decoder.layers.\1.vision_cross_attn_layer_norm.",
    r"transformer\.decoder\.layers\.(\d+)\.catext_norm\.":                 r"detr_decoder.layers.\1.text_cross_attn_layer_norm.",
    r"transformer\.decoder\.layers\.(\d+)\.norm2\.":                       r"detr_decoder.layers.\1.self_attn_layer_norm.",
    r"transformer\.decoder\.layers\.(\d+)\.norm3\.":                       r"detr_decoder.layers.\1.mlp_layer_norm.",

    # ===========================================================================
    # dot Product Scoring
    # ===========================================================================
    r"dot_prod_scoring\.prompt_mlp\.layers\.0\.":                          r"dot_product_scoring.text_mlp.layer1.",
    r"dot_prod_scoring\.prompt_mlp\.layers\.1\.":                          r"dot_product_scoring.text_mlp.layer2.",
    r"dot_prod_scoring\.prompt_mlp\.out_norm\.":                           r"dot_product_scoring.text_mlp_out_norm.",
    r"dot_prod_scoring\.prompt_proj\.":                                    r"dot_product_scoring.text_proj.",
    r"dot_prod_scoring\.hs_proj\.":                                        r"dot_product_scoring.query_proj.",

    # ===========================================================================
    # ask Decoder
    # ===========================================================================
    r"segmentation_head\.pixel_decoder\.conv_layers\.(\d+)\.":             r"mask_decoder.pixel_decoder.conv_layers.\1.",
    r"segmentation_head\.pixel_decoder\.norms\.(\d+)\.":                   r"mask_decoder.pixel_decoder.norms.\1.",
    r"segmentation_head\.mask_embed\.layers\.(\d+)\.":                     r"mask_decoder.mask_embedder.layers.\1.",
    r"segmentation_head\.mask_predictor\.mask_embed\.layers\.(\d+)\.":     r"mask_decoder.mask_embedder.layers.\1.",
    r"segmentation_head\.instance_seg_head\.":                             r"mask_decoder.instance_projection.",
    r"segmentation_head\.semantic_seg_head\.":                             r"mask_decoder.semantic_projection.",
    r"segmentation_head\.cross_attend_prompt\.out_proj\.":                 r"mask_decoder.prompt_cross_attn.o_proj.",
    r"segmentation_head\.cross_attend_prompt\.":                           r"mask_decoder.prompt_cross_attn.",
    r"segmentation_head\.cross_attn_norm\.":                               r"mask_decoder.prompt_cross_attn_norm.",

    r"^detector_model\.vision_encoder\.tracker_neck\.": r"tracker_neck.",

}
# fmt: on

KEYS_TO_MODIFY_MAPPING = {
    "iou_prediction_head.layers.0": "iou_prediction_head.proj_in",
    "iou_prediction_head.layers.1": "iou_prediction_head.layers.0",
    "iou_prediction_head.layers.2": "iou_prediction_head.proj_out",
    "mask_decoder.output_upscaling.0": "mask_decoder.upscale_conv1",
    "mask_decoder.output_upscaling.1": "mask_decoder.upscale_layer_norm",
    "mask_decoder.output_upscaling.3": "mask_decoder.upscale_conv2",
    "mask_downscaling.0": "mask_embed.conv1",
    "mask_downscaling.1": "mask_embed.layer_norm1",
    "mask_downscaling.3": "mask_embed.conv2",
    "mask_downscaling.4": "mask_embed.layer_norm2",
    "mask_downscaling.6": "mask_embed.conv3",
    "dwconv": "depthwise_conv",
    "pwconv": "pointwise_conv",
    "fuser": "memory_fuser",
    "point_embeddings": "point_embed",
    "pe_layer.positional_encoding_gaussian_matrix": "shared_embedding.positional_embedding",
    "obj_ptr_tpos_proj": "temporal_positional_encoding_projection_layer",
    "no_obj_embed_spatial": "occlusion_spatial_embedding_parameter",
    "sam_prompt_encoder": "prompt_encoder",
    "sam_mask_decoder": "mask_decoder",
    "maskmem_tpos_enc": "memory_temporal_positional_encoding",
    "gamma": "scale",
    "image_encoder.neck": "vision_encoder.neck",
    "image_encoder": "vision_encoder.backbone",
    "neck.0": "neck.conv1",
    "neck.1": "neck.layer_norm1",
    "neck.2": "neck.conv2",
    "neck.3": "neck.layer_norm2",
    "pix_feat_proj": "feature_projection",
    "patch_embed.proj": "patch_embed.projection",
    "no_mem_embed": "no_memory_embedding",
    "no_mem_pos_enc": "no_memory_positional_encoding",
    "obj_ptr": "object_pointer",
    ".norm": ".layer_norm",
    "trunk.": "",
    "out_proj": "o_proj",
}


def adapt_internal_ckpt(ov_sd):
    # Replace values instead of keys, and remove any isinstance checks
    sam2_sd = {k: v.replace("backbone.vision_backbone.trunk", "image_encoder.trunk") for k, v in ov_sd.items()}
    sam2_sd = {k: v.replace("backbone.vision_backbone.convs", "image_encoder.neck.convs") for k, v in sam2_sd.items()}
    # rename components to be consistent with paper and public release
    sam2_sd = {k: v.replace("transformer.encoder", "memory_attention") for k, v in sam2_sd.items()}
    sam2_sd = {k: v.replace("maskmem_backbone", "memory_encoder") for k, v in sam2_sd.items()}
    sam2_sd = {
        k: v.replace(
            "memory_encoder.mask_downsampler.encoder.0.",
            "memory_encoder.mask_downsampler.layers.0.conv.",
        )
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace(
            "memory_encoder.mask_downsampler.encoder.1.",
            "memory_encoder.mask_downsampler.layers.0.layer_norm.",
        )
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace(
            "memory_encoder.mask_downsampler.encoder.3.",
            "memory_encoder.mask_downsampler.layers.1.conv.",
        )
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace(
            "memory_encoder.mask_downsampler.encoder.4.",
            "memory_encoder.mask_downsampler.layers.1.layer_norm.",
        )
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace(
            "memory_encoder.mask_downsampler.encoder.6.",
            "memory_encoder.mask_downsampler.layers.2.conv.",
        )
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace(
            "memory_encoder.mask_downsampler.encoder.7.",
            "memory_encoder.mask_downsampler.layers.2.layer_norm.",
        )
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace(
            "memory_encoder.mask_downsampler.encoder.9.",
            "memory_encoder.mask_downsampler.layers.3.conv.",
        )
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace(
            "memory_encoder.mask_downsampler.encoder.10.",
            "memory_encoder.mask_downsampler.layers.3.layer_norm.",
        )
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace(
            "memory_encoder.mask_downsampler.encoder.12.",
            "memory_encoder.mask_downsampler.final_conv.",
        )
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace(
            "memory_encoder.o_proj.",
            "memory_encoder.projection.",
        )
        for k, v in sam2_sd.items()
    }
    # MLPBLock to MLP
    sam2_sd = {
        k: v.replace("mask_decoder.transformer.layers.0.mlp.lin1", "mask_decoder.transformer.layers.0.mlp.layers.0")
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace("mask_decoder.transformer.layers.0.mlp.lin2", "mask_decoder.transformer.layers.0.mlp.layers.1")
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace("mask_decoder.transformer.layers.1.mlp.lin1", "mask_decoder.transformer.layers.1.mlp.layers.0")
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace("mask_decoder.transformer.layers.1.mlp.lin2", "mask_decoder.transformer.layers.1.mlp.layers.1")
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace(
            "mask_decoder.transformer.layers.0.mlp.layers.0.",
            "mask_decoder.transformer.layers.0.mlp.proj_in.",
        )
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace(
            "mask_decoder.transformer.layers.0.mlp.layers.1.",
            "mask_decoder.transformer.layers.0.mlp.proj_out.",
        )
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace(
            "mask_decoder.transformer.layers.1.mlp.layers.0.",
            "mask_decoder.transformer.layers.1.mlp.proj_in.",
        )
        for k, v in sam2_sd.items()
    }
    sam2_sd = {
        k: v.replace(
            "mask_decoder.transformer.layers.1.mlp.layers.1.",
            "mask_decoder.transformer.layers.1.mlp.proj_out.",
        )
        for k, v in sam2_sd.items()
    }
    # FFN to MLP
    # sam2_sd = {k: v.replace(".fc1", ".layers.0") for k, v in sam2_sd.items()}
    # sam2_sd = {k: v.replace(".fc2", ".layers.1") for k, v in sam2_sd.items()}
    return sam2_sd


def replace_keys(key_mapping: dict):
    output_hypernetworks_mlps_pattern = r".*.output_hypernetworks_mlps.(\d+).layers.(\d+).*"
    output_mask_decoder_mlps_pattern = r"tracker_model.mask_decoder.transformer.layers.(\d+).mlp.layers.(\d+).*"
    output_mask_decoder_score_head_pattern = r"tracker_model.mask_decoder.pred_obj_score_head.layers.(\d+).*"
    output_vision_encoder_mlps_pattern = r"vision_encoder.backbone.blocks.(\d+).mlp.layers.(\d+).*"
    output_vision_encoder_neck_pattern = r"tracker_model.vision_encoder.neck.convs.(\d+).conv"
    output_memory_encoder_projection_pattern = r"tracker_model.memory_encoder.o_proj.*"
    output_object_pointer_proj_pattern = r"tracker_model.object_pointer_proj.layers.(\d+).*"
    output_memory_encoder_mask_downsampler_pattern = r"tracker_model.memory_encoder.mask_downsampler.encoder.(\d+).*"
    key_mapping_copy = key_mapping.copy()
    for value, key in key_mapping_copy.items():
        if not value.startswith("sam2_predictor."):
            continue
        for key_to_modify, new_key in KEYS_TO_MODIFY_MAPPING.items():
            if key_to_modify in key:
                key = key.replace(key_to_modify, new_key)

        # vision_encoder.blocks.0.mlp.layers.1.weight -> vision_encoder.blocks.0.mlp.proj_out.weight
        if re.match(output_vision_encoder_mlps_pattern, key):
            layer_nb = int(re.match(output_vision_encoder_mlps_pattern, key).group(2))
            if layer_nb == 0:
                key = key.replace("layers.0", "proj_in")
            elif layer_nb == 1:
                key = key.replace("layers.1", "proj_out")

        # mask_decoder.transformer.layers.0.mlp.layers.1.weight -> mask_decoder.transformer.layers.1.mlp.proj_out.weight
        if re.match(output_mask_decoder_mlps_pattern, key):
            layer_nb = int(re.match(output_mask_decoder_mlps_pattern, key).group(2))
            if layer_nb == 0:
                key = key.replace("mlp.layers.0", "mlp.proj_in")
            elif layer_nb == 1:
                key = key.replace("mlp.layers.1", "mlp.proj_out")

        # mask_decoder.pred_obj_score_head.layers.1.weight -> mask_decoder.pred_obj_score_head.proj_in.weight
        if re.match(output_mask_decoder_score_head_pattern, key):
            layer_nb = int(re.match(output_mask_decoder_score_head_pattern, key).group(1))
            if layer_nb == 0:
                key = key.replace("layers.0", "proj_in")
            elif layer_nb == 1:
                key = key.replace("layers.1", "layers.0")
            elif layer_nb == 2:
                key = key.replace("layers.2", "proj_out")

        if re.match(output_hypernetworks_mlps_pattern, key):
            layer_nb = int(re.match(output_hypernetworks_mlps_pattern, key).group(2))
            if layer_nb == 0:
                key = key.replace("layers.0", "proj_in")
            elif layer_nb == 1:
                key = key.replace("layers.1", "layers.0")
            elif layer_nb == 2:
                key = key.replace("layers.2", "proj_out")

        # vision_encoder.neck.convs.1.conv.bias -> vision_encoder.neck.convs.1.bias
        if re.match(output_vision_encoder_neck_pattern, key):
            key = key.replace(".conv.", ".")

        # memory_encoder.o_proj.weight -> memory_encoder.projection.weight
        if re.match(output_memory_encoder_projection_pattern, key):
            key = key.replace(".o_proj.", ".projection.")

        if re.match(output_object_pointer_proj_pattern, key):
            layer_nb = int(re.match(output_object_pointer_proj_pattern, key).group(1))
            if layer_nb == 0:
                key = key.replace("layers.0", "proj_in")
            elif layer_nb == 1:
                key = key.replace("layers.1", "layers.0")
            elif layer_nb == 2:
                key = key.replace("layers.2", "proj_out")

        if re.match(output_memory_encoder_mask_downsampler_pattern, key):
            layer_nb = int(re.match(output_memory_encoder_mask_downsampler_pattern, key).group(1))
            if layer_nb == 12:
                key = key.replace(f"encoder.{layer_nb}", "final_conv")
            elif layer_nb % 3 == 0:
                key = key.replace(f"encoder.{layer_nb}", f"layers.{layer_nb // 3}.conv")
            elif layer_nb % 3 == 1:
                key = key.replace(f"encoder.{layer_nb}", f"layers.{layer_nb // 3}.layer_norm")
        key_mapping[value] = key

    return key_mapping


def convert_old_keys_to_new_keys(state_dict_keys: list[str]) -> dict[str, str]:
    """
    Convert original SAM3 checkpoint keys to HuggingFace format.

    This function applies regex patterns to efficiently rename keys in bulk.

    Args:
        state_dict_keys: List of original checkpoint keys

    Returns:
        Dictionary mapping original keys to new keys
    """
    output_dict = {}
    if state_dict_keys is not None:
        old_text = "\n".join(state_dict_keys)
        new_text = old_text

        # Apply all regex patterns
        for pattern, replacement in ORIGINAL_TO_CONVERTED_KEY_MAPPING.items():
            new_text = re.sub(pattern, replacement, new_text, flags=re.MULTILINE)

        output_dict = dict(zip(old_text.split("\n"), new_text.split("\n")))

    output_dict = replace_keys(output_dict)
    output_dict = adapt_internal_ckpt(output_dict)

    return output_dict


def split_qkv(state_dict: dict) -> dict:
    """
    Split combined QKV weights/biases into separate Q, K, V projections.

    Both the vision backbone and text encoder in the original SAM3 use combined QKV projections,
    but the refactored model uses separate Q, K, V projections.

    Args:
        state_dict: State dictionary with combined QKV weights

    Returns:
        State dictionary with split Q, K, V weights
    """
    import torch  # OpenDicomViewer: imported here so the module loads without torch

    # Handle vision backbone: .attention.qkv.* → .attention.{q,k,v}_proj.*
    vision_keys_to_split = [key for key in state_dict.keys() if ".attention.qkv." in key]

    for key in vision_keys_to_split:
        qkv = state_dict.pop(key)
        # Split into 3 equal chunks along dimension 0 (output dimension)
        q, k, v = torch.chunk(qkv, 3, dim=0)

        # Create new keys for q_proj, k_proj, v_proj
        state_dict[key.replace(".qkv.", ".q_proj.")] = q
        state_dict[key.replace(".qkv.", ".k_proj.")] = k
        state_dict[key.replace(".qkv.", ".v_proj.")] = v

    # Handle all attention layers with in_proj_* (text encoder, DETR decoder cross-attention, mask decoder)
    # These use: .{attn_type}.in_proj_* → .{attn_type}.{q,k,v}_proj.*
    in_proj_keys_to_split = [key for key in state_dict.keys() if ".in_proj_" in key]

    for key in in_proj_keys_to_split:
        in_proj = state_dict.pop(key)
        # Split into 3 equal chunks along dimension 0 (output dimension)
        q, k, v = torch.chunk(in_proj, 3, dim=0)

        # Create new keys for q_proj, k_proj, v_proj
        # Replace "in_proj_weight" with "q_proj.weight" (or "in_proj_bias" with "q_proj.bias")
        if key.endswith("in_proj_weight"):
            base_key = key.replace("in_proj_weight", "")
            state_dict[base_key + "q_proj.weight"] = q
            state_dict[base_key + "k_proj.weight"] = k
            state_dict[base_key + "v_proj.weight"] = v
        elif key.endswith("in_proj_bias"):
            base_key = key.replace("in_proj_bias", "")
            state_dict[base_key + "q_proj.bias"] = q
            state_dict[base_key + "k_proj.bias"] = k
            state_dict[base_key + "v_proj.bias"] = v

    return state_dict




# ---------------------------------------------------------------------------
# OpenDicomViewer glue
# ---------------------------------------------------------------------------


def source_fingerprint(checkpoint: Path) -> dict[str, Any]:
    stat = checkpoint.stat()
    return {"name": checkpoint.name, "size": stat.st_size, "mtime_ns": stat.st_mtime_ns}


def is_converted(out_dir: Path, checkpoint: Path) -> bool:
    """Whether `out_dir` holds a finished conversion of this exact file."""
    try:
        stamp = json.loads((out_dir / SOURCE_STAMP).read_text())
    except (OSError, ValueError):
        return False
    return (stamp == source_fingerprint(checkpoint)
            and (out_dir / "config.json").is_file()
            and (out_dir / "model.safetensors").is_file())


def unwrap(checkpoint: dict) -> dict:
    """The state dict inside whatever wrapper the training code saved."""
    for key in ("model", "state_dict"):
        inner = checkpoint.get(key)
        if isinstance(inner, dict):
            return inner
    return checkpoint


def to_internal_names(keys: list[str]) -> dict[str, str]:
    """Public `detector.` / `tracker.` names -> the layout the mapping expects.

    Keys already in the internal layout pass through, so a checkpoint saved by
    Meta's training code converts too.
    """
    renamed: dict[str, str] = {}
    for key in keys:
        new = key
        for public, internal in PUBLIC_TO_INTERNAL_PREFIX.items():
            if key.startswith(public):
                new = internal + key[len(public):]
                break
        renamed[key] = new
    return renamed


def convert_state_dict(state_dict: dict) -> dict:
    """Rename and reshape a SAM 3 state dict into the Hugging Face layout.

    Mirrors the body of upstream `convert_sam3_checkpoint` between loading the
    file and building the model.
    """
    import torch

    internal = to_internal_names(list(state_dict))
    internal_dict = {internal[key]: value for key, value in state_dict.items()}
    all_keys = list(internal_dict)
    key_mapping = convert_old_keys_to_new_keys(all_keys)

    converted: dict = {}
    for old_key in all_keys:
        new_key = key_mapping.get(old_key, old_key)
        if new_key == "detector_model.vision_encoder.backbone.embeddings.position_embeddings":
            # The original carries a cls-token position the port drops.
            converted[new_key] = internal_dict[old_key][:, 1:, :]
        else:
            converted[new_key] = internal_dict[old_key]

    converted["tracker_model.shared_image_embedding.positional_embedding"] = converted[
        "tracker_model.prompt_encoder.shared_embedding.positional_embedding"
    ]
    converted["tracker_model.prompt_encoder.point_embed.weight"] = torch.cat(
        [converted.pop(f"tracker_model.prompt_encoder.point_embed.{i}.weight") for i in range(4)],
        dim=0,
    )
    converted = split_qkv(converted)
    text_projection = "detector_model.text_encoder.text_projection.weight"
    if text_projection in converted:
        converted[text_projection] = converted[text_projection].T
    return converted


def _recomputed(key: str, value: Any) -> bool:
    """Tensors the port computes itself rather than loading.

    The original stores each ViT block's rotary table (`freqs_cis`) as a
    complex64 buffer; the port rebuilds it at construction (upstream lists it
    among the expected unexpected keys). safetensors writes complex tensors
    but transformers refuses to read them back, so they are left out.
    """
    return key.endswith("rotary_emb.rope_embeddings") or bool(getattr(value, "is_complex", lambda: False)())


def save_converted(state_dict: dict, out_dir: Path) -> None:
    """Write `model.safetensors` and a `config.json` the tracker can load.

    Tensors are made contiguous and unshared first: the QKV split leaves views
    into one storage and the positional embedding is stored under two names,
    and safetensors refuses either.
    """
    from safetensors.torch import save_file
    from transformers.models.sam3_video.configuration_sam3_video import Sam3VideoConfig

    out_dir.mkdir(parents=True, exist_ok=True)
    tensors = {key: value.detach().contiguous().clone() for key, value in state_dict.items()
               if not _recomputed(key, value)}
    save_file(tensors, str(out_dir / "model.safetensors"), metadata={"format": "pt"})
    config = Sam3VideoConfig()
    config.architectures = ["Sam3VideoModel"]
    config.save_pretrained(str(out_dir))


def convert_checkpoint(checkpoint: Path, out_dir: Path,
                       log: Callable[[str], None] = lambda _message: None) -> Path:
    """Convert `checkpoint` into `out_dir` once; reuse a finished conversion.

    Peak memory is about twice the checkpoint (the original tensors plus the
    contiguous copies written out), roughly 7 GB for SAM 3, and it happens
    once: later loads read the converted directory directly.
    """
    import torch

    if is_converted(out_dir, checkpoint):
        return out_dir
    log(f"Converting {checkpoint.name} to the Hugging Face layout (one time)")
    stamp = out_dir / SOURCE_STAMP
    if stamp.exists():
        stamp.unlink()
    raw = torch.load(str(checkpoint), map_location="cpu", weights_only=True)
    converted = convert_state_dict(unwrap(raw))
    del raw
    save_converted(converted, out_dir)
    del converted
    # Written last: its presence is what marks the conversion finished.
    tmp = out_dir / (SOURCE_STAMP + ".tmp")
    tmp.write_text(json.dumps(source_fingerprint(checkpoint)))
    os.replace(tmp, stamp)
    log(f"Converted checkpoint written to {out_dir}")
    return out_dir
