"""Base type for all checked SpecQR input and capacity failures."""
abstract type SpecQRError <: Exception end
for (name, code) in ((:DataTooLongError,"DATA_TOO_LONG"), (:InvalidInputError,"INVALID_INPUT"),
                     (:InvalidVersionError,"INVALID_VERSION"), (:InvalidModeError,"INVALID_MODE"),
                     (:InvalidColorError,"INVALID_COLOR"), (:InvalidEciError,"INVALID_ECI"),
                     (:InvalidOutputError,"INVALID_OUTPUT"),
                     (:InvalidEccError,"INVALID_ECC_LEVEL"))
    @eval begin
        struct $name <: SpecQRError
            message::String
        end
        error_code(::$name) = $code
    end
end
Base.showerror(io::IO, error::SpecQRError) = print(io, error_code(error), ": ", error.message)

struct InvalidGs1Error <: SpecQRError
    message::String
    detail_code::String
end
InvalidGs1Error(message::String) = InvalidGs1Error(message,"GS1_INVALID_INPUT")
error_code(::InvalidGs1Error) = "INVALID_GS1"
