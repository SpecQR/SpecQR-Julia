using SpecQR
q = generate("Hello, 世界 🌍"; error_correction_level="Q")
println("version=$(q.version), mask=$(q.mask_pattern), modules=$(size(q.matrix,1))")
println("planned bits=",plan("Hello, 世界 🌍").data_bit_length)
write("hello.svg",to_svg(q))
write("hello.png",to_png(q))
