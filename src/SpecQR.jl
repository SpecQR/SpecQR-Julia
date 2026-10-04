"""SpecQR: a from-scratch, standard-library-only QR encoder."""
module SpecQR
using Base64
include("errors.jl")
include("json.jl")
include("tables.jl")
include("core.jl")
include("kanji_data.jl")
include("segments.jl")
include("optimizer.jl")
include("render.jl")
include("gs1.jl")
include("api.jl")
include("structured_append.jl")
export SpecQRError, DataTooLongError, InvalidInputError, InvalidVersionError,
       InvalidModeError, InvalidColorError, InvalidEciError, InvalidGs1Error,
       InvalidOutputError, InvalidEccError, error_code
export Segment, Options, Capacity, Plan, QRResult, generate, generate_segments, plan, plan_segments, estimate, analyze_segments, get_capacity,
       optimize_segments, SegmentOptimizationTracker, append_character!, diagnostics, module_at,
       to_pixels, to_svg_data_url, to_png_data_url, render,
       to_svg, to_png, to_data_url, generate_structured_append,
       calculate_structured_append_parity, calculate_structured_append_segments_parity,
       generate_segments_structured_append, merge_structured_append_parts, SAResult, MergeResult, create_segments
export GS1Element, GS1AiLength, GS1AiInfo, GS1ElementStringParseResult,
       GS1ValidationIssue, GS1ValidationResult, GS1UnknownQuery,
       GS1DigitalLinkParseResult, GS1DigitalLinkValidationResult, GS1_FNC1_SEPARATOR,
       get_supported_gs1_ais, get_gs1_ai_info, calculate_gs1_check_digit,
       validate_gs1_check_digit, calculate_gtin_check_digit, append_gtin_check_digit,
       validate_gtin_check_digit, calculate_sscc_check_digit, append_sscc_check_digit,
       validate_sscc_check_digit, parse_gs1_human_readable, create_gs1_element_string,
       parse_gs1_element_string, normalize_gs1_elements, validate_gs1_elements,
       validate_gs1_element_string, create_gs1_digital_link, parse_gs1_digital_link,
       validate_gs1_digital_link, normalize_gs1_digital_link, gs1_normalize,
       gs1_from_human_readable, gs1_to_human_readable, gs1_to_element_string,
       gs1_element_string_to_human_readable, gs1_build, gs1_parse, gs1_digital_link,
       gs1_to_digital_link
export Pixels, render_rgba, render_dimensions, parse_color, contrast_ratio

end
