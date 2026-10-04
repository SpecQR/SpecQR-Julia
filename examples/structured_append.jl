using SpecQR
set=generate_structured_append(repeat("SPECQR ",20);version=1)
println("parts=$(set.total), parity=$(set.parity)")
for (i,q) in enumerate(set.symbols)
    write("part-$(lpad(i,2,'0')).png",to_png(q))
end
