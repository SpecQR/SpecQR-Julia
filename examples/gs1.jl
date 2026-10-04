using SpecQR
elements=[(ai="01",value="09506000134352"),(ai="10",value="BATCH%ONE")]
text=create_gs1_element_string(elements)
q=generate(text;gs1=true)
write("gs1.svg",to_svg(q))
println(create_gs1_digital_link(elements;base_url="https://id.example"))
